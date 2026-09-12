# Production Upgrade Plan (existing hospital database)

Date: 2026-09-12
Status: **plan validated against an isolated pre-upgrade simulation; production
compatibility remains UNVERIFIED.**

> Scope: upgrading an **already-running** production database in place so it can
> support the offline OPD work. Nothing in this document has been executed
> against production, and no production permission, migration or history change
> is authorised by this repository.

---

## 1. Why a clean local reset is not proof

`supabase db reset` builds the schema from scratch in file order. A real
hospital database is not in that state:

* it already contains data, constraints, policies, triggers and identifiers
  that must survive;
* its `supabase_migrations.schema_migrations` history is **not** the same as the
  repository's file list.

Two concrete divergences exist in this repository:

| Issue | Detail |
|---|---|
| Duplicate historical version numbers | Three historical migration files were renamed to unique versions because they collided: `20260827000000_voucher_attachments.sql` → `20260827000002_…`, `20260828000000_ipd_doctor_selection_charges.sql` → `20260828000007_…`, `20260828000000_ipd_patient_dashboard_groups.sql` → `20260828000008_…`. A fourth file, `20260828000000_counseling_recording_consent.sql`, shares the same prefix and is the one whose version most likely occupies the `20260828000000` slot in production history. |
| `public.doctors` has no creating migration | Later migrations reference `public.doctors`, so it must already exist in production (created out-of-band). `20260825000014_create_doctors_table.sql` reconstructs it for fresh databases. |

Consequence: `supabase db push` against production would try to apply the
renamed versions as new migrations and could re-run effects that already exist,
and it may fail or duplicate work. This must be resolved deliberately, with the
real history in hand.

---

## 2. Read-only inspection (run first, no writes)

These queries need **read-only** access. They are the input to the plan; without
them the renames cannot be certified inert.

```sql
-- 2.1 What history does production actually have for the touched versions?
SELECT version, name
  FROM supabase_migrations.schema_migrations
 WHERE version IN (
   '20260825000014',
   '20260827000000', '20260827000002',
   '20260828000000', '20260828000007', '20260828000008',
   '20260911000000', '20260912000000'
 )
 ORDER BY version;

-- 2.2 Do the schema effects of the ambiguous versions already exist?
SELECT to_regclass('public.doctors')                        AS doctors_table,
       to_regclass('public.voucher_attachments')            AS voucher_attachments,
       to_regclass('public.hims_change_log')                AS change_log,
       to_regclass('public.hims_operation_receipts')        AS receipts;

SELECT column_name
  FROM information_schema.columns
 WHERE table_schema = 'public' AND table_name = 'ipd_admissions'
   AND column_name IN ('doctor_name', 'department_name')
 ORDER BY column_name;

SELECT table_name
  FROM information_schema.columns
 WHERE table_schema = 'public' AND column_name = 'patient_group'
   AND table_name LIKE 'ipd%'
 GROUP BY table_name;

-- 2.3 Is `public.doctors` actually usable by the app role? (A manually created
--     table often has no grants, which breaks the doctor list entirely.)
SELECT c.relrowsecurity,
       has_table_privilege('authenticated', 'public.doctors', 'SELECT') AS auth_select,
       has_table_privilege('authenticated', 'public.doctors', 'INSERT') AS auth_insert
  FROM pg_class c
 WHERE c.oid = 'public.doctors'::regclass;

SELECT column_name
  FROM information_schema.columns
 WHERE table_schema = 'public' AND table_name = 'doctors'
 ORDER BY column_name;

-- 2.4 Are there already rows with no tenant that the new policies would hide?
SELECT 'doctors' AS t, count(*) FILTER (WHERE hospital_id IS NULL) AS null_tenant, count(*) AS total
  FROM public.doctors
UNION ALL
SELECT 'billing_items', count(*) FILTER (WHERE hospital_id IS NULL), count(*) FROM public.billing_items
UNION ALL
SELECT 'payment_logs', count(*) FILTER (WHERE hospital_id IS NULL), count(*) FROM public.payment_logs;

-- 2.5 Existing row counts on the tables the upgrade touches.
SELECT 'patients' AS t, count(*) FROM public.patients
UNION ALL SELECT 'opd_registrations', count(*) FROM public.opd_registrations
UNION ALL SELECT 'billing', count(*) FROM public.billing
UNION ALL SELECT 'billing_items', count(*) FROM public.billing_items
UNION ALL SELECT 'payment_logs', count(*) FROM public.payment_logs;
```

