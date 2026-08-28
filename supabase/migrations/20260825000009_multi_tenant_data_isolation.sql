-- ======================================================================
-- HIMS - Multi-Tenant Data Isolation
--
-- Har hospital sirf apna data dekh/change kar sake, iske liye:
--   1. Saari tenant tables mein `hospital_id` column (IF NOT EXISTS).
--   2. Saari tenant tables par RLS enable.
--   3. Purani "allow all authenticated" policies drop.
--   4. Naye tenant-scoped SELECT / INSERT / UPDATE / DELETE policies.
--
-- Policy rule (har table ke liye):
--   hospital_id = (SELECT hospital_id FROM users WHERE auth_id = auth.uid())
--
-- Supabase Dashboard -> SQL Editor mein run karo.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. hospital_id COLUMNS (safety: already exist hone par no-op)
-- ----------------------------------------------------------------------
ALTER TABLE public.patients
    ADD COLUMN IF NOT EXISTS hospital_id UUID REFERENCES public.hospitals(id) ON DELETE SET NULL;

ALTER TABLE public.opd_registrations
    ADD COLUMN IF NOT EXISTS hospital_id UUID REFERENCES public.hospitals(id) ON DELETE SET NULL;

ALTER TABLE public.ipd_admissions
    ADD COLUMN IF NOT EXISTS hospital_id UUID REFERENCES public.hospitals(id) ON DELETE SET NULL;

ALTER TABLE public.billing
    ADD COLUMN IF NOT EXISTS hospital_id UUID REFERENCES public.hospitals(id) ON DELETE SET NULL;

ALTER TABLE public.vouchers
    ADD COLUMN IF NOT EXISTS hospital_id UUID REFERENCES public.hospitals(id) ON DELETE SET NULL;

ALTER TABLE public.diagnostic_orders
    ADD COLUMN IF NOT EXISTS hospital_id UUID REFERENCES public.hospitals(id) ON DELETE SET NULL;

ALTER TABLE public.prescriptions
    ADD COLUMN IF NOT EXISTS hospital_id UUID REFERENCES public.hospitals(id) ON DELETE SET NULL;

ALTER TABLE public.pharmacy_medicines
    ADD COLUMN IF NOT EXISTS hospital_id UUID REFERENCES public.hospitals(id) ON DELETE SET NULL;

-- users.hospital_id (login ke waqt yahi fetch hota hai)
ALTER TABLE public.users
    ADD COLUMN IF NOT EXISTS hospital_id UUID REFERENCES public.hospitals(id) ON DELETE SET NULL;

-- hospitals.id — initial schema mein already PRIMARY KEY hai. Agar kisi
-- existing DB mein missing ho toh yah block use karega.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'hospitals'
          AND column_name = 'id'
    ) THEN
        ALTER TABLE public.hospitals
            ADD COLUMN id UUID PRIMARY KEY DEFAULT uuid_generate_v4();
    END IF;
END $$;

-- ----------------------------------------------------------------------
-- 2. INDEXES (tenant lookups fast rahen)
-- ----------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_patients_hospital ON public.patients(hospital_id);
CREATE INDEX IF NOT EXISTS idx_opd_hospital ON public.opd_registrations(hospital_id);
CREATE INDEX IF NOT EXISTS idx_ipd_hospital ON public.ipd_admissions(hospital_id);
CREATE INDEX IF NOT EXISTS idx_billing_hospital ON public.billing(hospital_id);
CREATE INDEX IF NOT EXISTS idx_vouchers_hospital ON public.vouchers(hospital_id);
CREATE INDEX IF NOT EXISTS idx_diag_orders_hospital ON public.diagnostic_orders(hospital_id);
CREATE INDEX IF NOT EXISTS idx_prescriptions_hospital ON public.prescriptions(hospital_id);
CREATE INDEX IF NOT EXISTS idx_pharmacy_medicines_hospital ON public.pharmacy_medicines(hospital_id);
CREATE INDEX IF NOT EXISTS idx_users_hospital ON public.users(hospital_id);

-- ----------------------------------------------------------------------
-- 3. BACKFILL (OPTIONAL but recommended)
--
-- Pehle se exist karta hua data hospital_id NULL ke saath RLS lagne ke baad
-- invisible ho jayega. Isliye NULL rows ko default 'HIMS' hospital se link
-- kar dete hain. Agar aapke paas multiple hospitals hain toh WHERE clause
-- apne hisaab se adjust karein.
-- ----------------------------------------------------------------------
UPDATE public.patients
SET hospital_id = (SELECT id FROM public.hospitals WHERE code = 'HIMS' LIMIT 1)
WHERE hospital_id IS NULL;

UPDATE public.opd_registrations
SET hospital_id = (SELECT id FROM public.hospitals WHERE code = 'HIMS' LIMIT 1)
WHERE hospital_id IS NULL;

UPDATE public.ipd_admissions
SET hospital_id = (SELECT id FROM public.hospitals WHERE code = 'HIMS' LIMIT 1)
WHERE hospital_id IS NULL;

