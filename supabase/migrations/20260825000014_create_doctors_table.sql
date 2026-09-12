-- ======================================================================
-- HIMS - Create the `doctors` master table
-- ----------------------------------------------------------------------
-- NOTE: `public.doctors` is referenced by several later migrations
-- (prescription_mode, doctor-wise charges, database indexes, IPD doctor
-- selection) but was never created by any earlier migration — it was
-- evidently created manually in the production database.
--
-- This migration reconstructs it so the migration chain is complete for a
-- FRESH isolated/local database. It is idempotent (`IF NOT EXISTS`) and is a
-- no-op against an existing production table, so it is safe to apply
-- anywhere.
--
-- The column set is the minimal set the later migrations and the app code
-- reference; additional columns may exist in production and are preserved.
-- ======================================================================

CREATE TABLE IF NOT EXISTS public.doctors (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES public.hospitals(id) ON DELETE CASCADE,
    department_id UUID REFERENCES public.departments(id) ON DELETE SET NULL,
    name VARCHAR(255) NOT NULL,
    specialization VARCHAR(255),
    qualification VARCHAR(255),
    registration_number VARCHAR(100),
    phone VARCHAR(20),
    email VARCHAR(255),
    opd_fee DECIMAL(10,2) DEFAULT 0,
    emergency_fee DECIMAL(10,2) DEFAULT 0,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ----------------------------------------------------------------------
-- Access for the reconstructed table.
--
-- The table is read by the app (offline OPD doctor/department picker and the
-- doctor `prescription_mode` lookup) and written by the doctor management
-- screen, so it needs the same tenant-scoped access as every other
-- operational table. Without these grants every read fails with
-- "permission denied for table doctors" — the table is present but unusable.
--
-- Idempotent, and deliberately NOT guarded by the `CREATE TABLE IF NOT
-- EXISTS` above: re-running this file also REPAIRS an existing production
-- `doctors` table that was created manually without grants or RLS.
-- ----------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON public.doctors TO authenticated;

CREATE INDEX IF NOT EXISTS idx_doctors_hospital ON public.doctors(hospital_id);

ALTER TABLE public.doctors ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Enable all access for authenticated users on doctors"
    ON public.doctors;
DROP POLICY IF EXISTS "tenant_select_doctors" ON public.doctors;
DROP POLICY IF EXISTS "tenant_insert_doctors" ON public.doctors;
DROP POLICY IF EXISTS "tenant_update_doctors" ON public.doctors;
DROP POLICY IF EXISTS "tenant_delete_doctors" ON public.doctors;

CREATE POLICY "tenant_select_doctors" ON public.doctors
    FOR SELECT TO authenticated
    USING (hospital_id = public.current_user_hospital_id());

CREATE POLICY "tenant_insert_doctors" ON public.doctors
    FOR INSERT TO authenticated
    WITH CHECK (hospital_id = public.current_user_hospital_id());

CREATE POLICY "tenant_update_doctors" ON public.doctors
    FOR UPDATE TO authenticated
    USING (hospital_id = public.current_user_hospital_id())
    WITH CHECK (hospital_id = public.current_user_hospital_id());

CREATE POLICY "tenant_delete_doctors" ON public.doctors
    FOR DELETE TO authenticated
    USING (hospital_id = public.current_user_hospital_id());

-- Keep hospital_id populated from the authenticated tenant (the same trigger
-- pattern every other tenant table uses).
DROP TRIGGER IF EXISTS trg_tenant_hospital_doctors ON public.doctors;
CREATE TRIGGER trg_tenant_hospital_doctors
    BEFORE INSERT OR UPDATE ON public.doctors
    FOR EACH ROW EXECUTE FUNCTION public.set_hospital_id_from_current_user();
