-- ======================================================================
-- HIMS - Free Trial / Subscription Module
-- ----------------------------------------------------------------------
-- * hospitals: adds trial + subscription tracking columns.
--     - trial_start_date      -> when the free trial started
--     - trial_end_date        -> when the free trial ends (365 days)
--     - subscription_status   -> trial | active | expired
--     - subscription_plan     -> basic | standard | premium
--     - subscription_expiry   -> paid subscription expiry (active plans)
-- * payments: subscription payment history (amount, method, status).
-- * Trigger: every newly registered hospital automatically starts its
--   365-day free trial, even when the inserting client/Edge Function
--   does not pass the trial columns.
--
-- Run manually in the Supabase SQL Editor, or `supabase db push`.
-- The script is idempotent (safe to run more than once).
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. HOSPITALS: subscription columns
-- ----------------------------------------------------------------------
ALTER TABLE public.hospitals
    ADD COLUMN IF NOT EXISTS trial_start_date TIMESTAMPTZ;

ALTER TABLE public.hospitals
    ADD COLUMN IF NOT EXISTS trial_end_date TIMESTAMPTZ;

ALTER TABLE public.hospitals
    ADD COLUMN IF NOT EXISTS subscription_status VARCHAR(20);

ALTER TABLE public.hospitals
    ADD COLUMN IF NOT EXISTS subscription_plan VARCHAR(20);

ALTER TABLE public.hospitals
    ADD COLUMN IF NOT EXISTS subscription_expiry TIMESTAMPTZ;

-- Backfill existing hospitals: trial counts from the registration date.
UPDATE public.hospitals
SET trial_start_date = COALESCE(created_at, NOW())
WHERE trial_start_date IS NULL;

UPDATE public.hospitals
SET trial_end_date = trial_start_date + INTERVAL '365 days'
WHERE trial_end_date IS NULL;

UPDATE public.hospitals
SET subscription_status = 'trial'
WHERE subscription_status IS NULL;

-- Defaults so any future INSERT that omits the columns still starts a trial.
ALTER TABLE public.hospitals
    ALTER COLUMN trial_start_date SET DEFAULT NOW();

ALTER TABLE public.hospitals
    ALTER COLUMN trial_end_date SET DEFAULT (NOW() + INTERVAL '365 days');

ALTER TABLE public.hospitals
    ALTER COLUMN subscription_status SET DEFAULT 'trial';

ALTER TABLE public.hospitals
    ALTER COLUMN trial_start_date SET NOT NULL;

ALTER TABLE public.hospitals
    ALTER COLUMN trial_end_date SET NOT NULL;

ALTER TABLE public.hospitals
    ALTER COLUMN subscription_status SET NOT NULL;

-- ----------------------------------------------------------------------
-- 2. AUTO-START TRIAL TRIGGER (belt & braces for edge-function inserts)
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.ensure_hospital_trial()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    NEW.trial_start_date := COALESCE(NEW.trial_start_date, NOW());
    NEW.trial_end_date := COALESCE(
        NEW.trial_end_date,
        NEW.trial_start_date + INTERVAL '365 days'
    );
    NEW.subscription_status := COALESCE(NEW.subscription_status, 'trial');
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_hospital_trial ON public.hospitals;

CREATE TRIGGER trg_hospital_trial
    BEFORE INSERT ON public.hospitals
    FOR EACH ROW
    EXECUTE FUNCTION public.ensure_hospital_trial();

-- ----------------------------------------------------------------------
-- 3. PAYMENTS TABLE (subscription payment history)
-- ----------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.payments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    hospital_id UUID NOT NULL REFERENCES public.hospitals(id) ON DELETE CASCADE,
    payment_amount DECIMAL(12,2) NOT NULL DEFAULT 0,
    payment_date TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    payment_method VARCHAR(50) NOT NULL DEFAULT 'mock',   -- mock | stripe | upi | paytm
    payment_status VARCHAR(20) NOT NULL DEFAULT 'success', -- success | failed | pending
    subscription_plan VARCHAR(20),                          -- basic | standard | premium
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_payments_hospital
    ON public.payments(hospital_id);

CREATE INDEX IF NOT EXISTS idx_payments_date
    ON public.payments(payment_date);

-- ----------------------------------------------------------------------
-- 4. ROW LEVEL SECURITY (matches the permissive app policies)
-- ----------------------------------------------------------------------
ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Enable all access for authenticated users on payments"
    ON public.payments;

CREATE POLICY "Enable all access for authenticated users on payments"
    ON public.payments
    FOR ALL
    TO authenticated
    USING (true)
    WITH CHECK (true);

-- ----------------------------------------------------------------------
-- 5. GRANTS (required on newer Supabase versions)
-- ----------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON public.payments
    TO authenticated, anon;
