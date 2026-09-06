// ============================================================================
// ABDM V3 M2 (HIP) — official contract constants, validators, builders and
// processing pipeline.
// ----------------------------------------------------------------------------
// CONTRACT SOURCE (reviewed 2026-09-06)
//   NHA official ABDM-wrapper v3 source (github.com/NHA-ABDM/ABDM-wrapper):
//   - application-v3.properties (gatewayBaseUrl = https://dev.abdm.gov.in/api/hiecm)
//   - v3/common/constants/GatewayURL.java (inbound HIP callback paths)
//   - v3/hip/hrp/discover, link/userInitiated, consent, dataTransfer services
//     (outbound gateway paths + request/response bodies)
//
// The V3 session / bridge-services / bridge-url endpoints used by the rest of
// this project are in core.ts. This module intentionally imports the canonical
// V3 token + header + fetch primitives from core.ts so no parallel session or
// token logic exists.
//
// SECURITY
//   * No secrets or patient clinical data are ever logged here.
//   * Callback payloads passed to stores are sanitized by the caller.
//   * Link-confirm tokens are never persisted raw (only a SHA-256 hash).
// ============================================================================

import {
  acquireV3AccessToken,
  asRecord,
  buildV3AuthenticatedHeaders,
  type FetchImpl,
  freshV3RequestId,
  freshV3Timestamp,
  type GatewayConfig,
  type GatewayHttpResponse,
  type V3SessionRequestOptions,
  V3_GATEWAY_BASE_URL,
  v3FetchJson,
  v3GatewayPost,
  type V3TokenCacheRef,
} from "./core.ts";

// ----------------------------------------------------------------------------
// Official V3 M2 gateway paths (HIP -> ABDM gateway)
// ----------------------------------------------------------------------------

/** HIP -> Gateway: user-initiated linking on-discover response. */
export const V3_M2_ON_DISCOVER_PATH =
  "/api/hiecm/user-initiated-linking/v3/patient/care-context/on-discover";
/** HIP -> Gateway: user-initiated linking on-init response. */
export const V3_M2_ON_INIT_PATH =
  "/api/hiecm/user-initiated-linking/v3/link/care-context/on-init";
/** HIP -> Gateway: user-initiated linking on-confirm response. */
export const V3_M2_ON_CONFIRM_PATH =
  "/api/hiecm/user-initiated-linking/v3/link/care-context/on-confirm";
/** HIP -> Gateway: consent notification acknowledgement. */
export const V3_M2_CONSENT_ON_NOTIFY_PATH =
  "/api/hiecm/consent/v3/request/hip/on-notify";
/** HIP -> Gateway: health-information request acknowledgement. */
export const V3_M2_HEALTH_INFORMATION_ON_REQUEST_PATH =
  "/api/hiecm/data-flow/v3/health-information/hip/on-request";
/** HIP -> Gateway: health-information data-transfer completion notification. */
export const V3_M2_HEALTH_INFORMATION_NOTIFY_PATH =
  "/api/hiecm/data-flow/v3/health-information/notify";

// ----------------------------------------------------------------------------
// Official V3 M2 inbound callback paths (ABDM gateway -> HIP bridge)
// ----------------------------------------------------------------------------

export const V3_M2_CB_DISCOVER = "/api/v3/hip/patient/care-context/discover";
export const V3_M2_CB_LINK_INIT = "/api/v3/hip/link/care-context/init";
export const V3_M2_CB_LINK_CONFIRM = "/api/v3/hip/link/care-context/confirm";
export const V3_M2_CB_CONSENT_NOTIFY = "/api/v3/consent/request/hip/notify";
export const V3_M2_CB_HEALTH_INFORMATION_REQUEST =
  "/api/v3/hip/health-information/request";
// Acknowledgement-only inbound callbacks (HIP-initiated linking / ack flows).
export const V3_M2_CB_PROFILE_SHARE = "/api/v3/hip/patient/share";
export const V3_M2_CB_LINK_ON_NOTIFY = "/api/v3/links/context/on-notify";
export const V3_M2_CB_SMS_ON_NOTIFY = "/api/v3/patients/sms/on-notify";
export const V3_M2_CB_ON_ADD_CARE_CONTEXT = "/api/v3/link/on_carecontext";
export const V3_M2_CB_ON_GENERATE_TOKEN = "/api/v3/hip/token/on-generate-token";

export const V3_M2_HIP_ID_HEADER = "X-HIP-ID";

export type M2CallbackType =
  | "discover"
  | "linkInit"
  | "linkConfirm"
  | "consentNotify"
  | "healthInformationRequest"
  | "profileShare"
  | "linkOnNotify"
  | "smsOnNotify"
  | "onAddCareContext"
  | "onGenerateToken";

const M2_CALLBACK_TYPE_BY_PATH: Readonly<Record<string, M2CallbackType>> = {
  [V3_M2_CB_DISCOVER.toLowerCase()]: "discover",
  [V3_M2_CB_LINK_INIT.toLowerCase()]: "linkInit",
  [V3_M2_CB_LINK_CONFIRM.toLowerCase()]: "linkConfirm",
  [V3_M2_CB_CONSENT_NOTIFY.toLowerCase()]: "consentNotify",
  [V3_M2_CB_HEALTH_INFORMATION_REQUEST.toLowerCase()]:
    "healthInformationRequest",
  [V3_M2_CB_PROFILE_SHARE.toLowerCase()]: "profileShare",
  [V3_M2_CB_LINK_ON_NOTIFY.toLowerCase()]: "linkOnNotify",
  [V3_M2_CB_SMS_ON_NOTIFY.toLowerCase()]: "smsOnNotify",
  [V3_M2_CB_ON_ADD_CARE_CONTEXT.toLowerCase()]: "onAddCareContext",
  [V3_M2_CB_ON_GENERATE_TOKEN.toLowerCase()]: "onGenerateToken",
};

/** Maps an inbound subpath to its canonical V3 M2 callback type (or null). */
export function m2CallbackTypeForSubpath(subpath: string): M2CallbackType | null {
  const path = subpath.toLowerCase().replace(/\/+$/, "");
  return M2_CALLBACK_TYPE_BY_PATH[path] ?? null;
}

/** ABDM gateway base path used by every M2 outbound request. */
export function m2GatewayBasePath(): string {
  return V3_GATEWAY_BASE_URL;
}

// ----------------------------------------------------------------------------
// Persistence row + store contracts (implemented by index.ts, faked in tests)
// ----------------------------------------------------------------------------

export interface M2Hospital {
  hospitalId: string;
  facilityId: string;
  facilityName: string;
  hipName: string;
}

export interface M2RequestRow {
  hospital_id: string | null;
  request_id: string | null;
  transaction_id: string | null;
  request_type: string;
  callback_path: string;
  status: string;
  payload: Record<string, unknown>;
  response_payload?: Record<string, unknown> | null;
  link_ref_number?: string | null;
  token_hash?: string | null;
  expires_at?: string | null;
  error_code?: string | null;
  error_message?: string | null;
  received_at: string;
}

export type M2InsertResult = "inserted" | "duplicate";

export interface M2LinkInitRecord {
  request_id: string | null;
  transaction_id: string | null;
  abha_address: string | null;
  link_ref_number: string;
  token_hash: string;
  expires_at: string | null;
  care_context_refs: string[];
}

