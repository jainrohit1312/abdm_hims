-- ======================================================================
-- HIMS - OPD registrations: department_name persistence
-- ----------------------------------------------------------------------
-- IPD admissions already persist department_name so ward/queue displays
-- survive even when the departments table is edited or deleted later.
-- This migration mirrors that behaviour for OPD registrations so the
-- patient profile / visit history can show the department without an
-- extra join on every render.
--
-- Idempotent hai — Supabase SQL Editor / supabase db push dono mein safe.
-- ======================================================================

ALTER TABLE public.opd_registrations
    ADD COLUMN IF NOT EXISTS department_name VARCHAR(255);
