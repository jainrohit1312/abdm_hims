-- ======================================================================
-- HIMS - Authentication Security Migration
-- ----------------------------------------------------------------------
-- Is file mein:
--   1. RLS helper functions (agar pehle se na hon)
--   2. Saari tenant tables par hospital-scoped RLS policies
--      (database_service.dart mein use hone wali har table covered hai)
--   3. Child tables (billing_items, payment_logs, ipd_vitals, ...) par
--      parent-join se tenant isolation
--   4. hospitals / users / user_roles / global catalogs ke special policies
--   5. auth.config best-effort settings (password policy + rate limits)
--      -> Agar `auth.config` table na mile to Dashboard se set karein:
--         Authentication -> Providers -> Email (password policy)
--         Authentication -> Rate Limits
--
-- Idempotent hai — baar baar run kar sakte hain.
-- Supabase Dashboard -> SQL Editor mein run karein.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. RLS HELPER FUNCTIONS (SECURITY DEFINER => recursive RLS nahi hota)
--    (migration 20260825000006 se pehle se hain; phir bhi re-assert)
-- ----------------------------------------------------------------------
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

-- RLS ke saath compatibility: agar koi INSERT/UPDATE `hospital_id` bhejna
-- bhool jaaye to server khud current user ke hospital se fill kar deta hai.
-- Isse RLS enforcement ke baad bhi existing app write-flows nahi tootenge.
CREATE OR REPLACE FUNCTION public.set_hospital_id_from_current_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NEW.hospital_id IS NULL THEN
        NEW.hospital_id := public.current_user_hospital_id();
    END IF;
    RETURN NEW;
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_hospital_id_from_current_user() TO authenticated, anon;

-- ----------------------------------------------------------------------
-- 2. TENANT TABLES — direct hospital_id wali tables
--    Policy: hospital_id = current_user_hospital_id()
-- ----------------------------------------------------------------------
DO $$
DECLARE
    t   text;
    pol text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        -- Core / clinical
        'patients',
        'opd_registrations',
        'ipd_admissions',
        'beds',
        'bed_allocations',
        'prescriptions',
        'progress_notes',
        'vitals',
        'departments',
        'doctors',
        -- Pharmacy / lab (legacy + new)
        'pharmacy_medicines',
        'lab_tests',
        'lab_orders',
        'investigations',
        'medication_administration',
        'pharmacy_stock',
        'pharmacy_purchases',
        'stock_checks',
        -- Billing / accounting
        'billing',
        'daily_hisab',
        'daily_hisab_expenses',
        'payments',
        -- Voucher module
        'vouchers',
        'voucher_categories',
        'voucher_settings',
        -- Diagnostics module
        'diagnostic_tests',
        'diagnostic_orders',
        'lab_revenue',
        -- Insurance / ABDM / misc
        'patient_insurances',
        'abha_linking_logs',
        'insurance_claims',
        'care_contexts',
        'consent_artefacts',
        'data_flow_logs',
        'notifications',
        'audit_logs'
    ]
    LOOP
        -- Table exist karti hai tabhi aage badho (doctors jaise optional tables
        -- ke liye guard).
        IF to_regclass(format('public.%I', t)) IS NOT NULL THEN
            EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);

            -- hospital_id column hai tabhi tenant policies banao. Child tables
            -- (jaise lab_results) ka alag se parent-join section hai.
            IF EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public'
                  AND table_name = t
                  AND column_name = 'hospital_id'
            ) THEN
                -- Purani permissive / duplicate policies drop karo.
                FOREACH pol IN ARRAY ARRAY[
                    'Enable all access for authenticated users on ' || t,
                    'Allow read access for authenticated users',
                    'Enable insert for authenticated users on ' || t,
                    'Enable update for authenticated users on ' || t,
                    'Enable delete for authenticated users on ' || t,
                    'tenant_select_' || t,
                    'tenant_insert_' || t,
                    'tenant_update_' || t,
                    'tenant_delete_' || t,
                    'tenant_all_' || t
                ]
                LOOP
                    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', pol, t);
                END LOOP;

                -- Naye tenant-scoped policies.
                EXECUTE format(
                    'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (hospital_id = public.current_user_hospital_id())',
                    'tenant_select_' || t, t);
                EXECUTE format(
                    'CREATE POLICY %I ON public.%I FOR INSERT TO authenticated WITH CHECK (hospital_id = public.current_user_hospital_id())',
                    'tenant_insert_' || t, t);
                EXECUTE format(
                    'CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated USING (hospital_id = public.current_user_hospital_id()) WITH CHECK (hospital_id = public.current_user_hospital_id())',
                    'tenant_update_' || t, t);
                EXECUTE format(
                    'CREATE POLICY %I ON public.%I FOR DELETE TO authenticated USING (hospital_id = public.current_user_hospital_id())',
                    'tenant_delete_' || t, t);

                -- Auto-fill trigger: hospital_id missing ho to current user ke
                -- hospital se bhar do.
                EXECUTE format('DROP TRIGGER IF EXISTS trg_tenant_hospital_%I ON public.%I', t, t);
                EXECUTE format(
                    'CREATE TRIGGER trg_tenant_hospital_%I BEFORE INSERT OR UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.set_hospital_id_from_current_user()',
                    t, t);
            ELSE
                -- hospital_id nahi hai — purani permissive policy hata kar
                -- is table ko child/global section mein handle karein.
                FOREACH pol IN ARRAY ARRAY[
                    'Enable all access for authenticated users on ' || t,
                    'Allow read access for authenticated users',
                    'Enable insert for authenticated users on ' || t,
                    'Enable update for authenticated users on ' || t,
                    'Enable delete for authenticated users on ' || t
                ]
                LOOP
                    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', pol, t);
                END LOOP;
                RAISE NOTICE 'Table % has no hospital_id column — child/global policy needed (check migration).', t;
            END IF;
        END IF;
    END LOOP;
