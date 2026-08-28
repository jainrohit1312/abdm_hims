-- ======================================================================
-- HIMS - Clinical Counseling Documentation
-- ----------------------------------------------------------------------
-- Table: counseling_records
--   id, hospital_id, patient_id, visit_type (opd/ipd), counseling_date,
--   transcript_text, summary_text, doctor_id, created_at, updated_at
--
-- `hospital_id` is included so multi-tenant RLS (hospital data isolation)
-- works exactly like the other HIMS tables.
--
-- Supabase Dashboard -> SQL Editor mein run karo. Idempotent hai.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. TABLE
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.counseling_records (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES public.hospitals(id) ON DELETE SET NULL,
    patient_id UUID NOT NULL REFERENCES public.patients(id) ON DELETE CASCADE,
    visit_type VARCHAR(10) NOT NULL DEFAULT 'opd'
        CONSTRAINT chk_counseling_visit_type CHECK (visit_type IN ('opd', 'ipd')),
    counseling_date DATE NOT NULL DEFAULT CURRENT_DATE,
    transcript_text TEXT,
    summary_text TEXT,
    doctor_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ----------------------------------------------------------------------
-- 2. INDEXES
-- ----------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_counseling_records_patient
    ON public.counseling_records(patient_id);

CREATE INDEX IF NOT EXISTS idx_counseling_records_hospital
    ON public.counseling_records(hospital_id);

CREATE INDEX IF NOT EXISTS idx_counseling_records_date
    ON public.counseling_records(counseling_date);

-- ----------------------------------------------------------------------
-- 3. ROW LEVEL SECURITY (multi-tenant isolation)
--    Har hospital sirf apne patients ke counseling records dekh/change
--    kar sakta hai.
-- ----------------------------------------------------------------------
ALTER TABLE public.counseling_records ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "tenant_select_counseling_records"
    ON public.counseling_records;
CREATE POLICY "tenant_select_counseling_records" ON public.counseling_records
    FOR SELECT TO authenticated
    USING (hospital_id = (
        SELECT hospital_id FROM public.users
        WHERE auth_id = auth.uid()
        LIMIT 1
    ));

DROP POLICY IF EXISTS "tenant_insert_counseling_records"
    ON public.counseling_records;
CREATE POLICY "tenant_insert_counseling_records" ON public.counseling_records
    FOR INSERT TO authenticated
    WITH CHECK (hospital_id = (
        SELECT hospital_id FROM public.users
        WHERE auth_id = auth.uid()
        LIMIT 1
    ));

DROP POLICY IF EXISTS "tenant_update_counseling_records"
    ON public.counseling_records;
CREATE POLICY "tenant_update_counseling_records" ON public.counseling_records
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

DROP POLICY IF EXISTS "tenant_delete_counseling_records"
    ON public.counseling_records;
CREATE POLICY "tenant_delete_counseling_records" ON public.counseling_records
    FOR DELETE TO authenticated
    USING (hospital_id = (
        SELECT hospital_id FROM public.users
        WHERE auth_id = auth.uid()
        LIMIT 1
    ));

-- ----------------------------------------------------------------------
-- 4. GRANTS (newer Supabase versions default-deny public tables)
-- ----------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON public.counseling_records TO authenticated;
