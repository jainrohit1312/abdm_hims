-- ======================================================================
-- HIMS - PRO / Marketing Module
--
-- Domain: REFERRAL DOCTORS are a completely separate domain. These are
-- external doctors/clinics that refer patients to the hospital. They are
-- NOT hospital doctors and are never mixed with the `doctors` table or
-- any internal OPD/IPD doctor master.
--
-- Tables:
--   marketing_areas
--     Field-work areas (Govardhan, Vrindavan, Barsana, Mathura, Raya...).
--   referral_doctors
--     Referral doctor master. One primary marketing area per doctor.
--     Stores the official geofence point (lat/lng + radius) used for
--     visit-punch verification.
--   marketing_visits
--     Visit punches. Location is captured ONLY at punch time; there is no
--     continuous/live location tracking and no location history table.
--   patient_referrals
--     Event/visit based patient referral history. Patient master has NO
--     permanent referral-doctor field.
--
-- Location privacy rule:
--   * location columns are written once per visit punch (or once per
--     first-time clinic-location setup on the referral doctor master),
--   * there is no movement route, no heartbeat, no background tracking,
--   * normal visit punches never overwrite the referral doctor's master
--     coordinates.
--
-- RLS: every policy filters by hospital_id = public.current_user_hospital_id().
--      Hospital A can never read Hospital B's marketing data.
--
-- Run manually in Supabase SQL Editor, or `supabase db push`.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. MARKETING AREAS
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.marketing_areas (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID NOT NULL REFERENCES public.hospitals(id) ON DELETE CASCADE,
    name VARCHAR(100) NOT NULL,
    code VARCHAR(50),
    description TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT uq_marketing_areas_hospital_name UNIQUE (hospital_id, name)
);

CREATE INDEX IF NOT EXISTS idx_marketing_areas_hospital_name
    ON public.marketing_areas(hospital_id, name);

