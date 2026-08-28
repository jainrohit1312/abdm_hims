-- ======================================================================
-- HIMS - Hospital Voucher / Expense Module
--
-- Tables:
--   vouchers            -> expense / payment / adjustment vouchers
--   voucher_categories  -> hospital-specific custom expense categories
--   voucher_settings    -> approver name + approval limit (per hospital)
--
-- Run manually in Supabase SQL Editor, or `supabase db push`.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. VOUCHERS
--    voucher_type: Expense | Payment | Adjustment
--    payment_mode: Cash | Card | UPI | Bank Transfer
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS vouchers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    voucher_number VARCHAR(50) NOT NULL UNIQUE,
    hospital_id UUID REFERENCES hospitals(id) ON DELETE CASCADE,
    voucher_date DATE NOT NULL DEFAULT CURRENT_DATE,
    payee_name VARCHAR(255),
    payment_mode VARCHAR(30) NOT NULL DEFAULT 'Cash',
    description TEXT,
    amount NUMERIC(12, 2) NOT NULL DEFAULT 0,
    voucher_type VARCHAR(20) NOT NULL DEFAULT 'Expense'
        CHECK (voucher_type IN ('Expense', 'Payment', 'Adjustment')),
    expense_category VARCHAR(255),
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    approved_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_vouchers_hospital
    ON vouchers(hospital_id);
CREATE INDEX IF NOT EXISTS idx_vouchers_voucher_date
    ON vouchers(voucher_date);
CREATE INDEX IF NOT EXISTS idx_vouchers_hospital_date
    ON vouchers(hospital_id, voucher_date);
CREATE INDEX IF NOT EXISTS idx_vouchers_category
    ON vouchers(expense_category);

-- ----------------------------------------------------------------------
-- 2. VOUCHER CUSTOM CATEGORIES
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS voucher_categories (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE CASCADE,
    category_name VARCHAR(255) NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (hospital_id, category_name)
);

CREATE INDEX IF NOT EXISTS idx_voucher_categories_hospital
    ON voucher_categories(hospital_id);

-- ----------------------------------------------------------------------
-- 3. VOUCHER APPROVAL SETTINGS (one row per hospital)
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS voucher_settings (
    hospital_id UUID PRIMARY KEY REFERENCES hospitals(id) ON DELETE CASCADE,
    approver_name VARCHAR(255),
    approval_limit NUMERIC(12, 2) NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ----------------------------------------------------------------------
-- 4. updated_at AUTO TRIGGER
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_voucher_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_vouchers_updated_at ON vouchers;
CREATE TRIGGER trg_vouchers_updated_at
    BEFORE UPDATE ON vouchers
    FOR EACH ROW EXECUTE FUNCTION set_voucher_updated_at();

DROP TRIGGER IF EXISTS trg_voucher_settings_updated_at ON voucher_settings;
CREATE TRIGGER trg_voucher_settings_updated_at
    BEFORE UPDATE ON voucher_settings
    FOR EACH ROW EXECUTE FUNCTION set_voucher_updated_at();

-- ----------------------------------------------------------------------
-- 5. ROW LEVEL SECURITY
-- ----------------------------------------------------------------------
ALTER TABLE vouchers ENABLE ROW LEVEL SECURITY;
ALTER TABLE voucher_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE voucher_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Enable all access for authenticated users on vouchers" ON vouchers;
CREATE POLICY "Enable all access for authenticated users on vouchers"
    ON vouchers FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Enable all access for authenticated users on voucher_categories" ON voucher_categories;
CREATE POLICY "Enable all access for authenticated users on voucher_categories"
    ON voucher_categories FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Enable all access for authenticated users on voucher_settings" ON voucher_settings;
CREATE POLICY "Enable all access for authenticated users on voucher_settings"
    ON voucher_settings FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- ----------------------------------------------------------------------
-- 6. GRANTS
-- ----------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON vouchers TO authenticated, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON voucher_categories TO authenticated, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON voucher_settings TO authenticated, anon;
