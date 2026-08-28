-- ======================================================================
-- HIMS - Unified Lab / Diagnostics Module
-- (Pathology + Radiology + Cardiology + Other Diagnostics)
--
-- Tables:
--   diagnostic_tests        -> master of all lab/radiology/cardiology tests
--   diagnostic_orders       -> order header (patient, doctor, urgency, status)
--   diagnostic_order_items  -> line items of an order
--   diagnostic_results      -> result entry per order item
--   lab_revenue             -> revenue collection log
--
-- Run manually in Supabase SQL Editor, or `supabase db push` as migration.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. DIAGNOSTIC TESTS MASTER
--    category: pathology | radiology | cardiology | other
--    sample_type is mainly for pathology (e.g. Whole Blood, Serum, Urine)
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS diagnostic_tests (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE CASCADE,
    test_name VARCHAR(255) NOT NULL,
    test_code VARCHAR(100) NOT NULL,
    category VARCHAR(50) NOT NULL DEFAULT 'pathology'
        CHECK (category IN ('pathology', 'radiology', 'cardiology', 'other')),
    sample_type VARCHAR(100),
    price NUMERIC(10, 2) NOT NULL DEFAULT 0,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_diagnostic_tests_hospital
    ON diagnostic_tests(hospital_id);
CREATE INDEX IF NOT EXISTS idx_diagnostic_tests_category
    ON diagnostic_tests(category);
CREATE INDEX IF NOT EXISTS idx_diagnostic_tests_active
    ON diagnostic_tests(is_active);

-- ----------------------------------------------------------------------
-- 2. DIAGNOSTIC ORDERS (header)
--    urgency: routine | urgent | stat
--    status:  pending | in_progress | completed | cancelled
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS diagnostic_orders (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE CASCADE,
    patient_id UUID REFERENCES patients(id) ON DELETE CASCADE,
    doctor_id UUID REFERENCES users(id) ON DELETE SET NULL,
    order_date DATE NOT NULL DEFAULT CURRENT_DATE,
    urgency VARCHAR(20) NOT NULL DEFAULT 'routine'
        CHECK (urgency IN ('routine', 'urgent', 'stat')),
    status VARCHAR(30) NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'in_progress', 'completed', 'cancelled')),
    total_amount NUMERIC(10, 2) NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_diagnostic_orders_hospital
    ON diagnostic_orders(hospital_id);
CREATE INDEX IF NOT EXISTS idx_diagnostic_orders_patient
    ON diagnostic_orders(patient_id);
CREATE INDEX IF NOT EXISTS idx_diagnostic_orders_status
    ON diagnostic_orders(status);
CREATE INDEX IF NOT EXISTS idx_diagnostic_orders_order_date
    ON diagnostic_orders(order_date);