UPDATE public.billing
SET hospital_id = (SELECT id FROM public.hospitals WHERE code = 'HIMS' LIMIT 1)
WHERE hospital_id IS NULL;

UPDATE public.vouchers
SET hospital_id = (SELECT id FROM public.hospitals WHERE code = 'HIMS' LIMIT 1)
WHERE hospital_id IS NULL;

UPDATE public.diagnostic_orders
SET hospital_id = (SELECT id FROM public.hospitals WHERE code = 'HIMS' LIMIT 1)
WHERE hospital_id IS NULL;

UPDATE public.prescriptions
SET hospital_id = (SELECT id FROM public.hospitals WHERE code = 'HIMS' LIMIT 1)
WHERE hospital_id IS NULL;

UPDATE public.pharmacy_medicines
SET hospital_id = (SELECT id FROM public.hospitals WHERE code = 'HIMS' LIMIT 1)
WHERE hospital_id IS NULL;

UPDATE public.users
SET hospital_id = (SELECT id FROM public.hospitals WHERE code = 'HIMS' LIMIT 1)
WHERE hospital_id IS NULL;

-- ----------------------------------------------------------------------
-- 4. RLS POLICIES
-- ----------------------------------------------------------------------

-- ======================================================================
-- 4.1 patients
-- ======================================================================
ALTER TABLE public.patients ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Enable all access for authenticated users on patients"
    ON public.patients;

CREATE POLICY "tenant_select_patients" ON public.patients
    FOR SELECT TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

CREATE POLICY "tenant_insert_patients" ON public.patients
    FOR INSERT TO authenticated
    WITH CHECK (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

CREATE POLICY "tenant_update_patients" ON public.patients
    FOR UPDATE TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1))
    WITH CHECK (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

CREATE POLICY "tenant_delete_patients" ON public.patients
    FOR DELETE TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

-- ======================================================================
-- 4.2 opd_registrations
-- ======================================================================
ALTER TABLE public.opd_registrations ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Enable all access for authenticated users on opd_registrations"
    ON public.opd_registrations;

CREATE POLICY "tenant_select_opd_registrations" ON public.opd_registrations
    FOR SELECT TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

CREATE POLICY "tenant_insert_opd_registrations" ON public.opd_registrations
    FOR INSERT TO authenticated
    WITH CHECK (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

CREATE POLICY "tenant_update_opd_registrations" ON public.opd_registrations
    FOR UPDATE TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1))
    WITH CHECK (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

CREATE POLICY "tenant_delete_opd_registrations" ON public.opd_registrations
    FOR DELETE TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

-- ======================================================================
-- 4.3 ipd_admissions
-- ======================================================================
ALTER TABLE public.ipd_admissions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Enable all access for authenticated users on ipd_admissions"
    ON public.ipd_admissions;

CREATE POLICY "tenant_select_ipd_admissions" ON public.ipd_admissions
    FOR SELECT TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

CREATE POLICY "tenant_insert_ipd_admissions" ON public.ipd_admissions
    FOR INSERT TO authenticated
    WITH CHECK (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

CREATE POLICY "tenant_update_ipd_admissions" ON public.ipd_admissions
    FOR UPDATE TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1))
    WITH CHECK (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

CREATE POLICY "tenant_delete_ipd_admissions" ON public.ipd_admissions
    FOR DELETE TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

-- ======================================================================
-- 4.4 billing
-- ======================================================================
ALTER TABLE public.billing ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Enable all access for authenticated users on billing"
    ON public.billing;

CREATE POLICY "tenant_select_billing" ON public.billing
    FOR SELECT TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

CREATE POLICY "tenant_insert_billing" ON public.billing
    FOR INSERT TO authenticated
    WITH CHECK (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

CREATE POLICY "tenant_update_billing" ON public.billing
    FOR UPDATE TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1))
    WITH CHECK (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

CREATE POLICY "tenant_delete_billing" ON public.billing
    FOR DELETE TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

-- ======================================================================
-- 4.5 vouchers
-- ======================================================================
ALTER TABLE public.vouchers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Enable all access for authenticated users on vouchers"
    ON public.vouchers;

CREATE POLICY "tenant_select_vouchers" ON public.vouchers
    FOR SELECT TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

CREATE POLICY "tenant_insert_vouchers" ON public.vouchers
    FOR INSERT TO authenticated
    WITH CHECK (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

CREATE POLICY "tenant_update_vouchers" ON public.vouchers
    FOR UPDATE TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1))
    WITH CHECK (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

CREATE POLICY "tenant_delete_vouchers" ON public.vouchers
    FOR DELETE TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

-- ======================================================================
-- 4.6 diagnostic_orders
-- ======================================================================
ALTER TABLE public.diagnostic_orders ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Enable all access for authenticated users on diagnostic_orders"
    ON public.diagnostic_orders;

CREATE POLICY "tenant_select_diagnostic_orders" ON public.diagnostic_orders
    FOR SELECT TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

CREATE POLICY "tenant_insert_diagnostic_orders" ON public.diagnostic_orders
    FOR INSERT TO authenticated
    WITH CHECK (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

CREATE POLICY "tenant_update_diagnostic_orders" ON public.diagnostic_orders
    FOR UPDATE TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1))
    WITH CHECK (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

CREATE POLICY "tenant_delete_diagnostic_orders" ON public.diagnostic_orders
    FOR DELETE TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

-- ======================================================================
-- 4.7 prescriptions
-- ======================================================================
ALTER TABLE public.prescriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Enable all access for authenticated users on prescriptions"
    ON public.prescriptions;

CREATE POLICY "tenant_select_prescriptions" ON public.prescriptions
    FOR SELECT TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

CREATE POLICY "tenant_insert_prescriptions" ON public.prescriptions
    FOR INSERT TO authenticated
    WITH CHECK (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

CREATE POLICY "tenant_update_prescriptions" ON public.prescriptions
    FOR UPDATE TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1))
    WITH CHECK (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

CREATE POLICY "tenant_delete_prescriptions" ON public.prescriptions
    FOR DELETE TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

-- ======================================================================
-- 4.8 pharmacy_medicines
-- ======================================================================
ALTER TABLE public.pharmacy_medicines ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow read access for authenticated users"
    ON public.pharmacy_medicines;
DROP POLICY IF EXISTS "Enable insert for authenticated users on pharmacy_medicines"
    ON public.pharmacy_medicines;
DROP POLICY IF EXISTS "Enable update for authenticated users on pharmacy_medicines"
    ON public.pharmacy_medicines;
DROP POLICY IF EXISTS "Enable delete for authenticated users on pharmacy_medicines"
    ON public.pharmacy_medicines;

CREATE POLICY "tenant_select_pharmacy_medicines" ON public.pharmacy_medicines
    FOR SELECT TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

CREATE POLICY "tenant_insert_pharmacy_medicines" ON public.pharmacy_medicines
    FOR INSERT TO authenticated
    WITH CHECK (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

CREATE POLICY "tenant_update_pharmacy_medicines" ON public.pharmacy_medicines
    FOR UPDATE TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1))
    WITH CHECK (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

CREATE POLICY "tenant_delete_pharmacy_medicines" ON public.pharmacy_medicines
    FOR DELETE TO authenticated
    USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));

