-- ======================================================================
-- Isolated verification: atomic OPD payment operation
-- ----------------------------------------------------------------------
-- Runs against the LOCAL isolated Supabase Postgres ONLY. Every row is
-- synthetic and the whole script is rolled back at the end, so it is
-- repeatable and leaves no residue.
--
--   docker exec -i supabase_db_abdm_hims psql -U postgres -d postgres ^
--       -v ON_ERROR_STOP=1 -f - < supabase/verify_opd_payment_atomic.sql
--
-- Scenarios covered here:
--   1  successful accounting operation
--   2  forced failure halfway through  -> no partial accounting writes
--   2b the retry after that rollback succeeds (no orphan receipt)
--   3  server committed, response lost -> replay returns the original result
--   5  same operation id, different amounts -> explicit conflict
--   6  invalid cross-hospital references / invalid amounts -> nothing written
--   7  supported partial payment, and a second collection is refused
--   8  no duplicate revenue / payment records
-- (4 = concurrent retries, needs real concurrent connections:
--      supabase/verify_opd_payment_concurrent.sql)
-- ======================================================================

\set ON_ERROR_STOP on
\set QUIET on

BEGIN;

-- `extensions` is where Supabase installs pgcrypto (crypt / gen_salt).
SET search_path = pg_temp, public, extensions;

CREATE TEMP TABLE _hims_verify (
    label  TEXT PRIMARY KEY,
    ok     BOOLEAN NOT NULL,
    detail TEXT
) ON COMMIT DROP;

-- SECURITY DEFINER so the assertion helpers can write the (postgres-owned)
-- temp table while the session is switched to `authenticated`.
CREATE OR REPLACE FUNCTION pg_temp.hv(
    label TEXT, ok BOOLEAN, detail TEXT DEFAULT NULL
) RETURNS VOID LANGUAGE sql SECURITY DEFINER AS $hv$
    INSERT INTO pg_temp._hims_verify (label, ok, detail)
    VALUES (label, ok, detail)
    ON CONFLICT (label) DO UPDATE SET ok = EXCLUDED.ok, detail = EXCLUDED.detail;
$hv$;

