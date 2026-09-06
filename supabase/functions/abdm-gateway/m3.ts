// ============================================================================
// ABDM V3 M3 (HIU) — official contract constants, validators, builders, stores
// and the inbound data-push processing pipeline.
// ----------------------------------------------------------------------------
// CONTRACT SOURCE (reviewed 2026-09-06)
//   NHA official ABDM-wrapper v3 source (github.com/NHA-ABDM/ABDM-wrapper):
//   - application-v3.properties
//       consentInitPath                 = /consent/v3/request/init
//       consentStatusPath               = /consent/v3/request/status
//       consentHiuOnNotifyPath          = /consent/v3/request/hiu/on-notify
//       fetchConsentPath                = /consent/v3/fetch
//       healthInformationConsentManagerPath =
//           /data-flow/v3/health-information/request
//       healthInformationPushNotificationPath =
//           /data-flow/v3/health-information/notify
//       gatewayBaseUrl                  = https://dev.abdm.gov.in/api/hiecm
//   - v3/common/constants/GatewayURL.java (inbound HIU callback paths)
//   - v3/hiu/hrp/consent/HIUConsentV3Service.java + callbacks
//   - v3/hiu/hrp/dataTransfer/HIUV3HealthInformationService.java +
//     HIUV3FacadeHealthInformationService.java + callbacks
//   - v1/hiu/hrp/dataTransfer/DecryptionManager.java (crypto contract, STOPPED)
//
// The canonical V3 session/token/header primitives are imported from core.ts;
// the key-material validator is reused from m2_transfer.ts (identical official
// keyMaterial schema for HIP and HIU transfers).
//
// SECURITY
//   * No access tokens, private keys, encrypted payloads or decrypted FHIR are
//     ever logged or returned through the public API.
//   * Production decryption is STOPPED: the official BouncyCastle ECDH
//     curve25519 contract does not match RFC 7748 X25519 (see m2_transfer.ts
//     and the M3 decryptor below).
// ============================================================================

import {
  type FetchImpl,
  type GatewayConfig,
  type GatewayHttpResponse,
  type V3SessionRequestOptions,
  type V3TokenCacheRef,
  v3GatewayPost,
  freshV3RequestId,
  freshV3Timestamp,
  isValidAbhaAddress,
  isValidAbhaNumber,
} from "./core.ts";
import { validateM2KeyMaterial } from "./m2_transfer.ts";
import type { M2Hospital } from "./m2.ts";

// ----------------------------------------------------------------------------
// Official V3 M3 gateway paths (HIU -> ABDM gateway)
// ----------------------------------------------------------------------------

/** HIU -> Gateway: initiate a consent request. */
export const V3_M3_CONSENT_INIT_PATH = "/api/hiecm/consent/v3/request/init";
/** HIU -> Gateway: poll the status of a consent request. */
export const V3_M3_CONSENT_STATUS_PATH = "/api/hiecm/consent/v3/request/status";
/** HIU -> Gateway: acknowledge a consent notification. */
export const V3_M3_CONSENT_HIU_ON_NOTIFY_PATH =
  "/api/hiecm/consent/v3/request/hiu/on-notify";
/** HIU -> Gateway: fetch a consent artefact by consent id. */
export const V3_M3_CONSENT_FETCH_PATH = "/api/hiecm/consent/v3/fetch";
/** HIU -> Gateway: request encrypted health information from a HIP. */
export const V3_M3_HEALTH_INFORMATION_REQUEST_PATH =
  "/api/hiecm/data-flow/v3/health-information/request";
/** HIU -> Gateway: final health-information transfer status notification. */
export const V3_M3_HEALTH_INFORMATION_NOTIFY_PATH =
  "/api/hiecm/data-flow/v3/health-information/notify";

// ----------------------------------------------------------------------------
// Official V3 M3 inbound callback paths (ABDM gateway -> HIU bridge)
// ----------------------------------------------------------------------------

export const V3_M3_CB_CONSENT_ON_INIT =
  "/api/v3/hiu/consent/request/on-init";
export const V3_M3_CB_CONSENT_ON_STATUS =
  "/api/v3/hiu/consent/request/on-status";
export const V3_M3_CB_CONSENT_NOTIFY =
  "/api/v3/hiu/consent/request/notify";
export const V3_M3_CB_CONSENT_ON_FETCH = "/api/v3/hiu/consent/on-fetch";
export const V3_M3_CB_HEALTH_INFORMATION_ON_REQUEST =
  "/api/v3/hiu/health-information/on-request";

/**
 * HIP -> HIU encrypted data push. This is the HIU's OWN dataPushUrl subpath
 * (the value sent to the gateway inside the health-information request). The
 * official wrapper exposes its HIU transfer controller on `/v3/transfer`; this
 * deployment mirrors that convention under the gateway function URL.
 */
export const V3_M3_DATA_PUSH_PATH =
  "/api/v3/hiu/health-information/transfer";

/** Official service-id header for HIU outbound gateway requests. */
export const V3_M3_HIU_ID_HEADER = "X-HIU-ID";

// ----------------------------------------------------------------------------
// Official HI type enum (sample-hiu generated OpenAPI / wrapper HiTypeEnum)
// ----------------------------------------------------------------------------

export const V3_M3_HI_TYPES: ReadonlySet<string> = new Set([
  "OPConsultation",
  "Prescription",
  "DischargeSummary",
  "DiagnosticReport",
  "ImmunizationRecord",
  "HealthDocumentRecord",
  "WellnessRecord",
]);

/** True when `value` is one of the official V3 HI types. */
export function isOfficialM3HiType(value: string): boolean {
  return V3_M3_HI_TYPES.has(value.trim());
}

/** Official frequency units accepted by the consent permission. */
const M3_FREQUENCY_UNITS: ReadonlySet<string> = new Set([
  "HOUR",
  "DAY",
  "WEEK",
  "MONTH",
  "YEAR",
]);

// ----------------------------------------------------------------------------
// Callback type mapping (inbound ABDM gateway -> HIU)
// ----------------------------------------------------------------------------

export type M3CallbackType =
  | "consentOnInit"
  | "consentOnStatus"
  | "consentNotify"
  | "consentOnFetch"
  | "healthInformationOnRequest";

const M3_CALLBACK_TYPE_BY_PATH: Readonly<Record<string, M3CallbackType>> = {
  [V3_M3_CB_CONSENT_ON_INIT.toLowerCase()]: "consentOnInit",
  [V3_M3_CB_CONSENT_ON_STATUS.toLowerCase()]: "consentOnStatus",
  [V3_M3_CB_CONSENT_NOTIFY.toLowerCase()]: "consentNotify",
  [V3_M3_CB_CONSENT_ON_FETCH.toLowerCase()]: "consentOnFetch",
  [V3_M3_CB_HEALTH_INFORMATION_ON_REQUEST.toLowerCase()]:
    "healthInformationOnRequest",
};

/** Maps an inbound subpath to its canonical V3 M3 callback type (or null). */
export function m3CallbackTypeForSubpath(
  subpath: string,
): M3CallbackType | null {
  const path = subpath.toLowerCase().replace(/\/+$/, "");
  return M3_CALLBACK_TYPE_BY_PATH[path] ?? null;
}

/** True when the subpath is the HIU encrypted data-push endpoint. */
export function isM3DataPushSubpath(subpath: string): boolean {
  return subpath.toLowerCase().replace(/\/+$/, "") ===
    V3_M3_DATA_PUSH_PATH.toLowerCase();
}

// ----------------------------------------------------------------------------
// Error codes + lifecycle constants
// ----------------------------------------------------------------------------

export const M3_ERROR_CODES = {
  INVALID_REQUEST: "ABDM_M3_INVALID_REQUEST",
  HIU_NOT_CONFIGURED: "ABDM_M3_HIU_NOT_CONFIGURED",
  HIU_NOT_FOUND: "ABDM_M3_HIU_NOT_FOUND",
  HIU_LINKAGE_MISSING: "ABDM_M3_HIU_LINKAGE_MISSING",
  PATIENT_NOT_FOUND: "ABDM_M3_PATIENT_NOT_FOUND",
  CONSENT_INVALID: "ABDM_M3_CONSENT_INVALID",
  CONSENT_EXPIRED: "ABDM_M3_CONSENT_EXPIRED",
  CONSENT_REQUEST_UNKNOWN: "ABDM_M3_CONSENT_REQUEST_UNKNOWN",
  CONSENT_REQUEST_DUPLICATE: "ABDM_M3_CONSENT_REQUEST_DUPLICATE",
  TRANSACTION_UNKNOWN: "ABDM_M3_TRANSACTION_UNKNOWN",
  TRANSACTION_HOSPITAL_MISMATCH: "ABDM_M3_TRANSACTION_HOSPITAL_MISMATCH",
  DATA_IMPORT_GATED: "ABDM_M3_DATA_IMPORT_GATED",
  KEYPAIR_UNAVAILABLE: "ABDM_M3_KEYPAIR_UNAVAILABLE",
  PRIVATE_KEY_STORE_UNAVAILABLE: "ABDM_M3_PRIVATE_KEY_STORE_UNAVAILABLE",
  DECRYPTION_UNAVAILABLE: "ABDM_M3_DECRYPTION_UNAVAILABLE",
  FHIR_INVALID: "ABDM_M3_FHIR_INVALID",
  RATE_LIMITED: "ABDM_M3_RATE_LIMITED",
  INTERNAL: "ABDM_M3_INTERNAL",
} as const;

/** Normalized outgoing consent-request lifecycle. */
export const M3_CONSENT_REQUEST_STATUS = {
  CREATED: "created",
  SUBMITTED: "submitted",
  PENDING: "pending",
  GRANTED: "granted",
  DENIED: "denied",
  EXPIRED: "expired",
  REVOKED: "revoked",
  FAILED: "failed",
} as const;
export type M3ConsentRequestStatus =
  typeof M3_CONSENT_REQUEST_STATUS[keyof typeof M3_CONSENT_REQUEST_STATUS];

/** HIU health-information transfer lifecycle. */
export const M3_HI_REQUEST_STATUS = {
  REQUEST_CREATED: "request_created",
  REQUEST_SUBMITTED: "request_submitted",
  WAITING_FOR_DATA: "waiting_for_data",
  RECEIVING: "receiving",
  ALL_PAGES_RECEIVED: "all_pages_received",
  DECRYPTING: "decrypting",
  VALIDATING: "validating",
  PERSISTED: "persisted",
  COMPLETED: "completed",
  RETRYABLE_FAILURE: "retryable_failure",
  FAILED_SAFE: "failed_safe",
  EXPIRED: "expired",
  CANCELLED: "cancelled",
} as const;
export type M3HiRequestStatus =
  typeof M3_HI_REQUEST_STATUS[keyof typeof M3_HI_REQUEST_STATUS];

export const M3_PAGE_STATUS = {
  RECEIVED: "received",
  DUPLICATE: "duplicate",
  PROCESSING: "processing",
  PROCESSED: "processed",
  FAILED_SAFE: "failed_safe",
} as const;
export type M3PageStatus = typeof M3_PAGE_STATUS[keyof typeof M3_PAGE_STATUS];

// ----------------------------------------------------------------------------
// Persistence row + store contracts (implemented by index.ts, faked in tests)
// ----------------------------------------------------------------------------

export interface M3ConsentRequestRow {
  hospital_id: string | null;
  patient_id: string | null;
  request_id: string;
  consent_request_id: string | null;
  abha_address: string;
  status: M3ConsentRequestStatus;
  purpose_text: string | null;
  purpose_code: string | null;
  hi_types: string[];
  date_from: string | null;
  date_to: string | null;
  data_erase_at: string | null;
  frequency: Record<string, unknown>;
  hip_id: string | null;
  hiu_id: string | null;
  error_code: string | null;
  error_message: string | null;
  submitted_at: string | null;
  responded_at: string | null;
}

export type M3InsertResult = "inserted" | "duplicate";

export interface M3ConsentRequestStore {
  insert(row: M3ConsentRequestRow): Promise<M3InsertResult>;
  updateByRequestId(
    requestId: string,
    patch: Partial<M3ConsentRequestRow>,
  ): Promise<void>;
  findByRequestId(requestId: string): Promise<M3ConsentRequestRow | null>;
  findByConsentRequestId(
    consentRequestId: string,
  ): Promise<M3ConsentRequestRow | null>;
}

