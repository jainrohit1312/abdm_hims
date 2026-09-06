// ============================================================================
// ABDM V3 M2 HIP — health-information data-transfer execution.
// ----------------------------------------------------------------------------
// This module contains the production pieces that run AFTER a valid
// health-information request has been persisted as an `abdm_data_transfer_jobs`
// row:
//
//   * official dataPushUrl SSRF validation + bounded HTTPS push
//   * job lifecycle execution (preparing -> encrypted -> pushing -> pushed
//     -> notifying -> completed) with atomic lease/claim, bounded retries and
//     safe terminal failure states
//   * final ABDM health-information notify via the canonical V3 client
//   * production encryption availability gate
//
// ENCRYPTION STATUS (reviewed 2026-09-06)
//   The official NHA ABDM-wrapper v3 / fidelius reference implements
//   `ECDH` + `curve25519` through BouncyCastle. A deterministic vector
//   generated with BouncyCastle 1.66 (the exact dependency used by the
//   official wrapper) shows that its curve25519 ECDH does NOT match standard
//   RFC 7748 X25519 (different generator and no RFC 7748 scalar clamping), so
//   WebCrypto / @noble/curves cannot be substituted without an official ABDM
//   interoperability test vector. Live encryption therefore stays STOPPED:
//   the production encryptor reports ABDM_M2_ENCRYPTION_UNAVAILABLE and the
//   data-transfer feature gate must remain OFF.
// ============================================================================

import {
  type FetchImpl,
  type GatewayHttpResponse,
  isLocalOrPrivateHost,
} from "./core.ts";
import {
  buildHealthInformationNotifyBody,
  M2_ERROR_CODES,
  M2_JOB_STATUS,
  type M2DataTransferJobRow,
  type M2EncryptionResult,
  type M2Encryptor,
  type M2HealthInformationRequest,
  type M2ProcessRuntime,
  validateConsentForTransfer,
  V3_M2_HEALTH_INFORMATION_NOTIFY_PATH,
} from "./m2.ts";
import { m2GatewayPost } from "./m2.ts";

// ----------------------------------------------------------------------------
// Official V3 encryption availability (STOPPED until an official vector exists)
// ----------------------------------------------------------------------------

export function unavailableM2Encryptor(reason?: string): M2Encryptor {
  const message = reason ??
    "Official ABDM V3 encryption (ECDH curve25519 per the NHA wrapper/fidelius reference) " +
      "requires BouncyCastle curve semantics that are not available in the Deno Edge " +
      "Runtime and have no official JavaScript interoperability vector";
  return {
    available: false,
    async encrypt(): Promise<M2EncryptionResult> {
      return {
        ok: false,
        code: M2_ERROR_CODES.ENCRYPTION_UNAVAILABLE,
        message,
      };
    },
  };
}

export interface M2KeyMaterialValidation {
  ok: boolean;
  code?: string;
  error?: string;
}

/**
 * Validates the official V3 key-material contract shape:
 *   cryptoAlg: ECDH
 *   curve: curve25519
 *   dhPublicKey.keyValue: non-empty base64
 *   nonce: non-empty base64
 */
