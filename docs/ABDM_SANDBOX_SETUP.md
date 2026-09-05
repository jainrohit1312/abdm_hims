# ABDM Sandbox Setup — Secure Backend Foundation

This document covers the **backend-foundation phase only**: Supabase Edge Function
deployment, server-side ABDM session management, the callback gateway, Bridge /
service-management operations, and multi-tenant ABDM security.

> **Reminder:** real ABDM secrets must **never** be committed to Git, placed in
> Flutter source, `web/env.js`, `--dart-define`, `.env.example`, browser local
> storage, database tables, logs, or any API response sent to Flutter.

---

## 1. Supabase Edge Function secrets

Set these in **Supabase Dashboard → Edge Functions → Secrets** (or via
`supabase secrets set`). They exist only as Edge Function secrets.

| Secret name | Required | Purpose |
|---|---|---|
| `ABDM_CLIENT_ID` | yes | ABDM gateway client id |
| `ABDM_CLIENT_SECRET` | yes | ABDM gateway client secret (rotated — do not reuse the exposed one) |
| `ABDM_BASE_URL` | no | Gateway base URL. Defaults to `https://dev.abdm.gov.in` |
| `ABDM_BRIDGE_ID` | no | Your ABDM Bridge id (kept for audit/display; the Bridge path does **not** append it) |
| `ABDM_HIP_ID` | no | Your HIP facility id |
| `ABDM_HIU_ID` | no | Your HIU id |
| `ABDM_CALLBACK_BASE_URL` | no | Public base URL of this function, e.g. `https://<project-ref>.supabase.co/functions/v1/abdm-gateway` |
| `ABDM_SESSION_PATH` | no | Session endpoint path override. Default `/gateway/v1/sessions` — **requires confirmation** (v0.5 variant: `/gateway/v0.5/sessions`) |
| `ABDM_BRIDGE_PATH` | no | Bridge endpoint path override. Default `/gateway/v1/bridges` |
| `ABDM_SERVICES_PATH` | no | addUpdateServices path override. Default `/gateway/v1/bridges/addUpdateServices` |
| `ABDM_GET_SERVICES_PATH` | no | getServices path override. Default `/gateway/v1/bridges/getServices` |
| `ABDM_SERVICE_TYPES` | no | Comma-separated official service types accepted for `services[].type`. Default `HIP,HIU` — **confirm against the onboarding email / official docs** |

`SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are injected
automatically by Supabase.

### Set secrets (CLI)

```bash
supabase secrets set \
  ABDM_CLIENT_ID="<your-client-id>" \
  ABDM_CLIENT_SECRET="<your-rotated-client-secret>" \
  ABDM_BASE_URL="https://dev.abdm.gov.in" \
  ABDM_BRIDGE_ID="<your-bridge-id>" \
  ABDM_HIP_ID="<your-hip-id>" \
  ABDM_HIU_ID="<your-hiu-id>" \
  ABDM_CALLBACK_BASE_URL="https://<project-ref>.supabase.co/functions/v1/abdm-gateway"
```

---

## 2. Deployment

```bash
# Link the project (once)
supabase link --project-ref <project-ref>

# Push migrations (creates abdm_gateway_callbacks + hardens ABDM RLS)
supabase db push

