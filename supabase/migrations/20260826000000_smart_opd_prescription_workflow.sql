-- ======================================================================
-- HIMS - Smart OPD & Prescription Workflow
-- ----------------------------------------------------------------------
-- 1. doctors.prescription_mode
--    true  => Doctor printed prescription generate karega (OPD pending)
--    false => Direct OPD (OPD registration ke saath hi completed)
-- 2. opd_registrations.payment_amount
--    (payment_mode & payment_status billing migration se already exist
--     karte hain; yahan IF NOT EXISTS se safe re-add kiya hai)
-- 3. opd_registrations.status
--    'pending' / 'completed' values ko normalize karta hai.
--
-- Idempotent hai — Supabase SQL Editor mein run kar sakte hain.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. DOCTORS: prescription_mode column
-- ----------------------------------------------------------------------
ALTER TABLE public.doctors
    ADD COLUMN IF NOT EXISTS prescription_mode BOOLEAN NOT NULL DEFAULT FALSE;

CREATE INDEX IF NOT EXISTS idx_doctors_prescription_mode
    ON public.doctors(prescription_mode);

-- ----------------------------------------------------------------------
-- 2. OPD REGISTRATIONS: payment tracking columns
-- ----------------------------------------------------------------------
ALTER TABLE public.opd_registrations
    ADD COLUMN IF NOT EXISTS payment_amount DECIMAL(12,2) NOT NULL DEFAULT 0;

ALTER TABLE public.opd_registrations
    ADD COLUMN IF NOT EXISTS payment_mode VARCHAR(50);

ALTER TABLE public.opd_registrations
    ADD COLUMN IF NOT EXISTS payment_status VARCHAR(50) NOT NULL DEFAULT 'unpaid';

ALTER TABLE public.opd_registrations
    ADD COLUMN IF NOT EXISTS paid_amount DECIMAL(12,2) NOT NULL DEFAULT 0;

ALTER TABLE public.opd_registrations
    ADD COLUMN IF NOT EXISTS balance_amount DECIMAL(12,2) NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS idx_opd_payment_status
    ON public.opd_registrations(payment_status);

-- ----------------------------------------------------------------------
-- 3. BACKFILL existing rows
-- ----------------------------------------------------------------------

-- payment_amount ko consultation fee se backfill karo.
UPDATE public.opd_registrations
SET payment_amount = COALESCE(consultation_fee, 0)
WHERE payment_amount = 0;

-- balance_amount / payment_status ko sync karo (unpaid rows).
UPDATE public.opd_registrations
SET balance_amount = COALESCE(consultation_fee, 0) - COALESCE(paid_amount, 0),
    payment_status = CASE
        WHEN COALESCE(paid_amount, 0) >= COALESCE(consultation_fee, 0)
             AND COALESCE(consultation_fee, 0) > 0 THEN 'paid'
        WHEN COALESCE(paid_amount, 0) > 0 THEN 'partially_paid'
        ELSE 'unpaid'
    END
WHERE payment_status = 'unpaid';

-- ----------------------------------------------------------------------
-- 4. STATUS normalisation
--    Legacy 'waiting' / 'in_consultation' => 'pending'
-- ----------------------------------------------------------------------
UPDATE public.opd_registrations
SET status = 'pending'
WHERE status IN ('waiting', 'in_consultation');
