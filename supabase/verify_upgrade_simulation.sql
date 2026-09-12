-- ======================================================================
-- Isolated production-upgrade simulation: seed / assert / functional
-- ----------------------------------------------------------------------
-- Used by tool/verify_prod_upgrade_simulation.ps1 against the LOCAL isolated
-- Supabase Postgres only.
--
--   :phase = seed        -> capture the pre-upgrade synthetic state
--   :phase = assert      -> prove the upgrade preserved it
--   :phase = functional  -> pay a PRE-EXISTING visit through the new endpoint
--
-- The snapshot lives in a real table (`public.hims_upgrade_snapshot`) so it
-- survives between psql invocations. It is never created in production.
--
-- Preservation is asserted per OBJECT (one row per column / trigger / policy /
-- constraint), so the upgrade may legitimately ADD objects without failing:
-- a seed fact must still be true afterwards, never merely unchanged in count.
--
--   docker exec -i supabase_db_abdm_hims psql -U supabase_admin -d postgres ^
--       -v ON_ERROR_STOP=1 -v phase=seed -f - ^
--       < supabase/verify_upgrade_simulation.sql
-- ======================================================================

\set ON_ERROR_STOP on
\set QUIET on

SET search_path = public, extensions;

CREATE TABLE IF NOT EXISTS public.hims_upgrade_snapshot (
    phase  TEXT NOT NULL,
    metric TEXT NOT NULL,
    value  TEXT,
    PRIMARY KEY (phase, metric)
);

-- ----------------------------------------------------------------------
-- Synthetic pre-upgrade data.
--
-- NOTE: this runs against the PRE-upgrade schema too, so it must not mention
-- `deleted_at` (added by the offline-sync migration).
-- ----------------------------------------------------------------------
DO $fixture$
DECLARE
    v_hosp UUID;
