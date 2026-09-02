# MediFlux HIMS — Performance Audit & Optimizations

Date: 2026-09-02
Scope: entire `abdm_hims` repository (163 Dart files, ~79k lines in `lib/`)
Platforms: Android + Windows desktop (web must keep building)

All fixes below are performance-only. No billing/OPD/IPD/patient/diagnostics/
pharmacy/attendance/salary/PRO/geofence/compliance/report/auth/RLS/route logic
was changed. Pagination only adds the ability to load further records; it does
not hide or drop data.

---

## 1. Findings (by severity)

### P0 — freezes / crashes / memory leaks
None found that are new. Existing PDF rasterization is flagged as a P1 risk below.

### P1 — unbounded data / N+1 / duplicate heavy work

| # | Finding | File | Platform | Fix |
|---|---------|------|----------|-----|
| 1 | Diagnostic Results screen fetched **every** diagnostic order (unbounded) and then each visible order tile fired its own `getDiagnosticOrderItems` request (N+1). First screen load = 1 huge query + 8–12 item queries; grows with history. | `lib/services/database_service.dart`, `lib/app/providers.dart`, `lib/presentation/screens/diagnostics/diagnostic_result_screen.dart` | Android + Windows | Added server-side pagination (`getDiagnosticOrdersPage`, 30/page, status `inFilter`) and a focused single-order query. Order items now load only when a tile is expanded. |
| 2 | Voucher list fetched the **entire** voucher history for the selected range with all columns, then built every card eagerly in a `ListView(children:)`. Dashboard `getVoucherStats` fetched the same full rows twice just to sum amounts. | `lib/services/database_service.dart`, `lib/app/providers.dart`, `lib/presentation/screens/voucher/voucher_list_screen.dart` | Android + Windows | Added `getVouchersPage` (30/page, `.range`) + `getVoucherRangeAmounts` (amount-only). Voucher screen uses `ListView.builder` + scroll pagination; header total comes from the amount-only range summary so totals stay correct for the whole range. |
| 3 | Compliance dashboard fetched the full record set **3–4× per load** (records grid, stats via `getRecords` again, stats via `getAllDocuments` → `getRecords`, reminder engine → `getRecords`), each with a documents-enrichment query. | `lib/services/compliance_service.dart`, `lib/app/providers.dart`, `lib/presentation/screens/compliance/compliance_dashboard_screen.dart` | Android + Windows | `complianceStatsProvider` now reuses `complianceRecordsProvider` and one `COUNT` query for file count. Reminder engine reuses the already-fetched records. |
| 4 | Patient profile resolved bed numbers with **one query per bed** (up to 50 admissions ⇒ up to 50 lookups). | `lib/services/database_service.dart` | Android + Windows | Replaced with one batch `inFilter('id', bedIds)` query. |
| 5 | Background sync timer started even on the **login screen** (no session) and notified listeners twice per 30-second pass even when nothing changed, causing dashboard/header rebuild churn. `Connectivity()` was constructed fresh every pass. | `lib/app/app_bootstrap_gate.dart`, `lib/services/background_sync.dart`, `lib/services/database_service.dart` | Android + Windows | Sync now starts only with a session + hospital context. `_notify()` is change-aware (skips no-op passes). `Connectivity` instance is reused. |
| 6 | Firebase Core was initialized eagerly in `AppConfig.init` at startup even though only FCM uses it. | `lib/config/app_config.dart` | Android + Windows | Firebase is now initialized lazily inside `PushNotificationService.initialize` (which already had a duplicate-app guard). |

### P2 — unnecessary rebuild / network / payload work

| # | Finding | File | Fix |
|---|---------|------|-----|
| 7 | Compliance `getRecords` live-status refresh updated drifted rows with `.update(...).select()` returning full rows. | `lib/services/compliance_service.dart` | `.select('id')` — same write, smaller response. |
| 8 | WhatsApp campaign audience dialog built every recipient `CheckboxListTile` eagerly (capped height, but unbounded count). | `lib/presentation/screens/whatsapp/whatsapp_campaigns_screen.dart` | `ListView.builder` inside the same 160px constraint. |
| 9 | Diagnostic order screen picker already debounces 400 ms; patient combined search debounces 400 ms; medicine dialog debounces 350 ms. | — | Verified OK; no change needed. |

### P3 — micro-optimizations

