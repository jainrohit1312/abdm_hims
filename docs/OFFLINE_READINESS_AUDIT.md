# MediFlux HIMS — Offline-First Readiness Audit & Roadmap

Date: 2026-09-11
Scope: whole `abdm_hims` repository, verified against the current working tree
Status: **Phase 0 complete** — Phase 1 (foundation + OPD) is in progress.

> This document is the single source of truth for the offline-first upgrade.
> It records what actually exists (verified against code/migrations), what is
> missing, the multi-computer safety boundaries, and the phased rollout plan.

---

## 1. Verified current state (inspection leads confirmed / corrected)

| Lead from prompt | Verified result |
|---|---|
| `lib/services/local_db.dart` | **Confirmed.** `LocalDatabase` abstract API + `LocalTables` (4 tables: `patients`, `opd_registrations`, `ipd_admissions`, `billing`). |
| Platform `local_db_io.dart` / `local_db_web.dart` | **Confirmed.** Native = drift/SQLite (`hims_offline.sqlite`, JSON-blob payload, `offline_id` + `is_synced` + `updated_at`). Web = Hive/IndexedDB. |
| `database_service.dart` | **Confirmed** (7231 lines). Most reads/writes call Supabase directly. |
| `background_sync.dart` | **Confirmed.** `BackgroundSyncService` is the **active** engine (30s timer). |
| `sync_service.dart` | **Confirmed duplicate.** `SyncService` is dead code — not wired to any provider. `syncServiceProvider` is an alias for `backgroundSyncServiceProvider`. |
| `cache_service.dart` | **Confirmed.** 5-minute Hive TTL cache for `doctors/departments/medicines/patients`. |
| `providers.dart` | **Confirmed.** Wires `DatabaseService`, `LocalDatabase`, `CacheService`, `BackgroundSyncService`. |
| `20260825000008_offline_first_sync.sql` | **Confirmed.** Adds `offline_id UUID` + `sync_status VARCHAR` (default `synced`) to the 4 core tables, with unique indexes and `UPDATE ... SET offline_id = id` backfill. |
| `20260825000012_background_sync_push_notifications.sql` | **Confirmed** (push/FCM related, not core sync). |

### 1.1 Observed behaviour (confirmed)

1. Native uses drift/SQLite; Web uses Hive/IndexedDB. **Correct.**
2. `LocalTables` = patients, opd_registrations, ipd_admissions, billing. **Correct.**
3. Background sync runs periodically (30s). **Correct** — but **push-only**.
4. Doctors/departments/medicines/patients use a 5-min Hive TTL cache. **Correct.**
5. Some important paths call Supabase directly. **Correct and worse than the lead suggested** — the *entire* primary OPD/patient/billing flow is direct-Supabase:
   - `registerPatient` → direct `.insert()`.
   - `createOPDRegistration` → direct `.insert()`.
   - `generateOPDSlip` / `_syncOpdSlipToBilling` → direct read + update + inserts (billing, billing_items, payment_logs, billing_audit).
   - `saveOfflineData()` exists but is **not called by any OPD/patient screen**.
6. Sync indicator infers "Synced" from pending count alone. **Correct** (`isSynced => !_isSyncing && _pendingCount == 0`).
7. Connectivity check = network present, not reachable/authenticated Supabase. **Correct** (`ConnectivityResult != none`).

### 1.2 Additional gaps found (not in the original lead)

- **No queue token generation.** `opd_registrations.token_number` (INTEGER) exists in the schema, and the slip/queue read it, but the OPD registration flow never sets it. Slip falls back to `LEFT(id, 8)`. Offline OPD step 7 ("Create OPD visit and applicable queue token") is therefore not implemented at all.
- **Collision-prone identifiers generated on-device:**
  - Patient UHID (`patient_registration_screen.dart` `_generateUHID`) = `OPD|IPD` + **second-precision** timestamp — collision-prone across two devices / two registrations in the same second.
  - `_generateBillNumber` = prefix + date + `Random().nextInt(9999)` — collision-prone.
  - `generateWalkInUHID` = `D` + millisecond timestamp — better but still not device-safe.