BEGIN
    SELECT id INTO v_hosp FROM public.hospitals WHERE code = 'HIMS' LIMIT 1;
    IF v_hosp IS NULL THEN
        RAISE EXCEPTION 'seed requires the seeded HIMS hospital';
    END IF;

    INSERT INTO public.patients (id, hospital_id, uhid, first_name, last_name, mobile_number)
    VALUES ('eeeeeeee-0000-4000-8000-000000000021', v_hosp,
            'UPG-UHID-0001', 'Upgrade', 'Patient', '9000000001')
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.opd_registrations (
        id, hospital_id, patient_id, visit_date, consultation_fee,
        payment_amount, paid_amount, balance_amount, payment_status, status
    ) VALUES ('eeeeeeee-0000-4000-8000-000000000031', v_hosp,
              'eeeeeeee-0000-4000-8000-000000000021', CURRENT_DATE,
              500.00, 500.00, 500.00, 0, 'paid', 'completed')
    ON CONFLICT (id) DO UPDATE SET
        payment_amount = EXCLUDED.payment_amount,
        paid_amount = EXCLUDED.paid_amount,
        balance_amount = EXCLUDED.balance_amount,
        payment_status = EXCLUDED.payment_status,
        status = EXCLUDED.status;

    -- A second, still-unpaid visit: after the upgrade it is paid through the
    -- NEW atomic endpoint, proving the upgrade works on pre-existing rows.
    INSERT INTO public.opd_registrations (
        id, hospital_id, patient_id, visit_date, consultation_fee,
        payment_amount, paid_amount, balance_amount, payment_status, status
    ) VALUES ('eeeeeeee-0000-4000-8000-000000000032', v_hosp,
              'eeeeeeee-0000-4000-8000-000000000021', CURRENT_DATE,
              300.00, 300.00, 0, 300.00, 'unpaid', 'completed')
    ON CONFLICT (id) DO UPDATE SET
        payment_amount = EXCLUDED.payment_amount,
        paid_amount = 0,
        balance_amount = EXCLUDED.balance_amount,
        payment_status = 'unpaid',
        payment_mode = NULL;

    INSERT INTO public.billing (
        id, hospital_id, patient_id, opd_registration_id, source_type,
        bill_number, bill_date, bill_type, visit_type, subtotal, total_amount,
        discount_amount, net_amount, paid_amount, balance_amount,
        payment_status, status
    ) VALUES ('eeeeeeee-0000-4000-8000-000000000041', v_hosp,
              'eeeeeeee-0000-4000-8000-000000000021',
              'eeeeeeee-0000-4000-8000-000000000031', 'opd',
              'UPG-BILL-0001', CURRENT_DATE, 'opd', 'opd', 500.00, 500.00,
              0, 500.00, 500.00, 0, 'paid', 'paid')
    ON CONFLICT (id) DO UPDATE SET
        subtotal = EXCLUDED.subtotal,
        total_amount = EXCLUDED.total_amount,
        net_amount = EXCLUDED.net_amount,
        paid_amount = EXCLUDED.paid_amount,
        balance_amount = EXCLUDED.balance_amount,
        payment_status = EXCLUDED.payment_status,
        status = EXCLUDED.status;

    INSERT INTO public.billing_items (
        id, bill_id, item_type, item_name, quantity, unit_price, total_price
    ) VALUES ('eeeeeeee-0000-4000-8000-000000000051',
              'eeeeeeee-0000-4000-8000-000000000041', 'consultation',
              'Consultation Fee', 1, 500.00, 500.00)
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.payment_logs (
        id, bill_id, amount_paid, payment_amount, payment_mode
    ) VALUES ('eeeeeeee-0000-4000-8000-000000000061',
              'eeeeeeee-0000-4000-8000-000000000041', 500.00, 500.00, 'cash')
    ON CONFLICT (id) DO NOTHING;

    -- Keep the synthetic rows live when re-run against a POST-upgrade schema.
    IF EXISTS (
        SELECT 1 FROM information_schema.columns
         WHERE table_schema = 'public' AND table_name = 'opd_registrations'
           AND column_name = 'deleted_at'
    ) THEN
        EXECUTE 'UPDATE public.opd_registrations SET deleted_at = NULL WHERE id IN ('
             || quote_literal('eeeeeeee-0000-4000-8000-000000000031') || ','
             || quote_literal('eeeeeeee-0000-4000-8000-000000000032') || ')';
        EXECUTE 'UPDATE public.billing SET deleted_at = NULL WHERE id = '
             || quote_literal('eeeeeeee-0000-4000-8000-000000000041');
    END IF;
END
$fixture$;

-- ----------------------------------------------------------------------
-- Capture
-- ----------------------------------------------------------------------
DELETE FROM public.hims_upgrade_snapshot WHERE phase = :'phase';

-- Row counts (must not lose or gain rows to an ADDITIVE upgrade).
INSERT INTO public.hims_upgrade_snapshot (phase, metric, value)
SELECT :'phase', 'count:' || t, count(*)::text
  FROM (
    SELECT 'hospitals' AS t, id FROM public.hospitals
    UNION ALL SELECT 'users', id FROM public.users
    UNION ALL SELECT 'patients', id FROM public.patients
    UNION ALL SELECT 'opd_registrations', id FROM public.opd_registrations
    UNION ALL SELECT 'billing', id FROM public.billing
    UNION ALL SELECT 'billing_items', id FROM public.billing_items
    UNION ALL SELECT 'payment_logs', id FROM public.payment_logs
    UNION ALL SELECT 'doctors', id FROM public.doctors
    UNION ALL SELECT 'departments', id FROM public.departments
  ) x
 GROUP BY t;

-- Identifiers must be byte-identical.
INSERT INTO public.hims_upgrade_snapshot (phase, metric, value)
SELECT :'phase', 'ids:' || t, md5(string_agg(id::text, ',' ORDER BY id))
  FROM (
    SELECT 'patients' AS t, id FROM public.patients
    UNION ALL SELECT 'opd_registrations', id FROM public.opd_registrations
    UNION ALL SELECT 'billing', id FROM public.billing
    UNION ALL SELECT 'billing_items', id FROM public.billing_items
    UNION ALL SELECT 'payment_logs', id FROM public.payment_logs
  ) x
 GROUP BY t;