**Decision points**

* If 2.2 shows the effects exist and 2.1 shows the version row is absent, the
  version must be recorded (see §3 step 3). This **is** a migration-history
  change — it is not "no history change", and it must be reviewed and approved
  like any other change.
* If 2.2 shows an effect is missing, the corresponding migration must be
  applied instead of being recorded.
* If 2.3 shows `auth_select = false`, applying
  `20260825000014_create_doctors_table.sql` repairs it (the file is idempotent
  and its grants are not guarded by `CREATE TABLE IF NOT EXISTS`).
* If 2.4 shows `doctors.hospital_id IS NULL` rows, enabling RLS will hide them
  until they are assigned a tenant. Assign them **only** with the hospital's
  approval and a verified mapping.

---

## 3. Incremental upgrade plan (apply in this order)

> Every command below targets production. They are listed for review; they are
> **not** authorised by this repository and have **not** been run.

1. **Back up** (`supabase db dump` / provider snapshot) and record the counts
   from 2.5 so the upgrade can be verified afterwards.

2. **Doctors table**
   ```bash
   supabase db push --include-all   # would apply 20260825000014 if unrecorded
   ```
   Equivalent manual step (idempotent), when the CLI would re-order versions:
   ```bash
   psql "$PROD_DB_URL" -f supabase/migrations/20260825000014_create_doctors_table.sql
   ```
   Safe against an existing table (all statements are `IF NOT EXISTS` /
   `DROP POLICY IF EXISTS` + `CREATE`) and deliberately repairs the missing
   grants/RLS/policy/trigger so the doctor list is readable.

3. **Repair the ambiguous historical versions** — only for versions whose
   effects 2.2 confirmed:
   ```bash
   supabase migration repair --status applied 20260827000002 --db-url "$PROD_DB_URL"
   supabase migration repair --status applied 20260828000007 --db-url "$PROD_DB_URL"
   supabase migration repair --status applied 20260828000008 --db-url "$PROD_DB_URL"
   # and 20260825000014 if step 2 was run manually
   supabase migration repair --status applied 20260825000014 --db-url "$PROD_DB_URL"
   ```
   This writes rows into `supabase_migrations.schema_migrations`. It changes
   migration history. Do **not** run it for a version whose effects are absent.

4. **Apply the offline change log**
   ```bash
   psql "$PROD_DB_URL" -f supabase/migrations/20260911000000_offline_sync_outbox_v2.sql
   ```
   Adds `hims_change_log` (+ sequence, triggers, soft-delete columns,
   `billing_items.hospital_id` / `payment_logs.hospital_id` with a backfill from
   the parent bill, and RLS). Additive; it does not drop or rewrite data.
   It also creates the change-log triggers as `SECURITY DEFINER` — without that,
   every authenticated write would fail with `permission denied for table
   hims_change_log` (see §5).

5. **Apply the atomic OPD payment endpoint**
   ```bash
   psql "$PROD_DB_URL" -f supabase/migrations/20260912000000_opd_payment_atomic_operation.sql
   ```
   Adds `hims_operation_receipts` and `public.hims_apply_opd_payment(...)`.
   Additive; no existing object is replaced.

6. **Record the newly applied versions**
   ```bash
   supabase migration repair --status applied 20260911000000 --db-url "$PROD_DB_URL"
   supabase migration repair --status applied 20260912000000 --db-url "$PROD_DB_URL"
   ```
   (Skip when the versions were applied through the CLI, which records them.)

7. **Verify** — re-run the 2.5 counts and confirm they are unchanged, then spot
   check that the new objects exist and that a signed-in client can read the
   doctor list.

**Do not**: rewrite production history, delete or recreate tables, drop
policies, reset the database, or change permissions as part of this upgrade.

---

## 4. What was actually tested (isolated, synthetic)

Procedure: `tool/verify_prod_upgrade_simulation.ps1`
(data assertions: `supabase/verify_upgrade_simulation.sql`).

