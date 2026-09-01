-- ======================================================================
-- HIMS - Unified Billing History (read-only, paginated, deduplicated)
-- ----------------------------------------------------------------------
-- Creates a read-only view that normalizes `billing` rows and raw
-- `opd_registrations` payment rows into one chronological billing history.
--
-- * Materialised OPD bills come from `billing` (source_type = 'opd').
-- * Raw OPD registrations are included only when NO materialised billing
--   row exists for them (NOT EXISTS) — this preserves the app's existing
--   deduplication behaviour at the SQL level.
-- * The app queries this view with:
--     hospital_id eq filter
--     source_type eq filter (optional)
--     order bill_date DESC, created_at DESC
--     range pagination
--
-- Adds the two genuinely missing composite indexes used by that query.
-- Idempotent — safe to run more than once.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. Unified billing history view
-- ----------------------------------------------------------------------
CREATE OR REPLACE VIEW billing_history_view AS
SELECT
    b.id::text AS record_id,
    b.id::text AS billing_id,
    COALESCE(
        b.opd_registration_id::text,
        b.ipd_admission_id::text,
        b.diagnostic_order_id::text
    ) AS source_record_id,
    COALESCE(b.source_type, 'manual') AS source_type,
    b.patient_id::text AS patient_id,
    COALESCE(
        NULLIF(TRIM(CONCAT(p.first_name, ' ', p.last_name)), ''),
        'Unknown Patient'
    ) AS patient_name,
    p.uhid AS uhid,
    COALESCE(
        b.bill_number,
        'BILL-' || LEFT(b.id::text, 8)
    ) AS bill_number,
    b.bill_date AS bill_date,
    b.created_at AS created_at,
    b.total_amount AS total_amount,
    b.net_amount AS net_amount,
    b.paid_amount AS paid_amount,
    b.balance_amount AS balance_amount,
    b.payment_status AS payment_status,
    b.payment_mode AS payment_mode,
    COALESCE(b.visit_type, b.bill_type, 'manual') AS visit_type,
    b.opd_registration_id::text AS opd_registration_id,
    b.ipd_admission_id::text AS ipd_admission_id,
    b.diagnostic_order_id::text AS diagnostic_order_id,
    b.hospital_id::text AS hospital_id
FROM billing b
LEFT JOIN patients p ON p.id = b.patient_id

UNION ALL

SELECT
    o.id::text AS record_id,
    NULL::text AS billing_id,
    o.id::text AS source_record_id,
    'opd'::text AS source_type,
    o.patient_id::text AS patient_id,
    COALESCE(
        NULLIF(TRIM(CONCAT(p.first_name, ' ', p.last_name)), ''),
        'Unknown Patient'
    ) AS patient_name,
    p.uhid AS uhid,
    'OPD-' || COALESCE(o.token_number::text, LEFT(o.id::text, 8)) AS bill_number,
    o.visit_date AS bill_date,
    o.created_at AS created_at,
    COALESCE(o.consultation_fee, 0) AS total_amount,
    COALESCE(o.consultation_fee, 0) AS net_amount,
    COALESCE(o.paid_amount, 0) AS paid_amount,
    COALESCE(o.balance_amount, 0) AS balance_amount,
    COALESCE(
        o.payment_status,
        CASE
            WHEN COALESCE(o.paid_amount, 0) >= COALESCE(o.consultation_fee, 0)
                 AND COALESCE(o.consultation_fee, 0) > 0 THEN 'paid'
            WHEN COALESCE(o.paid_amount, 0) > 0 THEN 'partially_paid'
            ELSE 'unpaid'
        END
    ) AS payment_status,
    o.payment_mode AS payment_mode,
    'opd'::text AS visit_type,
    o.id::text AS opd_registration_id,
    NULL::text AS ipd_admission_id,
    NULL::text AS diagnostic_order_id,
    o.hospital_id::text AS hospital_id
FROM opd_registrations o
LEFT JOIN patients p ON p.id = o.patient_id
WHERE NOT EXISTS (
    SELECT 1
    FROM billing b2
    WHERE b2.opd_registration_id = o.id
);

-- ----------------------------------------------------------------------
-- 2. Grants for PostgREST (authenticated app access)
-- ----------------------------------------------------------------------
GRANT SELECT ON billing_history_view TO authenticated, anon;

-- ----------------------------------------------------------------------
-- 3. Missing composite indexes used by the billing history query
-- ----------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_billing_hospital_source_date
    ON billing(hospital_id, source_type, bill_date DESC, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_opd_hospital_visit_date
    ON opd_registrations(hospital_id, visit_date DESC, created_at DESC);
