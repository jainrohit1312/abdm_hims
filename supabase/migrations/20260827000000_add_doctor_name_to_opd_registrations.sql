-- ======================================================================
-- HIMS - OPD slip: doctor_name persistence
-- ----------------------------------------------------------------------
-- Live deployments mein opd_registrations.doctor_id column exist nahi
-- karta (OPD screen doctors table se doctor select karti hai). Isliye
-- doctor ka naam doctor_name column mein persist karte hain taaki OPD
-- queue se payment slip hamesha sahi doctor naam ke saath print ho.
--
-- Idempotent hai — Supabase SQL Editor / supabase db push dono mein safe.
-- ======================================================================

ALTER TABLE public.opd_registrations
    ADD COLUMN IF NOT EXISTS doctor_name VARCHAR(255);
