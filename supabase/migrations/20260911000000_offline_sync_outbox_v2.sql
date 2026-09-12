-- ======================================================================
-- HIMS - Offline-First Sync v2 (server-side change log)
-- ----------------------------------------------------------------------
-- Purpose: give the Flutter client a reliable, paginated, tenant-scoped
-- change feed for BIDIRECTIONAL incremental sync. This is the ONLY source the
-- client trusts for pull freshness. Without it the client must NOT claim
-- "up to date".
--
-- Scope: OPD-only. The four core operational tables (patients,
-- opd_registrations, ipd_admissions, billing) plus the two billing child
-- tables (billing_items, payment_logs) are tracked. The child tables gain a
-- denormalised `hospital_id` (backfilled from their parent billing row) so
-- they are tenant-scoped and can be pulled uniformly.
--
-- Mechanism:
--   * a single global monotonic sequence `hims_change_sequence`;
--   * a `hims_change_log` table written by AFTER-triggers in the SAME
--     transaction as the business write (a change is never visible before
--     its row commits);
--   * soft-delete via `deleted_at` so deletes also produce a change entry;
--   * the client pulls its own hospital's rows; contiguity is NOT assumed.
--
-- Idempotent — safe to run more than once.
--
-- WARNING: production migrations must be reviewed and approved before they
-- are applied. This file is a proposal, not an executed change.
-- ======================================================================

-- ----------------------------------------------------------------------
-- 1. Global monotonic sequence + change-log table
-- ----------------------------------------------------------------------
CREATE SEQUENCE IF NOT EXISTS hims_change_sequence;

CREATE TABLE IF NOT EXISTS hims_change_log (
    change_id    BIGINT PRIMARY KEY DEFAULT nextval('hims_change_sequence'),
    entity       TEXT NOT NULL,
    record_id    UUID NOT NULL,
    operation    TEXT NOT NULL CHECK (operation IN ('insert', 'update', 'delete')),
    hospital_id  UUID,
    new_data     JSONB,
    committed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_change_log_hospital ON hims_change_log(hospital_id, change_id);
CREATE INDEX IF NOT EXISTS idx_change_log_record ON hims_change_log(entity, record_id);

-- ----------------------------------------------------------------------
-- 2. Denormalise hospital_id onto the billing child tables so they are
--    tenant-scoped for pull and reconciliation. Backfilled from the parent
--    billing row.
-- ----------------------------------------------------------------------
ALTER TABLE billing_items
    ADD COLUMN IF NOT EXISTS hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL;
ALTER TABLE payment_logs
    ADD COLUMN IF NOT EXISTS hospital_id UUID REFERENCES hospitals(id) ON DELETE SET NULL;

UPDATE billing_items bi
SET hospital_id = b.hospital_id
FROM billing b
WHERE b.id = bi.bill_id AND bi.hospital_id IS NULL;

UPDATE payment_logs pl
SET hospital_id = b.hospital_id
FROM billing b
WHERE b.id = pl.bill_id AND pl.hospital_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_billing_items_hospital ON billing_items(hospital_id);
CREATE INDEX IF NOT EXISTS idx_payment_logs_hospital ON payment_logs(hospital_id);

-- Auto-fill hospital_id from the parent billing row on insert (so a change-log
-- trigger always sees the correct tenant scope even for server-side inserts).
--
-- SECURITY DEFINER is required: the trigger fires as the writing role
-- (`authenticated`), which cannot read rows outside its own hospital and must
-- not need extra grants to resolve the parent's tenant. search_path is pinned
-- so the function cannot be hijacked by a shadowing object.
CREATE OR REPLACE FUNCTION hims_set_child_hospital_id()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path = public
AS $func$
BEGIN
    IF NEW.hospital_id IS NULL THEN
        SELECT hospital_id INTO NEW.hospital_id
        FROM public.billing
        WHERE id = NEW.bill_id;
    END IF;
    RETURN NEW;
END;
$func$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_billing_items_hospital ON billing_items;
CREATE TRIGGER trg_billing_items_hospital
    BEFORE INSERT ON billing_items
    FOR EACH ROW EXECUTE FUNCTION hims_set_child_hospital_id();

DROP TRIGGER IF EXISTS trg_payment_logs_hospital ON payment_logs;
CREATE TRIGGER trg_payment_logs_hospital
    BEFORE INSERT ON payment_logs
    FOR EACH ROW EXECUTE FUNCTION hims_set_child_hospital_id();

-- ----------------------------------------------------------------------
-- 3. Soft-delete columns on all tracked tables.
-- ----------------------------------------------------------------------
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'patients', 'opd_registrations', 'ipd_admissions', 'billing',
        'billing_items', 'payment_logs'
    ] LOOP
        EXECUTE format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ', t);
        EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I (deleted_at)',
                       'idx_' || t || '_deleted_at', t);
    END LOOP;
