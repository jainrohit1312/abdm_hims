-- ======================================================================
-- HIMS - Unified Billing Module Upgrade
-- ----------------------------------------------------------------------
-- * billing.visit_type        -> opd | ipd | lab (unified filter column)
-- * billing.diagnostic_order_id -> links a lab bill back to its order
-- * opd_registrations payment columns -> OPD bills can track payments
-- * bill_edits                -> audit trail for every bill change
-- * payment_logs              -> transaction/payment history per bill
--
-- Run manually in the Supabase SQL Editor, or `supabase db push`.
-- The script is idempotent (safe to run more than once).
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. BILLING: add visit_type + diagnostic_order_id
-- ----------------------------------------------------------------------
ALTER TABLE billing
    ADD COLUMN IF NOT EXISTS visit_type VARCHAR(20);

ALTER TABLE billing
    ADD COLUMN IF NOT EXISTS diagnostic_order_id UUID REFERENCES diagnostic_orders(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_billing_visit_type ON billing(visit_type);
CREATE INDEX IF NOT EXISTS idx_billing_diagnostic_order ON billing(diagnostic_order_id);

-- Backfill visit_type from the legacy bill_type values.
UPDATE billing
SET visit_type = CASE
    WHEN bill_type IN ('ipd', 'discharge') THEN 'ipd'
    WHEN bill_type IN ('diagnostics', 'lab', 'radiology') THEN 'lab'
    WHEN bill_type = 'opd' THEN 'opd'
    ELSE 'opd'
END
WHERE visit_type IS NULL;

-- ----------------------------------------------------------------------
-- 2. OPD REGISTRATIONS: payment tracking columns so OPD bills can be
--    edited / settled from the unified billing screen without needing a
--    pre-existing `billing` row.
-- ----------------------------------------------------------------------
ALTER TABLE opd_registrations
    ADD COLUMN IF NOT EXISTS paid_amount DECIMAL(12,2) NOT NULL DEFAULT 0;

ALTER TABLE opd_registrations
    ADD COLUMN IF NOT EXISTS balance_amount DECIMAL(12,2) NOT NULL DEFAULT 0;

ALTER TABLE opd_registrations
    ADD COLUMN IF NOT EXISTS payment_status VARCHAR(50) NOT NULL DEFAULT 'unpaid';

ALTER TABLE opd_registrations
    ADD COLUMN IF NOT EXISTS payment_mode VARCHAR(50);

-- Backfill balance for rows that still have the default 0 balance.
UPDATE opd_registrations
SET balance_amount = COALESCE(consultation_fee, 0) - COALESCE(paid_amount, 0),
    payment_status = CASE
        WHEN COALESCE(paid_amount, 0) >= COALESCE(consultation_fee, 0)
             AND COALESCE(consultation_fee, 0) > 0 THEN 'paid'
        WHEN COALESCE(paid_amount, 0) > 0 THEN 'partially_paid'
        ELSE 'unpaid'
    END
WHERE balance_amount = 0
   OR payment_status = 'unpaid';

-- ----------------------------------------------------------------------
-- 3. BILL EDITS (audit trail)
--    OPD bills are materialised into `billing` before any edit, so
--    `bill_id` always references a real `billing.id`.
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS bill_edits (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    bill_id UUID NOT NULL REFERENCES billing(id) ON DELETE CASCADE,
    edited_by UUID REFERENCES users(id) ON DELETE SET NULL,
    old_amount DECIMAL(12,2) NOT NULL DEFAULT 0,
    new_amount DECIMAL(12,2) NOT NULL DEFAULT 0,
    edit_reason TEXT,
    edit_date TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_bill_edits_bill ON bill_edits(bill_id);
CREATE INDEX IF NOT EXISTS idx_bill_edits_date ON bill_edits(edit_date);

-- ----------------------------------------------------------------------
-- 4. PAYMENT LOGS (transaction history)
--    `bill_id` references `billing(id)` so PostgREST can embed the
--    transaction history directly on the bill.
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS payment_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    bill_id UUID NOT NULL REFERENCES billing(id) ON DELETE CASCADE,
    amount_paid DECIMAL(12,2) NOT NULL DEFAULT 0,
    payment_mode VARCHAR(50),           -- cash, card, upi, online, cheque
    payment_date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    paid_by VARCHAR(255),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_payment_logs_bill ON payment_logs(bill_id);
CREATE INDEX IF NOT EXISTS idx_payment_logs_date ON payment_logs(payment_date);

-- ----------------------------------------------------------------------
-- 5. AUTO updated_at FOR billing
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_billing_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_billing_updated_at ON billing;
CREATE TRIGGER trg_billing_updated_at
    BEFORE UPDATE ON billing
    FOR EACH ROW EXECUTE FUNCTION set_billing_updated_at();

-- ----------------------------------------------------------------------
-- 6. ROW LEVEL SECURITY (matches the permissive app policies)
-- ----------------------------------------------------------------------
ALTER TABLE bill_edits ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Enable all access for authenticated users on bill_edits" ON bill_edits;
CREATE POLICY "Enable all access for authenticated users on bill_edits"
    ON bill_edits FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Enable all access for authenticated users on payment_logs" ON payment_logs;
CREATE POLICY "Enable all access for authenticated users on payment_logs"
    ON payment_logs FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- ----------------------------------------------------------------------
-- 7. GRANTS (required on newer Supabase versions)
-- ----------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON bill_edits, payment_logs
    TO authenticated, anon;