export interface M2RequestStore {
  insert(row: M2RequestRow): Promise<M2InsertResult>;
  updateLinkInit(
    requestId: string,
    record: M2LinkInitPersistRecord,
  ): Promise<void>;
  findLinkInitByLinkRef(
    linkRefNumber: string,
  ): Promise<M2LinkInitRecord | null>;
  /** Number of link-init attempts for an ABHA address in a hospital window. */
  countRecentLinkInit(
    abhaAddress: string,
    hospitalId: string,
    sinceIso: string,
  ): Promise<number>;
  markProcessed(
    requestId: string,
    requestType: string,
    status: string,
    responsePayload: Record<string, unknown> | null,
    errorCode?: string | null,
    errorMessage?: string | null,
  ): Promise<void>;
}

export interface M2CareContext {
  referenceNumber: string;
  display: string;
  hiType: string;
}

export interface M2PatientMatch {
  patientReference: string;
  patientDisplay: string;
  careContexts: M2CareContext[];
}

export interface M2CareContextStore {
  findUnlinkedByAbha(
    abhaId: string,
    hospitalId: string,
  ): Promise<M2PatientMatch | null>;
  findForReferences(
    abhaId: string,
    careContextRefs: string[],
    hospitalId: string,
  ): Promise<M2CareContext[]>;
  markLinked(
    abhaId: string,
    careContextRefs: string[],
    hospitalId: string,
  ): Promise<void>;
}

export interface M2ConsentArtefactRow {
  hospital_id: string;
  patient_id?: string | null;
  abha_id: string;
  consent_id: string;
  hip_id: string | null;
  hiu_id: string | null;
  purpose: string | null;
  data_from: string | null;
  data_to: string | null;
  status: string;
  granted_at: string | null;
  expires_at: string | null;
  care_context_references: string[];
  hi_types: string[];
}

export interface M2ConsentStore {
  upsert(row: M2ConsentArtefactRow): Promise<{ error: { code?: string; message: string } | null }>;
  findByConsentId(consentId: string): Promise<M2ConsentArtefactRow | null>;
}

/** Persisted health-information data-transfer job lifecycle. */
export const M2_JOB_STATUS = {
  QUEUED: "queued",
  PREPARING: "preparing",
  ENCRYPTED: "encrypted",
  PUSHING: "pushing",
  PUSHED: "pushed",
  NOTIFYING: "notifying",
  COMPLETED: "completed",
  BLOCKED_SAFE: "blocked_safe",
  FAILED_SAFE: "failed_safe",
} as const;

export type M2JobStatus = typeof M2_JOB_STATUS[keyof typeof M2_JOB_STATUS];

export interface M2DataTransferJobRow {
  hospital_id: string | null;
  consent_id: string;
  transaction_id: string;
  status: string;
  care_context_references: string[];
  care_context_hi_types: string[];
  fhir_bundle: Record<string, unknown> | null;
  key_material: Record<string, unknown>;
  data_push_url: string | null;
  attempts: number;
  error_code: string | null;
  error_message: string | null;
  lease_owner?: string | null;
  lease_expires_at?: string | null;
  last_attempt_at?: string | null;
  next_retry_at?: string | null;
  notification_status?: string | null;
  encrypted_entries?: Record<string, unknown>[] | null;
}

export interface M2DataTransferJobStore {
  upsert(row: M2DataTransferJobRow): Promise<{ error: { code?: string; message: string } | null }>;
  /**
   * Atomically claims the oldest due job (status in a retryable state and
   * next_retry_at <= now, or no lease) and marks it preparing with the given
   * lease owner. Returns null when no job is claimable so two workers can
   * never execute the same job simultaneously.
   */
  claimDue(
    now: string,
    leaseOwner: string,
    leaseSeconds: number,
    hospitalId: string,
  ): Promise<M2DataTransferJobRow | null>;
}

export interface M2LinkNotifier {
  sendOtp(input: {
    abhaAddress: string;
    mobile: string;
    linkRefNumber: string;
    token: string;
    expiresAt: string;
  }): Promise<{ ok: boolean; code?: string; error?: string }>;
}

// ----------------------------------------------------------------------------
// Validation contracts
// ----------------------------------------------------------------------------

export interface M2Validation<T> {
  ok: boolean;
  errors: string[];
  value?: T;
}

export interface M2DiscoverRequest {
  requestId: string;
  transactionId: string;
  timestamp: string;
  patientId: string; // ABHA address sent as patient.id
  name: string;
  gender: string;
  yearOfBirth: string;
  hipId: string;
}

export interface M2LinkInitRequest {
  transactionId: string;
  abhaAddress: string;
  patientReference: string;
  patientDisplay: string;
  careContextRefs: string[];
}

export interface M2LinkConfirmRequest {
  requestId: string;
  linkRefNumber: string;
  token: string;
}

export interface M2ConsentNotification {
  requestId: string;
  timestamp: string;
  consentId: string;
  status: string;
  signature: string | null;
  patientId: string | null;
  careContextRefs: string[];
  hiTypes: string[];
  purposeText: string | null;
  hipId: string | null;
  hiuId: string | null;
  dataFrom: string | null;
  dataTo: string | null;
  dataEraseAt: string | null;
}

export interface M2HealthInformationRequest {
  requestId: string;
  timestamp: string;
  transactionId: string;
  consentId: string;
  dateFrom: string | null;
  dateTo: string | null;
  dataPushUrl: string;
  keyMaterial: {
    cryptoAlg: string;
    curve: string;
    dhPublicKey: {
      expiry: string | null;
      parameters: string | null;
      keyValue: string;
    };
    nonce: string | null;
  };
}