END $$;

-- ----------------------------------------------------------------------
-- 4. Per-table change-log trigger functions + triggers (INSERT/UPDATE).
--
-- SECURITY DEFINER + pinned search_path is REQUIRED here, not cosmetic:
--   * the trigger executes as the writing role (`authenticated`), and
--   * `hims_change_log` intentionally grants that role SELECT only, with a
--     SELECT-only RLS policy, so clients cannot forge change records.
-- Without SECURITY DEFINER every authenticated write would fail with
-- "permission denied for table hims_change_log".
-- ----------------------------------------------------------------------
DO $$
DECLARE
    t text;
    fn text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'patients', 'opd_registrations', 'ipd_admissions', 'billing',
        'billing_items', 'payment_logs'
    ] LOOP
        fn := 'hims_change_log_' || t;

        EXECUTE format($fn$
            CREATE OR REPLACE FUNCTION %I() RETURNS TRIGGER
            SECURITY DEFINER
            SET search_path = public
            AS $func$
            BEGIN
                INSERT INTO public.hims_change_log (entity, record_id, operation, hospital_id, new_data)
                VALUES (TG_ARGV[0], NEW.id, lower(TG_OP), NEW.hospital_id, row_to_json(NEW));
                RETURN NEW;
            END;
            $func$ LANGUAGE plpgsql;
        $fn$, fn);

        EXECUTE format('DROP TRIGGER IF EXISTS trg_%I_change ON %I', t, t);
        EXECUTE format($tg$
            CREATE TRIGGER trg_%I_change
            AFTER INSERT OR UPDATE ON %I
            FOR EACH ROW EXECUTE FUNCTION %I('%I')
        $tg$, t, t, fn, t);
    END LOOP;
END $$;

-- ----------------------------------------------------------------------
-- 5. Soft-delete triggers (BEFORE DELETE) — log the delete, then suppress
--    the hard delete by returning NULL.
--
-- SECURITY DEFINER for the same reason as §4: the change-log INSERT is not
-- permitted to `authenticated`. The DELETE statement itself is already
-- filtered by the table's tenant RLS policy, so the trigger only ever fires
-- for rows the caller was allowed to delete.
-- ----------------------------------------------------------------------
DO $$
DECLARE
    t text;
    fn text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'patients', 'opd_registrations', 'ipd_admissions', 'billing',
        'billing_items', 'payment_logs'
    ] LOOP
        fn := 'hims_soft_delete_' || t;

        EXECUTE format($fn$
            CREATE OR REPLACE FUNCTION %I() RETURNS TRIGGER
            SECURITY DEFINER
            SET search_path = public
            AS $func$
            BEGIN
                INSERT INTO public.hims_change_log (entity, record_id, operation, hospital_id, new_data)
                VALUES (TG_ARGV[0], OLD.id, 'delete', OLD.hospital_id, NULL);
                UPDATE ONLY %I SET deleted_at = NOW() WHERE id = OLD.id;
                RETURN NULL;
            END;
            $func$ LANGUAGE plpgsql;
        $fn$, fn, t);

        EXECUTE format('DROP TRIGGER IF EXISTS trg_%I_soft_delete ON %I', t, t);
        EXECUTE format($tg$
            CREATE TRIGGER trg_%I_soft_delete
            BEFORE DELETE ON %I
            FOR EACH ROW EXECUTE FUNCTION %I('%I')
        $tg$, t, t, fn, t);
    END LOOP;
END $$;

-- ----------------------------------------------------------------------
-- 6. Row-level security: a client may only read its own hospital's change
--    entries. The hospital is resolved from the public `users` record linked
--    to the authenticated JWT subject.
-- ----------------------------------------------------------------------
ALTER TABLE hims_change_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "hospital-scoped change log read" ON hims_change_log;
CREATE POLICY "hospital-scoped change log read"
    ON hims_change_log FOR SELECT TO authenticated
    USING (
        hospital_id = (
            SELECT u.hospital_id
            FROM users u
            WHERE u.auth_id = auth.uid()
            LIMIT 1
        )
    );

-- ----------------------------------------------------------------------
-- 7. Grants for authenticated clients (change-feed reads).
-- ----------------------------------------------------------------------
GRANT SELECT ON hims_change_log TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE hims_change_sequence TO authenticated;