-- ----------------------------------------------------------------------
-- 3. DIAGNOSTIC ORDER ITEMS (line items)
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS diagnostic_order_items (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_id UUID NOT NULL REFERENCES diagnostic_orders(id) ON DELETE CASCADE,
    test_id UUID REFERENCES diagnostic_tests(id) ON DELETE SET NULL,
    test_name VARCHAR(255) NOT NULL,
    category VARCHAR(50) NOT NULL DEFAULT 'pathology',
    price NUMERIC(10, 2) NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_diagnostic_order_items_order
    ON diagnostic_order_items(order_id);
CREATE INDEX IF NOT EXISTS idx_diagnostic_order_items_test
    ON diagnostic_order_items(test_id);
CREATE INDEX IF NOT EXISTS idx_diagnostic_order_items_category
    ON diagnostic_order_items(category);

-- ----------------------------------------------------------------------
-- 4. DIAGNOSTIC RESULTS (one row per order item)
--    Pathology  -> result_value + reference_range + unit
--    Radiology  -> findings + impression + recommendations + image_url
--    Cardiology -> result_value (interpretation) + image_url
--    status: draft | final | amended
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS diagnostic_results (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_item_id UUID NOT NULL REFERENCES diagnostic_order_items(id) ON DELETE CASCADE,
    result_value TEXT,
    reference_range TEXT,
    unit VARCHAR(100),
    findings TEXT,
    impression TEXT,
    recommendations TEXT,
    image_url TEXT,
    status VARCHAR(20) NOT NULL DEFAULT 'draft'
        CHECK (status IN ('draft', 'final', 'amended')),
    result_date DATE NOT NULL DEFAULT CURRENT_DATE,
    technician_id UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_diagnostic_results_order_item
    ON diagnostic_results(order_item_id);
CREATE INDEX IF NOT EXISTS idx_diagnostic_results_status
    ON diagnostic_results(status);

-- ----------------------------------------------------------------------
-- 5. LAB REVENUE
--    One row is inserted when a diagnostic order is created (collection).
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lab_revenue (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID REFERENCES hospitals(id) ON DELETE CASCADE,
    order_id UUID REFERENCES diagnostic_orders(id) ON DELETE SET NULL,
    total_amount NUMERIC(10, 2) NOT NULL DEFAULT 0,
    collected_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_lab_revenue_hospital
    ON lab_revenue(hospital_id);
CREATE INDEX IF NOT EXISTS idx_lab_revenue_collected_at
    ON lab_revenue(collected_at);

-- ----------------------------------------------------------------------
-- 6. updated_at AUTO TRIGGER
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_diagnostics_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_diagnostic_tests_updated_at ON diagnostic_tests;
CREATE TRIGGER trg_diagnostic_tests_updated_at
    BEFORE UPDATE ON diagnostic_tests
    FOR EACH ROW EXECUTE FUNCTION set_diagnostics_updated_at();

DROP TRIGGER IF EXISTS trg_diagnostic_orders_updated_at ON diagnostic_orders;
CREATE TRIGGER trg_diagnostic_orders_updated_at
    BEFORE UPDATE ON diagnostic_orders
    FOR EACH ROW EXECUTE FUNCTION set_diagnostics_updated_at();

DROP TRIGGER IF EXISTS trg_diagnostic_results_updated_at ON diagnostic_results;
CREATE TRIGGER trg_diagnostic_results_updated_at
    BEFORE UPDATE ON diagnostic_results
    FOR EACH ROW EXECUTE FUNCTION set_diagnostics_updated_at();

-- ----------------------------------------------------------------------
-- 7. ROW LEVEL SECURITY
-- ----------------------------------------------------------------------
ALTER TABLE diagnostic_tests ENABLE ROW LEVEL SECURITY;
ALTER TABLE diagnostic_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE diagnostic_order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE diagnostic_results ENABLE ROW LEVEL SECURITY;
ALTER TABLE lab_revenue ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Enable all access for authenticated users on diagnostic_tests" ON diagnostic_tests;
CREATE POLICY "Enable all access for authenticated users on diagnostic_tests"
    ON diagnostic_tests FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Enable all access for authenticated users on diagnostic_orders" ON diagnostic_orders;
CREATE POLICY "Enable all access for authenticated users on diagnostic_orders"
    ON diagnostic_orders FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Enable all access for authenticated users on diagnostic_order_items" ON diagnostic_order_items;
CREATE POLICY "Enable all access for authenticated users on diagnostic_order_items"
    ON diagnostic_order_items FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Enable all access for authenticated users on diagnostic_results" ON diagnostic_results;
CREATE POLICY "Enable all access for authenticated users on diagnostic_results"
    ON diagnostic_results FOR ALL TO authenticated USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS "Enable all access for authenticated users on lab_revenue" ON lab_revenue;
CREATE POLICY "Enable all access for authenticated users on lab_revenue"
    ON lab_revenue FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- ----------------------------------------------------------------------
-- 8. GRANTS
-- ----------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON diagnostic_tests TO authenticated, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON diagnostic_orders TO authenticated, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON diagnostic_order_items TO authenticated, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON diagnostic_results TO authenticated, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON lab_revenue TO authenticated, anon;

-- ----------------------------------------------------------------------
-- 9. DEFAULT TEST CATALOG SEED (optional but recommended)
--    Seeds the standard test list for every hospital that has no tests yet.
--    You can edit/add/delete these later from the Tests Master screen.
-- ----------------------------------------------------------------------
DO $$
DECLARE
    h record;
    v_count int;
BEGIN
    FOR h IN SELECT id FROM hospitals LOOP
        SELECT COUNT(*) INTO v_count FROM diagnostic_tests WHERE hospital_id = h.id;
        IF v_count = 0 THEN
            -- Pathology
            INSERT INTO diagnostic_tests (hospital_id, test_name, test_code, category, sample_type, price) VALUES
                (h.id, 'Complete Blood Count (CBC)',      'CBC',        'pathology',   'Whole Blood (EDTA)', 400.00),
                (h.id, 'Liver Function Test (LFT)',       'LFT',        'pathology',   'Serum',              550.00),
                (h.id, 'Kidney Function Test (KFT)',      'KFT',        'pathology',   'Serum',              500.00),
                (h.id, 'Lipid Profile',                   'LIPID',      'pathology',   'Serum (Fasting)',    600.00),
                (h.id, 'HbA1c (Glycated Hemoglobin)',     'HBA1C',      'pathology',   'Whole Blood (EDTA)', 450.00),
                (h.id, 'PT/INR',                          'PTINR',      'pathology',   'Citrated Plasma',    350.00),
                (h.id, 'Urine Routine Examination',       'URINE_RE',   'pathology',   'Urine',              150.00),
                -- Radiology
                (h.id, 'X-Ray Chest PA View',             'XR_CHEST',   'radiology',   NULL,                 350.00),
                (h.id, 'X-Ray Spine (AP/Lat)',            'XR_SPINE',   'radiology',   NULL,                 450.00),
                (h.id, 'CT Scan Head (Plain)',            'CT_HEAD',    'radiology',   NULL,                2500.00),
                (h.id, 'CT Scan Chest (Plain)',           'CT_CHEST',   'radiology',   NULL,                3000.00),
                (h.id, 'MRI Brain',                       'MRI_BRAIN',  'radiology',   NULL,                5500.00),
                (h.id, 'MRI Knee',                        'MRI_KNEE',   'radiology',   NULL,                6000.00),
                (h.id, 'Ultrasound Abdomen',              'USG_ABD',    'radiology',   NULL,                900.00),
                (h.id, 'Ultrasound Pelvis',               'USG_PELVIS', 'radiology',   NULL,                900.00),
                -- Cardiology
                (h.id, 'ECG (12 Lead)',                   'ECG',        'cardiology',  NULL,                 250.00),
                (h.id, 'Echocardiography (2D Echo)',      'ECHO',       'cardiology',  NULL,                1800.00),
                (h.id, 'Treadmill Test (TMT)',            'TMT',        'cardiology',  NULL,                2200.00),
                (h.id, 'Arterial Blood Gas (ABG)',        'ABG',        'cardiology',  'Arterial Blood',     500.00),
                -- Other Diagnostics
                (h.id, 'Pulmonary Function Test (PFT)',   'PFT',        'other',       NULL,                 800.00),
                (h.id, 'Upper GI Endoscopy',              'ENDOSCOPY',  'other',       NULL,                3500.00),
                (h.id, 'Biopsy (Histopathology)',         'BIOPSY',     'other',       'Tissue',            1200.00);
        END IF;
    END LOOP;
END $$;
