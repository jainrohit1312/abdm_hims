-- ======================================================================
-- Isolated verification (scenario 4): concurrent retries of the SAME
-- accounting operation must not create a duplicate collection.
-- ----------------------------------------------------------------------
-- Uses two genuinely concurrent Postgres sessions (the second over `dblink`)
-- so the receipt-claim race is real, not simulated:
--
--   * session A starts the operation as `authenticated`;
--   * the main session issues the same operation id while A is still running;
--   * exactly one side reports `applied`, the other `replayed`, and there is
--     exactly one receipt, one bill and one payment log.
--
-- Run as the local superuser (dblink requires it):
--
--   docker exec -i supabase_db_abdm_hims psql -U supabase_admin -d postgres ^
--       -v ON_ERROR_STOP=1 -f - ^
--       < supabase/verify_opd_payment_concurrent.sql
--
-- LOCAL ISOLATED DATABASE ONLY. Rows are synthetic and cleaned up at the end.
-- ======================================================================

\set ON_ERROR_STOP on
\set QUIET on

SET search_path = public, extensions;

-- dblink is only needed for this two-session test; it is installed in the
-- throwaway local database, never in production.
CREATE EXTENSION IF NOT EXISTS dblink;

-- ----------------------------------------------------------------------
-- Fixtures + pre-run cleanup (so the script is repeatable)
-- ----------------------------------------------------------------------
DO $setup$
DECLARE
    v_op   UUID := 'cccccccc-0000-4000-8000-0000000000c4';
    v_opd  UUID := 'aaaaaaaa-0000-4000-8000-00000000004b';
BEGIN
    DELETE FROM public.payment_logs
     WHERE bill_id IN (SELECT id FROM public.billing WHERE opd_registration_id = v_opd);
    DELETE FROM public.billing_items
     WHERE bill_id IN (SELECT id FROM public.billing WHERE opd_registration_id = v_opd);
    DELETE FROM public.billing_audit
     WHERE bill_id IN (SELECT id FROM public.billing WHERE opd_registration_id = v_opd);
    DELETE FROM public.billing WHERE opd_registration_id = v_opd;
    DELETE FROM public.hims_operation_receipts WHERE operation_id = v_op;
    DELETE FROM public.opd_registrations WHERE id = v_opd;

    INSERT INTO auth.users (
        instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
        confirmation_token, recovery_token, email_change_token_new, email_change,
        is_super_admin
    ) VALUES (
        '00000000-0000-0000-0000-000000000000',
        'cccccccc-0000-4000-8000-0000000000c1', 'authenticated', 'authenticated',
        'e2e.hosp.c@example.test', extensions.crypt('password123', extensions.gen_salt('bf', 10)), now(),
        '{"provider":"email","providers":["email"]}', '{}', now(), now(),
        '', '', '', '', false
    ) ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.hospitals (id, code, name)
    VALUES ('cccccccc-0000-4000-8000-000000000001', 'E2E-C', 'E2E Hospital C')
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.users (id, auth_id, hospital_id, first_name, last_name, email, role, is_active)
    VALUES ('cccccccc-0000-4000-8000-000000000011', 'cccccccc-0000-4000-8000-0000000000c1',
            'cccccccc-0000-4000-8000-000000000001', 'Doc', 'C', 'e2e.hosp.c@example.test',
            'admin', true)
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO public.patients (id, hospital_id, uhid, first_name, last_name)
    VALUES ('cccccccc-0000-4000-8000-000000000021', 'cccccccc-0000-4000-8000-000000000001',
            'E2E-C-UHID-0001', 'Synthetic', 'Gamma')
    ON CONFLICT (id) DO NOTHING;

    -- Upsert (not insert): the local soft-delete trigger turns DELETE into a
    -- `deleted_at` update, so a row left by a failed run must be reset here.
    INSERT INTO public.opd_registrations (
        id, hospital_id, patient_id, visit_date, consultation_fee,
        payment_amount, paid_amount, balance_amount, payment_status, status, created_by
    ) VALUES (
        v_opd, 'cccccccc-0000-4000-8000-000000000001',
        'cccccccc-0000-4000-8000-000000000021', CURRENT_DATE, 500.00, 500.00, 0, 500.00,
        'unpaid', 'completed', 'cccccccc-0000-4000-8000-000000000011'
    )
    ON CONFLICT (id) DO UPDATE SET
        consultation_fee = EXCLUDED.consultation_fee,
        payment_amount   = EXCLUDED.payment_amount,
        paid_amount      = 0,
        balance_amount   = EXCLUDED.balance_amount,
        payment_status   = 'unpaid',
        payment_mode     = NULL,
        status           = 'completed',
        deleted_at       = NULL;
END
$setup$;

-- ----------------------------------------------------------------------
-- Session A: start the operation and leave it in flight.
-- ----------------------------------------------------------------------
SELECT dblink_connect('hims_conc', 'dbname=postgres user=supabase_admin');
SELECT dblink_exec('hims_conc', 'SET ROLE authenticated');
SELECT dblink_exec(
    'hims_conc',
    'SET request.jwt.claims = ''{"sub":"cccccccc-0000-4000-8000-0000000000c1"}'''
);

SELECT dblink_send_query('hims_conc', $callA$
    SELECT public.hims_apply_opd_payment(
        'cccccccc-0000-4000-8000-0000000000c4', 'e2e-device-conc',
        'aaaaaaaa-0000-4000-8000-00000000004b', 'cccccccc-0000-4000-8000-000000000021',
        500.00, 0, 500.00, 'cash',
        'dddddddd-0000-4000-8000-0000000000c4', 'dddddddd-0000-4000-8000-0000000000f4',
        'OPD-E2E-CONC', 'dddddddd-0000-4000-8000-0000000000b4', 'dddddddd-0000-4000-8000-0000000000c9'
    ) ->> 'status' AS a_status
$callA$);

