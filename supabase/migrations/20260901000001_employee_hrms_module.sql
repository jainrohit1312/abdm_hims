-- ======================================================================
-- HIMS - Employee / HRMS Module (Employee Master + Attendance + Salary)
--
-- Tables:
--   employees
--     Employee master. An employee is NOT a HIMS login user; an employee
--     may or may not have a HIMS login. `/users` continues to hold login
--     accounts only.
--   employee_attendance_punches
--     Raw punch events (source of truth). The future Android face-attendance
--     kiosk app writes rows into this table directly (source = 'face_kiosk').
--   employee_code_counters
--     Hospital-wise sequence counter used by next_employee_code() so
--     employee codes (EMP-0001, EMP-0002, ...) are generated atomically
--     inside the database instead of using count(*)+1 (which is racy).
--
-- Employee code strategy (documented):
--   * next_employee_code(p_hospital_id) upserts the per-hospital counter row
--     and returns the incremented number in ONE statement:
--         INSERT ... ON CONFLICT (hospital_id)
--         DO UPDATE SET last_number = employee_code_counters.last_number + 1
--         RETURNING last_number
--     That single statement is atomic (row lock on the counter row), so two
--     concurrent inserts can never produce the same code.
--   * The returned number is formatted as EMP-0001, EMP-0002, ...
--   * The unique constraint (hospital_id, employee_code) is a second safety
--     net. If an insert fails for any other reason the number is simply
--     skipped — gap-free sequences are not required.
--
-- Attendance sources (open for extension — OCP):
--   The `source` column is intentionally NOT constrained by a CHECK list.
--   Today:  face_kiosk (Android kiosk app), manual_admin (future HIMS use).
--   Future: biometric_device, mobile_app — can be written without a new
--   migration and without touching AttendanceCalculator / SalaryCalculator.
--
-- Future Android kiosk payload (contract):
--   POST /rest/v1/employee_attendance_punches
--   {
--     "hospital_id":  "<uuid>",
--     "employee_id":  "<uuid>",
--     "punched_at":   "2026-09-01T09:00:00+05:30",
--     "punch_type":   "in" | "out",
--     "source":       "face_kiosk",
--     "device_id":    "KIOSK-01"
--   }
--   Kiosk authentication (service-role free) will be added as a separate,
--   scoped auth/RPC later. RLS stays ENABLED; no service_role key is used
--   by the HIMS app.
--
-- RLS: every policy filters by hospital_id = current_user_hospital_id(),
--      the SECURITY DEFINER helper created in
--      20260825000006_hospital_onboarding_user_management.sql.
--
-- Run manually in Supabase SQL Editor, or `supabase db push`.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. EMPLOYEES (employee master)
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.employees (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID NOT NULL REFERENCES public.hospitals(id) ON DELETE CASCADE,
    employee_code VARCHAR(50) NOT NULL,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100),
    mobile_number VARCHAR(20),
    department_id UUID REFERENCES public.departments(id) ON DELETE SET NULL,
    designation VARCHAR(100),
    monthly_salary NUMERIC(12, 2) NOT NULL DEFAULT 0,
    joining_date DATE NOT NULL DEFAULT CURRENT_DATE,
    relieving_date DATE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    -- Backend metadata only — never shown/edited in HIMS UI. The Android
    -- kiosk fills these after face enrollment.
    face_reference_id VARCHAR(255),
    face_enrolled BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    CONSTRAINT uq_employees_hospital_code UNIQUE (hospital_id, employee_code),
    CONSTRAINT chk_employees_relieving_after_joining
        CHECK (relieving_date IS NULL OR relieving_date >= joining_date)
);

CREATE INDEX IF NOT EXISTS idx_employees_hospital_active
    ON public.employees(hospital_id, is_active);

