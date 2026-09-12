-- Isolated validation of child-record sync + accounting idempotency. Synthetic.

-- Clean previous run.
DELETE FROM hims_change_log WHERE hospital_id IN (SELECT id FROM hospitals WHERE code IN ('SYNTHA','SYNTHB'));
DELETE FROM payment_logs WHERE hospital_id IN (SELECT id FROM hospitals WHERE code IN ('SYNTHA','SYNTHB'));
DELETE FROM billing_items WHERE hospital_id IN (SELECT id FROM hospitals WHERE code IN ('SYNTHA','SYNTHB'));
DELETE FROM billing WHERE hospital_id IN (SELECT id FROM hospitals WHERE code IN ('SYNTHA','SYNTHB'));
DELETE FROM opd_registrations WHERE hospital_id IN (SELECT id FROM hospitals WHERE code IN ('SYNTHA','SYNTHB'));
DELETE FROM patients WHERE hospital_id IN (SELECT id FROM hospitals WHERE code IN ('SYNTHA','SYNTHB'));
DELETE FROM hospitals WHERE code IN ('SYNTHA','SYNTHB');

INSERT INTO hospitals (id, name, code) VALUES
  (gen_random_uuid(), 'Hosp A', 'SYNTHA'),
  (gen_random_uuid(), 'Hosp B', 'SYNTHB');

-- A patient (fixed id for idempotency) + a bill with child rows.
INSERT INTO patients (id, hospital_id, uhid, first_name)
SELECT '44444444-4444-4444-4444-444444444444', h.id, 'SYNTH-UHID-1', 'Synthetic'
FROM hospitals h WHERE h.code = 'SYNTHA';

INSERT INTO billing (id, hospital_id, patient_id, bill_number, bill_date, total_amount, net_amount, paid_amount, balance_amount, payment_status, source_type)
SELECT '11111111-1111-1111-1111-111111111111', h.id, '44444444-4444-4444-4444-444444444444', 'SYNTH-BILL-1', CURRENT_DATE, 300, 300, 300, 0, 'paid', 'opd'
FROM hospitals h WHERE h.code = 'SYNTHA';

INSERT INTO billing_items (id, bill_id, hospital_id, item_name, quantity, unit_price, total_price)
VALUES ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', NULL, 'Consultation Fee', 1, 300, 300);

INSERT INTO payment_logs (id, bill_id, hospital_id, amount_paid, payment_mode, payment_date)
VALUES ('33333333-3333-3333-3333-333333333333', '11111111-1111-1111-1111-111111111111', NULL, 300, 'cash', NOW());

-- 1. Child rows auto-filled hospital_id from parent.
SELECT 'billing_items_hospital_filled' AS check, count(*) AS result
FROM billing_items bi JOIN hospitals h ON h.id = bi.hospital_id
WHERE bi.id = '22222222-2222-2222-2222-222222222222' AND h.code = 'SYNTHA';

SELECT 'payment_logs_hospital_filled' AS check, count(*) AS result
FROM payment_logs pl JOIN hospitals h ON h.id = pl.hospital_id
WHERE pl.id = '33333333-3333-3333-3333-333333333333' AND h.code = 'SYNTHA';

-- 2. change_log captured patient + billing + items + payment.
SELECT 'change_log_patient_count' AS check, count(*) AS result
FROM hims_change_log cl JOIN hospitals h ON h.id = cl.hospital_id
WHERE h.code = 'SYNTHA' AND cl.entity = 'patients';

SELECT 'change_log_billing_count' AS check, count(*) AS result
FROM hims_change_log cl JOIN hospitals h ON h.id = cl.hospital_id
WHERE h.code = 'SYNTHA' AND cl.entity = 'billing';

SELECT 'change_log_items_count' AS check, count(*) AS result
FROM hims_change_log cl JOIN hospitals h ON h.id = cl.hospital_id
WHERE h.code = 'SYNTHA' AND cl.entity = 'billing_items';

SELECT 'change_log_payment_count' AS check, count(*) AS result
FROM hims_change_log cl JOIN hospitals h ON h.id = cl.hospital_id
WHERE h.code = 'SYNTHA' AND cl.entity = 'payment_logs';

-- 3. Idempotency: the fixed bill id exists exactly once.
SELECT 'billing_rows_for_fixed_id' AS check, count(*) AS result
FROM billing WHERE id = '11111111-1111-1111-1111-111111111111';

-- 4. Tenant isolation: Hosp B must not see Hosp A's child rows.
SELECT 'cross_tenant_child_rows' AS check, count(*) AS result
FROM billing_items bi JOIN hospitals h ON h.id = bi.hospital_id
WHERE h.code = 'SYNTHB' AND bi.bill_id = '11111111-1111-1111-1111-111111111111';