CREATE OR REPLACE FUNCTION pg_temp.hv_eq(
    label TEXT, actual ANYELEMENT, expected ANYELEMENT
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER AS $hv$
BEGIN
    PERFORM pg_temp.hv(
        label,
        actual IS NOT DISTINCT FROM expected,
        format('actual=%s expected=%s', actual, expected)
    );
END;
$hv$;

-- ----------------------------------------------------------------------
-- Fixtures (synthetic, fixed ids)
-- ----------------------------------------------------------------------
INSERT INTO auth.users (
    instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    confirmation_token, recovery_token, email_change_token_new, email_change,
    is_super_admin
) VALUES
    ('00000000-0000-0000-0000-000000000000',
     'aaaaaaaa-0000-4000-8000-0000000000a1', 'authenticated', 'authenticated',
     'e2e.hosp.a@example.test', crypt('password123', gen_salt('bf', 10)), now(),
     '{"provider":"email","providers":["email"]}', '{}', now(), now(),
     '', '', '', '', false),
    ('00000000-0000-0000-0000-000000000000',
     'bbbbbbbb-0000-4000-8000-0000000000b1', 'authenticated', 'authenticated',
     'e2e.hosp.b@example.test', crypt('password123', gen_salt('bf', 10)), now(),
     '{"provider":"email","providers":["email"]}', '{}', now(), now(),
     '', '', '', '', false)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.hospitals (id, code, name) VALUES
    ('aaaaaaaa-0000-4000-8000-000000000001', 'E2E-A', 'E2E Hospital A'),
    ('bbbbbbbb-0000-4000-8000-000000000002', 'E2E-B', 'E2E Hospital B')
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.users (id, auth_id, hospital_id, first_name, last_name, email, role, is_active) VALUES
    ('aaaaaaaa-0000-4000-8000-000000000011', 'aaaaaaaa-0000-4000-8000-0000000000a1',
     'aaaaaaaa-0000-4000-8000-000000000001', 'Doc', 'A', 'e2e.hosp.a@example.test', 'admin', true),
    ('bbbbbbbb-0000-4000-8000-000000000012', 'bbbbbbbb-0000-4000-8000-0000000000b1',
     'bbbbbbbb-0000-4000-8000-000000000002', 'Doc', 'B', 'e2e.hosp.b@example.test', 'admin', true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.patients (id, hospital_id, uhid, first_name, last_name) VALUES
    ('aaaaaaaa-0000-4000-8000-000000000021', 'aaaaaaaa-0000-4000-8000-000000000001',
     'E2E-A-UHID-0001', 'Synthetic', 'Alpha'),
    ('bbbbbbbb-0000-4000-8000-000000000022', 'bbbbbbbb-0000-4000-8000-000000000002',
     'E2E-B-UHID-0001', 'Synthetic', 'Beta')
ON CONFLICT (id) DO NOTHING;

-- opd_1 / opd_2 / opd_3 belong to hospital A; opd_B to hospital B.
INSERT INTO public.opd_registrations (
    id, hospital_id, patient_id, visit_date, consultation_fee,
    payment_amount, paid_amount, balance_amount, payment_status, status, created_by
) VALUES
    ('aaaaaaaa-0000-4000-8000-000000000031', 'aaaaaaaa-0000-4000-8000-000000000001',
     'aaaaaaaa-0000-4000-8000-000000000021', CURRENT_DATE, 500.00, 500.00, 0, 500.00,
     'unpaid', 'completed', 'aaaaaaaa-0000-4000-8000-000000000011'),
    ('aaaaaaaa-0000-4000-8000-000000000033', 'aaaaaaaa-0000-4000-8000-000000000001',
     'aaaaaaaa-0000-4000-8000-000000000021', CURRENT_DATE, 300.00, 300.00, 0, 300.00,
     'unpaid', 'completed', 'aaaaaaaa-0000-4000-8000-000000000011'),
    ('bbbbbbbb-0000-4000-8000-000000000032', 'bbbbbbbb-0000-4000-8000-000000000002',
     'bbbbbbbb-0000-4000-8000-000000000022', CURRENT_DATE, 400.00, 400.00, 0, 400.00,
     'unpaid', 'completed', 'bbbbbbbb-0000-4000-8000-000000000012')
ON CONFLICT (id) DO NOTHING;

-- ======================================================================
-- Scenario 1 — successful accounting operation (as an authenticated client)
-- ======================================================================
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"aaaaaaaa-0000-4000-8000-0000000000a1"}';

SELECT pg_temp.hv_eq(
    'scenario1 status applied',
    (public.hims_apply_opd_payment(
        'cccccccc-0000-4000-8000-000000000001', 'e2e-device-1',
        'aaaaaaaa-0000-4000-8000-000000000031', 'aaaaaaaa-0000-4000-8000-000000000021',
        500.00, 0, 500.00, 'cash',
        'dddddddd-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-0000000000f1',
        'OPD-E2E-0001', 'dddddddd-0000-4000-8000-0000000000b1', 'dddddddd-0000-4000-8000-0000000000c1'
    ) ->> 'status'),
    'applied'
);

RESET ROLE;

SELECT pg_temp.hv_eq('scenario1 billing rows', count(*), 1::bigint)
  FROM public.billing
 WHERE opd_registration_id = 'aaaaaaaa-0000-4000-8000-000000000031';

SELECT pg_temp.hv_eq('scenario1 billing paid', paid_amount, 500.00::numeric)
  FROM public.billing
 WHERE opd_registration_id = 'aaaaaaaa-0000-4000-8000-000000000031';

SELECT pg_temp.hv_eq('scenario1 visit paid', payment_status, 'paid')
  FROM public.opd_registrations
 WHERE id = 'aaaaaaaa-0000-4000-8000-000000000031';

SELECT pg_temp.hv_eq('scenario1 item rows', count(*), 1::bigint)
  FROM public.billing_items bi
  JOIN public.billing b ON b.id = bi.bill_id
 WHERE b.opd_registration_id = 'aaaaaaaa-0000-4000-8000-000000000031';

SELECT pg_temp.hv_eq('scenario1 payment log rows', count(*), 1::bigint)
  FROM public.payment_logs pl
  JOIN public.billing b ON b.id = pl.bill_id
 WHERE b.opd_registration_id = 'aaaaaaaa-0000-4000-8000-000000000031';

SELECT pg_temp.hv_eq('scenario1 payment log attributed', pl.recorded_by, 'aaaaaaaa-0000-4000-8000-000000000011'::uuid)
  FROM public.payment_logs pl
  JOIN public.billing b ON b.id = pl.bill_id
 WHERE b.opd_registration_id = 'aaaaaaaa-0000-4000-8000-000000000031';

SELECT pg_temp.hv_eq('scenario1 audit trail present', count(*), 2::bigint)
  FROM public.billing_audit ba
  JOIN public.billing b ON b.id = ba.bill_id
 WHERE b.opd_registration_id = 'aaaaaaaa-0000-4000-8000-000000000031';

SELECT pg_temp.hv_eq('scenario1 receipt committed', count(*), 1::bigint)
  FROM public.hims_operation_receipts
 WHERE operation_id = 'cccccccc-0000-4000-8000-000000000001';

-- ======================================================================
-- Scenario 3 — server committed, response lost, then retry
-- ======================================================================
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"aaaaaaaa-0000-4000-8000-0000000000a1"}';