# Deploy the gateway function
supabase functions deploy abdm-gateway
```

Verify the function exists:

```bash
supabase functions list
```

### Public callback access (`verify_jwt = false`)

`supabase/config.toml` already contains:

```toml
[functions.abdm-gateway]
verify_jwt = false
```

This is required because ABDM callbacks do **not** carry a Supabase user JWT.
With platform JWT verification disabled:

- public `POST /<callback-subpath>` routes are accepted without a JWT;
- `session`, `bridge`, `addUpdateServices` and `getServices` actions still
  **manually** validate the Supabase user JWT inside the function and require
  an owner/super-admin role;
- callback routes can never reach an administrative action (routing ignores
  `action` values on callback subpaths).

---

## 3. Callback URL format

ABDM callbacks are sent to the deployed function URL with a callback subpath
appended by the gateway, for example:

```text
https://<project-ref>.supabase.co/functions/v1/abdm-gateway/<callback-subpath>
```

Example (HIP patient status notify — subpath contract requires confirmation):

```text
https://<project-ref>.supabase.co/functions/v1/abdm-gateway/v0.5/patients/status/notify
```

The function:

- accepts `POST` with JSON content type (non-JSON → `415`),
- applies a 256 KiB payload-size limit (`413` when exceeded),
- applies a best-effort per-worker rate limit for public callbacks
  (120 requests/minute/IP → `429`),
- preserves the callback subpath (`callback_path`),
- captures `request-id` / `timestamp` headers,
- sanitizes the payload (tokens/secrets/OTP/Aadhaar redacted) before storing,
- stores `hospital_id = null` — a client-supplied `hospital_id` is **never
  trusted** for RLS ownership,
- deduplicates on `(request_id, callback_path)`,
- returns an immediate ABDM-compatible acknowledgement (`200 {"status":"ACK"}`).

> **Callback signature limitation:** the current official documentation does not
> specify a callback signature/source-verification header for this phase. Until
> one is specified, callback authenticity relies on TLS + the public URL. Do not
> treat callback payloads as trusted input; they are sanitized and only stored,
> never used to mutate clinical data.

> **Platform note:** Supabase Edge Functions match the bare function URL. If
> your Supabase project does not route subpaths to the function, put a thin
> proxy/custom domain in front that forwards the full path, or confirm the
> current Supabase subpath-routing behaviour during Sandbox verification.

---

## 4. Session connectivity test (owner-only)

All internal actions require a HIMS user session (`Authorization: Bearer
<user-jwt>`). `session`, `bridge` and `services` additionally require an
owner/super-admin role (`role` = `admin` or `super_admin`). `health` only
requires an authenticated user.

```bash
curl -X POST \
  "https://<project-ref>.supabase.co/functions/v1/abdm-gateway" \
  -H "Authorization: Bearer <owner-user-jwt>" \
  -H "Content-Type: application/json" \
  -d '{"action":"session"}'
```

Expected (sanitized — the raw ABDM token is never returned):

```json
{
  "status": "connected",
  "baseUrl": "https://dev.abdm.gov.in",
  "clientId": "<masked-client-id>",
  "sessionValidForSeconds": 3400,
  "note": "ABDM session established server-side. The raw token is never returned."
}
```

---

## 5. Bridge URL update procedure (owner-only)

Defaults to `PATCH https://dev.abdm.gov.in/gateway/v1/bridges` with body
`{"url": "<valid-https-callback-base-url>"}`. No `/{bridgeId}` is appended.

```bash
curl -X PATCH \
  "https://<project-ref>.supabase.co/functions/v1/abdm-gateway" \
  -H "Authorization: Bearer <owner-user-jwt>" \
  -H "Content-Type: application/json" \
  -d '{"action":"bridge","callbackUrl":"https://<project-ref>.supabase.co/functions/v1/abdm-gateway"}'
```

The function obtains the server-side ABDM access token and sends
`Authorization: Bearer <abdm-token>` + `Content-Type: application/json` on the
Bridge request. The response is sanitized before being returned.

---

## 6. HIP / HIU service registration procedure (owner-only)

Service type, id, aliases and endpoint use must be copied from the
**current official ABDM Sandbox documentation / onboarding email**. No real
service ids are embedded in this project.

Defaults to `POST https://dev.abdm.gov.in/gateway/v1/bridges/addUpdateServices`
with the exact ABDM array body:

```bash
curl -X POST \
  "https://<project-ref>.supabase.co/functions/v1/abdm-gateway" \
  -H "Authorization: Bearer <owner-user-jwt>" \
  -H "Content-Type: application/json" \
  -d '{
    "action": "services",
    "services": [
      {
        "id": "<service-id-from-abdm-docs>",
        "name": "<service-name>",
        "type": "<official-service-type>",
        "active": true,
        "alias": ["<alias-1>"],
        "endpoints": [
          {
            "address": "https://<project-ref>.supabase.co/functions/v1/abdm-gateway/<notify-subpath>",
            "connectionType": "https",
            "use": "<official-endpoint-use>"
          }
        ]
      }
    ]
  }'
```

Validation performed server-side:

- `services` must be a non-empty array,
- each entry requires `id`, `name`, `type`, `active` (boolean),
  `alias` (array of strings) and a non-empty `endpoints` array,
- `type` is validated against `ABDM_SERVICE_TYPES` (default `HIP,HIU` —
  **confirm against the onboarding email**),
- each endpoint requires `address` (https) — the field is **not** renamed from
  `url`; `connectionType` must be `"https"`; `use` is required.

---

## 7. getServices verification (owner-only)

Defaults to `GET https://dev.abdm.gov.in/gateway/v1/bridges/getServices`.

```bash
curl -X GET \
  "https://<project-ref>.supabase.co/functions/v1/abdm-gateway?action=services" \
  -H "Authorization: Bearer <owner-user-jwt>"
```