END $$;

-- ----------------------------------------------------------------------
-- 3. CHILD TABLES — hospital_id nahi hai; parent FK se tenant resolve hota hai
-- ----------------------------------------------------------------------
DO $$
DECLARE
    t      text;
    pol    text;
    parent_expr text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'billing_items',
        'payment_logs',
        'bill_edits',
        'prescription_items',
        'diagnostic_order_items',
        'diagnostic_results',
        'ipd_vitals',
        'ipd_progress_notes',
        'ipd_medications',
        'ipd_reports',
        'ipd_charges',
        'ward_transfers',
        'lab_results',
        'investigation_results',
        'purchase_entries',
        'stock_check_discrepancies'
    ]
    LOOP
        IF to_regclass(format('public.%I', t)) IS NOT NULL THEN
            parent_expr := CASE t
                WHEN 'billing_items'        THEN 'bill_id IN (SELECT id FROM public.billing WHERE hospital_id = public.current_user_hospital_id())'
                WHEN 'payment_logs'         THEN 'bill_id IN (SELECT id FROM public.billing WHERE hospital_id = public.current_user_hospital_id())'
                WHEN 'bill_edits'           THEN 'bill_id IN (SELECT id FROM public.billing WHERE hospital_id = public.current_user_hospital_id())'
                WHEN 'prescription_items'   THEN 'prescription_id IN (SELECT id FROM public.prescriptions WHERE hospital_id = public.current_user_hospital_id())'
                WHEN 'diagnostic_order_items' THEN 'order_id IN (SELECT id FROM public.diagnostic_orders WHERE hospital_id = public.current_user_hospital_id())'
                WHEN 'diagnostic_results'   THEN 'order_item_id IN (SELECT oi.id FROM public.diagnostic_order_items oi JOIN public.diagnostic_orders o ON o.id = oi.order_id WHERE o.hospital_id = public.current_user_hospital_id())'
                WHEN 'ipd_vitals'           THEN 'admission_id IN (SELECT id FROM public.ipd_admissions WHERE hospital_id = public.current_user_hospital_id())'
                WHEN 'ipd_progress_notes'   THEN 'admission_id IN (SELECT id FROM public.ipd_admissions WHERE hospital_id = public.current_user_hospital_id())'
                WHEN 'ipd_medications'      THEN 'admission_id IN (SELECT id FROM public.ipd_admissions WHERE hospital_id = public.current_user_hospital_id())'
                WHEN 'ipd_reports'          THEN 'admission_id IN (SELECT id FROM public.ipd_admissions WHERE hospital_id = public.current_user_hospital_id())'
                WHEN 'ipd_charges'          THEN 'admission_id IN (SELECT id FROM public.ipd_admissions WHERE hospital_id = public.current_user_hospital_id())'
                WHEN 'ward_transfers'       THEN 'admission_id IN (SELECT id FROM public.ipd_admissions WHERE hospital_id = public.current_user_hospital_id())'
                WHEN 'lab_results'          THEN 'lab_order_id IN (SELECT id FROM public.lab_orders WHERE hospital_id = public.current_user_hospital_id())'
                WHEN 'investigation_results' THEN 'investigation_id IN (SELECT id FROM public.investigations WHERE hospital_id = public.current_user_hospital_id())'
                WHEN 'purchase_entries'     THEN 'purchase_id IN (SELECT id FROM public.pharmacy_purchases WHERE hospital_id = public.current_user_hospital_id())'
                WHEN 'stock_check_discrepancies' THEN 'stock_check_id IN (SELECT id FROM public.stock_checks WHERE hospital_id = public.current_user_hospital_id())'
                ELSE 'FALSE'
            END;

            EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);

            FOREACH pol IN ARRAY ARRAY[
                'Enable all access for authenticated users on ' || t,
                'tenant_select_' || t,
                'tenant_insert_' || t,
                'tenant_update_' || t,
                'tenant_delete_' || t,
                'tenant_all_' || t
            ]
            LOOP
                EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', pol, t);
            END LOOP;

            EXECUTE format(
                'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (%s)',
                'tenant_select_' || t, t, parent_expr);
            EXECUTE format(
                'CREATE POLICY %I ON public.%I FOR INSERT TO authenticated WITH CHECK (%s)',
                'tenant_insert_' || t, t, parent_expr);
            EXECUTE format(
                'CREATE POLICY %I ON public.%I FOR UPDATE TO authenticated USING (%s) WITH CHECK (%s)',
                'tenant_update_' || t, t, parent_expr, parent_expr);
            EXECUTE format(
                'CREATE POLICY %I ON public.%I FOR DELETE TO authenticated USING (%s)',
                'tenant_delete_' || t, t, parent_expr);
        END IF;
    END LOOP;