-- ----------------------------------------------------------------------
-- 2. REFERRAL DOCTOR MASTER (separate from hospital `doctors` table)
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.referral_doctors (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID NOT NULL REFERENCES public.hospitals(id) ON DELETE CASCADE,
    name VARCHAR(150) NOT NULL,
    clinic_name VARCHAR(200),
    practitioner_type VARCHAR(30) NOT NULL DEFAULT 'clinic'
        CHECK (practitioner_type IN
               ('registered_practitioner', 'local_practitioner', 'clinic', 'other')),
    registration_number VARCHAR(100),
    mobile_number VARCHAR(20),
    alternate_mobile VARCHAR(20),
    area_id UUID REFERENCES public.marketing_areas(id) ON DELETE SET NULL,
    village VARCHAR(100),
    address TEXT,
    city VARCHAR(100),
    pincode VARCHAR(10),
    -- Official geofence point. Written once during first-time clinic-location
    -- setup, or explicitly edited by a HIMS admin when the clinic shifts.
    -- Visit punches NEVER overwrite these master coordinates.
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    geo_radius_meters INTEGER NOT NULL DEFAULT 150,
    location_verified BOOLEAN NOT NULL DEFAULT FALSE,
    location_verified_at TIMESTAMPTZ,
    location_verified_by UUID REFERENCES public.users(id) ON DELETE SET NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_referral_doctors_hospital_area_active
    ON public.referral_doctors(hospital_id, area_id, is_active);

CREATE INDEX IF NOT EXISTS idx_referral_doctors_hospital_name
    ON public.referral_doctors(hospital_id, name);

-- ----------------------------------------------------------------------
-- 3. MARKETING VISITS (visit punch only — no continuous tracking)
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.marketing_visits (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID NOT NULL REFERENCES public.hospitals(id) ON DELETE CASCADE,
    marketing_employee_id UUID REFERENCES public.employees(id) ON DELETE SET NULL,
    -- RESTRICT so visit history is never silently lost when a doctor is
    -- deleted; inactive doctors remain usable via is_active = false.
    referral_doctor_id UUID NOT NULL REFERENCES public.referral_doctors(id) ON DELETE RESTRICT,
    area_id UUID REFERENCES public.marketing_areas(id) ON DELETE SET NULL,
    visited_at TIMESTAMPTZ NOT NULL,
    -- Employee location captured ONLY at the moment of the visit punch.
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    distance_from_doctor_meters DOUBLE PRECISION,
    geofence_radius_meters INTEGER,
    geo_verified BOOLEAN NOT NULL DEFAULT FALSE,
    -- Extensible source (open for extension — no CHECK list):
    --   mobile_app  (future Android PRO app)
    --   admin_entry (HIMS manual entry)
    visit_source VARCHAR(20) NOT NULL DEFAULT 'mobile_app',
    visit_purpose VARCHAR(100),
    visit_notes TEXT,
    next_follow_up_date DATE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_marketing_visits_hospital_visited
    ON public.marketing_visits(hospital_id, visited_at DESC);

CREATE INDEX IF NOT EXISTS idx_marketing_visits_hospital_doctor_visited
    ON public.marketing_visits(hospital_id, referral_doctor_id, visited_at DESC);

CREATE INDEX IF NOT EXISTS idx_marketing_visits_hospital_employee_visited
    ON public.marketing_visits(hospital_id, marketing_employee_id, visited_at DESC);

-- ----------------------------------------------------------------------
-- 4. PATIENT REFERRAL HISTORY (event/visit based — NOT a patient field)
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.patient_referrals (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID NOT NULL REFERENCES public.hospitals(id) ON DELETE CASCADE,
    -- RESTRICT: deleting a patient/doctor must not silently erase referral
    -- history. Inactivate/retain the master instead.
    patient_id UUID NOT NULL REFERENCES public.patients(id) ON DELETE RESTRICT,
    referral_doctor_id UUID NOT NULL REFERENCES public.referral_doctors(id) ON DELETE RESTRICT,
    marketing_employee_id UUID REFERENCES public.employees(id) ON DELETE SET NULL,
    referral_date DATE NOT NULL DEFAULT CURRENT_DATE,
    opd_registration_id UUID REFERENCES public.opd_registrations(id) ON DELETE SET NULL,
    ipd_admission_id UUID REFERENCES public.ipd_admissions(id) ON DELETE SET NULL,
    -- Extensible source (open for extension — no CHECK list):
    --   admin_entry (HIMS)
    --   mobile_app  (future Android PRO app)
    source VARCHAR(20) NOT NULL DEFAULT 'admin_entry',
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_patient_referrals_hospital_date
    ON public.patient_referrals(hospital_id, referral_date DESC);

CREATE INDEX IF NOT EXISTS idx_patient_referrals_hospital_doctor_date
    ON public.patient_referrals(hospital_id, referral_doctor_id, referral_date DESC);

CREATE INDEX IF NOT EXISTS idx_patient_referrals_hospital_patient
    ON public.patient_referrals(hospital_id, patient_id);

-- ----------------------------------------------------------------------
-- 5. GRANTS (new tables are exposed to the Data API explicitly)
-- ----------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON public.marketing_areas TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.referral_doctors TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.marketing_visits TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.patient_referrals TO authenticated;

-- ----------------------------------------------------------------------
-- 6. RLS — MARKETING AREAS
-- ----------------------------------------------------------------------
ALTER TABLE public.marketing_areas ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "marketing_areas_select_hospital" ON public.marketing_areas;
CREATE POLICY "marketing_areas_select_hospital"
    ON public.marketing_areas
    FOR SELECT
    TO authenticated
    USING (hospital_id = public.current_user_hospital_id());

DROP POLICY IF EXISTS "marketing_areas_insert_hospital" ON public.marketing_areas;
CREATE POLICY "marketing_areas_insert_hospital"
    ON public.marketing_areas
    FOR INSERT
    TO authenticated
    WITH CHECK (hospital_id = public.current_user_hospital_id());

DROP POLICY IF EXISTS "marketing_areas_update_hospital" ON public.marketing_areas;
CREATE POLICY "marketing_areas_update_hospital"
    ON public.marketing_areas
    FOR UPDATE
    TO authenticated
    USING (hospital_id = public.current_user_hospital_id())
    WITH CHECK (hospital_id = public.current_user_hospital_id());

DROP POLICY IF EXISTS "marketing_areas_delete_hospital" ON public.marketing_areas;
CREATE POLICY "marketing_areas_delete_hospital"
    ON public.marketing_areas
    FOR DELETE
    TO authenticated
    USING (hospital_id = public.current_user_hospital_id());

-- ----------------------------------------------------------------------
-- 7. RLS — REFERRAL DOCTORS
-- ----------------------------------------------------------------------
ALTER TABLE public.referral_doctors ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "referral_doctors_select_hospital" ON public.referral_doctors;
CREATE POLICY "referral_doctors_select_hospital"
    ON public.referral_doctors
    FOR SELECT
    TO authenticated
    USING (hospital_id = public.current_user_hospital_id());

DROP POLICY IF EXISTS "referral_doctors_insert_hospital" ON public.referral_doctors;
CREATE POLICY "referral_doctors_insert_hospital"
    ON public.referral_doctors
    FOR INSERT
    TO authenticated
    WITH CHECK (hospital_id = public.current_user_hospital_id());

DROP POLICY IF EXISTS "referral_doctors_update_hospital" ON public.referral_doctors;
CREATE POLICY "referral_doctors_update_hospital"
    ON public.referral_doctors
    FOR UPDATE
    TO authenticated
    USING (hospital_id = public.current_user_hospital_id())
    WITH CHECK (hospital_id = public.current_user_hospital_id());

DROP POLICY IF EXISTS "referral_doctors_delete_hospital" ON public.referral_doctors;
CREATE POLICY "referral_doctors_delete_hospital"
    ON public.referral_doctors
    FOR DELETE
    TO authenticated
    USING (hospital_id = public.current_user_hospital_id());

-- ----------------------------------------------------------------------
-- 8. RLS — MARKETING VISITS
-- ----------------------------------------------------------------------
ALTER TABLE public.marketing_visits ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "marketing_visits_select_hospital" ON public.marketing_visits;
CREATE POLICY "marketing_visits_select_hospital"
    ON public.marketing_visits
    FOR SELECT
    TO authenticated
    USING (hospital_id = public.current_user_hospital_id());

DROP POLICY IF EXISTS "marketing_visits_insert_hospital" ON public.marketing_visits;
CREATE POLICY "marketing_visits_insert_hospital"
    ON public.marketing_visits
    FOR INSERT
    TO authenticated
    WITH CHECK (hospital_id = public.current_user_hospital_id());

DROP POLICY IF EXISTS "marketing_visits_update_hospital" ON public.marketing_visits;
CREATE POLICY "marketing_visits_update_hospital"
    ON public.marketing_visits
    FOR UPDATE
    TO authenticated
    USING (hospital_id = public.current_user_hospital_id())
    WITH CHECK (hospital_id = public.current_user_hospital_id());

DROP POLICY IF EXISTS "marketing_visits_delete_hospital" ON public.marketing_visits;
CREATE POLICY "marketing_visits_delete_hospital"
    ON public.marketing_visits
    FOR DELETE
    TO authenticated
    USING (hospital_id = public.current_user_hospital_id());

-- ----------------------------------------------------------------------
-- 9. RLS — PATIENT REFERRALS
-- ----------------------------------------------------------------------
ALTER TABLE public.patient_referrals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "patient_referrals_select_hospital" ON public.patient_referrals;
CREATE POLICY "patient_referrals_select_hospital"
    ON public.patient_referrals
    FOR SELECT
    TO authenticated
    USING (hospital_id = public.current_user_hospital_id());

DROP POLICY IF EXISTS "patient_referrals_insert_hospital" ON public.patient_referrals;
CREATE POLICY "patient_referrals_insert_hospital"
    ON public.patient_referrals
    FOR INSERT
    TO authenticated
    WITH CHECK (hospital_id = public.current_user_hospital_id());

DROP POLICY IF EXISTS "patient_referrals_update_hospital" ON public.patient_referrals;
CREATE POLICY "patient_referrals_update_hospital"
    ON public.patient_referrals
    FOR UPDATE
    TO authenticated
    USING (hospital_id = public.current_user_hospital_id())
    WITH CHECK (hospital_id = public.current_user_hospital_id());

DROP POLICY IF EXISTS "patient_referrals_delete_hospital" ON public.patient_referrals;
CREATE POLICY "patient_referrals_delete_hospital"
    ON public.patient_referrals
    FOR DELETE
    TO authenticated
    USING (hospital_id = public.current_user_hospital_id());