-- Business values must be untouched.
INSERT INTO public.hims_upgrade_snapshot (phase, metric, value)
VALUES (
    :'phase', 'patient:UPG-UHID-0001',
    (SELECT concat_ws('|', uhid, first_name, last_name, mobile_number,
                      hospital_id::text)
       FROM public.patients WHERE uhid = 'UPG-UHID-0001')
);

INSERT INTO public.hims_upgrade_snapshot (phase, metric, value)
VALUES (
    :'phase', 'bill:UPG-BILL-0001',
    (SELECT concat_ws('|', bill_number, subtotal, total_amount,
                      discount_amount, net_amount, paid_amount,
                      balance_amount, payment_status, status,
                      patient_id::text, opd_registration_id::text)
       FROM public.billing WHERE bill_number = 'UPG-BILL-0001')
);

INSERT INTO public.hims_upgrade_snapshot (phase, metric, value)
VALUES (
    :'phase', 'visit:eeeeeeee-0000-4000-8000-000000000031',
    (SELECT concat_ws('|', consultation_fee, payment_amount, paid_amount,
                      balance_amount, payment_status, status, patient_id::text)
       FROM public.opd_registrations
      WHERE id = 'eeeeeeee-0000-4000-8000-000000000031')
);

-- Referential integrity of the synthetic graph.
INSERT INTO public.hims_upgrade_snapshot (phase, metric, value)
SELECT :'phase', 'fk:patients->opd_registrations', count(*)::text
  FROM public.opd_registrations o
  JOIN public.patients p ON p.id = o.patient_id
 WHERE o.id = 'eeeeeeee-0000-4000-8000-000000000031';

INSERT INTO public.hims_upgrade_snapshot (phase, metric, value)
SELECT :'phase', 'fk:billing->opd_registrations', count(*)::text
  FROM public.billing b
  JOIN public.opd_registrations o ON o.id = b.opd_registration_id
 WHERE b.id = 'eeeeeeee-0000-4000-8000-000000000041';

INSERT INTO public.hims_upgrade_snapshot (phase, metric, value)
SELECT :'phase', 'fk:billing_items->billing', count(*)::text
  FROM public.billing_items i
  JOIN public.billing b ON b.id = i.bill_id
 WHERE i.id = 'eeeeeeee-0000-4000-8000-000000000051';

INSERT INTO public.hims_upgrade_snapshot (phase, metric, value)
SELECT :'phase', 'fk:payment_logs->billing', count(*)::text
  FROM public.payment_logs l
  JOIN public.billing b ON b.id = l.bill_id
 WHERE l.id = 'eeeeeeee-0000-4000-8000-000000000061';

-- Per-object preservation (additions are allowed; removals are not).
INSERT INTO public.hims_upgrade_snapshot (phase, metric, value)
SELECT :'phase', 'col:' || table_name || '.' || column_name, 'present'
  FROM information_schema.columns
 WHERE table_schema = 'public'
   AND table_name IN ('patients', 'opd_registrations', 'billing',
                      'billing_items', 'payment_logs', 'users');

INSERT INTO public.hims_upgrade_snapshot (phase, metric, value)
SELECT :'phase', 'policy:' || tablename || '.' || policyname, 'present'
  FROM pg_policies
 WHERE schemaname = 'public'
   AND tablename IN ('patients', 'opd_registrations', 'billing',
                     'billing_items', 'payment_logs', 'users');

INSERT INTO public.hims_upgrade_snapshot (phase, metric, value)
SELECT :'phase', 'trigger:' || c.relname || '.' || t.tgname, 'present'
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public' AND NOT t.tgisinternal
   AND c.relname IN ('patients', 'opd_registrations', 'billing',
                     'billing_items', 'payment_logs');

INSERT INTO public.hims_upgrade_snapshot (phase, metric, value)
SELECT :'phase', 'constraint:' || c.relname || '.' || k.conname, 'present'
  FROM pg_constraint k
  JOIN pg_class c ON c.oid = k.conrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'public' AND k.contype IN ('p', 'f', 'u')
   AND c.relname IN ('patients', 'opd_registrations', 'billing',
                     'billing_items', 'payment_logs');

