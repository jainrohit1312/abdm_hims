-- ======================================================================
-- HIMS - Database Indexing Module (SAFE / AUTO-SKIP VERSION)
-- ----------------------------------------------------------------------
-- Analysis source : lib/services/database_service.dart + lib/app/providers.dart
--
-- * Har index sirf tabhi banta hai jab table AUR saare columns exist karte
--   hain. Agar aapke Supabase project mein koi column/table missing hai
--   (e.g. doctor_id), toh sirf wahi index skip hoga — baaki script chalti
--   rahegi, koi ERROR nahi aayega.
-- * Idempotent : safe to run multiple times.
-- * Run in      : Supabase Dashboard -> SQL Editor (paste & Run).
-- ======================================================================

-- ======================================================================
-- STEP 0: Helper function (auto-skips missing tables/columns)
-- ======================================================================
CREATE OR REPLACE FUNCTION hims_create_index(
    p_index text,
    p_table text,
    p_cols text[],
    p_def text,
    p_using text DEFAULT 'btree'
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    v_schema text;
    v_table  text;
    v_col    text;
BEGIN
    v_schema := split_part(p_table, '.', 1);
    v_table  := split_part(p_table, '.', 2);

    IF v_schema = '' OR v_table = '' THEN
        RAISE NOTICE 'SKIP %: invalid table name %', p_index, p_table;
        RETURN;
    END IF;

    IF to_regclass(p_table) IS NULL THEN
        RAISE NOTICE 'SKIP %: table % does not exist', p_index, p_table;
        RETURN;
    END IF;

    FOREACH v_col IN ARRAY p_cols
    LOOP
        IF NOT EXISTS (
            SELECT 1
            FROM information_schema.columns
            WHERE table_schema = v_schema
              AND table_name   = v_table
              AND column_name  = v_col
        ) THEN
            RAISE NOTICE 'SKIP %: column %.% does not exist', p_index, v_table, v_col;
            RETURN;
        END IF;
    END LOOP;

    IF EXISTS (
        SELECT 1
        FROM pg_indexes
        WHERE schemaname = v_schema
          AND tablename  = v_table
          AND indexname  = p_index
    ) THEN
        RAISE NOTICE 'EXISTS % (skipped)', p_index;
        RETURN;
    END IF;

    IF p_using = 'gin' THEN
        EXECUTE format('CREATE INDEX %I ON %s USING GIN (%s)', p_index, p_table, p_def);
    ELSE
        EXECUTE format('CREATE INDEX %I ON %s (%s)', p_index, p_table, p_def);
    END IF;

    RAISE NOTICE 'CREATED % ON %', p_index, p_table;
END;
$$;

-- ======================================================================
-- 1. PATIENTS
-- ======================================================================
SELECT hims_create_index('idx_patients_uhid', 'public.patients',
    ARRAY['uhid'], 'uhid');
SELECT hims_create_index('idx_patients_mobile', 'public.patients',
    ARRAY['mobile_number'], 'mobile_number');
SELECT hims_create_index('idx_patients_name', 'public.patients',
    ARRAY['first_name','last_name'], 'first_name, last_name');
SELECT hims_create_index('idx_patients_last_name', 'public.patients',
    ARRAY['last_name'], 'last_name');
SELECT hims_create_index('idx_patients_hospital_created', 'public.patients',
    ARRAY['hospital_id','created_at'], 'hospital_id, created_at DESC');
SELECT hims_create_index('idx_patients_hospital_mobile', 'public.patients',
    ARRAY['hospital_id','mobile_number'], 'hospital_id, mobile_number');

-- ======================================================================
-- 2. OPD REGISTRATIONS
-- ======================================================================
SELECT hims_create_index('idx_opd_patient', 'public.opd_registrations',
    ARRAY['patient_id'], 'patient_id');
SELECT hims_create_index('idx_opd_date', 'public.opd_registrations',
    ARRAY['visit_date'], 'visit_date');
SELECT hims_create_index('idx_opd_hospital', 'public.opd_registrations',
    ARRAY['hospital_id'], 'hospital_id');
SELECT hims_create_index('idx_opd_visit_date_doctor', 'public.opd_registrations',
    ARRAY['visit_date','doctor_id'], 'visit_date, doctor_id');
SELECT hims_create_index('idx_opd_hospital_visit_date_doctor', 'public.opd_registrations',
    ARRAY['hospital_id','visit_date','doctor_id'], 'hospital_id, visit_date, doctor_id');
SELECT hims_create_index('idx_opd_hospital_created_at', 'public.opd_registrations',
    ARRAY['hospital_id','created_at'], 'hospital_id, created_at DESC');
SELECT hims_create_index('idx_opd_hospital_patient', 'public.opd_registrations',
    ARRAY['hospital_id','patient_id'], 'hospital_id, patient_id');

-- ======================================================================
-- 3. IPD ADMISSIONS
-- ======================================================================
SELECT hims_create_index('idx_ipd_patient', 'public.ipd_admissions',
    ARRAY['patient_id'], 'patient_id');
SELECT hims_create_index('idx_ipd_admission_date', 'public.ipd_admissions',
    ARRAY['admission_date'], 'admission_date');
SELECT hims_create_index('idx_ipd_hospital', 'public.ipd_admissions',
    ARRAY['hospital_id'], 'hospital_id');
SELECT hims_create_index('idx_ipd_hospital_admission_date', 'public.ipd_admissions',
    ARRAY['hospital_id','admission_date'], 'hospital_id, admission_date');
SELECT hims_create_index('idx_ipd_hospital_created_at', 'public.ipd_admissions',
    ARRAY['hospital_id','created_at'], 'hospital_id, created_at DESC');
SELECT hims_create_index('idx_ipd_hospital_patient', 'public.ipd_admissions',
    ARRAY['hospital_id','patient_id'], 'hospital_id, patient_id');
SELECT hims_create_index('idx_ipd_bed_status', 'public.ipd_admissions',
    ARRAY['bed_id','status'], 'bed_id, status');

-- ======================================================================
-- 4. BILLING
-- ======================================================================
SELECT hims_create_index('idx_billing_patient', 'public.billing',
    ARRAY['patient_id'], 'patient_id');
SELECT hims_create_index('idx_billing_date', 'public.billing',
    ARRAY['bill_date'], 'bill_date');
SELECT hims_create_index('idx_billing_hospital', 'public.billing',
    ARRAY['hospital_id'], 'hospital_id');
SELECT hims_create_index('idx_billing_hospital_bill_date', 'public.billing',
    ARRAY['hospital_id','bill_date','created_at'],
    'hospital_id, bill_date DESC, created_at DESC');
SELECT hims_create_index('idx_billing_hospital_visit_type_date', 'public.billing',
    ARRAY['hospital_id','visit_type','bill_date','created_at'],
    'hospital_id, visit_type, bill_date DESC, created_at DESC');
SELECT hims_create_index('idx_billing_hospital_patient', 'public.billing',
    ARRAY['hospital_id','patient_id'], 'hospital_id, patient_id');
SELECT hims_create_index('idx_billing_ipd_admission_date', 'public.billing',
    ARRAY['ipd_admission_id','bill_date'], 'ipd_admission_id, bill_date DESC');
SELECT hims_create_index('idx_billing_opd_registration', 'public.billing',
    ARRAY['opd_registration_id'], 'opd_registration_id');
SELECT hims_create_index('idx_billing_items_bill', 'public.billing_items',
    ARRAY['bill_id'], 'bill_id');

-- ======================================================================
-- 5. VOUCHERS
-- ======================================================================
SELECT hims_create_index('idx_vouchers_hospital', 'public.vouchers',
    ARRAY['hospital_id'], 'hospital_id');
SELECT hims_create_index('idx_vouchers_voucher_date', 'public.vouchers',
    ARRAY['voucher_date'], 'voucher_date');
SELECT hims_create_index('idx_vouchers_hospital_date', 'public.vouchers',
    ARRAY['hospital_id','voucher_date'], 'hospital_id, voucher_date');
SELECT hims_create_index('idx_vouchers_hospital_date_created', 'public.vouchers',
    ARRAY['hospital_id','voucher_date','created_at'],
    'hospital_id, voucher_date DESC, created_at DESC');
SELECT hims_create_index('idx_vouchers_hospital_date_number', 'public.vouchers',
    ARRAY['hospital_id','voucher_date','voucher_number'],
    'hospital_id, voucher_date, voucher_number DESC');

-- ======================================================================
-- 6. DIAGNOSTIC ORDERS
-- ======================================================================
SELECT hims_create_index('idx_diagnostic_orders_patient', 'public.diagnostic_orders',
    ARRAY['patient_id'], 'patient_id');
SELECT hims_create_index('idx_diagnostic_orders_hospital', 'public.diagnostic_orders',
    ARRAY['hospital_id'], 'hospital_id');
SELECT hims_create_index('idx_diagnostic_orders_hospital_status', 'public.diagnostic_orders',
    ARRAY['hospital_id','status','created_at'],
    'hospital_id, status, created_at DESC');
SELECT hims_create_index('idx_diagnostic_orders_hospital_created_at', 'public.diagnostic_orders',
    ARRAY['hospital_id','created_at'], 'hospital_id, created_at DESC');
SELECT hims_create_index('idx_diagnostic_orders_hospital_patient', 'public.diagnostic_orders',
    ARRAY['hospital_id','patient_id'], 'hospital_id, patient_id');

-- ======================================================================
-- 7. SECONDARY TABLES (where / join / order columns)
-- ======================================================================

-- Users & roles
SELECT hims_create_index('idx_users_auth_id', 'public.users',
    ARRAY['auth_id'], 'auth_id');
SELECT hims_create_index('idx_users_hospital_created_at', 'public.users',
    ARRAY['hospital_id','created_at'], 'hospital_id, created_at DESC');
SELECT hims_create_index('idx_user_roles_hospital_active', 'public.user_roles',
    ARRAY['hospital_id','is_active'], 'hospital_id, is_active');

-- Departments
SELECT hims_create_index('idx_departments_hospital_name', 'public.departments',
    ARRAY['hospital_id','name'], 'hospital_id, name');

-- Beds & wards
SELECT hims_create_index('idx_beds_hospital_status', 'public.beds',
    ARRAY['hospital_id','status'], 'hospital_id, status');
SELECT hims_create_index('idx_beds_hospital_ward_type', 'public.beds',
    ARRAY['hospital_id','ward_type'], 'hospital_id, ward_type');

-- Bed allocations
SELECT hims_create_index('idx_bed_allocations_patient', 'public.bed_allocations',
    ARRAY['patient_id'], 'patient_id');
SELECT hims_create_index('idx_bed_allocations_ipd_status', 'public.bed_allocations',
    ARRAY['ipd_admission_id','status'], 'ipd_admission_id, status');
SELECT hims_create_index('idx_bed_allocations_patient_date', 'public.bed_allocations',
    ARRAY['patient_id','allocation_date'], 'patient_id, allocation_date');

-- Prescriptions
SELECT hims_create_index('idx_prescriptions_opd_created', 'public.prescriptions',
    ARRAY['opd_registration_id','created_at'], 'opd_registration_id, created_at DESC');
SELECT hims_create_index('idx_prescriptions_ipd', 'public.prescriptions',
    ARRAY['ipd_admission_id'], 'ipd_admission_id');
SELECT hims_create_index('idx_prescription_items_prescription', 'public.prescription_items',
    ARRAY['prescription_id','created_at'], 'prescription_id, created_at');

-- Pharmacy medicines
SELECT hims_create_index('idx_pharmacy_medicines_hospital_active', 'public.pharmacy_medicines',
    ARRAY['hospital_id','is_active'], 'hospital_id, is_active');

-- IPD charges / ward transfers / dashboard tables
SELECT hims_create_index('idx_ipd_charges_admission_date', 'public.ipd_charges',
    ARRAY['admission_id','charge_date'], 'admission_id, charge_date DESC');
SELECT hims_create_index('idx_ward_transfers_admission_date', 'public.ward_transfers',
    ARRAY['admission_id','transfer_date'], 'admission_id, transfer_date DESC');
SELECT hims_create_index('idx_ipd_vitals_admission_recorded', 'public.ipd_vitals',
    ARRAY['admission_id','recorded_at'], 'admission_id, recorded_at DESC');
SELECT hims_create_index('idx_ipd_progress_notes_admission_date', 'public.ipd_progress_notes',
    ARRAY['admission_id','note_date'], 'admission_id, note_date DESC');
SELECT hims_create_index('idx_ipd_medications_admission_date', 'public.ipd_medications',
    ARRAY['admission_id','start_date'], 'admission_id, start_date DESC');
SELECT hims_create_index('idx_ipd_reports_admission_date', 'public.ipd_reports',
    ARRAY['admission_id','report_date'], 'admission_id, report_date DESC');

-- IPD pricing / packages / service master
SELECT hims_create_index('idx_ipd_ward_pricing_active', 'public.ipd_ward_pricing',
    ARRAY['is_active','daily_rate'], 'is_active, daily_rate');
SELECT hims_create_index('idx_ipd_packages_active_name', 'public.ipd_packages',
    ARRAY['is_active','name'], 'is_active, name');
SELECT hims_create_index('idx_ipd_service_master_active', 'public.ipd_service_master',
    ARRAY['is_active','name'], 'is_active, name');

-- Diagnostics support
SELECT hims_create_index('idx_diagnostic_tests_hospital_active', 'public.diagnostic_tests',
    ARRAY['hospital_id','is_active'], 'hospital_id, is_active');
SELECT hims_create_index('idx_diagnostic_tests_hospital_category', 'public.diagnostic_tests',
    ARRAY['hospital_id','category','test_name'], 'hospital_id, category, test_name');
SELECT hims_create_index('idx_diagnostic_order_items_order_date', 'public.diagnostic_order_items',
    ARRAY['order_id','created_at'], 'order_id, created_at');
SELECT hims_create_index('idx_lab_revenue_hospital_collected', 'public.lab_revenue',
    ARRAY['hospital_id','collected_at'], 'hospital_id, collected_at DESC');

-- Payments
SELECT hims_create_index('idx_payments_hospital_date', 'public.payments',
    ARRAY['hospital_id','payment_date'], 'hospital_id, payment_date DESC');

-- ======================================================================
-- 8. SEARCH OPTIMIZATION (pg_trgm GIN)
-- ======================================================================
CREATE EXTENSION IF NOT EXISTS pg_trgm;

SELECT hims_create_index('idx_patients_search_trgm', 'public.patients',
    ARRAY['uhid','first_name','last_name','mobile_number'],
    'uhid gin_trgm_ops, first_name gin_trgm_ops, last_name gin_trgm_ops, mobile_number gin_trgm_ops',
    'gin');

SELECT hims_create_index('idx_pharmacy_medicines_search_trgm', 'public.pharmacy_medicines',
    ARRAY['medicine_name','generic_name','brand_name'],
    'medicine_name gin_trgm_ops, generic_name gin_trgm_ops, brand_name gin_trgm_ops',
    'gin');

-- ======================================================================
-- 9. DOCTORS TABLE (agar exist karta hai toh hi banega)
-- ======================================================================
SELECT hims_create_index('idx_doctors_hospital_department_active', 'public.doctors',
    ARRAY['hospital_id','department_id','is_active'],
    'hospital_id, department_id, is_active');
SELECT hims_create_index('idx_doctors_department_active_name', 'public.doctors',
    ARRAY['department_id','is_active','name'],
    'department_id, is_active, name');

-- ======================================================================
-- 10. VERIFY (run separately if you want to inspect the result)
-- ======================================================================
-- SELECT tablename, indexname, indexdef
-- FROM pg_indexes
-- WHERE schemaname = 'public'
--   AND indexname LIKE 'idx_%'
-- ORDER BY tablename, indexname;