export function validateM2KeyMaterial(
  keyMaterial: M2HealthInformationRequest["keyMaterial"],
): M2KeyMaterialValidation {
  if (!keyMaterial || typeof keyMaterial !== "object") {
    return {
      ok: false,
      code: M2_ERROR_CODES.ENCRYPTION_UNAVAILABLE,
      error: "keyMaterial is missing",
    };
  }
  if (keyMaterial.cryptoAlg !== "ECDH") {
    return {
      ok: false,
      code: M2_ERROR_CODES.ENCRYPTION_UNAVAILABLE,
      error: `Unsupported cryptoAlg: ${keyMaterial.cryptoAlg || "missing"}`,
    };
  }
  if (keyMaterial.curve !== "curve25519") {
    return {
      ok: false,
      code: M2_ERROR_CODES.ENCRYPTION_UNAVAILABLE,
      error: `Unsupported curve: ${keyMaterial.curve || "missing"}`,
    };
  }
  const keyValue = keyMaterial.dhPublicKey?.keyValue ?? "";
  if (!keyValue.trim()) {
    return {
      ok: false,
      code: M2_ERROR_CODES.ENCRYPTION_UNAVAILABLE,
      error: "dhPublicKey.keyValue is missing",
    };
  }
  try {
    const bytes = Uint8Array.from(atob(keyValue), (c) => c.charCodeAt(0));
    if (bytes.byteLength === 0) throw new Error("empty");
  } catch (_) {
    return {
      ok: false,
      code: M2_ERROR_CODES.ENCRYPTION_UNAVAILABLE,
      error: "dhPublicKey.keyValue is not valid base64",
    };
  }
  const nonce = keyMaterial.nonce ?? "";
  if (!nonce.trim()) {
    return {
      ok: false,
      code: M2_ERROR_CODES.ENCRYPTION_UNAVAILABLE,
      error: "nonce is missing",
    };
  }
  try {
    const bytes = Uint8Array.from(atob(nonce), (c) => c.charCodeAt(0));
    if (bytes.byteLength === 0) throw new Error("empty");
  } catch (_) {
    return {
      ok: false,
      code: M2_ERROR_CODES.ENCRYPTION_UNAVAILABLE,
      error: "nonce is not valid base64",
    };
  }
  return { ok: true };
}

// ----------------------------------------------------------------------------
// dataPushUrl SSRF validation
// ----------------------------------------------------------------------------

export interface DataPushUrlValidation {
  ok: boolean;
  url?: string;
  code?: string;
  error?: string;
}

const METADATA_HOST_PATTERNS = [
  /(^|\.)metadata(\.|$)/i,
  /(^|\.)metadata\.google\.internal$/i,
  /\.internal$/i,
];

function isMetadataHostname(hostname: string): boolean {
  return METADATA_HOST_PATTERNS.some((pattern) => pattern.test(hostname));
}

export type DnsResolver = (hostname: string) => Promise<string[]>;

/**
 * Validates the official health-information request `dataPushUrl` before any
 * outbound request is built:
 *   * absolute HTTPS URL only
 *   * no credentials, query string or fragment
 *   * hostname is not localhost / private / link-local / reserved (RFC 1918,
 *     100.64/10, 169.254/16, 192.0.0/24, metadata endpoints)
 *   * when DNS resolution is available every resolved A/AAAA record must be
 *     public as well (fail closed when resolution fails)
 */
export async function validateDataPushUrl(
  raw: string,
  resolveDns?: DnsResolver,
): Promise<DataPushUrlValidation> {
  const trimmed = raw.trim();
  let url: URL;
  try {
    url = new URL(trimmed);
  } catch (_) {
    return { ok: false, code: "ABDM_M2_PUSH_URL_INVALID", error: "dataPushUrl must be a valid absolute URL" };
  }
  if (url.protocol !== "https:") {
    return { ok: false, code: "ABDM_M2_PUSH_URL_INSECURE", error: "dataPushUrl must use HTTPS" };
  }
  if (url.username || url.password) {
    return { ok: false, code: "ABDM_M2_PUSH_URL_INVALID", error: "dataPushUrl must not contain credentials" };
  }
  if (url.search) {
    return { ok: false, code: "ABDM_M2_PUSH_URL_INVALID", error: "dataPushUrl must not contain a query string" };
  }
  if (url.hash) {
    return { ok: false, code: "ABDM_M2_PUSH_URL_INVALID", error: "dataPushUrl must not contain a fragment" };
  }

  const hostname = url.hostname.toLowerCase();
  if (isLocalOrPrivateHost(hostname) || isMetadataHostname(hostname)) {
    return {
      ok: false,
      code: "ABDM_M2_PUSH_URL_PRIVATE",
      error: "dataPushUrl must not target localhost, private, link-local or metadata endpoints",
    };
  }

  if (resolveDns) {
    let records: string[];
    try {
      records = await resolveDns(hostname);
    } catch (_) {
      return {
        ok: false,
        code: "ABDM_M2_PUSH_URL_DNS",
        error: "dataPushUrl hostname could not be resolved",
      };
    }
    if (records.length === 0) {
      return {
        ok: false,
        code: "ABDM_M2_PUSH_URL_DNS",
        error: "dataPushUrl hostname resolved to no addresses",
      };
    }
    for (const record of records) {
      if (isLocalOrPrivateHost(record)) {
        return {
          ok: false,
          code: "ABDM_M2_PUSH_URL_PRIVATE",
          error: "dataPushUrl resolves to a private or reserved address",
        };
      }
    }
  }

  return { ok: true, url: trimmed };
}

