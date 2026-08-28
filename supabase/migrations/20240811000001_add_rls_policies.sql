-- ======================================================================
-- Add RLS policies for all tables accessed by the HIMS application
-- Fixes: permission denied for table patients (and others)
-- ======================================================================

-- 1. PATIENTS
CREATE POLICY "Enable all access for authenticated users on patients"
    ON patients FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 2. PATIENT INSURANCES
CREATE POLICY "Enable all access for authenticated users on patient_insurances"
    ON patient_insurances FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 3. ABHA LINKING LOGS
CREATE POLICY "Enable all access for authenticated users on abha_linking_logs"
    ON abha_linking_logs FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 4. OPD REGISTRATIONS
CREATE POLICY "Enable all access for authenticated users on opd_registrations"
    ON opd_registrations FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 5. BEDS
CREATE POLICY "Enable all access for authenticated users on beds"
    ON beds FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 6. BED ALLOCATIONS
CREATE POLICY "Enable all access for authenticated users on bed_allocations"
    ON bed_allocations FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 7. IPD ADMISSIONS
CREATE POLICY "Enable all access for authenticated users on ipd_admissions"
    ON ipd_admissions FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 8. VITALS
CREATE POLICY "Enable all access for authenticated users on vitals"
    ON vitals FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 9. PROGRESS NOTES
CREATE POLICY "Enable all access for authenticated users on progress_notes"
    ON progress_notes FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 10. PRESCRIPTIONS
CREATE POLICY "Enable all access for authenticated users on prescriptions"
    ON prescriptions FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 11. MEDICATION ADMINISTRATION
CREATE POLICY "Enable all access for authenticated users on medication_administration"
    ON medication_administration FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 12. INVESTIGATIONS
CREATE POLICY "Enable all access for authenticated users on investigations"
    ON investigations FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 13. INVESTIGATION RESULTS
CREATE POLICY "Enable all access for authenticated users on investigation_results"
    ON investigation_results FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 14. LAB ORDERS
CREATE POLICY "Enable all access for authenticated users on lab_orders"
    ON lab_orders FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 15. LAB RESULTS
CREATE POLICY "Enable all access for authenticated users on lab_results"
    ON lab_results FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 16. PHARMACY STOCK
CREATE POLICY "Enable all access for authenticated users on pharmacy_stock"
    ON pharmacy_stock FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 17. PHARMACY PURCHASES
CREATE POLICY "Enable all access for authenticated users on pharmacy_purchases"
    ON pharmacy_purchases FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 18. PURCHASE ENTRIES
CREATE POLICY "Enable all access for authenticated users on purchase_entries"
    ON purchase_entries FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 19. STOCK CHECKS
CREATE POLICY "Enable all access for authenticated users on stock_checks"
    ON stock_checks FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 20. STOCK CHECK DISCREPANCIES
CREATE POLICY "Enable all access for authenticated users on stock_check_discrepancies"
    ON stock_check_discrepancies FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 21. DAILY HISAB
CREATE POLICY "Enable all access for authenticated users on daily_hisab"
    ON daily_hisab FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 22. DAILY HISAB EXPENSES
CREATE POLICY "Enable all access for authenticated users on daily_hisab_expenses"
    ON daily_hisab_expenses FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 23. BILLING
CREATE POLICY "Enable all access for authenticated users on billing"
    ON billing FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 24. BILLING ITEMS
CREATE POLICY "Enable all access for authenticated users on billing_items"
    ON billing_items FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 25. INSURANCE CLAIMS
CREATE POLICY "Enable all access for authenticated users on insurance_claims"
    ON insurance_claims FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 26. CARE CONTEXTS
CREATE POLICY "Enable all access for authenticated users on care_contexts"
    ON care_contexts FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 27. CONSENT ARTEFACTS
CREATE POLICY "Enable all access for authenticated users on consent_artefacts"
    ON consent_artefacts FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 28. DATA FLOW LOGS
CREATE POLICY "Enable all access for authenticated users on data_flow_logs"
    ON data_flow_logs FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 29. NOTIFICATIONS
CREATE POLICY "Enable all access for authenticated users on notifications"
    ON notifications FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 30. AUDIT LOGS
CREATE POLICY "Enable all access for authenticated users on audit_logs"
    ON audit_logs FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- 31. USERS
CREATE POLICY "Enable all access for authenticated users on users"
    ON users FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- Also add INSERT/UPDATE/DELETE for the tables that only have SELECT policies
-- (hospitals, departments, lab_tests, pharmacy_medicines are only SELECT in initial schema)

CREATE POLICY "Enable insert for authenticated users on hospitals"
    ON hospitals FOR INSERT TO authenticated WITH CHECK (true);

CREATE POLICY "Enable update for authenticated users on hospitals"
    ON hospitals FOR UPDATE TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "Enable delete for authenticated users on hospitals"
    ON hospitals FOR DELETE TO authenticated USING (true);

CREATE POLICY "Enable insert for authenticated users on departments"
    ON departments FOR INSERT TO authenticated WITH CHECK (true);

CREATE POLICY "Enable update for authenticated users on departments"
    ON departments FOR UPDATE TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "Enable delete for authenticated users on departments"
    ON departments FOR DELETE TO authenticated USING (true);

CREATE POLICY "Enable insert for authenticated users on lab_tests"
    ON lab_tests FOR INSERT TO authenticated WITH CHECK (true);

CREATE POLICY "Enable update for authenticated users on lab_tests"
    ON lab_tests FOR UPDATE TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "Enable delete for authenticated users on lab_tests"
    ON lab_tests FOR DELETE TO authenticated USING (true);

CREATE POLICY "Enable insert for authenticated users on pharmacy_medicines"
    ON pharmacy_medicines FOR INSERT TO authenticated WITH CHECK (true);

CREATE POLICY "Enable update for authenticated users on pharmacy_medicines"
    ON pharmacy_medicines FOR UPDATE TO authenticated USING (true) WITH CHECK (true);

CREATE POLICY "Enable delete for authenticated users on pharmacy_medicines"
    ON pharmacy_medicines FOR DELETE TO authenticated USING (true);