SELECT pg_temp.hv_eq(
    'scenario3 replay status',
    (public.hims_apply_opd_payment(
        'cccccccc-0000-4000-8000-000000000001', 'e2e-device-1',
        'aaaaaaaa-0000-4000-8000-000000000031', 'aaaaaaaa-0000-4000-8000-000000000021',
        500.00, 0, 500.00, 'cash',
        'dddddddd-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-0000000000f1',
        'OPD-E2E-0001', 'dddddddd-0000-4000-8000-0000000000b1', 'dddddddd-0000-4000-8000-0000000000c1'
    ) ->> 'status'),
    'replayed'
);

SELECT pg_temp.hv_eq(
    'scenario3 replay returns original amounts',
    (public.hims_apply_opd_payment(
        'cccccccc-0000-4000-8000-000000000001', 'e2e-device-1',
        'aaaaaaaa-0000-4000-8000-000000000031', 'aaaaaaaa-0000-4000-8000-000000000021',
        500.00, 0, 500.00, 'cash',
        'dddddddd-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-0000000000f1',
        'OPD-E2E-0001', 'dddddddd-0000-4000-8000-0000000000b1', 'dddddddd-0000-4000-8000-0000000000c1'
    ) ->> 'paid_amount')::numeric,
    500.00::numeric
);

RESET ROLE;

SELECT pg_temp.hv_eq('scenario3 no extra payment log', count(*), 1::bigint)
  FROM public.payment_logs pl
  JOIN public.billing b ON b.id = pl.bill_id
 WHERE b.opd_registration_id = 'aaaaaaaa-0000-4000-8000-000000000031';

SELECT pg_temp.hv_eq('scenario3 no extra receipt', count(*), 1::bigint)
  FROM public.hims_operation_receipts
 WHERE operation_id = 'cccccccc-0000-4000-8000-000000000001';

SELECT pg_temp.hv_eq('scenario3 no extra audit row', count(*), 2::bigint)
  FROM public.billing_audit ba
  JOIN public.billing b ON b.id = ba.bill_id
 WHERE b.opd_registration_id = 'aaaaaaaa-0000-4000-8000-000000000031';

-- ======================================================================
-- Scenario 5 — same operation id, DIFFERENT amounts -> explicit conflict
-- ======================================================================
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"aaaaaaaa-0000-4000-8000-0000000000a1"}';

