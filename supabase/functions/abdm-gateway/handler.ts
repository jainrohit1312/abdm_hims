// ============================================================================
// ABDM Gateway Edge Function — request handler (testable, no Supabase SDK)
// ----------------------------------------------------------------------------
// This module contains the full HTTP request handling logic and depends only
// on `core.ts` + the injected dependencies in `RequestDeps`, so `deno test`
// can exercise routing, auth and ABDM contract behaviour without loading the
// Supabase JS SDK.
// ============================================================================

import {
  ABDM_M1_CONTRACT_UNCONFIRMED,
  acquireV3AccessToken,
  buildCallbackRow,
  buildV3EnvelopeInspection,
  type CallbackRow,
  createV3Session,
  extractV3BridgeId,
  extractV3BridgeServiceById,
  type FetchImpl,
  FUNCTION_NAME,
  type GatewayConfig,
  type GatewayHttpResponse,
  gatewayRequest,
  getSubpath,
  hfrPostAddUpdateServices,
  type HfrGatewayHttpResponse,
  type HfrUpstreamSummary,
  type HfrUpstreamShape,
  hostnameOfUrl,
  interpretHfrUpstreamResponse,
  summarizeHfrUpstreamShape,
  type InternalAction,
  isAdminRole,
  isM1ActionName,
  isM1ContractConfigured,
  isM1RoleAllowed,
  isReservedSubpath,
  isValidAadhaar,
  isValidAbhaAddress,
  isValidAbhaNumber,
  isValidIndianMobile,
  isValidM1Otp,
  type M1Action,
  maskClientId,
  MAX_BODY_BYTES,
  normalizeAbhaNumber,
  parseV3ServicesResponse,
  persistCallback,
  readConfig,
  readHeader,
  readJsonBody,
  redactSensitiveText,
  resolveInternalAction,
  sanitizePayload,
  SlidingWindowRateLimiter,
  type TokenCacheRef,
  V3_GATEWAY_BASE_URL,
  V3_GATEWAY_BRIDGE_SERVICES_PATH,
  V3_GATEWAY_BRIDGE_SERVICE_BY_ID_PATH,
  V3_GATEWAY_BRIDGE_URL_PATH,
  V3_GATEWAY_SESSION_PATH,
  type V3BridgeInspectResult,
  type V3DiagnosticResult,
  type V3FailureCategory,
  v3FailureCode,
  v3FailureMessage,
  v3GatewayRequest,
  v3GetBridgeServiceById,
  v3GetBridgeServices,
  type V3Stage,
  type V3TokenCacheRef,
  type V3TokenRecord,
  validateCallbackBaseUrl,
  validateHfrLinkageInput,
  validateServicesPayload,
} from "./core.ts";
import { GatewayError, HttpError } from "./core.ts";

// Supabase Edge Runtime exposes `waitUntil` so async callback persistence can
// finish after the response is sent. Plain Deno (local tests) does not have it.
declare const EdgeRuntime:
  | { waitUntil?: (promise: Promise<unknown>) => void }
  | undefined;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, request-id, timestamp",
  // PATCH must be explicitly advertised, otherwise the browser blocks the
  // preflighted Bridge PATCH request after a 200 OPTIONS. The Supabase
  // Flutter/Web Functions client sends the preflight method token as lowercase
  // `patch`, so the exact lowercase token is advertised alongside the
  // uppercase methods used by other clients.
  "Access-Control-Allow-Methods": "GET, POST, PATCH, OPTIONS, patch",
};

function jsonResponse(
  body: unknown,
  status = 200,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
      ...extraHeaders,
    },
  });
}

export interface AuthenticatedUser {
  authId: string;
  userId: string;
  role: string;
  hospitalId: string | null;
}

/**
 * Server-side M1 continuation transaction. The ABDM `txnId` is bound to the
 * Supabase user, hospital and operation so a browser-supplied transaction id
 * can never be replayed by another operator. OTP and raw Aadhaar are NEVER
 * persisted here.
 */
export interface M1Transaction {
  transactionId: string;
  userId: string;
  hospitalId: string;
  operation: string;
  expiresAt: string;
  consumedAt: string | null;
}

export interface M1TransactionStore {
  findByTransactionId(transactionId: string): Promise<M1Transaction | null>;
  markConsumed(transactionId: string): Promise<void>;
}

/**
 * Hospital-specific ABDM/HFR settings resolved server-side for the current
 * hospital. Never supplied by the Flutter client.
 */
export interface HospitalAbdmSettings {
  /** HFR facility id — used as the ABDM V3 service-id. */
  facilityId: string;
  /** Official facility name (hospitals.name). */
  facilityName: string;
  /** Short ABDM HIP name configured per facility. */
  hipName: string;
}

export interface HospitalAbdmSettingsStore {
  getByHospitalId(hospitalId: string): Promise<HospitalAbdmSettings | null>;
}

export interface RequestDeps {
  env: Record<string, string | undefined>;
  fetchImpl: FetchImpl;
  /** Manual Supabase JWT validation for protected internal actions. */
  authenticate: (
    req: Request,
    env: Record<string, string | undefined>,
  ) => Promise<AuthenticatedUser>;
  /** Persist a sanitized callback row (service-role). */
  persistCallbackRow: (row: CallbackRow) => Promise<void>;
  /** Injectable rate limiter for public callback routes. */
  callbackRateLimiter?: SlidingWindowRateLimiter;
  /** Injectable ABDM token cache (tests pass a fresh one per case). */
  tokenCache?: TokenCacheRef;
  /** Injectable canonical V3 token cache (SEPARATE from legacy tokenCache). */
  v3TokenCache?: V3TokenCacheRef;
  /** Injectable M1 OTP-sensitive rate limiter (per user + operation). */
  m1OtpRateLimiter?: SlidingWindowRateLimiter;
  /** Injectable M1 general rate limiter (per user + operation). */
  m1RateLimiter?: SlidingWindowRateLimiter;
  /** Server-side M1 transaction binding store (production: Supabase table). */
  m1TransactionStore?: M1TransactionStore;
  /** Server-side hospital ABDM/HFR settings store (production: hospitals table). */
  hospitalAbdmSettingsStore?: HospitalAbdmSettingsStore;
  /** Injectable throttling for the isolated V3 diagnostic (per user). */
  v3DiagnosticRateLimiter?: SlidingWindowRateLimiter;
}

// Default worker-scoped ABDM token cache (memory only, never returned).
// LEGACY v0.5/v1 cache — used ONLY by the legacy addUpdateServices flow.
const defaultTokenCache: TokenCacheRef = { current: null };

// Canonical V3 token cache (worker memory, never returned). This cache is
// intentionally SEPARATE from `defaultTokenCache`; legacy and V3 tokens must
// never be mixed.
const defaultV3TokenCache: V3TokenCacheRef = { current: null };

// Default best-effort per-worker limiter: 120 public callbacks/minute/IP.
const defaultCallbackRateLimiter = new SlidingWindowRateLimiter(60_000, 120);

// OTP-sensitive M1 endpoints are heavily throttled per user+operation so an
// operator (or a compromised session) cannot mint duplicate OTPs/accounts.
const defaultM1OtpRateLimiter = new SlidingWindowRateLimiter(60_000, 5);
const defaultM1RateLimiter = new SlidingWindowRateLimiter(60_000, 20);

// The isolated V3 diagnostic is limited to at most one session POST + one
// services GET per click, and is additionally throttled per user. LIMITATION:
// like every SlidingWindowRateLimiter in this function, the window is
// worker-local (per isolate). A cold start or concurrent isolate can reset the
// count; the hard per-request sequence limit (1 session + 1 services call) is
// still enforced inside the handler itself.
const defaultV3DiagnosticRateLimiter = new SlidingWindowRateLimiter(60_000, 5);

/**
 * Structured sanitized error returned by M1 handlers. The `code` is preserved
 * in the JSON response so Flutter can map it to the ABDM_M1_* error contract.
 */
class M1StructuredError extends HttpError {
  readonly code: string;
  readonly supportReference?: string;

  constructor(
    status: number,
    code: string,
    message: string,
    supportReference?: string,
  ) {
    super(status, message);
    this.code = code;
    this.supportReference = supportReference;
  }
}

// ----------------------------------------------------------------------------
// Request handler
// ----------------------------------------------------------------------------

