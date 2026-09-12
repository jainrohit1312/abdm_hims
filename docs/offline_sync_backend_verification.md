# Offline-Sync Backend Verification (isolated)

This is the reproducible procedure to validate the Phase 1 offline-sync
migration and the end-to-end Windows workflow against an **isolated local
Supabase** — never production.

## Prerequisites

- Docker Desktop installed **and its daemon running**.
  (On this machine the CLI is present but the daemon was not running —
  `supabase status` returned `open //./pipe/dockerDesktopLinuxEngine: The
  system cannot find the file specified`. Start Docker Desktop first.)
- Supabase CLI (`supabase --version` → 2.113.0 present).

## 1. Start an isolated local stack

```powershell
cd C:\Projects\abdm_hims
supabase start
```

This creates a throwaway local Postgres + Auth + Storage. It does **not** touch
any cloud project.

## 2. Apply every migration (including the offline change-log)

```powershell
supabase db reset
```

`db reset` drops and recreates the local database, then applies all files in
`supabase/migrations/` in order, including
`20260911000000_offline_sync_outbox_v2.sql` (the `hims_change_log` + soft-delete
triggers). A SQL error in that migration will surface here.

Verify the change-log is wired:

```powershell
supabase db reset
# then insert a patient and confirm a row lands in hims_change_log:
supabase db execute --file supabase/snippets/verify_change_log.sql
```

Suggested `verify_change_log.sql` (synthetic data only):

```sql
INSERT INTO hospitals (id, name, code) VALUES (gen_random_uuid(), 'Test Hosp', 'TEST01');
INSERT INTO patients (id, hospital_id, uhid, first_name)
SELECT h.id, h.id, 'TEST-UHID-1', 'Synthetic' FROM hospitals h WHERE h.code = 'TEST01';
SELECT change_id, entity, operation, (new_data->>'uhid') AS uhid
FROM hims_change_log WHERE entity = 'patients' ORDER BY change_id DESC LIMIT 5;
```

## 3. Tenant-isolation check for the change log

Confirm that `hims_change_log` rows are scoped by `hospital_id` and that RLS (or
the application query) never returns another hospital's payloads. The
`new_data` JSONB must only be read by the owning hospital's authenticated role.

```sql
-- Insert a second hospital + patient, then confirm the change log carries
-- each row's hospital_id so the client can filter by tenant.
SELECT change_id, entity, hospital_id, (new_data->>'uhid') AS uhid
FROM hims_change_log ORDER BY change_id;
```

## 4. End-to-end Windows scenario (manual, synthetic data)

1. Build/run the Windows app against the local `supabase start` URL + anon key
   (printed by `supabase status`).
2. Sign in as a provisioned user and let the baseline download run.
3. Disconnect the network (disable the adapter / airplane mode).
4. Restart the app.
5. Search an existing patient; register a new patient.
6. Create an OPD visit and record payment; print the slip.
7. Restart again offline; open the queue, visit details and payment history;
   reprint (verify no new payment rows).
8. Reconnect; wait for the sync engine.
9. Query the local Postgres to confirm exactly one patient, one OPD visit, one
   billing row, one billing_items row, one payment_logs row — no duplicates, and
   `created_by` is a valid public `users.id`.
10. From a second client session (same hospital), confirm the synchronized
    records appear.

## 5. Automated assertions (once the stack is up)

Add a Deno test (matching the existing `supabase/functions/**/*_test.ts` style)
that, against the local DB, runs the SQL assertions above. Keep the data
synthetic; never use production patient data.

---

**Status (updated 2026-09-12, later revision):** the isolated backend **is**
running on this machine (Docker Desktop + Supabase CLI 2.113.0), and the whole
chain now applies **52** migrations (including the atomic OPD payment endpoint).
The earlier note that the native SQLite tests were skipped is **out of date —
they pass** (see the end of this document). See the validation results below.

## Validation results (real Postgres, synthetic data only)

Executed via `docker exec supabase_db_abdm_hims psql ...` against the isolated
local database:

| Check | Result |
|---|---|
| Migration applies cleanly (whole chain) | ✅ |
| Patient INSERT captured in `hims_change_log` | ✅ (1 row, correct `hospital_id` + `new_data`) |
| Patient UPDATE captured | ✅ (1 row) |
| Rollback leaves no orphan change row | ✅ (0 rows after `BEGIN; INSERT; ROLLBACK;`) |
| Soft-delete captured (`operation='delete'`, `deleted_at` set) | ✅ |
| RLS enabled on `hims_change_log` | ✅ (`relrowsecurity = t`) |
| RLS policy present | ✅ (1 policy) |
| Tenant isolation (Hosp B rows invisible under Hosp A filter) | ✅ (0 rows) |
| Interleaved change_ids across hospitals (gaps in a per-hospital stream) | ✅ demonstrated |

### Child-record sync + accounting idempotency (real Postgres)

`supabase/verify_child_sync.sql` (synthetic data) confirmed:

| Check | Result |
|---|---|
| `billing_items.hospital_id` auto-filled from parent billing | ✅ 1 |
| `payment_logs.hospital_id` auto-filled from parent billing | ✅ 1 |
| change-log captured `patients` / `billing` / `billing_items` / `payment_logs` | ✅ 1 each |
| Fixed bill `id` present exactly once (PK idempotency for retries) | ✅ 1 row |
| Cross-tenant child rows visible under another hospital | ✅ 0 |

Client-side decision logic (a same-id-different-payload retry is a **conflict**,
never a silent success) is covered by `test/services/sync_outbox_idempotency_test.dart`.

### Reconciliation

`pullChanges` uses a hospital-scoped incremental cursor; `reconcileDataset` /
`reconcileAll` (in `DatabaseService`, scheduled by `SyncEngine.reconcileNow`)
provide the eventual-consistency guarantee by paginating the full authorized
business table (including soft-deletes) independently of the cursor. Green
status now requires a completed reconciliation — never incremental alone.

Two pre-existing migration-chain defects were **fixed** to reach the offline
migration locally (both are safe/idempotent and do not run against production):

1. `public.doctors` was referenced by later migrations but never created →
   added `20260825000014_create_doctors_table.sql` (reconstruction, `IF NOT EXISTS`).
2. Duplicate migration versions → renamed to unique versions:
   `20260827000000_voucher_attachments.sql` → `20260827000002_...`,
   `20260828000000_ipd_doctor_selection_charges.sql` → `20260828000007_...`,
   `20260828000000_ipd_patient_dashboard_groups.sql` → `20260828000008_...`.

The offline-sync migration itself was fixed during validation:
- `TG_OP` returns uppercase; the CHECK constraint is lowercase → trigger now
  uses `lower(TG_OP)`.
- Inner `$$` dollar-quoting collided with the outer `DO $$` → inner function
  body now uses `$func$`.

### Atomic OPD payment endpoint (added 2026-09-12)

Migration `20260912000000_opd_payment_atomic_operation.sql` adds
`hims_operation_receipts` + `public.hims_apply_opd_payment(...)`. The previous
four independent PostgREST writes (opd update / billing / billing_items /
payment_logs) could leave a half-applied accounting operation in the cloud.

`supabase/verify_opd_payment_atomic.sql` (synthetic data, all rolled back):

| Check | Result |
|---|---|
| Scenario 1 — successful accounting operation (billing + item + payment + audit + receipt) | ✅ |
| Scenario 2 — forced failure halfway (trigger on `payment_logs`) leaves **no** partial writes | ✅ |
| Scenario 2b — the same operation id then succeeds (no orphan receipt) | ✅ |
| Scenario 3 — committed but response lost, then retry returns the original result, no new rows | ✅ |
| Scenario 5 — same operation id with different amounts → explicit `hims_opd_payment_conflict` | ✅ |
| Scenario 6a–6f — cross-hospital visit / foreign patient / unknown visit (retryable) / overpayment / over-discount / fee mismatch | ✅ |
| Scenario 6g — receipt not readable by another hospital (RLS) | ✅ |
| Scenario 6h — `anon` cannot execute the money operation | ✅ |
| Scenario 7 — partial payment carried as `partially_paid` with the balance; a second collection is refused | ✅ |
| Scenario 8 — one bill per paid visit, no orphans, collected total == billed paid total, child rows tenant-correct, every receipt finalised | ✅ |
| **Total** | **48 / 48 checks** |

`supabase/verify_opd_payment_concurrent.sql` (two genuinely concurrent sessions
via `dblink`, run as the local superuser; commits and cleans up):

| Check | Result |
|---|---|
| Exactly one `applied` and one `replayed` (observed: session A `applied`, main `replayed`) | ✅ |
| Exactly one receipt / bill / item / payment log; collected exactly once | ✅ |
| **Total** | **7 / 7 checks** |

### Access defects found and fixed

- The change-log trigger functions were not `SECURITY DEFINER`, so **every
  authenticated write failed** with `permission denied for table
  hims_change_log`. They now run as the owner with a pinned `search_path`.
- The reconstructed `public.doctors` table had **no grants and no RLS**, so the
  app could not read the doctor list at all
  (`permission denied for table doctors`). The migration now grants
  `SELECT/INSERT/UPDATE/DELETE` to `authenticated` and adds tenant policies +
  the `hospital_id` trigger.

### Production upgrade path

See `docs/production_upgrade_plan.md`. The incremental plan was validated
against a representative pre-upgrade schema with synthetic data (215/215
preserved facts). **Production compatibility remains UNVERIFIED** — no
authorised read-only access was available.

## Remaining unexecuted

- The **GUI** portion of the Windows scenario: rendering, the print dialog and
  physical/virtual printer output, and a second physical client device. The
  service-level workflow is automated and passing — see
  `test/integration/offline_opd_e2e_test.dart`.
- **Native SQLite integration tests** — no longer skipped: they pass on this
  host (`.qwen/tmp/sqlite3/sqlite3.dll`).