DO $sc5$
BEGIN
    PERFORM public.hims_apply_opd_payment(
        'cccccccc-0000-4000-8000-000000000001', 'e2e-device-1',
        'aaaaaaaa-0000-4000-8000-000000000031', 'aaaaaaaa-0000-4000-8000-000000000021',
        500.00, 0, 123.45, 'cash',
        'dddddddd-0000-4000-8000-000000000001', 'dddddddd-0000-4000-8000-0000000000f1',
        'OPD-E2E-0001', 'dddddddd-0000-4000-8000-0000000000b1', 'dddddddd-0000-4000-8000-0000000000c1'
    );
    PERFORM pg_temp.hv('scenario5 conflict raised', false, 'no exception raised');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.hv(
        'scenario5 conflict raised',
        position('hims_opd_payment_conflict' in SQLERRM) > 0,
        SQLERRM
    );
END;
$sc5$;

RESET ROLE;

SELECT pg_temp.hv_eq('scenario5 collection unchanged', paid_amount, 500.00::numeric)
  FROM public.billing
 WHERE opd_registration_id = 'aaaaaaaa-0000-4000-8000-000000000031';

-- ======================================================================
-- Scenario 6 — invalid cross-hospital references and invalid amounts
-- ======================================================================
-- 6a: hospital A user paying hospital B's visit.
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"aaaaaaaa-0000-4000-8000-0000000000a1"}';

DO $sc6a$
BEGIN
    PERFORM public.hims_apply_opd_payment(
        'cccccccc-0000-4000-8000-000000000006', 'e2e-device-1',
        'bbbbbbbb-0000-4000-8000-000000000032', 'bbbbbbbb-0000-4000-8000-000000000022',
        400.00, 0, 400.00, 'cash',
        'dddddddd-0000-4000-8000-000000000006', 'dddddddd-0000-4000-8000-0000000000f6',
        'OPD-E2E-0006', 'dddddddd-0000-4000-8000-0000000000b6', 'dddddddd-0000-4000-8000-0000000000c6'
    );
    PERFORM pg_temp.hv('scenario6a cross-hospital forbidden', false, 'no exception raised');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.hv(
        'scenario6a cross-hospital forbidden',
        position('hims_opd_payment_forbidden' in SQLERRM) > 0,
        SQLERRM
    );
END;
$sc6a$;

-- 6b: own visit, but the patient belongs to another hospital.
DO $sc6b$
BEGIN
    PERFORM public.hims_apply_opd_payment(
        'cccccccc-0000-4000-8000-000000000016', 'e2e-device-1',
        'aaaaaaaa-0000-4000-8000-000000000033', 'bbbbbbbb-0000-4000-8000-000000000022',
        300.00, 0, 300.00, 'cash',
        'dddddddd-0000-4000-8000-000000000016', 'dddddddd-0000-4000-8000-0000000000f6',
        'OPD-E2E-0016', 'dddddddd-0000-4000-8000-0000000000b6', 'dddddddd-0000-4000-8000-0000000000c6'
    );
    PERFORM pg_temp.hv('scenario6b foreign patient rejected', false, 'no exception raised');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.hv(
        'scenario6b foreign patient rejected',
        position('hims_opd_payment_' in SQLERRM) > 0,
        SQLERRM
    );
END;
$sc6b$;

-- 6c: unknown visit -> retryable (never a permanent rejection).
DO $sc6c$
BEGIN
    PERFORM public.hims_apply_opd_payment(
        'cccccccc-0000-4000-8000-000000000026', 'e2e-device-1',
        'aaaaaaaa-0000-4000-8000-0000000000ff', 'aaaaaaaa-0000-4000-8000-000000000021',
        500.00, 0, 500.00, 'cash',
        'dddddddd-0000-4000-8000-000000000026', 'dddddddd-0000-4000-8000-0000000000f6',
        'OPD-E2E-0026', 'dddddddd-0000-4000-8000-0000000000b6', 'dddddddd-0000-4000-8000-0000000000c6'
    );
    PERFORM pg_temp.hv('scenario6c unknown visit is retryable', false, 'no exception raised');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.hv(
        'scenario6c unknown visit is retryable',
        position('hims_opd_payment_retry' in SQLERRM) > 0,
        SQLERRM
    );
