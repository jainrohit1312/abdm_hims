-- ======================================================================
-- HIMS - Hospital Onboarding & Multi-User Management
--
-- * Creates the `user_roles` master (per-hospital role catalogue).
-- * Adds hospital-scoped RLS policies on `users` so an admin can only
--   see/manage users of their own hospital.
-- * Adds RLS policies on `user_roles` (visible to the whole hospital,
--   managed by hospital admins only).
-- * Seeds the default role catalogue for every hospital (including the
--   seeded HIMS hospital) and auto-seeds it for future hospitals via a
--   trigger.
--
-- NOTE:
-- * `hospitals` and `users` tables already exist from the initial schema
--   and already contain every column needed by this module
--   (see 20240811000000_initial_schema.sql). No ALTERs are required.
-- * For logo uploads make sure a public storage bucket named
--   `hims-storage` exists (StorageService uses it).
-- * Self-registration uses the client-side `auth.signUp()` API. Keep
--   "Confirm email" disabled (or auto-confirm) in
--   Authentication -> Providers -> Email, otherwise the newly registered
--   admin must verify their email before first login.
--
-- Run manually in Supabase SQL Editor, or `supabase db push`.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. USER ROLES MASTER
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.user_roles (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID NOT NULL REFERENCES public.hospitals(id) ON DELETE CASCADE,
    role_name VARCHAR(50) NOT NULL,
    description TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (hospital_id, role_name)
);

CREATE INDEX IF NOT EXISTS idx_user_roles_hospital
    ON public.user_roles(hospital_id);

-- ----------------------------------------------------------------------
-- 2. RLS HELPER FUNCTIONS (SECURITY DEFINER => no recursive RLS lookups)
-- ----------------------------------------------------------------------

-- Hospital id of the currently authenticated user (from public.users).
CREATE OR REPLACE FUNCTION public.current_user_hospital_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT hospital_id
    FROM public.users
    WHERE auth_id = auth.uid()
    LIMIT 1;
$$;

-- True when the current user is an active admin/super_admin.
CREATE OR REPLACE FUNCTION public.is_current_user_hospital_admin()
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    SELECT EXISTS (
        SELECT 1
        FROM public.users
        WHERE auth_id = auth.uid()
          AND is_active = TRUE
          AND lower(role) IN ('super_admin', 'admin')
    );
$$;

GRANT EXECUTE ON FUNCTION public.current_user_hospital_id() TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.is_current_user_hospital_admin() TO authenticated, anon;

-- ----------------------------------------------------------------------
-- 3. USERS - hospital-scoped RLS policies
-- ----------------------------------------------------------------------
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

-- Replace the old permissive policies with hospital-scoped ones.
DROP POLICY IF EXISTS "Enable all access for authenticated users on users"
    ON public.users;

DROP POLICY IF EXISTS "Users can view hospital colleagues" ON public.users;
DROP POLICY IF EXISTS "Users can insert own record" ON public.users;
DROP POLICY IF EXISTS "Admins can insert hospital users" ON public.users;
DROP POLICY IF EXISTS "Users can update own record" ON public.users;
DROP POLICY IF EXISTS "Admins can update hospital users" ON public.users;
DROP POLICY IF EXISTS "Admins can delete hospital users" ON public.users;

-- SELECT: a user always sees their own row; everyone else only sees rows
-- belonging to their own hospital.
CREATE POLICY "Users can view hospital colleagues"
    ON public.users
    FOR SELECT
    TO authenticated
    USING (
        auth_id = auth.uid()
        OR hospital_id = public.current_user_hospital_id()
    );

-- INSERT: used during self-registration (new admin inserts their own row).
CREATE POLICY "Users can insert own record"
    ON public.users
    FOR INSERT
    TO authenticated
    WITH CHECK (auth_id = auth.uid());

-- INSERT: a hospital admin can create other users inside their hospital.
CREATE POLICY "Admins can insert hospital users"
    ON public.users
    FOR INSERT
    TO authenticated
    WITH CHECK (
        public.is_current_user_hospital_admin()
        AND hospital_id = public.current_user_hospital_id()
    );