/** Consent artefact persisted in the existing `consent_artefacts` table. */
export interface M3ConsentArtefactRow {
  hospital_id: string;
  patient_id: string | null;
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

export interface M3ConsentStore {
  upsert(
    row: M3ConsentArtefactRow,
  ): Promise<{ error: { code: string; message: string } | null }>;
  findByConsentId(consentId: string): Promise<M3ConsentArtefactRow | null>;
}

export interface M3HiRequestRow {
  hospital_id: string | null;
  patient_id: string | null;
  consent_id: string;
  request_id: string;
  transaction_id: string | null;
  hip_id: string | null;
  hiu_id: string | null;
  status: M3HiRequestStatus;
  requested_from: string | null;
  requested_to: string | null;
  hi_types: string[];
  care_context_references: string[];
  /** Public key-material only (dhPublicKey + nonce). NEVER a private key. */
  key_material: Record<string, unknown>;
  expected_pages: number | null;
  received_pages: number;
  error_code: string | null;
  error_message: string | null;
  submitted_at: string | null;
  completed_at: string | null;
}

export interface M3HiRequestStore {
  insert(row: M3HiRequestRow): Promise<M3InsertResult>;
  updateByRequestId(
    requestId: string,
    patch: Partial<M3HiRequestRow>,
  ): Promise<void>;
  updateByTransactionId(
    transactionId: string,
    patch: Partial<M3HiRequestRow>,
  ): Promise<void>;
  findByRequestId(requestId: string): Promise<M3HiRequestRow | null>;
  findByTransactionId(
    transactionId: string,
  ): Promise<M3HiRequestRow | null>;
}

export interface M3HealthInformationEntry {
  content: string;
  media: string;
  checksum: string | null;
  careContextReference: string;
}

export interface M3DataPageRow {
  hospital_id: string | null;
  transaction_id: string;
  page_number: number;
  page_count: number;
  status: M3PageStatus;
  entry_count: number;
  entries: M3HealthInformationEntry[];
  key_material: Record<string, unknown>;
  checksum_metadata: Record<string, unknown>[];
  received_at: string;
  processing_status: string | null;
  error_code: string | null;
  error_message: string | null;
}

export interface M3DataPageStore {
  insertPage(row: M3DataPageRow): Promise<M3InsertResult>;
  listByTransactionId(transactionId: string): Promise<M3DataPageRow[]>;
  markProcessing(transactionId: string, pageNumber: number): Promise<void>;
  markProcessed(
    transactionId: string,
    pageNumber: number,
    status: M3PageStatus,
    errorCode?: string | null,
    errorMessage?: string | null,
  ): Promise<void>;
}

export interface M3ImportedFhirRecord {
  hospital_id: string;
  patient_id: string;
  abha_id: string;
  consent_id: string;
  transaction_id: string;
  care_context_reference: string;
  hi_type: string;
  resource_type: string;
  record_id: string;
  source_hip_id: string | null;
  fhir_resource: Record<string, unknown>;
  received_at: string;
  checksum: string | null;
  verification_status: "verified" | "unverified";
}

export interface M3FhirRecordStore {
  insertImported(record: M3ImportedFhirRecord): Promise<M3InsertResult | "error">;
}

// ----------------------------------------------------------------------------
// HIU keypair lifecycle + decryption abstractions
// ----------------------------------------------------------------------------

export interface M3KeypairResult {
  ok: boolean;
  code?: string;
  error?: string;
  privateKeyBase64?: string;
  publicKeyBase64?: string;
  nonceBase64?: string;
  parameters?: string;
}

export interface M3KeypairProvider {
  /** False while live crypto is unverified (production default). */
  readonly available: boolean;
  generate(): Promise<M3KeypairResult>;
}

export interface M3StoredKeyMaterial {
  privateKeyBase64: string;
  nonceBase64: string;
  expiresAt: string;
}

export interface M3PrivateKeyStore {
  /**
   * False when no server-side protected mechanism is configured. Production
   * returns false so private keys are never written to plaintext storage.
   */
  readonly available: boolean;
  save(
    transactionId: string,
    privateKeyBase64: string,
    nonceBase64: string,
    expiresAtIso: string,
  ): Promise<{ ok: boolean; code?: string; error?: string }>;
  get(transactionId: string): Promise<M3StoredKeyMaterial | null>;
  delete(transactionId: string): Promise<void>;
}

export interface M3DecryptionInput {
  encryptedContent: string;
  receiverPrivateKey: string;
  receiverNonce: string;
  senderKeyMaterial: {
    cryptoAlg: string;
    curve: string;
    dhPublicKey: { expiry: string | null; parameters: string | null; keyValue: string };
    nonce: string | null;
  };
  transactionContext: string;
}

export interface M3DecryptionResult {
  ok: boolean;
  code?: string;
  error?: string;
  plaintext?: string;
}

export interface M3Decryptor {
  readonly available: boolean;
  decrypt(input: M3DecryptionInput): Promise<M3DecryptionResult>;
}

// ----------------------------------------------------------------------------
// Key-material validation (reuses the official M2 validator — identical schema)
// ----------------------------------------------------------------------------

export interface M3KeyMaterialValidation {
  ok: boolean;
  code?: string;
  error?: string;
}

export function validateM3KeyMaterial(
  keyMaterial: M3DecryptionInput["senderKeyMaterial"] | undefined,
): M3KeyMaterialValidation {
  if (!keyMaterial || typeof keyMaterial !== "object") {
    return {
      ok: false,
      code: M3_ERROR_CODES.DECRYPTION_UNAVAILABLE,
      error: "keyMaterial is missing",
    };
  }
  const result = validateM2KeyMaterial(keyMaterial);
  if (result.ok) return { ok: true };
  return {
    ok: false,
    code: result.code ?? M3_ERROR_CODES.DECRYPTION_UNAVAILABLE,
    error: result.error ?? "Invalid key material",
  };
}

// ----------------------------------------------------------------------------
// Consent request input validation + official body builders
// ----------------------------------------------------------------------------

export interface M3ConsentRequestInput {
  hospitalId: string;
  patientId: string;
  abhaAddress: string;
  purposeText: string;
  purposeCode: string;
  purposeRefUri: string;
  hiTypes: string[];
  dateFrom: string;
  dateTo: string;
  dataEraseAt: string;
  accessMode: string;
  frequencyUnit: string;
  frequencyValue: number;
  frequencyRepeats: number;
  hipId: string | null;
  careContexts: Array<{
    patientReference: string;
    careContextReference: string;
  }>;
  requesterName: string;
  requesterIdentifierType: string;
  requesterIdentifierValue: string;
  requesterIdentifierSystem: string;
}

function m3Text(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function isValidIsoDate(value: string): boolean {
  if (!value) return false;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed);
}

export function validateM3ConsentRequestInput(
  input: M3ConsentRequestInput,
  allowedAbhaSuffixes: readonly string[],
): { ok: boolean; errors: string[] } {
  const errors: string[] = [];
  if (!input.hospitalId) errors.push("hospitalId is required");
  if (!input.patientId) errors.push("patientId is required");

  const abhaAddress = input.abhaAddress.trim();
  if (!abhaAddress) {
    errors.push("abhaAddress is required");
  } else if (
    !isValidAbhaAddress(abhaAddress, allowedAbhaSuffixes) &&
    !isValidAbhaNumber(abhaAddress)
  ) {
    errors.push(
      "abhaAddress must be a valid ABHA address (for example user@abdm or user@sbx)",
    );
  }

  if (!input.purposeText) errors.push("purpose.text is required");
  if (!input.purposeCode) errors.push("purpose.code is required");
  if (!input.purposeRefUri) errors.push("purpose.refUri is required");

  if (input.hiTypes.length === 0) {
    errors.push("hiTypes is required");
  } else {
    for (const hiType of input.hiTypes) {
      if (!isOfficialM3HiType(hiType)) {
        errors.push(`hiTypes contains an unsupported official HI type: ${hiType}`);
      }
    }
  }

  if (!isValidIsoDate(input.dateFrom)) errors.push("dateFrom must be a valid ISO-8601 date");
  if (!isValidIsoDate(input.dateTo)) errors.push("dateTo must be a valid ISO-8601 date");
  if (isValidIsoDate(input.dateFrom) && isValidIsoDate(input.dateTo)) {
    if (Date.parse(input.dateFrom) > Date.parse(input.dateTo)) {
      errors.push("dateFrom must not be after dateTo");
    }
  }
  if (!isValidIsoDate(input.dataEraseAt)) {
    errors.push("dataEraseAt must be a valid ISO-8601 date");
  } else if (isValidIsoDate(input.dateTo) && Date.parse(input.dataEraseAt) < Date.parse(input.dateTo)) {
    errors.push("dataEraseAt must not be before dateTo");
  }

  const accessMode = input.accessMode.trim().toUpperCase();
  if (accessMode !== "VIEW") {
    errors.push("accessMode must be VIEW");
  }

  const unit = input.frequencyUnit.trim().toUpperCase();
  if (!M3_FREQUENCY_UNITS.has(unit)) {
    errors.push(`frequency.unit must be one of ${[...M3_FREQUENCY_UNITS].join(", ")}`);
  }
  if (!Number.isInteger(input.frequencyValue) || input.frequencyValue < 1 || input.frequencyValue > 999) {
    errors.push("frequency.value must be an integer between 1 and 999");
  }
  if (!Number.isInteger(input.frequencyRepeats) || input.frequencyRepeats < 0 || input.frequencyRepeats > 999) {
    errors.push("frequency.repeats must be an integer between 0 and 999");
  }

  if (!input.requesterName) errors.push("requester.name is required");
  if (!input.requesterIdentifierType) errors.push("requester.identifier.type is required");
  if (!input.requesterIdentifierValue) errors.push("requester.identifier.value is required");
  if (!input.requesterIdentifierSystem) errors.push("requester.identifier.system is required");

  for (const context of input.careContexts) {
    if (!context.patientReference) {
      errors.push("careContexts[].patientReference is required");
      break;
    }
    if (!context.careContextReference) {
      errors.push("careContexts[].careContextReference is required");
      break;
    }
  }

  return { ok: errors.length === 0, errors };
}

/** Builds the official V3 consent-request init body (HIU -> gateway). */
export function buildM3ConsentInitBody(input: {
  requestId: string;
  timestamp: string;
  hiuId: string;
  abhaAddress: string;
  purposeText: string;
  purposeCode: string;
  purposeRefUri: string;
  hiTypes: string[];
  dateFrom: string;
  dateTo: string;
  dataEraseAt: string;
  accessMode: string;
  frequencyUnit: string;
  frequencyValue: number;
  frequencyRepeats: number;
  hipId: string | null;
  careContexts: Array<{
    patientReference: string;
    careContextReference: string;
  }>;
  requesterName: string;
  requesterIdentifierType: string;
  requesterIdentifierValue: string;
  requesterIdentifierSystem: string;
}): Record<string, unknown> {
  const consent: Record<string, unknown> = {
    purpose: {
      text: input.purposeText,
      code: input.purposeCode,
      refUri: input.purposeRefUri,
    },
    patient: { id: input.abhaAddress },
    hiu: { id: input.hiuId },
    requester: {
      name: input.requesterName,
      identifier: {
        type: input.requesterIdentifierType,
        value: input.requesterIdentifierValue,
        system: input.requesterIdentifierSystem,
      },
    },
    hiTypes: input.hiTypes,
    permission: {
      accessMode: input.accessMode,
      dateRange: { from: input.dateFrom, to: input.dateTo },
      dataEraseAt: input.dataEraseAt,
      frequency: {
        unit: input.frequencyUnit,
        value: input.frequencyValue,
        repeats: input.frequencyRepeats,
      },
    },
  };
  if (input.hipId) consent["hip"] = { id: input.hipId };
  if (input.careContexts.length > 0) consent["careContexts"] = input.careContexts;
  return {
    requestId: input.requestId,
    timestamp: input.timestamp,
    consent,
  };
}

/** Builds the official V3 consent-request status body. */
export function buildM3ConsentStatusBody(input: {
  requestId: string;
  timestamp: string;
  consentRequestId: string;
}): Record<string, unknown> {
  return {
    requestId: input.requestId,
    timestamp: input.timestamp,
    consentRequestId: input.consentRequestId,
  };
}

/** Builds the official V3 consent fetch body. */
export function buildM3ConsentFetchBody(input: {
  requestId: string;
  timestamp: string;
  consentId: string;
}): Record<string, unknown> {
  return {
    requestId: input.requestId,
    timestamp: input.timestamp,
    consentId: input.consentId,
  };
}

/** Builds the official V3 consent hiu/on-notify acknowledgement body. */
export function buildM3ConsentOnNotifyAckBody(input: {
  requestId: string;
  consentIds: string[];
}): Record<string, unknown> {
  return {
    acknowledgement: input.consentIds.map((consentId) => ({
      status: "OK",
      consentId,
    })),
    response: { requestId: input.requestId },
  };
}

// ----------------------------------------------------------------------------
// Health-information request builders + consent validation
// ----------------------------------------------------------------------------

export function buildM3HealthInformationRequestBody(input: {
  requestId: string;
  timestamp: string;
  consentId: string;
  dateFrom: string;
  dateTo: string;
  dataPushUrl: string;
  keyMaterial: Record<string, unknown>;
}): Record<string, unknown> {
  return {
    requestId: input.requestId,
    timestamp: input.timestamp,
    hiRequest: {
      consent: { id: input.consentId },
      dateRange: { from: input.dateFrom, to: input.dateTo },
      dataPushUrl: input.dataPushUrl,
      keyMaterial: input.keyMaterial,
    },
  };
}

export function buildM3HealthInformationNotifyBody(input: {
  requestId: string;
  timestamp: string;
  consentId: string;
  transactionId: string;
  doneAt: string;
  hiuId: string;
  hipId: string;
  sessionStatus: "TRANSFERRED" | "FAILED";
  statusResponses: Array<{
    careContextReference: string;
    hiStatus: "OK" | "ERRORED";
    description: string;
  }>;
}): Record<string, unknown> {
  return {
    requestId: input.requestId,
    timestamp: input.timestamp,
    notification: {
      consentId: input.consentId,
      transactionId: input.transactionId,
      doneAt: input.doneAt,
      notifier: { type: "HIU", id: input.hiuId },
      statusNotification: {
        sessionStatus: input.sessionStatus,
        hipId: input.hipId,
        statusResponses: input.statusResponses,
      },
    },
  };
}

function consentIsUsable(
  consent: M3ConsentArtefactRow | null,
  now: Date,
): { usable: boolean; code?: string; error?: string } {
  if (!consent) {
    return {
      usable: false,
      code: M3_ERROR_CODES.CONSENT_INVALID,
      error: "Consent artefact not found",
    };
  }
  const status = consent.status.toLowerCase();
  if (status !== "granted" && status !== "active") {
    return {
      usable: false,
      code: M3_ERROR_CODES.CONSENT_INVALID,
      error: `Consent is ${consent.status}`,
    };
  }
  const expiresAt = consent.expires_at ? Date.parse(consent.expires_at) : NaN;
  if (Number.isFinite(expiresAt) && expiresAt <= now.getTime()) {
    return {
      usable: false,
      code: M3_ERROR_CODES.CONSENT_EXPIRED,
      error: "Consent has expired",
    };
  }
  const to = consent.data_to ? Date.parse(consent.data_to) : NaN;
  if (Number.isFinite(to) && now.getTime() > to) {
    return {
      usable: false,
      code: M3_ERROR_CODES.CONSENT_EXPIRED,
      error: "Consent permission window has ended",
    };
  }
  return { usable: true };
}

/**
 * Fail-closed HIU-side consent validation before a health-information request
 * is sent to the gateway. The HIU id, patient, time window, HI types and care
 * contexts must all be authorized by the stored consent artefact.
 */
export function validateM3ConsentForRequest(input: {
  consent: M3ConsentArtefactRow;
  hiuId: string;
  hospitalId: string;
  hiTypes: string[];
  careContextRefs: string[];
  now: Date;
}): { ok: boolean; code?: string; error?: string } {
  const { consent, hiuId, hospitalId, hiTypes, careContextRefs, now } = input;

  if (consent.hospital_id !== hospitalId) {
    return {
      ok: false,
      code: M3_ERROR_CODES.CONSENT_INVALID,
      error: "Consent artefact belongs to a different hospital",
    };
  }
  if (consent.hiu_id && consent.hiu_id !== hiuId) {
    return {
      ok: false,
      code: M3_ERROR_CODES.CONSENT_INVALID,
      error: "Consent artefact does not belong to this HIU",
    };
  }
  const usable = consentIsUsable(consent, now);
  if (!usable.usable) return { ok: false, code: usable.code, error: usable.error };

  const from = consent.data_from ? Date.parse(consent.data_from) : NaN;
  if (Number.isFinite(from) && now.getTime() < from) {
    return {
      ok: false,
      code: M3_ERROR_CODES.CONSENT_INVALID,
      error: "Consent permission window has not started",
    };
  }

  if (hiTypes.length === 0) {
    return {
      ok: false,
      code: M3_ERROR_CODES.CONSENT_INVALID,
      error: "No HI types requested",
    };
  }
  if (consent.hi_types.length === 0) {
    return {
      ok: false,
      code: M3_ERROR_CODES.CONSENT_INVALID,
      error: "Consent artefact does not record HI types",
    };
  }
  const allowedHiTypes = new Set(consent.hi_types.map((t) => t.toUpperCase()));
  for (const hiType of hiTypes) {
    if (!allowedHiTypes.has(hiType.toUpperCase())) {
      return {
        ok: false,
        code: M3_ERROR_CODES.CONSENT_INVALID,
        error: `HI type ${hiType} is not covered by the consent`,
      };
    }
  }

  if (careContextRefs.length === 0) {
    return {
      ok: false,
      code: M3_ERROR_CODES.CONSENT_INVALID,
      error: "Consent has no care-context references",
    };
  }
  const allowedRefs = new Set(consent.care_context_references);
  for (const ref of careContextRefs) {
    if (!allowedRefs.has(ref)) {
      return {
        ok: false,
        code: M3_ERROR_CODES.CONSENT_INVALID,
        error: `Care-context reference ${ref} is not covered by the consent`,
      };
    }
  }

  return { ok: true };
}

// ----------------------------------------------------------------------------
// Inbound callback validators (ABDM gateway -> HIU)
// ----------------------------------------------------------------------------

function requireRecord(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function requireString(
  record: Record<string, unknown>,
  key: string,
  errors: string[],
  label: string,
): string {
  const value = m3Text(record[key]);
  if (!value) errors.push(`${label} is required`);
  return value;
}

function optionalString(
  record: Record<string, unknown>,
  key: string,
): string | null {
  const value = m3Text(record[key]);
  return value || null;
}

export interface M3ConsentOnInitData {
  responseRequestId: string;
  consentRequestId: string;
  errorMessage: string | null;
}

export function validateM3ConsentOnInit(
  body: Record<string, unknown>,
): { ok: boolean; errors: string[]; value?: M3ConsentOnInitData } {
  const errors: string[] = [];
  const response = requireRecord(body["response"]);
  const responseRequestId = requireString(response, "requestId", errors, "response.requestId");
  const consentRequest = requireRecord(body["consentRequest"]);
  const consentRequestId = requireString(consentRequest, "id", errors, "consentRequest.id");
  const error = requireRecord(body["error"]);
  const errorMessage = optionalString(error, "message");
  if (errors.length === 0) {
    return {
      ok: true,
      errors,
      value: { responseRequestId, consentRequestId, errorMessage },
    };
  }
  return { ok: false, errors };
}

export interface M3ConsentOnStatusData {
  responseRequestId: string;
  status: string;
  consentArtefacts: Array<{
    id: string;
    hipId: string | null;
    careContextReferences: string[];
  }>;
}

export function validateM3ConsentOnStatus(
  body: Record<string, unknown>,
): { ok: boolean; errors: string[]; value?: M3ConsentOnStatusData } {
  const errors: string[] = [];
  const response = requireRecord(body["response"]);
  const responseRequestId = requireString(response, "requestId", errors, "response.requestId");
  const consentRequest = requireRecord(body["consentRequest"]);
  const status = requireString(consentRequest, "status", errors, "consentRequest.status");
  const artefacts = Array.isArray(consentRequest["consentArtefacts"])
    ? consentRequest["consentArtefacts"] as unknown[]
    : [];
  const consentArtefacts = artefacts.map((entry) => {
    const record = requireRecord(entry);
    const careContexts = Array.isArray(record["careContextReference"])
      ? (record["careContextReference"] as unknown[]).map((v) => String(v))
      : [];
    return {
      id: m3Text(record["id"]),
      hipId: optionalString(record, "hipId"),
      careContextReferences: careContexts,
    };
  });
  if (errors.length === 0) {
    return {
      ok: true,
      errors,
      value: { responseRequestId, status, consentArtefacts },
    };
  }
  return { ok: false, errors };
}

export interface M3ConsentNotifyData {
  requestId: string;
  timestamp: string;
  consentRequestId: string;
  status: string;
  consentArtefacts: Array<{
    id: string;
    hipId: string | null;
    careContextReferences: string[];
  }>;
  errorMessage: string | null;
}

export function validateM3ConsentNotify(
  body: Record<string, unknown>,
): { ok: boolean; errors: string[]; value?: M3ConsentNotifyData } {
  const errors: string[] = [];
  const requestId = requireString(body, "requestId", errors, "requestId");
  const timestamp = requireString(body, "timestamp", errors, "timestamp");
  const notification = requireRecord(body["notification"]);
  const consentRequestId = requireString(
    notification,
    "consentRequestId",
    errors,
    "notification.consentRequestId",
  );
  const status = requireString(notification, "status", errors, "notification.status");
  const artefacts = Array.isArray(notification["consentArtefacts"])
    ? notification["consentArtefacts"] as unknown[]
    : [];
  const consentArtefacts = artefacts.map((entry) => {
    const record = requireRecord(entry);
    const careContexts = Array.isArray(record["careContextReference"])
      ? (record["careContextReference"] as unknown[]).map((v) => String(v))
      : [];
    return {
      id: m3Text(record["id"]),
      hipId: optionalString(record, "hipId"),
      careContextReferences: careContexts,
    };
  });
  const error = requireRecord(body["error"]);
  const errorMessage = optionalString(error, "message");
  if (errors.length === 0) {
    return {
      ok: true,
      errors,
      value: {
        requestId,
        timestamp,
        consentRequestId,
        status: status.toUpperCase(),
        consentArtefacts,
        errorMessage,
      },
    };
  }
  return { ok: false, errors };
}

export interface M3ConsentOnFetchData {
  responseRequestId: string;
  consentId: string;
  status: string;
  patientAbhaAddress: string;
  hipId: string | null;
  hiuId: string | null;
  purposeText: string | null;
  dataFrom: string | null;
  dataTo: string | null;
  dataEraseAt: string | null;
  hiTypes: string[];
  careContextReferences: string[];
}

export function validateM3ConsentOnFetch(
  body: Record<string, unknown>,
): { ok: boolean; errors: string[]; value?: M3ConsentOnFetchData } {
  const errors: string[] = [];
  const response = requireRecord(body["response"]);
  const responseRequestId = requireString(response, "requestId", errors, "response.requestId");
  const consent = requireRecord(body["consent"]);
  const detail = requireRecord(consent["consentDetail"]);
  const consentId = requireString(detail, "consentId", errors, "consent.consentDetail.consentId");
  const status = requireString(consent, "status", errors, "consent.status");
  const patient = requireRecord(detail["patient"]);
  const patientAbhaAddress = requireString(patient, "id", errors, "consent.consentDetail.patient.id");
  const hip = requireRecord(detail["hip"]);
  const hiu = requireRecord(detail["hiu"]);
  const purpose = requireRecord(detail["purpose"]);
  const permission = requireRecord(detail["permission"]);
  const dateRange = requireRecord(permission["dateRange"]);
  const careContexts = Array.isArray(detail["careContexts"])
    ? detail["careContexts"] as unknown[]
    : [];
  const careContextReferences = careContexts
    .map((entry) => {
      const record = requireRecord(entry);
      return optionalString(record, "careContextReference") ??
        optionalString(record, "referenceNumber") ?? "";
    })
    .filter(Boolean);
  const hiTypes = Array.isArray(detail["hiTypes"])
    ? (detail["hiTypes"] as unknown[]).map((v) => String(v))
    : [];
  if (errors.length === 0) {
    return {
      ok: true,
      errors,
      value: {
        responseRequestId,
        consentId,
        status: status.toUpperCase(),
        patientAbhaAddress,
        hipId: optionalString(hip, "id"),
        hiuId: optionalString(hiu, "id"),
        purposeText: optionalString(purpose, "text"),
        dataFrom: optionalString(dateRange, "from"),
        dataTo: optionalString(dateRange, "to"),
        dataEraseAt: optionalString(permission, "dataEraseAt"),
        hiTypes,
        careContextReferences,
      },
    };
  }
  return { ok: false, errors };
}

export interface M3HealthInformationOnRequestData {
  responseRequestId: string;
  transactionId: string;
  sessionStatus: string;
  errorMessage: string | null;
}

export function validateM3HealthInformationOnRequest(
  body: Record<string, unknown>,
): { ok: boolean; errors: string[]; value?: M3HealthInformationOnRequestData } {
  const errors: string[] = [];
  const response = requireRecord(body["response"]);
  const responseRequestId = requireString(response, "requestId", errors, "response.requestId");
  const hiRequest = requireRecord(body["hiRequest"]);
  const transactionId = requireString(hiRequest, "transactionId", errors, "hiRequest.transactionId");
  const sessionStatus = requireString(hiRequest, "sessionStatus", errors, "hiRequest.sessionStatus");
  const error = requireRecord(body["error"]);
  const errorMessage = optionalString(error, "message");
  if (errors.length === 0) {
    return {
      ok: true,
      errors,
      value: { responseRequestId, transactionId, sessionStatus, errorMessage },
    };
  }
  return { ok: false, errors };
}

// ----------------------------------------------------------------------------
// Encrypted data-push validation (HIP -> HIU)
// ----------------------------------------------------------------------------

export interface M3DataPushData {
  pageNumber: number;
  pageCount: number;
  transactionId: string;
  entries: M3HealthInformationEntry[];
  keyMaterial: M3DecryptionInput["senderKeyMaterial"];
}

export const M3_MAX_DATA_PUSH_PAGES = 100;
export const M3_MAX_ENTRY_CONTENT_BYTES = 512_000;
export const M3_ALLOWED_MEDIA = "application/fhir+json";

function isBase64(value: string): boolean {
  if (!value || value.length % 4 !== 0) return false;
  try {
    const bytes = Uint8Array.from(atob(value), (c) => c.charCodeAt(0));
    return bytes.byteLength > 0;
  } catch (_) {
    return false;
  }
}

export function validateM3DataPush(
  body: Record<string, unknown>,
): { ok: boolean; errors: string[]; value?: M3DataPushData } {
  const errors: string[] = [];
  const transactionId = requireString(body, "transactionId", errors, "transactionId");
  if (!Number.isInteger(body["pageNumber"])) {
    errors.push("pageNumber is required");
  }
  if (!Number.isInteger(body["pageCount"]) || Number(body["pageCount"]) < 1) {
    errors.push("pageCount must be a positive integer");
  }
  const pageNumber = Number(body["pageNumber"]);
  const pageCount = Number(body["pageCount"]);
  if (Number.isInteger(pageNumber) && Number.isInteger(pageCount)) {
    if (pageNumber < 0 || pageNumber >= pageCount) {
      errors.push("pageNumber must be between 0 and pageCount - 1");
    }
    if (pageCount > M3_MAX_DATA_PUSH_PAGES) {
      errors.push(`pageCount must not exceed ${M3_MAX_DATA_PUSH_PAGES}`);
    }
  }

  const entriesRaw = body["entries"];
  if (!Array.isArray(entriesRaw) || entriesRaw.length === 0) {
    errors.push("entries must be a non-empty array");
  }
  const entries: M3HealthInformationEntry[] = [];
  if (Array.isArray(entriesRaw)) {
    for (const entry of entriesRaw) {
      const record = requireRecord(entry);
      const content = requireString(record, "content", errors, "entries[].content");
      const media = requireString(record, "media", errors, "entries[].media");
      const checksum = optionalString(record, "checksum");
      const careContextReference = requireString(
        record,
        "careContextReference",
        errors,
        "entries[].careContextReference",
      );
      if (content && !isBase64(content)) {
        errors.push("entries[].content must be valid base64");
      }
      if (content && content.length > M3_MAX_ENTRY_CONTENT_BYTES) {
        errors.push(`entries[].content exceeds ${M3_MAX_ENTRY_CONTENT_BYTES} bytes`);
      }
      if (media && media !== M3_ALLOWED_MEDIA) {
        errors.push(`entries[].media must be ${M3_ALLOWED_MEDIA}`);
      }
      if (careContextReference && careContextReference.length > 255) {
        errors.push("entries[].careContextReference is too long");
      }
      if (content || media || checksum || careContextReference) {
        entries.push({ content, media, checksum, careContextReference });
      }
    }
  }

  const keyMaterial = requireRecord(body["keyMaterial"]) as unknown as
    M3DecryptionInput["senderKeyMaterial"];
  const keyCheck = validateM3KeyMaterial(
    Object.keys(keyMaterial).length > 0 ? keyMaterial : undefined,
  );
  if (!keyCheck.ok) {
    errors.push(keyCheck.error ?? "keyMaterial is invalid");
  }

  if (errors.length === 0) {
    return {
      ok: true,
      errors,
      value: { pageNumber, pageCount, transactionId, entries, keyMaterial },
    };
  }
  return { ok: false, errors };
}

// ----------------------------------------------------------------------------
// FHIR R4 validation (structural + care-context correlation)
// ----------------------------------------------------------------------------

const M3_ALLOWED_FHIR_RESOURCE_TYPES: ReadonlySet<string> = new Set([
  "Bundle",
  "Composition",
  "DiagnosticReport",
  "MedicationRequest",
  "DocumentReference",
  "Immunization",
  "Observation",
  "Encounter",
  "Procedure",
  "Condition",
  "AllergyIntolerance",
  "Patient",
  "Organization",
  "Practitioner",
]);

/** Maps an official HI type to the FHIR R4 resource type it authorizes. */
export function fhirResourceTypeForHiType(hiType: string): string {
  switch (hiType.toUpperCase()) {
    case "PRESCRIPTION":
      return "MedicationRequest";
    case "DISCHARGESUMMARY":
      return "DocumentReference";
    case "DIAGNOSTICREPORT":
      return "DiagnosticReport";
    case "OPCONSULTATION":
      return "Encounter";
    case "IMMUNIZATIONRECORD":
      return "Immunization";
    case "WELLNESSRECORD":
      return "Observation";
    case "HEALTHDOCUMENTRECORD":
      return "DocumentReference";
    default:
      return "DocumentReference";
  }
}

/** Maps a FHIR R4 resource type to the official HI type it represents. */
export function hiTypeForFhirResourceType(resourceType: string): string | null {
  switch (resourceType) {
    case "MedicationRequest":
      return "Prescription";
    case "DocumentReference":
      return "HealthDocumentRecord";
    case "DiagnosticReport":
      return "DiagnosticReport";
    case "Encounter":
      return "OPConsultation";
    case "Immunization":
      return "ImmunizationRecord";
    case "Observation":
      return "WellnessRecord";
    default:
      return null;
  }
}

export interface M3FhirValidation {
  ok: boolean;
  code?: string;
  error?: string;
  resourceType?: string;
  clinicalResources?: Array<{
    resourceType: string;
    resourceId: string;
  }>;
}

/** Validates a decrypted FHIR payload (Bundle or single Resource). */
export function validateM3FhirPayload(
  payload: unknown,
): M3FhirValidation {
  if (typeof payload !== "object" || payload === null || Array.isArray(payload)) {
    return {
      ok: false,
      code: M3_ERROR_CODES.FHIR_INVALID,
      error: "Decrypted payload is not a JSON object",
    };
  }
  const record = payload as Record<string, unknown>;
  const resourceType = m3Text(record["resourceType"]);
  if (!resourceType) {
    return {
      ok: false,
      code: M3_ERROR_CODES.FHIR_INVALID,
      error: "FHIR resourceType is missing",
    };
  }

  if (resourceType === "Bundle") {
    const entries = record["entry"];
    if (entries !== undefined && !Array.isArray(entries)) {
      return {
        ok: false,
        code: M3_ERROR_CODES.FHIR_INVALID,
        error: "FHIR Bundle.entry must be an array",
      };
    }
    const clinicalResources: Array<{ resourceType: string; resourceId: string }> = [];
    if (Array.isArray(entries)) {
      for (const entry of entries) {
        const entryRecord = requireRecord(entry);
        const resource = entryRecord["resource"];
        if (resource !== undefined) {
          const validation = validateM3FhirPayload(resource);
          if (!validation.ok) return validation;
          clinicalResources.push({
            resourceType: validation.resourceType!,
            resourceId: m3Text(requireRecord(resource)["id"]) || "",
          });
        }
      }
    }
    return {
      ok: true,
      resourceType: "Bundle",
      clinicalResources,
    };
  }

  if (!M3_ALLOWED_FHIR_RESOURCE_TYPES.has(resourceType)) {
    return {
      ok: false,
      code: M3_ERROR_CODES.FHIR_INVALID,
      error: `Unsupported FHIR resource type: ${resourceType}`,
    };
  }
  const resourceId = m3Text(record["id"]);
  if (!resourceId) {
    return {
      ok: false,
      code: M3_ERROR_CODES.FHIR_INVALID,
      error: `FHIR ${resourceType} resource id is missing`,
    };
  }
  return {
    ok: true,
    resourceType,
    clinicalResources: [{ resourceType, resourceId }],
  };
}

/** Extracts the FHIR resources to import from a validated payload. */
export function extractM3FhirResources(
  payload: Record<string, unknown>,
): Array<{ resourceType: string; resourceId: string; resource: Record<string, unknown> }> {
  const resourceType = m3Text(payload["resourceType"]);
  if (resourceType === "Bundle") {
    const entries = Array.isArray(payload["entry"]) ? payload["entry"] as unknown[] : [];
    return entries
      .map((entry) => requireRecord(entry)["resource"])
      .filter((resource): resource is Record<string, unknown> =>
        typeof resource === "object" && resource !== null && !Array.isArray(resource))
      .map((resource) => ({
        resourceType: m3Text(resource["resourceType"]),
        resourceId: m3Text(resource["id"]),
        resource,
      }))
      .filter((resource) => resource.resourceType && resource.resourceId);
  }
  return [{
    resourceType,
    resourceId: m3Text(payload["id"]),
    resource: payload,
  }];
}

// ----------------------------------------------------------------------------
// M3 processing runtime + pipeline entry points
// ----------------------------------------------------------------------------

export interface M3ProcessRuntime {
  fetchImpl: FetchImpl;
  config: GatewayConfig;
  v3TokenCache: V3TokenCacheRef;
  hospital: M2Hospital;
  consentRequestStore: M3ConsentRequestStore;
  consentStore: M3ConsentStore;
  hiRequestStore: M3HiRequestStore;
  dataPageStore: M3DataPageStore;
  fhirRecordStore: M3FhirRecordStore;
  keypairProvider: M3KeypairProvider | null;
  privateKeyStore: M3PrivateKeyStore | null;
  decryptor: M3Decryptor | null;
  /** True only when live M3 data import may run (default FALSE). */
  dataImportEnabled: boolean;
}

export class M3ProcessingError extends Error {
  readonly status: number;
  readonly code: string;

  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

/** Sanitized outbound gateway call produced by M3 processing. */
export interface M3OutboundCall {
  path: string;
  body: Record<string, unknown>;
}

export interface M3ProcessResult {
  /** HTTP status returned to the gateway/HIP for the inbound callback. */
  ackStatus: number;
  outbound: M3OutboundCall | null;
  status: string;
  errorCode: string | null;
  errorMessage: string | null;
}

export interface M3SubmitResult {
  ok: boolean;
  status: number;
  code?: string;
  error?: string;
  requestId?: string;
  consentRequestId?: string | null;
  requestStatus?: M3ConsentRequestStatus;
  upstreamStatus?: number | null;
}

export interface M3HiRequestResult {
  ok: boolean;
  status: number;
  code?: string;
  error?: string;
  requestId?: string;
  transactionId?: string | null;
  requestStatus?: M3HiRequestStatus;
  upstreamStatus?: number | null;
}

export interface M3ConsentStatusResult {
  ok: boolean;
  status: number;
  code?: string;
  error?: string;
  requestId?: string;
  requestStatus?: M3ConsentRequestStatus;
  upstreamStatus?: number | null;
}

function retryableStatus(status: number): boolean {
  return status === 408 || status === 425 || status === 429 || status >= 500;
}

/** Safe correlation id used for outbound request ids. */
export function freshM3RequestId(): string {
  return freshV3RequestId();
}

/** Safe current timestamp. */
export function freshM3Timestamp(): string {
  return freshV3Timestamp();
}

function sanitizeUpstreamError(message: string): string {
  const redacted = message
    .replace(/Bearer\s+[A-Za-z0-9._-]+/gi, "Bearer [redacted]")
    .replace(/client_secret=([^&\s]+)/gi, "client_secret=[redacted]");
  return redacted.length > 300 ? redacted.slice(0, 300) : redacted;
}

function m3Error(status: number, code: string, message: string): never {
  throw new M3ProcessingError(status, code, message);
}

// ----------------------------------------------------------------------------
// 1. Consent request submission (HIU -> gateway)
// ----------------------------------------------------------------------------

export async function submitM3ConsentRequest(
  runtime: M3ProcessRuntime,
  input: M3ConsentRequestInput,
): Promise<M3SubmitResult> {
  if (!runtime.config.hiuId) {
    return {
      ok: false,
      status: 501,
      code: M3_ERROR_CODES.HIU_NOT_CONFIGURED,
      error: "ABDM_HIU_ID is not configured",
    };
  }

  const requestId = freshM3RequestId();
  const body = buildM3ConsentInitBody({
    requestId,
    timestamp: freshM3Timestamp(),
    hiuId: runtime.config.hiuId,
    abhaAddress: input.abhaAddress,
    purposeText: input.purposeText,
    purposeCode: input.purposeCode,
    purposeRefUri: input.purposeRefUri,
    hiTypes: input.hiTypes,
    dateFrom: input.dateFrom,
    dateTo: input.dateTo,
    dataEraseAt: input.dataEraseAt,
    accessMode: input.accessMode,
    frequencyUnit: input.frequencyUnit,
    frequencyValue: input.frequencyValue,
    frequencyRepeats: input.frequencyRepeats,
    hipId: input.hipId,
    careContexts: input.careContexts,
    requesterName: input.requesterName,
    requesterIdentifierType: input.requesterIdentifierType,
    requesterIdentifierValue: input.requesterIdentifierValue,
    requesterIdentifierSystem: input.requesterIdentifierSystem,
  });

  const row: M3ConsentRequestRow = {
    hospital_id: input.hospitalId,
    patient_id: input.patientId,
    request_id: requestId,
    consent_request_id: null,
    abha_address: input.abhaAddress,
    status: M3_CONSENT_REQUEST_STATUS.CREATED,
    purpose_text: input.purposeText,
    purpose_code: input.purposeCode,
    hi_types: input.hiTypes,
    date_from: input.dateFrom,
    date_to: input.dateTo,
    data_erase_at: input.dataEraseAt,
    frequency: {
      unit: input.frequencyUnit,
      value: input.frequencyValue,
      repeats: input.frequencyRepeats,
    },
    hip_id: input.hipId,
    hiu_id: runtime.config.hiuId,
    error_code: null,
    error_message: null,
    submitted_at: null,
    responded_at: null,
  };

  const insertResult = await runtime.consentRequestStore.insert(row);
  if (insertResult === "duplicate") {
    const existing = await runtime.consentRequestStore.findByRequestId(requestId);
    return {
      ok: true,
      status: 200,
      requestId,
      consentRequestId: existing?.consent_request_id ?? null,
      requestStatus: existing?.status ?? M3_CONSENT_REQUEST_STATUS.CREATED,
    };
  }

  let response: GatewayHttpResponse;
  try {
    response = await v3GatewayPost(
      runtime.fetchImpl,
      runtime.config,
      runtime.v3TokenCache,
      V3_M3_HIU_ID_HEADER,
      runtime.config.hiuId,
      V3_M3_CONSENT_INIT_PATH,
      body,
    );
  } catch (error) {
    const message = sanitizeUpstreamError(
      error instanceof Error ? error.message : String(error),
    );
    await runtime.consentRequestStore.updateByRequestId(requestId, {
      status: M3_CONSENT_REQUEST_STATUS.FAILED,
      error_code: "ABDM_M3_CONSENT_UPSTREAM_FAILED",
      error_message: message,
      submitted_at: freshM3Timestamp(),
    });
    return {
      ok: false,
      status: 502,
      code: "ABDM_M3_CONSENT_UPSTREAM_FAILED",
      error: message,
      requestId,
      requestStatus: M3_CONSENT_REQUEST_STATUS.FAILED,
    };
  }

  if (!response.ok) {
    const code = `ABDM_M3_CONSENT_UPSTREAM_${response.status}`;
    const error = sanitizeUpstreamError(
      `ABDM consent request init returned HTTP ${response.status}`,
    );
    await runtime.consentRequestStore.updateByRequestId(requestId, {
      status: M3_CONSENT_REQUEST_STATUS.FAILED,
      error_code: code,
      error_message: error,
      submitted_at: freshM3Timestamp(),
    });
    return {
      ok: false,
      status: retryableStatus(response.status) ? 502 : 400,
      code,
      error,
      requestId,
      requestStatus: M3_CONSENT_REQUEST_STATUS.FAILED,
      upstreamStatus: response.status,
    };
  }

  await runtime.consentRequestStore.updateByRequestId(requestId, {
    status: M3_CONSENT_REQUEST_STATUS.SUBMITTED,
    error_code: null,
    error_message: null,
    submitted_at: freshM3Timestamp(),
  });

  return {
    ok: true,
    status: 200,
    requestId,
    consentRequestId: null,
    requestStatus: M3_CONSENT_REQUEST_STATUS.SUBMITTED,
    upstreamStatus: response.status,
  };
}

// ----------------------------------------------------------------------------
// 2. Consent status polling (HIU -> gateway)
// ----------------------------------------------------------------------------

export async function fetchM3ConsentStatus(
  runtime: M3ProcessRuntime,
  input: { hospitalId: string; requestId: string },
): Promise<M3ConsentStatusResult> {
  const row = await runtime.consentRequestStore.findByRequestId(input.requestId);
  if (!row || row.hospital_id !== input.hospitalId) {
    return {
      ok: false,
      status: 404,
      code: M3_ERROR_CODES.CONSENT_REQUEST_UNKNOWN,
      error: "Consent request not found for this hospital",
    };
  }

  // If the gateway has not returned a consent-request id yet, report the local
  // state without issuing an upstream status request.
  if (!row.consent_request_id) {
    return {
      ok: true,
      status: 200,
      requestId: row.request_id,
      requestStatus: row.status,
    };
  }

  const body = buildM3ConsentStatusBody({
    requestId: freshM3RequestId(),
    timestamp: freshM3Timestamp(),
    consentRequestId: row.consent_request_id,
  });

  let response: GatewayHttpResponse;
  try {
    response = await v3GatewayPost(
      runtime.fetchImpl,
      runtime.config,
      runtime.v3TokenCache,
      V3_M3_HIU_ID_HEADER,
      runtime.config.hiuId,
      V3_M3_CONSENT_STATUS_PATH,
      body,
    );
  } catch (error) {
    return {
      ok: false,
      status: 502,
      code: "ABDM_M3_CONSENT_STATUS_UPSTREAM_FAILED",
      error: sanitizeUpstreamError(
        error instanceof Error ? error.message : String(error),
      ),
      requestId: row.request_id,
      requestStatus: row.status,
    };
  }
  if (!response.ok) {
    return {
      ok: false,
      status: retryableStatus(response.status) ? 502 : 400,
      code: `ABDM_M3_CONSENT_STATUS_UPSTREAM_${response.status}`,
      error: sanitizeUpstreamError(
        `ABDM consent status returned HTTP ${response.status}`,
      ),
      requestId: row.request_id,
      requestStatus: row.status,
      upstreamStatus: response.status,
    };
  }

  await runtime.consentRequestStore.updateByRequestId(row.request_id, {
    status: M3_CONSENT_REQUEST_STATUS.PENDING,
  });

  return {
    ok: true,
    status: 200,
    requestId: row.request_id,
    requestStatus: M3_CONSENT_REQUEST_STATUS.PENDING,
    upstreamStatus: response.status,
  };
}

// ----------------------------------------------------------------------------
// 3. Health-information request (HIU -> gateway)
// ----------------------------------------------------------------------------

export async function requestM3HealthInformation(
  runtime: M3ProcessRuntime,
  input: { hospitalId: string; consentId: string },
): Promise<M3HiRequestResult> {
  if (!runtime.config.hiuId) {
    return {
      ok: false,
      status: 501,
      code: M3_ERROR_CODES.HIU_NOT_CONFIGURED,
      error: "ABDM_HIU_ID is not configured",
    };
  }
  if (!runtime.config.callbackBaseUrl) {
    return {
      ok: false,
      status: 501,
      code: M3_ERROR_CODES.HIU_NOT_CONFIGURED,
      error: "ABDM_CALLBACK_BASE_URL is not configured",
    };
  }

  const consent = await runtime.consentStore.findByConsentId(input.consentId);
  if (!consent) {
    return {
      ok: false,
      status: 400,
      code: M3_ERROR_CODES.CONSENT_INVALID,
      error: "Consent artefact not found",
    };
  }
  const consentCheck = validateM3ConsentForRequest({
    consent,
    hiuId: runtime.config.hiuId,
    hospitalId: input.hospitalId,
    hiTypes: consent.hi_types,
    careContextRefs: consent.care_context_references,
    now: new Date(),
  });
  if (!consentCheck.ok) {
    return {
      ok: false,
      status: 400,
      code: consentCheck.code ?? M3_ERROR_CODES.CONSENT_INVALID,
      error: consentCheck.error ?? "Consent is not valid",
    };
  }

  // Live import stays gated until official crypto interoperability exists.
  if (!runtime.dataImportEnabled) {
    return {
      ok: false,
      status: 501,
      code: M3_ERROR_CODES.DATA_IMPORT_GATED,
      error:
        "Live M3 health-information import is gated. Set ABDM_M3_DATA_IMPORT_ENABLED=true only after HIU linkage and verified decryption are available.",
    };
  }
  const keypairProvider = runtime.keypairProvider;
  if (!keypairProvider || keypairProvider.available !== true) {
    return {
      ok: false,
      status: 501,
      code: M3_ERROR_CODES.KEYPAIR_UNAVAILABLE,
      error:
        "Official ABDM V3 HIU keypair generation is not available in this runtime",
    };
  }
  const privateKeyStore = runtime.privateKeyStore;
  if (!privateKeyStore || privateKeyStore.available !== true) {
    return {
      ok: false,
      status: 501,
      code: M3_ERROR_CODES.PRIVATE_KEY_STORE_UNAVAILABLE,
      error:
        "No secure server-side private-key storage is configured for M3 transfers",
    };
  }
  const decryptor = runtime.decryptor;
  if (!decryptor || decryptor.available !== true) {
    return {
      ok: false,
      status: 501,
      code: M3_ERROR_CODES.DECRYPTION_UNAVAILABLE,
      error:
        "Official ABDM V3 decryption is not available in this runtime",
    };
  }

  const requestId = freshM3RequestId();
  const keypair = await keypairProvider.generate();
  if (!keypair.ok || !keypair.publicKeyBase64 || !keypair.nonceBase64 || !keypair.privateKeyBase64) {
    return {
      ok: false,
      status: 500,
      code: keypair.code ?? M3_ERROR_CODES.KEYPAIR_UNAVAILABLE,
      error: keypair.error ?? "HIU keypair generation failed",
    };
  }

  // Save the private key BEFORE the request is sent so the asynchronous data
  // push can always be decrypted. The store is transaction-bound.
  const keyExpiry = consent!.data_to ?? consent!.expires_at ??
    new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString();
  const saved = await privateKeyStore.save(
    requestId,
    keypair.privateKeyBase64,
    keypair.nonceBase64,
    keyExpiry,
  );
  if (!saved.ok) {
    return {
      ok: false,
      status: 500,
      code: saved.code ?? M3_ERROR_CODES.PRIVATE_KEY_STORE_UNAVAILABLE,
      error: saved.error ?? "HIU private key could not be stored securely",
    };
  }

  const dataPushUrl = runtime.config.callbackBaseUrl.replace(/\/+$/, "") +
    V3_M3_DATA_PUSH_PATH;
  const keyMaterial = {
    cryptoAlg: "ECDH",
    curve: "curve25519",
    dhPublicKey: {
      expiry: keyExpiry,
      parameters: keypair.parameters ?? "Curve25519/32byte random key",
      keyValue: keypair.publicKeyBase64,
    },
    nonce: keypair.nonceBase64,
  };
  const body = buildM3HealthInformationRequestBody({
    requestId,
    timestamp: freshM3Timestamp(),
    consentId: input.consentId,
    dateFrom: consent!.data_from ?? "",
    dateTo: consent!.data_to ?? "",
    dataPushUrl,
    keyMaterial,
  });

  const row: M3HiRequestRow = {
    hospital_id: input.hospitalId,
    patient_id: consent!.patient_id,
    consent_id: input.consentId,
    request_id: requestId,
    transaction_id: null,
    hip_id: consent!.hip_id,
    hiu_id: runtime.config.hiuId,
    status: M3_HI_REQUEST_STATUS.REQUEST_CREATED,
    requested_from: consent!.data_from,
    requested_to: consent!.data_to,
    hi_types: consent!.hi_types,
    care_context_references: consent!.care_context_references,
    key_material: keyMaterial,
    expected_pages: null,
    received_pages: 0,
    error_code: null,
    error_message: null,
    submitted_at: null,
    completed_at: null,
  };

  let response: GatewayHttpResponse;
  try {
    response = await v3GatewayPost(
      runtime.fetchImpl,
      runtime.config,
      runtime.v3TokenCache,
      V3_M3_HIU_ID_HEADER,
      runtime.config.hiuId,
      V3_M3_HEALTH_INFORMATION_REQUEST_PATH,
      body,
    );
  } catch (error) {
    await privateKeyStore.delete(requestId);
    return {
      ok: false,
      status: 502,
      code: "ABDM_M3_HI_REQUEST_UPSTREAM_FAILED",
      error: sanitizeUpstreamError(
        error instanceof Error ? error.message : String(error),
      ),
      requestId,
      requestStatus: M3_HI_REQUEST_STATUS.RETRYABLE_FAILURE,
    };
  }

  if (!response.ok) {
    await privateKeyStore.delete(requestId);
    await runtime.hiRequestStore.insert({
      ...row,
      status: M3_HI_REQUEST_STATUS.FAILED_SAFE,
      error_code: `ABDM_M3_HI_REQUEST_UPSTREAM_${response.status}`,
      error_message: sanitizeUpstreamError(
        `ABDM health-information request returned HTTP ${response.status}`,
      ),
    });
    return {
      ok: false,
      status: retryableStatus(response.status) ? 502 : 400,
      code: `ABDM_M3_HI_REQUEST_UPSTREAM_${response.status}`,
      error: sanitizeUpstreamError(
        `ABDM health-information request returned HTTP ${response.status}`,
      ),
      requestId,
      requestStatus: M3_HI_REQUEST_STATUS.FAILED_SAFE,
      upstreamStatus: response.status,
    };
  }

  await runtime.hiRequestStore.insert({
    ...row,
    status: M3_HI_REQUEST_STATUS.REQUEST_SUBMITTED,
    submitted_at: freshM3Timestamp(),
  });

  return {
    ok: true,
    status: 200,
    requestId,
    transactionId: null,
    requestStatus: M3_HI_REQUEST_STATUS.REQUEST_SUBMITTED,
    upstreamStatus: response.status,
  };
}

// ----------------------------------------------------------------------------
// 4. Inbound gateway callback processing (ABDM gateway -> HIU)
// ----------------------------------------------------------------------------

async function persistConsentArtefactFromNotification(
  runtime: M3ProcessRuntime,
  data: M3ConsentNotifyData,
  requestRow: M3ConsentRequestRow | null,
): Promise<boolean> {
  for (const artefact of data.consentArtefacts) {
    const consentRow = await runtime.consentStore.findByConsentId(artefact.id);
    const abhaId = consentRow?.abha_id ?? requestRow?.abha_address ?? "";
    const patientId = consentRow?.patient_id ?? requestRow?.patient_id ?? null;
    const upsertResult = await runtime.consentStore.upsert({
      hospital_id: runtime.hospital.hospitalId,
      patient_id: patientId,
      abha_id: abhaId,
      consent_id: artefact.id,
      hip_id: artefact.hipId ?? consentRow?.hip_id ?? null,
      hiu_id: runtime.config.hiuId,
      purpose: consentRow?.purpose ?? requestRow?.purpose_text ?? null,
      data_from: consentRow?.data_from ?? requestRow?.date_from ?? null,
      data_to: consentRow?.data_to ?? requestRow?.date_to ?? null,
      status: data.status.toLowerCase(),
      granted_at: data.status.toUpperCase() === "GRANTED"
        ? data.timestamp
        : (data.status.toUpperCase() === "REVOKED" ? null : consentRow?.granted_at ?? null),
      expires_at: consentRow?.expires_at ?? requestRow?.data_erase_at ?? null,
      care_context_references: artefact.careContextReferences.length > 0
        ? artefact.careContextReferences
        : (consentRow?.care_context_references ?? []),
      hi_types: consentRow?.hi_types ?? requestRow?.hi_types ?? [],
    });
    if (upsertResult.error) return false;
  }
  return true;
}

export async function processM3Callback(
  type: M3CallbackType,
  body: Record<string, unknown>,
  runtime: M3ProcessRuntime,
): Promise<M3ProcessResult> {
  switch (type) {
    case "consentOnInit": {
      const validation = validateM3ConsentOnInit(body);
      if (!validation.ok || !validation.value) {
        m3Error(400, M3_ERROR_CODES.INVALID_REQUEST, validation.errors.join("; "));
      }
      const data = validation.value;
      const existing = await runtime.consentRequestStore.findByRequestId(
        data.responseRequestId,
      );
      if (!existing) {
        return {
          ackStatus: 202,
          outbound: null,
          status: "consent_on_init_unknown",
          errorCode: M3_ERROR_CODES.CONSENT_REQUEST_UNKNOWN,
          errorMessage: "Consent request not found",
        };
      }
      if (existing.hospital_id !== runtime.hospital.hospitalId) {
        return {
          ackStatus: 202,
          outbound: null,
          status: "consent_on_init_hospital_mismatch",
          errorCode: M3_ERROR_CODES.CONSENT_REQUEST_UNKNOWN,
          errorMessage: "Consent request does not belong to this hospital",
        };
      }
      await runtime.consentRequestStore.updateByRequestId(data.responseRequestId, {
        consent_request_id: data.consentRequestId,
        status: M3_CONSENT_REQUEST_STATUS.PENDING,
        error_code: data.errorMessage
          ? "ABDM_M3_CONSENT_INIT_ERROR"
          : null,
        error_message: data.errorMessage,
        responded_at: freshM3Timestamp(),
      });
      return {
        ackStatus: 202,
        outbound: null,
        status: "consent_on_init_received",
        errorCode: data.errorMessage ? "ABDM_M3_CONSENT_INIT_ERROR" : null,
        errorMessage: data.errorMessage,
      };
    }
    case "consentOnStatus": {
      const validation = validateM3ConsentOnStatus(body);
      if (!validation.ok || !validation.value) {
        m3Error(400, M3_ERROR_CODES.INVALID_REQUEST, validation.errors.join("; "));
      }
      const data = validation.value;
      const requestRow = await runtime.consentRequestStore.findByRequestId(
        data.responseRequestId,
      );
      if (!requestRow) {
        return {
          ackStatus: 202,
          outbound: null,
          status: "consent_on_status_unknown",
          errorCode: M3_ERROR_CODES.CONSENT_REQUEST_UNKNOWN,
          errorMessage: "Consent request not found",
        };
      }
      if (requestRow.hospital_id !== runtime.hospital.hospitalId) {
        return {
          ackStatus: 202,
          outbound: null,
          status: "consent_on_status_hospital_mismatch",
          errorCode: M3_ERROR_CODES.CONSENT_REQUEST_UNKNOWN,
          errorMessage: "Consent request does not belong to this hospital",
        };
      }
      const normalizedStatus = data.status.toLowerCase() as M3ConsentRequestStatus;
      await runtime.consentRequestStore.updateByRequestId(data.responseRequestId, {
        status: normalizedStatus,
        responded_at: freshM3Timestamp(),
        error_code: null,
        error_message: null,
      });
      return {
        ackStatus: 202,
        outbound: null,
        status: "consent_on_status_received",
        errorCode: null,
        errorMessage: null,
      };
    }
    case "consentNotify": {
      const validation = validateM3ConsentNotify(body);
      if (!validation.ok || !validation.value) {
        m3Error(400, M3_ERROR_CODES.INVALID_REQUEST, validation.errors.join("; "));
      }
      const data = validation.value;
      const requestRow = await runtime.consentRequestStore.findByConsentRequestId(
        data.consentRequestId,
      );
      if (!requestRow) {
        return {
          ackStatus: 202,
          outbound: null,
          status: "consent_notify_unknown",
          errorCode: M3_ERROR_CODES.CONSENT_REQUEST_UNKNOWN,
          errorMessage: "Consent request not found",
        };
      }
      if (requestRow.hospital_id !== runtime.hospital.hospitalId) {
        return {
          ackStatus: 202,
          outbound: null,
          status: "consent_notify_hospital_mismatch",
          errorCode: M3_ERROR_CODES.CONSENT_REQUEST_UNKNOWN,
          errorMessage: "Consent request does not belong to this hospital",
        };
      }

      const statusMap: Record<string, M3ConsentRequestStatus> = {
        GRANTED: M3_CONSENT_REQUEST_STATUS.GRANTED,
        DENIED: M3_CONSENT_REQUEST_STATUS.DENIED,
        REVOKED: M3_CONSENT_REQUEST_STATUS.REVOKED,
        EXPIRED: M3_CONSENT_REQUEST_STATUS.EXPIRED,
      };
      const nextStatus = statusMap[data.status] ?? M3_CONSENT_REQUEST_STATUS.PENDING;
      await runtime.consentRequestStore.updateByRequestId(requestRow.request_id, {
        status: nextStatus,
        responded_at: freshM3Timestamp(),
        error_code: data.errorMessage ? "ABDM_M3_CONSENT_NOTIFY_ERROR" : null,
        error_message: data.errorMessage,
      });

      if (data.status === "GRANTED" || data.status === "REVOKED" || data.status === "EXPIRED") {
        await persistConsentArtefactFromNotification(runtime, data, requestRow);
      }

      const outbound = {
        path: V3_M3_CONSENT_HIU_ON_NOTIFY_PATH,
        body: buildM3ConsentOnNotifyAckBody({
          requestId: data.requestId,
          consentIds: data.consentArtefacts.map((artefact) => artefact.id),
        }),
      };
      return {
        ackStatus: 202,
        outbound,
        status: "consent_notify_received",
        errorCode: null,
        errorMessage: null,
      };
    }
    case "consentOnFetch": {
      const validation = validateM3ConsentOnFetch(body);
      if (!validation.ok || !validation.value) {
        m3Error(400, M3_ERROR_CODES.INVALID_REQUEST, validation.errors.join("; "));
      }
      const data = validation.value;
      const consentId = data.consentId;
      const existing = await runtime.consentStore.findByConsentId(consentId);
      const upsertResult = await runtime.consentStore.upsert({
        hospital_id: runtime.hospital.hospitalId,
        patient_id: existing?.patient_id ?? null,
        abha_id: data.patientAbhaAddress,
        consent_id: consentId,
        hip_id: data.hipId ?? existing?.hip_id ?? null,
        hiu_id: data.hiuId ?? runtime.config.hiuId,
        purpose: data.purposeText ?? existing?.purpose ?? null,
        data_from: data.dataFrom ?? existing?.data_from ?? null,
        data_to: data.dataTo ?? existing?.data_to ?? null,
        status: data.status.toLowerCase(),
        granted_at: data.status.toUpperCase() === "GRANTED"
          ? freshM3Timestamp()
          : existing?.granted_at ?? null,
        expires_at: data.dataEraseAt ?? existing?.expires_at ?? null,
        care_context_references: data.careContextReferences.length > 0
          ? data.careContextReferences
          : (existing?.care_context_references ?? []),
        hi_types: data.hiTypes.length > 0 ? data.hiTypes : (existing?.hi_types ?? []),
      });
      if (upsertResult.error) {
        m3Error(500, M3_ERROR_CODES.CONSENT_INVALID, "Consent artefact could not be persisted");
      }
      return {
        ackStatus: 202,
        outbound: null,
        status: "consent_on_fetch_received",
        errorCode: null,
        errorMessage: null,
      };
    }
    case "healthInformationOnRequest": {
      const validation = validateM3HealthInformationOnRequest(body);
      if (!validation.ok || !validation.value) {
        m3Error(400, M3_ERROR_CODES.INVALID_REQUEST, validation.errors.join("; "));
      }
      const data = validation.value;
      const requestRow = await runtime.hiRequestStore.findByRequestId(
        data.responseRequestId,
      );
      if (!requestRow) {
        return {
          ackStatus: 202,
          outbound: null,
          status: "health_information_on_request_unknown",
          errorCode: M3_ERROR_CODES.TRANSACTION_UNKNOWN,
          errorMessage: "Health-information request not found",
        };
      }
      if (requestRow.hospital_id !== runtime.hospital.hospitalId) {
        return {
          ackStatus: 202,
          outbound: null,
          status: "health_information_on_request_hospital_mismatch",
          errorCode: M3_ERROR_CODES.TRANSACTION_UNKNOWN,
          errorMessage: "Health-information request does not belong to this hospital",
        };
      }
      await runtime.hiRequestStore.updateByRequestId(data.responseRequestId, {
        transaction_id: data.transactionId,
        status: M3_HI_REQUEST_STATUS.WAITING_FOR_DATA,
        error_code: data.errorMessage ? "ABDM_M3_HI_REQUEST_ACK_ERROR" : null,
        error_message: data.errorMessage,
      });
      return {
        ackStatus: 202,
        outbound: null,
        status: "health_information_on_request_received",
        errorCode: null,
        errorMessage: null,
      };
    }
    default:
      m3Error(400, M3_ERROR_CODES.INVALID_REQUEST, `Unsupported M3 callback type: ${type}`);
  }
}

// ----------------------------------------------------------------------------
// 5. Encrypted data push (HIP -> HIU) + transfer state machine
// ----------------------------------------------------------------------------

export interface M3DataPushResult {
  ackStatus: number;
  ackBody: Record<string, unknown>;
  outbound: M3OutboundCall | null;
  status: string;
  errorCode: string | null;
  errorMessage: string | null;
}

function pageSetComplete(pages: M3DataPageRow[], pageCount: number): boolean {
  if (pages.length !== pageCount) return false;
  const numbers = new Set(pages.map((page) => page.page_number));
  for (let i = 0; i < pageCount; i++) {
    if (!numbers.has(i)) return false;
  }
  return true;
}

export async function processM3DataPush(
  body: Record<string, unknown>,
  runtime: M3ProcessRuntime,
): Promise<M3DataPushResult> {
  const validation = validateM3DataPush(body);
  if (!validation.ok || !validation.value) {
    return {
      ackStatus: 400,
      ackBody: {
        error: { code: M3_ERROR_CODES.INVALID_REQUEST, message: validation.errors.join("; ") },
      },
      outbound: null,
      status: "data_push_invalid",
      errorCode: M3_ERROR_CODES.INVALID_REQUEST,
      errorMessage: validation.errors.join("; "),
    };
  }
  const data = validation.value;

  const request = await runtime.hiRequestStore.findByTransactionId(
    data.transactionId,
  );
  if (!request) {
    return {
      ackStatus: 400,
      ackBody: {
        error: { code: M3_ERROR_CODES.TRANSACTION_UNKNOWN, message: "Transaction id not found" },
      },
      outbound: null,
      status: "data_push_unknown_transaction",
      errorCode: M3_ERROR_CODES.TRANSACTION_UNKNOWN,
      errorMessage: "Transaction id not found",
    };
  }
  if (request.hospital_id !== runtime.hospital.hospitalId) {
    return {
      ackStatus: 400,
      ackBody: {
        error: {
          code: M3_ERROR_CODES.TRANSACTION_HOSPITAL_MISMATCH,
          message: "Transaction does not belong to this hospital",
        },
      },
      outbound: null,
      status: "data_push_hospital_mismatch",
      errorCode: M3_ERROR_CODES.TRANSACTION_HOSPITAL_MISMATCH,
      errorMessage: "Transaction does not belong to this hospital",
    };
  }

  // Consent correlation must still hold when the data arrives.
  const consent = await runtime.consentStore.findByConsentId(request.consent_id);
  const consentCheck = consentIsUsable(consent, new Date());
  if (!consentCheck.usable) {
    await runtime.hiRequestStore.updateByTransactionId(data.transactionId, {
      status: M3_HI_REQUEST_STATUS.FAILED_SAFE,
      error_code: consentCheck.code ?? M3_ERROR_CODES.CONSENT_INVALID,
      error_message: consentCheck.error ?? "Consent is not valid",
    });
    return {
      ackStatus: 400,
      ackBody: {
        error: { code: consentCheck.code ?? M3_ERROR_CODES.CONSENT_INVALID, message: consentCheck.error ?? "Consent is not valid" },
      },
      outbound: null,
      status: "data_push_consent_invalid",
      errorCode: consentCheck.code ?? M3_ERROR_CODES.CONSENT_INVALID,
      errorMessage: consentCheck.error ?? "Consent is not valid",
    };
  }

  // Care-context entries must belong to the consent.
  const allowedRefs = new Set(consent!.care_context_references);
  for (const entry of data.entries) {
    if (!allowedRefs.has(entry.careContextReference)) {
      await runtime.hiRequestStore.updateByTransactionId(data.transactionId, {
        status: M3_HI_REQUEST_STATUS.FAILED_SAFE,
        error_code: M3_ERROR_CODES.CONSENT_INVALID,
        error_message: `Care-context reference ${entry.careContextReference} is not covered by the consent`,
      });
      return {
        ackStatus: 400,
        ackBody: {
          error: {
            code: M3_ERROR_CODES.CONSENT_INVALID,
            message: `Care-context reference ${entry.careContextReference} is not covered by the consent`,
          },
        },
        outbound: null,
        status: "data_push_care_context_unauthorized",
        errorCode: M3_ERROR_CODES.CONSENT_INVALID,
        errorMessage: `Care-context reference ${entry.careContextReference} is not covered by the consent`,
      };
    }
  }

  // Record expected page count the first time we learn it; reject an
  // inconsistent pageCount on subsequent pages.
  if (request.expected_pages !== null && request.expected_pages !== data.pageCount) {
    return {
      ackStatus: 400,
      ackBody: {
        error: {
          code: M3_ERROR_CODES.INVALID_REQUEST,
          message: "pageCount does not match the previously declared pageCount",
        },
      },
      outbound: null,
      status: "data_push_page_count_mismatch",
      errorCode: M3_ERROR_CODES.INVALID_REQUEST,
      errorMessage: "pageCount does not match the previously declared pageCount",
    };
  }

  const nowIso = freshM3Timestamp();
  const pageRow: M3DataPageRow = {
    hospital_id: request.hospital_id,
    transaction_id: data.transactionId,
    page_number: data.pageNumber,
    page_count: data.pageCount,
    status: M3_PAGE_STATUS.RECEIVED,
    entry_count: data.entries.length,
    entries: data.entries,
    key_material: data.keyMaterial as unknown as Record<string, unknown>,
    checksum_metadata: data.entries.map((entry) => ({
      careContextReference: entry.careContextReference,
      checksum: entry.checksum,
    })),
    received_at: nowIso,
    processing_status: null,
    error_code: null,
    error_message: null,
  };

  const insertResult = await runtime.dataPageStore.insertPage(pageRow);
  if (insertResult === "duplicate") {
    // ABDM/HIP replays are idempotent — the page is already stored.
    return {
      ackStatus: 200,
      ackBody: { status: "ACK" },
      outbound: null,
      status: "data_push_page_duplicate",
      errorCode: null,
      errorMessage: null,
    };
  }

  await runtime.hiRequestStore.updateByTransactionId(data.transactionId, {
    expected_pages: data.pageCount,
    received_pages: (request.received_pages ?? 0) + 1,
    status: M3_HI_REQUEST_STATUS.RECEIVING,
    error_code: null,
    error_message: null,
  });

  const pages = await runtime.dataPageStore.listByTransactionId(data.transactionId);
  if (!pageSetComplete(pages, data.pageCount)) {
    // Wait for the remaining pages.
    return {
      ackStatus: 200,
      ackBody: { status: "ACK" },
      outbound: null,
      status: "data_push_page_received",
      errorCode: null,
      errorMessage: null,
    };
  }

  // All pages received: decrypt -> validate -> persist -> notify gateway.
  await runtime.hiRequestStore.updateByTransactionId(data.transactionId, {
    status: M3_HI_REQUEST_STATUS.ALL_PAGES_RECEIVED,
  });

  const finalize = await finalizeM3Transfer(
    runtime,
    request,
    pages,
    data.transactionId,
  );

  return {
    ackStatus: 200,
    ackBody: { status: "ACK" },
    outbound: finalize.outbound,
    status: finalize.status,
    errorCode: finalize.errorCode,
    errorMessage: finalize.errorMessage,
  };
}

interface M3FinalizeResult {
  status: string;
  errorCode: string | null;
  errorMessage: string | null;
  outbound: M3OutboundCall | null;
}

async function finalizeM3Transfer(
  runtime: M3ProcessRuntime,
  request: M3HiRequestRow,
  pages: M3DataPageRow[],
  transactionId: string,
): Promise<M3FinalizeResult> {
  const nowIso = freshM3Timestamp();
  const patientId = request.patient_id;
  if (!patientId) {
    await runtime.hiRequestStore.updateByTransactionId(transactionId, {
      status: M3_HI_REQUEST_STATUS.FAILED_SAFE,
      error_code: M3_ERROR_CODES.PATIENT_NOT_FOUND,
      error_message: "Consent patient could not be resolved",
      completed_at: nowIso,
    });
    return {
      status: "data_push_patient_unresolved",
      errorCode: M3_ERROR_CODES.PATIENT_NOT_FOUND,
      errorMessage: "Consent patient could not be resolved",
      outbound: buildM3TransferFailureNotify(runtime, request, transactionId),
    };
  }

  if (!runtime.dataImportEnabled) {
    await runtime.hiRequestStore.updateByTransactionId(transactionId, {
      status: M3_HI_REQUEST_STATUS.FAILED_SAFE,
      error_code: M3_ERROR_CODES.DATA_IMPORT_GATED,
      error_message: "Live M3 data import is gated",
      completed_at: nowIso,
    });
    return {
      status: "data_push_import_gated",
      errorCode: M3_ERROR_CODES.DATA_IMPORT_GATED,
      errorMessage: "Live M3 data import is gated",
      outbound: buildM3TransferFailureNotify(runtime, request, transactionId),
    };
  }

  const decryptor = runtime.decryptor;
  if (!decryptor || decryptor.available !== true) {
    await runtime.hiRequestStore.updateByTransactionId(transactionId, {
      status: M3_HI_REQUEST_STATUS.FAILED_SAFE,
      error_code: M3_ERROR_CODES.DECRYPTION_UNAVAILABLE,
      error_message: "Official ABDM V3 decryption is not available in this runtime",
      completed_at: nowIso,
    });
    return {
      status: "data_push_decryption_unavailable",
      errorCode: M3_ERROR_CODES.DECRYPTION_UNAVAILABLE,
      errorMessage: "Official ABDM V3 decryption is not available in this runtime",
      outbound: buildM3TransferFailureNotify(runtime, request, transactionId),
    };
  }

  const privateKeyStore = runtime.privateKeyStore;
  const storedKey = privateKeyStore
    ? await privateKeyStore.get(request.request_id)
    : null;
  if (!storedKey) {
    await runtime.hiRequestStore.updateByTransactionId(transactionId, {
      status: M3_HI_REQUEST_STATUS.FAILED_SAFE,
      error_code: M3_ERROR_CODES.PRIVATE_KEY_STORE_UNAVAILABLE,
      error_message: "HIU private key is not available for this transaction",
      completed_at: nowIso,
    });
    return {
      status: "data_push_private_key_unavailable",
      errorCode: M3_ERROR_CODES.PRIVATE_KEY_STORE_UNAVAILABLE,
      errorMessage: "HIU private key is not available for this transaction",
      outbound: buildM3TransferFailureNotify(runtime, request, transactionId),
    };
  }

  await runtime.hiRequestStore.updateByTransactionId(transactionId, {
    status: M3_HI_REQUEST_STATUS.DECRYPTING,
  });

  // Decrypt every entry on every page. A single failure fails the transfer.
  const decryptedEntries: Array<{
    page: M3DataPageRow;
    entry: M3HealthInformationEntry;
    payload: Record<string, unknown>;
  }> = [];
  for (const page of pages.sort((a, b) => a.page_number - b.page_number)) {
    await runtime.dataPageStore.markProcessing(transactionId, page.page_number);
    for (const entry of page.entries) {
      const decryption = await decryptor.decrypt({
        encryptedContent: entry.content,
        receiverPrivateKey: storedKey.privateKeyBase64,
        receiverNonce: storedKey.nonceBase64,
        senderKeyMaterial: page.key_material as M3DecryptionInput["senderKeyMaterial"],
        transactionContext: transactionId,
      });
      if (!decryption.ok || !decryption.plaintext) {
        await runtime.dataPageStore.markProcessed(
          transactionId,
          page.page_number,
          M3_PAGE_STATUS.FAILED_SAFE,
          decryption.code ?? M3_ERROR_CODES.DECRYPTION_UNAVAILABLE,
          decryption.error ?? "Decryption failed",
        );
        await runtime.hiRequestStore.updateByTransactionId(transactionId, {
          status: M3_HI_REQUEST_STATUS.FAILED_SAFE,
          error_code: decryption.code ?? M3_ERROR_CODES.DECRYPTION_UNAVAILABLE,
          error_message: decryption.error ?? "Decryption failed",
          completed_at: nowIso,
        });
        return {
          status: "data_push_decryption_failed",
          errorCode: decryption.code ?? M3_ERROR_CODES.DECRYPTION_UNAVAILABLE,
          errorMessage: decryption.error ?? "Decryption failed",
          outbound: buildM3TransferFailureNotify(runtime, request, transactionId),
        };
      }
      let parsed: unknown;
      try {
        parsed = JSON.parse(decryption.plaintext);
      } catch (_) {
        await runtime.hiRequestStore.updateByTransactionId(transactionId, {
          status: M3_HI_REQUEST_STATUS.FAILED_SAFE,
          error_code: M3_ERROR_CODES.FHIR_INVALID,
          error_message: "Decrypted payload is not valid JSON",
          completed_at: nowIso,
        });
        return {
          status: "data_push_fhir_invalid",
          errorCode: M3_ERROR_CODES.FHIR_INVALID,
          errorMessage: "Decrypted payload is not valid JSON",
          outbound: buildM3TransferFailureNotify(runtime, request, transactionId),
        };
      }
      const payload = parsed as Record<string, unknown>;
      const fhirValidation = validateM3FhirPayload(payload);
      if (!fhirValidation.ok) {
        await runtime.hiRequestStore.updateByTransactionId(transactionId, {
          status: M3_HI_REQUEST_STATUS.FAILED_SAFE,
          error_code: fhirValidation.code ?? M3_ERROR_CODES.FHIR_INVALID,
          error_message: fhirValidation.error ?? "FHIR validation failed",
          completed_at: nowIso,
        });
        return {
          status: "data_push_fhir_invalid",
          errorCode: fhirValidation.code ?? M3_ERROR_CODES.FHIR_INVALID,
          errorMessage: fhirValidation.error ?? "FHIR validation failed",
          outbound: buildM3TransferFailureNotify(runtime, request, transactionId),
        };
      }
      decryptedEntries.push({ page, entry, payload });
    }
  }

  await runtime.hiRequestStore.updateByTransactionId(transactionId, {
    status: M3_HI_REQUEST_STATUS.VALIDATING,
  });

  // Persist each FHIR resource tenant-scoped and idempotently. A duplicate
  // (transaction + care-context + resource id) is never inserted twice.
  const consent = await runtime.consentStore.findByConsentId(request.consent_id);
  const consentHiTypes = consent?.hi_types ?? [];
  if (consentHiTypes.length === 0) {
    await runtime.hiRequestStore.updateByTransactionId(transactionId, {
      status: M3_HI_REQUEST_STATUS.FAILED_SAFE,
      error_code: M3_ERROR_CODES.CONSENT_INVALID,
      error_message: "Consent artefact does not record HI types",
      completed_at: nowIso,
    });
    return {
      status: "data_push_consent_hi_types_absent",
      errorCode: M3_ERROR_CODES.CONSENT_INVALID,
      errorMessage: "Consent artefact does not record HI types",
      outbound: buildM3TransferFailureNotify(runtime, request, transactionId),
    };
  }
  const allowedHiTypes = new Set(consentHiTypes.map((t) => t.toUpperCase()));
  for (const decrypted of decryptedEntries) {
    for (const resource of extractM3FhirResources(decrypted.payload)) {
      const hiType = hiTypeForFhirResourceType(resource.resourceType) ??
        "HealthDocumentRecord";
      if (!allowedHiTypes.has(hiType.toUpperCase())) {
        await runtime.hiRequestStore.updateByTransactionId(transactionId, {
          status: M3_HI_REQUEST_STATUS.FAILED_SAFE,
          error_code: M3_ERROR_CODES.FHIR_INVALID,
          error_message: `FHIR resource type ${resource.resourceType} is not covered by the consent HI types`,
          completed_at: nowIso,
        });
        return {
          status: "data_push_fhir_hi_type_unauthorized",
          errorCode: M3_ERROR_CODES.FHIR_INVALID,
          errorMessage: `FHIR resource type ${resource.resourceType} is not covered by the consent HI types`,
          outbound: buildM3TransferFailureNotify(runtime, request, transactionId),
        };
      }
      const insertResult = await runtime.fhirRecordStore.insertImported({
        hospital_id: request.hospital_id ?? runtime.hospital.hospitalId,
        patient_id: patientId,
        abha_id: consent?.abha_id ?? "",
        consent_id: request.consent_id,
        transaction_id: transactionId,
        care_context_reference: decrypted.entry.careContextReference,
        hi_type: hiType,
        resource_type: resource.resourceType,
        record_id: resource.resourceId,
        source_hip_id: request.hip_id,
        fhir_resource: resource.resource,
        received_at: nowIso,
        checksum: decrypted.entry.checksum,
        verification_status: "verified",
      });
      if (insertResult === "error") {
        await runtime.hiRequestStore.updateByTransactionId(transactionId, {
          status: M3_HI_REQUEST_STATUS.FAILED_SAFE,
          error_code: M3_ERROR_CODES.INTERNAL,
          error_message: "FHIR record could not be persisted",
          completed_at: nowIso,
        });
        return {
          status: "data_push_fhir_persist_failed",
          errorCode: M3_ERROR_CODES.INTERNAL,
          errorMessage: "FHIR record could not be persisted",
          outbound: buildM3TransferFailureNotify(runtime, request, transactionId),
        };
      }
    }
  }

  for (const page of pages) {
    await runtime.dataPageStore.markProcessed(
      transactionId,
      page.page_number,
      M3_PAGE_STATUS.PROCESSED,
    );
  }

  await runtime.hiRequestStore.updateByTransactionId(transactionId, {
    status: M3_HI_REQUEST_STATUS.PERSISTED,
    completed_at: nowIso,
  });
  await runtime.hiRequestStore.updateByTransactionId(transactionId, {
    status: M3_HI_REQUEST_STATUS.COMPLETED,
  });

  return {
    status: "data_push_completed",
    errorCode: null,
    errorMessage: null,
    outbound: buildM3TransferSuccessNotify(runtime, request, transactionId),
  };
}

function buildM3TransferSuccessNotify(
  runtime: M3ProcessRuntime,
  request: M3HiRequestRow,
  transactionId: string,
): M3OutboundCall {
  return {
    path: V3_M3_HEALTH_INFORMATION_NOTIFY_PATH,
    body: buildM3HealthInformationNotifyBody({
      requestId: freshM3RequestId(),
      timestamp: freshM3Timestamp(),
      consentId: request.consent_id,
      transactionId,
      doneAt: freshM3Timestamp(),
      hiuId: runtime.config.hiuId,
      hipId: request.hip_id ?? "",
      sessionStatus: "TRANSFERRED",
      statusResponses: request.care_context_references.map((ref) => ({
        careContextReference: ref,
        hiStatus: "OK",
        description: "Done",
      })),
    }),
  };
}

function buildM3TransferFailureNotify(
  runtime: M3ProcessRuntime,
  request: M3HiRequestRow,
  transactionId: string,
): M3OutboundCall {
  return {
    path: V3_M3_HEALTH_INFORMATION_NOTIFY_PATH,
    body: buildM3HealthInformationNotifyBody({
      requestId: freshM3RequestId(),
      timestamp: freshM3Timestamp(),
      consentId: request.consent_id,
      transactionId,
      doneAt: freshM3Timestamp(),
      hiuId: runtime.config.hiuId,
      hipId: request.hip_id ?? "",
      sessionStatus: "FAILED",
      statusResponses: request.care_context_references.map((ref) => ({
        careContextReference: ref,
        hiStatus: "ERRORED",
        description: "HIU could not process the transferred health information",
      })),
    }),
  };
}

// ----------------------------------------------------------------------------
// Production decryptor (STOPPED until official interoperability is proven)
// ----------------------------------------------------------------------------

/**
 * The official V3 M3 decryption contract (DecryptionManager.java) is:
 *
 *   1. XOR the HIP nonce bytes with the HIU nonce bytes (cycling the shorter).
 *   2. ECDH shared secret: BouncyCastle "ECDH" on CustomNamedCurves
 *      `curve25519` with the HIU private scalar (raw BigInteger) and the HIP
 *      public key parsed as X.509 SubjectPublicKeyInfo.
 *   3. HKDF-SHA256(IKM = base64(sharedSecretBytes), salt = first 20 bytes of
 *      the XOR output, info = empty) -> 32-byte AES key.
 *   4. AES-128-GCM (BouncyCastle GCMBlockCipher) with IV = last 12 bytes of
 *      the XOR output, 128-bit tag and no AAD.
 *
 * This contract CANNOT be reproduced safely in the Deno Edge Runtime:
 *   * The official BouncyCastle curve25519 ECDH does NOT match RFC 7748
 *     X25519 (different generator, no RFC 7748 scalar clamping), so WebCrypto
 *     X25519 and @noble/curves X25519 are not interoperable substitutions.
 *   * The official sender encodes the public key with
 *     `ECPoint.getEncoded(false)` (raw 0x04 || X || Y) while the official
 *     receiver parses it with `X509EncodedKeySpec` (SubjectPublicKeyInfo),
 *     which is internally inconsistent without the private BC provider path.
 *
 * Production decryption therefore stays STOPPED and reports
 * ABDM_M3_DECRYPTION_UNAVAILABLE. The rest of the M3 pipeline is fully
 * testable with an injectable mock decryptor.
 */
export function unavailableM3Decryptor(reason?: string): M3Decryptor {
  const message = reason ??
    "Official ABDM V3 decryption (BouncyCastle ECDH curve25519 + XOR nonces + " +
      "HKDF-SHA256 + AES-128-GCM) has no official JavaScript interoperability " +
      "vector and cannot be substituted safely in the Deno Edge Runtime";
  return {
    available: false,
    async decrypt(): Promise<M3DecryptionResult> {
      return {
        ok: false,
        code: M3_ERROR_CODES.DECRYPTION_UNAVAILABLE,
        error: message,
      };
    },
  };
}

/**
 * Production HIU keypair provider. Live keypair generation stays STOPPED for
 * exactly the same reason as decryption: generating an RFC 7748 X25519 keypair
 * in the Edge Runtime would not interoperate with the official BouncyCastle
 * curve25519 contract.
 */
export function unavailableM3KeypairProvider(reason?: string): M3KeypairProvider {
  const message = reason ??
    "Official ABDM V3 HIU keypair generation is not available in this runtime";
  return {
    available: false,
    async generate(): Promise<M3KeypairResult> {
      return {
        ok: false,
        code: M3_ERROR_CODES.KEYPAIR_UNAVAILABLE,
        error: message,
      };
    },
  };
}

/**
 * Production private-key store. There is no server-side protected mechanism
 * configured in this repository, so production refuses to persist any private
 * key and reports UNAVAILABLE. A transaction-bound store can be enabled by an
 * operator only with an approved secure mechanism (for example a Supabase
 * Vault-backed store) and must never write plaintext private keys.
 */
export function unavailableM3PrivateKeyStore(reason?: string): M3PrivateKeyStore {
  const message = reason ??
    "No secure server-side private-key storage is configured for M3 transfers";
  return {
    available: false,
    async save() {
      return {
        ok: false,
        code: M3_ERROR_CODES.PRIVATE_KEY_STORE_UNAVAILABLE,
        error: message,
      };
    },
    async get() {
      return null;
    },
    async delete() {
      // Nothing persisted.
    },
  };
}