END;
$sc6c$;

-- 6d: payment above the net payable.
DO $sc6d$
BEGIN
    PERFORM public.hims_apply_opd_payment(
        'cccccccc-0000-4000-8000-000000000036', 'e2e-device-1',
        'aaaaaaaa-0000-4000-8000-000000000033', 'aaaaaaaa-0000-4000-8000-000000000021',
        300.00, 0, 301.00, 'cash',
        'dddddddd-0000-4000-8000-000000000036', 'dddddddd-0000-4000-8000-0000000000f6',
        'OPD-E2E-0036', 'dddddddd-0000-4000-8000-0000000000b6', 'dddddddd-0000-4000-8000-0000000000c6'
    );
    PERFORM pg_temp.hv('scenario6d overpayment rejected', false, 'no exception raised');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.hv(
        'scenario6d overpayment rejected',
        position('hims_opd_payment_invalid' in SQLERRM) > 0,
        SQLERRM
    );
END;
$sc6d$;

-- 6e: discount above the gross fee.
DO $sc6e$
BEGIN
    PERFORM public.hims_apply_opd_payment(
        'cccccccc-0000-4000-8000-000000000046', 'e2e-device-1',
        'aaaaaaaa-0000-4000-8000-000000000033', 'aaaaaaaa-0000-4000-8000-000000000021',
        300.00, 301.00, 0, 'cash',
        'dddddddd-0000-4000-8000-000000000046', 'dddddddd-0000-4000-8000-0000000000f6',
        'OPD-E2E-0046', 'dddddddd-0000-4000-8000-0000000000b6', 'dddddddd-0000-4000-8000-0000000000c6'
    );
    PERFORM pg_temp.hv('scenario6e over-discount rejected', false, 'no exception raised');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.hv(
        'scenario6e over-discount rejected',
        position('hims_opd_payment_invalid' in SQLERRM) > 0,
        SQLERRM
    );
END;
$sc6e$;

-- 6f: consultation fee mismatch between client and server.
DO $sc6f$
BEGIN
    PERFORM public.hims_apply_opd_payment(
        'cccccccc-0000-4000-8000-000000000056', 'e2e-device-1',
        'aaaaaaaa-0000-4000-8000-000000000033', 'aaaaaaaa-0000-4000-8000-000000000021',
        999.00, 0, 999.00, 'cash',
        'dddddddd-0000-4000-8000-000000000056', 'dddddddd-0000-4000-8000-0000000000f6',
        'OPD-E2E-0056', 'dddddddd-0000-4000-8000-0000000000b6', 'dddddddd-0000-4000-8000-0000000000c6'
    );
    PERFORM pg_temp.hv('scenario6f fee mismatch is a conflict', false, 'no exception raised');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.hv(
        'scenario6f fee mismatch is a conflict',
        position('hims_opd_payment_conflict' in SQLERRM) > 0,
        SQLERRM
    );
END;
$sc6f$;

-- 6g: hospital B may not read hospital A's receipt (RLS).
SET LOCAL request.jwt.claims = '{"sub":"bbbbbbbb-0000-4000-8000-0000000000b1"}';
SELECT pg_temp.hv_eq('scenario6g receipt tenant isolation', count(*), 0::bigint)
  FROM public.hims_operation_receipts
 WHERE operation_id = 'cccccccc-0000-4000-8000-000000000001';

-- 6h: an unauthenticated (anon) client cannot execute the money operation.
RESET ROLE;
SET LOCAL ROLE anon;
SET LOCAL request.jwt.claims = '{}';