Returns the sanitized ABDM services list. Bearer tokens / credentials are never
returned to the client.

---

## 8. Secret rotation procedure

1. Generate a new Client Secret in the ABDM Sandbox portal.
2. Update the Edge Function secret:
   ```bash
   supabase secrets set ABDM_CLIENT_SECRET="<new-secret>"
   ```
3. Deploy the function so new workers pick it up:
   ```bash
   supabase functions deploy abdm-gateway
   ```
4. Run the session connectivity test (section 4) and the Bridge update
   (section 5) to confirm the new credentials work.
5. Never commit the old or new secret. Treat the old secret as compromised and
   revoke it in the ABDM portal if possible.

---

## 9. Rollback instructions

- **Function rollback:** redeploy the previous working commit:
  ```bash
  git checkout <previous-good-commit> -- supabase/functions/abdm-gateway
  supabase functions deploy abdm-gateway
  ```
- **Migration rollback:** migrations are additive and idempotent. To remove the
  callback table and ABDM RLS hardening, apply a manual rollback script in the
  SQL Editor (drop the new policies/table), or restore a database backup taken
  before `supabase db push`.
- **Flutter rollback:** rebuild without the `--dart-define=ABDM_REAL_MODE=true`
  flag (the switch defaults to `false`) to return the app to mock mode without
  redeploying the backend.

---

## 10. Verification checklist

- [ ] All ABDM secrets exist only in Supabase Edge Function secrets.
- [ ] `grep -R "ABDM_CLIENT_SECRET" lib web .env.example` returns no real value.
- [ ] `supabase/config.toml` has `[functions.abdm-gateway] verify_jwt = false`.
- [ ] `supabase db push` applied both migrations.
- [ ] `supabase functions deploy abdm-gateway` succeeded.
- [ ] Session connectivity test returns `status: connected` (manual, real call).
- [ ] Bridge callback URL update returns a sanitized success response (manual).
- [ ] `getServices` returns the ABDM-registered service list (manual).
- [ ] A test callback `POST`ed to the callback URL is acknowledged and appears
      in `abdm_gateway_callbacks`.
- [ ] Duplicate callback with the same `request-id` + path does not create a
      duplicate row.
- [ ] `flutter test` passes.
- [ ] `deno test` passes for the Edge Function core + handler logic.

> **Do not claim Sandbox verification** unless the manual API calls above were
> completed successfully against the live Sandbox with the new secrets.

---

## 11. Contract-confirmation register

Confirmed defaults for the initial Bridge-management endpoints (per the
onboarding email):

| Item | Default | Status |
|---|---|---|
| Gateway base URL | `https://dev.abdm.gov.in` | Confirmed default |
| Bridge update | `PATCH /gateway/v1/bridges` body `{"url": "..."}` | Confirmed default |
| addUpdateServices | `POST /gateway/v1/bridges/addUpdateServices` (array body) | Confirmed default |
| getServices | `GET /gateway/v1/bridges/getServices` | Confirmed default |
| Service entry fields | `id`, `name`, `type`, `active`, `alias[]`, `endpoints[]` | Confirmed structure |
| Endpoint fields | `address`, `connectionType: "https"`, `use` | Confirmed structure |
| Gateway request headers | `Authorization: Bearer <access-token>` + `Content-Type: application/json` | Confirmed per current auth docs |

Still requiring confirmation from the current official documentation:

| Item | Default / behaviour | Status |
|---|---|---|
| Session endpoint path | `POST /gateway/v1/sessions` (`/gateway/v0.5/sessions` is the documented v0.5 variant) | **Requires confirmation** |
| Official service-type list | `HIP,HIU` via `ABDM_SERVICE_TYPES` | **Requires confirmation** (copy from onboarding email) |
| Official endpoint `use` values | supplied by the operator, validated only as non-empty | **Requires confirmation** |
| Callback acknowledgement body | `200 {"status":"ACK"}` | **Requires confirmation** |
| Callback subpath patterns (HIP/HIU notify paths) | Function accepts and persists any subpath | **Requires confirmation** |
| Callback signature / source verification header | None specified yet | **Limitation documented** |

---

## 12. RLS multi-hospital isolation verification (manual SQL)

Run these checks in the Supabase SQL Editor while logged in as an
authenticated user (RLS applies to `authenticated`):