END $$;

-- ----------------------------------------------------------------------
-- 4. HOSPITALS — root tenant table
--    * SELECT/UPDATE: sirf apna hospital
--    * INSERT: sirf naya signup jiska abhi tak koi public.users record nahi
--      (self-registration fallback flow)
--    * DELETE: sirf apne hospital ka admin
-- ----------------------------------------------------------------------
ALTER TABLE public.hospitals ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Allow read access for authenticated users" ON public.hospitals;
DROP POLICY IF EXISTS "Enable insert for authenticated users on hospitals" ON public.hospitals;
DROP POLICY IF EXISTS "Enable update for authenticated users on hospitals" ON public.hospitals;
DROP POLICY IF EXISTS "Enable delete for authenticated users on hospitals" ON public.hospitals;
DROP POLICY IF EXISTS "hospitals_select_own" ON public.hospitals;
DROP POLICY IF EXISTS "hospitals_insert_new_signup" ON public.hospitals;
DROP POLICY IF EXISTS "hospitals_update_own" ON public.hospitals;
DROP POLICY IF EXISTS "hospitals_delete_own_admin" ON public.hospitals;

CREATE POLICY "hospitals_select_own" ON public.hospitals
    FOR SELECT TO authenticated
    USING (id = public.current_user_hospital_id());

CREATE POLICY "hospitals_insert_new_signup" ON public.hospitals
    FOR INSERT TO authenticated
    WITH CHECK (
        NOT EXISTS (
            SELECT 1 FROM public.users WHERE auth_id = auth.uid()
        )
    );

CREATE POLICY "hospitals_update_own" ON public.hospitals
    FOR UPDATE TO authenticated
    USING (id = public.current_user_hospital_id())
    WITH CHECK (id = public.current_user_hospital_id());

CREATE POLICY "hospitals_delete_own_admin" ON public.hospitals
    FOR DELETE TO authenticated
    USING (
        id = public.current_user_hospital_id()
        AND public.is_current_user_hospital_admin()
    );

-- ----------------------------------------------------------------------
-- 5. USERS — hospital-scoped policies (migration 06 jaise, re-assert)
-- ----------------------------------------------------------------------
ALTER TABLE public.users ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Enable all access for authenticated users on users" ON public.users;
DROP POLICY IF EXISTS "Users can view hospital colleagues" ON public.users;
DROP POLICY IF EXISTS "Users can insert own record" ON public.users;
DROP POLICY IF EXISTS "Admins can insert hospital users" ON public.users;
DROP POLICY IF EXISTS "Users can update own record" ON public.users;
DROP POLICY IF EXISTS "Admins can update hospital users" ON public.users;
DROP POLICY IF EXISTS "Admins can delete hospital users" ON public.users;

