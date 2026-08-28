-- ======================================================================
-- Add is_emergency column to OPD Registrations table
-- ======================================================================

ALTER TABLE opd_registrations
ADD COLUMN IF NOT EXISTS is_emergency BOOLEAN DEFAULT false;

COMMENT ON COLUMN opd_registrations.is_emergency IS 'Flags emergency OPD cases for queue prioritisation';