```sql
-- 1. Current hospital id helper must resolve for your user.
select public.current_user_hospital_id();

-- 2. A hospital user can only see their own hospital's ABDM callbacks:
select count(*) from public.abdm_gateway_callbacks;

-- 3. Attempting to insert a callback for another hospital must fail
--    (RLS WITH CHECK rejects it; use another hospital's id).
insert into public.abdm_gateway_callbacks (hospital_id, callback_path)
values ('<other-hospital-id>', '/rls-test');
-- expect: new row violates row-level security policy
```

Repeat with two different hospital users to confirm isolation across
`abha_profiles`, `care_contexts`, `consent_artefacts`, `data_flow_logs`,
`fhir_records`, `abha_linking_logs` and `abdm_gateway_callbacks`.

> Note: the Edge Function stores callbacks with `hospital_id = null` because a
> client-supplied hospital id is untrusted. A deterministic server-side mapping
> (e.g. ABDM HIP/HIU id → hospital) can be added when the official docs specify
> one.

---

## 13. M1 (ABHA identity) integration architecture

```
Flutter authenticated user
  → Supabase Edge Function `abdm-gateway`  (manual JWT validation)
  → ABDM Sandbox M1/ABHA API               (NOT IMPLEMENTED until contract confirmed)
```

The Flutter client sends only:

```json
{ "action": "<M1 action>", "payload": { } }
```

and never calls ABDM directly. ABDM Client Secret, ABDM access token, private
keys and any encryption material stay exclusively inside the Edge Function.

### 13.1 M1 actions

| Action | Purpose | Continuation txn required |
|---|---|---|
| `m1GenerateAadhaarOtp` | Aadhaar OTP generation | no |
| `m1VerifyAadhaarOtp` | Aadhaar OTP verification / eKYC | yes |
| `m1CreateAbha` | ABHA creation (pre-verified flow) | yes |
| `m1GetProfile` | ABHA profile retrieval | no |
| `m1VerifyAbhaNumber` | ABHA number verification | no |
| `m1SearchByMobile` | ABHA search by mobile | no |
| `m1VerifyAbhaAddress` | ABHA Address verification | no |
| `m1GetAbhaCard` | ABHA card retrieval | no |
| `m1GetAbhaQr` | ABHA QR retrieval (only if an official API exists) | no |

Every M1 action validates the Supabase JWT, resolves the HIMS user and
hospital, applies the M1 permission policy, validates/normalizes input, binds
continuation steps to a server-side transaction, applies per-user rate limits
(OTP endpoints are throttled harder), sanitizes every response, and maps
failures to the structured `ABDM_M1_*` error contract.

### 13.2 M1 permission policy

* Patient-facing M1 operations: `super_admin`, `admin`, `receptionist`
  (configurable via `ABDM_M1_ALLOWED_ROLES`; the default targets authorized
  registration/front-desk staff).
* Bridge / `session` / `services` / `getServices`: unchanged, admin /
  super_admin only.
* M1 operations additionally require a non-null hospital context.

### 13.3 CONTRACT GATE — do not skip

This repository contains **no official client-supplied M1/ABHA contract**, so
every real M1 operation is deliberately **stopped with
`ABDM_M1_CONTRACT_UNCONFIRMED` (HTTP 501)** before any outbound request is
built. No M1 endpoint path, method, request body, header set, encryption format
or response shape is invented by this project.

When the client supplies the current official Sandbox M1/ABHA contract, the
operator must configure the exact values from that contract and implement the
outbound request builder from it:

| Secret/config name | Required | Meaning |
|---|---|---|
| `ABDM_M1_BASE_URL` | yes for M1 | Official M1/ABHA API base URL from the client contract |
| `ABDM_M1_GENERATE_AADHAAR_OTP_PATH` | yes for that op | Official generate-OTP endpoint path |
| `ABDM_M1_VERIFY_AADHAAR_OTP_PATH` | yes for that op | Official verify-OTP/eKYC endpoint path |
| `ABDM_M1_CREATE_ABHA_PATH` | yes for that op | Official create-ABHA endpoint path |
| `ABDM_M1_GET_PROFILE_PATH` | yes for that op | Official profile retrieval endpoint path |
| `ABDM_M1_VERIFY_ABHA_NUMBER_PATH` | yes for that op | Official ABHA number verification path |
| `ABDM_M1_SEARCH_BY_MOBILE_PATH` | yes for that op | Official mobile search path |
| `ABDM_M1_VERIFY_ABHA_ADDRESS_PATH` | yes for that op | Official ABHA Address verification path |
| `ABDM_M1_GET_ABHA_CARD_PATH` | yes for that op | Official card retrieval path |
| `ABDM_M1_GET_ABHA_QR_PATH` | no (blocked by default) | Official QR path, if any |
| `ABDM_M1_ALLOWED_ROLES` | no | Comma-separated M1 roles; default `super_admin,admin,receptionist` |
| `ABDM_M1_ABHA_ADDRESS_SUFFIXES` | no | Allowed ABHA address domains; default `abdm,sbx` |