DO $sc6h$
BEGIN
    PERFORM public.hims_apply_opd_payment(
        'cccccccc-0000-4000-8000-000000000066', 'e2e-device-1',
        'aaaaaaaa-0000-4000-8000-000000000033', 'aaaaaaaa-0000-4000-8000-000000000021',
        300.00, 0, 300.00, 'cash',
        'dddddddd-0000-4000-8000-000000000066', 'dddddddd-0000-4000-8000-0000000000f6',
        'OPD-E2E-0066', 'dddddddd-0000-4000-8000-0000000000b6', 'dddddddd-0000-4000-8000-0000000000c6'
    );
    PERFORM pg_temp.hv('scenario6h anon cannot execute', false, 'no exception raised');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.hv(
        'scenario6h anon cannot execute',
        position('permission denied' in lower(SQLERRM)) > 0,
        SQLERRM
    );
END;
$sc6h$;

RESET ROLE;

SELECT pg_temp.hv_eq('scenario6 visit 2 untouched', payment_status, 'unpaid')
  FROM public.opd_registrations
 WHERE id = 'aaaaaaaa-0000-4000-8000-000000000033';

SELECT pg_temp.hv_eq('scenario6 visit 1 unchanged', paid_amount, 500.00::numeric)
  FROM public.opd_registrations
 WHERE id = 'aaaaaaaa-0000-4000-8000-000000000031';

SELECT pg_temp.hv_eq('scenario6 no bill for hospital B visit', count(*), 0::bigint)
  FROM public.billing
 WHERE opd_registration_id = 'bbbbbbbb-0000-4000-8000-000000000032';

-- ======================================================================
-- Scenario 2 — forced failure halfway -> no partial accounting writes
-- ======================================================================
CREATE OR REPLACE FUNCTION pg_temp.hv_fail_payment() RETURNS TRIGGER
LANGUAGE plpgsql AS $hv$
BEGIN
    RAISE EXCEPTION 'forced failure halfway through the accounting operation';
END;
$hv$;

CREATE TRIGGER trg_hv_fail_payment
    BEFORE INSERT ON public.payment_logs
    FOR EACH ROW EXECUTE FUNCTION pg_temp.hv_fail_payment();

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"aaaaaaaa-0000-4000-8000-0000000000a1"}';

DO $sc2$
BEGIN
    PERFORM public.hims_apply_opd_payment(
        'cccccccc-0000-4000-8000-000000000002', 'e2e-device-1',
        'aaaaaaaa-0000-4000-8000-000000000033', 'aaaaaaaa-0000-4000-8000-000000000021',
        300.00, 0, 300.00, 'cash',
        'dddddddd-0000-4000-8000-000000000002', 'dddddddd-0000-4000-8000-0000000000f2',
        'OPD-E2E-0002', 'dddddddd-0000-4000-8000-0000000000b2', 'dddddddd-0000-4000-8000-0000000000c2'
    );
    PERFORM pg_temp.hv('scenario2 failure forced', false, 'no exception raised');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.hv('scenario2 failure forced', true, SQLERRM);
END;
$sc2$;

RESET ROLE;

SELECT pg_temp.hv_eq('scenario2 no billing row', count(*), 0::bigint)
  FROM public.billing
 WHERE opd_registration_id = 'aaaaaaaa-0000-4000-8000-000000000033';

SELECT pg_temp.hv_eq('scenario2 no receipt row', count(*), 0::bigint)
  FROM public.hims_operation_receipts
 WHERE operation_id = 'cccccccc-0000-4000-8000-000000000002';

SELECT pg_temp.hv_eq('scenario2 visit still unpaid', payment_status, 'unpaid')
  FROM public.opd_registrations
 WHERE id = 'aaaaaaaa-0000-4000-8000-000000000033';

SELECT pg_temp.hv_eq('scenario2 no payment log row', count(*), 0::bigint)
  FROM public.payment_logs
 WHERE id = 'dddddddd-0000-4000-8000-0000000000c2';

DROP TRIGGER trg_hv_fail_payment ON public.payment_logs;

-- 2b) with the fault removed, the SAME operation id succeeds (proving the
--     rollback left no orphan receipt that would block the retry).
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"aaaaaaaa-0000-4000-8000-0000000000a1"}';