It (1) stashes the two genuinely-new migrations and runs `supabase db reset`,
which builds a **representative pre-upgrade schema**; (2) rewrites
`supabase_migrations.schema_migrations` to the **production-like duplicate
history** (removing `20260825000014`, `20260827000002`, `20260828000007`,
`20260828000008`); (3) seeds synthetic patients/visits/bills/items/payments;
(4) snapshot every fact that must be preserved; (5) applies the plan from §3;
(6) re-asserts.

| Check | Result |
|---|---|
| Pre-upgrade facts snapshotted | **215** facts (row counts, id checksums, business values, FK links, per-column, per-policy, per-trigger, per-constraint) |
| Facts preserved after the upgrade | **215 / 215 unchanged** |
| New objects present | `hims_change_log`, `hims_operation_receipts`, `hims_apply_opd_payment` ✅ |
| `billing_items.hospital_id` / `payment_logs.hospital_id` backfilled to the parent bill | ✅ 0 mismatches |
| A **pre-existing** unpaid visit paid through the new endpoint after the upgrade | ✅ `applied`, exactly 1 bill, 1 payment log, collected 300.00 |
| Migration chain applies cleanly on a fresh database | ✅ (`supabase db reset`, 52 migrations) |

This proves the *plan's mechanics* on a schema that contains real data. It does
**not** prove anything about the production database's actual content, history
rows or permissions.

### Provenance / re-validation note

The simulation above was executed **before** the `doctors`-table access fix in
§5.2 (grants + RLS + policies + tenant trigger were added to
`20260825000014_create_doctors_table.sql` afterwards). That change is additive
and confined to the `doctors` relation, and the preservation snapshot does not
track `doctors` policies/triggers, so the 215-fact result is unaffected in
substance — but the simulation was **not** re-executed at the final revision
(the repeat attempt at the isolated history-simulation step was blocked by the
session's shell policy). Re-running `tool/verify_prod_upgrade_simulation.ps1` at
the final revision is the outstanding step before this plan is used on a real
database.

What **was** executed at the final revision:

* the full fresh-database chain (`supabase db reset`, 52 migrations) ✅
* `supabase/verify_opd_payment_atomic.sql` — 48/48 ✅
* `supabase/verify_opd_payment_concurrent.sql` — 7/7 ✅
* `test/integration/offline_opd_e2e_test.dart` — including the doctor
  master-data download that the access fix unblocked ✅
* `flutter analyze`, the full test suite (206 passed / 1 opt-in skip), and the
  Windows + Web release builds ✅


---

## 5. Defects this work surfaced

These were found while validating the upgrade path; they are fixed in the
migration files, and each one is a reason the plan must not be skipped.

1. **The offline change-log triggers broke every authenticated write.** The
   per-table `hims_change_log_*` / `hims_soft_delete_*` trigger functions ran as
   the writing role (`authenticated`), which only has `SELECT` on
   `hims_change_log` by design — so any insert into `patients`,
   `opd_registrations`, `billing`, … failed with
   `permission denied for table hims_change_log`. The functions are now
   `SECURITY DEFINER` with a pinned `search_path`, which keeps clients unable to
   forge change-log rows while letting the triggers write them.
2. **`public.doctors` was unusable.** The reconstructed table had no grants and
   no RLS, so `GET /rest/v1/doctors` returned
   `permission denied for table doctors` and the offline OPD doctor picker and
   the prescription-mode lookup could not work. The migration now grants
   `SELECT/INSERT/UPDATE/DELETE` to `authenticated` and adds the same
   tenant-scoped policies/trigger as the other operational tables.
3. **Migration-history ambiguity** for three duplicate-version files (§1), which
   makes a blind `db push` unsafe.

---

## 6. Remaining unverified

* **Production compatibility is UNVERIFIED.** No authorised read-only access to
  the production database was available, so §2 was never run and §3 was never
  applied. The statements in §2 are the exact queries needed.
* Whether production's `doctors` table has grants/RLS, and whether any of its
  rows have a NULL `hospital_id` (which the new policy would hide).
* Whether production's `billing_items` / `payment_logs` contain rows whose
  parent bill is in another hospital (they would be backfilled to the parent's
  hospital, which is the intended tenant).
* Real-world row volumes: the offline migration's backfill and the
  `deleted_at` index creation have not been timed on production-sized tables.
