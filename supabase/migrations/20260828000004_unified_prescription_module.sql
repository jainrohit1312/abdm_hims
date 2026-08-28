-- ======================================================================
-- HIMS - Unified Prescription Module (OPD + IPD)
-- ----------------------------------------------------------------------
-- One `prescriptions` table ab dono visit contexts handle karti hai:
--
--   * OPD Prescription -> poori clinical document:
--       history + investigations + medicines + advice
--   * IPD Prescription -> sirf medicines
--       (History / Investigations / Advice IPD mein dusre modules
--        sambhalte hain — ipd_vitals, ipd_progress_notes, ipd_reports,
--        discharge summary, etc.)
--
-- Naya JSONB section layout:
--   history         = { chief_complaints, history_presenting_illness,
--                       past_history, personal_history, family_history,
--                       allergies, examination_findings }
--   investigations  = { lab_tests[], radiology[], other_investigations[] }
--   medicines       = [ { medicine_name, generic_name, strength, dosage,
--                         frequency, duration, route, instructions,
--                         custom_times[] } ]
--   advice          = { follow_up_date, dietary_advice, activity_advice,
--                       other_advice }
--
-- Ye migration idempotent hai. Purane `clinical_notes` JSONB aur
-- `prescription_items` line items se data backfill karta hai taaki
-- existing prescriptions naye columns mein bhi dikhein.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. CONTEXT + SECTION COLUMNS
-- ----------------------------------------------------------------------

ALTER TABLE public.prescriptions
    ADD COLUMN IF NOT EXISTS visit_type VARCHAR(10);

-- Existing rows ke liye CHECK constraint add karne se pehle NULLs handle
-- karo, phir constraint lagao (sirf tab jab wo pehle se na ho).
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'prescriptions_visit_type_check'
          AND conrelid = 'public.prescriptions'::regclass
    ) THEN
        ALTER TABLE public.prescriptions
            ADD CONSTRAINT prescriptions_visit_type_check
            CHECK (visit_type IN ('opd', 'ipd'));
    END IF;
END $$;

ALTER TABLE public.prescriptions
    ADD COLUMN IF NOT EXISTS history JSONB DEFAULT '{}'::jsonb;

ALTER TABLE public.prescriptions
    ADD COLUMN IF NOT EXISTS investigations JSONB DEFAULT '{}'::jsonb;

ALTER TABLE public.prescriptions
    ADD COLUMN IF NOT EXISTS medicines JSONB DEFAULT '[]'::jsonb;

ALTER TABLE public.prescriptions
    ADD COLUMN IF NOT EXISTS advice JSONB DEFAULT '{}'::jsonb;

ALTER TABLE public.prescriptions
    ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES public.users(id) ON DELETE SET NULL;

-- ----------------------------------------------------------------------
-- 2. STATUS CHECK (legacy column ko requested values tak normalize karo)
-- ----------------------------------------------------------------------
UPDATE public.prescriptions
SET status = 'active'
WHERE status IS NULL OR status NOT IN ('active', 'completed', 'cancelled');

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'prescriptions_status_check'
          AND conrelid = 'public.prescriptions'::regclass
    ) THEN
        ALTER TABLE public.prescriptions
            ADD CONSTRAINT prescriptions_status_check
            CHECK (status IN ('active', 'completed', 'cancelled'));
    END IF;
END $$;

-- ----------------------------------------------------------------------
-- 3. BACKFILL visit_type
-- ----------------------------------------------------------------------
UPDATE public.prescriptions
SET visit_type = 'ipd'
WHERE visit_type IS NULL
  AND ipd_admission_id IS NOT NULL;

UPDATE public.prescriptions
SET visit_type = 'opd'
WHERE visit_type IS NULL
  AND opd_registration_id IS NOT NULL;

-- Bache hue (kisi bhi visit se linked nahi) default OPD maan lo.
UPDATE public.prescriptions
SET visit_type = 'opd'
WHERE visit_type IS NULL;

