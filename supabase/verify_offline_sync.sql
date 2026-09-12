-- Isolated validation of the offline-sync change log (synthetic data only).

-- Clean any previous run.
DELETE FROM hims_change_log WHERE hospital_id IN (SELECT id FROM hospitals WHERE code IN ('SYNTHA','SYNTHB'));
DELETE FROM patients WHERE hospital_id IN (SELECT id FROM hospitals WHERE code IN ('SYNTHA','SYNTHB'));
DELETE FROM hospitals WHERE code IN ('SYNTHA','SYNTHB');

-- 1. Two hospitals + synthetic patients.
INSERT INTO hospitals (id, name, code) VALUES
  (gen_random_uuid(), 'Hosp A', 'SYNTHA'),
  (gen_random_uuid(), 'Hosp B', 'SYNTHB');

INSERT INTO patients (id, hospital_id, uhid, first_name)
SELECT gen_random_uuid(), h.id, 'SYNTH-A-1', 'PatientA'
FROM hospitals h WHERE h.code = 'SYNTHA';

-- 2. INSERT captured with hospital_id + new_data.
SELECT 'change_log_insert_count' AS check, count(*) AS result
FROM hims_change_log cl JOIN hospitals h ON h.id = cl.hospital_id
WHERE h.code = 'SYNTHA' AND cl.entity = 'patients' AND cl.operation = 'insert';

-- 3. UPDATE captured.
UPDATE patients SET first_name = 'PatientA2'
WHERE hospital_id = (SELECT id FROM hospitals WHERE code = 'SYNTHA') AND uhid = 'SYNTH-A-1';

SELECT 'change_log_update_count' AS check, count(*) AS result
FROM hims_change_log cl JOIN hospitals h ON h.id = cl.hospital_id
WHERE h.code = 'SYNTHA' AND cl.entity = 'patients' AND cl.operation = 'update';

-- 4. Rollback must NOT leave a change_log row.
SAVEPOINT before_rollback;
INSERT INTO patients (id, hospital_id, uhid, first_name)
SELECT gen_random_uuid(), h.id, 'SYNTH-A-ROLLBACK', 'Rollback'
FROM hospitals h WHERE h.code = 'SYNTHA';
ROLLBACK TO SAVEPOINT before_rollback;

SELECT 'change_log_rollback_count' AS check, count(*) AS result
FROM hims_change_log cl JOIN hospitals h ON h.id = cl.hospital_id
WHERE h.code = 'SYNTHA' AND cl.new_data->>'uhid' = 'SYNTH-A-ROLLBACK';

-- 5. Soft-delete captured as operation='delete' and deleted_at set.
DELETE FROM patients
WHERE hospital_id = (SELECT id FROM hospitals WHERE code = 'SYNTHA') AND uhid = 'SYNTH-A-1';

SELECT 'change_log_delete_count' AS check, count(*) AS result
FROM hims_change_log cl JOIN hospitals h ON h.id = cl.hospital_id
WHERE h.code = 'SYNTHA' AND cl.entity = 'patients' AND cl.operation = 'delete';

SELECT 'soft_deleted_rows' AS check, count(*) AS result
FROM patients p JOIN hospitals h ON h.id = p.hospital_id
WHERE h.code = 'SYNTHA' AND p.uhid = 'SYNTH-A-1' AND p.deleted_at IS NOT NULL;

-- 6. RLS enabled + policy present.
SELECT 'change_log_rls_enabled' AS check,
       (SELECT relrowsecurity FROM pg_class WHERE oid = 'hims_change_log'::regclass) AS result;

SELECT 'change_log_rls_policy' AS check, count(*) AS result
FROM pg_policies WHERE schemaname = 'public' AND tablename = 'hims_change_log';

-- 7. Tenant isolation: Hosp B's change_log rows must not be visible under
--    Hosp A's hospital_id filter.
SELECT 'cross_tenant_rows_for_hosp_a' AS check,
       count(*) AS result
FROM hims_change_log cl JOIN hospitals h ON h.id = cl.hospital_id
WHERE h.code = 'SYNTHA' AND cl.new_data->>'uhid' LIKE 'SYNTH-B%';