function m2Text(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function m2Record(value: unknown): Record<string, unknown> {
  return asRecord(value);
}

function m2Validation<T>(
  ok: boolean,
  errors: string[],
  value?: T,
): M2Validation<T> {
  return ok ? { ok, errors, value } : { ok, errors };
}

function requireString(
  record: Record<string, unknown>,
  key: string,
  errors: string[],
  label: string,
): string {
  const value = m2Text(record[key]);
  if (!value) errors.push(`${label} is required`);
  return value;
}

function optionalString(
  record: Record<string, unknown>,
  key: string,
): string | null {
  const value = m2Text(record[key]);
  return value || null;
}

/** Extracts care-context references from an array of objects. */
export function extractCareContextRefs(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  const out: string[] = [];
  for (const entry of value) {
    const record = m2Record(entry);
    const ref = optionalString(record, "careContextReference") ??
      optionalString(record, "referenceNumber");
    if (ref && !out.includes(ref)) out.push(ref);
  }
  return out;
}

export function validateM2DiscoverRequest(
  body: Record<string, unknown>,
  hipId: string,
): M2Validation<M2DiscoverRequest> {
  const errors: string[] = [];
  const requestId = requireString(body, "requestId", errors, "requestId");
  const transactionId = requireString(body, "transactionId", errors, "transactionId");
  const timestamp = requireString(body, "timestamp", errors, "timestamp");
  const patient = m2Record(body["patient"]);
  const patientId = requireString(patient, "id", errors, "patient.id");
  const name = optionalString(patient, "name") ?? "";
  const gender = optionalString(patient, "gender") ?? "";
  const yearOfBirth = optionalString(patient, "yearOfBirth") ?? "";
  if (!hipId) errors.push("X-HIP-ID header is required");
  return m2Validation(errors.length === 0, errors, {
    requestId,
    transactionId,
    timestamp,
    patientId,
    name,
    gender,
    yearOfBirth,
    hipId,
  });
}

export function validateM2LinkInitRequest(
  body: Record<string, unknown>,
): M2Validation<M2LinkInitRequest> {
  const errors: string[] = [];
  const transactionId = requireString(body, "transactionId", errors, "transactionId");
  const abhaAddress = requireString(body, "abhaAddress", errors, "abhaAddress");
  const patients = Array.isArray(body["patient"]) ? body["patient"] as unknown[] : [];
  if (patients.length === 0) {
    errors.push("patient array is required");
    return m2Validation(false, errors);
  }
  const first = m2Record(patients[0]);
  const patientReference = optionalString(first, "referenceNumber") ?? "";
  const patientDisplay = optionalString(first, "display") ?? "";
  const careContextRefs = extractCareContextRefs(first["careContexts"]);
  if (!patientReference) errors.push("patient[0].referenceNumber is required");
  if (careContextRefs.length === 0) errors.push("patient[0].careContexts is required");
  return m2Validation(errors.length === 0, errors, {
    transactionId,
    abhaAddress,
    patientReference,
    patientDisplay,
    careContextRefs,
  });
}

export function validateM2LinkConfirmRequest(
  body: Record<string, unknown>,
): M2Validation<M2LinkConfirmRequest> {
  const errors: string[] = [];
  const requestId = requireString(body, "requestId", errors, "requestId");
  const confirmation = m2Record(body["confirmation"]);
  const linkRefNumber = requireString(confirmation, "linkRefNumber", errors, "confirmation.linkRefNumber");
  const token = requireString(confirmation, "token", errors, "confirmation.token");
  return m2Validation(errors.length === 0, errors, {
    requestId,
    linkRefNumber,
    token,
  });
}

export function validateM2ConsentNotification(
  body: Record<string, unknown>,
): M2Validation<M2ConsentNotification> {
  const errors: string[] = [];
  const requestId = requireString(body, "requestId", errors, "requestId");
  const timestamp = requireString(body, "timestamp", errors, "timestamp");
  const notification = m2Record(body["notification"]);
  const consentId = requireString(notification, "consentId", errors, "notification.consentId");
  const status = requireString(notification, "status", errors, "notification.status");
  const detail = m2Record(notification["consentDetail"]);
  const patient = m2Record(detail["patient"]);
  const patientId = optionalString(patient, "id");
  const careContexts = Array.isArray(detail["careContexts"]) ? detail["careContexts"] as unknown[] : [];
  const careContextRefs = extractCareContextRefs(careContexts);
  const hiTypes = Array.isArray(detail["hiTypes"])
    ? (detail["hiTypes"] as unknown[]).filter((v): v is string => typeof v === "string")
    : [];
  const purpose = m2Record(detail["purpose"]);
  const hip = m2Record(detail["hip"]);
  const hiu = m2Record(detail["hiu"]);
  const permission = m2Record(detail["permission"]);
  const dateRange = m2Record(permission["dateRange"]);
  if (careContextRefs.length === 0) errors.push("notification.consentDetail.careContexts is required");
  if (!patientId) errors.push("notification.consentDetail.patient.id is required");
  return m2Validation(errors.length === 0, errors, {
    requestId,
    timestamp,
    consentId,
    status: status.toUpperCase(),
    signature: optionalString(notification, "signature"),
    patientId,
    careContextRefs,
    hiTypes,
    purposeText: optionalString(purpose, "text"),
    hipId: optionalString(hip, "id"),
    hiuId: optionalString(hiu, "id"),
    dataFrom: optionalString(dateRange, "from"),
    dataTo: optionalString(dateRange, "to"),
    dataEraseAt: optionalString(permission, "dataEraseAt"),
  });
}

export function validateM2HealthInformationRequest(
  body: Record<string, unknown>,
): M2Validation<M2HealthInformationRequest> {
  const errors: string[] = [];
  const requestId = requireString(body, "requestId", errors, "requestId");
  const timestamp = requireString(body, "timestamp", errors, "timestamp");
  const transactionId = requireString(body, "transactionId", errors, "transactionId");
  const hiRequest = m2Record(body["hiRequest"]);
  const consent = m2Record(hiRequest["consent"]);
  const consentId = requireString(consent, "id", errors, "hiRequest.consent.id");
  const dataPushUrl = requireString(hiRequest, "dataPushUrl", errors, "hiRequest.dataPushUrl");
  const dateRange = m2Record(hiRequest["dateRange"]);
  const keyMaterial = m2Record(hiRequest["keyMaterial"]);
  const cryptoAlg = requireString(keyMaterial, "cryptoAlg", errors, "hiRequest.keyMaterial.cryptoAlg");
  const curve = optionalString(keyMaterial, "curve");
  const dhPublicKey = m2Record(keyMaterial["dhPublicKey"]);
  const keyValue = requireString(dhPublicKey, "keyValue", errors, "hiRequest.keyMaterial.dhPublicKey.keyValue");
  return m2Validation(errors.length === 0, errors, {
    requestId,
    timestamp,
    transactionId,
    consentId,
    dateFrom: optionalString(dateRange, "from"),
    dateTo: optionalString(dateRange, "to"),
    dataPushUrl,
    keyMaterial: {
      cryptoAlg,
      curve: curve ?? "",
      dhPublicKey: {
        expiry: optionalString(dhPublicKey, "expiry"),
        parameters: optionalString(dhPublicKey, "parameters"),
        keyValue,
      },
      nonce: optionalString(keyMaterial, "nonce"),
    },
  });
}

// ----------------------------------------------------------------------------
// Outbound body builders (HIP -> ABDM gateway)
// ----------------------------------------------------------------------------

export interface M2PatientCareContextHiType {
  referenceNumber: string;
  display: string;
  careContexts: M2CareContext[];
  hiType: string;
  count: number;
}

/** Groups care contexts by hiType into the V3 patient array shape. */
export function groupCareContextsByHiType(
  patientReference: string,
  patientDisplay: string,
  careContexts: M2CareContext[],
): M2PatientCareContextHiType[] {
  const grouped = new Map<string, M2CareContext[]>();
  for (const context of careContexts) {
    const hiType = context.hiType || "HealthDocumentRecord";
    const list = grouped.get(hiType) ?? [];
    list.push({ ...context, hiType });
    grouped.set(hiType, list);
  }
  return [...grouped.entries()].map(([hiType, contexts]) => ({
    referenceNumber: patientReference,
    display: patientDisplay || patientReference,
    careContexts: contexts.map((context) => ({
      referenceNumber: context.referenceNumber,
      display: context.display,
      hiType: context.hiType,
    })),
    hiType,
    count: contexts.length,
  }));
}

export function buildOnDiscoverBody(input: {
  transactionId: string;
  requestId: string;
  patient: M2PatientCareContextHiType[];
  matchedBy: string[];
}): Record<string, unknown> {
  return {
    transactionId: input.transactionId,
    patient: input.patient,
    matchedBy: input.matchedBy,
    response: { requestId: input.requestId },
  };
}

export function buildOnDiscoverErrorBody(input: {
  transactionId: string;
  requestId: string;
  code: string;
  message: string;
}): Record<string, unknown> {
  return {
    transactionId: input.transactionId,
    response: { requestId: input.requestId },
    error: { code: input.code, message: input.message },
  };
}

export function buildOnInitBody(input: {
  transactionId: string;
  requestId: string;
  linkReferenceNumber: string;
  authenticationType: string;
  communicationMedium: string;
  communicationHint: string;
  communicationExpiry: string;
}): Record<string, unknown> {
  return {
    transactionId: input.transactionId,
    link: {
      referenceNumber: input.linkReferenceNumber,
      authenticationType: input.authenticationType,
      meta: {
        communicationMedium: input.communicationMedium,
        communicationHint: input.communicationHint,
        communicationExpiry: input.communicationExpiry,
      },
    },
    response: { requestId: input.requestId },
  };
}

export function buildOnInitErrorBody(input: {
  transactionId: string;
  requestId: string;
  code: string;
  message: string;
}): Record<string, unknown> {
  return {
    transactionId: input.transactionId,
    response: { requestId: input.requestId },
    error: { code: input.code, message: input.message },
  };
}

export function buildOnConfirmBody(input: {
  requestId: string;
  patient: M2PatientCareContextHiType[];
}): Record<string, unknown> {
  return {
    patient: input.patient,
    response: { requestId: input.requestId },
  };
}

export function buildOnConfirmErrorBody(input: {
  requestId: string;
  code: string;
  message: string;
}): Record<string, unknown> {
  return {
    response: { requestId: input.requestId },
    error: { code: input.code, message: input.message },
  };
}

export function buildConsentOnNotifyBody(input: {
  requestId: string;
  status: "OK" | "FAILURE";
  consentId: string;
}): Record<string, unknown> {
  return {
    response: { requestId: input.requestId },
    acknowledgement: { status: input.status, consentId: input.consentId },
  };
}

export function buildConsentOnNotifyErrorBody(input: {
  requestId: string;
  code: string;
  message: string;
}): Record<string, unknown> {
  return {
    response: { requestId: input.requestId },
    error: { code: input.code, message: input.message },
  };
}

export function buildHealthInformationOnRequestBody(input: {
  requestId: string;
  transactionId: string;
  sessionStatus: "ACKNOWLEDGED";
}): Record<string, unknown> {
  return {
    hiRequest: {
      transactionId: input.transactionId,
      sessionStatus: input.sessionStatus,
    },
    response: { requestId: input.requestId },
  };
}

export function buildHealthInformationOnRequestErrorBody(input: {
  requestId: string;
  code: string;
  message: string;
}): Record<string, unknown> {
  return {
    response: { requestId: input.requestId },
    error: { code: input.code, message: input.message },
  };
}

export function buildHealthInformationNotifyBody(input: {
  consentId: string;
  transactionId: string;
  doneAt: string;
  hipId: string;
  sessionStatus: "TRANSFERRED" | "FAILED";
  statusResponses: Array<{
    careContextReference: string;
    hiStatus: "DELIVERED" | "ERRORED";
    description: string;
  }>;
}): Record<string, unknown> {
  return {
    requestId: freshV3RequestId(),
    timestamp: freshV3Timestamp(),
    notification: {
      consentId: input.consentId,
      transactionId: input.transactionId,
      doneAt: input.doneAt,
      notifier: { type: "HIP", id: input.hipId },
      statusNotification: {
        sessionStatus: input.sessionStatus,
        hipId: input.hipId,
        statusResponses: input.statusResponses,
      },
    },
  };
}

// ----------------------------------------------------------------------------
// Canonical V3 M2 outbound POST (reuses core.ts session/token primitives)
// ----------------------------------------------------------------------------

export async function m2GatewayPost(
  fetchImpl: FetchImpl,
  config: GatewayConfig,
  cache: V3TokenCacheRef,
  hipId: string,
  path: string,
  body: unknown,
  options: V3SessionRequestOptions = {},
): Promise<GatewayHttpResponse> {
  return v3GatewayPost(
    fetchImpl,
    config,
    cache,
    V3_M2_HIP_ID_HEADER,
    hipId,
    path,
    body,
    options,
  );
}

// ----------------------------------------------------------------------------
// Link token helpers (OTP/link token generation + hashing)
// ----------------------------------------------------------------------------

export function generateLinkToken(): string {
  const token = Math.floor(100000 + Math.random() * 900000).toString();
  return token;
}

export function generateLinkRefNumber(): string {
  return freshV3RequestId();
}

export async function sha256Hex(value: string): Promise<string> {
  try {
    if (typeof crypto !== "undefined" && crypto.subtle) {
      const data = new TextEncoder().encode(value);
      const digest = await crypto.subtle.digest("SHA-256", data);
      return [...new Uint8Array(digest)]
        .map((byte) => byte.toString(16).padStart(2, "0"))
        .join("");
    }
  } catch (_) {
    // fall through to simple hash for non-WebCrypto test environments
  }
  let hash = 0;
  for (let i = 0; i < value.length; i++) {
    hash = ((hash << 5) - hash + value.charCodeAt(i)) | 0;
  }
  return `fnv_${(hash >>> 0).toString(16)}`;
}

export function maskMobile(value: string): string {
  const digits = value.replace(/\D/g, "");
  if (digits.length < 4) return "XXXXXX0000";
  return `XXXXXX${digits.slice(-4)}`;
}

// ----------------------------------------------------------------------------
// FHIR R4 mapping layer (ABDM-supported resource/bundle structure)
// ----------------------------------------------------------------------------

export interface M2FhirPatientSource {
  abhaId: string;
  abhaAddress?: string | null;
  name?: string | null;
  gender?: string | null;
  dateOfBirth?: string | null;
}

export interface M2FhirClinicalSource {
  recordType: string;
  recordId: string;
  display: string;
  careContextReference: string;
  dateTime?: string | null;
  data?: Record<string, unknown>;
}

export interface M2FhirBundleSource {
  patient: M2FhirPatientSource;
  careContexts: M2FhirClinicalSource[];
}

export interface M2FhirBundleResult {
  ok: boolean;
  bundle?: Record<string, unknown>;
  error?: string;
}

export function fhirPatientId(abhaId: string): string {
  return abhaId.replace(/[^a-zA-Z0-9]/g, "") || "unknown";
}

function fhirResourceTypeForRecordType(recordType: string): string {
  switch (recordType.toLowerCase()) {
    case "prescription":
      return "MedicationRequest";
    case "lab_report":
    case "diagnostic_report":
      return "DiagnosticReport";
    case "opd_visit":
    case "ipd_admission":
    case "consultation":
    case "encounter":
      return "Encounter";
    case "discharge_summary":
      return "DocumentReference";
    default:
      return "DocumentReference";
  }
}

/** Maps a Mediflux record type to the ABDM V3 HI type. */
export function hiTypeForRecordType(recordType: string): string {
  switch (recordType.toLowerCase()) {
    case "opd_visit":
    case "consultation":
      return "OPConsultation";
    case "prescription":
      return "Prescription";
    case "lab_report":
    case "diagnostic_report":
      return "DiagnosticReport";
    case "discharge_summary":
      return "DischargeSummary";
    case "immunization":
      return "ImmunizationRecord";
    case "wellness_record":
      return "WellnessRecord";
    default:
      return "HealthDocumentRecord";
  }
}

/**
 * Builds an ABDM-supported FHIR R4 Bundle from real Mediflux source rows.
 * Fails safely (ok:false) when mandatory source data is absent.
 */
export function buildFhirBundleFromSource(
  source: M2FhirBundleSource,
): M2FhirBundleResult {
  if (!source?.patient?.abhaId) {
    return { ok: false, error: "Mandatory patient source data is absent" };
  }
  if (!Array.isArray(source.careContexts) || source.careContexts.length === 0) {
    return { ok: false, error: "Mandatory clinical source data is absent" };
  }

  const patientId = fhirPatientId(source.patient.abhaId);
  const now = new Date().toISOString();
  const entries: Record<string, unknown>[] = [];

  const patientResource: Record<string, unknown> = {
    resourceType: "Patient",
    id: patientId,
    identifier: [
      { system: "https://healthid.ndhm.gov.in", value: source.patient.abhaId },
    ],
  };
  if (source.patient.name) {
    patientResource["name"] = [{ text: source.patient.name }];
  }
  if (source.patient.gender) {
    patientResource["gender"] =
      source.patient.gender.toLowerCase() === "male"
        ? "male"
        : source.patient.gender.toLowerCase() === "female"
        ? "female"
        : "other";
  }
  if (source.patient.dateOfBirth) {
    patientResource["birthDate"] = source.patient.dateOfBirth;
  }
  entries.push({
    fullUrl: `Patient/${patientId}`,
    resource: patientResource,
  });

  for (const careContext of source.careContexts) {
    const resourceType = fhirResourceTypeForRecordType(careContext.recordType);
    const resourceId = careContext.recordId || careContext.careContextReference;
    const resource: Record<string, unknown> = {
      resourceType,
      id: resourceId,
      status: "final",
      subject: { reference: `Patient/${patientId}` },
      identifier: [
        {
          system: "https://abdm.gov.in/fhir/care-context",
          value: careContext.careContextReference,
        },
      ],
    };
    if (resourceType === "Encounter") {
      resource["class"] = { code: "AMB" };
      if (careContext.dateTime) resource["period"] = { start: careContext.dateTime };
    } else if (resourceType === "DocumentReference") {
      resource["type"] = { text: careContext.recordType };
      resource["date"] = careContext.dateTime ?? now;
      resource["content"] = [{ attachment: { title: careContext.display } }];
    } else if (resourceType === "DiagnosticReport") {
      resource["code"] = { text: careContext.recordType };
      resource["issued"] = careContext.dateTime ?? now;
    } else if (resourceType === "MedicationRequest") {
      resource["intent"] = "order";
      resource["authoredOn"] = careContext.dateTime ?? now;
    }
    if (careContext.data && typeof careContext.data === "object") {
      Object.assign(resource, careContext.data);
    }
    entries.push({
      fullUrl: `${resourceType}/${resourceId}`,
      resource,
    });
  }

  return {
    ok: true,
    bundle: {
      resourceType: "Bundle",
      type: "document",
      timestamp: now,
      identifier: {
        system: "https://abdm.gov.in/fhir",
        value: `bundle-${patientId}-${Date.now()}`,
      },
      entry: entries,
    },
  };
}

// ----------------------------------------------------------------------------
// Data-transfer pipeline (encryption is injectable; live transfer is gated)
// ----------------------------------------------------------------------------

export interface M2HealthInformationEntry {
  content: string;
  media: "application/fhir+json";
  checksum: string;
  careContextReference: string;
}

export interface M2EncryptionResult {
  ok: boolean;
  code?: string;
  message?: string;
  entries?: M2HealthInformationEntry[];
  keyMaterial?: Record<string, unknown>;
}

export interface M2Encryptor {
  /** False while the official V3 encryption contract is not available. */
  readonly available: boolean;
  encrypt(
    bundle: Record<string, unknown>,
    keyMaterial: M2HealthInformationRequest["keyMaterial"],
    careContextRefs: string[],
  ): Promise<M2EncryptionResult>;
}

export function buildDataTransferJob(input: {
  hospitalId: string | null;
  consentId: string;
  transactionId: string;
  careContextRefs: string[];
  careContextHiTypes: string[];
  fhirBundle: Record<string, unknown> | null;
  keyMaterial: Record<string, unknown>;
  dataPushUrl: string | null;
  status: string;
  errorCode?: string | null;
  errorMessage?: string | null;
}): M2DataTransferJobRow {
  return {
    hospital_id: input.hospitalId,
    consent_id: input.consentId,
    transaction_id: input.transactionId,
    status: input.status,
    care_context_references: input.careContextRefs,
    care_context_hi_types: input.careContextHiTypes,
    fhir_bundle: input.fhirBundle,
    key_material: input.keyMaterial,
    data_push_url: input.dataPushUrl,
    attempts: 0,
    error_code: input.errorCode ?? null,
    error_message: input.errorMessage ?? null,
  };
}

// ----------------------------------------------------------------------------
// M2 processing error (sanitized, HTTP-ready)
// ----------------------------------------------------------------------------

export class M2ProcessingError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

/** Error codes shared by M2 handlers. */
export const M2_ERROR_CODES = {
  INVALID_REQUEST: "ABDM_M2_INVALID_REQUEST",
  HIP_NOT_FOUND: "ABDM_M2_HIP_NOT_FOUND",
  PATIENT_NOT_FOUND: "ABDM-1010",
  INVALID_TOKEN: "ABDM-1035",
  OTP_SEND_FAILED: "ABDM_M2_OTP_SEND_FAILED",
  CONSENT_INVALID: "ABDM_M2_CONSENT_INVALID",
  CONSENT_EXPIRED: "ABDM_M2_CONSENT_EXPIRED",
  SOURCE_DATA_ABSENT: "ABDM_M2_SOURCE_DATA_ABSENT",
  ENCRYPTION_UNAVAILABLE: "ABDM_M2_ENCRYPTION_UNAVAILABLE",
  TRANSFER_GATED: "ABDM_M2_TRANSFER_GATED",
  LINK_REQUEST_UNKNOWN: "ABDM_M2_LINK_REQUEST_UNKNOWN",
} as const;

// ----------------------------------------------------------------------------
// M2 callback processing pipeline (validates, persists, builds outbound)
// ----------------------------------------------------------------------------

export interface M2ProcessRuntime {
  fetchImpl: FetchImpl;
  config: GatewayConfig;
  v3TokenCache: V3TokenCacheRef;
  hospital: M2Hospital;
  careContextStore: M2CareContextStore;
  consentStore: M2ConsentStore;
  dataTransferJobStore: M2DataTransferJobStore;
  /** Link-init records (token hash lookup for confirm callbacks). */
  linkInitStore: M2RequestStore;
  encryptor: M2Encryptor | null;
  /** When false, live health-information transfer is never attempted. */
  dataTransferEnabled: boolean;
  /** Delivers link OTP/token to the patient. Production may be unavailable. */
  linkNotifier: M2LinkNotifier | null;
  /** Builds a FHIR bundle source for the consent's care contexts. */
  fetchFhirSource: (
    abhaId: string,
    careContextRefs: string[],
    hospitalId: string,
  ) => Promise<M2FhirBundleSource | null>;
}

export interface M2OutboundCall {
  path: string;
  body: Record<string, unknown>;
}

export interface M2LinkInitPersistRecord {
  linkRefNumber: string;
  tokenHash: string;
  expiresAt: string;
  abhaAddress: string;
  careContextRefs: string[];
}

export interface M2ProcessResult {
  /** HTTP status returned to the ABDM gateway for the inbound callback. */
  ackStatus: number;
  /** Outbound gateway request to send after the ACK (or null). */
  outbound: M2OutboundCall | null;
  /** Sanitized processing summary for the event row. */
  status: string;
  errorCode: string | null;
  errorMessage: string | null;
  /** Persist link-init record (only for linkInit callbacks). */
  linkInitRecord?: M2LinkInitPersistRecord;
  /** Queued transfer job (only when live execution is ready to start). */
  transferJob?: M2DataTransferJobRow;
}

function processError(
  status: number,
  code: string,
  message: string,
): never {
  throw new M2ProcessingError(status, code, message);
}

function consentIsUsable(consent: M2ConsentArtefactRow | null): {
  usable: boolean;
  error?: string;
  code?: string;
} {
  if (!consent) {
    return {
      usable: false,
      error: "Consent artefact not found",
      code: M2_ERROR_CODES.CONSENT_INVALID,
    };
  }
  const status = consent.status.toLowerCase();
  if (status !== "granted" && status !== "active") {
    return {
      usable: false,
      error: `Consent is ${consent.status}`,
      code: M2_ERROR_CODES.CONSENT_INVALID,
    };
  }
  const expiresAt = consent.expires_at ? Date.parse(consent.expires_at) : NaN;
  if (Number.isFinite(expiresAt) && expiresAt <= Date.now()) {
    return {
      usable: false,
      error: "Consent has expired",
      code: M2_ERROR_CODES.CONSENT_EXPIRED,
    };
  }
  return { usable: true };
}

/** Fail-closed consent validation for a health-information transfer. */
export function validateConsentForTransfer(input: {
  consent: M2ConsentArtefactRow;
  careContextRefs: string[];
  careContextHiTypes: string[];
  now: Date;
}): { ok: boolean; code?: string; error?: string } {
  const { consent, careContextRefs, careContextHiTypes, now } = input;

  // 1. Consent status + expiry (same rules as consentIsUsable).
  const usable = consentIsUsable(consent);
  if (!usable.usable) return { ok: false, code: usable.code, error: usable.error };

  // 2. Care-context references must be non-empty and fully owned by the
  //    consent artefact for this hospital.
  if (careContextRefs.length === 0) {
    return {
      ok: false,
      code: M2_ERROR_CODES.CONSENT_INVALID,
      error: "Consent has no care-context references",
    };
  }
  const allowed = new Set(consent.care_context_references);
  for (const ref of careContextRefs) {
    if (!allowed.has(ref)) {
      return {
        ok: false,
        code: M2_ERROR_CODES.CONSENT_INVALID,
        error: `Care-context reference ${ref} is not covered by the consent`,
      };
    }
  }

  // 3. Consent time window (permission dateRange).
  const from = consent.data_from ? Date.parse(consent.data_from) : NaN;
  const to = consent.data_to ? Date.parse(consent.data_to) : NaN;
  if (Number.isFinite(from) && now.getTime() < from) {
    return {
      ok: false,
      code: M2_ERROR_CODES.CONSENT_INVALID,
      error: "Consent permission window has not started",
    };
  }
  if (Number.isFinite(to) && now.getTime() > to) {
    return {
      ok: false,
      code: M2_ERROR_CODES.CONSENT_EXPIRED,
      error: "Consent permission window has ended",
    };
  }

  // 4. HI types: when the consent lists HI types, every transferred care
  //    context must map to an allowed HI type. Empty consent hi_types means
  //    "not recorded" and does NOT authorize everything — transfers are then
  //    blocked until the consent artefact records its HI types.
  if (!Array.isArray(consent.hi_types) || consent.hi_types.length === 0) {
    return {
      ok: false,
      code: M2_ERROR_CODES.CONSENT_INVALID,
      error: "Consent artefact does not record HI types",
    };
  }
  const allowedHiTypes = new Set(consent.hi_types.map((t) => t.toUpperCase()));
  for (const hiType of careContextHiTypes) {
    if (!allowedHiTypes.has(hiType.toUpperCase())) {
      return {
        ok: false,
        code: M2_ERROR_CODES.CONSENT_INVALID,
        error: `HI type ${hiType} is not covered by the consent`,
      };
    }
  }

  return { ok: true };
}

/** Resolves an inbound M2 callback into a validated outbound gateway request. */
export async function processM2Callback(
  type: M2CallbackType,
  body: Record<string, unknown>,
  requestId: string,
  runtime: M2ProcessRuntime,
): Promise<M2ProcessResult> {
  switch (type) {
    case "discover":
      return processM2Discover(body, requestId, runtime);
    case "linkInit":
      return processM2LinkInit(body, requestId, runtime);
    case "linkConfirm":
      return processM2LinkConfirm(body, requestId, runtime);
    case "consentNotify":
      return processM2ConsentNotify(body, requestId, runtime);
    case "healthInformationRequest":
      return processM2HealthInformationRequest(body, requestId, runtime);
    case "profileShare":
    case "linkOnNotify":
    case "smsOnNotify":
    case "onAddCareContext":
    case "onGenerateToken":
      return {
        ackStatus: 200,
        outbound: null,
        status: "acknowledged",
        errorCode: null,
        errorMessage: null,
      };
    default:
      processError(400, M2_ERROR_CODES.INVALID_REQUEST, `Unsupported M2 callback type: ${type}`);
  }
}

async function processM2Discover(
  body: Record<string, unknown>,
  requestId: string,
  runtime: M2ProcessRuntime,
): Promise<M2ProcessResult> {
  const validation = validateM2DiscoverRequest(body, runtime.hospital.facilityId);
  if (!validation.ok || !validation.value) {
    processError(400, M2_ERROR_CODES.INVALID_REQUEST, validation.errors.join("; "));
  }
  const discover = validation.value;

  const match = await runtime.careContextStore.findUnlinkedByAbha(
    discover.patientId,
    runtime.hospital.hospitalId,
  );

  if (!match || match.careContexts.length === 0) {
    return {
      ackStatus: 200,
      status: "patient_not_found",
      errorCode: M2_ERROR_CODES.PATIENT_NOT_FOUND,
      errorMessage: "Patient not found",
      outbound: {
        path: V3_M2_ON_DISCOVER_PATH,
        body: buildOnDiscoverErrorBody({
          transactionId: discover.transactionId,
          requestId,
          code: M2_ERROR_CODES.PATIENT_NOT_FOUND,
          message: "Patient not found",
        }),
      },
    };
  }

  const patient = groupCareContextsByHiType(
    match.patientReference,
    match.patientDisplay,
    match.careContexts,
  );

  return {
    ackStatus: 200,
    status: "on_discover_sent",
    errorCode: null,
    errorMessage: null,
    outbound: {
      path: V3_M2_ON_DISCOVER_PATH,
      body: buildOnDiscoverBody({
        transactionId: discover.transactionId,
        requestId,
        patient,
        matchedBy: ["ABHA_ADDRESS"],
      }),
    },
  };
}

async function processM2LinkInit(
  body: Record<string, unknown>,
  requestId: string,
  runtime: M2ProcessRuntime,
): Promise<M2ProcessResult> {
  const validation = validateM2LinkInitRequest(body);
  if (!validation.ok || !validation.value) {
    processError(400, M2_ERROR_CODES.INVALID_REQUEST, validation.errors.join("; "));
  }
  const init = validation.value;

  const match = await runtime.careContextStore.findForReferences(
    init.abhaAddress,
    init.careContextRefs,
    runtime.hospital.hospitalId,
  );
  if (match.length === 0) {
    return {
      ackStatus: 200,
      status: "link_init_error",
      errorCode: M2_ERROR_CODES.PATIENT_NOT_FOUND,
      errorMessage: "Care contexts not found for patient",
      outbound: {
        path: V3_M2_ON_INIT_PATH,
        body: buildOnInitErrorBody({
          transactionId: init.transactionId,
          requestId,
          code: M2_ERROR_CODES.PATIENT_NOT_FOUND,
          message: "Care contexts not found for patient",
        }),
      },
    };
  }

  // Attempt limit: a patient (ABHA address) may only receive a bounded number
  // of link OTPs per hospital per window. The count is tenant-scoped and
  // derived from persisted link-init events, so it survives worker restarts.
  const attemptWindowMs = 10 * 60 * 1000;
  const recentAttempts = await runtime.linkInitStore.countRecentLinkInit(
    init.abhaAddress,
    runtime.hospital.hospitalId,
    new Date(Date.now() - attemptWindowMs).toISOString(),
  );
  if (recentAttempts >= 5) {
    return {
      ackStatus: 200,
      status: "link_init_attempt_limit",
      errorCode: M2_ERROR_CODES.OTP_SEND_FAILED,
      errorMessage: "Too many link OTP attempts for this patient",
      outbound: {
        path: V3_M2_ON_INIT_PATH,
        body: buildOnInitErrorBody({
          transactionId: init.transactionId,
          requestId,
          code: M2_ERROR_CODES.OTP_SEND_FAILED,
          message: "Too many link OTP attempts for this patient",
        }),
      },
    };
  }

  const linkReferenceNumber = generateLinkRefNumber();
  const token = generateLinkToken();
  const tokenHash = await sha256Hex(token);
  const expiresAt = new Date(Date.now() + 10 * 60 * 1000).toISOString();

  const persistRecord: M2LinkInitPersistRecord = {
    linkRefNumber: linkReferenceNumber,
    tokenHash,
    expiresAt,
    abhaAddress: init.abhaAddress,
    careContextRefs: init.careContextRefs,
  };

  const notifier = runtime.linkNotifier;
  let notifierErrorCode: string | null = M2_ERROR_CODES.OTP_SEND_FAILED;
  let notifierErrorMessage = "Link OTP could not be delivered to the patient";
  let notifierOk = false;
  if (notifier) {
    const result = await notifier.sendOtp({
      abhaAddress: init.abhaAddress,
      mobile: "", // production notifier resolves the mobile from the patient record
      linkRefNumber: linkReferenceNumber,
      token,
      expiresAt,
    });
    notifierOk = result.ok;
    if (!result.ok && result.code) notifierErrorCode = result.code;
    if (!result.ok && result.error) notifierErrorMessage = result.error;
  } else {
    notifierErrorCode = "ABDM_M2_OTP_PROVIDER_NOT_CONFIGURED";
    notifierErrorMessage =
      "No link OTP provider is configured for this hospital";
  }

  if (!notifierOk) {
    return {
      ackStatus: 200,
      status: "link_init_otp_failed",
      errorCode: notifierErrorCode,
      errorMessage: notifierErrorMessage,
      linkInitRecord: persistRecord,
      outbound: {
        path: V3_M2_ON_INIT_PATH,
        body: buildOnInitErrorBody({
          transactionId: init.transactionId,
          requestId,
          code: notifierErrorCode ?? M2_ERROR_CODES.OTP_SEND_FAILED,
          message: notifierErrorMessage,
        }),
      },
    };
  }

  return {
    ackStatus: 200,
    status: "link_init_sent",
    errorCode: null,
    errorMessage: null,
    linkInitRecord: persistRecord,
    outbound: {
      path: V3_M2_ON_INIT_PATH,
      body: buildOnInitBody({
        transactionId: init.transactionId,
        requestId,
        linkReferenceNumber,
        authenticationType: "MEDIATE",
        communicationMedium: "MOBILE",
        communicationHint: "XXXXXX0000",
        communicationExpiry: expiresAt,
      }),
    },
  };
}

async function processM2LinkConfirm(
  body: Record<string, unknown>,
  requestId: string,
  runtime: M2ProcessRuntime,
): Promise<M2ProcessResult> {
  const validation = validateM2LinkConfirmRequest(body);
  if (!validation.ok || !validation.value) {
    processError(400, M2_ERROR_CODES.INVALID_REQUEST, validation.errors.join("; "));
  }
  const confirm = validation.value;

  const record = await runtime.linkInitStore.findLinkInitByLinkRef(
    confirm.linkRefNumber,
  );
  if (!record) {
    return {
      ackStatus: 200,
      status: "link_confirm_error",
      errorCode: M2_ERROR_CODES.LINK_REQUEST_UNKNOWN,
      errorMessage: "Link request not found",
      outbound: {
        path: V3_M2_ON_CONFIRM_PATH,
        body: buildOnConfirmErrorBody({
          requestId,
          code: M2_ERROR_CODES.LINK_REQUEST_UNKNOWN,
          message: "Link request not found",
        }),
      },
    };
  }

  const tokenHash = await sha256Hex(confirm.token);
  if (tokenHash !== record.token_hash) {
    return {
      ackStatus: 200,
      status: "link_confirm_error",
      errorCode: M2_ERROR_CODES.INVALID_TOKEN,
      errorMessage: "Incorrect OTP",
      outbound: {
        path: V3_M2_ON_CONFIRM_PATH,
        body: buildOnConfirmErrorBody({
          requestId,
          code: M2_ERROR_CODES.INVALID_TOKEN,
          message: "Incorrect OTP",
        }),
      },
    };
  }

  const expiresAt = record.expires_at ? Date.parse(record.expires_at) : NaN;
  if (Number.isFinite(expiresAt) && expiresAt <= Date.now()) {
    return {
      ackStatus: 200,
      status: "link_confirm_error",
      errorCode: M2_ERROR_CODES.LINK_REQUEST_UNKNOWN,
      errorMessage: "Link request expired",
      outbound: {
        path: V3_M2_ON_CONFIRM_PATH,
        body: buildOnConfirmErrorBody({
          requestId,
          code: M2_ERROR_CODES.LINK_REQUEST_UNKNOWN,
          message: "Link request expired",
        }),
      },
    };
  }

  const abhaId = record.abha_address ?? "";
  await runtime.careContextStore.markLinked(
    abhaId,
    record.care_context_refs,
    runtime.hospital.hospitalId,
  );

  const linked = await runtime.careContextStore.findForReferences(
    abhaId,
    record.care_context_refs,
    runtime.hospital.hospitalId,
  );
  const patient = groupCareContextsByHiType(
    abhaId,
    abhaId,
    linked.map((context) => ({
      ...context,
      hiType: context.hiType || "HealthDocumentRecord",
    })),
  );

  return {
    ackStatus: 200,
    status: "link_confirmed",
    errorCode: null,
    errorMessage: null,
    outbound: {
      path: V3_M2_ON_CONFIRM_PATH,
      body: buildOnConfirmBody({ requestId, patient }),
    },
  };
}

async function processM2ConsentNotify(
  body: Record<string, unknown>,
  requestId: string,
  runtime: M2ProcessRuntime,
): Promise<M2ProcessResult> {
  const validation = validateM2ConsentNotification(body);
  if (!validation.ok || !validation.value) {
    processError(400, M2_ERROR_CODES.INVALID_REQUEST, validation.errors.join("; "));
  }
  const notification = validation.value;

  const upsertResult = await runtime.consentStore.upsert({
    hospital_id: runtime.hospital.hospitalId,
    patient_id: null,
    abha_id: notification.patientId ?? "",
    consent_id: notification.consentId,
    hip_id: notification.hipId ?? runtime.hospital.facilityId,
    hiu_id: notification.hiuId,
    purpose: notification.purposeText,
    data_from: notification.dataFrom,
    data_to: notification.dataTo,
    status: notification.status.toLowerCase(),
    granted_at: notification.status.toUpperCase() === "REVOKED"
      ? null
      : notification.timestamp || null,
    expires_at: notification.dataEraseAt,
    care_context_references: notification.careContextRefs,
    hi_types: notification.hiTypes,
  });

  if (upsertResult.error) {
    return {
      ackStatus: 202,
      status: "consent_notify_error",
      errorCode: M2_ERROR_CODES.CONSENT_INVALID,
      errorMessage: "Consent artefact could not be persisted",
      outbound: {
        path: V3_M2_CONSENT_ON_NOTIFY_PATH,
        body: buildConsentOnNotifyErrorBody({
          requestId,
          code: M2_ERROR_CODES.CONSENT_INVALID,
          message: "Consent artefact could not be persisted",
        }),
      },
    };
  }

  return {
    ackStatus: 202,
    status: "consent_notify_ack",
    errorCode: null,
    errorMessage: null,
    outbound: {
      path: V3_M2_CONSENT_ON_NOTIFY_PATH,
      body: buildConsentOnNotifyBody({
        requestId,
        status: "OK",
        consentId: notification.consentId,
      }),
    },
  };
}

async function processM2HealthInformationRequest(
  body: Record<string, unknown>,
  requestId: string,
  runtime: M2ProcessRuntime,
): Promise<M2ProcessResult> {
  const validation = validateM2HealthInformationRequest(body);
  if (!validation.ok || !validation.value) {
    processError(400, M2_ERROR_CODES.INVALID_REQUEST, validation.errors.join("; "));
  }
  const request = validation.value;

  const consent = await runtime.consentStore.findByConsentId(request.consentId);
  const consentCheck = consentIsUsable(consent);
  if (!consentCheck.usable) {
    return {
      ackStatus: 202,
      status: "health_information_consent_invalid",
      errorCode: consentCheck.code ?? M2_ERROR_CODES.CONSENT_INVALID,
      errorMessage: consentCheck.error ?? "Consent is not valid",
      outbound: {
        path: V3_M2_HEALTH_INFORMATION_ON_REQUEST_PATH,
        body: buildHealthInformationOnRequestErrorBody({
          requestId,
          code: consentCheck.code ?? M2_ERROR_CODES.CONSENT_INVALID,
          message: consentCheck.error ?? "Consent is not valid",
        }),
      },
    };
  }

  const careContextRefs = consent!.care_context_references ?? [];
  const fhirSource = await runtime.fetchFhirSource(
    consent!.abha_id,
    careContextRefs,
    runtime.hospital.hospitalId,
  );

  // Fail-closed consent validation: refs, time window and HI types must all
  // be satisfied before any FHIR bundle is accepted for transfer.
  const careContextHiTypes = fhirSource?.careContexts.map((c) =>
    c.recordType ? hiTypeForRecordType(c.recordType) : "HealthDocumentRecord"
  ) ?? [];
  const transferConsentCheck = validateConsentForTransfer({
    consent: consent!,
    careContextRefs,
    careContextHiTypes,
    now: new Date(),
  });

  let fhirBundle: Record<string, unknown> | null = null;
  let jobStatus: string = M2_JOB_STATUS.BLOCKED_SAFE;
  let jobErrorCode: string | null = null;
  let jobErrorMessage: string | null = null;

  if (!transferConsentCheck.ok) {
    jobErrorCode = transferConsentCheck.code ?? M2_ERROR_CODES.CONSENT_INVALID;
    jobErrorMessage = transferConsentCheck.error ?? "Consent is not valid";
  } else if (!fhirSource) {
    jobStatus = M2_JOB_STATUS.FAILED_SAFE;
    jobErrorCode = M2_ERROR_CODES.SOURCE_DATA_ABSENT;
    jobErrorMessage = "Mandatory source data is absent for the consent care contexts";
  } else {
    const bundleResult = buildFhirBundleFromSource(fhirSource);
    if (!bundleResult.ok || !bundleResult.bundle) {
      jobStatus = M2_JOB_STATUS.FAILED_SAFE;
      jobErrorCode = M2_ERROR_CODES.SOURCE_DATA_ABSENT;
      jobErrorMessage = bundleResult.error ?? "Mandatory source data is absent";
    } else {
      fhirBundle = bundleResult.bundle;
      if (
        !runtime.dataTransferEnabled || runtime.encryptor?.available !== true
      ) {
        jobStatus = M2_JOB_STATUS.BLOCKED_SAFE;
        jobErrorCode = M2_ERROR_CODES.TRANSFER_GATED;
        jobErrorMessage =
          "Live health-information transfer is gated until HIP linkage, valid consent and encryption prerequisites are satisfied";
      } else {
        jobStatus = M2_JOB_STATUS.QUEUED;
      }
    }
  }

  const job = buildDataTransferJob({
    hospitalId: runtime.hospital.hospitalId,
    consentId: request.consentId,
    transactionId: request.transactionId,
    careContextRefs,
    careContextHiTypes,
    fhirBundle,
    keyMaterial: {
      cryptoAlg: request.keyMaterial.cryptoAlg,
      curve: request.keyMaterial.curve,
      dhPublicKey: request.keyMaterial.dhPublicKey,
      nonce: request.keyMaterial.nonce,
    },
    dataPushUrl: request.dataPushUrl,
    status: jobStatus,
    errorCode: jobErrorCode,
    errorMessage: jobErrorMessage,
  });
  const jobUpsert = await runtime.dataTransferJobStore.upsert(job);
  if (jobUpsert.error) {
    return {
      ackStatus: 202,
      status: "health_information_ack",
      errorCode: M2_ERROR_CODES.INVALID_REQUEST,
      errorMessage: "Data-transfer job could not be persisted",
      outbound: {
        path: V3_M2_HEALTH_INFORMATION_ON_REQUEST_PATH,
        body: buildHealthInformationOnRequestBody({
          requestId,
          transactionId: request.transactionId,
          sessionStatus: "ACKNOWLEDGED",
        }),
      },
    };
  }

  return {
    ackStatus: 202,
    status: "health_information_ack",
    errorCode: null,
    errorMessage: null,
    outbound: {
      path: V3_M2_HEALTH_INFORMATION_ON_REQUEST_PATH,
      body: buildHealthInformationOnRequestBody({
        requestId,
        transactionId: request.transactionId,
        sessionStatus: "ACKNOWLEDGED",
      }),
    },
    // Live execution starts only for genuinely queued jobs.
    ...(jobStatus === M2_JOB_STATUS.QUEUED ? { transferJob: job } : {}),
  };
}