CREATE POLICY "Users can view hospital colleagues"
    ON public.users FOR SELECT TO authenticated
    USING (
        auth_id = auth.uid()
        OR hospital_id = public.current_user_hospital_id()
    );

CREATE POLICY "Users can insert own record"
    ON public.users FOR INSERT TO authenticated
    WITH CHECK (auth_id = auth.uid());

CREATE POLICY "Admins can insert hospital users"
    ON public.users FOR INSERT TO authenticated
    WITH CHECK (
        public.is_current_user_hospital_admin()
        AND hospital_id = public.current_user_hospital_id()
    );

CREATE POLICY "Users can update own record"
    ON public.users FOR UPDATE TO authenticated
    USING (auth_id = auth.uid())
    WITH CHECK (
        auth_id = auth.uid()
        AND hospital_id IS NOT DISTINCT FROM public.current_user_hospital_id()
    );

CREATE POLICY "Admins can update hospital users"
    ON public.users FOR UPDATE TO authenticated
    USING (
        public.is_current_user_hospital_admin()
        AND hospital_id = public.current_user_hospital_id()
    )
    WITH CHECK (
        public.is_current_user_hospital_admin()
        AND hospital_id = public.current_user_hospital_id()
    );

CREATE POLICY "Admins can delete hospital users"
    ON public.users FOR DELETE TO authenticated
    USING (
        public.is_current_user_hospital_admin()
        AND hospital_id = public.current_user_hospital_id()
        AND auth_id <> auth.uid()
    );

-- ----------------------------------------------------------------------
-- 6. USER_ROLES — hospital ka role catalogue (sab dekh sakte hain, sirf
--    admin manage kar sakta hai)
-- ----------------------------------------------------------------------
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view hospital roles" ON public.user_roles;
DROP POLICY IF EXISTS "Admins can manage hospital roles" ON public.user_roles;

CREATE POLICY "Users can view hospital roles"
    ON public.user_roles FOR SELECT TO authenticated
    USING (hospital_id = public.current_user_hospital_id());

CREATE POLICY "Admins can manage hospital roles"
    ON public.user_roles FOR ALL TO authenticated
    USING (
        public.is_current_user_hospital_admin()
        AND hospital_id = public.current_user_hospital_id()
    )
    WITH CHECK (
        public.is_current_user_hospital_admin()
        AND hospital_id = public.current_user_hospital_id()
    );

-- ----------------------------------------------------------------------
-- 7. GLOBAL CATALOGS — ipd_ward_pricing / ipd_packages / ipd_service_master
--    Hospital-specific nahi hain; sab authenticated read kar sakte hain,
--    writes sirf hospital admin.
-- ----------------------------------------------------------------------
DO $$
DECLARE
    t   text;
    pol text;
BEGIN
    FOREACH t IN ARRAY ARRAY['ipd_ward_pricing', 'ipd_packages', 'ipd_service_master']
    LOOP
        IF to_regclass(format('public.%I', t)) IS NOT NULL THEN
            EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);

            FOREACH pol IN ARRAY ARRAY[
                'Enable all access for authenticated users on ' || t,
                'tenant_select_' || t,
                'tenant_all_' || t
            ]
            LOOP
                EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', pol, t);
            END LOOP;

            EXECUTE format(
                'CREATE POLICY %I ON public.%I FOR SELECT TO authenticated USING (true)',
                'catalog_select_' || t, t);
            EXECUTE format(
                'CREATE POLICY %I ON public.%I FOR ALL TO authenticated USING (public.is_current_user_hospital_admin()) WITH CHECK (public.is_current_user_hospital_admin())',
                'catalog_admin_' || t, t);
        END IF;
    END LOOP;
END $$;

-- ----------------------------------------------------------------------
-- 8. GRANTS — newer Supabase versions default-deny public tables
-- ----------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO authenticated;