export async function handleRequest(
  req: Request,
  deps: RequestDeps,
): Promise<Response> {
  // Normalize once so routing, callback dispatch and authorization decisions
  // are case-insensitive. The outbound ABDM request method is chosen
  // separately (and explicitly stays uppercase PATCH for the Bridge call).
  const method = req.method.toUpperCase();

  if (method === "OPTIONS") {
    // Preflight must succeed without Supabase auth and advertise every method
    // the browser may follow up with (GET/POST/PATCH/OPTIONS/patch).
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  const url = new URL(req.url);
  const subpath = getSubpath(url.toString(), FUNCTION_NAME);
  const queryAction = url.searchParams.get("action") ?? undefined;

  const bodyResult = await readJsonBody(req, MAX_BODY_BYTES);
  if (!bodyResult.ok) {
    return jsonResponse(
      { error: bodyResult.error ?? "Invalid request body" },
      bodyResult.status ?? 400,
    );
  }
  const body = bodyResult.body;

  const action = resolveInternalAction(
    method,
    subpath,
    typeof body["action"] === "string" ? (body["action"] as string) : undefined,
    queryAction,
  );

  try {
    if (action) {
      return await handleInternalAction(req, method, action, body, deps);
    }

    if (method === "POST") {
      if (!subpath) {
        return jsonResponse(
          { error: "Callback subpath is required for public POST callbacks" },
          404,
        );
      }
      if (isReservedSubpath(subpath)) {
        return jsonResponse(
          { error: "Method not allowed for this reserved path" },
          405,
        );
      }
      return await handleCallback(req, body, subpath, deps);
    }

    return jsonResponse(
      {
        error:
          "Not found. Use /session, /bridge, /services, /health or POST a callback subpath.",
      },
      404,
    );
  } catch (error) {
    // SECURITY: never log request bodies / headers — only a redacted message.
    const rawMessage = error instanceof Error ? error.message : String(error);
    const message = redactSensitiveText(rawMessage);
    const status = error instanceof HttpError ? error.status : 500;
    console.error(`abdm-gateway error (status ${status}): ${message}`);
    if (error instanceof M1StructuredError) {
      return jsonResponse(
        {
          error: message,
          code: error.code,
          ...(error.supportReference
            ? { supportReference: error.supportReference }
            : {}),
        },
        status,
      );
    }
    return jsonResponse({ error: message }, status);
  }
}

// ----------------------------------------------------------------------------
// Internal (protected) actions
// ----------------------------------------------------------------------------

async function handleInternalAction(
  req: Request,
  method: string,
  action: InternalAction,
  body: Record<string, unknown>,
  deps: RequestDeps,
): Promise<Response> {
  const config = requireConfig(deps.env);

  // Every internal action requires a valid HIMS user session (manual JWT
  // validation because this function is deployed with verify_jwt = false).
  const user = await deps.authenticate(req, deps.env);

  // M1 (ABHA identity) operations use the patient-facing M1 permission policy
  // (configurable allow-list, default super_admin/admin/receptionist) and
  // require a hospital context. Session / Bridge / Services stay owner-only.
  if (isM1ActionName(action)) {
    return handleM1Action(action, user, body, deps, req, config);
  }

  // Session / Bridge / Services are owner-only (hospital admin / super_admin).
  if (action !== "health") {
    requireAdmin(user.role);
  }

  switch (action) {
    case "session":
      return handleSession(config, deps);
    case "bridge":
      return handleBridge(config, body, deps, req);
    case "services":
      return method === "GET"
        ? handleInspectServices(config, deps, req)
        : handlePostServices(config, body, deps, req, user);
    case "getServices":
      // Production Flutter path: POST {"action":"getServices"} on the bare
      // function URL (avoids browser method-casing/CORS preflight issues).
      return handleInspectServices(config, deps, req);
    case "diagnoseV3Gateway":
      // Isolated V3 session + bridge-services diagnostic. Explicitly a
      // protected internal action — it can never fall through to the public
      // callback route (see resolveInternalAction + isReservedSubpath).
      return handleV3GatewayDiagnostic(config, body, deps, req, user);
    case "inspectV3Bridge":
      // Read-only V3 bridge envelope inspection. Same session + GET
      // bridge-services flow, but it describes the real response shape and
      // never performs any ABDM mutation.
      return handleV3BridgeInspect(config, body, deps, req, user);
    case "health":
      return jsonResponse({
        status: "ok",
        service: "abdm-gateway",
        baseUrl: config.baseUrl,
        clientId: maskClientId(config.clientId),
        secretsConfigured: true,
        timestamp: new Date().toISOString(),
      });
  }
}

function requireConfig(env: Record<string, string | undefined>): GatewayConfig {
  const result = readConfig(env);
  if (!result.ok || !result.config) {
    // Never echo the missing secret VALUES (only the names).
    const problems = [
      ...(result.missing.length > 0
        ? [`Missing Edge Function secrets: ${result.missing.join(", ")}`]
        : []),
      ...result.errors,
    ];
    throw new HttpError(500, problems.join("; "));
  }
  return result.config;
}

function requireAdmin(role: string): void {
  if (!isAdminRole(role)) {
    throw new HttpError(
      403,
      "Owner / super-admin role required for this action",
    );
  }
}

// ----------------------------------------------------------------------------
// M1 (ABHA identity) actions — protected, contract-gated
// ----------------------------------------------------------------------------

function m1Record(value: unknown): Record<string, unknown> {
  if (typeof value === "object" && value !== null && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }
  return {};
}

function m1Text(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

/** Reads the Flutter `{"action": "...", "payload": {...}}` payload safely. */
function m1Payload(body: Record<string, unknown>): Record<string, unknown> {
  const nested = m1Record(body["payload"]);
  return Object.keys(nested).length > 0 ? nested : body;
}

function requireM1Access(user: AuthenticatedUser, config: GatewayConfig): void {
  if (!user.hospitalId) {
    throw new M1StructuredError(
      403,
      "ABDM_M1_FORBIDDEN",
      "No hospital is assigned to your account. ABHA M1 operations require a hospital context.",
    );
  }
  if (!isM1RoleAllowed(user.role, config.m1AllowedRoles)) {
    throw new M1StructuredError(
      403,
      "ABDM_M1_FORBIDDEN",
      "Your role is not allowed to perform ABHA M1 operations.",
    );
  }
}

function m1InputError(
  message: string,
  supportReference?: string,
): M1StructuredError {
  return new M1StructuredError(
    400,
    "ABDM_M1_INVALID_INPUT",
    message,
    supportReference,
  );
}

/**
 * Stops an M1 operation because the official client-supplied Sandbox M1/ABHA
 * contract has not been confirmed/configured. This is deliberate: no M1
 * endpoint path, method, request body, header set or encryption format is
 * invented by this project.
 */
function requireM1Contract(
  config: GatewayConfig,
  action: M1Action,
  supportReference?: string,
): void {
  if (!isM1ContractConfigured(config, action)) {
    throw new M1StructuredError(
      501,
      ABDM_M1_CONTRACT_UNCONFIRMED,
      `M1 operation "${action}" is blocked: the official ABDM Sandbox M1/ABHA contract for this client has not been confirmed. ` +
        `Configure ABDM_M1_BASE_URL and the official ${action} endpoint path only after the contract is supplied.`,
      supportReference,
    );
  }
}

function m1RateLimiterFor(
  deps: RequestDeps,
  action: M1Action,
): SlidingWindowRateLimiter {
  const otpSensitive = action === "m1GenerateAadhaarOtp" ||
    action === "m1VerifyAadhaarOtp";
  if (otpSensitive) return deps.m1OtpRateLimiter ?? defaultM1OtpRateLimiter;
  return deps.m1RateLimiter ?? defaultM1RateLimiter;
}

function enforceM1RateLimit(
  deps: RequestDeps,
  user: AuthenticatedUser,
  action: M1Action,
): void {
  const limiter = m1RateLimiterFor(deps, action);
  if (!limiter.allow(`${user.userId}:${action}`)) {
    throw new M1StructuredError(
      429,
      "ABDM_M1_RATE_LIMITED",
      "Too many ABHA M1 requests. Please wait a moment and try again.",
    );
  }
}

/**
 * Binds a continuation step (verify OTP / create ABHA) to a server-side
 * transaction owned by the current user, hospital and operation. Expired,
 * consumed or foreign transactions are rejected — a browser-supplied txnId is
 * never trusted blindly. OTP and raw Aadhaar are never part of the record.
 */
async function requireActiveM1Transaction(
  deps: RequestDeps,
  user: AuthenticatedUser,
  action: M1Action,
  transactionId: string,
): Promise<void> {
  const store = deps.m1TransactionStore;
  if (!store) {
    throw new HttpError(500, "M1 transaction store is not configured");
  }

  const record = await store.findByTransactionId(transactionId);
  if (!record) {
    throw new M1StructuredError(
      410,
      "ABDM_M1_TRANSACTION_EXPIRED",
      "The ABHA transaction is missing or has expired. Please generate a fresh OTP and try again.",
    );
  }
  if (record.userId !== user.userId || record.hospitalId !== user.hospitalId) {
    throw new M1StructuredError(
      403,
      "ABDM_M1_TRANSACTION_EXPIRED",
      "The ABHA transaction does not belong to the current user and hospital.",
    );
  }
  if (
    record.operation !== action && !(
      (action === "m1VerifyAadhaarOtp" || action === "m1CreateAbha") &&
      record.operation === "m1GenerateAadhaarOtp"
    )
  ) {
    throw new M1StructuredError(
      400,
      "ABDM_M1_INVALID_INPUT",
      "The ABHA transaction is not valid for this operation.",
    );
  }
  if (record.consumedAt !== null) {
    throw new M1StructuredError(
      410,
      "ABDM_M1_TRANSACTION_EXPIRED",
      "The ABHA transaction has already been used.",
    );
  }
  const expiresAt = Date.parse(record.expiresAt);
  if (!Number.isFinite(expiresAt) || expiresAt <= Date.now()) {
    throw new M1StructuredError(
      410,
      "ABDM_M1_TRANSACTION_EXPIRED",
      "The ABHA transaction has expired. Please generate a fresh OTP and try again.",
    );
  }
  await store.markConsumed(transactionId);
}

async function handleM1Action(
  action: M1Action,
  user: AuthenticatedUser,
  body: Record<string, unknown>,
  deps: RequestDeps,
  req: Request,
  config: GatewayConfig,
): Promise<Response> {
  requireM1Access(user, config);
  const requestId = safeRequestId(req);
  const payload = m1Payload(body);

  switch (action) {
    case "m1GenerateAadhaarOtp": {
      const aadhaar = m1Text(payload["aadhaarNumber"] ?? payload["aadhaar"]);
      if (!isValidAadhaar(aadhaar)) {
        throw m1InputError(
          "Aadhaar number must be exactly 12 numeric digits.",
          requestId,
        );
      }
      enforceM1RateLimit(deps, user, action);
      // SECURITY: the Aadhaar value is validated, then discarded. It is never
      // logged, never persisted and never returned. Encryption is implemented
      // only when the official contract confirms the exact mechanism.
      requireM1Contract(config, action, requestId);
      /* never reached until the official contract is configured */
      break;
    }
    case "m1VerifyAadhaarOtp": {
      const transactionId = m1Text(
        payload["txnId"] ?? payload["transactionId"],
      );
      const otp = m1Text(payload["otp"]);
      if (!transactionId) {
        throw m1InputError(
          "Transaction id is required. Please generate an OTP first.",
          requestId,
        );
      }
      if (!isValidM1Otp(otp)) {
        throw m1InputError("OTP must be exactly 6 digits.", requestId);
      }
      enforceM1RateLimit(deps, user, action);
      await requireActiveM1Transaction(deps, user, action, transactionId);
      requireM1Contract(config, action, requestId);
      /* never reached until the official contract is configured */
      break;
    }
    case "m1CreateAbha": {
      const transactionId = m1Text(
        payload["txnId"] ?? payload["transactionId"],
      );
      if (!transactionId) {
        throw m1InputError(
          "Transaction id is required. Please verify the Aadhaar OTP first.",
          requestId,
        );
      }
      // Preferred ABHA Address (not Number) may be supplied where the official
      // flow allows choosing an address. Ignored until the contract confirms it.
      const preferredAbhaAddress = m1Text(
        payload["preferredAbhaAddress"] ?? payload["abhaAddress"],
      );
      if (
        preferredAbhaAddress &&
        !isValidAbhaAddress(preferredAbhaAddress, config.m1AbhaAddressSuffixes)
      ) {
        throw m1InputError("Preferred ABHA Address is not valid.", requestId);
      }
      enforceM1RateLimit(deps, user, action);
      await requireActiveM1Transaction(deps, user, action, transactionId);
      requireM1Contract(config, action, requestId);
      /* never reached until the official contract is configured */
      break;
    }
    case "m1GetProfile": {
      const abhaNumber = m1Text(payload["abhaNumber"] ?? payload["healthId"]);
      const abhaAddress = m1Text(payload["abhaAddress"]);
      if (!abhaNumber && !abhaAddress) {
        throw m1InputError(
          "Either an ABHA number or an ABHA address is required.",
          requestId,
        );
      }
      if (abhaNumber && !isValidAbhaNumber(abhaNumber)) {
        throw m1InputError(
          "ABHA number must be 14 digits (dashes optional).",
          requestId,
        );
      }
      if (
        abhaAddress &&
        !isValidAbhaAddress(abhaAddress, config.m1AbhaAddressSuffixes)
      ) {
        throw m1InputError("ABHA address is not valid.", requestId);
      }
      enforceM1RateLimit(deps, user, action);
      requireM1Contract(config, action, requestId);
      break;
    }
    case "m1VerifyAbhaNumber": {
      const abhaNumber = m1Text(payload["abhaNumber"] ?? payload["healthId"]);
      if (!isValidAbhaNumber(abhaNumber)) {
        throw m1InputError(
          "ABHA number must be 14 digits (dashes optional).",
          requestId,
        );
      }
      enforceM1RateLimit(deps, user, action);
      requireM1Contract(config, action, requestId);
      break;
    }
    case "m1SearchByMobile": {
      const mobile = m1Text(payload["mobile"] ?? payload["mobileNumber"]);
      if (!isValidIndianMobile(mobile)) {
        throw m1InputError(
          "Mobile number must be a valid 10-digit Indian mobile.",
          requestId,
        );
      }
      enforceM1RateLimit(deps, user, action);
      requireM1Contract(config, action, requestId);
      break;
    }
    case "m1VerifyAbhaAddress": {
      const abhaAddress = m1Text(payload["abhaAddress"]);
      if (!isValidAbhaAddress(abhaAddress, config.m1AbhaAddressSuffixes)) {
        throw m1InputError("ABHA address is not valid.", requestId);
      }
      enforceM1RateLimit(deps, user, action);
      requireM1Contract(config, action, requestId);
      break;
    }
    case "m1GetAbhaCard": {
      const abhaAddress = m1Text(payload["abhaAddress"]);
      if (!isValidAbhaAddress(abhaAddress, config.m1AbhaAddressSuffixes)) {
        throw m1InputError("ABHA address is not valid.", requestId);
      }
      enforceM1RateLimit(deps, user, action);
      requireM1Contract(config, action, requestId);
      break;
    }
    case "m1GetAbhaQr": {
      const abhaAddress = m1Text(payload["abhaAddress"]);
      if (!isValidAbhaAddress(abhaAddress, config.m1AbhaAddressSuffixes)) {
        throw m1InputError("ABHA address is not valid.", requestId);
      }
      enforceM1RateLimit(deps, user, action);
      requireM1Contract(config, action, requestId);
      break;
    }
  }

  // When the official contract is configured this line is reached only because
  // the outbound request builder (method/body/headers from the client-supplied
  // contract) has deliberately not been hard-coded. It must be implemented
  // from the confirmed contract — never guessed.
  throw new HttpError(
    501,
    "M1 outbound call is not implemented: the official request method, body and headers for this operation must be built from the client-supplied contract.",
  );
}

async function handleSession(
  config: GatewayConfig,
  deps: RequestDeps,
): Promise<Response> {
  const v3Cache = deps.v3TokenCache ?? defaultV3TokenCache;
  let record: V3TokenRecord;
  try {
    record = await acquireV3AccessToken(deps.fetchImpl, config, v3Cache);
  } catch (error) {
    // SECURITY: the GatewayError body is already sanitized, but the client only
    // needs a useful message — never the raw ABDM token / Client Secret.
    if (error instanceof GatewayError) {
      throw sessionGatewayError(error);
    }
    throw error;
  }
  const remainingSeconds = Math.max(
    0,
    Math.floor((record.expiresAt - Date.now()) / 1000),
  );

  return jsonResponse({
    status: "connected",
    baseUrl: V3_GATEWAY_BASE_URL,
    clientId: maskClientId(config.clientId),
    sessionValidForSeconds: remainingSeconds,
    note:
      "ABDM V3 session established server-side. The raw token is never returned.",
  });
}

function sessionGatewayError(error: GatewayError): HttpError {
  if (error.status === 401 || error.status === 403) {
    return new HttpError(
      502,
      "ABDM authentication rejected: verify Client ID/rotated Client Secret",
    );
  }
  if (error.status === 0) {
    return new HttpError(
      502,
      "ABDM gateway unavailable. Check network connectivity and try again.",
    );
  }
  return new HttpError(
    502,
    `ABDM V3 session request failed with status ${error.status}`,
  );
}

/**
 * Logs exactly the allow-listed structured fields for the production V3
 * Bridge update action. Authorization headers, JWT, ABDM tokens, client
 * id/secret, X-CM-ID raw value and complete request/response bodies are NEVER
 * logged.
 */
function logV3BridgeUpdate(
  requestId: string,
  fields: {
    method: string;
    pathname: string;
    upstreamStatus?: number | null;
    code?: string | null;
    category?: "timeout" | "network" | "http" | "ok";
  },
): void {
  const entry: Record<string, unknown> = {
    operation: "bridge_update_v3",
    hostname: hostnameOfUrl(V3_GATEWAY_BASE_URL),
    method: fields.method,
    pathname: fields.pathname,
    category: fields.category ?? "http",
    requestId,
  };
  if (fields.upstreamStatus !== null && fields.upstreamStatus !== undefined) {
    entry.upstreamStatus = fields.upstreamStatus;
  }
  if (fields.code) entry.code = fields.code;
  console.log(`abdm-gateway bridge_update_v3 ${JSON.stringify(entry)}`);
}

/** Returns a safe request id for diagnostics (validated inbound or generated). */
function safeRequestId(req: Request): string {
  const inbound = readHeader(
    req.headers,
    "x-request-id",
    "x-request_id",
    "request-id",
  );
  if (inbound && /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(inbound)) {
    return inbound;
  }
  try {
    if (typeof crypto !== "undefined" && crypto.randomUUID) {
      return `req_${crypto.randomUUID()}`;
    }
  } catch (_) {
    // fall through to timestamp-based id
  }
  return `req_${Date.now().toString(36)}_${
    Math.random().toString(36).slice(2, 10)
  }`;
}

/** Builds a sanitized 502 response for the production V3 Bridge action. */
function v3BridgeFailureResponse(
  requestId: string,
  code: string,
  message: string,
  upstreamStatus: number | null,
  category: "timeout" | "network" | "http" = "http",
): Response {
  logV3BridgeUpdate(requestId, {
    method: "PATCH",
    pathname: V3_GATEWAY_BRIDGE_URL_PATH,
    upstreamStatus,
    code,
    category,
  });
  return jsonResponse(
    {
      error: message,
      code,
      ...(upstreamStatus !== null ? { upstreamStatus } : {}),
      supportReference: requestId,
    },
    502,
  );
}

function v3BridgeGatewayErrorCode(
  error: GatewayError,
): { code: string; message: string } {
  if (error.category === "timeout") {
    return {
      code: "ABDM_BRIDGE_TIMEOUT",
      message: "ABDM V3 Bridge update timed out before receiving a response.",
    };
  }
  if (error.category === "network") {
    return {
      code: "ABDM_BRIDGE_NETWORK",
      message: "ABDM V3 Bridge update failed: the ABDM gateway is unreachable.",
    };
  }
  if (error.status === 401 || error.status === 403) {
    return {
      code: `ABDM_BRIDGE_${error.status}`,
      message:
        "ABDM authentication rejected: verify Client ID/rotated Client Secret",
    };
  }
  return {
    code: `ABDM_BRIDGE_${error.status}`,
    message: `ABDM V3 Bridge update failed (HTTP ${error.status}).`,
  };
}

/**
 * Production Bridge URL configuration. Uses the official V3 mutation endpoint:
 *
 *   PATCH /api/hiecm/gateway/v3/bridge/url
 *   Authorization: Bearer <fresh V3 token>
 *   REQUEST-ID / TIMESTAMP / X-CM-ID / Content-Type as per the README
 *   body: { "url": "<ABDM_CALLBACK_BASE_URL>" }
 */
async function handleBridge(
  config: GatewayConfig,
  body: Record<string, unknown>,
  deps: RequestDeps,
  req: Request,
): Promise<Response> {
  // SECURITY: the callback URL may ONLY come from the ABDM_CALLBACK_BASE_URL
  // Edge Function secret. A client-supplied callbackUrl/url is rejected so the
  // ABDM Bridge can never be redirected to an arbitrary endpoint.
  if (body["callbackUrl"] !== undefined || body["url"] !== undefined) {
    throw new HttpError(
      400,
      "Client-supplied callbackUrl is not allowed. The Bridge URL is set from ABDM_CALLBACK_BASE_URL.",
    );
  }

  if (!config.callbackBaseUrl) {
    throw new HttpError(
      500,
      "Missing ABDM_CALLBACK_BASE_URL Edge Function secret",
    );
  }

  const validation = validateCallbackBaseUrl(config.callbackBaseUrl);
  if (!validation.ok) {
    throw new HttpError(
      400,
      validation.error ?? "Invalid ABDM_CALLBACK_BASE_URL",
    );
  }

  const requestId = safeRequestId(req);
  const callbackUrl = config.callbackBaseUrl.trim();
  const v3Cache = deps.v3TokenCache ?? defaultV3TokenCache;

  let response: GatewayHttpResponse;
  try {
    response = await v3GatewayRequest(
      deps.fetchImpl,
      config,
      v3Cache,
      "PATCH",
      V3_GATEWAY_BRIDGE_URL_PATH,
      { url: callbackUrl },
    );
  } catch (error) {
    if (error instanceof GatewayError) {
      const mapped = v3BridgeGatewayErrorCode(error);
      return v3BridgeFailureResponse(
        requestId,
        mapped.code,
        mapped.message,
        error.status === 0 ? null : error.status,
        error.category,
      );
    }
    throw error;
  }

  if (!response.ok) {
    const status = response.status || 0;
    return v3BridgeFailureResponse(
      requestId,
      status === 0 ? "ABDM_BRIDGE_NETWORK" : `ABDM_BRIDGE_${status}`,
      `ABDM V3 Bridge update failed (HTTP ${status}).`,
      status === 0 ? null : status,
    );
  }

  logV3BridgeUpdate(requestId, {
    method: "PATCH",
    pathname: V3_GATEWAY_BRIDGE_URL_PATH,
    upstreamStatus: response.status,
    code: "ABDM_BRIDGE_OK",
    category: "ok",
  });

  return jsonResponse({
    status: "bridge_configured",
    baseUrl: V3_GATEWAY_BASE_URL,
    callbackUrl,
    gateway: sanitizePayload(response.data),
  });
}

/** Builds a sanitized 502 response for the production V3 getServices action. */
function v3GetServicesFailureResponse(
  requestId: string,
  code: string,
  message: string,
  upstreamStatus: number | null,
  category: "timeout" | "network" | "http" = "http",
): Response {
  const entry: Record<string, unknown> = {
    operation: "get_services_v3",
    hostname: hostnameOfUrl(V3_GATEWAY_BASE_URL),
    method: "GET",
    pathname: V3_GATEWAY_BRIDGE_SERVICES_PATH,
    code,
    category,
    requestId,
  };
  if (upstreamStatus !== null) entry.upstreamStatus = upstreamStatus;
  console.log(`abdm-gateway get_services_v3 ${JSON.stringify(entry)}`);
  return jsonResponse(
    {
      error: message,
      code,
      ...(upstreamStatus !== null ? { upstreamStatus } : {}),
      supportReference: requestId,
    },
    502,
  );
}

function v3GetServicesGatewayErrorCode(
  error: GatewayError,
): { code: string; message: string } {
  if (error.category === "timeout") {
    return {
      code: "ABDM_GET_SERVICES_TIMEOUT",
      message: "ABDM V3 getServices timed out before receiving a response.",
    };
  }
  if (error.category === "network") {
    return {
      code: "ABDM_GET_SERVICES_NETWORK",
      message: "ABDM V3 getServices failed: the ABDM gateway is unreachable.",
    };
  }
  if (error.status === 403) {
    return {
      code: "ABDM_GET_SERVICES_403",
      message:
        "ABDM V3 getServices failed: access was denied for this request.",
    };
  }
  if (error.status === 401) {
    return {
      code: "ABDM_GET_SERVICES_401",
      message:
        "ABDM V3 getServices failed: the ABDM access token was not accepted (HTTP 401).",
    };
  }
  return {
    code: `ABDM_GET_SERVICES_${error.status}`,
    message: `ABDM V3 getServices failed (HTTP ${error.status}).`,
  };
}

/**
 * Production Bridge/services inspection. Uses the official V3 read endpoint:
 * GET /api/hiecm/gateway/v3/bridge-services with the V3 token, then returns
 * only the sanitized envelope (top-level type, safe field names, bridge/URL
 * presence, sanitized service id/name/type/active).
 */
async function handleInspectServices(
  config: GatewayConfig,
  deps: RequestDeps,
  req: Request,
): Promise<Response> {
  const requestId = safeRequestId(req);
  const v3Cache = deps.v3TokenCache ?? defaultV3TokenCache;

  let response: GatewayHttpResponse;
  try {
    response = await v3GatewayRequest(
      deps.fetchImpl,
      config,
      v3Cache,
      "GET",
      V3_GATEWAY_BRIDGE_SERVICES_PATH,
    );
  } catch (error) {
    if (error instanceof GatewayError) {
      const mapped = v3GetServicesGatewayErrorCode(error);
      return v3GetServicesFailureResponse(
        requestId,
        mapped.code,
        mapped.message,
        error.status === 0 ? null : error.status,
        error.category,
      );
    }
    throw error;
  }

  if (!response.ok) {
    const status = response.status || 0;
    const mapped = v3GetServicesGatewayErrorCode(
      new GatewayError(
        status,
        `V3 getServices failed (HTTP ${status}).`,
        undefined,
        "http",
        {
          method: "GET",
          hostname: hostnameOfUrl(V3_GATEWAY_BASE_URL),
          pathname: V3_GATEWAY_BRIDGE_SERVICES_PATH,
        },
      ),
    );
    return v3GetServicesFailureResponse(
      requestId,
      mapped.code,
      mapped.message,
      status === 0 ? null : status,
    );
  }

  const envelope = buildV3EnvelopeInspection(response.data);
  const serviceCount = envelope.services.length;
  const entry: Record<string, unknown> = {
    operation: "get_services_v3",
    hostname: hostnameOfUrl(V3_GATEWAY_BASE_URL),
    method: "GET",
    pathname: V3_GATEWAY_BRIDGE_SERVICES_PATH,
    upstreamStatus: response.status,
    code: "ABDM_GET_SERVICES_OK",
    requestId,
  };
  if (serviceCount !== null) entry.serviceCount = serviceCount;
  console.log(`abdm-gateway get_services_v3 ${JSON.stringify(entry)}`);

  return jsonResponse({
    status: "services_fetched_v3",
    upstreamStatus: response.status,
    serviceCount,
    services: envelope.services.items,
    envelope,
    supportReference: requestId,
  });
}

// ----------------------------------------------------------------------------
// Isolated V3 gateway diagnostic (session POST + bridge-services GET)
// ----------------------------------------------------------------------------

const V3_FORBIDDEN_OVERRIDE_KEYS = new Set([
  "origin",
  "baseurl",
  "url",
  "path",
  "sessionpath",
  "servicespath",
  "headers",
  "credentials",
  "cmid",
  "cmcontext",
  "xcmid",
  "accesstoken",
  "token",
  "authorization",
  "clientid",
  "clientsecret",
]);

function normalizeV3BodyKey(key: string): string {
  return key.toLowerCase().replace(/[^a-z0-9]/g, "");
}

function v3UpstreamHostname(): string {
  return new URL(V3_GATEWAY_BASE_URL).hostname;
}

/**
 * Builds an allow-listed failure result. Only stage, upstream status, code,
 * short message and metadata are returned — never raw bodies, headers, the
 * V3 token, client id/secret or any patient information.
 */
function v3FailureResult(
  requestId: string,
  stage: "session" | "services",
  category: V3FailureCategory,
  status: number | null,
  sessionUpstreamStatus: number | null,
  startedAt: number,
): V3DiagnosticResult {
  const pathname = stage === "session"
    ? V3_GATEWAY_SESSION_PATH
    : V3_GATEWAY_BRIDGE_SERVICES_PATH;
  const method = stage === "session" ? "POST" : "GET";
  const code = v3FailureCode(stage, status ?? 0, category);
  return {
    operation: "diagnoseV3Gateway",
    environment: "sandbox",
    sessionSucceeded: stage === "services",
    sessionUpstreamStatus,
    servicesSucceeded: false,
    servicesUpstreamStatus: stage === "services" ? status : null,
    serviceCount: null,
    services: [],
    supportReference: requestId,
    stage,
    code,
    message: v3FailureMessage(stage, status ?? 0, category),
    upstreamHostname: v3UpstreamHostname(),
    method,
    pathname,
    category,
    durationMs: Date.now() - startedAt,
  };
}

/**
 * Logs exactly the allow-listed V3 diagnostic fields. Tokens, credentials,
 * headers and request/response bodies are never logged.
 */
function logV3Diagnostic(result: V3DiagnosticResult): void {
  const entry: Record<string, unknown> = {
    operation: result.operation,
    stage: result.stage,
    hostname: result.upstreamHostname,
    method: result.method,
    pathname: result.pathname,
    durationMs: result.durationMs,
    category: result.category,
    supportReference: result.supportReference,
  };
  if (result.code) entry.code = result.code;
  if (result.sessionUpstreamStatus !== null) {
    entry.sessionUpstreamStatus = result.sessionUpstreamStatus;
  }
  if (result.servicesUpstreamStatus !== null) {
    entry.servicesUpstreamStatus = result.servicesUpstreamStatus;
  }
  if (result.serviceCount !== null) entry.serviceCount = result.serviceCount;
  console.log(`abdm-gateway v3_diagnostic ${JSON.stringify(entry)}`);
}

function v3DiagnosticResponse(result: V3DiagnosticResult): Response {
  logV3Diagnostic(result);
  return jsonResponse(result);
}

async function handleV3GatewayDiagnostic(
  config: GatewayConfig,
  body: Record<string, unknown>,
  deps: RequestDeps,
  req: Request,
  user: AuthenticatedUser,
): Promise<Response> {
  const requestId = safeRequestId(req);

  // SECURITY: origin, path, headers, credentials, CM context, tokens and
  // client credentials are fixed server-side for this diagnostic. Any attempt
  // to supply them from the request is rejected before any ABDM call.
  for (const key of Object.keys(body)) {
    if (V3_FORBIDDEN_OVERRIDE_KEYS.has(normalizeV3BodyKey(key))) {
      throw new HttpError(
        400,
        "Client-supplied V3 origin/path/headers/credentials/CM context/token overrides are not allowed.",
      );
    }
  }

  const limiter = deps.v3DiagnosticRateLimiter ??
    defaultV3DiagnosticRateLimiter;
  if (!limiter.allow(`${user.userId}:diagnoseV3Gateway`)) {
    throw new HttpError(
      429,
      "Too many V3 gateway diagnostics. Please wait a moment and try again.",
    );
  }

  const startedAt = Date.now();

  // Stage 1: the single production V3 session implementation
  // (`createV3Session`) performs the official POST with fresh UUID/timestamp.
  // Diagnostics intentionally bypass the V3 cache: one session POST per click.
  const sessionResult = await createV3Session(deps.fetchImpl, config);
  if (!sessionResult.ok) {
    return v3DiagnosticResponse(
      v3FailureResult(
        requestId,
        "session",
        sessionResult.category,
        sessionResult.status,
        sessionResult.status,
        startedAt,
      ),
    );
  }

  // SECURITY: the fresh V3 token is request-local. It is never cached,
  // persisted, logged or returned, and the legacy v0.5/v1 token cache is never
  // read, written or invalidated by this diagnostic.
  const sessionUpstreamStatus = sessionResult.upstreamStatus;

  // Stage 2: production V3 GET bridge-services with the token obtained above.
  let servicesResponse: GatewayHttpResponse;
  try {
    servicesResponse = await v3GetBridgeServices(
      deps.fetchImpl,
      sessionResult.token,
    );
  } catch (error) {
    if (error instanceof GatewayError) {
      const status = error.status === 0 ? null : error.status;
      return v3DiagnosticResponse(
        v3FailureResult(
          requestId,
          "services",
          error.category,
          status,
          sessionUpstreamStatus,
          startedAt,
        ),
      );
    }
    throw error;
  }

  if (!servicesResponse.ok) {
    return v3DiagnosticResponse(
      v3FailureResult(
        requestId,
        "services",
        "http",
        servicesResponse.status,
        sessionUpstreamStatus,
        startedAt,
      ),
    );
  }

  const servicesParse = parseV3ServicesResponse(servicesResponse.data);
  if (servicesParse.kind === "unexpected") {
    return v3DiagnosticResponse(
      v3FailureResult(
        requestId,
        "services",
        "protocol",
        servicesResponse.status,
        sessionUpstreamStatus,
        startedAt,
      ),
    );
  }

  const result: V3DiagnosticResult = {
    operation: "diagnoseV3Gateway",
    environment: "sandbox",
    sessionSucceeded: true,
    sessionUpstreamStatus,
    servicesSucceeded: true,
    servicesUpstreamStatus: servicesResponse.status,
    serviceCount: servicesParse.services.length,
    services: servicesParse.services,
    supportReference: requestId,
    stage: "complete",
    code: "ABDM_V3_OK",
    message:
      "V3 session and services inspection succeeded. Bridge URL configuration has not been changed.",
    upstreamHostname: v3UpstreamHostname(),
    method: "GET",
    pathname: V3_GATEWAY_BRIDGE_SERVICES_PATH,
    category: "ok",
    durationMs: Date.now() - startedAt,
  };
  return v3DiagnosticResponse(result);
}

// ----------------------------------------------------------------------------
// Read-only V3 bridge envelope inspection (inspectV3Bridge)
// ----------------------------------------------------------------------------

function v3InspectFailureResult(
  requestId: string,
  stage: "session" | "services",
  category: V3FailureCategory,
  status: number | null,
  sessionUpstreamStatus: number | null,
  startedAt: number,
): V3BridgeInspectResult {
  const pathname = stage === "session"
    ? V3_GATEWAY_SESSION_PATH
    : V3_GATEWAY_BRIDGE_SERVICES_PATH;
  const method = stage === "session" ? "POST" : "GET";
  const code = v3FailureCode(stage, status ?? 0, category);
  return {
    operation: "inspectV3Bridge",
    environment: "sandbox",
    sessionSucceeded: stage === "services",
    sessionUpstreamStatus,
    servicesSucceeded: false,
    servicesUpstreamStatus: stage === "services" ? status : null,
    supportReference: requestId,
    stage,
    code,
    message: v3FailureMessage(stage, status ?? 0, category),
    upstreamHostname: v3UpstreamHostname(),
    method,
    pathname,
    category,
    durationMs: Date.now() - startedAt,
    envelope: null,
  };
}

/** Logs only the allow-listed, shape-level fields of the bridge inspection. */
function logV3BridgeInspect(result: V3BridgeInspectResult): void {
  const entry: Record<string, unknown> = {
    operation: result.operation,
    stage: result.stage,
    hostname: result.upstreamHostname,
    method: result.method,
    pathname: result.pathname,
    durationMs: result.durationMs,
    category: result.category,
    supportReference: result.supportReference,
  };
  if (result.code) entry.code = result.code;
  if (result.sessionUpstreamStatus !== null) {
    entry.sessionUpstreamStatus = result.sessionUpstreamStatus;
  }
  if (result.servicesUpstreamStatus !== null) {
    entry.servicesUpstreamStatus = result.servicesUpstreamStatus;
  }
  if (result.envelope) {
    entry.topLevelType = result.envelope.topLevelType;
    if (result.envelope.services.length !== null) {
      entry.servicesLength = result.envelope.services.length;
    }
  }
  console.log(`abdm-gateway v3_bridge_inspect ${JSON.stringify(entry)}`);
}

function v3InspectResponse(result: V3BridgeInspectResult): Response {
  logV3BridgeInspect(result);
  return jsonResponse(result);
}

/**
 * Read-only V3 Bridge inspection. Reuses the exact V3 session + GET
 * bridge-services implementation of the existing diagnostic, but instead of
 * counting recognized services it returns a sanitized shape-only description
 * of the real bridge-services response. It never calls PATCH /bridge/url,
 * addUpdateServices or any other mutation endpoint.
 */
async function handleV3BridgeInspect(
  config: GatewayConfig,
  body: Record<string, unknown>,
  deps: RequestDeps,
  req: Request,
  user: AuthenticatedUser,
): Promise<Response> {
  const requestId = safeRequestId(req);

  // SECURITY: identical override protection as diagnoseV3Gateway — origin,
  // path, headers, credentials, CM context and tokens are fixed server-side.
  for (const key of Object.keys(body)) {
    if (V3_FORBIDDEN_OVERRIDE_KEYS.has(normalizeV3BodyKey(key))) {
      throw new HttpError(
        400,
        "Client-supplied V3 origin/path/headers/credentials/CM context/token overrides are not allowed.",
      );
    }
  }

  const limiter = deps.v3DiagnosticRateLimiter ??
    defaultV3DiagnosticRateLimiter;
  if (!limiter.allow(`${user.userId}:inspectV3Bridge`)) {
    throw new HttpError(
      429,
      "Too many V3 bridge inspections. Please wait a moment and try again.",
    );
  }

  const startedAt = Date.now();

  // Stage 1: single production V3 session implementation, no cache — one
  // session POST per inspection click.
  const sessionResult = await createV3Session(deps.fetchImpl, config);
  if (!sessionResult.ok) {
    return v3InspectResponse(
      v3InspectFailureResult(
        requestId,
        "session",
        sessionResult.category,
        sessionResult.status,
        sessionResult.status,
        startedAt,
      ),
    );
  }

  // SECURITY: request-local fresh V3 token; legacy cache never touched.
  const sessionUpstreamStatus = sessionResult.upstreamStatus;

  // Stage 2: production V3 GET bridge-services with the fresh token.
  let servicesResponse: GatewayHttpResponse;
  try {
    servicesResponse = await v3GetBridgeServices(
      deps.fetchImpl,
      sessionResult.token,
    );
  } catch (error) {
    if (error instanceof GatewayError) {
      const status = error.status === 0 ? null : error.status;
      return v3InspectResponse(
        v3InspectFailureResult(
          requestId,
          "services",
          error.category,
          status,
          sessionUpstreamStatus,
          startedAt,
        ),
      );
    }
    throw error;
  }

  if (!servicesResponse.ok) {
    return v3InspectResponse(
      v3InspectFailureResult(
        requestId,
        "services",
        "http",
        servicesResponse.status,
        sessionUpstreamStatus,
        startedAt,
      ),
    );
  }

  const result: V3BridgeInspectResult = {
    operation: "inspectV3Bridge",
    environment: "sandbox",
    sessionSucceeded: true,
    sessionUpstreamStatus,
    servicesSucceeded: true,
    servicesUpstreamStatus: servicesResponse.status,
    supportReference: requestId,
    stage: "complete",
    code: "ABDM_V3_OK",
    message:
      "V3 Bridge inspection succeeded. Bridge URL configuration has not been changed.",
    upstreamHostname: v3UpstreamHostname(),
    method: "GET",
    pathname: V3_GATEWAY_BRIDGE_SERVICES_PATH,
    category: "ok",
    durationMs: Date.now() - startedAt,
    envelope: buildV3EnvelopeInspection(servicesResponse.data),
  };
  return v3InspectResponse(result);
}

// ----------------------------------------------------------------------------
// HFR facility/HIP linkage (production POST `services` action)
// ----------------------------------------------------------------------------

const HFR_FORBIDDEN_OVERRIDE_KEYS = new Set([
  "facilityid",
  "facilityname",
  "bridgeid",
  "hipname",
  "hrp",
  "url",
  "baseurl",
  "path",
  "headers",
  "authorization",
  "accesstoken",
  "token",
  "clientid",
  "clientsecret",
  "cmid",
  "xcmid",
]);

function normalizeHfrBodyKey(key: string): string {
  return key.toLowerCase().replace(/[^a-z0-9]/g, "");
}

/** Logs only allow-listed HFR linkage fields (never headers/body/tokens). */
function logHfrLinkage(
  requestId: string,
  fields: {
    method: string;
    pathname: string;
    code?: string | null;
    upstreamStatus?: number | null;
    category?: "timeout" | "network" | "http" | "ok";
  },
): void {
  const entry: Record<string, unknown> = {
    operation: "hfr_linkage",
    hostname: "apihspsbx.abdm.gov.in",
    method: fields.method,
    pathname: fields.pathname,
    category: fields.category ?? "http",
    requestId,
  };
  if (fields.upstreamStatus !== null && fields.upstreamStatus !== undefined) {
    entry.upstreamStatus = fields.upstreamStatus;
  }
  if (fields.code) entry.code = fields.code;
  console.log(`abdm-gateway hfr_linkage ${JSON.stringify(entry)}`);
}

function hfrUpstreamJson(summary: HfrUpstreamSummary): Record<string, unknown> {
  return {
    status: summary.status,
    contentType: summary.contentType,
    bodyType: summary.bodyType,
    code: summary.code,
    statusField: summary.statusField,
    message: summary.message,
    facilityId: summary.facilityId,
    bridgeId: summary.bridgeId,
    ...(summary.errorMessage !== null ? { errorMessage: summary.errorMessage } : {}),
    ...(summary.errorCode !== null ? { errorCode: summary.errorCode } : {}),
    ...(summary.errorKeys.length > 0 ? { errorKeys: summary.errorKeys } : {}),
  };
}

/**
 * Single sanitized log line for the live HFR array-error shape. Never includes
 * tokens, secrets, headers, Aadhaar, OTP or patient data.
 */
function logHfrUpstreamError(
  requestId: string,
  summary: HfrUpstreamSummary,
  facilityId: string,
  bridgeId: string,
): void {
  const entry: Record<string, unknown> = {
    operation: "hfr_upstream_error",
    supportReference: requestId,
    upstreamStatus: summary.status,
    facilityId,
    bridgeId,
    errorCode: summary.errorCode,
    errorMessage: summary.errorMessage,
  };
  console.log(`abdm-gateway hfr_upstream_error ${JSON.stringify(entry)}`);
}

/**
 * Single server-side log line for the HFR upstream response SHAPE. Key names
 * are safe to log; no primitive values, tokens or secrets are included.
 */
function logHfrUpstreamShape(
  requestId: string,
  shape: HfrUpstreamShape,
): void {
  const entry: Record<string, unknown> = {
    operation: "hfr_upstream_shape",
    supportReference: requestId,
    rootType: shape.rootType,
    topLevelKeys: shape.topLevelKeys,
    firstItemKeys: shape.firstItemKeys,
    dataKeys: shape.dataKeys,
    resultKeys: shape.resultKeys,
  };
  console.log(`abdm-gateway hfr_upstream_shape ${JSON.stringify(entry)}`);
}

/**
 * Single server-side log line for the HFR upstream response. Only whitelisted
 * safe fields are logged — never tokens, secrets, headers, Aadhaar, OTP or
 * patient data.
 */
function logHfrUpstreamResponse(
  requestId: string,
  summary: HfrUpstreamSummary,
  facilityId: string,
  bridgeId: string,
): void {
  const entry: Record<string, unknown> = {
    operation: "hfr_upstream_response",
    supportReference: requestId,
    upstreamStatus: summary.status,
    upstreamCode: summary.code,
    upstreamMessage: summary.message,
    facilityId,
    bridgeId,
  };
  console.log(`abdm-gateway hfr_upstream_response ${JSON.stringify(entry)}`);
}

function hfrFailureResponse(
  requestId: string,
  code: string,
  message: string,
  upstreamStatus: number | null,
  category: "timeout" | "network" | "http" = "http",
  hfrUpstream?: Record<string, unknown>,
  hfrUpstreamShape?: Record<string, unknown>,
): Response {
  logHfrLinkage(requestId, {
    method: "POST",
    pathname: "/v1/bridges/MutipleHRPAddUpdateServices",
    upstreamStatus,
    code,
    category,
  });
  return jsonResponse(
    {
      error: message,
      code,
      ...(upstreamStatus !== null ? { upstreamStatus } : {}),
      ...(hfrUpstream ? { hfrUpstream } : {}),
      ...(hfrUpstreamShape ? { hfrUpstreamShape } : {}),
      supportReference: requestId,
    },
    502,
  );
}

function hfrErrorMapping(
  error: GatewayError,
): { code: string; message: string } {
  if (error.category === "timeout") {
    return {
      code: "HFR_LINKAGE_TIMEOUT",
      message: "ABDM HFR linkage timed out before receiving a response.",
    };
  }
  if (error.category === "network") {
    return {
      code: "HFR_LINKAGE_NETWORK",
      message: "ABDM HFR linkage failed: the HFR service is unreachable.",
    };
  }
  if (error.status === 401 || error.status === 403) {
    return {
      code: "HFR_AUTH_REJECTED",
      message:
        "ABDM HFR linkage was rejected: the V3 gateway access token was not accepted by HFR.",
    };
  }
  return {
    code: `HFR_LINKAGE_${error.status}`,
    message: `ABDM HFR linkage failed (HTTP ${error.status}).`,
  };
}

/**
 * Sanitized failure response for the preflight "configured bridge id vs live
 * bridge.id" verification. Never includes tokens, secrets or raw bodies.
 */
function hfrBridgeVerifyFailureResponse(
  requestId: string,
  code: string,
  message: string,
  upstreamStatus: number | null,
): Response {
  logHfrLinkage(requestId, {
    method: "GET",
    pathname: V3_GATEWAY_BRIDGE_SERVICES_PATH,
    code,
    upstreamStatus,
    category: "http",
  });
  return jsonResponse(
    {
      error: message,
      code,
      ...(upstreamStatus !== null ? { upstreamStatus } : {}),
      supportReference: requestId,
    },
    502,
  );
}

/**
 * Before the HFR mutation, verifies the configured ABDM_BRIDGE_ID against the
 * live `bridge.id` returned by the canonical V3 GET bridge-services endpoint.
 *
 * - mismatch        -> ABDM_BRIDGE_ID_MISMATCH (STOP, no HFR POST)
 * - id unavailable  -> ABDM_BRIDGE_ID_UNAVAILABLE (STOP, no HFR POST)
 * - match           -> proceeds
 *
 * Never reads the deprecated legacy token cache and never falls back to a
 * legacy API.
 */
async function verifyConfiguredBridgeId(
  deps: RequestDeps,
  token: string,
  configuredBridgeId: string,
  requestId: string,
): Promise<{ ok: boolean; response?: Response }> {
  let bridgeServicesResponse: GatewayHttpResponse;
  try {
    bridgeServicesResponse = await v3GetBridgeServices(deps.fetchImpl, token);
  } catch (error) {
    if (error instanceof GatewayError) {
      return {
        ok: false,
        response: hfrBridgeVerifyFailureResponse(
          requestId,
          "ABDM_BRIDGE_ID_UNAVAILABLE",
          "ABDM bridge-services could not be read before HFR linkage; bridge id verification is required.",
          error.status === 0 ? null : error.status,
        ),
      };
    }
    throw error;
  }

  if (!bridgeServicesResponse.ok) {
    return {
      ok: false,
      response: hfrBridgeVerifyFailureResponse(
        requestId,
        "ABDM_BRIDGE_ID_UNAVAILABLE",
        `ABDM bridge-services returned HTTP ${bridgeServicesResponse.status}; bridge id verification is required before HFR linkage.`,
        bridgeServicesResponse.status,
      ),
    };
  }

  const liveBridgeId = extractV3BridgeId(bridgeServicesResponse.data);
  if (!liveBridgeId) {
    return {
      ok: false,
      response: hfrBridgeVerifyFailureResponse(
        requestId,
        "ABDM_BRIDGE_ID_UNAVAILABLE",
        "ABDM bridge-services response did not provide bridge.id; refusing to run HFR linkage with an unverified bridge id.",
        bridgeServicesResponse.status,
      ),
    };
  }

  if (liveBridgeId !== configuredBridgeId.trim()) {
    return {
      ok: false,
      response: hfrBridgeVerifyFailureResponse(
        requestId,
        "ABDM_BRIDGE_ID_MISMATCH",
        "Configured ABDM_BRIDGE_ID does not match the live ABDM bridge.id; HFR linkage was not attempted.",
        bridgeServicesResponse.status,
      ),
    };
  }

  return { ok: true };
}

interface HfrVerificationOutcome {
  verified: boolean;
  byId: {
    serviceIdMatches: boolean;
    bridgeIdMatches: boolean | null;
    isHip: boolean;
    active: boolean;
  };
  bridgeServices: {
    containsFacility: boolean;
    containsHipType: boolean;
    active: boolean;
  };
  byIdUpstreamStatus: number | null;
  servicesUpstreamStatus: number | null;
}

/**
 * Performs exactly ONE verification sequence after an accepted HFR linkage:
 *   1. GET /api/hiecm/gateway/v3/bridge-service/serviceId/{facilityId}
 *   2. GET /api/hiecm/gateway/v3/bridge-services
 *
 * The two endpoints are INDEPENDENT signals:
 *   - by-id       -> bridgeId/serviceId/isHip/isHiu/active schema
 *   - services    -> id/types[]/active schema
 *
 * `isHip` is read from the by-id response only; bridge-services HIP status is
 * read from `types[]` only. Neither substitutes for the other. Verification
 * failures (including 404/network) are never retried and never fail the
 * accepted linkage — they produce a pending verification outcome.
 */
async function verifyHfrLinkageOnce(
  deps: RequestDeps,
  token: string,
  config: GatewayConfig,
  facilityId: string,
  bridgeId: string,
): Promise<HfrVerificationOutcome> {
  const facilityIdNormalized = facilityId.trim();

  let byIdEntry = null;
  let byIdUpstreamStatus: number | null = null;
  try {
    const byIdResponse = await v3GetBridgeServiceById(
      deps.fetchImpl,
      token,
      facilityIdNormalized,
    );
    byIdUpstreamStatus = byIdResponse.status;
    if (byIdResponse.ok) {
      byIdEntry = extractV3BridgeServiceById(byIdResponse.data);
    }
  } catch (_) {
    byIdUpstreamStatus = null;
  }

  let servicesParse: ReturnType<typeof parseV3ServicesResponse> = {
    kind: "recognized-empty",
    services: [],
  };
  let servicesUpstreamStatus: number | null = null;
  try {
    const servicesResponse = await v3GetBridgeServices(deps.fetchImpl, token);
    servicesUpstreamStatus = servicesResponse.status;
    if (servicesResponse.ok) {
      servicesParse = parseV3ServicesResponse(servicesResponse.data);
    }
  } catch (_) {
    servicesUpstreamStatus = null;
  }

  const byIdServiceIdMatches = byIdEntry?.serviceId === facilityIdNormalized;
  const byIdBridgeIdMatches = byIdEntry?.bridgeId
    ? byIdEntry.bridgeId === bridgeId.trim()
    : null;
  const byIdIsHip = byIdEntry?.isHip === true;
  const byIdActive = byIdEntry?.active === true;

  const matchingService = servicesParse.kind === "unexpected"
    ? null
    : servicesParse.services.find((service) =>
      service["id"] === facilityIdNormalized
    ) ?? null;
  const containsFacility = matchingService !== null;
  const containsHipType = Array.isArray(matchingService?.["types"]) &&
    (matchingService["types"] as string[]).includes("HIP");
  const servicesActive = matchingService?.["active"] === true;

  // All authoritative checks must be true. A missing/unknown by-id bridgeId
  // is NOT treated as verified: bridgeIdMatches must be exactly true.
  const verified = byIdEntry !== null &&
    byIdServiceIdMatches &&
    byIdBridgeIdMatches === true &&
    byIdIsHip &&
    byIdActive &&
    containsFacility &&
    containsHipType &&
    servicesActive;

  return {
    verified,
    byId: {
      serviceIdMatches: byIdServiceIdMatches,
      bridgeIdMatches: byIdBridgeIdMatches,
      isHip: byIdIsHip,
      active: byIdActive,
    },
    bridgeServices: {
      containsFacility,
      containsHipType,
      active: servicesActive,
    },
    byIdUpstreamStatus,
    servicesUpstreamStatus,
  };
}

/**
 * PRODUCTION facility/service registration action. Replaces the legacy
 * addUpdateServices call with the official HFR Multiple HRP API:
 *
 *   POST https://apihspsbx.abdm.gov.in/v4/int/v1/bridges/MutipleHRPAddUpdateServices
 *   Authorization: Bearer <canonical V3 gateway access token>
 *   body: { facilityId, facilityName, HRP: [{ bridgeId, hipName, type: "HIP", active: true }] }
 *
 * facilityId/facilityName/hipName come from the hospital's server-side ABDM
 * settings; bridgeId comes from ABDM_BRIDGE_ID. The deprecated v0.5/v1 token
 * cache is never read. On 401/403 the sanitized code HFR_AUTH_REJECTED is
 * returned and the legacy API is NOT attempted.
 */
async function handlePostServices(
  config: GatewayConfig,
  body: Record<string, unknown>,
  deps: RequestDeps,
  req: Request,
  user: AuthenticatedUser,
): Promise<Response> {
  const requestId = safeRequestId(req);

  // SECURITY: HFR linkage fields are fixed server-side. A client-supplied
  // facilityId/facilityName/bridgeId/hipName/HRP (or any origin/path/header/
  // token override) is rejected before any outbound request is built.
  for (const key of Object.keys(body)) {
    if (key === "action") continue;
    if (HFR_FORBIDDEN_OVERRIDE_KEYS.has(normalizeHfrBodyKey(key))) {
      throw new HttpError(
        400,
        "Client-supplied HFR/ABDM linkage fields are not allowed. Facility and bridge data is resolved server-side.",
      );
    }
  }

  if (!user.hospitalId) {
    throw new HttpError(
      403,
      "No hospital is assigned to your account. HFR facility/HIP linkage requires a hospital context.",
    );
  }

  const store = deps.hospitalAbdmSettingsStore;
  if (!store) {
    throw new HttpError(500, "Hospital ABDM settings store is not configured");
  }

  const settings = await store.getByHospitalId(user.hospitalId);
  if (!settings) {
    throw new HttpError(
      500,
      "Hospital ABDM/HFR settings are not configured for this hospital",
    );
  }

  const validation = validateHfrLinkageInput(
    {
      facilityId: settings.facilityId,
      facilityName: settings.facilityName,
      hipName: settings.hipName,
    },
    config.bridgeId,
  );
  if (!validation.ok || !validation.payload) {
    throw new HttpError(400, validation.errors.join("; "));
  }

  const payload = validation.payload;
  const v3Cache = deps.v3TokenCache ?? defaultV3TokenCache;

  // AUTHENTICATION RULE: canonical V3 gateway access token only. The
  // deprecated v0.5/v1 token cache is never read, written or invalidated.
  let tokenRecord: V3TokenRecord;
  try {
    tokenRecord = await acquireV3AccessToken(deps.fetchImpl, config, v3Cache);
  } catch (error) {
    if (error instanceof GatewayError) {
      const mapped = hfrErrorMapping(error);
      return hfrFailureResponse(
        requestId,
        mapped.code,
        mapped.message,
        error.status === 0 ? null : error.status,
        error.category,
      );
    }
    throw error;
  }

  // Correction 3: verify the configured ABDM_BRIDGE_ID against the live V3
  // bridge.id BEFORE any HFR mutation. A mismatch (or an unavailable bridge.id)
  // stops the flow with a sanitized code and never falls back to legacy APIs.
  const bridgeVerification = await verifyConfiguredBridgeId(
    deps,
    tokenRecord.accessToken,
    payload.HRP[0].bridgeId,
    requestId,
  );
  if (!bridgeVerification.ok) return bridgeVerification.response!;

  let response: HfrGatewayHttpResponse;
  try {
    response = await hfrPostAddUpdateServices(
      deps.fetchImpl,
      tokenRecord.accessToken,
      payload,
      config,
    );
  } catch (error) {
    if (error instanceof GatewayError) {
      const mapped = hfrErrorMapping(error);
      return hfrFailureResponse(
        requestId,
        mapped.code,
        mapped.message,
        error.status === 0 ? null : error.status,
        error.category,
      );
    }
    throw error;
  }

  // Sanitized diagnostic summary of the actual HFR upstream response.
  const interpretation = interpretHfrUpstreamResponse(response);
  const hfrUpstream = hfrUpstreamJson(interpretation.summary);
  const hfrShape = summarizeHfrUpstreamShape(response);
  const hfrUpstreamShape = hfrShape as unknown as Record<string, unknown>;
  logHfrUpstreamResponse(
    requestId,
    interpretation.summary,
    payload.facilityId,
    payload.HRP[0].bridgeId,
  );
  logHfrUpstreamShape(requestId, hfrShape);
  if (
    interpretation.summary.errorMessage !== null ||
    interpretation.summary.errorCode !== null ||
    interpretation.summary.errorKeys.length > 0
  ) {
    logHfrUpstreamError(
      requestId,
      interpretation.summary,
      payload.facilityId,
      payload.HRP[0].bridgeId,
    );
  }

  if (!response.ok) {
    const status = response.status || 0;
    if (status === 401 || status === 403) {
      // Do NOT retry with legacy credentials and do NOT fall back to the
      // deprecated addUpdateServices API.
      return hfrFailureResponse(
        requestId,
        "HFR_AUTH_REJECTED",
        "ABDM HFR linkage was rejected: the V3 gateway access token was not accepted by HFR.",
        status,
        "http",
        hfrUpstream,
        hfrUpstreamShape,
      );
    }
    return hfrFailureResponse(
      requestId,
      status === 0 ? "HFR_LINKAGE_NETWORK" : `HFR_LINKAGE_${status}`,
      `ABDM HFR linkage failed (HTTP ${status}).`,
      status === 0 ? null : status,
      "http",
      hfrUpstream,
      hfrUpstreamShape,
    );
  }

  // A 2xx status alone does NOT mean the linkage was accepted. The body must
  // semantically indicate success/accepted; an explicit failure/validation
  // body inside HTTP 200 is a distinct sanitized failure code, and an
  // unrecognized body never proceeds to verification.
  if (interpretation.disposition === "failure") {
    return hfrFailureResponse(
      requestId,
      "HFR_LINKAGE_REJECTED",
      "ABDM HFR returned a failure/validation response inside HTTP 200; linkage was not accepted.",
      response.status,
      "http",
      hfrUpstream,
      hfrUpstreamShape,
    );
  }
  if (interpretation.disposition === "unknown") {
    return hfrFailureResponse(
      requestId,
      "HFR_LINKAGE_UNRECOGNIZED",
      "ABDM HFR response did not semantically confirm acceptance; linkage was not treated as accepted.",
      response.status,
      "http",
      hfrUpstream,
      hfrUpstreamShape,
    );
  }

  // Semantically accepted by HFR. Run exactly ONE normal verification sequence.
  const verification = await verifyHfrLinkageOnce(
    deps,
    tokenRecord.accessToken,
    config,
    payload.facilityId,
    payload.HRP[0].bridgeId,
  );

  const verified = verification.verified;
  logHfrLinkage(requestId, {
    method: "POST",
    pathname: "/v1/bridges/MutipleHRPAddUpdateServices",
    upstreamStatus: response.status,
    code: verified ? "HFR_LINKAGE_OK" : "HFR_LINKAGE_PENDING",
    category: "ok",
  });

  return jsonResponse({
    status: verified
      ? "linkage_verified"
      : "linkage_accepted_verification_pending",
    code: verified ? "HFR_LINKAGE_OK" : "HFR_LINKAGE_PENDING",
    message: verified
      ? "HFR facility/HIP linkage accepted and verified."
      : "HFR facility/HIP linkage accepted; verification pending ABDM propagation.",
    facilityId: payload.facilityId,
    bridgeId: payload.HRP[0].bridgeId,
    hfrUpstream,
    hfrUpstreamShape,
    verification: {
      byId: {
        serviceIdMatches: verification.byId.serviceIdMatches,
        bridgeIdMatches: verification.byId.bridgeIdMatches,
        isHip: verification.byId.isHip,
        active: verification.byId.active,
      },
      bridgeServices: {
        containsFacility: verification.bridgeServices.containsFacility,
        containsHipType: verification.bridgeServices.containsHipType,
        active: verification.bridgeServices.active,
      },
      byIdUpstreamStatus: verification.byIdUpstreamStatus,
      servicesUpstreamStatus: verification.servicesUpstreamStatus,
    },
    supportReference: requestId,
  });
}

/**
 * LEGACY v0.5/v1 facility registration (addUpdateServices). Kept isolated and
 * intentionally NOT wired to any production action while the live HFR call is
 * pending confirmation.
 *
 * @deprecated Use the HFR Multiple HRP flow in `handlePostServices`. Delete
 * this function once a successful live HFR call is confirmed.
 */
export async function handleLegacyAddUpdateServices(
  config: GatewayConfig,
  body: Record<string, unknown>,
  deps: RequestDeps,
): Promise<Response> {
  const validation = validateServicesPayload(body, config.allowedServiceTypes);
  if (!validation.ok || !validation.services) {
    throw new HttpError(400, validation.errors.join("; "));
  }

  // LEGACY v0.5/v1 facility registration (addUpdateServices). Kept unchanged
  // and isolated: it continues to use the legacy token cache/flow.
  // Forward the exact addUpdateServices array body: id/name/type/active/alias/
  // endpoints[{address, connectionType, use}]. Nothing is renamed or converted.
  const response = await gatewayRequest(
    deps.fetchImpl,
    config,
    deps.tokenCache ?? defaultTokenCache,
    "POST",
    config.servicesPath,
    validation.services,
  );

  if (!response.ok) {
    throw new HttpError(
      response.status || 502,
      `ABDM service registration failed (${response.status})`,
    );
  }

  return jsonResponse({
    status: "service_registered",
    services: validation.services.map((service) => ({
      id: service.id,
      type: service.type,
    })),
    gateway: sanitizePayload(response.data),
  });
}

// ----------------------------------------------------------------------------
// Public ABDM callbacks (no Supabase JWT)
// ----------------------------------------------------------------------------

async function handleCallback(
  req: Request,
  body: Record<string, unknown>,
  subpath: string,
  deps: RequestDeps,
): Promise<Response> {
  const contentType = req.headers.get("Content-Type") ?? "";
  if (!contentType.toLowerCase().includes("application/json")) {
    return jsonResponse(
      { error: "Content-Type must be application/json" },
      415,
    );
  }

  const clientIp = req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    "unknown";
  const limiter = deps.callbackRateLimiter ?? defaultCallbackRateLimiter;
  if (!limiter.allow(clientIp)) {
    return jsonResponse({ error: "Too many callback requests" }, 429);
  }

  const requestId = readHeader(
    req.headers,
    "request-id",
    "x-request-id",
    "x-request_id",
  ) ?? (body["requestId"] as string | undefined) ??
    (body["request_id"] as string | undefined);

  const transactionId = (body["transactionId"] as string | undefined) ??
    (body["transaction_id"] as string | undefined) ??
    readHeader(req.headers, "transaction-id", "x-transaction-id");

  const callbackType = (body["callbackType"] as string | undefined) ??
    (body["requestType"] as string | undefined) ??
    (body["type"] as string | undefined) ??
    "unknown";

  const gatewayTimestamp = readHeader(req.headers, "timestamp", "x-timestamp");

  // NOTE: hospital_id is intentionally NOT read from the callback body.
  const row = buildCallbackRow({
    subpath,
    body,
    requestId,
    transactionId,
    callbackType,
    gatewayTimestamp,
  });

  // Persist without delaying the ABDM acknowledgement. In Supabase Edge
  // Runtime `waitUntil` keeps the isolate alive until the write completes.
  const persistPromise = deps.persistCallbackRow(row);
  if (typeof EdgeRuntime !== "undefined" && EdgeRuntime?.waitUntil) {
    EdgeRuntime.waitUntil(persistPromise);
  }

  return jsonResponse({ status: "ACK" }, 200);
}

// Re-exported for the production wiring in index.ts.
export { defaultTokenCache, persistCallback };