- **No delete/tombstone propagation.** The sync engine only inserts (`_syncRecord` does `insert`); deletes are local-only.
- **No version/conflict mechanism.** `offline_id` unique index gives upload idempotency for the 4 core tables, but there is no `version` column, no conflict state, and `_syncRecord`'s conflict handling is "server already has this `offline_id` → **silently delete the local copy**" (destroys the local side of a conflict).
- **No pull/download sync.** `syncPendingData()` is upload-only. `fetchDataCached` does a `replaceRecords` cache refresh (destructive) but it is not a cursor-based incremental pull and it overwrites local rows.
- **`replaceRecords` overwrites pending edits.** `fetchDataCached`/`refreshCachedData` call `replaceRecords`, which deletes the whole local table and reinserts — this would wipe un-synced local rows if called on a table that also holds pending records. The 5-minute TTL cache is a *cache*, but the operational `LocalDatabase` shares the same 4 tables, so this is a real hazard.
- **`saveOfflineData` + `_syncRecord` do not persist a real outbox.** They rely on an `is_synced` flag and store the full payload; there is no `operation_type`, `base_version`, `attempt_count`, `next_retry_at`, `last_error`, `dependency group`, or durable acknowledgement.
- **`sync_status` inferred green while a pull has never happened.** Even with `pendingCount == 0`, there is no record of "last successful upload ack + last successful pull".

---

## 2. Offline-readiness matrix (implemented modules)

Legend: **L** = local (SQLite/Hive), **R** = remote (Supabase), **L→R** = local-first with outbox, **cache** = 5-min Hive TTL.

| Module | Tables (actual) | Read path | Create/Update/Delete path | Offline coverage today | Required cloud integration | Missing local data | Conflict strategy (planned) | Phase |
|---|---|---|---|---|---|---|---|---|
| Patients | `patients` (+ `patient_insurances`, `abha_linking_logs`) | R (paged), cache | R (direct `insert`) | ❌ none (direct R) | hospital RLS, `uhid` uniqueness | local patient master + indexes | version check → conflict state (preserve both sides) | 1 |
| OPD registration | `opd_registrations`, `departments`, `doctors` | R, cache | R (direct `insert`) | ❌ none | doctor `prescription_mode`, fee master, token sequence | local OPD rows, doctors, departments, token counter | version check; append-only queue token | 1 |
| OPD slip / billing | `billing`, `billing_items`, `payment_logs`, `billing_audit`, `opd_registrations` | R | R (multi-step read+update+insert) | ❌ none | unified billing, idempotency key | local bill + items + payment | append-only payment; idempotent materialisation | 1 |
| IPD admissions | `ipd_admissions`, `beds`, `bed_allocations` | R | R | ❌ none | bed availability authority | local IPD rows | **needs shared authority** (bed double-allocation) | 3 |
| IPD discharge/billing | `billing`, `ipd_charges`, `ipd_packages`, `ipd_ward_pricing`, `ipd_service_master` | R | R | ❌ none | billing + discharge | — | — | 3 |
| IPD ward transfer | `ward_transfers`, `bed_allocations` | R | R | ❌ none | bed authority | — | shared authority | 3 |
| Prescriptions | `prescriptions`, `prescription_items` | R | R | ❌ none | doctor + patient FKs | — | version check (clinical notes never LWW) | 3 |
| Vitals / progress notes | `vitals`, `progress_notes`, `ipd_vitals`, `ipd_progress_notes` | R | R | ❌ none | patient FKs | — | version check | 3 |
| Diagnostics | `diagnostic_orders`, `diagnostic_order_items`, `diagnostic_results`, `lab_*` | R (paged) | R | ❌ none | — | — | — | 4 |
| Pharmacy | `pharmacy_medicines`, `pharmacy_stock`, `pharmacy_purchases`, `purchase_entries`, `stock_checks` | R | R | ❌ none | stock authority | — | **needs shared authority** (no oversell) | 4 |
| Employees | `employees` | R | R | ❌ none | — | — | — | 5 |
| Attendance | `employee_attendance_punches` | R | R | ❌ none | face/liveness stack audit required | — | append-only/idempotent | 5 |
| PRO / referral visits | `marketing_areas`, `referral_doctors`, `marketing_visits`, `patient_referrals` | R | R | ❌ none | media + GPS upload | — | append-only visit capture | 5 |
| Compliance | `compliance_records/documents/reminders/audit_logs` | R | R | ❌ none | — | — | — | 6 |
| WhatsApp | `whatsapp_*` | R | R | ❌ none | online-only send service | local outbox for messages | revalidate consent/provider at send | 6 |
| ABDM/ABHA | `abha_linking_logs`, `care_contexts`, `consent_artefacts`, `data_flow_logs` | R | R | ❌ (by design online-only) | gateway Edge Function | — | never replay expired requests offline | online-only |
| Reports | `billing_history_view`, `reports`, etc. | R | — | ❌ none | consolidated totals | — | label local scope + last sync | 6 |