| # | Finding | File | Fix |
|---|---------|------|-----|
| 10 | `NumberFormat`/`DateFormat` created per row in employee salary/attendance list items. | `lib/presentation/screens/employees/employee_management_screen.dart` | Cached as `static final` formatters. |

### Documented but intentionally NOT changed (would alter semantics or risk correctness)

- `getLabRevenueStats` category breakdown is all-time and unbounded by design (it is a stats screen). Bounding it to a month would change displayed business numbers.
- `getReports` / compliance records / employee master are unbounded but these are small-to-moderate master/report lists; they are rendered with `ListView.builder` where they can grow. Converting them to pagination would be larger UI churn with little measured benefit.
- Report generation range queries carry a pre-existing `.limit(1000)`. Changing it would alter report totals; left as-is per "reports special case".
- `_syncRecord` uploads pending records one-by-one with a per-record conflict check. This is conflict-handling business logic and pending queues are small; left as-is.
- Compliance PDF viewer rasterizes all PDF pages at once on the UI isolate (`Printing.raster`). This can jank for very large PDFs; a paged/lazy rasterizer is a larger change and was not applied.
- Camera / `mobile_scanner` / audio / video controllers are already initialized on demand and disposed with their screens; verified, no change.

---

## 2. Database index audit

Existing migrations already cover the hot query patterns:

- `20260825000010_database_indexing.sql` — patients (hospital+created, hospital+mobile, name), OPD (hospital+created, hospital+patient, visit_date+doctor), IPD (hospital+created, hospital+patient, bed+status), billing (hospital+bill_date+created, hospital+visit_type+date, hospital+patient, ipd_admission+date), vouchers (hospital+date+created, hospital+date+number), diagnostic orders (hospital+status+created, hospital+created, hospital+patient), secondary tables.
- `20260901000001_employee_hrms_module.sql` — employees, attendance punches (hospital+employee+punched, hospital+punched).
- `20260901000002_pro_marketing_module.sql` — referral doctors, marketing visits (hospital+doctor+visited, hospital+visited, hospital+employee+visited), patient referrals (hospital+date, hospital+doctor+date, hospital+patient).
- `20260828000002_compliance_module.sql` — records/documents/reminders/audit logs.
- `20260901000000_billing_history_view.sql` — adds indexes for the unified billing view query.

**No new migration was added** — no genuinely missing high-value index was found (avoiding over-indexing).

---

## 3. Approximate major-screen request counts (first load)

| Screen | Before | After |
|--------|--------|-------|
| Dashboard | 2 voucher full-table queries (all columns) + local sync reads | 2 amount-only voucher queries + local sync reads |
| Diagnostics Results | 1 unbounded orders query + ~8–12 order-item queries (grows with list) | 1 page query (30 rows); item queries only on expand |
| Voucher list | 1 unbounded full-row query | 1 page query (30 rows) + 1 amount-only range query |
| Compliance dashboard | 3–4 full record fetches + 3–4 document fetches + all-documents fetch | 1 record fetch + 1 document enrichment + 1 COUNT |
| Patient profile | 13 parallel + N bed lookups (up to 50) | 13 parallel + 1 bed batch `inFilter` |
| Billing / OPD / IPD queues / patients | already paginated (30/30/30/20) | unchanged |
| Notifications | 1 query capped at 100 | unchanged |

---

## 4. Validation results

- `flutter analyze` — **0 errors, 0 warnings** (36 pre-existing info-level lints: `print`, deprecation notices). No new issues.
- `flutter test` — **37/37 passed** (after adding a test-only flutter_secure_storage platform-channel mock in `test/widget_test.dart`; the mock is required because secure storage has no test-environment plugin).
- `flutter build web --release` — **succeeded** (`build/web`).
- `flutter build apk --release` — **succeeded** (`build/app/outputs/flutter-apk/app-release.apk`, 93.2 MB).
- `flutter build windows --release` — **succeeded** (`build/windows/x64/runner/Release/MediFlux.exe`).

Platform limitations: no physical Android device / emulator interaction was performed, so no on-device ANR trace or DevTools profile was captured. Findings are static/evidence-based. Both native toolchains (Android SDK 36, Visual Studio 2026) are fully installed.

---

## 5. Business logic & UI behavior confirmation

- No calculations, statuses, routes, permissions, RLS, hospital scoping or stored data semantics changed.
- Pagination is server-side and additive; "load more" is preserved on the voucher and diagnostics lists.
- UI layout/labels/colors/module order are unchanged. Only invisible implementation details (list builders, query bounds, provider wiring) changed.