-- UPDATE: a user can update their own row without changing hospital_id.
CREATE POLICY "Users can update own record"
    ON public.users
    FOR UPDATE
    TO authenticated
    USING (auth_id = auth.uid())
    WITH CHECK (
        auth_id = auth.uid()
        AND hospital_id IS NOT DISTINCT FROM public.current_user_hospital_id()
    );

-- UPDATE: hospital admins can update users of their own hospital.
CREATE POLICY "Admins can update hospital users"
    ON public.users
    FOR UPDATE
    TO authenticated
    USING (
        public.is_current_user_hospital_admin()
        AND hospital_id = public.current_user_hospital_id()
    )
    WITH CHECK (
        public.is_current_user_hospital_admin()
        AND hospital_id = public.current_user_hospital_id()
    );

-- DELETE: hospital admins can delete users of their own hospital, except
-- themselves (prevents an admin from locking the hospital out).
CREATE POLICY "Admins can delete hospital users"
    ON public.users
    FOR DELETE
    TO authenticated
    USING (
        public.is_current_user_hospital_admin()
        AND hospital_id = public.current_user_hospital_id()
        AND auth_id <> auth.uid()
    );

-- ----------------------------------------------------------------------
-- 4. USER_ROLES - hospital-scoped RLS policies
-- ----------------------------------------------------------------------
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view hospital roles" ON public.user_roles;
DROP POLICY IF EXISTS "Admins can manage hospital roles" ON public.user_roles;

CREATE POLICY "Users can view hospital roles"
    ON public.user_roles
    FOR SELECT
    TO authenticated
    USING (hospital_id = public.current_user_hospital_id());

CREATE POLICY "Admins can manage hospital roles"
    ON public.user_roles
    FOR ALL
    TO authenticated
    USING (
        public.is_current_user_hospital_admin()
        AND hospital_id = public.current_user_hospital_id()
    )
    WITH CHECK (
        public.is_current_user_hospital_admin()
        AND hospital_id = public.current_user_hospital_id()
    );

-- ----------------------------------------------------------------------
-- 5. DEFAULT ROLE CATALOGUE
-- ----------------------------------------------------------------------

-- Seed roles for hospitals that already exist (e.g. HIMS Main Hospital).
INSERT INTO public.user_roles (hospital_id, role_name, description)
SELECT
    h.id,
    r.role_name,
    r.description
FROM public.hospitals h
CROSS JOIN (
    VALUES
        ('Admin',         'Hospital administrator with full access'),
        ('Doctor',        'Consulting doctors'),
        ('Nurse',         'Nursing staff'),
        ('Receptionist',  'Front desk / registration staff'),
        ('Pharmacist',    'Pharmacy staff'),
        ('Lab Technician','Laboratory / diagnostics staff'),
        ('Accountant',    'Accounts / billing staff')
) AS r(role_name, description)
ON CONFLICT (hospital_id, role_name) DO NOTHING;

-- Auto-seed the same catalogue whenever a new hospital registers.
CREATE OR REPLACE FUNCTION public.seed_user_roles_for_new_hospital()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    INSERT INTO public.user_roles (hospital_id, role_name, description)
    VALUES
        (NEW.id, 'Admin',          'Hospital administrator with full access'),
        (NEW.id, 'Doctor',         'Consulting doctors'),
        (NEW.id, 'Nurse',          'Nursing staff'),
        (NEW.id, 'Receptionist',   'Front desk / registration staff'),
        (NEW.id, 'Pharmacist',     'Pharmacy staff'),
        (NEW.id, 'Lab Technician', 'Laboratory / diagnostics staff'),
        (NEW.id, 'Accountant',     'Accounts / billing staff')
    ON CONFLICT (hospital_id, role_name) DO NOTHING;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_seed_user_roles_on_hospital_insert
    ON public.hospitals;

CREATE TRIGGER trg_seed_user_roles_on_hospital_insert
    AFTER INSERT ON public.hospitals
    FOR EACH ROW
    EXECUTE FUNCTION public.seed_user_roles_for_new_hospital();

-- ----------------------------------------------------------------------
-- 6. GRANTS (newer Supabase versions don't auto-expose public tables)
-- ----------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON public.user_roles TO authenticated, anon;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO authenticated, anon;