// ----------------------------------------------------------------------------
// Bounded, redirect-safe HTTPS push to the HIU dataPushUrl
// ----------------------------------------------------------------------------

export interface M2PushResponse {
  ok: boolean;
  status: number;
  contentType: string | null;
}

export const M2_PUSH_TIMEOUT_MS = 15_000;
export const M2_PUSH_MAX_BYTES = 512_000;
const M2_PUSH_MAX_REDIRECTS = 3;

export async function m2SafePush(
  fetchImpl: FetchImpl,
  dataPushUrl: string,
  body: unknown,
  options: { timeoutMs?: number; maxBytes?: number; resolveDns?: DnsResolver } = {},
): Promise<M2PushResponse> {
  const timeoutMs = options.timeoutMs ?? M2_PUSH_TIMEOUT_MS;
  const maxBytes = options.maxBytes ?? M2_PUSH_MAX_BYTES;

  let target = dataPushUrl;
  for (let redirects = 0; redirects <= M2_PUSH_MAX_REDIRECTS; redirects++) {
    const validation = await validateDataPushUrl(target, options.resolveDns);
    if (!validation.ok || !validation.url) {
      throw new Error(validation.error ?? "dataPushUrl is not safe");
    }

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);

    let response: Response;
    try {
      response = await fetchImpl(validation.url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          // SECURITY: no ABDM Authorization / X-CM-ID / X-HIP-ID headers are
          // ever forwarded to the HIU dataPushUrl.
        },
        body: JSON.stringify(body),
        redirect: "manual",
        signal: controller.signal,
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (/timeout|abort/i.test(message)) {
        throw new Error("dataPushUrl request timed out");
      }
      throw new Error("dataPushUrl request failed");
    } finally {
      clearTimeout(timer);
    }

    if (response.status >= 300 && response.status < 400) {
      const location = response.headers.get("location");
      if (!location) {
        return { ok: false, status: response.status, contentType: response.headers.get("content-type") };
      }
      target = new URL(location, validation.url).toString();
      continue;
    }

    const declared = Number(response.headers.get("content-length") ?? "0");
    if (Number.isFinite(declared) && declared > maxBytes) {
      throw new Error("dataPushUrl response exceeded the size limit");
    }
    const text = await response.text();
    if (text.length > maxBytes) {
      throw new Error("dataPushUrl response exceeded the size limit");
    }

    return {
      ok: response.ok,
      status: response.status,
      contentType: response.headers.get("content-type"),
    };
  }

  throw new Error("dataPushUrl redirect limit exceeded");
}

// ----------------------------------------------------------------------------
// Job execution
// ----------------------------------------------------------------------------

export const M2_MAX_TRANSFER_ATTEMPTS = 5;
export const M2_JOB_LEASE_SECONDS = 60;

export interface M2TransferExecutorOptions {
  now?: () => Date;
  leaseOwner?: string;
  maxAttempts?: number;
  leaseSeconds?: number;
  resolveDns?: DnsResolver;
}

function retryBackoffMs(attempts: number): number {
  return Math.min(30_000 * Math.pow(2, Math.max(0, attempts - 1)), 15 * 60 * 1000);
}

function retryableStatus(status: number): boolean {
  return status === 408 || status === 425 || status === 429 || status >= 500;
}

/**
 * Executes ONE already-claimed job through the official V3 data-transfer
 * lifecycle. This function never throws for expected failure paths — it
 * persists the next state (retryable or terminal) and returns the updated row.
 */