-- ----------------------------------------------------------------------
-- 9. AUTH CONFIG — password policy + rate limits (best-effort)
-- ----------------------------------------------------------------------
-- Supabase platform par ye settings `auth.config` table mein hoti hain
-- (project ke hisaab se column names thode alag ho sakte hain, isliye
-- information_schema se check karke update karte hain).
--
-- Agar ye block kuch update na kare (NOTICE dekhein), to Dashboard se set
-- karein:
--   Password policy : Authentication -> Providers -> Email
--                      Minimum password length = 8
--                      Password requirements   = lower_upper_letters_digits_symbols
--   Rate limits      : Authentication -> Rate Limits
--                      Sign-in/sign-ups (5 min) = 10
--                      Token refresh (5 min)    = 150
--   Session timeout  : Authentication -> Sessions (agar available ho)
DO $$
DECLARE
    v_col text;
BEGIN
    IF to_regclass('auth.config') IS NULL THEN
        RAISE NOTICE 'auth.config table not found — password policy + rate limits Dashboard se set karein.';
        RETURN;
    END IF;

    -- Password policy: minimum length 8.
    FOREACH v_col IN ARRAY ARRAY['minimum_password_length', 'password_min_length']
    LOOP
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'auth' AND table_name = 'config' AND column_name = v_col
        ) THEN
            EXECUTE format('UPDATE auth.config SET %I = 8', v_col);
            RAISE NOTICE 'auth.config.% updated to 8', v_col;
        END IF;
    END LOOP;

    -- Password requirements: letters + digits + symbols (strongest supported).
    FOREACH v_col IN ARRAY ARRAY['password_requirements', 'password_required_characters']
    LOOP
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'auth' AND table_name = 'config' AND column_name = v_col
        ) THEN
            IF v_col = 'password_required_characters' THEN
                -- GoTrue (older) character-set format.
                EXECUTE format(
                    'UPDATE auth.config SET %I = %L',
                    v_col,
                    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()');
            ELSE
                -- GoTrue (newer) preset format.
                EXECUTE format('UPDATE auth.config SET %I = %L', v_col, 'lower_upper_letters_digits_symbols');
            END IF;
            RAISE NOTICE 'auth.config.% updated', v_col;
        END IF;
    END LOOP;

    -- Rate limits (per-IP). Defaults se tighter values.
    FOREACH v_col IN ARRAY ARRAY[
        'rate_limit_sign_in_sign_ups',
        'sign_in_sign_ups',
        'rate_limit_signups'
    ]
    LOOP
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'auth' AND table_name = 'config' AND column_name = v_col
        ) THEN
            EXECUTE format('UPDATE auth.config SET %I = 10', v_col);
            RAISE NOTICE 'auth.config.% updated to 10', v_col;
        END IF;
    END LOOP;

    FOREACH v_col IN ARRAY ARRAY['rate_limit_token_refresh', 'token_refresh']
    LOOP
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'auth' AND table_name = 'config' AND column_name = v_col
        ) THEN
            EXECUTE format('UPDATE auth.config SET %I = 150', v_col);
            RAISE NOTICE 'auth.config.% updated to 150', v_col;
        END IF;
    END LOOP;

    FOREACH v_col IN ARRAY ARRAY['rate_limit_email_sent', 'email_sent']
    LOOP
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'auth' AND table_name = 'config' AND column_name = v_col
        ) THEN
            EXECUTE format('UPDATE auth.config SET %I = 5', v_col);
            RAISE NOTICE 'auth.config.% updated to 5', v_col;
        END IF;
    END LOOP;

    FOREACH v_col IN ARRAY ARRAY['rate_limit_sms_sent', 'sms_sent']
    LOOP
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'auth' AND table_name = 'config' AND column_name = v_col
        ) THEN
            EXECUTE format('UPDATE auth.config SET %I = 30', v_col);
            RAISE NOTICE 'auth.config.% updated to 30', v_col;
        END IF;
    END LOOP;

    -- Auth session timebox / inactivity timeout (agar columns hain).
    FOREACH v_col IN ARRAY ARRAY['sessions_timebox', 'session_timebox']
    LOOP
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'auth' AND table_name = 'config' AND column_name = v_col
        ) THEN
            EXECUTE format('UPDATE auth.config SET %I = %L', v_col, '24h');
            RAISE NOTICE 'auth.config.% updated to 24h', v_col;
        END IF;
    END LOOP;

    FOREACH v_col IN ARRAY ARRAY['sessions_inactivity_timeout', 'session_inactivity_timeout']
    LOOP
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'auth' AND table_name = 'config' AND column_name = v_col
        ) THEN
            EXECUTE format('UPDATE auth.config SET %I = %L', v_col, '8h');
            RAISE NOTICE 'auth.config.% updated to 8h', v_col;
        END IF;
    END LOOP;
END $$;