All `ABDM_M1_*_PATH` values must be copied from the official contract — they
are **not** defaulted and **not** guessed. Until then M1 real-mode requests
fail closed with `ABDM_M1_CONTRACT_UNCONFIRMED`.

### 13.4 Sensitive-data rules implemented

* Raw Aadhaar is never stored, logged or returned; the Edge Function validates
  the 12 digits and discards the value.
* OTP is never stored or logged (including masked OTP); Flutter clears OTP
  state after submission.
* ABHA number: 14 digits (dashes optional); mobile: valid Indian mobile;
  ABHA Address: validated against the configured official domains.
* Transaction ids are bound server-side to user + hospital + operation with an
  expiry (`abdm_m1_transactions`, service-role only) — never trusted blindly.
* No unsafe retries: OTP generation and ABHA creation are never replayed on
  401/403 (the generic Bridge retry is disabled for those operations).
* Mobile numbers returned to Flutter are masked to the final four digits.

### 13.5 Patient linking and consent evidence

* `link_abha_profile` RPC atomically upserts `abha_profiles`, updates
  `patients.abha_id / abha_address / abha_linked`, and writes a
  `abha_linking_logs` success row under hospital isolation.
* The partial unique index `uq_abha_profiles_hospital_abha` prevents the same
  ABHA number from being linked to two patients in the same hospital.
* `abha_m1_consent_evidence` stores non-sensitive consent evidence (purpose,
  text/version, timestamp, operator, hospital, patient where known, safe
  transaction correlation id). No Aadhaar / OTP is stored with it.
* The create flow records consent evidence and the UI wording is limited to
  ABHA creation/verification — it does not claim health-record-sharing consent.

### 13.6 Manual live verification sequence (DO NOT execute until contract supplied)

1. Confirm the official client-supplied M1/ABHA Sandbox contract (endpoints,
   methods, request/response bodies, headers, encryption, token acceptance).
2. Configure the exact `ABDM_M1_*` values listed in 13.3 as Edge Function
   secrets.
3. Implement the outbound request builder in `handler.ts` from that contract
   (replace the contract gate with the confirmed call for each action).
4. Deploy `supabase functions deploy abdm-gateway`.
5. `supabase db push` (applies `20260904000002_abdm_m1_secure_linking.sql`).
6. Log in as a receptionist/admin, create/verify an ABHA in real mode
   (`ABDM_REAL_MODE=true`) and confirm each M1 state renders correctly.
7. Verify `abdm_m1_transactions` / `abha_m1_consent_evidence` /
   `abha_linking_logs` rows contain no Aadhaar, OTP, token or KYC payload.

### 13.7 Safe troubleshooting codes (sanitized, returned to Flutter)

| Code | Meaning |
|---|---|
| `ABDM_M1_INVALID_INPUT` | Client input failed validation |
| `ABDM_M1_NO_SESSION` | Server-side ABDM session could not be established |
| `ABDM_M1_FORBIDDEN` | Role/hospital policy rejected the operation |
| `ABDM_M1_CONTRACT_UNCONFIRMED` | Official M1 contract not configured — blocked by design |
| `ABDM_M1_PROVISIONING_REQUIRED` | ABDM portal/client provisioning pending |
| `ABDM_M1_OTP_REQUEST_FAILED` / `ABDM_M1_OTP_INVALID` | OTP generation/verification failures |
| `ABDM_M1_TRANSACTION_EXPIRED` | Continuation txn missing, expired, consumed or foreign |
| `ABDM_M1_PROFILE_NOT_FOUND` | No ABHA record for the search input |
| `ABDM_M1_ALREADY_EXISTS` | ABHA already exists where creation was requested |
| `ABDM_M1_UPSTREAM_400/401/403/404/409/429/500` | Mapped upstream status |
| `ABDM_M1_TIMEOUT` / `ABDM_M1_NETWORK` | Transport failures |

### 13.8 Remaining blocked by ABDM approval

* Every live M1 outbound call (contract-gated, see 13.3).
* Aadhaar/OTP encryption format (implemented only from the official contract).
* ABHA card / QR binary response shapes.
* Mobile search and ABHA Address verification official availability for this
  registered client.
* Bridge `getServices` provisioning (returns HTTP 403 `Resource forbidden`;
  this is a portal provisioning issue, not an M1 code failure).
