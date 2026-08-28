-- ======================================================================
-- HIMS - IPD Patient Dashboard
-- Tables: ipd_vitals, ipd_progress_notes, ipd_medications, ipd_reports
-- Run manually in Supabase SQL Editor, or `supabase db push` as migration.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. IPD VITALS (temperature, pulse, BP, SpO2 per admission)
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ipd_vitals (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    admission_id UUID NOT NULL REFERENCES ipd_admissions(id) ON DELETE CASCADE,
    temperature NUMERIC(4,1),
    pulse_rate INTEGER,
    blood_pressure_systolic INTEGER,
    blood_pressure_diastolic INTEGER,
    spo2 NUMERIC(5,2),
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ipd_vitals_admission
    ON ipd_vitals(admission_id, recorded_at DESC);

-- ----------------------------------------------------------------------
-- 2. IPD PROGRESS NOTES (doctor's daily clinical notes)
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ipd_progress_notes (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    admission_id UUID NOT NULL REFERENCES ipd_admissions(id) ON DELETE CASCADE,
    note_date DATE DEFAULT CURRENT_DATE,
    note_text TEXT NOT NULL,
    doctor_id UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ipd_progress_notes_admission
    ON ipd_progress_notes(admission_id, note_date DESC);

-- ----------------------------------------------------------------------
-- 3. IPD MEDICATIONS (medication chart for the admission)
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ipd_medications (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    admission_id UUID NOT NULL REFERENCES ipd_admissions(id) ON DELETE CASCADE,
    medicine_name TEXT NOT NULL,
    dosage TEXT,
    frequency TEXT,
    start_date DATE,
    end_date DATE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ipd_medications_admission
    ON ipd_medications(admission_id, start_date DESC);

-- ----------------------------------------------------------------------
-- 4. IPD REPORTS (lab reports & investigation results)
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ipd_reports (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    admission_id UUID NOT NULL REFERENCES ipd_admissions(id) ON DELETE CASCADE,
    report_type TEXT NOT NULL,
    report_url TEXT,
    report_date DATE DEFAULT CURRENT_DATE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ipd_reports_admission
    ON ipd_reports(admission_id, report_date DESC);

-- ----------------------------------------------------------------------
-- 5. RANGE CHECKS (safe to re-run)
-- ----------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ipd_vitals_spo2_range') THEN
        ALTER TABLE ipd_vitals
            ADD CONSTRAINT ipd_vitals_spo2_range
            CHECK (spo2 IS NULL OR (spo2 BETWEEN 0 AND 100));
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ipd_vitals_pulse_range') THEN
        ALTER TABLE ipd_vitals
            ADD CONSTRAINT ipd_vitals_pulse_range
            CHECK (pulse_rate IS NULL OR (pulse_rate BETWEEN 0 AND 300));
    END IF;
END $$;

-- ----------------------------------------------------------------------
-- 6. COLUMN ADDITIONS (safe to re-run)
--    The dashboard reads these ipd_admissions columns. Most environments
--    already have them from earlier migrations; IF NOT EXISTS keeps this
--    migration idempotent.
-- ----------------------------------------------------------------------
ALTER TABLE ipd_admissions
    ADD COLUMN IF NOT EXISTS bed_id UUID REFERENCES beds(id) ON DELETE SET NULL;

ALTER TABLE ipd_admissions
    ADD COLUMN IF NOT EXISTS ward_type VARCHAR(50);

ALTER TABLE ipd_admissions
    ADD COLUMN IF NOT EXISTS diagnosis TEXT;

ALTER TABLE ipd_admissions
    ADD COLUMN IF NOT EXISTS advance_payment DECIMAL(12,2) DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_ipd_admissions_bed_id ON ipd_admissions(bed_id);

-- ----------------------------------------------------------------------
-- 7. ROW LEVEL SECURITY (permissive, matches the existing app policies)
-- ----------------------------------------------------------------------
ALTER TABLE ipd_vitals ENABLE ROW LEVEL SECURITY;
ALTER TABLE ipd_progress_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE ipd_medications ENABLE ROW LEVEL SECURITY;
ALTER TABLE ipd_reports ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Enable all access for authenticated users on ipd_vitals" ON ipd_vitals;
CREATE POLICY "Enable all access for authenticated users on ipd_vitals"
    ON ipd_vitals FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Enable all access for authenticated users on ipd_progress_notes" ON ipd_progress_notes;
CREATE POLICY "Enable all access for authenticated users on ipd_progress_notes"
    ON ipd_progress_notes FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Enable all access for authenticated users on ipd_medications" ON ipd_medications;
CREATE POLICY "Enable all access for authenticated users on ipd_medications"
    ON ipd_medications FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Enable all access for authenticated users on ipd_reports" ON ipd_reports;
CREATE POLICY "Enable all access for authenticated users on ipd_reports"
    ON ipd_reports FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- ----------------------------------------------------------------------
-- 8. GRANTS (required on newer Supabase versions)
-- ----------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON
    ipd_vitals, ipd_progress_notes, ipd_medications, ipd_reports
    TO authenticated, anon;
