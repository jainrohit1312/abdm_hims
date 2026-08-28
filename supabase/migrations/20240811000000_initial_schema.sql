-- ======================================================================
-- HIMS - Hospital Information Management System
-- Initial Database Schema
-- ======================================================================

-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ======================================================================
-- 1. USERS & AUTH
-- ======================================================================

CREATE TABLE hospitals (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,
    code VARCHAR(50) UNIQUE NOT NULL,
    address TEXT,
    city VARCHAR(100),
    state VARCHAR(100),
    pincode VARCHAR(10),
    phone VARCHAR(20),
    email VARCHAR(255),
    registration_number VARCHAR(100),
    logo_url TEXT,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE departments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID NOT NULL REFERENCES hospitals(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    code VARCHAR(50),
    description TEXT,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    auth_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    department_id UUID REFERENCES departments(id) ON DELETE SET NULL,
    first_name VARCHAR(100) NOT NULL,
    last_name VARCHAR(100),
    email VARCHAR(255) UNIQUE NOT NULL,
    phone VARCHAR(20),
    role VARCHAR(50) NOT NULL DEFAULT 'staff', -- super_admin, admin, doctor, nurse, pharmacist, receptionist, billing_staff, lab_technician
    designation VARCHAR(100),
    license_number VARCHAR(100),
    specialization VARCHAR(255),
    is_active BOOLEAN DEFAULT true,
    last_login_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ======================================================================
-- 2. PATIENTS
-- ======================================================================

CREATE TABLE patients (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    uhid VARCHAR(50) UNIQUE NOT NULL, -- Unique Health ID
    first_name VARCHAR(100) NOT NULL,
    middle_name VARCHAR(100),
    last_name VARCHAR(100),
    date_of_birth DATE,
    age INTEGER,
    gender VARCHAR(20), -- male, female, other
    blood_group VARCHAR(5),
    marital_status VARCHAR(20),
    
    -- Contact Info
    mobile_number VARCHAR(20),
    alternate_mobile VARCHAR(20),
    email VARCHAR(255),
    
    -- Address
    address_line1 TEXT,
    address_line2 TEXT,
    city VARCHAR(100),
    state VARCHAR(100),
    pincode VARCHAR(10),
    country VARCHAR(50) DEFAULT 'India',
    
    -- Emergency Contact
    emergency_contact_name VARCHAR(200),
    emergency_contact_number VARCHAR(20),
    emergency_contact_relation VARCHAR(50),
    
    -- ABHA
    abha_id VARCHAR(20),
    abha_number VARCHAR(20),
    abha_linked BOOLEAN DEFAULT false,
    
    -- Documents
    aadhaar_number VARCHAR(20),
    photo_url TEXT,
    
    -- Status
    is_active BOOLEAN DEFAULT true,
    registration_date DATE DEFAULT CURRENT_DATE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_patients_uhid ON patients(uhid);
CREATE INDEX idx_patients_mobile ON patients(mobile_number);
CREATE INDEX idx_patients_name ON patients(first_name, last_name);
CREATE INDEX idx_patients_abha ON patients(abha_id);

CREATE TABLE patient_insurances (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    patient_id UUID NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    insurance_provider VARCHAR(255),
    policy_number VARCHAR(100),
    policy_holder_name VARCHAR(200),
    policy_holder_relation VARCHAR(50),
    insurance_type VARCHAR(50), -- individual, family, corporate, government
    coverage_amount DECIMAL(12,2),
    valid_from DATE,
    valid_to DATE,
    tpa_name VARCHAR(255),
    tpa_code VARCHAR(100),
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ======================================================================
-- 3. ABHA LINKING LOGS
-- ======================================================================

CREATE TABLE abha_linking_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    patient_id UUID REFERENCES patients(id) ON DELETE CASCADE,
    abha_id VARCHAR(20),
    request_type VARCHAR(50), -- link, unlink, verify, create
    request_payload JSONB,
    response_payload JSONB,
    status VARCHAR(50), -- success, failed, pending
    error_message TEXT,
    transaction_id VARCHAR(100),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ======================================================================
-- 4. OPD (Outpatient Department)
-- ======================================================================

CREATE TABLE opd_registrations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    patient_id UUID NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
    doctor_id UUID REFERENCES users(id) ON DELETE SET NULL,
    department_id UUID REFERENCES departments(id) ON DELETE SET NULL,
    visit_date DATE NOT NULL DEFAULT CURRENT_DATE,
    visit_time TIME,
    token_number INTEGER,
    consultation_type VARCHAR(50) DEFAULT 'general', -- general, emergency, follow_up, referral
    chief_complaint TEXT,
    symptoms TEXT,
    vital_signs JSONB,
    
    -- Diagnosis & Treatment
    diagnosis TEXT,
    treatment_advice TEXT,
    follow_up_date DATE,
    referred_to VARCHAR(255),
    
    -- Status
    status VARCHAR(50) DEFAULT 'waiting', -- waiting, in_consultation, completed, cancelled, no_show
    consultation_fee DECIMAL(10,2),
    is_emergency BOOLEAN DEFAULT false,
    
    created_by UUID REFERENCES users(id),
    completed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_opd_date ON opd_registrations(visit_date);
CREATE INDEX idx_opd_doctor ON opd_registrations(doctor_id);
CREATE INDEX idx_opd_patient ON opd_registrations(patient_id);
CREATE INDEX idx_opd_status ON opd_registrations(status);

-- ======================================================================
-- 5. IPD (Inpatient Department)
-- ======================================================================

CREATE TABLE beds (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    bed_number VARCHAR(50) NOT NULL,
    ward_name VARCHAR(100),
    room_number VARCHAR(50),
    ward_type VARCHAR(50), -- general, semi_private, private, deluxe, icu, nicu, picu, emergency
    floor_number VARCHAR(20),
    bed_type VARCHAR(50), -- manual, electric, icu_bed
    daily_charge DECIMAL(10,2) DEFAULT 0,
    status VARCHAR(50) DEFAULT 'available', -- available, occupied, reserved, maintenance, cleaning
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(hospital_id, bed_number)
);

CREATE INDEX idx_beds_status ON beds(status);
CREATE INDEX idx_beds_ward ON beds(ward_type);

CREATE TABLE bed_allocations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    bed_id UUID NOT NULL REFERENCES beds(id) ON DELETE RESTRICT,
    patient_id UUID NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    allocation_date DATE NOT NULL DEFAULT CURRENT_DATE,
    allocation_time TIME,
    discharge_date DATE,
    discharge_time TIME,
    discharge_reason TEXT,
    notes TEXT,
    status VARCHAR(50) DEFAULT 'active', -- active, discharged, transfer_out
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE ipd_admissions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    patient_id UUID NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
    bed_allocation_id UUID REFERENCES bed_allocations(id) ON DELETE SET NULL,
    doctor_id UUID REFERENCES users(id) ON DELETE SET NULL,
    department_id UUID REFERENCES departments(id) ON DELETE SET NULL,
    admission_date DATE NOT NULL DEFAULT CURRENT_DATE,
    admission_time TIME,
    admission_type VARCHAR(50), -- emergency, planned, transfer
    primary_diagnosis TEXT,
    secondary_diagnosis TEXT,
    
    -- Discharge
    discharge_date DATE,
    discharge_time TIME,
    discharge_type VARCHAR(50), -- normal, dama, absconded, death, transfer
    discharge_summary TEXT,
    discharge_instructions TEXT,
    
    -- Treatment
    treatment_plan TEXT,
    surgery_required BOOLEAN DEFAULT false,
    isolation_required BOOLEAN DEFAULT false,
    
    status VARCHAR(50) DEFAULT 'admitted', -- admitted, discharged, transferred
    created_by UUID REFERENCES users(id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_ipd_admission_date ON ipd_admissions(admission_date);
CREATE INDEX idx_ipd_patient ON ipd_admissions(patient_id);
CREATE INDEX idx_ipd_doctor ON ipd_admissions(doctor_id);

-- ======================================================================
-- 6. CLINICAL - VITALS & NOTES
-- ======================================================================

CREATE TABLE vitals (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    patient_id UUID NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
    ipd_admission_id UUID REFERENCES ipd_admissions(id) ON DELETE CASCADE,
    opd_registration_id UUID REFERENCES opd_registrations(id) ON DELETE CASCADE,
    recorded_by UUID REFERENCES users(id) ON DELETE SET NULL,
    recorded_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- Vitals
    temperature DECIMAL(4,1), -- in Celsius
    pulse_rate INTEGER, -- bpm
    respiratory_rate INTEGER, -- breaths/min
    blood_pressure_systolic INTEGER,
    blood_pressure_diastolic INTEGER,
    spo2 DECIMAL(4,1), -- oxygen saturation %
    blood_sugar DECIMAL(5,1), -- mg/dL
    weight DECIMAL(5,2), -- kg
    height DECIMAL(5,2), -- cm
    bmi DECIMAL(4,1),
    pain_score INTEGER CHECK (pain_score >= 0 AND pain_score <= 10),
    gcs_score INTEGER, -- Glasgow Coma Scale
    
    -- Additional
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_vitals_patient ON vitals(patient_id);
CREATE INDEX idx_vitals_date ON vitals(recorded_at);

CREATE TABLE progress_notes (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    patient_id UUID NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
    ipd_admission_id UUID REFERENCES ipd_admissions(id) ON DELETE CASCADE,
    doctor_id UUID REFERENCES users(id) ON DELETE SET NULL,
    note_date DATE NOT NULL DEFAULT CURRENT_DATE,
    note_time TIME NOT NULL DEFAULT CURRENT_TIME,
    subjective TEXT, -- Patient's complaints
    objective TEXT, -- Doctor's observations
    assessment TEXT, -- Diagnosis/Assessment
    plan TEXT, -- Treatment plan
    note_type VARCHAR(50) DEFAULT 'daily', -- daily, admission, discharge, procedure
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_notes_patient ON progress_notes(patient_id);
CREATE INDEX idx_notes_ipd ON progress_notes(ipd_admission_id);

-- ======================================================================
-- 7. PRESCRIPTIONS & MEDICATIONS
-- ======================================================================

CREATE TABLE prescriptions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    patient_id UUID NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
    ipd_admission_id UUID REFERENCES ipd_admissions(id) ON DELETE CASCADE,
    opd_registration_id UUID REFERENCES opd_registrations(id) ON DELETE CASCADE,
    doctor_id UUID REFERENCES users(id) ON DELETE SET NULL,
    prescription_date DATE NOT NULL DEFAULT CURRENT_DATE,
    
    -- Medication Details
    medicine_name VARCHAR(255) NOT NULL,
    dosage VARCHAR(100),
    frequency VARCHAR(100),
    duration VARCHAR(100),
    route VARCHAR(50), -- oral, iv, im, sc, topical, etc.
    instructions TEXT,
    
    quantity_prescribed DECIMAL(10,2),
    quantity_dispensed DECIMAL(10,2) DEFAULT 0,
    
    status VARCHAR(50) DEFAULT 'active', -- active, completed, discontinued, cancelled
    start_date DATE,
    end_date DATE,
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_prescriptions_patient ON prescriptions(patient_id);

CREATE TABLE medication_administration (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    prescription_id UUID NOT NULL REFERENCES prescriptions(id) ON DELETE CASCADE,
    patient_id UUID NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
    administered_by UUID REFERENCES users(id) ON DELETE SET NULL,
    administration_date DATE NOT NULL DEFAULT CURRENT_DATE,
    administration_time TIME NOT NULL DEFAULT CURRENT_TIME,
    
    dosage_given VARCHAR(100),
    route VARCHAR(50),
    
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ======================================================================
-- 8. INVESTIGATIONS (Radiology, etc.)
-- ======================================================================

CREATE TABLE investigations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    patient_id UUID NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
    ipd_admission_id UUID REFERENCES ipd_admissions(id) ON DELETE CASCADE,
    opd_registration_id UUID REFERENCES opd_registrations(id) ON DELETE CASCADE,
    doctor_id UUID REFERENCES users(id) ON DELETE SET NULL,
    investigation_name VARCHAR(255) NOT NULL,
    investigation_type VARCHAR(50), -- x_ray, ct_scan, mri, ultrasound, ecg, echo, etc.
    body_part VARCHAR(100),
    urgency VARCHAR(20) DEFAULT 'routine', -- routine, urgent, stat
    clinical_notes TEXT,
    
    status VARCHAR(50) DEFAULT 'ordered', -- ordered, in_progress, completed, cancelled
    ordered_date DATE DEFAULT CURRENT_DATE,
    completed_date DATE,
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE investigation_results (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    investigation_id UUID NOT NULL REFERENCES investigations(id) ON DELETE CASCADE,
    reported_by UUID REFERENCES users(id) ON DELETE SET NULL,
    result_text TEXT,
    findings TEXT,
    impression TEXT,
    recommendations TEXT,
    result_file_url TEXT,
    status VARCHAR(50) DEFAULT 'draft', -- draft, final, amended
    result_date TIMESTAMPTZ DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ======================================================================
-- 9. LABORATORY
-- ======================================================================

CREATE TABLE lab_tests (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    test_name VARCHAR(255) NOT NULL,
    test_code VARCHAR(50) UNIQUE,
    test_category VARCHAR(100), -- hematology, biochemistry, microbiology, serology, pathology
    sample_type VARCHAR(100), -- blood, urine, stool, sputum, swab, etc.
    normal_range TEXT,
    unit VARCHAR(50),
    test_price DECIMAL(10,2) DEFAULT 0,
    turnaround_time_hours INTEGER,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE lab_orders (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    patient_id UUID NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
    ipd_admission_id UUID REFERENCES ipd_admissions(id) ON DELETE CASCADE,
    opd_registration_id UUID REFERENCES opd_registrations(id) ON DELETE CASCADE,
    doctor_id UUID REFERENCES users(id) ON DELETE SET NULL,
    order_date DATE DEFAULT CURRENT_DATE,
    urgency VARCHAR(20) DEFAULT 'routine', -- routine, urgent, stat
    clinical_diagnosis TEXT,
    notes TEXT,
    status VARCHAR(50) DEFAULT 'ordered', -- ordered, sample_collected, in_progress, completed, cancelled
    collected_at TIMESTAMPTZ,
    collected_by UUID REFERENCES users(id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE lab_results (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    lab_order_id UUID NOT NULL REFERENCES lab_orders(id) ON DELETE CASCADE,
    lab_test_id UUID NOT NULL REFERENCES lab_tests(id) ON DELETE RESTRICT,
    tested_by UUID REFERENCES users(id) ON DELETE SET NULL,
    result_value TEXT,
    is_abnormal BOOLEAN DEFAULT false,
    reference_range TEXT,
    notes TEXT,
    result_date TIMESTAMPTZ DEFAULT NOW(),
    status VARCHAR(50) DEFAULT 'draft', -- draft, final, amended
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ======================================================================
-- 10. PHARMACY
-- ======================================================================

CREATE TABLE pharmacy_medicines (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    medicine_name VARCHAR(255) NOT NULL,
    generic_name VARCHAR(255),
    brand_name VARCHAR(255),
    manufacturer VARCHAR(255),
    category VARCHAR(100), -- analgesic, antibiotic, antihypertensive, etc.
    drug_form VARCHAR(50), -- tablet, capsule, syrup, injection, ointment, etc.
    strength VARCHAR(100), -- e.g., 500mg, 10mg/ml
    packaging VARCHAR(100), -- e.g., strip of 10, vial of 5ml
    mrp DECIMAL(10,2),
    purchase_price DECIMAL(10,2),
    selling_price DECIMAL(10,2),
    hsn_code VARCHAR(20),
    gst_percentage DECIMAL(4,2) DEFAULT 0,
    is_controlled_drug BOOLEAN DEFAULT false,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE pharmacy_stock (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    medicine_id UUID NOT NULL REFERENCES pharmacy_medicines(id) ON DELETE CASCADE,
    batch_number VARCHAR(100),
    expiry_date DATE,
    quantity INTEGER NOT NULL DEFAULT 0,
    min_stock_level INTEGER DEFAULT 10,
    max_stock_level INTEGER DEFAULT 1000,
    rack_location VARCHAR(100),
    storage_condition VARCHAR(100), -- room temp, cold chain, etc.
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_stock_medicine ON pharmacy_stock(medicine_id);
CREATE INDEX idx_stock_expiry ON pharmacy_stock(expiry_date);

CREATE TABLE pharmacy_purchases (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    supplier_name VARCHAR(255),
    invoice_number VARCHAR(100),
    invoice_date DATE DEFAULT CURRENT_DATE,
    total_amount DECIMAL(12,2),
    gst_amount DECIMAL(12,2),
    net_amount DECIMAL(12,2),
    payment_status VARCHAR(50) DEFAULT 'pending', -- pending, partial, paid
    notes TEXT,
    created_by UUID REFERENCES users(id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE purchase_entries (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    purchase_id UUID NOT NULL REFERENCES pharmacy_purchases(id) ON DELETE CASCADE,
    medicine_id UUID NOT NULL REFERENCES pharmacy_medicines(id) ON DELETE RESTRICT,
    quantity INTEGER NOT NULL,
    batch_number VARCHAR(100),
    expiry_date DATE,
    unit_price DECIMAL(10,2),
    mrp DECIMAL(10,2),
    gst_percentage DECIMAL(4,2),
    total_amount DECIMAL(10,2),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE stock_checks (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    checked_by UUID REFERENCES users(id),
    check_date DATE DEFAULT CURRENT_DATE,
    notes TEXT,
    status VARCHAR(50) DEFAULT 'in_progress', -- in_progress, completed
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE stock_check_discrepancies (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    stock_check_id UUID NOT NULL REFERENCES stock_checks(id) ON DELETE CASCADE,
    medicine_id UUID NOT NULL REFERENCES pharmacy_medicines(id) ON DELETE RESTRICT,
    expected_quantity INTEGER,
    actual_quantity INTEGER,
    difference INTEGER,
    reason TEXT,
    action_taken TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ======================================================================
-- 11. DAILY HISAB (Accounting)
-- ======================================================================

CREATE TABLE daily_hisab (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    entry_date DATE NOT NULL DEFAULT CURRENT_DATE,
    opening_balance DECIMAL(12,2) DEFAULT 0,
    total_income DECIMAL(12,2) DEFAULT 0,
    total_expense DECIMAL(12,2) DEFAULT 0,
    closing_balance DECIMAL(12,2) DEFAULT 0,
    notes TEXT,
    created_by UUID REFERENCES users(id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(hospital_id, entry_date)
);

CREATE TABLE daily_hisab_expenses (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    daily_hisab_id UUID NOT NULL REFERENCES daily_hisab(id) ON DELETE CASCADE,
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    expense_category VARCHAR(100), -- salary, utility, maintenance, supplies, etc.
    expense_description TEXT,
    amount DECIMAL(10,2) NOT NULL,
    payment_mode VARCHAR(50), -- cash, card, online, cheque
    reference_number VARCHAR(100),
    vendor_name VARCHAR(255),
    created_by UUID REFERENCES users(id),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ======================================================================
-- 12. BILLING
-- ======================================================================

CREATE TABLE billing (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    patient_id UUID NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
    ipd_admission_id UUID REFERENCES ipd_admissions(id) ON DELETE SET NULL,
    opd_registration_id UUID REFERENCES opd_registrations(id) ON DELETE SET NULL,
    bill_number VARCHAR(50) UNIQUE NOT NULL,
    bill_date DATE NOT NULL DEFAULT CURRENT_DATE,
    bill_type VARCHAR(50), -- opd, ipd, pharmacy, lab, radiology, procedure, discharge
    
    -- Amounts
    total_amount DECIMAL(12,2) NOT NULL DEFAULT 0,
    discount_amount DECIMAL(12,2) DEFAULT 0,
    discount_reason TEXT,
    tax_amount DECIMAL(12,2) DEFAULT 0,
    net_amount DECIMAL(12,2) NOT NULL DEFAULT 0,
    paid_amount DECIMAL(12,2) DEFAULT 0,
    balance_amount DECIMAL(12,2) DEFAULT 0,
    
    -- Payment
    payment_status VARCHAR(50) DEFAULT 'unpaid', -- unpaid, partially_paid, paid, refunded, waived
    payment_mode VARCHAR(50), -- cash, card, upi, online, insurance, cheque
    transaction_reference VARCHAR(255),
    payment_date TIMESTAMPTZ,
    
    status VARCHAR(50) DEFAULT 'draft', -- draft, generated, paid, cancelled
    created_by UUID REFERENCES users(id),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_billing_patient ON billing(patient_id);
CREATE INDEX idx_billing_date ON billing(bill_date);
CREATE INDEX idx_billing_status ON billing(payment_status);

CREATE TABLE billing_items (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    bill_id UUID NOT NULL REFERENCES billing(id) ON DELETE CASCADE,
    item_type VARCHAR(100), -- consultation, room_charge, medicine, lab_test, procedure, nursing, others
    item_name VARCHAR(255) NOT NULL,
    item_code VARCHAR(100),
    quantity INTEGER DEFAULT 1,
    unit_price DECIMAL(10,2) NOT NULL,
    total_price DECIMAL(12,2) NOT NULL,
    discount DECIMAL(10,2) DEFAULT 0,
    gst_percentage DECIMAL(4,2) DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ======================================================================
-- 13. INSURANCE CLAIMS
-- ======================================================================

CREATE TABLE insurance_claims (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    patient_id UUID NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
    patient_insurance_id UUID REFERENCES patient_insurances(id) ON DELETE SET NULL,
    bill_id UUID REFERENCES billing(id) ON DELETE SET NULL,
    claim_number VARCHAR(100) UNIQUE,
    claim_date DATE DEFAULT CURRENT_DATE,
    claim_amount DECIMAL(12,2),
    approved_amount DECIMAL(12,2) DEFAULT 0,
    rejection_reason TEXT,
    status VARCHAR(50) DEFAULT 'submitted', -- draft, submitted, in_review, approved, rejected, settled
    submitted_date DATE,
    settled_date DATE,
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ======================================================================
-- 14. CARE CONTEXTS & CONSENT (ABDM)
-- ======================================================================

CREATE TABLE care_contexts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    patient_id UUID NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
    abha_id VARCHAR(20),
    care_context_type VARCHAR(50), -- opd_visit, ipd_admission, prescription, lab_report, discharge_summary
    care_context_reference_id UUID,
    abdm_care_context_id VARCHAR(255),
    is_linked BOOLEAN DEFAULT false,
    linked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE consent_artefacts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    patient_id UUID NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
    care_context_id UUID REFERENCES care_contexts(id) ON DELETE CASCADE,
    consent_id VARCHAR(255) UNIQUE,
    consent_type VARCHAR(50), -- view, store, share
    hip_id VARCHAR(255),
    hiu_id VARCHAR(255),
    purpose TEXT,
    data_from DATE,
    data_to DATE,
    status VARCHAR(50), -- requested, granted, denied, expired, revoked
    granted_at TIMESTAMPTZ,
    expires_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE data_flow_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    patient_id UUID REFERENCES patients(id) ON DELETE CASCADE,
    consent_id VARCHAR(255),
    transaction_id VARCHAR(100),
    data_type VARCHAR(50),
    request_payload JSONB,
    response_payload JSONB,
    status VARCHAR(50), -- success, failed
    error_message TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ======================================================================
-- 15. NOTIFICATIONS & AUDIT LOGS
-- ======================================================================

CREATE TABLE notifications (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    user_id UUID REFERENCES users(id) ON DELETE CASCADE,
    title VARCHAR(255) NOT NULL,
    message TEXT,
    notification_type VARCHAR(50), -- info, alert, reminder, system
    is_read BOOLEAN DEFAULT false,
    read_at TIMESTAMPTZ,
    link_url TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_notifications_user ON notifications(user_id);
CREATE INDEX idx_notifications_read ON notifications(is_read);

CREATE TABLE audit_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL,
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    action VARCHAR(100) NOT NULL, -- create, update, delete, view, login, logout, export
    entity_type VARCHAR(100) NOT NULL, -- patient, billing, prescription, etc.
    entity_id UUID,
    old_values JSONB,
    new_values JSONB,
    ip_address VARCHAR(45),
    user_agent TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_audit_user ON audit_logs(user_id);
CREATE INDEX idx_audit_entity ON audit_logs(entity_type);
CREATE INDEX idx_audit_date ON audit_logs(created_at);

-- ======================================================================
-- 16. SEED DATA - DEFAULT HOSPITAL & DEPARTMENTS
-- ======================================================================

INSERT INTO hospitals (name, code, address, city, state, phone, email) VALUES
('HIMS Main Hospital', 'HIMS', '123 Healthcare Avenue', 'New Delhi', 'Delhi', '011-23456789', 'admin@himshospital.com');

INSERT INTO departments (hospital_id, name, code, description) VALUES
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'General Medicine', 'GENMED', 'General Medicine & Internal Medicine'),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'Cardiology', 'CARD', 'Heart and Cardiovascular Care'),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'Orthopedics', 'ORTHO', 'Bone and Joint Care'),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'Pediatrics', 'PED', 'Child Healthcare'),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'Obstetrics & Gynecology', 'OBGYN', 'Women Health and Maternity'),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'ENT', 'ENT', 'Ear, Nose and Throat'),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'Ophthalmology', 'OPTH', 'Eye Care'),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'Dermatology', 'DERM', 'Skin Care'),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'Dental', 'DENT', 'Dental Care'),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'Emergency', 'ER', 'Emergency & Trauma Care'),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'ICU', 'ICU', 'Intensive Care Unit'),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'Radiology', 'RAD', 'Imaging & Radiology'),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'Pathology', 'PATH', 'Laboratory & Pathology'),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'Pharmacy', 'PHARM', 'Pharmacy Services');

-- Insert some sample beds
INSERT INTO beds (hospital_id, bed_number, ward_name, room_number, ward_type, floor_number, daily_charge) VALUES
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'ICU-01', 'ICU', 'ICU-1', 'icu', '1st Floor', 5000),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'ICU-02', 'ICU', 'ICU-1', 'icu', '1st Floor', 5000),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'ICU-03', 'ICU', 'ICU-1', 'icu', '1st Floor', 5000),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'GW-M01', 'Male General Ward', 'GW-M', 'general', '2nd Floor', 500),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'GW-M02', 'Male General Ward', 'GW-M', 'general', '2nd Floor', 500),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'GW-M03', 'Male General Ward', 'GW-M', 'general', '2nd Floor', 500),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'GW-F01', 'Female General Ward', 'GW-F', 'general', '2nd Floor', 500),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'GW-F02', 'Female General Ward', 'GW-F', 'general', '2nd Floor', 500),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'GW-F03', 'Female General Ward', 'GW-F', 'general', '2nd Floor', 500),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'SP-101', 'Semi Private Room 101', '101', 'semi_private', '3rd Floor', 1500),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'SP-102', 'Semi Private Room 101', '101', 'semi_private', '3rd Floor', 1500),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'PV-201', 'Private Room 201', '201', 'private', '3rd Floor', 3000),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'PV-202', 'Private Room 202', '202', 'private', '3rd Floor', 3000),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'DLX-301', 'Deluxe Room 301', '301', 'deluxe', '4th Floor', 5000),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'DLX-302', 'Deluxe Room 302', '302', 'deluxe', '4th Floor', 5000),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'NICU-01', 'NICU', 'NICU', 'nicu', '1st Floor', 4000),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'NICU-02', 'NICU', 'NICU', 'nicu', '1st Floor', 4000),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'ER-01', 'Emergency', 'ER', 'emergency', 'Ground Floor', 1000),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'ER-02', 'Emergency', 'ER', 'emergency', 'Ground Floor', 1000),
((SELECT id FROM hospitals WHERE code = 'HIMS'), 'ER-03', 'Emergency', 'ER', 'emergency', 'Ground Floor', 1000);

-- ======================================================================
-- 17. ROW LEVEL SECURITY (RLS) POLICIES
-- ======================================================================

-- Enable RLS on all tables
DO $$
DECLARE
    tbl TEXT;
BEGIN
    FOR tbl IN 
        SELECT tablename FROM pg_tables 
        WHERE schemaname = 'public' 
        AND tablename NOT IN ('hospitals', 'departments', 'lab_tests', 'pharmacy_medicines')
    LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', tbl);
    END LOOP;
END $$;

-- Allow authenticated users to read hospitals & departments
ALTER TABLE hospitals ENABLE ROW LEVEL SECURITY;
ALTER TABLE departments ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Allow read access for authenticated users" ON hospitals
    FOR SELECT TO authenticated USING (true);

CREATE POLICY "Allow read access for authenticated users" ON departments
    FOR SELECT TO authenticated USING (true);

CREATE POLICY "Allow read access for authenticated users" ON lab_tests
    FOR SELECT TO authenticated USING (true);

CREATE POLICY "Allow read access for authenticated users" ON pharmacy_medicines
    FOR SELECT TO authenticated USING (true);