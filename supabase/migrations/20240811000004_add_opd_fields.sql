-- ======================================================================
-- Add Age and Blood Group columns to OPD Registrations table
-- ======================================================================

ALTER TABLE opd_registrations
ADD COLUMN IF NOT EXISTS age INTEGER,
ADD COLUMN IF NOT EXISTS blood_group VARCHAR(5);