SELECT pg_temp.hv_eq(
    'scenario2b retry after rollback applied',
    (public.hims_apply_opd_payment(
        'cccccccc-0000-4000-8000-000000000002', 'e2e-device-1',
        'aaaaaaaa-0000-4000-8000-000000000033', 'aaaaaaaa-0000-4000-8000-000000000021',
        300.00, 0, 300.00, 'cash',
        'dddddddd-0000-4000-8000-000000000002', 'dddddddd-0000-4000-8000-0000000000f2',
        'OPD-E2E-0002', 'dddddddd-0000-4000-8000-0000000000b2', 'dddddddd-0000-4000-8000-0000000000c2'
    ) ->> 'status'),
    'applied'
);

RESET ROLE;

SELECT pg_temp.hv_eq('scenario2b exactly one billing row', count(*), 1::bigint)
  FROM public.billing
 WHERE opd_registration_id = 'aaaaaaaa-0000-4000-8000-000000000033';

-- ======================================================================
-- Scenario 7 — supported partial payment
-- ======================================================================
-- A third visit (fee 300) with a 50 discount, collecting 100 of the 250 net.
INSERT INTO public.opd_registrations (
    id, hospital_id, patient_id, visit_date, consultation_fee,
    payment_amount, paid_amount, balance_amount, payment_status, status, created_by
) VALUES (
    'aaaaaaaa-0000-4000-8000-000000000037', 'aaaaaaaa-0000-4000-8000-000000000001',
    'aaaaaaaa-0000-4000-8000-000000000021', CURRENT_DATE, 300.00, 250.00, 0, 250.00,
    'unpaid', 'completed', 'aaaaaaaa-0000-4000-8000-000000000011'
);

SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"aaaaaaaa-0000-4000-8000-0000000000a1"}';

SELECT pg_temp.hv_eq(
    'scenario7 partial payment status',
    (public.hims_apply_opd_payment(
        'cccccccc-0000-4000-8000-000000000007', 'e2e-device-1',
        'aaaaaaaa-0000-4000-8000-000000000037', 'aaaaaaaa-0000-4000-8000-000000000021',
        300.00, 50.00, 100.00, 'cash',
        'dddddddd-0000-4000-8000-000000000007', 'dddddddd-0000-4000-8000-0000000000f7',
        'OPD-E2E-0007', 'dddddddd-0000-4000-8000-0000000000b7', 'dddddddd-0000-4000-8000-0000000000c7'
    ) ->> 'payment_status'),
    'partially_paid'
);

RESET ROLE;

SELECT pg_temp.hv_eq('scenario7 net is discounted', net_amount, 250.00::numeric)
  FROM public.billing
 WHERE opd_registration_id = 'aaaaaaaa-0000-4000-8000-000000000037';

SELECT pg_temp.hv_eq('scenario7 bill balance carried', balance_amount, 150.00::numeric)
  FROM public.billing
 WHERE opd_registration_id = 'aaaaaaaa-0000-4000-8000-000000000037';

SELECT pg_temp.hv_eq('scenario7 visit balance carried', balance_amount, 150.00::numeric)
  FROM public.opd_registrations
 WHERE id = 'aaaaaaaa-0000-4000-8000-000000000037';

SELECT pg_temp.hv_eq('scenario7 one payment log', count(*), 1::bigint)
  FROM public.payment_logs pl
  JOIN public.billing b ON b.id = pl.bill_id
 WHERE b.opd_registration_id = 'aaaaaaaa-0000-4000-8000-000000000037';

-- A SECOND, different operation against the same visit must not collect again.
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claims = '{"sub":"aaaaaaaa-0000-4000-8000-0000000000a1"}';