**Key:** "Offline coverage today = ❌ none" is the honest baseline: the current `LocalDatabase` is a cache + a push queue, not a local-first operational store, and no screen reads or writes through it for the primary workflows.

---

## 3. Multi-computer limitation (explicit)

### 3.1 What works on ONE disconnected Windows computer

A single provisioned machine can, once baseline data is downloaded and the
offline-access policy permits unlock:

- read locally cached master data (patients/doctors/departments/medicines);
- register patients, create OPD visits/tokens, collect payment, materialise a
  bill, print/reprint the OPD slip, and restart offline — all durably;
- queue all of the above in a local transactional outbox and upload later.

This is a **single-device offline workflow**. It does not coordinate with other
machines while disconnected.

### 3.2 What can work across computers while internet is down but hospital LAN is up

With LAN only (no internet/Supabase), nothing in the current architecture
coordinates two machines. What *could* be made to work with a LAN-only shared
authority (not implemented, and **not introduced in this phase**):

- a single designated "sync master" machine serving read-only snapshots over LAN;
- explicit transfer/import of a signed export from one machine to another.

There is no LAN peer-to-peer replication in this repository, and SQLite files
must **never** be shared directly over a network folder (corruption/locking).

### 3.3 What NEEDS a shared authority (or an explicit single-device ownership policy)

These cannot be made safe by giving each computer an independent local database:

- **Bed allocation / double bed allocation** — two machines can assign the same bed.
- **Pharmacy stock** — two machines can oversell the same batch.
- **Bill numbers / UHIDs / queue tokens** — two machines can mint the same number.

Prevention requires one of:
1. a reachable shared authority (Supabase when online, or a hospital LAN service
   when offline) that enforces uniqueness/availability at commit time; or
2. an explicit **single-device ownership policy** for the affected workflows
   (e.g. "only the front-desk PC admits OPD patients / allocates beds").

### 3.4 Decision needed before enabling affected multi-device workflows

Before IPD beds, pharmacy stock, or shared numbering can be enabled across
multiple disconnected Windows machines, the hospital must choose:

- **(A)** a hospital LAN service (a small on-prem server/authority), **or**
- **(B)** explicit single-device ownership per workflow (documented, enforced in
  the UI by device role), **or**
