-- ======================================================================
-- HIMS - IPD Doctor Selection & Doctor-Wise Charges
-- ----------------------------------------------------------------------
-- 1. doctors: doctor-wise charge columns + availability/patient-load columns
--    (round_charge, consultation_fee, emergency_fee, icu_visit_charge,
--     surgery_charge, followup_charge, home_visit_charge,
--     max_patients_per_day, current_patients)
-- 2. ipd_admissions: doctor_name persistence (so doctor display survives
--    even when the doctor row is edited/deleted later).
-- 3. ipd_admissions.doctor_id FK now points to doctors(id) instead of
--    users(id) — IPD admission screen selects from the doctors table.
--
-- Idempotent hai — Supabase SQL Editor / supabase db push dono mein safe.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. DOCTORS: doctor-wise charges + availability columns
-- ----------------------------------------------------------------------
ALTER TABLE public.doctors
    ADD COLUMN IF NOT EXISTS round_charge DECIMAL(10,2) DEFAULT 0,
    ADD COLUMN IF NOT EXISTS consultation_fee DECIMAL(10,2) DEFAULT 0,
    ADD COLUMN IF NOT EXISTS emergency_fee DECIMAL(10,2) DEFAULT 0,
    ADD COLUMN IF NOT EXISTS icu_visit_charge DECIMAL(10,2) DEFAULT 0,
    ADD COLUMN IF NOT EXISTS surgery_charge DECIMAL(10,2) DEFAULT 0,
    ADD COLUMN IF NOT EXISTS followup_charge DECIMAL(10,2) DEFAULT 0,
    ADD COLUMN IF NOT EXISTS home_visit_charge DECIMAL(10,2) DEFAULT 0,
    ADD COLUMN IF NOT EXISTS max_patients_per_day INTEGER DEFAULT 20,
    ADD COLUMN IF NOT EXISTS current_patients INTEGER DEFAULT 0;

-- ----------------------------------------------------------------------
-- 2. DOCTORS: validation constraints (idempotent)
-- ----------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'round_charge_positive'
    ) THEN
        ALTER TABLE public.doctors
            ADD CONSTRAINT round_charge_positive CHECK (round_charge >= 0);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'consultation_fee_positive'
    ) THEN
        ALTER TABLE public.doctors
            ADD CONSTRAINT consultation_fee_positive CHECK (consultation_fee >= 0);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'emergency_fee_positive'
    ) THEN
        ALTER TABLE public.doctors
            ADD CONSTRAINT emergency_fee_positive CHECK (emergency_fee >= 0);
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'max_patients_positive'
    ) THEN
        ALTER TABLE public.doctors
            ADD CONSTRAINT max_patients_positive CHECK (max_patients_per_day > 0);
    END IF;
END $$;

-- ----------------------------------------------------------------------
-- 3. IPD ADMISSIONS: doctor_name + department_name persistence
--    (department_id already exists; doctor_name is a snapshot of the
--    selected doctor for slips/billing headers.)
-- ----------------------------------------------------------------------
ALTER TABLE public.ipd_admissions
    ADD COLUMN IF NOT EXISTS doctor_name VARCHAR(255);

ALTER TABLE public.ipd_admissions
    ADD COLUMN IF NOT EXISTS department_name VARCHAR(255);

-- ----------------------------------------------------------------------
-- 4. IPD ADMISSIONS: doctor_id FK -> doctors(id)
--    Legacy FK (users.id) ko dynamic naam se drop karte hain kyunki live
--    deployments mein constraint ka naam alag ho sakta hai. NOT VALID isliye
--    use kiya hai taaki purane rows (jo users.id point karti hain) is
--    migration se block na hon.
-- ----------------------------------------------------------------------
DO $$
DECLARE
    fk record;
    has_doctors_fk boolean := false;
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_tables
        WHERE schemaname = 'public' AND tablename = 'doctors'
    ) THEN
        FOR fk IN
            SELECT c.conname AS conname,
                   c.confrelid AS target_relid
            FROM pg_constraint c
            JOIN pg_attribute a
              ON a.attrelid = c.conrelid AND a.attnum = ANY(c.conkey)
            WHERE c.conrelid = 'public.ipd_admissions'::regclass
              AND c.contype = 'f'
              AND a.attname = 'doctor_id'
        LOOP
            IF fk.target_relid = 'public.users'::regclass THEN
                EXECUTE format(
                    'ALTER TABLE public.ipd_admissions DROP CONSTRAINT %I',
                    fk.conname
                );
            ELSIF fk.target_relid = 'public.doctors'::regclass THEN
                has_doctors_fk := true;
            END IF;
        END LOOP;

        IF has_doctors_fk IS NOT TRUE THEN
            ALTER TABLE public.ipd_admissions
                ADD CONSTRAINT ipd_admissions_doctor_id_doctors_fkey
                FOREIGN KEY (doctor_id) REFERENCES public.doctors(id)
                ON DELETE SET NULL
                NOT VALID;
        END IF;
    END IF;
END $$;

-- ----------------------------------------------------------------------
-- 5. INDEXES
-- ----------------------------------------------------------------------
SELECT hims_create_index(
    'idx_ipd_admissions_doctor_id',
    'public.ipd_admissions',
    ARRAY['doctor_id'],
    'doctor_id'
);
