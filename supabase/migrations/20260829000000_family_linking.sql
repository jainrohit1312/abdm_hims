-- ======================================================================
-- HIMS - Family Linking & Relationship Tagging
-- ----------------------------------------------------------------------
-- Adds family relationship tagging to the patients table so patients
-- sharing the same mobile number can be displayed as a family group.
--
--   family_relationship examples:
--     Self, Father, Mother, Son, Daughter, Wife, Husband, Brother,
--     Sister, Grandfather, Grandmother, Other
--
-- Family membership is implicit: every patient row with the same
-- mobile_number belongs to the same family group.
--
-- Idempotent: safe to run more than once from the Supabase SQL Editor
-- (or via `supabase db push`).
-- ======================================================================

ALTER TABLE patients
    ADD COLUMN IF NOT EXISTS family_relationship VARCHAR(50);

-- Existing rows keep NULL; the Flutter UI falls back to "Self" for a
-- single-member family and "Member" for multi-member families.

-- Search for family members by mobile number already uses
-- idx_patients_mobile; add a composite index for relationship-grouped
-- family listings.
CREATE INDEX IF NOT EXISTS idx_patients_family_relationship
    ON patients(family_relationship)
    WHERE family_relationship IS NOT NULL;