DO $sc7b$
BEGIN
    PERFORM public.hims_apply_opd_payment(
        'cccccccc-0000-4000-8000-000000000017', 'e2e-device-2',
        'aaaaaaaa-0000-4000-8000-000000000037', 'aaaaaaaa-0000-4000-8000-000000000021',
        300.00, 50.00, 150.00, 'cash',
        'dddddddd-0000-4000-8000-000000000017', 'dddddddd-0000-4000-8000-0000000000f7',
        'OPD-E2E-0007', 'dddddddd-0000-4000-8000-0000000000b7', 'dddddddd-0000-4000-8000-0000000000c7'
    );
    PERFORM pg_temp.hv('scenario7b second collection blocked', false, 'no exception raised');
EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.hv(
        'scenario7b second collection blocked',
        position('hims_opd_payment_conflict' in SQLERRM) > 0,
        SQLERRM
    );
END;
$sc7b$;

RESET ROLE;

SELECT pg_temp.hv_eq('scenario7b still one payment log', count(*), 1::bigint)
  FROM public.payment_logs pl
  JOIN public.billing b ON b.id = pl.bill_id
 WHERE b.opd_registration_id = 'aaaaaaaa-0000-4000-8000-000000000037';

-- ======================================================================
-- Scenario 8 — no duplicate revenue / payment records overall
-- ======================================================================
SELECT pg_temp.hv_eq(
    'scenario8 one bill per paid visit',
    count(*),
    (SELECT count(DISTINCT opd_registration_id) FROM public.billing
      WHERE hospital_id = 'aaaaaaaa-0000-4000-8000-000000000001')
)
  FROM public.billing
 WHERE hospital_id = 'aaaaaaaa-0000-4000-8000-000000000001';

SELECT pg_temp.hv_eq('scenario8 no orphan billing items', count(*), 0::bigint)
  FROM public.billing_items bi
  LEFT JOIN public.billing b ON b.id = bi.bill_id
 WHERE b.id IS NULL;

SELECT pg_temp.hv_eq('scenario8 no orphan payment logs', count(*), 0::bigint)
  FROM public.payment_logs pl
  LEFT JOIN public.billing b ON b.id = pl.bill_id
 WHERE b.id IS NULL;

SELECT pg_temp.hv_eq(
    'scenario8 collected total matches billed paid total',
    (SELECT coalesce(sum(paid_amount), 0) FROM public.billing
      WHERE hospital_id = 'aaaaaaaa-0000-4000-8000-000000000001'),
    (SELECT coalesce(sum(pl.amount_paid), 0)
       FROM public.payment_logs pl
       JOIN public.billing b ON b.id = pl.bill_id
      WHERE b.hospital_id = 'aaaaaaaa-0000-4000-8000-000000000001')
);

SELECT pg_temp.hv_eq(
    'scenario8 child rows carry the parent tenant',
    count(*),
    0::bigint
)
  FROM public.billing_items bi
  JOIN public.billing b ON b.id = bi.bill_id
 WHERE bi.hospital_id IS DISTINCT FROM b.hospital_id;

SELECT pg_temp.hv_eq(
    'scenario8 every receipt is committed with a result',
    count(*),
    0::bigint
)
  FROM public.hims_operation_receipts
 WHERE result IS NULL OR result = '{}'::jsonb;

-- ----------------------------------------------------------------------
-- Report
-- ----------------------------------------------------------------------
SELECT pg_temp.hv(
    'harness recorded every expected check',
    (SELECT count(*) FROM _hims_verify) >= 40,
    format('recorded=%s', (SELECT count(*) FROM _hims_verify))
);

SELECT
    ok,
    count(*) AS checks,
    string_agg(label, ', ' ORDER BY label) AS labels
FROM _hims_verify
GROUP BY ok
ORDER BY ok;

SELECT label, detail
  FROM _hims_verify
 WHERE NOT ok
 ORDER BY label;

SELECT CASE
    WHEN count(*) FILTER (WHERE NOT ok) = 0
        THEN format('ALL %s CHECKS PASSED', count(*))
    ELSE format('%s of %s CHECKS FAILED',
                count(*) FILTER (WHERE NOT ok), count(*))
END AS result
  FROM _hims_verify;

ROLLBACK;
