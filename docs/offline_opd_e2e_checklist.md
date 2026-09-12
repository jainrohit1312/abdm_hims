# Offline OPD — End-to-End Test Checklist (isolated backend)

Scope: offline patient registration/search, OPD, OPD payments, queue and slip
printing/reprinting, and the online IPD patient handoff. Nothing else.

> **Safety:** every command below targets the **isolated local** Supabase stack
> (`http://127.0.0.1:54321`). Do **not** substitute a production URL. The helper
> script refuses any URL that is not `127.0.0.1` / `localhost`.

## 1. Start the isolated backend

```powershell
cd C:\Projects\abdm_hims
supabase start          # if not already running
supabase db reset       # applies all migrations incl. the offline-sync one
```

Keys are printed by `supabase status` (use the **Publishable** key, never the
secret). In this stack:

- Project URL: `http://127.0.0.1:54321`
- Publishable: `sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH`

## 2. Launch the Windows app against the local backend (safe wrapper)

`tool/run_local_e2e.ps1` (or run the command manually) refuses non-local URLs:

```powershell
$url = "http://127.0.0.1:54321"
if ($url -notmatch '^(http://)?(127\.0\.0\.1|localhost)') {
  throw "Refusing to run E2E against a non-local URL: $url"
}
flutter run -d windows `
  --dart-define=SUPABASE_URL=$url `
  --dart-define=SUPABASE_ANON_KEY=sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH `
  --dart-define=ABDM_REAL_MODE=false
```

## 3. Offline control (no physical Wi-Fi toggle)

A localhost backend is **not** affected by disabling Wi-Fi. Control the app's
backend access instead, by one of:

- Run the automated service-level test, which cuts a real transport in front of
  the app (`test/integration/offline_opd_e2e_test.dart`, §7); or
- Point the app at an unused port for the "offline" phase
  (`SUPABASE_URL=http://127.0.0.1:54399`) — every call fails to connect; or
- Add a debug "block network" switch wired to `DatabaseService.probeSupabase()`
  returning `false`; or
- Use a firewall rule blocking the app's loopback egress (last resort).

Whichever technique is used, **demonstrate that requests genuinely fail** during
the offline portion (a red/amber dashboard state alone is not proof).

## 4. Scenario checklist

| # | Step | Expected |
|---|---|---|
| 1 | Provision online, sign in, let baseline download + reconcile | Dashboard shows "Up to date / Reconciled …" |
| 2 | Switch the app to the offline URL, restart | Dashboard shows red Offline; no crash |
| 3 | Search an existing patient (local) | Local results, no "no records" when data exists |
| 4 | Register a new patient | Saved locally; status Amber "Saved locally, N awaiting upload" |
| 5 | Open OPD for that patient, pay, print | Slip prints (210×148 mm); token valid; ₹ correct; no Net Payable row |
| 6 | Restart still offline | Patient + OPD still present |
| 7 | Open queue, visit details, payment history | All render from local |
| 8 | Reprint the slip | Prints; **no** new payment rows, **no** payment-status change |
| 9 | Try IPD admission for the offline patient | Clear "Patient saved locally. Sync this patient before online IPD admission." No admission, no duplicate patient |
| 10 | Restore the local URL, wait for sync + reconcile | Status returns to green |
| 11 | Verify backend (psql / Studio): exactly one patient (same UHID), one OPD, one billing, one billing_items, one payment_logs; `created_by` is a valid public `users.id` | No duplicates |
| 12 | Retry sync (tap "Sync now" / force a pass) | Still exactly one of each |
| 13 | IPD admission now | Succeeds using the **same** patient id; no duplicate patient |
| 14 | Reconnect a second authorized client (same hospital) | Sees the patient/OPD/bill |
| 15 | Sign out / session expiry, then back in | Pending local ops preserved; sync resumes |
| 16 | Tenant isolation | A different hospital cannot see the patient/rows |

## 5. Backend row-count assertions (synthetic data)

```sql
-- Replace :uhid with the UHID printed on the slip.
SELECT 'patients' AS t, count(*) FROM patients WHERE uhid = :uhid
UNION ALL SELECT 'billing', count(*) FROM billing b JOIN patients p ON p.id = b.patient_id WHERE p.uhid = :uhid
UNION ALL SELECT 'billing_items', count(*) FROM billing_items bi JOIN billing b ON b.id = bi.bill_id JOIN patients p ON p.id = b.patient_id WHERE p.uhid = :uhid
UNION ALL SELECT 'payment_logs', count(*) FROM payment_logs pl JOIN billing b ON b.id = pl.bill_id JOIN patients p ON p.id = b.patient_id WHERE p.uhid = :uhid;
```

## 6. Manual-only checks (not automatable here)

- GUI rendering and printer output (physical/virtual printer).
- Physical network loss (use the offline-URL or proxy technique in §3 instead).
- A second physical client device.

Everything else (migration application, change-log capture, child-record sync,
accounting atomicity/idempotency/concurrency, tenant isolation, reconciliation)
is validated headlessly — see `docs/offline_sync_backend_verification.md`.

## 7. Automated coverage (already executed headlessly)

`test/integration/offline_opd_e2e_test.dart` runs the real client services
against the isolated backend with a **real** transport cut — a loopback HTTP
proxy that is blocked mid-run, which also breaks established keep-alive sockets:

```powershell
$env:HIMS_LOCAL_E2E = "1"
flutter test test/integration/offline_opd_e2e_test.dart
```

It asserts these service-level steps, all of which **passed**:

1. Authorized provisioning + master-data download (the doctor master list is
   downloadable and mirrored).
2. The transport cut produces genuine failures (`probeSupabase()` is false while
   the local network stack is up — so the UI can never report "green").
3. Existing patient search works locally while cut off.
4. A new patient can be registered offline (durable, with an outbox entry).
5. An OPD visit with a queue token and a cash payment can be saved offline.
6. Slip data is readable locally; the bill appears in the local billing list and
   the local queue embeds the patient.
7. **Reprint performs no payment writes** (outbox count and bill count
   unchanged).
8. Online IPD admission is refused while the patient is only local
   (`offline`/`cloudUnreachable`, never `synced`).
9. An app restart while offline preserves the patient, visit, payment and
   pending operations.
10. Connectivity returns and synchronization completes with **zero** pending
    operations and **zero** conflicts; the patient gate flips to `synced`.
11. The backend holds exactly one patient / visit / bill / line item / payment
    log / operation receipt, with the **same** UUIDs as the device, and a retry
    pass creates no duplicates.
12. A second authorized client receives the data through reconciliation,
    including the bill's line items and its payment history.
13. Online IPD admission reuses the **same** patient id — exactly one patient
    and exactly one admission.
14. Tenant isolation holds for another hospital.

**Not** covered by it, and therefore still manual: GUI rendering, the print
dialog and physical/virtual printer output, and a second physical client device.

