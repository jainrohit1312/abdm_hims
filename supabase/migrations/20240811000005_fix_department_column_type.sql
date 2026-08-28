-- ======================================================================
-- Fix OPD Registrations: Change department_id from UUID to VARCHAR
-- 
-- Problem: The Flutter app sends department NAME (e.g., "General Medicine")
--          but the column was UUID type expecting a foreign key reference.
-- Solution: Store department name directly as text (simpler, no lookup needed).
-- ======================================================================

-- Step 1: Drop the foreign key constraint dynamically
DO $$
DECLARE
    constraint_name text;
BEGIN
    SELECT con.conname INTO constraint_name
    FROM pg_constraint con
    JOIN pg_class rel ON rel.oid = con.conrelid
    WHERE rel.relname = 'opd_registrations'
    AND con.contype = 'f'
    AND EXISTS (
        SELECT 1 FROM pg_attribute att
        WHERE att.attrelid = rel.oid
        AND att.attname = 'department_id'
        AND att.attnum = ANY(con.conkey)
    );

    IF constraint_name IS NOT NULL THEN
        EXECUTE format('ALTER TABLE opd_registrations DROP CONSTRAINT %I', constraint_name);
    END IF;
END $$;

-- Step 2: Change column type from UUID to VARCHAR(255)
ALTER TABLE opd_registrations
ALTER COLUMN department_id TYPE VARCHAR(255) USING department_id::text;