-- ----------------------------------------------------------------------
-- 2. RAW ATTENDANCE PUNCH EVENTS (source of truth)
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.employee_attendance_punches (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID NOT NULL REFERENCES public.hospitals(id) ON DELETE CASCADE,
    employee_id UUID NOT NULL REFERENCES public.employees(id) ON DELETE CASCADE,
    punched_at TIMESTAMPTZ NOT NULL,
    punch_type VARCHAR(10) NOT NULL CHECK (punch_type IN ('in', 'out')),
    source VARCHAR(30) NOT NULL DEFAULT 'face_kiosk',
    device_id VARCHAR(100),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_att_punches_hospital_employee_punched
    ON public.employee_attendance_punches(hospital_id, employee_id, punched_at);

CREATE INDEX IF NOT EXISTS idx_att_punches_hospital_punched
    ON public.employee_attendance_punches(hospital_id, punched_at);

-- ----------------------------------------------------------------------
-- 3. EMPLOYEE CODE COUNTERS + SAFE SEQUENCE FUNCTION
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.employee_code_counters (
    hospital_id UUID PRIMARY KEY REFERENCES public.hospitals(id) ON DELETE CASCADE,
    last_number INTEGER NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- The app never reads/writes this table directly; only the function below
-- touches it, so RLS can be left with zero policies.
ALTER TABLE public.employee_code_counters ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.next_employee_code(p_hospital_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_number INTEGER;
BEGIN
    -- The function bypasses RLS (SECURITY DEFINER), so we must enforce the
    -- tenant boundary ourselves: a HIMS user may only mint codes for their
    -- own hospital.
    IF p_hospital_id IS NULL
       OR p_hospital_id IS DISTINCT FROM public.current_user_hospital_id() THEN
        RAISE EXCEPTION 'Cannot generate employee code for another hospital';
    END IF;

    -- Atomic per-hospital counter. The INSERT..ON CONFLICT..DO UPDATE..RETURNING
    -- takes a row lock on the counter row, making concurrent generation safe.
    INSERT INTO public.employee_code_counters (hospital_id, last_number)
    VALUES (p_hospital_id, 1)
    ON CONFLICT (hospital_id)
    DO UPDATE SET
        last_number = public.employee_code_counters.last_number + 1,
        updated_at = NOW()
    RETURNING last_number INTO v_number;

    RETURN 'EMP-' || LPAD(v_number::text, 4, '0');
END;
$$;

GRANT EXECUTE ON FUNCTION public.next_employee_code(UUID) TO authenticated;

-- ----------------------------------------------------------------------
-- 4. RLS — EMPLOYEES
-- ----------------------------------------------------------------------
ALTER TABLE public.employees ENABLE ROW LEVEL SECURITY;

CREATE POLICY "employee_select_hospital"
    ON public.employees
    FOR SELECT
    TO authenticated
    USING (hospital_id = public.current_user_hospital_id());

CREATE POLICY "employee_insert_hospital"
    ON public.employees
    FOR INSERT
    TO authenticated
    WITH CHECK (hospital_id = public.current_user_hospital_id());

CREATE POLICY "employee_update_hospital"
    ON public.employees
    FOR UPDATE
    TO authenticated
    USING (hospital_id = public.current_user_hospital_id())
    WITH CHECK (hospital_id = public.current_user_hospital_id());

CREATE POLICY "employee_delete_hospital"
    ON public.employees
    FOR DELETE
    TO authenticated
    USING (hospital_id = public.current_user_hospital_id());

-- ----------------------------------------------------------------------
-- 5. RLS — EMPLOYEE ATTENDANCE PUNCHES
-- ----------------------------------------------------------------------
ALTER TABLE public.employee_attendance_punches ENABLE ROW LEVEL SECURITY;

CREATE POLICY "attendance_punch_select_hospital"
    ON public.employee_attendance_punches
    FOR SELECT
    TO authenticated
    USING (hospital_id = public.current_user_hospital_id());

CREATE POLICY "attendance_punch_insert_hospital"
    ON public.employee_attendance_punches
    FOR INSERT
    TO authenticated
    WITH CHECK (hospital_id = public.current_user_hospital_id());

CREATE POLICY "attendance_punch_update_hospital"
    ON public.employee_attendance_punches
    FOR UPDATE
    TO authenticated
    USING (hospital_id = public.current_user_hospital_id())
    WITH CHECK (hospital_id = public.current_user_hospital_id());

CREATE POLICY "attendance_punch_delete_hospital"
    ON public.employee_attendance_punches
    FOR DELETE
    TO authenticated
    USING (hospital_id = public.current_user_hospital_id());
