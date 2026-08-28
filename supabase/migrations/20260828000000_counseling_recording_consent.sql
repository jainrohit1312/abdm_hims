-- ======================================================================
-- HIMS - AI-Powered Counseling Module: Recording, GPS & Consent
-- ----------------------------------------------------------------------
-- Tables:
--   * counseling_media   - video/audio recordings + GPS stamp metadata
--   * counseling_consents- auto-generated consent forms + signature state
-- Also extends counseling_records with duration_seconds.
--
-- Supabase Dashboard -> SQL Editor mein run karo. Idempotent hai.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. counseling_media
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.counseling_media (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES public.hospitals(id) ON DELETE SET NULL,
    counseling_record_id UUID
        REFERENCES public.counseling_records(id) ON DELETE CASCADE,
    patient_id UUID NOT NULL REFERENCES public.patients(id) ON DELETE CASCADE,
    media_type VARCHAR(10) NOT NULL DEFAULT 'video'
        CONSTRAINT chk_counseling_media_type
        CHECK (media_type IN ('video', 'audio')),
    file_url TEXT,
    local_file_path TEXT,
    duration_seconds INTEGER NOT NULL DEFAULT 0,
    file_size_bytes BIGINT NOT NULL DEFAULT 0,
    gps_latitude DOUBLE PRECISION,
    gps_longitude DOUBLE PRECISION,
    gps_accuracy DOUBLE PRECISION,
    gps_address TEXT,
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_counseling_media_record
    ON public.counseling_media(counseling_record_id);
CREATE INDEX IF NOT EXISTS idx_counseling_media_patient
    ON public.counseling_media(patient_id);
CREATE INDEX IF NOT EXISTS idx_counseling_media_hospital
    ON public.counseling_media(hospital_id);
CREATE INDEX IF NOT EXISTS idx_counseling_media_type
    ON public.counseling_media(media_type);

-- ----------------------------------------------------------------------
-- 2. counseling_consents
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.counseling_consents (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES public.hospitals(id) ON DELETE SET NULL,
    patient_id UUID NOT NULL REFERENCES public.patients(id) ON DELETE CASCADE,
    counseling_record_id UUID
        REFERENCES public.counseling_records(id) ON DELETE SET NULL,
    patient_name TEXT,
    uhid TEXT,
    hospital_name TEXT,
    doctor_name TEXT,
    consent_date DATE NOT NULL DEFAULT CURRENT_DATE,
    status VARCHAR(20) NOT NULL DEFAULT 'pending'
        CONSTRAINT chk_counseling_consent_status
        CHECK (status IN ('pending', 'signed', 'expired')),
    consent_version INTEGER NOT NULL DEFAULT 1,
    signed_consent_url TEXT,
    signature_data TEXT,
    signed_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_counseling_consents_record
    ON public.counseling_consents(counseling_record_id);
CREATE INDEX IF NOT EXISTS idx_counseling_consents_patient
    ON public.counseling_consents(patient_id);
CREATE INDEX IF NOT EXISTS idx_counseling_consents_hospital
    ON public.counseling_consents(hospital_id);
CREATE INDEX IF NOT EXISTS idx_counseling_consents_status
    ON public.counseling_consents(status);

-- ----------------------------------------------------------------------
-- 3. Extend counseling_records
-- ----------------------------------------------------------------------
ALTER TABLE public.counseling_records
    ADD COLUMN IF NOT EXISTS duration_seconds INTEGER NOT NULL DEFAULT 0;

-- ----------------------------------------------------------------------
-- 4. ROW LEVEL SECURITY (multi-tenant isolation)
-- ----------------------------------------------------------------------
ALTER TABLE public.counseling_media ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tenant_select_counseling_media"
    ON public.counseling_media;
CREATE POLICY "tenant_select_counseling_media" ON public.counseling_media
    FOR SELECT TO authenticated
    USING (hospital_id = (
        SELECT hospital_id FROM public.users
        WHERE auth_id = auth.uid()
        LIMIT 1
    ));

DROP POLICY IF EXISTS "tenant_insert_counseling_media"
    ON public.counseling_media;
CREATE POLICY "tenant_insert_counseling_media" ON public.counseling_media
    FOR INSERT TO authenticated
    WITH CHECK (hospital_id = (
        SELECT hospital_id FROM public.users
        WHERE auth_id = auth.uid()
        LIMIT 1
    ));

DROP POLICY IF EXISTS "tenant_update_counseling_media"
    ON public.counseling_media;
CREATE POLICY "tenant_update_counseling_media" ON public.counseling_media
    FOR UPDATE TO authenticated
    USING (hospital_id = (
        SELECT hospital_id FROM public.users
        WHERE auth_id = auth.uid()
        LIMIT 1
    ))
    WITH CHECK (hospital_id = (
        SELECT hospital_id FROM public.users
        WHERE auth_id = auth.uid()
        LIMIT 1
    ));

DROP POLICY IF EXISTS "tenant_delete_counseling_media"
    ON public.counseling_media;
CREATE POLICY "tenant_delete_counseling_media" ON public.counseling_media
    FOR DELETE TO authenticated
    USING (hospital_id = (
        SELECT hospital_id FROM public.users
        WHERE auth_id = auth.uid()
        LIMIT 1
    ));

ALTER TABLE public.counseling_consents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tenant_select_counseling_consents"
    ON public.counseling_consents;
CREATE POLICY "tenant_select_counseling_consents" ON public.counseling_consents
    FOR SELECT TO authenticated
    USING (hospital_id = (
        SELECT hospital_id FROM public.users
        WHERE auth_id = auth.uid()
        LIMIT 1
    ));

DROP POLICY IF EXISTS "tenant_insert_counseling_consents"
    ON public.counseling_consents;
CREATE POLICY "tenant_insert_counseling_consents" ON public.counseling_consents
    FOR INSERT TO authenticated
    WITH CHECK (hospital_id = (
        SELECT hospital_id FROM public.users
        WHERE auth_id = auth.uid()
        LIMIT 1
    ));

DROP POLICY IF EXISTS "tenant_update_counseling_consents"
    ON public.counseling_consents;
CREATE POLICY "tenant_update_counseling_consents" ON public.counseling_consents
    FOR UPDATE TO authenticated
    USING (hospital_id = (
        SELECT hospital_id FROM public.users
        WHERE auth_id = auth.uid()
        LIMIT 1
    ))
    WITH CHECK (hospital_id = (
        SELECT hospital_id FROM public.users
        WHERE auth_id = auth.uid()
        LIMIT 1
    ));

DROP POLICY IF EXISTS "tenant_delete_counseling_consents"
    ON public.counseling_consents;
CREATE POLICY "tenant_delete_counseling_consents" ON public.counseling_consents
    FOR DELETE TO authenticated
    USING (hospital_id = (
        SELECT hospital_id FROM public.users
        WHERE auth_id = auth.uid()
        LIMIT 1
    ));

-- ----------------------------------------------------------------------
-- 5. GRANTS
-- ----------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON public.counseling_media TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.counseling_consents TO authenticated;

-- ----------------------------------------------------------------------
-- 6. STORAGE policies for the counseling folder in hims-storage
-- ----------------------------------------------------------------------
INSERT INTO storage.buckets (id, name, public)
VALUES ('hims-storage', 'hims-storage', TRUE)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS "counseling_storage_upload" ON storage.objects;
CREATE POLICY "counseling_storage_upload" ON storage.objects
    FOR INSERT TO authenticated
    WITH CHECK (
        bucket_id = 'hims-storage'
        AND (storage.foldername(name))[1] = 'counseling'
    );

DROP POLICY IF EXISTS "counseling_storage_select" ON storage.objects;
CREATE POLICY "counseling_storage_select" ON storage.objects
    FOR SELECT TO authenticated
    USING (
        bucket_id = 'hims-storage'
        AND (storage.foldername(name))[1] = 'counseling'
    );

DROP POLICY IF EXISTS "counseling_storage_delete" ON storage.objects;
CREATE POLICY "counseling_storage_delete" ON storage.objects
    FOR DELETE TO authenticated
    USING (
        bucket_id = 'hims-storage'
        AND (storage.foldername(name))[1] = 'counseling'
    );