-- ----------------------------------------------------------------------
-- Report (assert only)
-- ----------------------------------------------------------------------
\if :is_assert
SELECT
    s.metric,
    s.value AS pre_upgrade,
    a.value AS post_upgrade
  FROM public.hims_upgrade_snapshot s
  LEFT JOIN public.hims_upgrade_snapshot a
    ON a.metric = s.metric AND a.phase = 'assert'
 WHERE s.phase = 'seed'
   AND (a.metric IS NULL OR s.value IS DISTINCT FROM a.value)
 ORDER BY s.metric;

SELECT CASE
    WHEN count(*) FILTER (
             WHERE a.metric IS NULL OR s.value IS DISTINCT FROM a.value
         ) = 0
        THEN format('PRESERVED: all %s pre-upgrade facts unchanged',
                    count(*))
    ELSE format('%s of %s PRE-UPGRADE FACTS LOST OR CHANGED',
                count(*) FILTER (
                    WHERE a.metric IS NULL OR s.value IS DISTINCT FROM a.value
                ),
                count(*))
END AS preservation_result
  FROM public.hims_upgrade_snapshot s
  LEFT JOIN public.hims_upgrade_snapshot a
    ON a.metric = s.metric AND a.phase = 'assert'
 WHERE s.phase = 'seed';

-- The post-upgrade objects must now exist, and the backfill must be correct.
SELECT
    (to_regclass('public.hims_change_log') IS NOT NULL) AS has_change_log,
    (to_regclass('public.hims_operation_receipts') IS NOT NULL) AS has_receipts,
    EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.proname = 'hims_apply_opd_payment'
    ) AS has_rpc,
    (SELECT count(*) FROM public.billing_items i
       JOIN public.billing b ON b.id = i.bill_id
      WHERE i.hospital_id IS DISTINCT FROM b.hospital_id) AS child_tenant_mismatches,
    (SELECT count(*) FROM public.payment_logs l
       JOIN public.billing b ON b.id = l.bill_id
      WHERE l.hospital_id IS DISTINCT FROM b.hospital_id) AS payment_tenant_mismatches;
\endif

\if :is_seed
SELECT metric, value FROM public.hims_upgrade_snapshot
 WHERE phase = 'seed' ORDER BY metric;
\endif

-- ----------------------------------------------------------------------
-- Functional check: the upgraded database pays a PRE-EXISTING visit through
-- the new atomic endpoint.
-- ----------------------------------------------------------------------
\if :is_functional
-- The seeded admin's auth subject is random per reset, so resolve it here.
SELECT set_config(
    'request.jwt.claims',
    (SELECT '{"sub":"' || u.auth_id::text || '"}'
       FROM public.users u
      WHERE u.auth_id IS NOT NULL AND u.role = 'admin'
      LIMIT 1),
    false
);

SET ROLE authenticated;

SELECT public.hims_apply_opd_payment(
    'ffffffff-0000-4000-8000-0000000000f1', 'e2e-upgrade-device',
    'eeeeeeee-0000-4000-8000-000000000032', 'eeeeeeee-0000-4000-8000-000000000021',
    300.00, 0, 300.00, 'cash',
    'ffffffff-0000-4000-8000-0000000000b1', 'ffffffff-0000-4000-8000-0000000000c1',
    'UPG-BILL-0002', 'ffffffff-0000-4000-8000-0000000000d1', 'ffffffff-0000-4000-8000-0000000000e1'
) ->> 'status' AS upgraded_visit_payment \gset

RESET ROLE;

SELECT
    :'upgraded_visit_payment' = 'applied' AS upgraded_visit_paid,
    (SELECT count(*) FROM public.billing
      WHERE opd_registration_id = 'eeeeeeee-0000-4000-8000-000000000032') AS bills,
    (SELECT count(*) FROM public.payment_logs pl
       JOIN public.billing b ON b.id = pl.bill_id
      WHERE b.opd_registration_id = 'eeeeeeee-0000-4000-8000-000000000032') AS payments,
    (SELECT paid_amount FROM public.billing
      WHERE opd_registration_id = 'eeeeeeee-0000-4000-8000-000000000032') AS collected;
\endif