export async function executeM2DataTransferJob(
  job: M2DataTransferJobRow,
  runtime: M2ProcessRuntime,
  options: M2TransferExecutorOptions = {},
): Promise<M2DataTransferJobRow> {
  const now = options.now?.() ?? new Date();
  const maxAttempts = options.maxAttempts ?? M2_MAX_TRANSFER_ATTEMPTS;
  const leaseSeconds = options.leaseSeconds ?? M2_JOB_LEASE_SECONDS;
  const leaseOwner = options.leaseOwner ?? "worker";

  async function persist(update: Partial<M2DataTransferJobRow>): Promise<void> {
    const merged: M2DataTransferJobRow = {
      ...job,
      ...update,
      last_attempt_at: now.toISOString(),
    };
    const result = await runtime.dataTransferJobStore.upsert(merged);
    if (result.error) {
      throw new Error(`Data-transfer job update failed: ${result.error.message}`);
    }
    job = merged;
  }

  async function terminal(
    code: string,
    message: string,
    attempts = (job.attempts ?? 0) + 1,
  ): Promise<M2DataTransferJobRow> {
    await persist({
      status: M2_JOB_STATUS.FAILED_SAFE,
      attempts,
      error_code: code,
      error_message: message,
      lease_owner: null,
      lease_expires_at: null,
      next_retry_at: null,
    });
    return job;
  }

  async function retryable(code: string, message: string): Promise<M2DataTransferJobRow> {
    const attempts = (job.attempts ?? 0) + 1;
    if (attempts >= maxAttempts) {
      return terminal(code, message, attempts);
    }
    const retryAt = new Date(now.getTime() + retryBackoffMs(attempts)).toISOString();
    await persist({
      status: M2_JOB_STATUS.QUEUED,
      attempts,
      error_code: code,
      error_message: message,
      lease_owner: null,
      lease_expires_at: null,
      next_retry_at: retryAt,
    });
    return job;
  }

  // 1. Hospital ownership of the job.
  if (job.hospital_id !== runtime.hospital.hospitalId) {
    return terminal("ABDM_M2_JOB_HOSPITAL_MISMATCH", "Data-transfer job does not belong to this hospital");
  }

  // 2. Consent + FHIR payload must still be valid.
  const consent = await runtime.consentStore.findByConsentId(job.consent_id);
  const careContextHiTypes = (job.care_context_hi_types ?? []).length > 0
    ? job.care_context_hi_types
    : (job.care_context_references ?? []).map(() => "HealthDocumentRecord");
  const consentCheck = consent
    ? validateConsentForTransfer({
      consent,
      careContextRefs: job.care_context_references ?? [],
      careContextHiTypes,
      now,
    })
    : { ok: false, code: M2_ERROR_CODES.CONSENT_INVALID, error: "Consent artefact not found" };
  if (!consentCheck.ok) {
    return terminal(consentCheck.code ?? M2_ERROR_CODES.CONSENT_INVALID, consentCheck.error ?? "Consent is not valid");
  }
  if (!job.fhir_bundle) {
    return terminal(M2_ERROR_CODES.SOURCE_DATA_ABSENT, "FHIR bundle is missing for the data-transfer job");
  }

  // 3. Encrypt (STOPPED in production until the official vector exists).
  await persist({ status: M2_JOB_STATUS.PREPARING });
  const encryptor = runtime.encryptor;
  if (!encryptor || encryptor.available !== true) {
    return terminal(
      M2_ERROR_CODES.ENCRYPTION_UNAVAILABLE,
      "Official ABDM V3 encryption is not available in this runtime",
    );
  }
  const keyMaterial = job.key_material as unknown as M2HealthInformationRequest["keyMaterial"];
  const keyCheck = validateM2KeyMaterial(keyMaterial);
  if (!keyCheck.ok) {
    return terminal(keyCheck.code ?? M2_ERROR_CODES.ENCRYPTION_UNAVAILABLE, keyCheck.error ?? "Invalid key material");
  }
  const encryption = await encryptor.encrypt(
    job.fhir_bundle,
    keyMaterial,
    job.care_context_references ?? [],
  );
  if (!encryption.ok || !encryption.entries || !encryption.keyMaterial) {
    return terminal(encryption.code ?? M2_ERROR_CODES.ENCRYPTION_UNAVAILABLE, encryption.message ?? "Encryption failed");
  }
  await persist({
    status: M2_JOB_STATUS.ENCRYPTED,
    encrypted_entries: encryption.entries as unknown as Record<string, unknown>[],
  });

  // 4. Push to the HIU dataPushUrl (SSRF-guarded, bounded redirects).
  const pushUrl = job.data_push_url ?? "";
  const pushBody = {
    pageNumber: 0,
    pageCount: 1,
    transactionId: job.transaction_id,
    entries: encryption.entries,
    keyMaterial: encryption.keyMaterial,
  };
  await persist({ status: M2_JOB_STATUS.PUSHING });
  let pushResponse: M2PushResponse;
  try {
    pushResponse = await m2SafePush(runtime.fetchImpl, pushUrl, pushBody, {
      resolveDns: options.resolveDns,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return retryable("ABDM_M2_PUSH_FAILED", message);
  }
  if (!pushResponse.ok) {
    if (retryableStatus(pushResponse.status)) {
      return retryable(
        `ABDM_M2_PUSH_${pushResponse.status}`,
        `dataPushUrl returned HTTP ${pushResponse.status}`,
      );
    }
    return terminal(
      `ABDM_M2_PUSH_${pushResponse.status}`,
      `dataPushUrl rejected the transfer (HTTP ${pushResponse.status})`,
    );
  }
  await persist({ status: M2_JOB_STATUS.PUSHED });

  // 5. Final ABDM health-information notify (canonical V3 client).
  await persist({ status: M2_JOB_STATUS.NOTIFYING });
  const hipId = runtime.hospital.facilityId;
  const notifyBody = buildHealthInformationNotifyBody({
    consentId: job.consent_id,
    transactionId: job.transaction_id,
    doneAt: new Date().toISOString(),
    hipId,
    sessionStatus: "TRANSFERRED",
    statusResponses: (job.care_context_references ?? []).map((ref) => ({
      careContextReference: ref,
      hiStatus: "DELIVERED",
      description: "Done",
    })),
  });
  let notifyResponse: GatewayHttpResponse;
  try {
    notifyResponse = await m2GatewayPost(
      runtime.fetchImpl,
      runtime.config,
      runtime.v3TokenCache,
      hipId,
      V3_M2_HEALTH_INFORMATION_NOTIFY_PATH,
      notifyBody,
    );
  } catch (_) {
    return retryable("ABDM_M2_NOTIFY_FAILED", "ABDM health-information notify request failed");
  }
  if (!notifyResponse.ok) {
    if (retryableStatus(notifyResponse.status)) {
      return retryable(
        `ABDM_M2_NOTIFY_${notifyResponse.status}`,
        `ABDM health-information notify returned HTTP ${notifyResponse.status}`,
      );
    }
    return terminal(
      `ABDM_M2_NOTIFY_${notifyResponse.status}`,
      `ABDM health-information notify was rejected (HTTP ${notifyResponse.status})`,
    );
  }

  await persist({
    status: M2_JOB_STATUS.COMPLETED,
    notification_status: "sent",
    attempts: (job.attempts ?? 0) + 1,
    error_code: null,
    error_message: null,
    lease_owner: null,
    lease_expires_at: null,
    next_retry_at: null,
  });
  return job;
}

/**
 * Claims and executes up to `limit` due jobs for the current hospital. Used
 * inline after a new job is queued (and can be reused by a future scheduled
 * trigger) so transient failures are retried safely without double execution.
 */
export async function executeDueM2DataTransferJobs(
  runtime: M2ProcessRuntime,
  options: M2TransferExecutorOptions & { limit?: number } = {},
): Promise<number> {
  const limit = options.limit ?? 3;
  const leaseOwner = options.leaseOwner ??
    `worker-${crypto.randomUUID?.() ?? Date.now()}`;
  let executed = 0;
  for (let i = 0; i < limit; i++) {
    const now = options.now?.() ?? new Date();
    const job = await runtime.dataTransferJobStore.claimDue(
      now.toISOString(),
      leaseOwner,
      options.leaseSeconds ?? M2_JOB_LEASE_SECONDS,
      runtime.hospital.hospitalId,
    );
    if (!job) break;
    await executeM2DataTransferJob(job, runtime, { ...options, leaseOwner });
    executed++;
  }
  return executed;
}
