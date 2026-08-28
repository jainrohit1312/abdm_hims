-- ======================================================================
-- HIMS - Counseling Module: Visit-Specific Linking
-- ----------------------------------------------------------------------
-- Counseling is a visit-specific activity, not a patient-profile activity.
-- Every counseling record must now be tied to exactly one of:
--   * an OPD registration   (opd_registration_id + visit_type = 'opd')
--   * an IPD admission      (ipd_admission_id   + visit_type = 'ipd')
--
-- This migration:
--   1. Adds the two FK columns to public.counseling_records.
--   2. Indexes them so visit-scoped history stacks are fast.
--   3. Adds a CHECK constraint so NEW records always carry a visit link
--      (existing legacy rows are left untouched via NOT VALID).
--
-- Supabase Dashboard -> SQL Editor mein run karo. Idempotent hai.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. Visit link columns
-- ----------------------------------------------------------------------
ALTER TABLE public.counseling_records
    ADD COLUMN IF NOT EXISTS opd_registration_id UUID
        REFERENCES public.opd_registrations(id) ON DELETE SET NULL;

ALTER TABLE public.counseling_records
    ADD COLUMN IF NOT EXISTS ipd_admission_id UUID
        REFERENCES public.ipd_admissions(id) ON DELETE SET NULL;

-- ----------------------------------------------------------------------
-- 2. Indexes for visit-scoped lookups
-- ----------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_counseling_records_opd
    ON public.counseling_records(opd_registration_id);

CREATE INDEX IF NOT EXISTS idx_counseling_records_ipd
    ON public.counseling_records(ipd_admission_id);

-- ----------------------------------------------------------------------
-- 3. Constraint: every NEW counseling record must belong to a visit
--    (legacy rows created before this refactor keep NULL visit links).
-- ----------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'chk_counseling_visit_link'
          AND conrelid = 'public.counseling_records'::regclass
    ) THEN
        ALTER TABLE public.counseling_records
            ADD CONSTRAINT chk_counseling_visit_link
            CHECK (
                (visit_type = 'opd' AND opd_registration_id IS NOT NULL)
                OR
                (visit_type = 'ipd' AND ipd_admission_id IS NOT NULL)
            )
            NOT VALID;
    END IF;
END $$;
