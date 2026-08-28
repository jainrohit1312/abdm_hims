-- ======================================================================
-- HIMS - WhatsApp Marketing Module (Meta WhatsApp Cloud API)
--
-- Tables:
--   whatsapp_settings   -> per-hospital Meta API credentials
--   whatsapp_templates  -> local copy of Meta message templates
--   whatsapp_campaigns  -> broadcast campaigns
--   whatsapp_messages   -> individual message delivery logs
--   whatsapp_opt_outs   -> patient DND list
--
-- Integration columns:
--   patients.whatsapp_opt_in          (patient master consent flag)
--   opd_registrations.whatsapp_opt_in (consent captured at OPD)
--   ipd_admissions.whatsapp_opt_in    (consent captured at IPD)
--
-- Run manually in Supabase SQL Editor, or `supabase db push`.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 0. Integration columns on existing tenant tables
-- ----------------------------------------------------------------------
ALTER TABLE public.patients
    ADD COLUMN IF NOT EXISTS whatsapp_opt_in BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE public.opd_registrations
    ADD COLUMN IF NOT EXISTS whatsapp_opt_in BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE public.ipd_admissions
    ADD COLUMN IF NOT EXISTS whatsapp_opt_in BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS idx_patients_whatsapp_opt_in
    ON public.patients(whatsapp_opt_in);
CREATE INDEX IF NOT EXISTS idx_opd_whatsapp_opt_in
    ON public.opd_registrations(whatsapp_opt_in);
CREATE INDEX IF NOT EXISTS idx_ipd_whatsapp_opt_in
    ON public.ipd_admissions(whatsapp_opt_in);