- **(C)** stay online-only for those workflows (today's behaviour).

This implementation **does not** introduce a hospital server and **does not**
silently impose a single-device restriction. Phase 1 (OPD) works single-device
offline; the multi-device decision is deferred and documented, not hidden.

---

## 4. Phase 0 → Phase 1 implementation order

### Phase 1 (this phase) — Foundation + OPD

1. **Durable local-first repository layer** — typed local operational tables +
   transactional outbox; screens read local, writes commit local immediately.
2. **Schema & data scope** — replicate authorised hospital operational data;
   typed local tables/indexes; minor-unit money; explicit Postgres type mapping;
   versioned local + cloud migrations.
3. **Bootstrap & offline auth** — module readiness states; baseline download;
   offline-access policy (tenant/user-scoped, secure unlock, cached permissions
   with expiry, no offline privilege elevation, protected sync on re-auth).
4. **Transactional outbox** — `operation_id`, `hospital_id`, `device_id`,
   `entity`, `record_id`, `operation_type`, `payload`, `base_version`,
   `dependency/group`, `attempt_count`, `next_retry_at`, `status`, `last_error`;
   stable local UUIDs preserved through sync; business + outbox in one tx;
   server-acknowledged idempotency.
5. **Bidirectional incremental sync** — paginated baseline; durable per-dataset
   cursors; pull new/modified + deletes; atomic cursor advance; never overwrite
   pending edits; parent/child ordering; no overlapping runs; bounded batches;
   backoff+jitter; permission vs network error separation; independent-record
   isolation; reliable server-side version mechanism (migration provided).
6. **Conflict & accounting safety** — append-only payments/attendance; audited
   adjustments; version checks; preserve both sides; server+local validation;
   collision-safe UHID/bill/token allocation.
7. **E2E offline OPD** — full workflow (unlock → search/register patient →
   doctor/department → fees/prescription mode → OPD + token → discount →
   cash/manual payment → bill + items + payment → print/reprint → restart →
   reconnect without duplicates). Preserve A5 slip requirements.
8. **Sync status & performance** — one coordinator, module queues, honest
   green/blue/amber/red/attention/neutral; last-successful-sync, pending count,
   readable failure, retry.

### Phase 2 (documented, not claimed)

- IPD beds, clinical notes, vitals, prescriptions (shared-authority decision required).

### Phase 3–6 (documented)

- Pharmacy stock movements & sales (shared authority).
- Lab orders/results & diagnostics.
- Employees & attendance (face/liveness audit first).
- PRO/referral visits & attachments; broader offline reports & remaining modules.

---

## 5. Migration strategy

- **Local:** drift `schemaVersion` is bumped; existing pending rows are preserved
  (no destructive reset).
- **Cloud:** new migrations
  `supabase/migrations/20260911000000_offline_sync_outbox_v2.sql` (§6) and
  `supabase/migrations/20260912000000_opd_payment_atomic_operation.sql`
  (the atomic OPD payment endpoint, §6.1).
  They are **provided but NOT applied to production** — production migrations
  require explicit approval (see §8), and `docs/production_upgrade_plan.md`
  documents the exact incremental upgrade path and its unverified parts.

---

## 6. Required cloud migration (provided, unapplied)

`supabase/migrations/20260911000000_offline_sync_outbox_v2.sql` adds a
**single global `hims_change_log`** table (not per-row `sync_version`):

- `hims_change_sequence` (global monotonic) + `hims_change_log` with
  `change_id / entity / record_id / operation / hospital_id / new_data`;
- AFTER INSERT/UPDATE triggers write a change-log row **in the same
  transaction** as the business write (a change is never visible before commit);
- `deleted_at TIMESTAMPTZ` on the core tables + BEFORE DELETE soft-delete
  triggers so deletes also produce a change entry;
- the client pulls `change_id > :cursor ORDER BY change_id LIMIT :batch` with a
  **safety overlap + per-record dedupe** to tolerate out-of-order transaction
  commits, and advances the cursor to a safe high-water mark.

Until this migration is applied, the client does **not** fall back to
`updated_at`-ordered pull. It surfaces **"Sync setup incomplete"**
(`SyncHealth.setupRequired`) and never reports "up to date".

### 6.1 Atomic OPD payment operation (second required migration)

`20260912000000_opd_payment_atomic_operation.sql` closes the last accounting
gap: the offline OPD payment used to be uploaded as **four independent**
PostgREST writes, so a failure after the first one could leave the cloud with a
paid visit but no bill, or a bill with no payment.

- `hims_operation_receipts` — one durable row per `operation_id`, holding the
  canonical request payload and the committed result, written in the **same
  transaction** as the accounting rows.
- `public.hims_apply_opd_payment(...)` — `SECURITY DEFINER` with a pinned
  `search_path`; validates and applies the whole operation:
  visit payment transition + `billing` + `billing_items` + `payment_logs` +
  `billing_audit` + receipt commit together or not at all.
- Authorization is derived from `auth.uid()` → `public.users`; the client's
  `hospital_id`/`created_by` are never trusted, and every referenced patient /
  visit / bill is verified to belong to the authorized hospital.
- Idempotency: same `operation_id` + same canonical payload returns the original
  result; same `operation_id` with a different payload raises an explicit
  `hims_opd_payment_conflict`; concurrent retries block on the receipt primary
  key, so they can never double-collect.
- The client sends the operation as ONE outbox entry
  (`DatabaseService.opdPaymentOperationEntity`) and **never** uploads its
  constituent rows through the old per-row path.
- Verified against isolated Postgres: 48/48 accounting checks plus 7/7
  concurrency checks (`docs/offline_sync_backend_verification.md`).

---

## 7. Phase 1 files & responsibilities (delivered)

| File | Change |
|---|---|
| `lib/services/local_db.dart` | Outbox + cursor + conflict APIs, **atomic `applyTransaction`**, scoped `setMetadata/getMetadata`. |
| `lib/services/local_db_io.dart` | Drift: `sync_outbox`, `sync_cursors`, `sync_conflicts`, `app_metadata`; schema v3; single-transaction `applyTransaction`. |
| `lib/services/local_db_web.dart` | Hive mirror (documented best-effort, not atomic). |
| `lib/services/outbox.dart` | `OutboxEntry`, `SyncCursor`, `SyncConflict`, `OutboxUploadResult` models. |
| `lib/services/sync_engine.dart` | Single coordinator: upload + change-log pull, honest `SyncHealth` (incl. `setupRequired`). |
| `lib/services/database_service.dart` | Offline identity mapping, local-first OPD writers, insert+verify idempotency, change-log pull, **single-operation OPD payment routing** (`opdPaymentOperationEntity` → `hims_apply_opd_payment`), **acknowledged-rows sync marking** (`acknowledgedLocalRecords`), OPD-only reconciliation. |
| `lib/app/providers.dart` | `syncEngineProvider`; persist public `users.id` identity on login. |
| `lib/presentation/screens/opd/opd_registration_screen.dart` | Local-first writers; strict public `users.id` FK. |
| `lib/presentation/screens/patients/patient_registration_screen.dart` | Local-first patient save. |
| `lib/presentation/screens/ipd/ipd_admission_screen.dart` | Blocks online IPD admission until the patient is cloud-confirmed; "Sync now" refreshes the patient selectors (never auto-admits). |
| `supabase/migrations/20260825000014_create_doctors_table.sql` | Reconstructs `doctors` **with grants + RLS + tenant trigger** (see §9). |
| `supabase/migrations/20260911000000_offline_sync_outbox_v2.sql` | Server `hims_change_log` + soft-delete; triggers are `SECURITY DEFINER` so authenticated writes work (unapplied in production). |
| `supabase/migrations/20260912000000_opd_payment_atomic_operation.sql` | `hims_operation_receipts` + `hims_apply_opd_payment` (unapplied in production). |
| `test/integration/offline_opd_e2e_test.dart` | Opt-in headless end-to-end run against the isolated backend with a real transport cut. |
| `supabase/verify_opd_payment_atomic.sql`, `supabase/verify_opd_payment_concurrent.sql` | Isolated Postgres checks for accounting atomicity / idempotency / concurrency. |
| `supabase/verify_upgrade_simulation.sql`, `tool/verify_prod_upgrade_simulation.ps1` | Isolated pre-upgrade simulation of the production upgrade plan. |

---

## 8. Safety boundaries (never violated by this upgrade)

- No production permissions changed; no production migration executed.
- Supabase service-role credentials never embedded in clients.
- Hospital/user isolation enforced on local reads/writes/sync.
- Pending operations scoped to their originating hospital + user.
- Sync is not a backup substitute; encrypted backup/restore is a separate later
  phase (documented, not claimed).
- Android/Web features are not removed to simplify Windows.

---

## 9. Known limitations (honest, not hidden)

- Reliable **pull** depends on the unapplied `hims_change_log` migration; until
  it is applied the sync engine reports `SyncHealth.setupRequired` and never
  claims "up to date". No `updated_at` fallback is used.
- Pull ordering uses a **lossless gap-free cursor**: the cursor only advances
  over a contiguous run of `change_id`s, so a late-committing transaction can
  never be permanently skipped.
- **Create replay is verified by payload/accounting hash** — a same-id-different-
  payload collision is treated as a conflict, never as `alreadyCommitted`.
- The **OPD payment transition** (`opd_registrations.payment_status` unpaid→paid)
  is now applied by the single atomic server-side operation
  (`hims_apply_opd_payment`), not by a client-side compare-and-swap. General
  mutable edits will still need a version check once later phases introduce
  them.
- **Web/Hive has no cross-box transaction** — the atomic `applyTransaction` is
  Drift/SQLite-only; on web it is ordered + idempotent, documented as
  best-effort (not atomic).
- **Native SQLite integration tests now PASS** on the Windows dev host. The
  `sqlite3` package is pointed (via the documented `open.overrideFor`) at the
  official precompiled SQLite DLL from sqlite.org, kept project-locally under
  `.qwen/tmp/sqlite3/` (transient, not committed — no global PATH change). The
  Drift tests cover atomic business+outbox persistence, rollback, metadata
  isolation, outbox transitions, and close/reopen persistence. `.qwen/tmp/` is
  transient; a fresh checkout must re-download the DLL to run these tests.
- **Cloud accounting atomicity IS now server-verified** for the OPD payment
  operation: 48/48 accounting checks and 7/7 concurrency checks against isolated
  Postgres (`docs/offline_sync_backend_verification.md`). The compensating
  control is that the four accounting rows are never uploaded individually.
- **Two access defects were found and fixed** while validating the upgrade path,
  and they matter for any deployment:
  1. the change-log trigger functions were not `SECURITY DEFINER`, so **every
     authenticated write** to a tracked table failed with
     `permission denied for table hims_change_log`;
  2. the reconstructed `public.doctors` table had **no grants and no RLS**, so
     the app could not read the doctor master list at all.
- **Production upgrade compatibility is UNVERIFIED.** Three historical
  migrations were renamed to unique versions (they had duplicate version
  numbers) and one `doctors`-table migration was added, so the **local** chain
  builds. No authorized read-only access to the production
  `supabase_migrations.schema_migrations` history was available to confirm the
  renames are inert against it. `docs/production_upgrade_plan.md` holds the
  exact read-only inspection queries, the incremental plan, and the isolated
  simulation results (215/215 pre-upgrade facts preserved). Recording the
  renamed versions **is** a migration-history change and must be approved — it
  is not "no history change". Do **not** rewrite production history, drop
  objects, or reset.
- **Reconciliation scope is deliberately OPD-only** (`patients`,
  `opd_registrations`, `billing`, and the billing child rows). IPD is not
  downloaded for offline use; the only IPD requirement — admitting a
  synchronized offline patient online — is served by the patient dataset. Child
  reconciliation and pull **merge** rows (never wipe the mirror), and the
  billing child rows are mirrored so another client sees a bill's items and
  payment history.
- **The offline outbox orders by enqueue time**, and a foreign-key violation is
  treated as retryable (never as a permanent rejection), so a parent row that
  has not been uploaded yet cannot permanently strand its child.
- Face attendance / ABDM / WhatsApp remain online-only or audited-later.
- Cross-device disconnected consistency is **not** solved (see §3).
- Offline numbering (UHID / bill number / token) is **device-scoped** for
  offline creation and collision-hardened; it is not a hospital-wide ordering
  guarantee (see §3.4).