-- ----------------------------------------------------------------------
-- 5. GRANTS (newer Supabase versions default-deny public tables)
-- ----------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON public.patients TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.opd_registrations TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.ipd_admissions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.billing TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.vouchers TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.diagnostic_orders TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.prescriptions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.pharmacy_medicines TO authenticated;
GRANT SELECT ON public.users TO authenticated;
GRANT SELECT ON public.hospitals TO authenticated;

-- ----------------------------------------------------------------------
-- 6. OPTIONAL — child tables hardening (baad mein jab zaroorat ho)
--
-- Neeche diye child tables bhi tenant data expose karti hain kyunki unpar
-- abhi bhi "allow all authenticated" policies hain. Inhe enable karne ke
-- liye comments hata kar run karein. (FK -> parent se hospital_id nahi
-- milta, isliye in tables mein bhi hospital_id column add karna hoga.)
-- ----------------------------------------------------------------------
-- ALTER TABLE public.billing_items
--     ADD COLUMN IF NOT EXISTS hospital_id UUID REFERENCES public.hospitals(id) ON DELETE SET NULL;
-- ALTER TABLE public.prescription_items
--     ADD COLUMN IF NOT EXISTS hospital_id UUID REFERENCES public.hospitals(id) ON DELETE SET NULL;
-- ALTER TABLE public.diagnostic_order_items
--     ADD COLUMN IF NOT EXISTS hospital_id UUID REFERENCES public.hospitals(id) ON DELETE SET NULL;
--
-- ALTER TABLE public.billing_items ENABLE ROW LEVEL SECURITY;
-- DROP POLICY IF EXISTS "Enable all access for authenticated users on billing_items" ON public.billing_items;
-- CREATE POLICY "tenant_all_billing_items" ON public.billing_items
--     FOR ALL TO authenticated
--     USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1))
--     WITH CHECK (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));
--
-- ALTER TABLE public.prescription_items ENABLE ROW LEVEL SECURITY;
-- DROP POLICY IF EXISTS "Enable all access for authenticated users on prescription_items" ON public.prescription_items;
-- CREATE POLICY "tenant_all_prescription_items" ON public.prescription_items
--     FOR ALL TO authenticated
--     USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1))
--     WITH CHECK (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));
--
-- ALTER TABLE public.diagnostic_order_items ENABLE ROW LEVEL SECURITY;
-- DROP POLICY IF EXISTS "Enable all access for authenticated users on diagnostic_order_items" ON public.diagnostic_order_items;
-- CREATE POLICY "tenant_all_diagnostic_order_items" ON public.diagnostic_order_items
--     FOR ALL TO authenticated
--     USING (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1))
--     WITH CHECK (hospital_id = (SELECT hospital_id FROM public.users WHERE auth_id = auth.uid() LIMIT 1));
