-- ======================================================================
-- HIMS - IPD Discharge & Billing Module
-- Tables: ipd_charges, ipd_packages, ipd_ward_pricing, ipd_service_master
-- Run manually in Supabase SQL Editor, or `supabase db push` as migration.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. IPD WARD PRICING (daily rate per ward type)
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ipd_ward_pricing (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    ward_type VARCHAR(50) NOT NULL UNIQUE,
    daily_rate DECIMAL(10,2) NOT NULL DEFAULT 0,
    description TEXT,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ----------------------------------------------------------------------
-- 2. IPD PACKAGES (fixed operation / procedure packages)
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ipd_packages (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,
    package_amount DECIMAL(12,2) NOT NULL DEFAULT 0,
    description TEXT,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ----------------------------------------------------------------------
-- 3. IPD CHARGES (all billing line items for an admission)
--    charge_type values:
--      ward_charge, ot_charges, anesthesia, nebulization,
--      blood_transfusion, doctor_visit, pharmacy, lab,
--      package, service, misc
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ipd_charges (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    admission_id UUID NOT NULL REFERENCES ipd_admissions(id) ON DELETE CASCADE,
    charge_type VARCHAR(50) NOT NULL,
    charge_description TEXT,
    amount DECIMAL(12,2) NOT NULL DEFAULT 0,
    charge_date DATE DEFAULT CURRENT_DATE,
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ipd_charges_admission ON ipd_charges(admission_id);
CREATE INDEX IF NOT EXISTS idx_ipd_charges_type ON ipd_charges(charge_type);

-- ----------------------------------------------------------------------
-- 4. IPD SERVICE MASTER (custom services for the discharge screen,
--    e.g. Sitting charge, Dressing charge, Special diet)
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ipd_service_master (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,
    default_charge DECIMAL(10,2) NOT NULL DEFAULT 0,
    description TEXT,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ----------------------------------------------------------------------
-- 5. COLUMN ADDITIONS (safe to re-run)
--    Links bed_allocations back to the admission so ward-transfer
--    segments can be calculated, and adds advance payment support.
--    Also adds the columns used by the existing IPD admission screen.
-- ----------------------------------------------------------------------
ALTER TABLE bed_allocations
    ADD COLUMN IF NOT EXISTS ipd_admission_id UUID REFERENCES ipd_admissions(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_bed_allocations_ipd ON bed_allocations(ipd_admission_id);

ALTER TABLE ipd_admissions
    ADD COLUMN IF NOT EXISTS advance_payment DECIMAL(12,2) DEFAULT 0;

ALTER TABLE ipd_admissions
    ADD COLUMN IF NOT EXISTS ward_type VARCHAR(50);

ALTER TABLE ipd_admissions
    ADD COLUMN IF NOT EXISTS bed_id UUID REFERENCES beds(id) ON DELETE SET NULL;

ALTER TABLE ipd_admissions
    ADD COLUMN IF NOT EXISTS diagnosis TEXT;

ALTER TABLE ipd_admissions
    ADD COLUMN IF NOT EXISTS admission_type VARCHAR(50);

ALTER TABLE ipd_admissions
    ADD COLUMN IF NOT EXISTS is_emergency BOOLEAN DEFAULT false;

ALTER TABLE ipd_admissions
    ADD COLUMN IF NOT EXISTS remarks TEXT;

-- ----------------------------------------------------------------------
-- 6. ROW LEVEL SECURITY (permissive, matches the existing app policies)
-- ----------------------------------------------------------------------
ALTER TABLE ipd_ward_pricing ENABLE ROW LEVEL SECURITY;
ALTER TABLE ipd_packages ENABLE ROW LEVEL SECURITY;
ALTER TABLE ipd_charges ENABLE ROW LEVEL SECURITY;
ALTER TABLE ipd_service_master ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Enable all access for authenticated users on ipd_ward_pricing" ON ipd_ward_pricing;
CREATE POLICY "Enable all access for authenticated users on ipd_ward_pricing"
    ON ipd_ward_pricing FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Enable all access for authenticated users on ipd_packages" ON ipd_packages;
CREATE POLICY "Enable all access for authenticated users on ipd_packages"
    ON ipd_packages FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Enable all access for authenticated users on ipd_charges" ON ipd_charges;
CREATE POLICY "Enable all access for authenticated users on ipd_charges"
    ON ipd_charges FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Enable all access for authenticated users on ipd_service_master" ON ipd_service_master;
CREATE POLICY "Enable all access for authenticated users on ipd_service_master"
    ON ipd_service_master FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- ----------------------------------------------------------------------
-- 7. GRANTS (required on newer Supabase versions)
-- ----------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON
    ipd_ward_pricing, ipd_packages, ipd_charges, ipd_service_master
    TO authenticated, anon;

-- ----------------------------------------------------------------------
-- 8. SEED DATA
-- ----------------------------------------------------------------------

-- Ward pricing (₹ per day)
INSERT INTO ipd_ward_pricing (ward_type, daily_rate, description) VALUES
    ('general',      500,  'General ward bed charge per day'),
    ('semi_private', 1500, 'Semi-private room charge per day'),
    ('private',      3000, 'Private room charge per day'),
    ('icu',          5000, 'ICU bed charge per day'),
    ('nicu',         4000, 'NICU bed charge per day'),
    ('deluxe',       5000, 'Deluxe room charge per day'),
    ('emergency',    1000, 'Emergency observation charge per day')
ON CONFLICT (ward_type) DO UPDATE SET
    daily_rate  = EXCLUDED.daily_rate,
    description = EXCLUDED.description,
    updated_at  = NOW();

-- Operation / procedure packages
INSERT INTO ipd_packages (name, package_amount, description, is_active) VALUES
    ('Appendectomy Package',         35000, 'Open/laparoscopic appendectomy with standard stay', true),
    ('Normal Delivery Package',      25000, 'Normal vaginal delivery package',                 true),
    ('C-Section Package',            55000, 'Caesarean section package',                        true),
    ('Hernia Repair Package',        40000, 'Inguinal/umbilical hernia repair package',         true),
    ('Cholecystectomy Package',      45000, 'Gall bladder removal (laparoscopic)',              true)
ON CONFLICT DO NOTHING;

-- Custom service master
INSERT INTO ipd_service_master (name, default_charge, description, is_active) VALUES
    ('Sitting Charge',      300,  'Attendant sitting charge per day', true),
    ('Dressing Charge',     150,  'Wound dressing charge per sitting', true),
    ('Special Diet',        250,  'Special diet charge per day',      true),
    ('Ambulance Charge',    800,  'Ambulance/transport charge',       true)
ON CONFLICT DO NOTHING;
