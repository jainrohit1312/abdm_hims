-- ======================================================================
-- HIMS - IPD Patient Dashboard: grouped record enhancements
--
-- 1. Adds the missing respiration_rate column to ipd_vitals so the
--    TPR (Temperature, Pulse, Respiration) chart can be displayed.
-- 2. Adds created_by / updated_by (and recorded_by for vitals) audit
--    columns so the dashboard can show who added/modified each record.
--
-- All statements are idempotent and safe to re-run.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. IPD VITALS: respiration + recorder audit columns
-- ----------------------------------------------------------------------
ALTER TABLE ipd_vitals
    ADD COLUMN IF NOT EXISTS respiration_rate INTEGER;

ALTER TABLE ipd_vitals
    ADD COLUMN IF NOT EXISTS recorded_by UUID REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE ipd_vitals
    ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES users(id) ON DELETE SET NULL;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ipd_vitals_respiration_range') THEN
        ALTER TABLE ipd_vitals
            ADD CONSTRAINT ipd_vitals_respiration_range
            CHECK (respiration_rate IS NULL OR (respiration_rate BETWEEN 0 AND 120));
    END IF;
END $$;

-- ----------------------------------------------------------------------
-- 2. Audit columns for the remaining dashboard tables
-- ----------------------------------------------------------------------
ALTER TABLE ipd_progress_notes
    ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE ipd_progress_notes
    ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE ipd_medications
    ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE ipd_medications
    ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE ipd_reports
    ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE ipd_reports
    ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES users(id) ON DELETE SET NULL;

-- ----------------------------------------------------------------------
-- 3. Indexes for the new audit columns
-- ----------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_ipd_vitals_recorded_by
    ON ipd_vitals(recorded_by);
CREATE INDEX IF NOT EXISTS idx_ipd_progress_notes_created_by
    ON ipd_progress_notes(created_by);
CREATE INDEX IF NOT EXISTS idx_ipd_medications_created_by
    ON ipd_medications(created_by);
CREATE INDEX IF NOT EXISTS idx_ipd_reports_created_by
    ON ipd_reports(created_by);