-- ----------------------------------------------------------------------
-- 1. WHATSAPP SETTINGS (one active row per hospital)
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS whatsapp_settings (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID NOT NULL UNIQUE REFERENCES hospitals(id) ON DELETE CASCADE,
    api_key TEXT NOT NULL DEFAULT '',
    phone_number_id VARCHAR(50) NOT NULL DEFAULT '',
    business_account_id VARCHAR(50) NOT NULL DEFAULT '',
    webhook_verify_token VARCHAR(255) NOT NULL DEFAULT '',
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_whatsapp_settings_hospital
    ON whatsapp_settings(hospital_id);

-- ----------------------------------------------------------------------
-- 2. WHATSAPP TEMPLATES
--    category: MARKETING | UTILITY | AUTHENTICATION
--    status:   pending | approved | rejected | paused
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS whatsapp_templates (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID NOT NULL REFERENCES hospitals(id) ON DELETE CASCADE,
    template_name VARCHAR(255) NOT NULL,
    language VARCHAR(10) NOT NULL DEFAULT 'en',
    category VARCHAR(20) NOT NULL DEFAULT 'MARKETING',
    body TEXT NOT NULL DEFAULT '',
    header_type VARCHAR(20) NOT NULL DEFAULT 'none',
    header_text TEXT NOT NULL DEFAULT '',
    footer_text TEXT NOT NULL DEFAULT '',
    buttons JSONB NOT NULL DEFAULT '[]'::jsonb,
    status VARCHAR(20) NOT NULL DEFAULT 'pending',
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (hospital_id, template_name)
);

CREATE INDEX IF NOT EXISTS idx_whatsapp_templates_hospital
    ON whatsapp_templates(hospital_id);
CREATE INDEX IF NOT EXISTS idx_whatsapp_templates_status
    ON whatsapp_templates(status);

-- ----------------------------------------------------------------------
-- 3. WHATSAPP CAMPAIGNS
--    status: draft | scheduled | sending | sent | failed | cancelled
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS whatsapp_campaigns (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID NOT NULL REFERENCES hospitals(id) ON DELETE CASCADE,
    template_id UUID REFERENCES whatsapp_templates(id) ON DELETE SET NULL,
    name VARCHAR(255) NOT NULL,
    message_body TEXT NOT NULL DEFAULT '',
    recipients JSONB NOT NULL DEFAULT '[]'::jsonb,
    status VARCHAR(20) NOT NULL DEFAULT 'draft',
    sent_count INTEGER NOT NULL DEFAULT 0,
    delivered_count INTEGER NOT NULL DEFAULT 0,
    read_count INTEGER NOT NULL DEFAULT 0,
    failed_count INTEGER NOT NULL DEFAULT 0,
    scheduled_at TIMESTAMPTZ,
    sent_at TIMESTAMPTZ,
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_whatsapp_campaigns_hospital
    ON whatsapp_campaigns(hospital_id);
CREATE INDEX IF NOT EXISTS idx_whatsapp_campaigns_status
    ON whatsapp_campaigns(status);
CREATE INDEX IF NOT EXISTS idx_whatsapp_campaigns_scheduled
    ON whatsapp_campaigns(scheduled_at)
    WHERE status = 'scheduled';

-- ----------------------------------------------------------------------
-- 4. WHATSAPP MESSAGES (individual message logs)
--    status: sent | delivered | read | failed
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS whatsapp_messages (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID NOT NULL REFERENCES hospitals(id) ON DELETE CASCADE,
    campaign_id UUID REFERENCES whatsapp_campaigns(id) ON DELETE SET NULL,
    patient_id UUID REFERENCES patients(id) ON DELETE SET NULL,
    phone_number VARCHAR(20) NOT NULL,
    template_id UUID REFERENCES whatsapp_templates(id) ON DELETE SET NULL,
    message_body TEXT NOT NULL DEFAULT '',
    message_id VARCHAR(255),
    status VARCHAR(20) NOT NULL DEFAULT 'sent',
    error_message TEXT,
    sent_at TIMESTAMPTZ,
    delivered_at TIMESTAMPTZ,
    read_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_whatsapp_messages_hospital
    ON whatsapp_messages(hospital_id);
CREATE INDEX IF NOT EXISTS idx_whatsapp_messages_campaign
    ON whatsapp_messages(campaign_id);
CREATE INDEX IF NOT EXISTS idx_whatsapp_messages_patient
    ON whatsapp_messages(patient_id);
CREATE INDEX IF NOT EXISTS idx_whatsapp_messages_meta_id
    ON whatsapp_messages(message_id);
CREATE INDEX IF NOT EXISTS idx_whatsapp_messages_status
    ON whatsapp_messages(status);

-- ----------------------------------------------------------------------
-- 5. WHATSAPP OPT-OUTS (DND records)
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS whatsapp_opt_outs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID NOT NULL REFERENCES hospitals(id) ON DELETE CASCADE,
    patient_id UUID REFERENCES patients(id) ON DELETE CASCADE,
    phone_number VARCHAR(20) NOT NULL,
    opted_out_at TIMESTAMPTZ DEFAULT NOW(),
    reason TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (hospital_id, phone_number)
);

CREATE INDEX IF NOT EXISTS idx_whatsapp_opt_outs_hospital
    ON whatsapp_opt_outs(hospital_id);
CREATE INDEX IF NOT EXISTS idx_whatsapp_opt_outs_patient
    ON whatsapp_opt_outs(patient_id);

-- ----------------------------------------------------------------------
-- 6. updated_at AUTO TRIGGERS
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_whatsapp_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_whatsapp_settings_updated_at ON whatsapp_settings;
CREATE TRIGGER trg_whatsapp_settings_updated_at
    BEFORE UPDATE ON whatsapp_settings
    FOR EACH ROW EXECUTE FUNCTION set_whatsapp_updated_at();

DROP TRIGGER IF EXISTS trg_whatsapp_templates_updated_at ON whatsapp_templates;
CREATE TRIGGER trg_whatsapp_templates_updated_at
    BEFORE UPDATE ON whatsapp_templates
    FOR EACH ROW EXECUTE FUNCTION set_whatsapp_updated_at();

DROP TRIGGER IF EXISTS trg_whatsapp_campaigns_updated_at ON whatsapp_campaigns;
CREATE TRIGGER trg_whatsapp_campaigns_updated_at
    BEFORE UPDATE ON whatsapp_campaigns
    FOR EACH ROW EXECUTE FUNCTION set_whatsapp_updated_at();

-- ----------------------------------------------------------------------
-- 7. ROW LEVEL SECURITY (multi-tenant isolation)
-- ----------------------------------------------------------------------
ALTER TABLE whatsapp_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE whatsapp_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE whatsapp_campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE whatsapp_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE whatsapp_opt_outs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Enable all access for authenticated users on whatsapp_settings" ON whatsapp_settings;
CREATE POLICY "tenant_all_whatsapp_settings" ON whatsapp_settings
    FOR ALL TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1))
    WITH CHECK (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

DROP POLICY IF EXISTS "Enable all access for authenticated users on whatsapp_templates" ON whatsapp_templates;
CREATE POLICY "tenant_all_whatsapp_templates" ON whatsapp_templates
    FOR ALL TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1))
    WITH CHECK (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

DROP POLICY IF EXISTS "Enable all access for authenticated users on whatsapp_campaigns" ON whatsapp_campaigns;
CREATE POLICY "tenant_all_whatsapp_campaigns" ON whatsapp_campaigns
    FOR ALL TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1))
    WITH CHECK (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

DROP POLICY IF EXISTS "Enable all access for authenticated users on whatsapp_messages" ON whatsapp_messages;
CREATE POLICY "tenant_all_whatsapp_messages" ON whatsapp_messages
    FOR ALL TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1))
    WITH CHECK (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

DROP POLICY IF EXISTS "Enable all access for authenticated users on whatsapp_opt_outs" ON whatsapp_opt_outs;
CREATE POLICY "tenant_all_whatsapp_opt_outs" ON whatsapp_opt_outs
    FOR ALL TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1))
    WITH CHECK (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

-- ----------------------------------------------------------------------
-- 8. GRANTS
-- ----------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON whatsapp_settings TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON whatsapp_templates TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON whatsapp_campaigns TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON whatsapp_messages TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON whatsapp_opt_outs TO authenticated;
