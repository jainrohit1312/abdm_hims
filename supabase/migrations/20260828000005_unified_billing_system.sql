-- ======================================================================
-- HIMS - Unified Billing System
-- ----------------------------------------------------------------------
-- Extends the existing billing module (billing, billing_items, bill_edits,
-- payment_logs) with:
--   * billing.source_type        -> opd | ipd | lab | pharmacy | manual
--   * billing.subtotal / discount_percentage / notes / internal_notes
--   * billing.updated_by         -> users(id) who last modified the bill
--   * payment_logs additional columns (payment_amount, transaction_reference,
--     recorded_by, notes)
--   * billing_audit              -> JSONB audit trail for every modification
--
-- Idempotent — safe to run more than once.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. BILLING: source tracking + financial/notes columns
-- ----------------------------------------------------------------------
ALTER TABLE billing
    ADD COLUMN IF NOT EXISTS source_type VARCHAR(20)
        DEFAULT 'manual'
        CHECK (source_type IN ('opd', 'ipd', 'lab', 'pharmacy', 'manual'));

ALTER TABLE billing
    ADD COLUMN IF NOT EXISTS opd_registration_id UUID REFERENCES opd_registrations(id) ON DELETE SET NULL;

ALTER TABLE billing
    ADD COLUMN IF NOT EXISTS ipd_admission_id UUID REFERENCES ipd_admissions(id) ON DELETE SET NULL;

ALTER TABLE billing
    ADD COLUMN IF NOT EXISTS diagnostic_order_id UUID REFERENCES diagnostic_orders(id) ON DELETE SET NULL;

ALTER TABLE billing
    ADD COLUMN IF NOT EXISTS bill_number VARCHAR(50) UNIQUE;

ALTER TABLE billing
    ADD COLUMN IF NOT EXISTS subtotal DECIMAL(12,2) DEFAULT 0;

ALTER TABLE billing
    ADD COLUMN IF NOT EXISTS discount_reason TEXT;

ALTER TABLE billing
    ADD COLUMN IF NOT EXISTS discount_percentage DECIMAL(5,2) DEFAULT 0;

ALTER TABLE billing
    ADD COLUMN IF NOT EXISTS notes TEXT;

ALTER TABLE billing
    ADD COLUMN IF NOT EXISTS internal_notes TEXT;

ALTER TABLE billing
    ADD COLUMN IF NOT EXISTS updated_by UUID REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE billing
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ DEFAULT NOW();

CREATE INDEX IF NOT EXISTS idx_billing_source_type ON billing(source_type);
CREATE INDEX IF NOT EXISTS idx_billing_opd_registration ON billing(opd_registration_id);
CREATE INDEX IF NOT EXISTS idx_billing_ipd_admission ON billing(ipd_admission_id);

-- ----------------------------------------------------------------------
-- 2. Backfill source_type from the linked visit records.
--    (opd_registration_id / ipd_admission_id already exist in the base
--    schema, so rows created before this migration can be classified.)
-- ----------------------------------------------------------------------
UPDATE billing SET source_type = 'opd'
WHERE opd_registration_id IS NOT NULL AND (source_type IS NULL OR source_type = 'manual');

UPDATE billing SET source_type = 'ipd'
WHERE ipd_admission_id IS NOT NULL AND (source_type IS NULL OR source_type = 'manual');

UPDATE billing SET source_type = 'lab'
WHERE visit_type = 'lab' AND (source_type IS NULL OR source_type = 'manual');

UPDATE billing SET source_type = 'manual'
WHERE source_type IS NULL;

-- ----------------------------------------------------------------------
-- 3. Bill numbers for any legacy rows that somehow lack one.
-- ----------------------------------------------------------------------
UPDATE billing
SET bill_number = 'BILL-' || to_char(created_at, 'YYYYMMDD') || '-' ||
                  LPAD(floor(random() * 9999)::text, 4, '0')
WHERE bill_number IS NULL;

-- ----------------------------------------------------------------------
-- 4. PAYMENT LOGS: extra columns for the unified payment history.
--    `payment_logs` already exists (billing module upgrade), so these are
--    additive and keep the original `amount_paid` column intact.
-- ----------------------------------------------------------------------
ALTER TABLE payment_logs
    ADD COLUMN IF NOT EXISTS payment_amount DECIMAL(12,2);

ALTER TABLE payment_logs
    ADD COLUMN IF NOT EXISTS transaction_reference VARCHAR(255);

ALTER TABLE payment_logs
    ADD COLUMN IF NOT EXISTS recorded_by UUID REFERENCES users(id) ON DELETE SET NULL;

ALTER TABLE payment_logs
    ADD COLUMN IF NOT EXISTS notes TEXT;

-- Backfill the new payment_amount column from amount_paid.
UPDATE payment_logs
SET payment_amount = amount_paid
WHERE payment_amount IS NULL AND amount_paid IS NOT NULL;

-- ----------------------------------------------------------------------
-- 5. BILLING AUDIT: JSONB audit trail for every bill modification.
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS billing_audit (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    bill_id UUID REFERENCES billing(id) ON DELETE CASCADE,
    action VARCHAR(50) NOT NULL
        CHECK (action IN (
            'created',
            'item_added',
            'item_removed',
            'item_updated',
            'discount_applied',
            'payment_added',
            'status_changed',
            'edited'
        )),
    old_value JSONB,
    new_value JSONB,
    description TEXT,
    performed_by UUID REFERENCES users(id) ON DELETE SET NULL,
    performed_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_billing_audit_bill ON billing_audit(bill_id);
CREATE INDEX IF NOT EXISTS idx_billing_audit_date ON billing_audit(performed_at);

-- ----------------------------------------------------------------------
-- 6. ROW LEVEL SECURITY (matches the permissive app policies)
-- ----------------------------------------------------------------------
ALTER TABLE billing_audit ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Enable all access for authenticated users on billing_audit" ON billing_audit;
CREATE POLICY "Enable all access for authenticated users on billing_audit"
    ON billing_audit FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- ----------------------------------------------------------------------
-- 7. GRANTS (required on newer Supabase versions)
-- ----------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON billing_audit
    TO authenticated, anon;
