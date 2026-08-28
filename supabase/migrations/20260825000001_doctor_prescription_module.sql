-- ======================================================================
-- HIMS - Doctor Prescription Module (e-prescription)
-- Tables: prescription_items (+ idempotent column guards for
--         prescriptions and pharmacy_medicines)
-- Run manually in Supabase SQL Editor, or `supabase db push` as migration.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. PRESCRIPTION ITEMS (line items for a prescription)
--    custom_times stores exact times as a jsonb array, e.g.
--    ["08:00 AM", "02:00 PM", "10:00 PM"]
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS prescription_items (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    prescription_id UUID NOT NULL REFERENCES prescriptions(id) ON DELETE CASCADE,
    medicine_name VARCHAR(255) NOT NULL,
    dosage VARCHAR(100),
    frequency VARCHAR(100),
    duration VARCHAR(100),
    instructions TEXT,
    custom_times JSONB DEFAULT '[]'::jsonb,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_prescription_items_prescription
    ON prescription_items(prescription_id);

-- ----------------------------------------------------------------------
-- 2. IDEMPOTENT COLUMN GUARDS
--    These columns already exist in most environments (initial schema +
--    earlier migrations). ADD COLUMN IF NOT EXISTS keeps this migration
--    safe to re-run.
-- ----------------------------------------------------------------------
ALTER TABLE prescriptions
    ADD COLUMN IF NOT EXISTS patient_id UUID REFERENCES patients(id) ON DELETE CASCADE;

ALTER TABLE prescriptions
    ADD COLUMN IF NOT EXISTS opd_registration_id UUID REFERENCES opd_registrations(id) ON DELETE CASCADE;

ALTER TABLE prescriptions
    ADD COLUMN IF NOT EXISTS ipd_admission_id UUID REFERENCES ipd_admissions(id) ON DELETE CASCADE;

ALTER TABLE prescriptions
    ADD COLUMN IF NOT EXISTS doctor_id UUID REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE prescriptions
    ADD COLUMN IF NOT EXISTS prescription_date DATE DEFAULT CURRENT_DATE;

ALTER TABLE prescriptions
    ADD COLUMN IF NOT EXISTS status VARCHAR(50) DEFAULT 'active';

ALTER TABLE pharmacy_medicines
    ADD COLUMN IF NOT EXISTS hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL;

ALTER TABLE pharmacy_medicines
    ADD COLUMN IF NOT EXISTS medicine_name VARCHAR(255);

ALTER TABLE pharmacy_medicines
    ADD COLUMN IF NOT EXISTS generic_name VARCHAR(255);

ALTER TABLE pharmacy_medicines
    ADD COLUMN IF NOT EXISTS strength VARCHAR(100);

ALTER TABLE pharmacy_medicines
    ADD COLUMN IF NOT EXISTS brand_name VARCHAR(255);

ALTER TABLE pharmacy_medicines
    ADD COLUMN IF NOT EXISTS is_active BOOLEAN DEFAULT true;

CREATE INDEX IF NOT EXISTS idx_pharmacy_medicines_search
    ON pharmacy_medicines(medicine_name, generic_name, brand_name);

-- ----------------------------------------------------------------------
-- 3. ROW LEVEL SECURITY
--    prescriptions and pharmacy_medicines already have policies from the
--    initial RLS migration; prescription_items is new.
-- ----------------------------------------------------------------------
ALTER TABLE prescription_items ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Enable all access for authenticated users on prescription_items" ON prescription_items;
CREATE POLICY "Enable all access for authenticated users on prescription_items"
    ON prescription_items FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- ----------------------------------------------------------------------
-- 4. GRANTS (required on newer Supabase versions)
-- ----------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON prescription_items TO authenticated, anon;
