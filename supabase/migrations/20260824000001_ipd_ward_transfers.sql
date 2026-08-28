-- ======================================================================
-- HIMS - IPD Ward Transfers
-- Run manually in Supabase SQL Editor, or `supabase db push` as migration.
-- ======================================================================

CREATE TABLE IF NOT EXISTS ward_transfers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    admission_id UUID NOT NULL REFERENCES ipd_admissions(id) ON DELETE CASCADE,
    old_ward_type VARCHAR(50),
    new_ward_type VARCHAR(50) NOT NULL,
    old_bed_id UUID REFERENCES beds(id) ON DELETE SET NULL,
    new_bed_id UUID NOT NULL REFERENCES beds(id) ON DELETE RESTRICT,
    transfer_reason TEXT,
    transfer_date DATE DEFAULT CURRENT_DATE,
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ward_transfers_admission ON ward_transfers(admission_id);
CREATE INDEX IF NOT EXISTS idx_ward_transfers_date ON ward_transfers(transfer_date);

ALTER TABLE ward_transfers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Enable all access for authenticated users on ward_transfers" ON ward_transfers;
CREATE POLICY "Enable all access for authenticated users on ward_transfers"
    ON ward_transfers FOR ALL TO authenticated USING (true) WITH CHECK (true);

GRANT SELECT, INSERT, UPDATE, DELETE ON ward_transfers TO authenticated, anon;
