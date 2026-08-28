-- ======================================================================
-- HIMS - Offline-First Data Sync
-- ----------------------------------------------------------------------
-- Adds offline_id (UUID) + sync_status (String) to the four core
-- transactional tables so the Flutter app can sync local rows to Supabase.
--
--   sync_status values: 'pending'  -> saved offline, not yet uploaded
--                       'synced'   -> uploaded successfully
--
-- Idempotent: safe to run more than once from the Supabase SQL Editor
-- (or via `supabase db push`).
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. PATIENTS
-- ----------------------------------------------------------------------
ALTER TABLE patients
    ADD COLUMN IF NOT EXISTS offline_id UUID,
    ADD COLUMN IF NOT EXISTS sync_status VARCHAR(20) NOT NULL DEFAULT 'synced';

CREATE UNIQUE INDEX IF NOT EXISTS idx_patients_offline_id
    ON patients(offline_id)
    WHERE offline_id IS NOT NULL;

-- Existing rows get offline_id = id so legacy data can still be cached
-- and deduplicated by the sync engine.
UPDATE patients
SET offline_id = id
WHERE offline_id IS NULL;

-- ----------------------------------------------------------------------
-- 2. OPD REGISTRATIONS
-- ----------------------------------------------------------------------
ALTER TABLE opd_registrations
    ADD COLUMN IF NOT EXISTS offline_id UUID,
    ADD COLUMN IF NOT EXISTS sync_status VARCHAR(20) NOT NULL DEFAULT 'synced';

CREATE UNIQUE INDEX IF NOT EXISTS idx_opd_registrations_offline_id
    ON opd_registrations(offline_id)
    WHERE offline_id IS NOT NULL;

UPDATE opd_registrations
SET offline_id = id
WHERE offline_id IS NULL;

-- ----------------------------------------------------------------------
-- 3. IPD ADMISSIONS
-- ----------------------------------------------------------------------
ALTER TABLE ipd_admissions
    ADD COLUMN IF NOT EXISTS offline_id UUID,
    ADD COLUMN IF NOT EXISTS sync_status VARCHAR(20) NOT NULL DEFAULT 'synced';

CREATE UNIQUE INDEX IF NOT EXISTS idx_ipd_admissions_offline_id
    ON ipd_admissions(offline_id)
    WHERE offline_id IS NOT NULL;

UPDATE ipd_admissions
SET offline_id = id
WHERE offline_id IS NULL;

-- ----------------------------------------------------------------------
-- 4. BILLING
-- ----------------------------------------------------------------------
ALTER TABLE billing
    ADD COLUMN IF NOT EXISTS offline_id UUID,
    ADD COLUMN IF NOT EXISTS sync_status VARCHAR(20) NOT NULL DEFAULT 'synced';

CREATE UNIQUE INDEX IF NOT EXISTS idx_billing_offline_id
    ON billing(offline_id)
    WHERE offline_id IS NOT NULL;

UPDATE billing
SET offline_id = id
WHERE offline_id IS NULL;

-- ----------------------------------------------------------------------
-- 5. GRANTS (required on newer Supabase versions; safe to re-run)
-- ----------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON
    patients, opd_registrations, ipd_admissions, billing
    TO authenticated, anon;