ALTER TABLE public.prescriptions
    ALTER COLUMN visit_type SET DEFAULT 'opd';

ALTER TABLE public.prescriptions
    ALTER COLUMN visit_type SET NOT NULL;

-- ----------------------------------------------------------------------
-- 4. BACKFILL medicines JSONB from prescription_items (legacy line items)
-- ----------------------------------------------------------------------
WITH grouped_items AS (
    SELECT
        prescription_id,
        jsonb_agg(
            jsonb_build_object(
                'medicine_name', COALESCE(medicine_name, ''),
                'generic_name', NULL,
                'strength', NULL,
                'dosage', COALESCE(dosage, ''),
                'frequency', COALESCE(frequency, ''),
                'duration', COALESCE(duration, ''),
                'route', NULL,
                'instructions', COALESCE(instructions, ''),
                'custom_times', COALESCE(custom_times, '[]'::jsonb)
            )
            ORDER BY created_at ASC, id ASC
        ) AS medicines_json
    FROM public.prescription_items
    GROUP BY prescription_id
)
UPDATE public.prescriptions p
SET medicines = gi.medicines_json
FROM grouped_items gi
WHERE p.id = gi.prescription_id
  AND (p.medicines IS NULL OR p.medicines = '[]'::jsonb);

-- Jin prescriptions mein items nahi the lekin legacy medicine_name column
-- bhara hai, unka single-medicine array bana do.
UPDATE public.prescriptions p
SET medicines = jsonb_build_array(
    jsonb_build_object(
        'medicine_name', COALESCE(NULLIF(p.medicine_name, 'No medicines prescribed'), p.medicine_name),
        'generic_name', NULL,
        'strength', NULL,
        'dosage', p.dosage,
        'frequency', p.frequency,
        'duration', p.duration,
        'route', p.route,
        'instructions', p.instructions,
        'custom_times', '[]'::jsonb
    )
)
WHERE (p.medicines IS NULL OR p.medicines = '[]'::jsonb)
  AND p.medicine_name IS NOT NULL
  AND p.medicine_name <> ''
  AND p.medicine_name <> 'No medicines prescribed';

-- ----------------------------------------------------------------------
-- 5. BACKFILL history / investigations / advice from clinical_notes
-- ----------------------------------------------------------------------

-- 5a. history  ---------------------------------------------------------
UPDATE public.prescriptions p
SET history = jsonb_build_object(
        'chief_complaints', COALESCE(p.clinical_notes->>'chief_complaints', ''),
        'history_presenting_illness', COALESCE(p.clinical_notes->>'hopi', ''),
        'past_history', COALESCE(p.clinical_notes->>'past_history', ''),
        'personal_history', COALESCE(p.clinical_notes->>'personal_family_history', ''),
        'family_history', '',
        'allergies', COALESCE(p.clinical_notes->>'drug_allergy', ''),
        'examination_findings', COALESCE(p.clinical_notes->>'examination', '')
    )
    || jsonb_build_object('diagnosis', COALESCE(p.clinical_notes->>'diagnosis', ''))
    || jsonb_build_object(
           'vitals',
           CASE
               WHEN p.clinical_notes ? 'vitals' THEN p.clinical_notes->'vitals'
               ELSE '{}'::jsonb
           END
       )
WHERE p.clinical_notes IS NOT NULL
  AND p.clinical_notes <> '{}'::jsonb
  AND (p.history IS NULL OR p.history = '{}'::jsonb);

-- 5b. investigations ---------------------------------------------------
UPDATE public.prescriptions p
SET investigations = jsonb_build_object(
    'lab_tests',
    CASE
        WHEN p.clinical_notes->'investigations' ? 'blood'
        THEN COALESCE(p.clinical_notes->'investigations'->'blood', '[]'::jsonb)
        ELSE '[]'::jsonb
    END,
    'radiology',
    CASE
        WHEN p.clinical_notes->'investigations' ? 'radiology'
        THEN COALESCE(p.clinical_notes->'investigations'->'radiology', '[]'::jsonb)
        ELSE '[]'::jsonb
    END,
    'other_investigations',
    CASE
        WHEN p.clinical_notes->'investigations' ? 'previous_findings'
        THEN jsonb_build_array(p.clinical_notes->'investigations'->>'previous_findings')
        ELSE '[]'::jsonb
    END
)
WHERE p.clinical_notes IS NOT NULL
  AND p.clinical_notes <> '{}'::jsonb
  AND (p.investigations IS NULL OR p.investigations = '{}'::jsonb);

