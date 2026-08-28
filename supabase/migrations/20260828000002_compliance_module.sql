-- ======================================================================
-- HIMS - Hospital Compliance & Renewal Reminder Module
--
-- Tables:
--   compliance_records     -> one compliance item (license/AMC/CMC/contract/NOC)
--   compliance_documents   -> document files + versions per record
--   compliance_reminders   -> reminder history (30-day, 7-day, expired, manual)
--   compliance_audit_logs  -> who uploaded/viewed/downloaded/shared/printed
--
-- Storage:
--   Files live in the existing public `hims-storage` bucket under
--   `compliance/{hospital_id}/{record_id}/...`. Storage policies below grant
--   authenticated access to the `compliance` folder only.
--
-- Run manually in Supabase SQL Editor, or `supabase db push`.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. COMPLIANCE RECORDS (the compliance item master)
--    document_type examples:
--      Hospital Registration Certificate, Fire NOC, Medical Equipment AMC, ...
--    category: regulatory | amc | cmc | insurance | contracts
--    status is derived in the app; stored for quick filtering:
--      active | expiring | expired | archived
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS compliance_records (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE CASCADE,
    document_name VARCHAR(255) NOT NULL,
    document_type VARCHAR(120) NOT NULL,
    category VARCHAR(30) NOT NULL DEFAULT 'regulatory'
        CHECK (category IN ('regulatory', 'amc', 'cmc', 'insurance', 'contracts')),
    authority_name VARCHAR(255),
    document_number VARCHAR(120),
    issue_date DATE,
    expiry_date DATE,
    reminder_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    status VARCHAR(20) NOT NULL DEFAULT 'active'
        CHECK (status IN ('active', 'expiring', 'expired', 'archived')),
    is_favorite BOOLEAN NOT NULL DEFAULT FALSE,
    notes TEXT,
    tags TEXT[] NOT NULL DEFAULT '{}',
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_compliance_records_hospital
    ON compliance_records(hospital_id);
CREATE INDEX IF NOT EXISTS idx_compliance_records_expiry
    ON compliance_records(expiry_date);
CREATE INDEX IF NOT EXISTS idx_compliance_records_category
    ON compliance_records(category);
CREATE INDEX IF NOT EXISTS idx_compliance_records_status
    ON compliance_records(status);
CREATE INDEX IF NOT EXISTS idx_compliance_records_favorite
    ON compliance_records(hospital_id, is_favorite);

-- ----------------------------------------------------------------------
-- 2. COMPLIANCE DOCUMENTS (versioned files per record)
--    version: 1, 2, 3 ... (v1, v2, ... in UI)
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS compliance_documents (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    record_id UUID NOT NULL REFERENCES compliance_records(id) ON DELETE CASCADE,
    hospital_id UUID REFERENCES hospitals(id) ON DELETE CASCADE,
    file_name VARCHAR(255) NOT NULL,
    file_path TEXT NOT NULL,
    file_url TEXT,
    file_size BIGINT NOT NULL DEFAULT 0,
    mime_type VARCHAR(120),
    version INTEGER NOT NULL DEFAULT 1,
    ocr_text TEXT,
    uploaded_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_compliance_documents_record
    ON compliance_documents(record_id);
CREATE INDEX IF NOT EXISTS idx_compliance_documents_hospital
    ON compliance_documents(hospital_id);
CREATE INDEX IF NOT EXISTS idx_compliance_documents_created
    ON compliance_documents(created_at DESC);

-- ----------------------------------------------------------------------
-- 3. COMPLIANCE REMINDERS (history + scheduling)
--    reminder_type: 30_day | 7_day | expired | manual
--    channel: in_app | email | whatsapp (email/whatsapp rows are marked
--    pending until a backend worker/Edge Function delivers them)
--    status: sent | pending | failed
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS compliance_reminders (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    record_id UUID NOT NULL REFERENCES compliance_records(id) ON DELETE CASCADE,
    hospital_id UUID REFERENCES hospitals(id) ON DELETE CASCADE,
    reminder_type VARCHAR(20) NOT NULL DEFAULT 'manual'
        CHECK (reminder_type IN ('30_day', '7_day', 'expired', 'manual')),
    scheduled_for DATE,
    sent_at TIMESTAMPTZ,
    channel VARCHAR(20) NOT NULL DEFAULT 'in_app'
        CHECK (channel IN ('in_app', 'email', 'whatsapp')),
    message TEXT,
    status VARCHAR(20) NOT NULL DEFAULT 'pending'
        CHECK (status IN ('sent', 'pending', 'failed')),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_compliance_reminders_record
    ON compliance_reminders(record_id);
CREATE INDEX IF NOT EXISTS idx_compliance_reminders_hospital
    ON compliance_reminders(hospital_id);
CREATE INDEX IF NOT EXISTS idx_compliance_reminders_type
    ON compliance_reminders(reminder_type);
CREATE INDEX IF NOT EXISTS idx_compliance_reminders_status
    ON compliance_reminders(status);

-- ----------------------------------------------------------------------
-- 4. COMPLIANCE AUDIT LOGS (who did what, when)
--    action: upload | view | download | share | print | delete |
--            favorite | unfavorite | update
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS compliance_audit_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    record_id UUID REFERENCES compliance_records(id) ON DELETE CASCADE,
    document_id UUID REFERENCES compliance_documents(id) ON DELETE CASCADE,
    hospital_id UUID REFERENCES hospitals(id) ON DELETE CASCADE,
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    user_name VARCHAR(255),
    action VARCHAR(30) NOT NULL,
    detail TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_compliance_audit_record
    ON compliance_audit_logs(record_id);
CREATE INDEX IF NOT EXISTS idx_compliance_audit_hospital
    ON compliance_audit_logs(hospital_id);
CREATE INDEX IF NOT EXISTS idx_compliance_audit_action
    ON compliance_audit_logs(action);
CREATE INDEX IF NOT EXISTS idx_compliance_audit_created
    ON compliance_audit_logs(created_at DESC);

-- ----------------------------------------------------------------------
-- 5. updated_at AUTO TRIGGER
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_compliance_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_compliance_records_updated_at ON compliance_records;
CREATE TRIGGER trg_compliance_records_updated_at
    BEFORE UPDATE ON compliance_records
    FOR EACH ROW EXECUTE FUNCTION set_compliance_updated_at();

-- ----------------------------------------------------------------------
-- 6. ROW LEVEL SECURITY
--    The app enforces hospital-scoped reads/writes in every query; RLS
--    mirrors the existing voucher module policy so authenticated users of
--    the same tenant can work with the module. (Multi-tenant data isolation
--    is applied at the application layer via `hospital_id` filters.)
-- ----------------------------------------------------------------------
ALTER TABLE compliance_records ENABLE ROW LEVEL SECURITY;
ALTER TABLE compliance_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE compliance_reminders ENABLE ROW LEVEL SECURITY;
ALTER TABLE compliance_audit_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Enable all access for authenticated users on compliance_records" ON compliance_records;
CREATE POLICY "Enable all access for authenticated users on compliance_records"
    ON compliance_records FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Enable all access for authenticated users on compliance_documents" ON compliance_documents;
CREATE POLICY "Enable all access for authenticated users on compliance_documents"
    ON compliance_documents FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Enable all access for authenticated users on compliance_reminders" ON compliance_reminders;
CREATE POLICY "Enable all access for authenticated users on compliance_reminders"
    ON compliance_reminders FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Enable all access for authenticated users on compliance_audit_logs" ON compliance_audit_logs;
CREATE POLICY "Enable all access for authenticated users on compliance_audit_logs"
    ON compliance_audit_logs FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- ----------------------------------------------------------------------
-- 7. GRANTS
-- ----------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON compliance_records TO authenticated, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON compliance_documents TO authenticated, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON compliance_reminders TO authenticated, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON compliance_audit_logs TO authenticated, anon;

-- ----------------------------------------------------------------------
-- 8. STORAGE policies for the compliance folder in hims-storage
-- ----------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public)
VALUES ('hims-storage', 'hims-storage', TRUE)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "compliance_storage_upload" ON storage.objects;
CREATE POLICY "compliance_storage_upload" ON storage.objects
    FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'hims-storage'
        AND (storage.foldername(name))[1] = 'compliance'
    );

DROP POLICY IF EXISTS "compliance_storage_select" ON storage.objects;
CREATE POLICY "compliance_storage_select" ON storage.objects
    FOR SELECT TO authenticated
    USING (
        bucket_id = 'hims-storage'
        AND (storage.foldername(name))[1] = 'compliance'
    );

DROP POLICY IF EXISTS "compliance_storage_delete" ON storage.objects;
CREATE POLICY "compliance_storage_delete" ON storage.objects
    FOR DELETE TO authenticated
    USING (
        bucket_id = 'hims-storage'
        AND (storage.foldername(name))[1] = 'compliance'
    );