-- Let A reach the receipt claim before the main session retries.
SELECT pg_sleep(1.0);

-- ----------------------------------------------------------------------
-- Main session: the concurrent retry with the SAME operation id.
-- ----------------------------------------------------------------------
SET ROLE authenticated;
SET request.jwt.claims = '{"sub":"cccccccc-0000-4000-8000-0000000000c1"}';

SELECT public.hims_apply_opd_payment(
    'cccccccc-0000-4000-8000-0000000000c4', 'e2e-device-conc',
    'aaaaaaaa-0000-4000-8000-00000000004b', 'cccccccc-0000-4000-8000-000000000021',
    500.00, 0, 500.00, 'cash',
    'dddddddd-0000-4000-8000-0000000000c4', 'dddddddd-0000-4000-8000-0000000000f4',
    'OPD-E2E-CONC', 'dddddddd-0000-4000-8000-0000000000b4', 'dddddddd-0000-4000-8000-0000000000c9'
) ->> 'status' AS main_status \gset

RESET ROLE;

SELECT r.a_status FROM dblink_get_result('hims_conc') AS r(a_status TEXT) \gset

SELECT dblink_disconnect('hims_conc');

-- ----------------------------------------------------------------------
-- Assertions
-- ----------------------------------------------------------------------
CREATE TEMP TABLE _conc_verify (label TEXT PRIMARY KEY, ok BOOLEAN, detail TEXT);

INSERT INTO _conc_verify (label, ok, detail)
VALUES (
    'exactly one applied and one replayed',
    (:'main_status' = 'applied' AND :'a_status' = 'replayed')
        OR (:'main_status' = 'replayed' AND :'a_status' = 'applied'),
    format('main=%s sessionA=%s', :'main_status', :'a_status')
);

INSERT INTO _conc_verify (label, ok, detail)
SELECT 'exactly one receipt', count(*) = 1, count(*)::text
  FROM public.hims_operation_receipts
 WHERE operation_id = 'cccccccc-0000-4000-8000-0000000000c4';

INSERT INTO _conc_verify (label, ok, detail)
SELECT 'exactly one bill', count(*) = 1, count(*)::text
  FROM public.billing
 WHERE opd_registration_id = 'aaaaaaaa-0000-4000-8000-00000000004b';

INSERT INTO _conc_verify (label, ok, detail)
SELECT 'exactly one billing item', count(*) = 1, count(*)::text
  FROM public.billing_items bi
  JOIN public.billing b ON b.id = bi.bill_id
 WHERE b.opd_registration_id = 'aaaaaaaa-0000-4000-8000-00000000004b';

INSERT INTO _conc_verify (label, ok, detail)
SELECT 'exactly one payment log', count(*) = 1, count(*)::text
  FROM public.payment_logs pl
  JOIN public.billing b ON b.id = pl.bill_id
 WHERE b.opd_registration_id = 'aaaaaaaa-0000-4000-8000-00000000004b';

INSERT INTO _conc_verify (label, ok, detail)
SELECT 'collected exactly once', coalesce(sum(pl.amount_paid), 0) = 500.00,
       coalesce(sum(pl.amount_paid), 0)::text
  FROM public.payment_logs pl
  JOIN public.billing b ON b.id = pl.bill_id
 WHERE b.opd_registration_id = 'aaaaaaaa-0000-4000-8000-00000000004b';

INSERT INTO _conc_verify (label, ok, detail)
SELECT 'billed paid total matches collection',
       (SELECT paid_amount FROM public.billing
         WHERE opd_registration_id = 'aaaaaaaa-0000-4000-8000-00000000004b') = 500.00,
       (SELECT paid_amount::text FROM public.billing
         WHERE opd_registration_id = 'aaaaaaaa-0000-4000-8000-00000000004b');

-- ----------------------------------------------------------------------
-- Report
-- ----------------------------------------------------------------------
SELECT :'main_status' AS main_session, :'a_status' AS concurrent_session;

SELECT ok, count(*) AS checks, string_agg(label, ', ' ORDER BY label) AS labels
  FROM _conc_verify GROUP BY ok ORDER BY ok;

SELECT label, detail FROM _conc_verify WHERE NOT ok ORDER BY label;

SELECT CASE
    WHEN count(*) FILTER (WHERE NOT ok) = 0
        THEN format('ALL %s CONCURRENCY CHECKS PASSED', count(*))
    ELSE format('%s of %s CONCURRENCY CHECKS FAILED',
                count(*) FILTER (WHERE NOT ok), count(*))
END AS result
  FROM _conc_verify;

-- ----------------------------------------------------------------------
-- Cleanup (this script commits, so it removes its own synthetic rows)
-- ----------------------------------------------------------------------
DO $cleanup$
DECLARE
    v_opd UUID := 'aaaaaaaa-0000-4000-8000-00000000004b';
BEGIN
    DELETE FROM public.payment_logs
     WHERE bill_id IN (SELECT id FROM public.billing WHERE opd_registration_id = v_opd);
    DELETE FROM public.billing_items
     WHERE bill_id IN (SELECT id FROM public.billing WHERE opd_registration_id = v_opd);
    DELETE FROM public.billing_audit
     WHERE bill_id IN (SELECT id FROM public.billing WHERE opd_registration_id = v_opd);
    DELETE FROM public.billing WHERE opd_registration_id = v_opd;
    DELETE FROM public.hims_operation_receipts
     WHERE operation_id = 'cccccccc-0000-4000-8000-0000000000c4';
    DELETE FROM public.opd_registrations WHERE id = v_opd;
END
$cleanup$;