-- 5c. advice -----------------------------------------------------------
UPDATE public.prescriptions p
SET advice = jsonb_build_object(
        'follow_up_date', '',
        'dietary_advice', '',
        'activity_advice', '',
        'other_advice', COALESCE(p.clinical_notes->>'advice', '')
    )
    || jsonb_build_object('follow_up', COALESCE(p.clinical_notes->>'follow_up', ''))
WHERE p.clinical_notes IS NOT NULL
  AND p.clinical_notes <> '{}'::jsonb
  AND (p.advice IS NULL OR p.advice = '{}'::jsonb);

-- Empty-string keys ko clean karo taaki print/UI ko sirf data dikhe.
-- NOTE: jsonb comparison ke liye '' nahi — '""'::jsonb chahiye (empty JSON
-- string). Raw '' Postgres mein invalid json literal hai.
UPDATE public.prescriptions
SET history = COALESCE(
    (SELECT jsonb_object_agg(key, value)
     FROM jsonb_each(history)
     WHERE value <> '""'::jsonb
       AND value <> '{}'::jsonb
       AND value <> '[]'::jsonb),
    '{}'::jsonb
)
WHERE history IS NOT NULL;

UPDATE public.prescriptions
SET investigations = COALESCE(
    (SELECT jsonb_object_agg(key, value)
     FROM jsonb_each(investigations)
     WHERE value <> '""'::jsonb
       AND value <> '{}'::jsonb
       AND value <> '[]'::jsonb),
    '{}'::jsonb
)
WHERE investigations IS NOT NULL;

UPDATE public.prescriptions
SET advice = COALESCE(
    (SELECT jsonb_object_agg(key, value)
     FROM jsonb_each(advice)
     WHERE value <> '""'::jsonb
       AND value <> '{}'::jsonb
       AND value <> '[]'::jsonb),
    '{}'::jsonb
)
WHERE advice IS NOT NULL;

-- ----------------------------------------------------------------------
-- 6. INDEXES
-- ----------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_prescriptions_patient
    ON public.prescriptions(patient_id);

CREATE INDEX IF NOT EXISTS idx_prescriptions_opd
    ON public.prescriptions(opd_registration_id);

CREATE INDEX IF NOT EXISTS idx_prescriptions_ipd
    ON public.prescriptions(ipd_admission_id);

CREATE INDEX IF NOT EXISTS idx_prescriptions_date
    ON public.prescriptions(prescription_date);

CREATE INDEX IF NOT EXISTS idx_prescriptions_visit_type
    ON public.prescriptions(visit_type);

CREATE INDEX IF NOT EXISTS idx_prescriptions_medicines_gin
    ON public.prescriptions USING GIN (medicines);

CREATE INDEX IF NOT EXISTS idx_prescriptions_history_gin
    ON public.prescriptions USING GIN (history);

-- ----------------------------------------------------------------------
-- 7. TRIGGER: updated_at auto-touch
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hims_prescriptions_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_prescriptions_set_updated_at ON public.prescriptions;
CREATE TRIGGER trg_prescriptions_set_updated_at
    BEFORE UPDATE ON public.prescriptions
    FOR EACH ROW
    EXECUTE FUNCTION hims_prescriptions_set_updated_at();

-- ----------------------------------------------------------------------
-- 8. GRANTS (newer Supabase versions default-deny; prescriptions already
--    granted in earlier migrations, but keep this idempotent + safe)
-- ----------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON public.prescriptions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.prescription_items TO authenticated;
