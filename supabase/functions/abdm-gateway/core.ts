// ============================================================================
// ABDM Gateway Edge Function — shared core (pure logic + HTTP helpers)
// ----------------------------------------------------------------------------
// This module is intentionally free of `serve()` so the routing, sanitization,
// token-caching and persistence logic can be unit-tested with `deno test`
// without starting an HTTP server. `index.ts` is the only file that binds a
// request handler.
//
// SECURITY RULES IMPLEMENTED HERE
//   1. ABDM client id / secret are read ONLY from Edge Function secrets
//      (Deno.env). They are never returned to callers and never logged.
//   2. The raw ABDM access token is cached in worker memory only and is never
//      returned to Flutter / stored in the database / written to logs.
//   3. All persisted callback payloads pass through `sanitizePayload`.
//   4. Authorization headers are never stored or logged.
//
// CONTRACT STATUS (reviewed 2026-09-04)
//   Defaults below follow the ABDM onboarding email for the initial
//   Bridge-management endpoints. The session endpoint and the
//   allowed-service-type list are centrally configurable and remain marked
//   REQUIRES CONFIRMATION against the current official ABDM documentation
//   before any live Sandbox call is treated as verified.
// ============================================================================

export const FUNCTION_NAME = "abdm-gateway";

/** Default inbound body limit for internal + callback requests (256 KiB). */
export const MAX_BODY_BYTES = 262_144;

// ----------------------------------------------------------------------------
// Configuration
// ----------------------------------------------------------------------------

export interface GatewayConfig {
  /** ABDM gateway base URL. Default: https://dev.abdm.gov.in */
  baseUrl: string;
  /** Supabase Edge Function secret: ABDM_CLIENT_ID */
  clientId: string;
  /** Supabase Edge Function secret: ABDM_CLIENT_SECRET */
  clientSecret: string;
  /** Supabase Edge Function secret: ABDM_BRIDGE_ID (kept for audit/display) */
  bridgeId: string;
  /** Supabase Edge Function secret: ABDM_HIP_ID */
  hipId: string;
  /** Supabase Edge Function secret: ABDM_HIU_ID */
  hiuId: string;
  /** Supabase Edge Function secret: ABDM_CALLBACK_BASE_URL */
  callbackBaseUrl: string;
  /**
   * Session endpoint path. Default `/gateway/v1/sessions`.
   * The WorkingWithABDMapi guide also documents the v0.5 variant
   * `/gateway/v0.5/sessions` — REQUIRES CONFIRMATION from the current docs.
   * Override with ABDM_SESSION_PATH.
   */
  sessionPath: string;
  /**
   * Bridge update endpoint path. Default `/gateway/v1/bridges` (PATCH).
   * Per the onboarding email, do NOT append `/{bridgeId}` unless the current
   * official documentation explicitly requires it. Override with
   * ABDM_BRIDGE_PATH.
   */
  bridgePath: string;
  /**
   * Add/update services endpoint path.
   * Default `/gateway/v1/bridges/addUpdateServices` (POST, array body).
   * Override with ABDM_SERVICES_PATH.
   */
  servicesPath: string;
  /**
   * Get registered services endpoint path.
   * Default `/gateway/v1/bridges/getServices` (GET).
   * Override with ABDM_GET_SERVICES_PATH.
   */
  getServicesPath: string;
  /**
   * HFR software linkage base URL.
   * Default `https://apihspsbx.abdm.gov.in/v4/int`. Override with
   * ABDM_HFR_BASE_URL.
   */
  hfrBaseUrl: string;
  /**
   * HFR Multiple HRP AddUpdateServices endpoint path.
   * Default `/v1/bridges/MutipleHRPAddUpdateServices`. Override with
   * ABDM_HFR_SERVICES_PATH.
   */
  hfrServicesPath: string;
  /**
   * Official service types accepted for `services[].type`. Configurable via
   * ABDM_SERVICE_TYPES (comma-separated). Defaults to HIP,HIU — REQUIRES
   * CONFIRMATION from the onboarding email / current official docs.
   */
  allowedServiceTypes: string[];
  /**
   * Consent-manager context identifier for Bridge-management calls only
   * (PATCH bridges / GET getServices / POST addUpdateServices).
   *
   * Not a secret. Empty string disables the X-CM-ID header. Defaults to
   * `sbx` only when the ABDM_BASE_URL hostname is `dev.abdm.gov.in`.
   * Never read from the request — server-side configuration only.
   */
  cmId: string;
  /** Seconds subtracted from token expiry before it is considered stale. */
  tokenSafetyMarginSeconds: number;
  /**
   * ------------------------------------------------------------------------
   * M1 (ABHA identity) contract configuration — CONTRACT-GATED.
   * ------------------------------------------------------------------------
   * Every value below is intentionally EMPTY by default. An empty value means
   * "the official M1 contract for this client has not been confirmed yet", so
   * the corresponding M1 action is STOPPED with ABDM_M1_CONTRACT_UNCONFIRMED
   * before any outbound request is built. No endpoint path, method, request
   * body, header set or encryption format for M1 is invented by this project.
   *
   * When the client supplies the current official Sandbox M1/ABHA contract,
   * operators must set the exact values from that contract as Edge Function
   * secrets (ABDM_M1_BASE_URL and the per-operation ABDM_M1_*_PATH entries).
   * ------------------------------------------------------------------------
   */
  m1BaseUrl: string;
  /** Official path for Aadhaar OTP generation. Empty = contract unconfirmed. */
  m1GenerateAadhaarOtpPath: string;
  /** Official path for Aadhaar OTP verification / eKYC. */
  m1VerifyAadhaarOtpPath: string;
  /** Official path for ABHA number creation (pre-verified flow). */
  m1CreateAbhaPath: string;
  /** Official path for ABHA profile retrieval. */
  m1GetProfilePath: string;
  /** Official path for ABHA number verification. */
  m1VerifyAbhaNumberPath: string;
  /** Official path for ABHA search by mobile. */
  m1SearchByMobilePath: string;
  /** Official path for ABHA Address verification. */
  m1VerifyAbhaAddressPath: string;
  /** Official path for ABHA card retrieval/download. */
  m1GetAbhaCardPath: string;
  /** Official path for ABHA QR retrieval. Empty = no official API confirmed. */
  m1GetAbhaQrPath: string;
  /**
   * Roles allowed to perform patient-facing M1 operations (comma-separated,
   * case-insensitive). Default `super_admin,admin,receptionist`. Bridge and
   * service-management actions remain admin/super_admin-only.
   */
  m1AllowedRoles: string[];
  /**
   * Accepted ABHA Address domains (comma-separated). Default `abdm,sbx`.
   * Configurable via ABDM_M1_ABHA_ADDRESS_SUFFIXES — never hard-coded to a
   * single domain because the official contract may permit other domains.
   */
  m1AbhaAddressSuffixes: string[];
}

export interface ConfigResult {
  ok: boolean;
  config?: GatewayConfig;
  missing: string[];
  /** Non-secret configuration errors (for example an invalid ABDM_CM_ID). */
  errors: string[];
}

/** Secret names that MUST exist only as Supabase Edge Function secrets. */
export const REQUIRED_SECRET_NAMES = [
  "ABDM_CLIENT_ID",
  "ABDM_CLIENT_SECRET",
] as const;

/**
 * X-CM-ID is a short, safe identifier (letters, digits, dot, underscore,
 * colon, hyphen) of at most 32 characters. It is NOT a secret, but it must
 * still be validated before it is ever added to an outgoing header, and its
 * raw value is never logged.
 */
export const CM_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,31}$/;

/** True when a value is usable as an X-CM-ID header value. */
export function isValidCmId(value: string): boolean {
  return CM_ID_PATTERN.test(value);
}

/**
 * Default X-CM-ID for the ABDM base URL. The Sandbox consent-manager context
 * `sbx` is applied only for the dev gateway; every other environment has no
 * default so operators can set ABDM_CM_ID explicitly (or leave it disabled).
 */
export function defaultCmIdForBaseUrl(baseUrl: string): string {
  return hostnameOfUrl(baseUrl) === "dev.abdm.gov.in" ? "sbx" : "";
}

/**
 * Resolves the validated X-CM-ID header value from configuration.
 * Empty string means "disabled" (header omitted).
 */
export function resolvedCmId(config: GatewayConfig): string {
  const value = (config.cmId ?? "").trim();
  return isValidCmId(value) ? value : "";
}

function csv(value: string): string[] {
  return value
    .split(",")
    .map((entry) => entry.trim().toUpperCase())
    .filter(Boolean);
}

export function readConfig(
  env: Record<string, string | undefined>,
): ConfigResult {
  const missing: string[] = [];
  const errors: string[] = [];
  for (const name of REQUIRED_SECRET_NAMES) {
    const value = (env[name] ?? "").trim();
    if (!value) missing.push(name);
  }

  const clientId = (env["ABDM_CLIENT_ID"] ?? "").trim();
  const clientSecret = (env["ABDM_CLIENT_SECRET"] ?? "").trim();
  const baseUrl = (env["ABDM_BASE_URL"] ?? "https://dev.abdm.gov.in").trim();

  // ABDM_CM_ID is not a secret: default `sbx` only for the dev gateway, allow
  // explicit override, and allow an empty value to disable the header.
  // The value is NEVER read from the request body/query/headers.
  const rawCmId = env["ABDM_CM_ID"];
  let cmId: string;
  if (rawCmId === undefined) {
    cmId = defaultCmIdForBaseUrl(baseUrl);
  } else {
    const trimmed = rawCmId.trim();
    if (trimmed === "") {
      cmId = "";
    } else if (!isValidCmId(trimmed)) {
      cmId = "";
      errors.push(
        "ABDM_CM_ID must be 1-32 characters using only letters, digits, dot, underscore, colon or hyphen",
      );
    } else {
      cmId = trimmed;
    }
  }

  const config: GatewayConfig = {
    baseUrl,
    clientId,
    clientSecret,
    bridgeId: (env["ABDM_BRIDGE_ID"] ?? "").trim(),
    hipId: (env["ABDM_HIP_ID"] ?? "").trim(),
    hiuId: (env["ABDM_HIU_ID"] ?? "").trim(),
    callbackBaseUrl: (env["ABDM_CALLBACK_BASE_URL"] ?? "").trim(),
    sessionPath: (env["ABDM_SESSION_PATH"] ?? "/gateway/v1/sessions").trim(),
    bridgePath: (env["ABDM_BRIDGE_PATH"] ?? "/gateway/v1/bridges").trim(),
    servicesPath:
      (env["ABDM_SERVICES_PATH"] ?? "/gateway/v1/bridges/addUpdateServices")
        .trim(),
    getServicesPath:
      (env["ABDM_GET_SERVICES_PATH"] ?? "/gateway/v1/bridges/getServices")
        .trim(),
    hfrBaseUrl:
      (env["ABDM_HFR_BASE_URL"] ?? "https://apihspsbx.abdm.gov.in/v4/int")
        .trim(),
    hfrServicesPath:
      (env["ABDM_HFR_SERVICES_PATH"] ??
        "/v1/bridges/MutipleHRPAddUpdateServices").trim(),
    allowedServiceTypes: csv(env["ABDM_SERVICE_TYPES"] ?? "HIP,HIU"),
    cmId,
    tokenSafetyMarginSeconds: 120,
    // M1 contract configuration. All paths default to EMPTY so every M1
    // action is contract-gated until the official client-supplied contract
    // is configured by the operator. No M1 path/method/body is invented.
    m1BaseUrl: (env["ABDM_M1_BASE_URL"] ?? "").trim(),
    m1GenerateAadhaarOtpPath: (env["ABDM_M1_GENERATE_AADHAAR_OTP_PATH"] ?? "")
      .trim(),
    m1VerifyAadhaarOtpPath: (env["ABDM_M1_VERIFY_AADHAAR_OTP_PATH"] ?? "")
      .trim(),
    m1CreateAbhaPath: (env["ABDM_M1_CREATE_ABHA_PATH"] ?? "").trim(),
    m1GetProfilePath: (env["ABDM_M1_GET_PROFILE_PATH"] ?? "").trim(),
    m1VerifyAbhaNumberPath: (env["ABDM_M1_VERIFY_ABHA_NUMBER_PATH"] ?? "")
      .trim(),
    m1SearchByMobilePath: (env["ABDM_M1_SEARCH_BY_MOBILE_PATH"] ?? "").trim(),
    m1VerifyAbhaAddressPath: (env["ABDM_M1_VERIFY_ABHA_ADDRESS_PATH"] ?? "")
      .trim(),
    m1GetAbhaCardPath: (env["ABDM_M1_GET_ABHA_CARD_PATH"] ?? "").trim(),
    m1GetAbhaQrPath: (env["ABDM_M1_GET_ABHA_QR_PATH"] ?? "").trim(),
    m1AllowedRoles: csv(
      env["ABDM_M1_ALLOWED_ROLES"] ?? "super_admin,admin,receptionist",
    ),
    m1AbhaAddressSuffixes: csv(
      env["ABDM_M1_ABHA_ADDRESS_SUFFIXES"] ?? "abdm,sbx",
    ),
  };

  return {
    ok: missing.length === 0 && errors.length === 0,
    config,
    missing,
    errors,
  };
}

/**
 * Returns the configured Bridge endpoint path. The onboarding-email contract
 * is PATCH `/gateway/v1/bridges` — no `/{bridgeId}` suffix is appended.
 */
export function resolveBridgePath(config: GatewayConfig): string {
  return config.bridgePath;
}

// ----------------------------------------------------------------------------
// Server-side callback URL validation
// ----------------------------------------------------------------------------

export interface CallbackUrlValidation {
  ok: boolean;
  error?: string;
}

/**
 * True when a hostname points at the local machine or a private/local/reserved
 * network. Used by the Bridge flow so an attacker can never register a
 * callback that would exfiltrate ABDM data to a local service.
 */
export function isLocalOrPrivateHost(hostname: string): boolean {
  const host = hostname.trim().toLowerCase().replace(/^\[|\]$/g, "");
  if (!host) return true;

  if (
    host === "localhost" ||
    host === "local" ||
    host.endsWith(".localhost") ||
    host.endsWith(".local")
  ) {
    return true;
  }

  // IPv4-compatible numeric host (for example https://2130706433 == 127.0.0.1).
  if (/^\d+$/.test(host)) {
    const numeric = Number(host);
    if (Number.isFinite(numeric) && numeric >= 0 && numeric <= 0xffffffff) {
      return isLocalOrPrivateHost(
        `${(numeric >>> 24) & 0xff}.${(numeric >>> 16) & 0xff}.${
          (numeric >>> 8) & 0xff
        }.${numeric & 0xff}`,
      );
    }
    return true;
  }

  const ipv4 = host.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (ipv4) {
    const octets = ipv4.slice(1).map(Number);
    if (octets.some((n) => n > 255)) return true; // malformed IPv4
    const [a, b, c] = octets;
    if (a === 0 || a === 10 || a === 127) return true;
    if (a === 100 && b >= 64 && b <= 127) return true; // 100.64/10 CGNAT
    if (a === 169 && b === 254) return true; // link-local
    if (a === 172 && b >= 16 && b <= 31) return true; // 172.16/12
    if (a === 192 && b === 0 && (c === 0 || c === 2)) return true; // 192.0.0/24, 192.0.2/24
    if (a === 192 && b === 168) return true; // 192.168/16
    if (a === 198 && (b === 18 || b === 19)) return true; // 198.18/15
    if (a === 198 && b === 51 && c === 100) return true; // 198.51.100/24
    if (a === 203 && b === 0 && c === 113) return true; // 203.0.113/24
    if (a >= 224) return true; // multicast + reserved + broadcast
    return false;
  }

  if (host.includes(":")) {
    if (host === "::" || host === "::1") return true;
    // fc00::/7 unique-local addresses.
    if (host.startsWith("fc") || host.startsWith("fd")) return true;
    // fe80::/10 link-local addresses.
    if (/^fe[89ab]/.test(host)) return true;
    // IPv4-mapped IPv6 (for example ::ffff:10.0.0.1).
    if (host.startsWith("::ffff:")) {
      const embedded = host.slice("::ffff:".length);
      if (embedded.includes(".")) return isLocalOrPrivateHost(embedded);
      // Hex form (for example ::ffff:7f00:1). Parse the last 32 bits.
      const hexParts = embedded.split(":").filter(Boolean);
      const last = hexParts[hexParts.length - 1] ?? "";
      const value = Number.parseInt(last, 16);
      if (Number.isFinite(value)) {
        return isLocalOrPrivateHost(
          `${(value >>> 24) & 0xff}.${(value >>> 16) & 0xff}.${
            (value >>> 8) & 0xff
          }.${value & 0xff}`,
        );
      }
      return true;
    }
    return false; // other IPv6 (global unicast)
  }

  return false;
}

/**
 * Validates the server-side `ABDM_CALLBACK_BASE_URL` value before it is sent
 * to the ABDM Bridge update endpoint:
 *   * non-empty, absolute URL
 *   * HTTPS only
 *   * no localhost / private / local / reserved IP
 *   * no query string or fragment
 */
export function validateCallbackBaseUrl(
  value: string,
): CallbackUrlValidation {
  const trimmed = value.trim();
  if (!trimmed) {
    return { ok: false, error: "ABDM_CALLBACK_BASE_URL is not configured" };
  }

  let url: URL;
  try {
    url = new URL(trimmed);
  } catch (_) {
    return {
      ok: false,
      error: "ABDM_CALLBACK_BASE_URL must be a valid absolute URL",
    };
  }

  if (url.protocol !== "https:") {
    return { ok: false, error: "ABDM_CALLBACK_BASE_URL must use HTTPS" };
  }
  if (url.username || url.password) {
    return {
      ok: false,
      error: "ABDM_CALLBACK_BASE_URL must not contain credentials",
    };
  }
  if (url.search) {
    return {
      ok: false,
      error: "ABDM_CALLBACK_BASE_URL must not contain a query string",
    };
  }
  if (url.hash) {
    return {
      ok: false,
      error: "ABDM_CALLBACK_BASE_URL must not contain a fragment",
    };
  }
  if (isLocalOrPrivateHost(url.hostname)) {
    return {
      ok: false,
      error:
        "ABDM_CALLBACK_BASE_URL must not use localhost or a private/local IP address",
    };
  }

  return { ok: true };
}

/** Owner/super-admin check shared by every privileged internal action. */
export function isAdminRole(role: string): boolean {
  const normalized = role.toLowerCase();
  return normalized === "super_admin" || normalized === "admin";
}

/** Masks a client id for safe display/audit (first 4 + last 4). */
export function maskClientId(clientId: string): string {
  if (clientId.length <= 8) return "********";
  return `${clientId.slice(0, 4)}****${clientId.slice(-4)}`;
}

// ----------------------------------------------------------------------------
// HTTP helpers (fetch is injectable so tests never touch the real gateway)
// ----------------------------------------------------------------------------

export type FetchImpl = typeof fetch;

/** Safe metadata about an outgoing ABDM request (never headers/body/tokens). */
export interface GatewayRequestInfo {
  method: string;
  hostname: string;
  pathname: string;
}

export interface GatewayHttpResponse {
  ok: boolean;
  status: number;
  data: unknown;
  contentType: string | null;
}

/**
 * Metadata attached to a gateway request that returned an HTTP response.
 * `initialStatus` is the very first upstream status (before any fresh-token
 * retry); `freshTokenRetryPerformed` / `retryStatus` describe the single
 * retry that may have been attempted on 401/403.
 */
export interface GatewayRequestResult extends GatewayHttpResponse {
  initialStatus: number | null;
  freshTokenRetryPerformed: boolean;
  retryStatus: number | null;
  cmContextApplied: boolean;
}

export type GatewayErrorCategory = "timeout" | "network" | "http";

export interface GatewayErrorMeta {
  /** True when the 401/403 fresh-token retry had already been attempted. */
  freshTokenRetryPerformed?: boolean;
  /** The very first upstream status that triggered the retry, when known. */
  initialStatus?: number | null;
}

export class GatewayError extends Error {
  readonly status: number;
  readonly body: unknown;
  readonly category: GatewayErrorCategory;
  readonly request?: GatewayRequestInfo;
  readonly freshTokenRetryPerformed: boolean;
  readonly initialStatus: number | null;

  constructor(
    status: number,
    message: string,
    body?: unknown,
    category: GatewayErrorCategory = status === 0 ? "network" : "http",
    request?: GatewayRequestInfo,
    meta?: GatewayErrorMeta,
  ) {
    super(message);
    this.status = status;
    this.body = body;
    this.category = category;
    this.request = request;
    this.freshTokenRetryPerformed = meta?.freshTokenRetryPerformed === true;
    this.initialStatus = meta?.initialStatus ?? null;
  }
}

export class HttpError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

/** Best-effort hostname extraction for structured logs (never logs full URL). */
export function hostnameOfUrl(rawUrl: string): string {
  try {
    return new URL(rawUrl).hostname || "unknown";
  } catch (_) {
    return "unknown";
  }
}

/** Best-effort pathname extraction for structured logs (no query/fragment). */
export function pathnameOfUrl(rawUrl: string): string {
  try {
    return new URL(rawUrl).pathname || "/";
  } catch (_) {
    return "/";
  }
}

/** Detects timeout-shaped fetch failures without depending on a specific runtime. */
export function isTimeoutError(error: unknown, rawMessage: string): boolean {
  const name = (error as { name?: string } | null)?.name ?? "";
  return (
    name === "TimeoutError" ||
    name === "AbortError" ||
    /timeout|timed\s*out/i.test(rawMessage)
  );
}

/**
 * String-level redaction for any message that could reach logs or clients.
 * `sanitizePayload` redacts token-like KEYS; this helper also redacts
 * JWT-shaped strings and `Bearer <token>` VALUES embedded in free text.
 */
export function redactSensitiveText(value: string): string {
  return value
    .replace(
      /eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g,
      "[REDACTED]",
    )
    .replace(
      /Bearer\s+[A-Za-z0-9._~+/=-]{8,}/g,
      "Bearer [REDACTED]",
    );
}

/**
 * LEGACY v0.5/v1 authenticated request headers. Kept intact for the legacy
 * `addUpdateServices` flow. V3 production requests use
 * `buildV3AuthenticatedHeaders` instead.
 *
 * @deprecated Use `buildV3AuthenticatedHeaders` for V3 requests.
 */
export function buildGatewayHeaders(
  token: string,
  cmId?: string | null,
): Record<string, string> {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    Authorization: `Bearer ${token}`,
  };
  const value = (cmId ?? "").trim();
  // Defense in depth: only a validated identifier ever becomes a header value.
  if (value && isValidCmId(value)) headers["X-CM-ID"] = value;
  return headers;
}

export async function safeFetchJson(
  fetchImpl: FetchImpl,
  url: string,
  init: RequestInit,
): Promise<GatewayHttpResponse> {
  const requestInfo: GatewayRequestInfo = {
    method: (init?.method ?? "GET").toUpperCase(),
    hostname: hostnameOfUrl(url),
    pathname: pathnameOfUrl(url),
  };

  let response: Response;
  try {
    response = await fetchImpl(url, init);
  } catch (error) {
    // SECURITY: never include the raw fetch error in the diagnostic message.
    // The category (timeout vs network) is all the operator needs to see.
    const rawMessage = (error as Error)?.message ?? String(error);
    const category: GatewayErrorCategory = isTimeoutError(error, rawMessage)
      ? "timeout"
      : "network";
    throw new GatewayError(
      0,
      category === "timeout"
        ? "ABDM gateway timed out"
        : "ABDM gateway unreachable",
      undefined,
      category,
      requestInfo,
    );
  }

  let data: unknown = null;
  try {
    data = await response.json();
  } catch (_) {
    data = null;
  }

  return {
    ok: response.ok,
    status: response.status,
    data,
    contentType: response.headers.get("content-type"),
  };
}

// ----------------------------------------------------------------------------
// Inbound body reading (size limit + strict JSON validation)
// ----------------------------------------------------------------------------

export interface JsonBodyResult {
  ok: boolean;
  body: Record<string, unknown>;
  status?: number;
  error?: string;
}

/**
 * Reads an inbound JSON object body with a hard byte limit. Non-GET/HEAD
 * requests with an empty body are accepted as `{}`. Oversized or malformed
 * JSON returns `ok: false` with an HTTP status ready to return to the caller.
 */
export async function readJsonBody(
  req: Request,
  maxBytes: number,
): Promise<JsonBodyResult> {
  if (req.method === "GET" || req.method === "HEAD") {
    return { ok: true, body: {} };
  }

  const declared = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > maxBytes) {
    return { ok: false, body: {}, status: 413, error: "Payload too large" };
  }

  const text = await req.text();
  if (text.length > maxBytes) {
    return { ok: false, body: {}, status: 413, error: "Payload too large" };
  }
  if (!text.trim()) return { ok: true, body: {} };

  try {
    const parsed = JSON.parse(text);
    if (
      typeof parsed !== "object" || parsed === null || Array.isArray(parsed)
    ) {
      return {
        ok: false,
        body: {},
        status: 400,
        error: "JSON body must be an object",
      };
    }
    return { ok: true, body: parsed as Record<string, unknown> };
  } catch (_) {
    return { ok: false, body: {}, status: 400, error: "Invalid JSON body" };
  }
}

// ----------------------------------------------------------------------------
// Best-effort per-worker rate limiting (callbacks are public)
// ----------------------------------------------------------------------------

export class SlidingWindowRateLimiter {
  private readonly hits = new Map<string, number[]>();

  constructor(
    private readonly windowMs: number,
    private readonly maxRequests: number,
  ) {}

  allow(key: string, now = Date.now()): boolean {
    const cutoff = now - this.windowMs;
    const previous = this.hits.get(key) ?? [];
    const recent = previous.filter((timestamp) => timestamp > cutoff);
    if (recent.length >= this.maxRequests) {
      this.hits.set(key, recent);
      return false;
    }
    recent.push(now);
    this.hits.set(key, recent);
    return true;
  }
}

// ----------------------------------------------------------------------------
// Server-side ABDM session management
// ----------------------------------------------------------------------------

export interface TokenRecord {
  accessToken: string;
  expiresAt: number;
}

export interface TokenCacheRef {
  current: TokenRecord | null;
}

/**
 * LEGACY v0.5/v1 session management. Kept intact (do not delete) for the
 * legacy `addUpdateServices` facility-registration flow until the official V3
 * write contract is confirmed. New production session/Bridge/services actions
 * must use `createV3Session` / `acquireV3AccessToken` instead.
 *
 * @deprecated Use the canonical V3 client (`acquireV3AccessToken`).
 */
export async function acquireAccessToken(
  fetchImpl: FetchImpl,
  config: GatewayConfig,
  cache: TokenCacheRef,
): Promise<TokenRecord> {
  const now = Date.now();
  const cached = cache.current;
  if (
    cached &&
    now < cached.expiresAt - config.tokenSafetyMarginSeconds * 1000
  ) {
    return cached;
  }

  const response = await safeFetchJson(
    fetchImpl,
    `${config.baseUrl}${config.sessionPath}`,
    {
      method: "POST",
      // Session creation authenticates with clientId/clientSecret body only.
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        clientId: config.clientId,
        clientSecret: config.clientSecret,
      }),
    },
  );

  if (!response.ok) {
    throw new GatewayError(
      response.status,
      `ABDM session request failed with status ${response.status}`,
      sanitizePayload(response.data),
      "http",
      {
        method: "POST",
        hostname: hostnameOfUrl(config.baseUrl),
        pathname: config.sessionPath,
      },
    );
  }

  const body = asRecord(response.data);
  const accessToken = (body["accessToken"] as string | undefined) ??
    (body["token"] as string | undefined) ??
    "";
  if (!accessToken) {
    throw new GatewayError(
      response.status,
      "ABDM session response did not contain an access token",
      undefined,
      "http",
      {
        method: "POST",
        hostname: hostnameOfUrl(config.baseUrl),
        pathname: config.sessionPath,
      },
    );
  }

  const expiresIn = parsePositiveInt(
    body["expiresIn"] ?? body["expires_in"],
    3600,
  );

  const record: TokenRecord = {
    accessToken,
    expiresAt: now + expiresIn * 1000,
  };
  cache.current = record;
  return record;
}

/** Convenience wrapper that returns only the raw token (internal use only). */
export async function getAccessToken(
  fetchImpl: FetchImpl,
  config: GatewayConfig,
  cache: TokenCacheRef,
): Promise<string> {
  const record = await acquireAccessToken(fetchImpl, config, cache);
  return record.accessToken;
}

/**
 * LEGACY v0.5/v1 authenticated gateway request. Kept intact (do not delete)
 * for the legacy `addUpdateServices` facility-registration flow until the
 * official V3 write contract is confirmed. New production Bridge/services
 * actions must use `v3GatewayRequest` / `v3GetBridgeServices` /
 * `v3PatchBridgeUrl` instead.
 *
 * @deprecated Use the canonical V3 client (`v3GatewayRequest`).
 */
export async function gatewayRequest(
  fetchImpl: FetchImpl,
  config: GatewayConfig,
  cache: TokenCacheRef,
  method: "GET" | "POST" | "PATCH" | "PUT",
  path: string,
  body?: unknown,
  options: { retryOnAuthFailure?: boolean } = {},
): Promise<GatewayRequestResult> {
  const cmId = resolvedCmId(config);
  const retryOnAuthFailure = options.retryOnAuthFailure !== false;

  async function send(token: string): Promise<GatewayHttpResponse> {
    return safeFetchJson(fetchImpl, `${config.baseUrl}${path}`, {
      method,
      headers: buildGatewayHeaders(token, cmId),
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  }

  let response = await send(await getAccessToken(fetchImpl, config, cache));
  const initialStatus = response.status;
  let freshTokenRetryPerformed = false;
  let retryStatus: number | null = null;

  if (
    retryOnAuthFailure && (response.status === 401 || response.status === 403)
  ) {
    // Invalidate ONLY the in-memory token cache, then request one fresh
    // session token and repeat the identical operation exactly once.
    cache.current = null;
    try {
      response = await send(await getAccessToken(fetchImpl, config, cache));
    } catch (error) {
      if (error instanceof GatewayError) {
        throw new GatewayError(
          error.status,
          error.message,
          error.body,
          error.category,
          error.request,
          { freshTokenRetryPerformed: true, initialStatus },
        );
      }
      throw error;
    }
    freshTokenRetryPerformed = true;
    retryStatus = response.status;
  }

  return {
    ok: response.ok,
    status: response.status,
    data: sanitizePayload(response.data),
    contentType: response.contentType,
    initialStatus,
    freshTokenRetryPerformed,
    retryStatus,
    cmContextApplied: cmId !== "",
  };
}

// ----------------------------------------------------------------------------
// Payload sanitization
// ----------------------------------------------------------------------------

const REDACT_KEYS = new Set([
  "accesstoken",
  "xtoken",
  "token",
  "clientsecret",
  "secret",
  "apikey",
  "authorization",
  "otp",
  "aadhaar",
  "password",
  "credential",
  "credentials",
]);

function normalizeKey(key: string): string {
  return key.toLowerCase().replace(/[^a-z0-9]/g, "");
}

/**
 * Recursively redacts token/secret/OTP/Aadhaar-like fields from an arbitrary
 * JSON value and truncates unusually long strings. Used for callback payloads
 * persisted to the database, audit logs and every gateway response returned
 * to Flutter. Authorization headers never reach this function.
 */
export function sanitizePayload(value: unknown, depth = 0): unknown {
  if (value === null || value === undefined) return null;
  if (typeof value === "string") {
    return value.length > 10_000
      ? `${value.slice(0, 10_000)}...[truncated]`
      : value;
  }
  if (typeof value === "number" || typeof value === "boolean") return value;
  if (typeof value === "bigint") return value.toString();
  if (Array.isArray(value)) {
    return value.map((entry) => sanitizePayload(entry, depth + 1));
  }
  if (typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (
      const [key, entry] of Object.entries(value as Record<string, unknown>)
    ) {
      if (REDACT_KEYS.has(normalizeKey(key))) {
        out[key] = "[REDACTED]";
      } else {
        out[key] = sanitizePayload(entry, depth + 1);
      }
    }
    return out;
  }
  return String(value);
}

// ----------------------------------------------------------------------------
// Bridge action diagnostics (safe, structured, no tokens/secrets/bodies)
// ----------------------------------------------------------------------------

export interface BridgeDiagnostic {
  operation: "bridge_update";
  /** Machine-readable client code, e.g. ABDM_BRIDGE_400. */
  code: string;
  /** Upstream HTTP status when an HTTP response exists; null for network errors. */
  upstreamStatus: number | null;
  /** Short sanitized message safe for the Flutter client. */
  message: string;
  upstreamHostname: string;
  method: string;
  pathname: string;
  contentType: string | null;
  category: "timeout" | "network" | "http";
  /** Sanitized upstream error code (may be null). */
  errorCode: string | null;
  /** Sanitized upstream error message (may be null). */
  errorMessage: string | null;
  /** Status of the very first attempt (before any fresh-token retry). */
  initialUpstreamStatus: number | null;
  /** True when the single 401/403 fresh-token retry was performed. */
  freshTokenRetryPerformed: boolean;
  /** Status of the retry attempt (null when no retry was performed). */
  retryStatus: number | null;
  /** True when X-CM-ID was applied to the outgoing request. */
  cmContextApplied: boolean;
}

/** Reads retry/context metadata from a GatewayRequestResult (defaults for plain responses). */
function gatewayRequestMeta(
  response: GatewayHttpResponse | GatewayRequestResult,
): {
  initialStatus: number | null;
  freshTokenRetryPerformed: boolean;
  retryStatus: number | null;
  cmContextApplied: boolean;
} {
  const meta = response as Partial<GatewayRequestResult>;
  return {
    initialStatus: typeof meta.initialStatus === "number"
      ? meta.initialStatus
      : response.status,
    freshTokenRetryPerformed: meta.freshTokenRetryPerformed === true,
    retryStatus: typeof meta.retryStatus === "number" ? meta.retryStatus : null,
    cmContextApplied: meta.cmContextApplied === true,
  };
}

const MAX_DIAGNOSTIC_TEXT_LENGTH = 160;

function truncateDiagnosticText(value: string): string {
  const clean = value.replace(/\s+/g, " ").trim();
  return clean.length > MAX_DIAGNOSTIC_TEXT_LENGTH
    ? `${clean.slice(0, MAX_DIAGNOSTIC_TEXT_LENGTH)}…`
    : clean;
}

function firstDefinedString(...values: unknown[]): string | null {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) return value.trim();
  }
  return null;
}

/**
 * Extracts a sanitized ABDM error code/message from an upstream body. The body
 * first passes through `sanitizePayload` (key redaction), then the extracted
 * strings pass through `redactSensitiveText` (JWT/Bearer value redaction) and
 * finally any known secret VALUES (client id / secret / access token) supplied
 * by the caller are replaced. Never returns the raw body.
 */
export function extractSanitizedUpstreamError(
  data: unknown,
  secrets: string[] = [],
): {
  code: string | null;
  message: string | null;
} {
  const record = asRecord(sanitizePayload(data));
  const errorRecord = asRecord(record["error"]);
  const rawCode = firstDefinedString(
    record["errorCode"],
    record["error_code"],
    record["code"],
    errorRecord["code"],
    errorRecord["errorCode"],
    errorRecord["error_code"],
  );
  const rawMessage = firstDefinedString(
    record["errorMessage"],
    record["error_message"],
    record["message"],
    typeof record["error"] === "string" ? record["error"] : null,
    record["detail"],
    record["details"],
    errorRecord["message"],
    errorRecord["errorMessage"],
    errorRecord["error_message"],
  );

  const secretValues = secrets
    .map((secret) => secret.trim())
    .filter((secret) => secret.length >= 4);

  function scrub(value: string): string {
    let out = redactSensitiveText(value);
    for (const secret of secretValues) {
      out = out.split(secret).join("[REDACTED]");
    }
    return out;
  }

  return {
    code: rawCode ? truncateDiagnosticText(scrub(rawCode)) : null,
    message: rawMessage ? truncateDiagnosticText(scrub(rawMessage)) : null,
  };
}

/** Diagnostic for an ABDM non-2xx HTTP response to the PATCH bridge call. */
export function buildBridgeHttpDiagnostic(
  response: GatewayHttpResponse,
  config: GatewayConfig,
  secrets: string[] = [],
): BridgeDiagnostic {
  const status = response.status || 0;
  const upstream = extractSanitizedUpstreamError(response.data, secrets);
  const detail = upstream.message ?? upstream.code;
  const meta = gatewayRequestMeta(response);
  return {
    operation: "bridge_update",
    code: status === 0 ? "ABDM_BRIDGE_NETWORK" : `ABDM_BRIDGE_${status}`,
    upstreamStatus: status === 0 ? null : status,
    message: `ABDM Bridge update failed (HTTP ${status})` +
      (detail ? `: ${detail}` : ""),
    upstreamHostname: hostnameOfUrl(config.baseUrl),
    method: "PATCH",
    pathname: resolveBridgePath(config),
    contentType: response.contentType,
    category: "http",
    errorCode: upstream.code,
    errorMessage: upstream.message,
    initialUpstreamStatus: status === 0 ? null : meta.initialStatus,
    freshTokenRetryPerformed: meta.freshTokenRetryPerformed,
    retryStatus: meta.retryStatus,
    cmContextApplied: meta.cmContextApplied,
  };
}

/** Diagnostic for a fetch-level GatewayError (timeout/network) in the bridge flow. */
export function buildBridgeGatewayDiagnostic(
  error: GatewayError,
  config: GatewayConfig,
): BridgeDiagnostic {
  const category: BridgeDiagnostic["category"] = error.category;
  const upstreamStatus = error.status === 0 ? null : error.status;
  const fallback: GatewayRequestInfo = {
    method: "PATCH",
    hostname: hostnameOfUrl(config.baseUrl),
    pathname: resolveBridgePath(config),
  };
  const target = error.request ?? fallback;

  const code = category === "timeout"
    ? "ABDM_BRIDGE_TIMEOUT"
    : category === "network"
    ? "ABDM_BRIDGE_NETWORK"
    : `ABDM_BRIDGE_${error.status}`;

  const message = category === "timeout"
    ? "ABDM Bridge update timed out before receiving a response."
    : category === "network"
    ? "ABDM Bridge update failed: the ABDM gateway is unreachable."
    : `ABDM Bridge update failed (HTTP ${error.status}).`;

  return {
    operation: "bridge_update",
    code,
    upstreamStatus,
    message,
    upstreamHostname: target.hostname,
    method: target.method,
    pathname: target.pathname,
    contentType: null,
    category,
    errorCode: null,
    errorMessage: null,
    initialUpstreamStatus: error.initialStatus ?? upstreamStatus,
    freshTokenRetryPerformed: error.freshTokenRetryPerformed,
    retryStatus: null,
    cmContextApplied: resolvedCmId(config) !== "",
  };
}

/** Diagnostic for a successful PATCH bridge call. */
export function buildBridgeSuccessDiagnostic(
  response: GatewayHttpResponse,
  config: GatewayConfig,
): BridgeDiagnostic {
  const meta = gatewayRequestMeta(response);
  return {
    operation: "bridge_update",
    code: "ABDM_BRIDGE_OK",
    upstreamStatus: response.status,
    message: "ABDM Bridge update succeeded.",
    upstreamHostname: hostnameOfUrl(config.baseUrl),
    method: "PATCH",
    pathname: resolveBridgePath(config),
    contentType: response.contentType,
    category: "http",
    errorCode: null,
    errorMessage: null,
    initialUpstreamStatus: meta.initialStatus,
    freshTokenRetryPerformed: meta.freshTokenRetryPerformed,
    retryStatus: meta.retryStatus,
    cmContextApplied: meta.cmContextApplied,
  };
}

// ----------------------------------------------------------------------------
// getServices action diagnostics + sanitized service list
// ----------------------------------------------------------------------------

export interface GetServicesDiagnostic {
  operation: "get_services";
  code: string;
  upstreamStatus: number | null;
  message: string;
  upstreamHostname: string;
  method: string;
  pathname: string;
  contentType: string | null;
  category: "timeout" | "network" | "http";
  errorCode: string | null;
  errorMessage: string | null;
  /** Status of the very first attempt (before any fresh-token retry). */
  initialUpstreamStatus: number | null;
  /** True when the single 401/403 fresh-token retry was performed. */
  freshTokenRetryPerformed: boolean;
  /** Status of the retry attempt (null when no retry was performed). */
  retryStatus: number | null;
  /** True when X-CM-ID was applied to the outgoing request. */
  cmContextApplied: boolean;
}

function sanitizeDiagnosticText(value: unknown): string {
  if (typeof value === "string") {
    return truncateDiagnosticText(redactSensitiveText(value));
  }
  if (typeof value === "number" || typeof value === "boolean") {
    return String(value);
  }
  return "";
}

function sanitizeServiceEndpoint(endpoint: unknown): Record<string, unknown> {
  const record = asRecord(endpoint);
  const out: Record<string, unknown> = {};
  if (record["address"] !== undefined) {
    out["address"] = sanitizeDiagnosticText(record["address"]);
  }
  if (record["connectionType"] !== undefined) {
    out["connectionType"] = sanitizeDiagnosticText(record["connectionType"]);
  }
  if (record["use"] !== undefined) {
    out["use"] = sanitizeDiagnosticText(record["use"]);
  }
  return out;
}

/**
 * Normalizes ABDM service type information into the canonical V3 `types`
 * array. The current official V3 schema uses `types: string[]`. For defensive
 * backwards compatibility only, a legacy singular `type` is normalized to
 * `[type]` when `types` is absent. Values are uppercased and deduplicated.
 */
export function normalizeServiceTypes(
  record: Record<string, unknown>,
): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  const push = (value: unknown) => {
    if (typeof value !== "string") return;
    const normalized = value.trim().toUpperCase();
    if (!normalized || seen.has(normalized)) return;
    seen.add(normalized);
    out.push(normalized);
  };

  const rawTypes = record["types"];
  if (Array.isArray(rawTypes)) {
    for (const entry of rawTypes) push(entry);
    if (out.length > 0) return out;
  }
  // Legacy defensive fallback: singular `type` only when `types` is absent
  // (or present but not a usable non-empty array).
  push(record["type"]);
  return out;
}

function sanitizeServiceEntry(entry: unknown): Record<string, unknown> {
  const record = asRecord(entry);
  const out: Record<string, unknown> = {};
  const types = normalizeServiceTypes(record);
  if (record["id"] !== undefined) {
    out["id"] = sanitizeDiagnosticText(record["id"]);
  }
  if (record["name"] !== undefined) {
    out["name"] = sanitizeDiagnosticText(record["name"]);
  }
  if (record["bridgeId"] !== undefined) {
    out["bridgeId"] = sanitizeDiagnosticText(record["bridgeId"]);
  }
  if (types.length > 0) out["types"] = types;
  if (typeof record["active"] === "boolean") out["active"] = record["active"];
  if (Array.isArray(record["alias"])) {
    out["alias"] = record["alias"].map((value) =>
      sanitizeDiagnosticText(value)
    );
  }
  if (Array.isArray(record["endpoints"])) {
    out["endpoints"] = record["endpoints"].map((endpoint) =>
      sanitizeServiceEndpoint(endpoint)
    );
  }
  return out;
}

/**
 * Extracts only the non-sensitive ABDM service fields from a getServices
 * response. The raw payload first passes through `sanitizePayload` (key/value
 * redaction) and each remaining string is truncated and text-redacted.
 */
export function extractSanitizedServices(
  data: unknown,
): Record<string, unknown>[] {
  const sanitized = sanitizePayload(data);
  const record = asRecord(sanitized);
  const raw = Array.isArray(sanitized)
    ? sanitized
    : Array.isArray(record["services"])
    ? record["services"]
    : [];
  return raw
    .filter((entry) => typeof entry === "object" && entry !== null)
    .map((entry) => sanitizeServiceEntry(entry));
}

function getServicesBase(config: GatewayConfig): {
  upstreamHostname: string;
  method: string;
  pathname: string;
} {
  return {
    upstreamHostname: hostnameOfUrl(config.baseUrl),
    method: "GET",
    pathname: config.getServicesPath,
  };
}

/** Diagnostic for an ABDM non-2xx HTTP response to the getServices GET call. */
export function buildGetServicesHttpDiagnostic(
  response: GatewayHttpResponse,
  config: GatewayConfig,
  secrets: string[] = [],
): GetServicesDiagnostic {
  const status = response.status || 0;
  const upstream = extractSanitizedUpstreamError(response.data, secrets);
  const detail = upstream.message ?? upstream.code;
  const meta = gatewayRequestMeta(response);
  return {
    operation: "get_services",
    code: status === 0
      ? "ABDM_GET_SERVICES_NETWORK"
      : `ABDM_GET_SERVICES_${status}`,
    upstreamStatus: status === 0 ? null : status,
    message: `ABDM getServices failed (HTTP ${status})` +
      (detail ? `: ${detail}` : ""),
    ...getServicesBase(config),
    contentType: response.contentType,
    category: "http",
    errorCode: upstream.code,
    errorMessage: upstream.message,
    initialUpstreamStatus: status === 0 ? null : meta.initialStatus,
    freshTokenRetryPerformed: meta.freshTokenRetryPerformed,
    retryStatus: meta.retryStatus,
    cmContextApplied: meta.cmContextApplied,
  };
}

/** Diagnostic for a fetch-level GatewayError (timeout/network) in getServices. */
export function buildGetServicesGatewayDiagnostic(
  error: GatewayError,
  config: GatewayConfig,
): GetServicesDiagnostic {
  const category: GetServicesDiagnostic["category"] = error.category;
  const upstreamStatus = error.status === 0 ? null : error.status;
  const fallback: GatewayRequestInfo = {
    method: "GET",
    hostname: hostnameOfUrl(config.baseUrl),
    pathname: config.getServicesPath,
  };
  const target = error.request ?? fallback;

  const code = category === "timeout"
    ? "ABDM_GET_SERVICES_TIMEOUT"
    : category === "network"
    ? "ABDM_GET_SERVICES_NETWORK"
    : `ABDM_GET_SERVICES_${error.status}`;

  const message = category === "timeout"
    ? "ABDM getServices timed out before receiving a response."
    : category === "network"
    ? "ABDM getServices failed: the ABDM gateway is unreachable."
    : `ABDM getServices failed (HTTP ${error.status}).`;

  return {
    operation: "get_services",
    code,
    upstreamStatus,
    message,
    upstreamHostname: target.hostname,
    method: target.method,
    pathname: target.pathname,
    contentType: null,
    category,
    errorCode: null,
    errorMessage: null,
    initialUpstreamStatus: error.initialStatus ?? upstreamStatus,
    freshTokenRetryPerformed: error.freshTokenRetryPerformed,
    retryStatus: null,
    cmContextApplied: resolvedCmId(config) !== "",
  };
}

/** Diagnostic for a successful getServices GET call. */
export function buildGetServicesSuccessDiagnostic(
  response: GatewayHttpResponse,
  config: GatewayConfig,
): GetServicesDiagnostic {
  const meta = gatewayRequestMeta(response);
  return {
    operation: "get_services",
    code: "ABDM_GET_SERVICES_OK",
    upstreamStatus: response.status,
    message: "ABDM getServices succeeded.",
    ...getServicesBase(config),
    contentType: response.contentType,
    category: "http",
    errorCode: null,
    errorMessage: null,
    initialUpstreamStatus: meta.initialStatus,
    freshTokenRetryPerformed: meta.freshTokenRetryPerformed,
    retryStatus: meta.retryStatus,
    cmContextApplied: meta.cmContextApplied,
  };
}

// ----------------------------------------------------------------------------
// diagnoseV3Gateway action — isolated V3 session + bridge-services diagnostic
// ----------------------------------------------------------------------------
//
// Contract source (recorded for this diagnostic):
//   https://github.com/NHA-ABDM/ABDM-wrapper/blob/master/README.md
//   commit bcc69513daddd18971a819a7afa44ec2b0ccf979
//   Section: "Register bridge (hostUrl) with ABDM for callbacks".
//
// The README documents the V3 session and bridge-services REQUESTS (method,
// headers and body). It does NOT document the response bodies. The wrapper
// implementation parses the session response field `accessToken`
// (SessionManager.java at the same commit), so this diagnostic requires an
// object with a non-empty string `accessToken`; a 2xx without it is a protocol
// failure. The bridge-services response body is NOT documented in the source,
// so this diagnostic recognizes only explicit service-list shapes (a JSON
// array, or an object carrying a `services` array) and reports anything else
// as ABDM_V3_PROTOCOL_ERROR — never as an empty list.
// ----------------------------------------------------------------------------

/**
 * Canonical production V3 gateway endpoints (verified live against Sandbox).
 * The V3 origin is fixed for the Sandbox environment; production ABDM would
 * use the production origin once configured by the operator.
 */
export const V3_GATEWAY_BASE_URL = "https://dev.abdm.gov.in";
/** Official v3 session endpoint path (README curl example). */
export const V3_GATEWAY_SESSION_PATH = "/api/hiecm/gateway/v3/sessions";
/** Official v3 bridge-services endpoint path (README curl example). */
export const V3_GATEWAY_BRIDGE_SERVICES_PATH =
  "/api/hiecm/gateway/v3/bridge-services";
/** Official v3 Bridge URL mutation endpoint path (README curl example). */
export const V3_GATEWAY_BRIDGE_URL_PATH = "/api/hiecm/gateway/v3/bridge/url";
/** Official v3 single bridge-service read endpoint (service-id = HFR facility id). */
export const V3_GATEWAY_BRIDGE_SERVICE_BY_ID_PATH =
  "/api/hiecm/gateway/v3/bridge-service/serviceId";
/** Fixed Sandbox X-CM-ID. Never read from the request. */
export const V3_GATEWAY_CM_ID = "sbx";
/** Per-request upstream timeout for V3 production requests. */
export const V3_GATEWAY_TIMEOUT_MS = 15_000;
/** Hard cap for each V3 production response body. */
export const V3_GATEWAY_MAX_BYTES = 512_000;

// ---------------------------------------------------------------------------
// Deprecated diagnostic-era aliases. Kept so older imports/tests keep working;
// new code must use the V3_GATEWAY_* canonical names.
// ---------------------------------------------------------------------------
/** @deprecated Use V3_GATEWAY_BASE_URL. */
export const V3_DIAGNOSTIC_BASE_URL = V3_GATEWAY_BASE_URL;
/** @deprecated Use V3_GATEWAY_SESSION_PATH. */
export const V3_SESSION_PATH = V3_GATEWAY_SESSION_PATH;
/** @deprecated Use V3_GATEWAY_BRIDGE_SERVICES_PATH. */
export const V3_BRIDGE_SERVICES_PATH = V3_GATEWAY_BRIDGE_SERVICES_PATH;
/** @deprecated Use V3_GATEWAY_CM_ID. */
export const V3_DIAGNOSTIC_CM_ID = V3_GATEWAY_CM_ID;
/** @deprecated Use V3_GATEWAY_TIMEOUT_MS. */
export const V3_DIAGNOSTIC_TIMEOUT_MS = V3_GATEWAY_TIMEOUT_MS;
/** @deprecated Use V3_GATEWAY_MAX_BYTES. */
export const V3_DIAGNOSTIC_MAX_BYTES = V3_GATEWAY_MAX_BYTES;

/**
 * Production V3 token cache (worker memory). This cache is COMPLETELY SEPARATE
 * from the legacy v0.5/v1 `TokenCacheRef`; the two must never be mixed.
 */
export interface V3TokenRecord {
  accessToken: string;
  expiresAt: number;
}

export interface V3TokenCacheRef {
  current: V3TokenRecord | null;
}

/** Generates a fresh REQUEST-ID (UUID v4) for every outbound V3 request. */
export function freshV3RequestId(): string {
  try {
    if (typeof crypto !== "undefined" && crypto.randomUUID) {
      return crypto.randomUUID();
    }
  } catch (_) {
    // fall through to timestamp-based id
  }
  return `${Date.now().toString(36)}-${
    Math.random().toString(36).slice(2, 10)
  }`;
}

/** Current UTC ISO-8601 timestamp for outbound V3 requests. */
export function freshV3Timestamp(): string {
  return new Date().toISOString();
}

/** Headers for the V3 session-creation POST (no Authorization header). */
export function buildV3SessionHeaders(): Record<string, string> {
  return {
    "Content-Type": "application/json",
    "REQUEST-ID": freshV3RequestId(),
    "TIMESTAMP": freshV3Timestamp(),
    "X-CM-ID": V3_GATEWAY_CM_ID,
  };
}

/**
 * Headers for authenticated V3 requests (bridge-services GET / bridge url
 * PATCH). Content-Type is added separately by callers that send a body.
 */
export function buildV3AuthenticatedHeaders(
  token: string,
): Record<string, string> {
  return {
    Authorization: `Bearer ${token}`,
    "REQUEST-ID": freshV3RequestId(),
    "TIMESTAMP": freshV3Timestamp(),
    "X-CM-ID": V3_GATEWAY_CM_ID,
  };
}

export interface V3SessionRequestOptions {
  timeoutMs?: number;
  maxBytes?: number;
}

export interface V3SessionSuccess {
  ok: true;
  token: string;
  expiresAt: number;
  upstreamStatus: number;
}

export interface V3SessionFailure {
  ok: false;
  category: V3FailureCategory;
  /** Present only when an HTTP response existed (null for network/timeout). */
  status: number | null;
  message: string;
}

export type V3SessionResult = V3SessionSuccess | V3SessionFailure;

/**
 * THE single implementation of the official V3 session POST:
 *
 *   POST https://dev.abdm.gov.in/api/hiecm/gateway/v3/sessions
 *   Content-Type: application/json
 *   REQUEST-ID: fresh UUID
 *   TIMESTAMP: current UTC ISO-8601
 *   X-CM-ID: sbx
 *   body: { clientId, clientSecret, grantType: "client_credentials" }
 *
 * No Authorization header is sent. The token is returned to the caller and is
 * never logged. This function always performs a fresh POST; cached production
 * flows use `acquireV3AccessToken`.
 */
export async function createV3Session(
  fetchImpl: FetchImpl,
  config: GatewayConfig,
  options: V3SessionRequestOptions = {},
): Promise<V3SessionResult> {
  let response: GatewayHttpResponse;
  try {
    response = await v3FetchJson(
      fetchImpl,
      `${V3_GATEWAY_BASE_URL}${V3_GATEWAY_SESSION_PATH}`,
      {
        method: "POST",
        headers: buildV3SessionHeaders(),
        body: JSON.stringify({
          clientId: config.clientId,
          clientSecret: config.clientSecret,
          grantType: "client_credentials",
        }),
      },
      options,
    );
  } catch (error) {
    if (error instanceof GatewayError) {
      const status = error.status === 0 ? null : error.status;
      return {
        ok: false,
        category: error.category,
        status,
        message: error.message,
      };
    }
    throw error;
  }

  if (!response.ok) {
    return {
      ok: false,
      category: "http",
      status: response.status,
      message:
        `V3 session request failed: ABDM returned HTTP ${response.status}.`,
    };
  }

  const parsed = parseV3SessionResponse(response.data);
  if (!parsed.ok || !parsed.accessToken) {
    return {
      ok: false,
      category: "protocol",
      status: response.status,
      message: "V3 session response did not match the documented schema.",
    };
  }

  const body = asRecord(response.data);
  const expiresIn = parsePositiveInt(
    body["expiresIn"] ?? body["expires_in"],
    3600,
  );

  return {
    ok: true,
    token: parsed.accessToken,
    expiresAt: Date.now() + expiresIn * 1000,
    upstreamStatus: response.status,
  };
}

/**
 * Returns a cached V3 access token when still valid, otherwise creates a fresh
 * V3 session and caches it in the SEPARATE V3 token cache. The legacy
 * v0.5/v1 `TokenCacheRef` is never read, written or invalidated here.
 */
export async function acquireV3AccessToken(
  fetchImpl: FetchImpl,
  config: GatewayConfig,
  cache: V3TokenCacheRef,
  options: V3SessionRequestOptions & { forceRefresh?: boolean } = {},
): Promise<V3TokenRecord> {
  const now = Date.now();
  const cached = cache.current;
  if (
    !options.forceRefresh &&
    cached &&
    now < cached.expiresAt - config.tokenSafetyMarginSeconds * 1000
  ) {
    return cached;
  }

  const result = await createV3Session(fetchImpl, config, options);
  if (!result.ok) {
    throw new GatewayError(
      result.status ?? 0,
      result.message,
      undefined,
      result.category === "protocol" ? "http" : result.category,
      {
        method: "POST",
        hostname: hostnameOfUrl(V3_GATEWAY_BASE_URL),
        pathname: V3_GATEWAY_SESSION_PATH,
      },
    );
  }

  const record: V3TokenRecord = {
    accessToken: result.token,
    expiresAt: result.expiresAt,
  };
  cache.current = record;
  return record;
}

/**
 * Performs an authenticated production V3 request using the SEPARATE V3 token
 * cache. Unlike the legacy `gatewayRequest`, it never performs a fresh-token
 * retry (the verified V3 flow is deterministic and the diagnostics previously
 * required, and still require, no automatic retries).
 */
export async function v3GatewayRequest(
  fetchImpl: FetchImpl,
  config: GatewayConfig,
  cache: V3TokenCacheRef,
  method: "GET" | "POST" | "PATCH",
  path: string,
  body?: unknown,
  options: V3SessionRequestOptions = {},
): Promise<GatewayRequestResult> {
  const token = await acquireV3AccessToken(fetchImpl, config, cache, options);
  const headers = buildV3AuthenticatedHeaders(token.accessToken);
  if (method === "POST" || method === "PATCH") {
    headers["Content-Type"] = "application/json";
  }

  const response = await v3FetchJson(
    fetchImpl,
    `${V3_GATEWAY_BASE_URL}${path}`,
    {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    },
    options,
  );

  return {
    ok: response.ok,
    status: response.status,
    data: response.data,
    contentType: response.contentType,
    initialStatus: response.status,
    freshTokenRetryPerformed: false,
    retryStatus: null,
    cmContextApplied: true,
  };
}

/**
 * Direct authenticated V3 GET bridge-services using an explicit fresh token
 * (used by the thin diagnostic wrappers so each diagnostic click performs
 * exactly one session POST + one services GET, without touching any cache).
 */
export async function v3GetBridgeServices(
  fetchImpl: FetchImpl,
  token: string,
  options: V3SessionRequestOptions = {},
): Promise<GatewayHttpResponse> {
  return v3FetchJson(
    fetchImpl,
    `${V3_GATEWAY_BASE_URL}${V3_GATEWAY_BRIDGE_SERVICES_PATH}`,
    {
      method: "GET",
      headers: buildV3AuthenticatedHeaders(token),
    },
    options,
  );
}

/**
 * Direct authenticated V3 GET bridge-service/serviceId/{service-id}. The
 * service-id is the configured HFR facility id. Uses the same bounded,
 * redirect-safe V3 fetch and never touches the legacy token cache.
 */
export async function v3GetBridgeServiceById(
  fetchImpl: FetchImpl,
  token: string,
  serviceId: string,
  options: V3SessionRequestOptions = {},
): Promise<GatewayHttpResponse> {
  const trimmed = serviceId.trim();
  const path = `${V3_GATEWAY_BRIDGE_SERVICE_BY_ID_PATH}/${encodeURIComponent(trimmed)}`;
  return v3FetchJson(
    fetchImpl,
    `${V3_GATEWAY_BASE_URL}${path}`,
    {
      method: "GET",
      headers: buildV3AuthenticatedHeaders(token),
    },
    options,
  );
}

/**
 * Direct authenticated V3 PATCH bridge/url with the official body
 * `{"url": "<callback URL>"}` and Content-Type application/json.
 */
export async function v3PatchBridgeUrl(
  fetchImpl: FetchImpl,
  token: string,
  url: string,
  options: V3SessionRequestOptions = {},
): Promise<GatewayHttpResponse> {
  return v3FetchJson(
    fetchImpl,
    `${V3_GATEWAY_BASE_URL}${V3_GATEWAY_BRIDGE_URL_PATH}`,
    {
      method: "PATCH",
      headers: {
        ...buildV3AuthenticatedHeaders(token),
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ url }),
    },
    options,
  );
}

export type V3Stage = "session" | "services" | "complete";
export type V3FailureCategory = "timeout" | "network" | "http" | "protocol";

/** Safe, allow-listed diagnostic result returned by the V3 diagnostic action. */
export interface V3DiagnosticResult {
  operation: "diagnoseV3Gateway";
  environment: "sandbox";
  sessionSucceeded: boolean;
  /** Present only when the ABDM session request produced an HTTP response. */
  sessionUpstreamStatus: number | null;
  servicesSucceeded: boolean;
  /** Present only when the ABDM services request produced an HTTP response. */
  servicesUpstreamStatus: number | null;
  /** Present only when a recognized service-list shape was parsed. */
  serviceCount: number | null;
  /** Sanitized id/name/type/active entries (allow-listed fields only). */
  services: Record<string, unknown>[];
  supportReference: string;
  stage: V3Stage;
  /** Structured failure code (ABDM_V3_*) or "ABDM_V3_OK" on success. */
  code: string | null;
  message: string;
  upstreamHostname: string;
  method: string;
  pathname: string;
  category: V3FailureCategory | "ok";
  durationMs: number;
}

/**
 * Sanitized, allow-listed envelope inspection produced by the read-only
 * `inspectV3Bridge` action. It intentionally describes the SHAPE of the real
 * bridge-services response (types, field names, safe values) so operators can
 * understand the actual V3 schema without any mutation and without exposing
 * tokens, secrets, cookies, credentials or patient information.
 */
export interface V3EnvelopeInspection {
  /** JSON type of the bridge-services body, or null when no body existed. */
  topLevelType: string | null;
  /** Safe top-level field names (sensitive names are never echoed). */
  topLevelFieldNames: string[];
  /** Whether a `bridge` object exists and its safe field names. */
  bridge: { exists: boolean; fieldNames: string[] };
  /** Whether a URL/hostUrl-like field exists and its sanitized safe value. */
  bridgeUrl: { exists: boolean; value: string | null };
  /** Whether a `services` array exists, its length and sanitized items. */
  services: {
    exists: boolean;
    length: number | null;
    items: Record<string, unknown>[];
  };
  /** Top-level field names outside the recognized bridge/services envelope. */
  unknownEnvelopeFieldNames: string[];
}

/** Safe, allow-listed result returned by the read-only `inspectV3Bridge` action. */
export interface V3BridgeInspectResult {
  operation: "inspectV3Bridge";
  environment: "sandbox";
  sessionSucceeded: boolean;
  sessionUpstreamStatus: number | null;
  servicesSucceeded: boolean;
  servicesUpstreamStatus: number | null;
  supportReference: string;
  stage: V3Stage;
  code: string | null;
  message: string;
  upstreamHostname: string;
  method: string;
  pathname: string;
  category: V3FailureCategory | "ok";
  durationMs: number;
  /** Envelope inspection; null on session/services failure. */
  envelope: V3EnvelopeInspection | null;
}

export interface V3SessionParseResult {
  ok: boolean;
  accessToken?: string;
}

export type V3ServicesParseKind =
  | "recognized-empty"
  | "recognized-list"
  | "unexpected";

export interface V3ServicesParseResult {
  kind: V3ServicesParseKind;
  services: Record<string, unknown>[];
}

/**
 * Parses the V3 session response using the wrapper-documented `accessToken`
 * field. The body must be a JSON object containing a non-empty string
 * `accessToken`; any other 2xx body (missing field, wrong type, array, null or
 * non-JSON) is a protocol failure, not a silent success.
 */
export function parseV3SessionResponse(data: unknown): V3SessionParseResult {
  const record = asRecord(data);
  const accessToken = record["accessToken"];
  if (typeof accessToken !== "string" || accessToken.trim() === "") {
    return { ok: false };
  }
  return { ok: true, accessToken: accessToken.trim() };
}

function sanitizeV3ServiceEntry(entry: unknown): Record<string, unknown> {
  const record = asRecord(entry);
  const out: Record<string, unknown> = {};
  const types = normalizeServiceTypes(record);
  if (record["id"] !== undefined) {
    out["id"] = sanitizeDiagnosticText(record["id"]);
  }
  if (record["name"] !== undefined) {
    out["name"] = sanitizeDiagnosticText(record["name"]);
  }
  if (record["bridgeId"] !== undefined) {
    out["bridgeId"] = sanitizeDiagnosticText(record["bridgeId"]);
  }
  if (types.length > 0) out["types"] = types;
  if (typeof record["active"] === "boolean") out["active"] = record["active"];
  if (record["endpoints"] !== undefined && record["endpoints"] !== null) {
    out["endpoints"] = Array.isArray(record["endpoints"])
      ? record["endpoints"].map((endpoint) => sanitizeServiceEndpoint(endpoint))
      : sanitizeServiceEndpoint(record["endpoints"]);
  }
  return out;
}

/**
 * Parses the V3 bridge-services response. Only explicit service-list shapes
 * are recognized: a top-level JSON array, or an object carrying a `services`
 * array. An empty array is a recognized empty list (serviceCount 0); a
 * non-empty array is only recognized when every entry is an object that
 * contains at least one of the documented id/name/type/active fields. Any
 * other shape is `unexpected` — it is never treated as "zero services".
 */
export function parseV3ServicesResponse(data: unknown): V3ServicesParseResult {
  const sanitized = sanitizePayload(data);
  let raw: unknown[] | null = null;
  if (Array.isArray(sanitized)) {
    raw = sanitized;
  } else {
    const record = asRecord(sanitized);
    if (Array.isArray(record["services"])) {
      raw = record["services"] as unknown[];
    }
  }
  if (raw === null) return { kind: "unexpected", services: [] };
  if (raw.length === 0) return { kind: "recognized-empty", services: [] };

  const services: Record<string, unknown>[] = [];
  for (const entry of raw) {
    if (typeof entry !== "object" || entry === null || Array.isArray(entry)) {
      return { kind: "unexpected", services: [] };
    }
    const service = sanitizeV3ServiceEntry(entry);
    if (Object.keys(service).length === 0) {
      return { kind: "unexpected", services: [] };
    }
    services.push(service);
  }
  return { kind: "recognized-list", services };
}

// ----------------------------------------------------------------------------
// V3 service entry extraction (single service, for bridge-services list items)
// ----------------------------------------------------------------------------

export interface V3ServiceEntry {
  id: string | null;
  name: string | null;
  types: string[];
  active: boolean | null;
  bridgeId: string | null;
  endpoints: Record<string, unknown>[] | null;
}

/**
 * Extracts a single sanitized service entry from a bridge-services list item.
 * `types` is canonical; legacy singular `type` is normalized defensively by
 * `normalizeServiceTypes`. Returns null when no documented service field can
 * be found.
 */
export function extractV3ServiceEntry(data: unknown): V3ServiceEntry | null {
  const sanitized = sanitizePayload(data);
  let record = asRecord(sanitized);
  if (Object.keys(record).length === 0 && Array.isArray(sanitized)) {
    const first = sanitized.find((entry) => typeof entry === "object" && entry !== null);
    record = asRecord(first);
  }
  if (Object.keys(record).length === 0) return null;

  for (const wrapperKey of ["service", "data", "result"]) {
    const nested = record[wrapperKey];
    if (typeof nested !== "object" || nested === null || Array.isArray(nested)) {
      continue;
    }
    const inner = asRecord(nested);
    if (
      inner["id"] !== undefined ||
      inner["name"] !== undefined ||
      inner["types"] !== undefined ||
      inner["type"] !== undefined ||
      inner["active"] !== undefined
    ) {
      record = inner;
      break;
    }
  }

  const id = typeof record["id"] === "string" ? record["id"].trim() : null;
  const name = typeof record["name"] === "string" ? record["name"].trim() : null;
  const types = normalizeServiceTypes(record);
  const active = typeof record["active"] === "boolean"
    ? record["active"]
    : null;
  const bridgeId = typeof record["bridgeId"] === "string"
    ? record["bridgeId"].trim()
    : null;
  let endpoints: Record<string, unknown>[] | null = null;
  if (Array.isArray(record["endpoints"])) {
    endpoints = record["endpoints"].map((endpoint) =>
      sanitizeServiceEndpoint(endpoint)
    );
  } else if (record["endpoints"] !== undefined && record["endpoints"] !== null) {
    endpoints = [sanitizeServiceEndpoint(record["endpoints"])];
  }

  if (!id && !name && types.length === 0 && active === null && !bridgeId) {
    return null;
  }
  return { id, name, types, active, bridgeId, endpoints };
}

// ----------------------------------------------------------------------------
// V3 bridge-services envelope: configured bridge id extraction
// ----------------------------------------------------------------------------

/**
 * Extracts the sanitized `bridge.id` from the official V3 bridge-services
 * envelope. Only the canonical envelope shape `{ bridge: { id: "..." }, ... }`
 * is recognized. Returns null when the shape does not provide an id — callers
 * must then STOP instead of inventing an id.
 */
export function extractV3BridgeId(data: unknown): string | null {
  const sanitized = sanitizePayload(data);
  const record = asRecord(sanitized);
  const bridge = record["bridge"];
  if (typeof bridge !== "object" || bridge === null || Array.isArray(bridge)) {
    return null;
  }
  const bridgeRecord = asRecord(bridge);
  const id = bridgeRecord["id"];
  if (typeof id !== "string" || !id.trim()) return null;
  return id.trim();
}

// ----------------------------------------------------------------------------
// V3 bridge-service/serviceId/{service-id} entry extraction (by-id schema)
// ----------------------------------------------------------------------------

export interface V3BridgeServiceByIdEntry {
  serviceId: string | null;
  bridgeId: string | null;
  name: string | null;
  isHip: boolean | null;
  isHiu: boolean | null;
  active: boolean | null;
}

/**
 * Extracts the sanitized by-id service fields from a
 * `bridge-service/serviceId/{service-id}` response using the OFFICIAL by-id
 * schema: bridgeId, serviceId, name, isHip, isHiu, active.
 *
 * This parser intentionally does NOT read `types`/`type` and does NOT derive
 * `isHip` from the bridge-services list schema. The two endpoints are treated
 * as independent verification signals.
 */
export function extractV3BridgeServiceById(
  data: unknown,
): V3BridgeServiceByIdEntry | null {
  const sanitized = sanitizePayload(data);
  let record = asRecord(sanitized);
  if (Object.keys(record).length === 0 && Array.isArray(sanitized)) {
    const first = sanitized.find((entry) => typeof entry === "object" && entry !== null);
    record = asRecord(first);
  }
  if (Object.keys(record).length === 0) return null;

  for (const wrapperKey of ["service", "data", "result"]) {
    const nested = record[wrapperKey];
    if (typeof nested !== "object" || nested === null || Array.isArray(nested)) {
      continue;
    }
    const inner = asRecord(nested);
    if (
      inner["serviceId"] !== undefined ||
      inner["bridgeId"] !== undefined ||
      inner["isHip"] !== undefined ||
      inner["isHiu"] !== undefined ||
      inner["active"] !== undefined
    ) {
      record = inner;
      break;
    }
  }

  const serviceId = typeof record["serviceId"] === "string"
    ? record["serviceId"].trim()
    : null;
  const bridgeId = typeof record["bridgeId"] === "string"
    ? record["bridgeId"].trim()
    : null;
  const name = typeof record["name"] === "string"
    ? record["name"].trim()
    : null;
  const isHip = typeof record["isHip"] === "boolean" ? record["isHip"] : null;
  const isHiu = typeof record["isHiu"] === "boolean" ? record["isHiu"] : null;
  const active = typeof record["active"] === "boolean" ? record["active"] : null;

  if (
    !serviceId && !bridgeId && !name && isHip === null && isHiu === null &&
    active === null
  ) {
    return null;
  }
  return { serviceId, bridgeId, name, isHip, isHiu, active };
}

// ----------------------------------------------------------------------------
// HFR (Health Facility Registry) software linkage — Multiple HRP API
// ----------------------------------------------------------------------------

/** Official HFR software linkage Sandbox base URL (contract section 2). */
export const HFR_BASE_URL = "https://apihspsbx.abdm.gov.in/v4/int";
/** Official Multiple HRP AddUpdateServices endpoint path. */
export const HFR_SERVICES_PATH = "/v1/bridges/MutipleHRPAddUpdateServices";
/** Per-request timeout for HFR linkage requests. */
export const HFR_TIMEOUT_MS = 15_000;
/** Hard cap for HFR response bodies. */
export const HFR_MAX_BYTES = 512_000;

export interface HfrFacilitySettings {
  /** HFR facility id (used as ABDM V3 service-id). */
  facilityId: string;
  /** Official facility name. */
  facilityName: string;
  /** Short, facility-specific ABDM HIP name. */
  hipName: string;
}

export interface HfrHrpDefinition {
  bridgeId: string;
  hipName: string;
  type: "HIP";
  active: true;
}

export interface HfrLinkagePayload {
  facilityId: string;
  facilityName: string;
  HRP: HfrHrpDefinition[];
}

export interface HfrLinkageValidation {
  ok: boolean;
  errors: string[];
  payload?: HfrLinkagePayload;
}

/**
 * Official HFR facility id shape (ABDM M2): starts with `IN` followed by
 * exactly 10 digits, total length 12. No other characters are allowed.
 */
export function isValidHfrFacilityId(value: string): boolean {
  return /^IN\d{10}$/.test(value.trim());
}

/**
 * Official HIP name restrictions (ABDM M2): required, maximum 15 characters,
 * unique for a bridge/facility, and special characters are not allowed.
 * Conservative production allow-list: letters, digits and spaces only.
 * Leading/trailing whitespace is trimmed by the caller before validation;
 * the value is never silently truncated.
 */
export function isValidAbdmHipName(value: string): boolean {
  return /^[A-Za-z0-9 ]{1,15}$/.test(value.trim());
}

/** Builds the exact HFR Multiple HRP AddUpdateServices request payload. */
export function buildHfrLinkagePayload(
  facility: HfrFacilitySettings,
  bridgeId: string,
): HfrLinkagePayload {
  return {
    facilityId: facility.facilityId.trim(),
    facilityName: facility.facilityName.trim(),
    HRP: [
      {
        bridgeId: bridgeId.trim(),
        hipName: facility.hipName.trim(),
        type: "HIP",
        active: true,
      },
    ],
  };
}

/** Validates the server-side inputs before any HFR request is built. */
export function validateHfrLinkageInput(
  facility: HfrFacilitySettings,
  bridgeId: string,
): HfrLinkageValidation {
  const errors: string[] = [];
  const facilityId = facility.facilityId.trim();
  const facilityName = facility.facilityName.trim();
  const hipName = facility.hipName.trim();
  const resolvedBridgeId = bridgeId.trim();

  if (!isValidHfrFacilityId(facilityId)) {
    errors.push(
      "HFR facility id must be 12 characters: 'IN' followed by 10 digits",
    );
  }
  if (!facilityName) {
    errors.push("Official facility name is not configured");
  } else if (facilityName.length > 255) {
    errors.push("Official facility name must be at most 255 characters");
  }
  if (!isValidAbdmHipName(hipName)) {
    errors.push(
      "ABDM HIP name must be 1-15 characters using only letters, digits and spaces",
    );
  }
  if (!resolvedBridgeId) {
    errors.push("ABDM_BRIDGE_ID is not configured");
  }

  if (errors.length > 0) return { ok: false, errors };
  return {
    ok: true,
    errors,
    payload: buildHfrLinkagePayload(
      { facilityId, facilityName, hipName },
      resolvedBridgeId,
    ),
  };
}

/**
 * Bounded, timed, redirect-safe JSON fetch for the HFR linkage endpoint. Like
 * `v3FetchJson`, it never follows redirects (so the Bearer token can never be
 * re-sent to another host) and enforces timeout + response-size limits. Unlike
 * `v3FetchJson`, it preserves the raw text body when the response is not JSON
 * so the caller can summarize a non-JSON/truncated body safely.
 */
async function hfrFetchJson(
  fetchImpl: FetchImpl,
  url: string,
  init: RequestInit,
  options: { timeoutMs?: number; maxBytes?: number } = {},
): Promise<HfrGatewayHttpResponse> {
  const timeoutMs = options.timeoutMs ?? HFR_TIMEOUT_MS;
  const maxBytes = options.maxBytes ?? HFR_MAX_BYTES;
  const requestInfo: GatewayRequestInfo = {
    method: (init?.method ?? "GET").toUpperCase(),
    hostname: hostnameOfUrl(url),
    pathname: pathnameOfUrl(url),
  };

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  let response: Response;
  try {
    response = await fetchImpl(url, {
      ...init,
      redirect: "manual",
      signal: controller.signal,
    });
  } catch (error) {
    const rawMessage = (error as Error)?.message ?? String(error);
    const category: GatewayErrorCategory = isTimeoutError(error, rawMessage)
      ? "timeout"
      : "network";
    throw new GatewayError(
      0,
      category === "timeout"
        ? "ABDM HFR linkage service timed out"
        : "ABDM HFR linkage service unreachable",
      undefined,
      category,
      requestInfo,
    );
  } finally {
    clearTimeout(timer);
  }

  const declared = Number(response.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > maxBytes) {
    throw new GatewayError(
      response.status,
      "ABDM HFR linkage response exceeded the size limit",
      undefined,
      "http",
      requestInfo,
    );
  }

  const text = await response.text();
  if (text.length > maxBytes) {
    throw new GatewayError(
      response.status,
      "ABDM HFR linkage response exceeded the size limit",
      undefined,
      "http",
      requestInfo,
    );
  }

  let data: unknown = null;
  let rawText: string | null = null;
  if (text.trim()) {
    try {
      data = JSON.parse(text);
    } catch (_) {
      rawText = text;
    }
  }

  return {
    ok: response.ok,
    status: response.status,
    data,
    contentType: response.headers.get("content-type"),
    rawText,
  };
}

/**
 * POST /v1/bridges/MutipleHRPAddUpdateServices on the HFR Sandbox using the
 * CANONICAL V3 gateway access token as the Bearer credential. The deprecated
 * v0.5/v1 token cache is never read here.
 *
 * Network/timeout GatewayErrors are re-labelled for the HFR operation.
 */
export async function hfrPostAddUpdateServices(
  fetchImpl: FetchImpl,
  token: string,
  payload: HfrLinkagePayload,
  config: GatewayConfig,
  options: V3SessionRequestOptions = {},
): Promise<HfrGatewayHttpResponse> {
  const url = `${config.hfrBaseUrl}${config.hfrServicesPath}`;
  try {
    return await hfrFetchJson(
      fetchImpl,
      url,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${token}`,
          // Security rule: every ABDM-family request carries a fresh UUID and
          // current UTC timestamp for traceability.
          "REQUEST-ID": freshV3RequestId(),
          "TIMESTAMP": freshV3Timestamp(),
        },
        body: JSON.stringify(payload),
      },
      {
        timeoutMs: options.timeoutMs ?? HFR_TIMEOUT_MS,
        maxBytes: options.maxBytes ?? HFR_MAX_BYTES,
      },
    );
  } catch (error) {
    if (error instanceof GatewayError) {
      throw new GatewayError(
        error.status,
        error.category === "timeout"
          ? "ABDM HFR linkage service timed out"
          : "ABDM HFR linkage service unreachable",
        error.body,
        error.category,
        error.request,
      );
    }
    throw error;
  }
}

// ----------------------------------------------------------------------------
// HFR upstream response summarization + semantic disposition
// ----------------------------------------------------------------------------

/** HFR HTTP response with the raw (non-JSON) text preserved for diagnostics. */
export interface HfrGatewayHttpResponse extends GatewayHttpResponse {
  rawText: string | null;
}

/** Sanitized, allow-listed summary of the HFR upstream response body. */
export interface HfrUpstreamSummary {
  status: number | null;
  contentType: string | null;
  bodyType: "json" | "text" | "empty";
  code: string | null;
  statusField: string | null;
  message: string | null;
  facilityId: string | null;
  bridgeId: string | null;
  error: string | null;
  validation: string | null;
}

export type HfrBodyDisposition = "success" | "failure" | "unknown";

export interface HfrResponseInterpretation {
  disposition: HfrBodyDisposition;
  summary: HfrUpstreamSummary;
}

const HFR_TEXT_LIMIT = 400;

function hfrSafeText(value: unknown): string {
  const text = typeof value === "string"
    ? value
    : typeof value === "number" || typeof value === "boolean"
    ? String(value)
    : "";
  const clean = text.replace(/\s+/g, " ").trim();
  return clean.length > HFR_TEXT_LIMIT
    ? `${clean.slice(0, HFR_TEXT_LIMIT)}…`
    : clean;
}

function hfrFirstDefinedString(
  record: Record<string, unknown>,
  keys: string[],
): string | null {
  for (const key of keys) {
    const value = record[key];
    if (value === null || value === undefined) continue;
    const text = hfrSafeText(value);
    if (text) return redactSensitiveText(text);
  }
  return null;
}

function hfrErrorLike(value: unknown): string | null {
  if (typeof value === "string") {
    const text = hfrSafeText(value);
    return text ? redactSensitiveText(text) : null;
  }
  if (typeof value === "object" && value !== null) {
    const record = asRecord(value);
    return hfrFirstDefinedString(record, [
      "message",
      "errorMessage",
      "error_message",
      "code",
      "errorCode",
      "error_code",
      "description",
      "detail",
    ]);
  }
  return null;
}

/**
 * Builds a sanitized summary of the HFR upstream response. Only whitelisted
 * safe fields are read: status, content-type, body type, code/status/message,
 * facilityId, bridgeId, and error/validation info. Tokens, secrets, Aadhaar,
 * OTP and patient data are never included.
 */
export function summarizeHfrUpstreamResponse(
  response: HfrGatewayHttpResponse,
): HfrUpstreamSummary {
  const data = sanitizePayload(response.data);
  let bodyType: HfrUpstreamSummary["bodyType"] = "empty";
  let code: string | null = null;
  let statusField: string | null = null;
  let message: string | null = null;
  let facilityId: string | null = null;
  let bridgeId: string | null = null;
  let error: string | null = null;
  let validation: string | null = null;

  if (typeof data === "string") {
    bodyType = "text";
    message = hfrSafeText(redactSensitiveText(data));
  } else if (Array.isArray(data)) {
    bodyType = "json";
    // HFR success bodies are objects; an array is summarized defensively with
    // no whitelisted fields extracted.
    message = null;
  } else if (typeof data === "object" && data !== null) {
    bodyType = "json";
    const record = data as Record<string, unknown>;
    code = hfrFirstDefinedString(record, [
      "code",
      "statusCode",
      "status_code",
      "errorCode",
      "error_code",
      "responseCode",
    ]);
    statusField = hfrFirstDefinedString(record, [
      "status",
      "statusValue",
      "status_value",
      "result",
    ]);
    message = hfrFirstDefinedString(record, [
      "message",
      "errorMessage",
      "error_message",
      "description",
      "msg",
    ]);
    facilityId = hfrFirstDefinedString(record, ["facilityId", "facility_id"]);
    bridgeId = hfrFirstDefinedString(record, ["bridgeId", "bridge_id"]);
    error = hfrErrorLike(record["error"] ?? record["errors"]);
    validation = hfrErrorLike(
      record["validation"] ?? record["validationErrors"] ??
        record["validation_errors"],
    );
  } else if (data !== null && data !== undefined) {
    bodyType = "text";
    message = hfrSafeText(redactSensitiveText(String(data)));
  }

  if (response.rawText && !message && bodyType === "empty") {
    bodyType = "text";
    message = hfrSafeText(redactSensitiveText(response.rawText));
  }

  return {
    status: response.status,
    contentType: response.contentType,
    bodyType,
    code,
    statusField,
    message,
    facilityId,
    bridgeId,
    error,
    validation,
  };
}

const HFR_FAILURE_WORDS = [
  "fail",
  "error",
  "invalid",
  "reject",
  "denied",
  "unauthorized",
  "forbidden",
];
const HFR_SUCCESS_STATUS_VALUES = new Set([
  "success",
  "accepted",
  "ok",
  "true",
  "200",
  "201",
  "202",
  "204",
]);
const HFR_SUCCESS_CODE_VALUES = new Set([
  "success",
  "accepted",
  "ok",
  "0",
  "200",
  "201",
  "202",
  "204",
]);

function hfrContainsFailureSignal(text: string | null): boolean {
  if (!text) return false;
  const lower = text.toLowerCase();
  return HFR_FAILURE_WORDS.some((word) => lower.includes(word));
}

/**
 * Interprets the HFR upstream body semantically. A 2xx status is NOT enough to
 * classify the linkage as accepted:
 *
 *   - explicit error/validation/failure fields or words -> "failure"
 *   - explicit success/status/accepted/ok signal and no failure -> "success"
 *   - anything else (including empty, text, or unrecognized JSON) -> "unknown"
 */
export function interpretHfrUpstreamResponse(
  response: HfrGatewayHttpResponse,
): HfrResponseInterpretation {
  const summary = summarizeHfrUpstreamResponse(response);

  const failureEvidence =
    hfrContainsFailureSignal(summary.code) ||
    hfrContainsFailureSignal(summary.statusField) ||
    hfrContainsFailureSignal(summary.message) ||
    summary.error !== null ||
    summary.validation !== null;

  if (failureEvidence) return { disposition: "failure", summary };

  const statusField = summary.statusField?.toLowerCase() ?? "";
  const code = summary.code?.toLowerCase() ?? "";
  const message = summary.message?.toLowerCase() ?? "";
  const successSignal = HFR_SUCCESS_STATUS_VALUES.has(statusField) ||
    HFR_SUCCESS_CODE_VALUES.has(code) ||
    message.includes("success") ||
    message.includes("accepted") ||
    message.includes("ok");

  if (successSignal) return { disposition: "success", summary };
  return { disposition: "unknown", summary };
}

// ----------------------------------------------------------------------------
// ABHA V3 audit helpers (certificate + runtime encryption algorithm)
// ----------------------------------------------------------------------------

/** Official ABHA V3 public certificate endpoint (audit reference only). */
export const ABHA_V3_CERTIFICATE_PATH =
  "/abha/api/v3/profile/public/certificate";

/**
 * Extracts the `encryptionAlgorithm` returned by the ABHA V3 certificate
 * endpoint. Future M1 encryption code must prefer this runtime value over any
 * hard-coded introductory/static value.
 */
export function extractAbhaEncryptionAlgorithm(data: unknown): string | null {
  const record = asRecord(sanitizePayload(data));
  const value = record["encryptionAlgorithm"];
  if (typeof value === "string" && value.trim()) return value.trim();
  return null;
}

/**
 * Prefers the runtime `encryptionAlgorithm` from the certificate endpoint and
 * only falls back to the provided static value when the API did not return
 * one. This prevents a conflicting Swagger introductory value from being
 * blindly hard-coded over the live API response.
 */
export function preferRuntimeEncryptionAlgorithm(
  runtimeValue: string | null | undefined,
  fallback?: string,
): string | null {
  const runtime = (runtimeValue ?? "").trim();
  if (runtime) return runtime;
  const staticValue = (fallback ?? "").trim();
  return staticValue || null;
}

// ----------------------------------------------------------------------------
// Read-only V3 bridge envelope inspection (no mutation, no token echo)
// ----------------------------------------------------------------------------

const V3_SENSITIVE_KEY_NAMES = new Set([
  "accesstoken",
  "token",
  "refreshtoken",
  "authorization",
  "clientsecret",
  "secret",
  "clientid",
  "apikey",
  "password",
  "credential",
  "credentials",
  "cookie",
  "cookies",
  "setcookie",
  "jwt",
]);

const V3_BRIDGE_KEY_ALIASES = new Set(["bridge"]);
const V3_SERVICES_KEY_ALIASES = new Set(["services"]);
const V3_URL_KEY_ALIASES = new Set([
  "url",
  "hosturl",
  "bridgeurl",
  "callbackurl",
  "address",
  "endpoint",
]);

function v3NormalizeKey(key: string): string {
  return key.toLowerCase().replace(/[^a-z0-9]/g, "");
}

/** True when a field NAME is safe to echo (sensitive names are never echoed). */
function v3SafeFieldName(key: string): boolean {
  return !V3_SENSITIVE_KEY_NAMES.has(v3NormalizeKey(key));
}

function v3TruncateFieldNames(keys: string[]): string[] {
  return keys
    .slice(0, 200)
    .map((key) => sanitizeDiagnosticText(key));
}

function v3TopLevelTypeOf(value: unknown): string {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  return typeof value;
}

function v3SanitizeServiceItems(raw: unknown[]): Record<string, unknown>[] {
  const items: Record<string, unknown>[] = [];
  for (const entry of raw) {
    if (typeof entry !== "object" || entry === null || Array.isArray(entry)) {
      continue;
    }
    const record = entry as Record<string, unknown>;
    const item: Record<string, unknown> = {};
    const types = normalizeServiceTypes(record);
    if (record["id"] !== undefined) {
      item["id"] = sanitizeDiagnosticText(record["id"]);
    }
    if (record["name"] !== undefined) {
      item["name"] = sanitizeDiagnosticText(record["name"]);
    }
    if (record["bridgeId"] !== undefined) {
      item["bridgeId"] = sanitizeDiagnosticText(record["bridgeId"]);
    }
    if (types.length > 0) item["types"] = types;
    if (typeof record["active"] === "boolean") {
      item["active"] = record["active"];
    }
    if (record["endpoints"] !== undefined && record["endpoints"] !== null) {
      item["endpoints"] = Array.isArray(record["endpoints"])
        ? record["endpoints"].map((endpoint) =>
          sanitizeServiceEndpoint(endpoint)
        )
        : sanitizeServiceEndpoint(record["endpoints"]);
    }
    items.push(item);
  }
  return items;
}

/**
 * Returns a sanitized bridge URL only when it is an absolute http(s) URL.
 * Query strings and fragments are intentionally dropped, the value is
 * token-redacted and truncated. Anything else returns null.
 */
export function sanitizeV3UrlValue(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (trimmed.length === 0 || trimmed.length > 2000) return null;
  let url: URL;
  try {
    url = new URL(trimmed);
  } catch (_) {
    return null;
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") return null;
  const safe = redactSensitiveText(`${url.origin}${url.pathname}`);
  return safe.length > 300 ? `${safe.slice(0, 300)}…` : safe;
}

function v3FindUrlField(
  record: Record<string, unknown>,
): { exists: boolean; value: string | null } {
  for (const [key, value] of Object.entries(record)) {
    if (!v3SafeFieldName(key)) continue;
    if (V3_URL_KEY_ALIASES.has(v3NormalizeKey(key))) {
      return { exists: true, value: sanitizeV3UrlValue(value) };
    }
  }
  return { exists: false, value: null };
}

/**
 * Builds a sanitized, shape-only description of a successful V3
 * bridge-services response body. It never returns raw values except for the
 * allow-listed service id/name/type/active fields and a sanitized, query-free
 * bridge URL. Field names are filtered so sensitive names are never echoed.
 */
export function buildV3EnvelopeInspection(data: unknown): V3EnvelopeInspection {
  const topLevelType = v3TopLevelTypeOf(data);
  const topLevelFieldNames: string[] = [];
  let bridge: V3EnvelopeInspection["bridge"] = {
    exists: false,
    fieldNames: [],
  };
  let bridgeUrl: V3EnvelopeInspection["bridgeUrl"] = {
    exists: false,
    value: null,
  };
  let services: V3EnvelopeInspection["services"] = {
    exists: false,
    length: null,
    items: [],
  };
  const unknownEnvelopeFieldNames: string[] = [];

  if (Array.isArray(data)) {
    // A top-level array is the same shape the existing diagnoseV3Gateway
    // parser recognizes as a service list.
    services = {
      exists: true,
      length: data.length,
      items: v3SanitizeServiceItems(data),
    };
  } else if (typeof data === "object" && data !== null) {
    const record = data as Record<string, unknown>;
    for (const key of Object.keys(record)) {
      if (v3SafeFieldName(key)) topLevelFieldNames.push(key);
    }

    for (const [key, value] of Object.entries(record)) {
      if (!v3SafeFieldName(key)) continue;
      if (!V3_BRIDGE_KEY_ALIASES.has(v3NormalizeKey(key))) continue;
      if (typeof value !== "object" || value === null || Array.isArray(value)) {
        continue;
      }
      const bridgeRecord = value as Record<string, unknown>;
      bridge = {
        exists: true,
        fieldNames: Object.keys(bridgeRecord).filter(v3SafeFieldName),
      };
      bridgeUrl = v3FindUrlField(bridgeRecord);
      break;
    }

    for (const [key, value] of Object.entries(record)) {
      if (!v3SafeFieldName(key)) continue;
      if (!V3_SERVICES_KEY_ALIASES.has(v3NormalizeKey(key))) continue;
      if (Array.isArray(value)) {
        services = {
          exists: true,
          length: value.length,
          items: v3SanitizeServiceItems(value),
        };
      } else {
        services = { exists: true, length: null, items: [] };
      }
      break;
    }

    // If no dedicated bridge object carried the URL, a top-level URL/hostUrl
    // field may still be the bridge URL.
    if (!bridgeUrl.exists) bridgeUrl = v3FindUrlField(record);

    for (const key of Object.keys(record)) {
      if (!v3SafeFieldName(key)) continue;
      const normalized = v3NormalizeKey(key);
      if (
        !V3_BRIDGE_KEY_ALIASES.has(normalized) &&
        !V3_SERVICES_KEY_ALIASES.has(normalized)
      ) {
        unknownEnvelopeFieldNames.push(key);
      }
    }
  }

  return {
    topLevelType,
    topLevelFieldNames: v3TruncateFieldNames(topLevelFieldNames),
    bridge: { ...bridge, fieldNames: v3TruncateFieldNames(bridge.fieldNames) },
    bridgeUrl,
    services,
    unknownEnvelopeFieldNames: v3TruncateFieldNames(unknownEnvelopeFieldNames),
  };
}

/** Maps a V3 stage failure to the documented ABDM_V3_* code family. */
export function v3FailureCode(
  stage: "session" | "services",
  status: number,
  category: V3FailureCategory,
): string {
  if (category === "timeout") {
    return stage === "session"
      ? "ABDM_V3_SESSION_TIMEOUT"
      : "ABDM_V3_SERVICES_TIMEOUT";
  }
  if (category === "network") {
    return stage === "session"
      ? "ABDM_V3_SESSION_NETWORK"
      : "ABDM_V3_SERVICES_NETWORK";
  }
  if (category === "protocol") return "ABDM_V3_PROTOCOL_ERROR";
  return stage === "session"
    ? `ABDM_V3_SESSION_${status}`
    : `ABDM_V3_SERVICES_${status}`;
}

/** Short sanitized message for a V3 stage failure (no tokens/secrets/bodies). */
export function v3FailureMessage(
  stage: "session" | "services",
  status: number,
  category: V3FailureCategory,
): string {
  if (category === "timeout") {
    return `V3 ${stage} request timed out before receiving a response.`;
  }
  if (category === "network") {
    return `V3 ${stage} request failed: the ABDM gateway is unreachable.`;
  }
  if (category === "protocol") {
    return `V3 ${stage} response did not match the documented schema.`;
  }
  if (stage === "session") {
    return status === 401 || status === 403
      ? `V3 session was rejected by ABDM (HTTP ${status}).`
      : `V3 session request failed: ABDM returned HTTP ${status}.`;
  }
  if (status === 403) {
    return "V3 services inspection failed: access was denied for this request.";
  }
  if (status === 401) {
    return "V3 services inspection failed: the ABDM access token was not accepted (HTTP 401).";
  }
  return `V3 services inspection failed: ABDM returned HTTP ${status}.`;
}

/**
 * Bounded, timed, redirect-safe JSON fetch used ONLY by the isolated V3
 * diagnostic. Unlike `safeFetchJson`, it never follows redirects (so a Bearer
 * token can never be re-sent to another host) and it enforces an explicit
 * timeout plus a hard response-body size limit.
 */
export async function v3FetchJson(
  fetchImpl: FetchImpl,
  url: string,
  init: RequestInit,
  options: { timeoutMs?: number; maxBytes?: number } = {},
): Promise<GatewayHttpResponse> {
  const timeoutMs = options.timeoutMs ?? V3_DIAGNOSTIC_TIMEOUT_MS;
  const maxBytes = options.maxBytes ?? V3_DIAGNOSTIC_MAX_BYTES;
  const requestInfo: GatewayRequestInfo = {
    method: (init?.method ?? "GET").toUpperCase(),
    hostname: hostnameOfUrl(url),
    pathname: pathnameOfUrl(url),
  };

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  let response: Response;
  try {
    response = await fetchImpl(url, {
      ...init,
      redirect: "manual",
      signal: controller.signal,
    });
  } catch (error) {
    const rawMessage = (error as Error)?.message ?? String(error);
    const category: GatewayErrorCategory = isTimeoutError(error, rawMessage)
      ? "timeout"
      : "network";
    throw new GatewayError(
      0,
      category === "timeout"
        ? "ABDM gateway timed out"
        : "ABDM gateway unreachable",
      undefined,
      category,
      requestInfo,
    );
  } finally {
    clearTimeout(timer);
  }

  const declared = Number(response.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > maxBytes) {
    throw new GatewayError(
      response.status,
      "ABDM gateway response exceeded the size limit",
      undefined,
      "http",
      requestInfo,
    );
  }

  const text = await response.text();
  if (text.length > maxBytes) {
    throw new GatewayError(
      response.status,
      "ABDM gateway response exceeded the size limit",
      undefined,
      "http",
      requestInfo,
    );
  }

  let data: unknown = null;
  if (text.trim()) {
    try {
      data = JSON.parse(text);
    } catch (_) {
      data = null;
    }
  }

  return {
    ok: response.ok,
    status: response.status,
    data,
    contentType: response.headers.get("content-type"),
  };
}

// ----------------------------------------------------------------------------
// M1 (ABHA identity) contract gate + validation helpers
// ----------------------------------------------------------------------------

export const ABDM_M1_CONTRACT_UNCONFIRMED = "ABDM_M1_CONTRACT_UNCONFIRMED";

export type M1Action =
  | "m1GenerateAadhaarOtp"
  | "m1VerifyAadhaarOtp"
  | "m1CreateAbha"
  | "m1GetProfile"
  | "m1VerifyAbhaNumber"
  | "m1SearchByMobile"
  | "m1VerifyAbhaAddress"
  | "m1GetAbhaCard"
  | "m1GetAbhaQr";

/**
 * Returns the configured official endpoint path for an M1 action, or an empty
 * string when the contract has not been confirmed/configured for it. An empty
 * string means the handler MUST stop with ABDM_M1_CONTRACT_UNCONFIRMED.
 */
export function m1PathForAction(
  config: GatewayConfig,
  action: M1Action,
): string {
  switch (action) {
    case "m1GenerateAadhaarOtp":
      return config.m1GenerateAadhaarOtpPath;
    case "m1VerifyAadhaarOtp":
      return config.m1VerifyAadhaarOtpPath;
    case "m1CreateAbha":
      return config.m1CreateAbhaPath;
    case "m1GetProfile":
      return config.m1GetProfilePath;
    case "m1VerifyAbhaNumber":
      return config.m1VerifyAbhaNumberPath;
    case "m1SearchByMobile":
      return config.m1SearchByMobilePath;
    case "m1VerifyAbhaAddress":
      return config.m1VerifyAbhaAddressPath;
    case "m1GetAbhaCard":
      return config.m1GetAbhaCardPath;
    case "m1GetAbhaQr":
      return config.m1GetAbhaQrPath;
  }
}

/** True when both the M1 base URL and the operation path are configured. */
export function isM1ContractConfigured(
  config: GatewayConfig,
  action: M1Action,
): boolean {
  return config.m1BaseUrl.trim() !== "" &&
    m1PathForAction(config, action).trim() !== "";
}

/**
 * M1 patient-facing permission policy. Bridge/service-management actions stay
 * admin/super_admin-only; M1 identity operations are available to the roles
 * configured in `ABDM_M1_ALLOWED_ROLES` (default super_admin, admin,
 * receptionist).
 */
export function isM1RoleAllowed(
  role: string,
  allowedRoles: readonly string[],
): boolean {
  const normalized = role.trim().toLowerCase();
  return allowedRoles.some((allowed) =>
    allowed.trim().toLowerCase() === normalized
  );
}

/** Aadhaar must be exactly 12 numeric digits before any encryption/use. */
export function isValidAadhaar(value: string): boolean {
  return /^\d{12}$/.test(value);
}

/**
 * OTP validation. ABDM Sandbox Aadhaar OTP is 6 digits per the official
 * onboarding documentation — REQUIRES_OFFICIAL_CONFIRMATION if the current
 * client contract specifies a different length.
 */
export function isValidM1Otp(value: string): boolean {
  return /^\d{6}$/.test(value);
}

/** Indian mobile validation (10 digits, valid leading digit). */
export function isValidIndianMobile(value: string): boolean {
  return /^[6-9]\d{9}$/.test(value);
}

/** Normalizes an ABHA number (14 digits, optional `XX-XXXX-XXXX-XXXX` form). */
export function normalizeAbhaNumber(value: string): string {
  return value.replace(/[\s-]/g, "").toUpperCase();
}

/** True for the official 14-digit ABHA number shape (dashes optional). */
export function isValidAbhaNumber(value: string): boolean {
  return /^\d{14}$/.test(normalizeAbhaNumber(value));
}

/**
 * ABHA Address validation against the configured official domains. The
 * accepted domains are configurable (ABDM_M1_ABHA_ADDRESS_SUFFIXES, default
 * `abdm,sbx`) so the code never hard-codes `@abdm` only.
 */
export function isValidAbhaAddress(
  value: string,
  allowedSuffixes: readonly string[],
): boolean {
  const address = value.trim().toLowerCase();
  if (address.length === 0 || address.length > 80) return false;
  const suffixes = allowedSuffixes
    .map((s) => s.trim().toLowerCase().replace(/^\./, ""))
    .filter(Boolean);
  if (suffixes.length === 0) return false;
  const suffixPattern = suffixes.map((s) =>
    s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  ).join("|");
  return new RegExp(`^[a-z0-9][a-z0-9._-]{0,63}@(${suffixPattern})$`).test(
    address,
  );
}

/** Masks a mobile number to the final four digits for safe display/audit. */
export function maskMobileNumber(value: unknown): string {
  const text = typeof value === "string" ? value.trim() : "";
  if (!text) return "";
  // Already masked by the gateway (e.g. XXXXXX1234 / ******1234).
  if (/^[*Xx]+\d{4}$/.test(text) || text.includes("*") || text.includes("X")) {
    return text;
  }
  const digits = text.replace(/\D/g, "");
  if (digits.length >= 4) {
    return `XXXXXX${digits.slice(-4)}`;
  }
  return "[REDACTED]";
}

/** Maps an M1 upstream failure to the structured ABDM_M1_* error contract. */
export function m1MapUpstreamError(
  status: number,
  category: "timeout" | "network" | "http" = "http",
): string {
  if (category === "timeout") return "ABDM_M1_TIMEOUT";
  if (category === "network") return "ABDM_M1_NETWORK";
  switch (status) {
    case 400:
      return "ABDM_M1_UPSTREAM_400";
    case 401:
      return "ABDM_M1_UPSTREAM_401";
    case 403:
      return "ABDM_M1_UPSTREAM_403";
    case 404:
      return "ABDM_M1_UPSTREAM_404";
    case 409:
      return "ABDM_M1_UPSTREAM_409";
    case 429:
      return "ABDM_M1_UPSTREAM_429";
    default:
      if (status >= 500) return "ABDM_M1_UPSTREAM_500";
      return `ABDM_M1_UPSTREAM_${status}`;
  }
}

const M1_PROFILE_ALLOWED_KEYS = new Set([
  "healthid",
  "healthidnumber",
  "abhaaddress",
  "name",
  "firstname",
  "lastname",
  "gender",
  "dateofbirth",
  "yearofbirth",
  "mobilenumber",
  "email",
  "state",
  "district",
  "status",
  "isnew",
  "txnid",
]);

function normalizeM1Key(key: string): string {
  return key.toLowerCase().replace(/[^a-z0-9]/g, "");
}

function sanitizeM1ProfileEntry(entry: unknown): Record<string, unknown> {
  const sanitized = sanitizePayload(entry);
  const record = asRecord(sanitized);
  const out: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(record)) {
    const normalized = normalizeM1Key(key);
    if (!M1_PROFILE_ALLOWED_KEYS.has(normalized)) continue;
    if (normalized === "mobilenumber") {
      const masked = maskMobileNumber(value);
      if (masked) out["mobileNumber"] = masked;
      continue;
    }
    if (typeof value === "string" && value.length > 300) {
      out[key] = `${value.slice(0, 300)}...[truncated]`;
      continue;
    }
    out[key] = value;
  }
  return out;
}

export interface M1ProfileExtract {
  profiles: Record<string, unknown>[];
  multiple: boolean;
}

/**
 * Allow-lists ABHA profile fields from an arbitrary upstream JSON response.
 * The raw payload first passes through `sanitizePayload` (token/OTP/Aadhaar
 * key redaction); then only the official non-sensitive profile fields are kept
 * and mobile numbers are masked. Supports both a single profile object and an
 * `accounts`/`profiles` array (mobile search can return multiple accounts).
 */
export function extractM1Profiles(data: unknown): M1ProfileExtract {
  const sanitized = sanitizePayload(data);
  const record = asRecord(sanitized);
  let raw: unknown[];
  if (Array.isArray(sanitized)) {
    raw = sanitized;
  } else if (Array.isArray(record["accounts"])) {
    raw = record["accounts"] as unknown[];
  } else if (Array.isArray(record["profiles"])) {
    raw = record["profiles"] as unknown[];
  } else {
    raw = [sanitized];
  }
  const profiles = raw
    .filter((entry) =>
      typeof entry === "object" && entry !== null && !Array.isArray(entry)
    )
    .map((entry) => sanitizeM1ProfileEntry(entry))
    .filter((profile) => Object.keys(profile).length > 0);
  return { profiles, multiple: profiles.length > 1 };
}

// ----------------------------------------------------------------------------
// Binary gateway responses (ABHA card / QR image handling)
// ----------------------------------------------------------------------------

export interface GatewayBinaryResponse {
  ok: boolean;
  status: number;
  contentType: string | null;
  bytes: Uint8Array;
}

const BINARY_CONTENT_TYPES = new Set([
  "image/png",
  "image/jpeg",
  "application/pdf",
]);

/**
 * Fetches a binary gateway response (card/QR) with a hard byte limit and a
 * content-type allow-list. Never returns text parsed from the body; callers
 * receive raw bytes only. Used by the M1 card/QR plumbing once the official
 * contract is confirmed.
 */
export async function safeFetchBinary(
  fetchImpl: FetchImpl,
  url: string,
  init: RequestInit,
  maxBytes = 5_000_000,
): Promise<GatewayBinaryResponse> {
  const requestInfo: GatewayRequestInfo = {
    method: (init?.method ?? "GET").toUpperCase(),
    hostname: hostnameOfUrl(url),
    pathname: pathnameOfUrl(url),
  };

  let response: Response;
  try {
    response = await fetchImpl(url, init);
  } catch (error) {
    const rawMessage = (error as Error)?.message ?? String(error);
    const category: GatewayErrorCategory = isTimeoutError(error, rawMessage)
      ? "timeout"
      : "network";
    throw new GatewayError(
      0,
      category === "timeout"
        ? "ABDM gateway timed out"
        : "ABDM gateway unreachable",
      undefined,
      category,
      requestInfo,
    );
  }

  const contentType = response.headers.get("content-type") ?? "";
  if (!response.ok) {
    let data: unknown = null;
    try {
      data = await response.json();
    } catch (_) {
      data = null;
    }
    throw new GatewayError(
      response.status,
      `ABDM gateway request failed with status ${response.status}`,
      sanitizePayload(data),
      "http",
      requestInfo,
    );
  }

  if (
    contentType &&
    ![...BINARY_CONTENT_TYPES].some((t) =>
      contentType.toLowerCase().startsWith(t)
    )
  ) {
    throw new GatewayError(
      response.status,
      "ABDM gateway returned an unsupported binary content type",
      undefined,
      "http",
      requestInfo,
    );
  }

  const declared = Number(response.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > maxBytes) {
    throw new GatewayError(
      response.status,
      "ABDM gateway binary response exceeded the size limit",
      undefined,
      "http",
      requestInfo,
    );
  }

  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.byteLength > maxBytes) {
    throw new GatewayError(
      response.status,
      "ABDM gateway binary response exceeded the size limit",
      undefined,
      "http",
      requestInfo,
    );
  }

  return { ok: response.ok, status: response.status, contentType, bytes };
}

// ----------------------------------------------------------------------------
// Routing
// ----------------------------------------------------------------------------

/** Extracts the sub-path after the function name from a request URL. */
export function getSubpath(url: string, functionName = FUNCTION_NAME): string {
  const pathname = new URL(url).pathname;
  const segments = pathname.split("/").filter(Boolean);
  const index = segments.indexOf(functionName);
  if (index === -1) return pathname === "/" ? "" : pathname;
  const remainder = segments.slice(index + 1).join("/");
  return remainder ? `/${remainder}` : "";
}

export type InternalAction =
  | "session"
  | "bridge"
  | "services"
  | "getServices"
  | "diagnoseV3Gateway"
  | "inspectV3Bridge"
  | "health"
  | M1Action;

const RESERVED_SUBPATHS = new Set([
  "/session",
  "/bridge",
  "/services",
  "/diagnosev3gateway",
  "/inspectv3bridge",
  "/health",
]);

/**
 * True when a subpath collides with a protected internal action path. Such
 * paths must never be treated as public callbacks, even when the HTTP method
 * does not match the internal action (for example `POST /bridge`).
 */
export function isReservedSubpath(subpath: string): boolean {
  const path = subpath.toLowerCase().replace(/\/+$/, "");
  return RESERVED_SUBPATHS.has(path);
}

/**
 * Determines which internal action a request targets. URL sub-paths
 * (`/abdm-gateway/session`) and body/query `action` values are supported so
 * the Flutter client can use `supabase.functions.invoke()` (which always
 * targets the bare function URL).
 *
 * SAFETY: when the request targets a non-empty callback subpath, `action`
 * values from the body/query are deliberately IGNORED — a public callback can
 * never be promoted into an administrative action by manipulating JSON/query
 * parameters. Administrative actions always require a user JWT + admin role
 * inside `handleInternalAction`.
 */
export function resolveInternalAction(
  method: string,
  subpath: string,
  bodyAction?: string,
  queryAction?: string,
): InternalAction | null {
  const path = subpath.toLowerCase().replace(/\/+$/, "");
  const m = method.toUpperCase();

  if (path === "/session" && m === "POST") return "session";
  // The production Flutter client uses POST `{"action":"bridge"}` on the bare
  // function URL. Inbound PATCH remains supported for backward compatibility.
  if (path === "/bridge" && m === "PATCH") return "bridge";
  if (path === "/services" && (m === "POST" || m === "GET")) return "services";
  if (path === "/diagnosev3gateway" && m === "POST") return "diagnoseV3Gateway";
  if (path === "/inspectv3bridge" && m === "POST") return "inspectV3Bridge";
  if (path === "/health" && m === "GET") return "health";

  if (!path) {
    const action = (bodyAction ?? queryAction ?? "").toLowerCase();
    if (action === "session" && m === "POST") return "session";
    if (action === "bridge" && (m === "POST" || m === "PATCH")) return "bridge";
    // The production Flutter client uses POST {"action":"getServices"} so the
    // browser never has to preflight a non-simple GET method token.
    if (action === "getservices" && m === "POST") return "getServices";
    if (action === "services" && (m === "POST" || m === "GET")) {
      return "services";
    }
    // The isolated V3 diagnostic is POST {"action":"diagnoseV3Gateway"} on the
    // bare function URL only. It is protected (JWT + admin) and never reaches
    // the public callback branch.
    if (action === "diagnosev3gateway" && m === "POST") {
      return "diagnoseV3Gateway";
    }
    // The read-only V3 bridge inspection is POST {"action":"inspectV3Bridge"}
    // on the bare function URL only. Protected (JWT + admin), never a callback.
    if (action === "inspectv3bridge" && m === "POST") {
      return "inspectV3Bridge";
    }
    if (action === "health" && m === "GET") return "health";
    // M1 actions are Flutter POST {"action":"<m1 action>","payload":{}} on
    // the bare function URL only — never reachable through a callback subpath.
    const m1Action = m1ActionFromName(action);
    if (m === "POST" && m1Action) return m1Action;
  }

  return null;
}

const M1_ACTION_NAMES: Readonly<Record<string, M1Action>> = {
  m1generateaadhaarotp: "m1GenerateAadhaarOtp",
  m1verifyaadhaarotp: "m1VerifyAadhaarOtp",
  m1createabha: "m1CreateAbha",
  m1getprofile: "m1GetProfile",
  m1verifyabhanumber: "m1VerifyAbhaNumber",
  m1searchbymobile: "m1SearchByMobile",
  m1verifyabhaaddress: "m1VerifyAbhaAddress",
  m1getabhacard: "m1GetAbhaCard",
  m1getabhaqr: "m1GetAbhaQr",
};

/** Maps a lowercased action name to the canonical M1 action, or null. */
export function m1ActionFromName(action: string): M1Action | null {
  return M1_ACTION_NAMES[action] ?? null;
}

/** True when the action name (any case) is one of the protected M1 actions. */
export function isM1ActionName(action: string): action is M1Action {
  return m1ActionFromName(action.toLowerCase()) !== null;
}

// ----------------------------------------------------------------------------
// Service definition validation (exact addUpdateServices array body)
// ----------------------------------------------------------------------------

export interface AbdmServiceEndpoint {
  address: string;
  connectionType: string;
  use: string;
}

export interface AbdmServiceDefinition {
  id: string;
  name: string;
  type: string;
  active: boolean;
  alias: string[];
  endpoints: AbdmServiceEndpoint[];
}

export interface ServiceValidationResult {
  ok: boolean;
  errors: string[];
  services?: AbdmServiceDefinition[];
}

function asString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function validateServiceEntry(
  entry: unknown,
  index: number,
  allowedTypes: Set<string>,
): { errors: string[]; service?: AbdmServiceDefinition } {
  const errors: string[] = [];
  const prefix = `services[${index}]`;

  if (typeof entry !== "object" || entry === null || Array.isArray(entry)) {
    return { errors: [`${prefix} must be an object`] };
  }
  const s = entry as Record<string, unknown>;

  const id = asString(s["id"]);
  const name = asString(s["name"]);
  const type = asString(s["type"]).toUpperCase();
  const active = s["active"];
  const alias = s["alias"];

  if (!id) errors.push(`${prefix}.id is required`);
  if (!name) errors.push(`${prefix}.name is required`);
  if (!type) {
    errors.push(`${prefix}.type is required`);
  } else if (!allowedTypes.has(type)) {
    errors.push(
      `${prefix}.type must be one of the official service types: ${
        [...allowedTypes].join(", ")
      }`,
    );
  }
  if (typeof active !== "boolean") {
    errors.push(`${prefix}.active must be a boolean`);
  }
  if (!Array.isArray(alias) || alias.some((a) => typeof a !== "string")) {
    errors.push(`${prefix}.alias must be an array of strings`);
  }

  const endpoints: AbdmServiceEndpoint[] = [];
  const endpointsRaw = s["endpoints"];
  if (!Array.isArray(endpointsRaw) || endpointsRaw.length === 0) {
    errors.push(`${prefix}.endpoints must be a non-empty array`);
  } else {
    endpointsRaw.forEach((endpoint, endpointIndex) => {
      const epPrefix = `${prefix}.endpoints[${endpointIndex}]`;
      if (
        typeof endpoint !== "object" ||
        endpoint === null ||
        Array.isArray(endpoint)
      ) {
        errors.push(`${epPrefix} must be an object`);
        return;
      }
      const ep = endpoint as Record<string, unknown>;
      const address = asString(ep["address"]);
      const connectionType = asString(ep["connectionType"]);
      const use = asString(ep["use"]);

      if (!address) {
        errors.push(`${epPrefix}.address is required (do not use "url")`);
      } else if (!/^https:\/\//i.test(address)) {
        errors.push(`${epPrefix}.address must start with https://`);
      }
      if (!connectionType) {
        errors.push(`${epPrefix}.connectionType is required`);
      } else if (connectionType.toLowerCase() !== "https") {
        errors.push(`${epPrefix}.connectionType must be "https"`);
      }
      if (!use) errors.push(`${epPrefix}.use is required`);

      if (address && connectionType.toLowerCase() === "https" && use) {
        endpoints.push({ address, connectionType, use });
      }
    });
  }

  if (errors.length > 0) return { errors };

  return {
    errors,
    service: {
      id,
      name,
      type,
      active: active as boolean,
      alias: alias as string[],
      endpoints,
    },
  };
}

/**
 * Validates the exact `addUpdateServices` array payload:
 *
 *   {
 *     "action": "services",
 *     "services": [
 *       {
 *         "id": "<service-id>",
 *         "name": "<service-name>",
 *         "type": "<official-service-type>",
 *         "active": true,
 *         "alias": ["<alias>"],
 *         "endpoints": [
 *           { "address": "<https-endpoint>", "connectionType": "https", "use": "<official-endpoint-use>" }
 *         ]
 *       }
 *     ]
 *   }
 *
 * `address` is never renamed to `url`, and `alias` is preserved exactly as an
 * array of strings. `type` is validated against the configured official
 * service-type list (`ABDM_SERVICE_TYPES`).
 */
export function validateServicesPayload(
  body: unknown,
  allowedTypes: readonly string[],
): ServiceValidationResult {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, errors: ["Request body must be a JSON object"] };
  }
  const record = body as Record<string, unknown>;
  const raw = record["services"];
  if (!Array.isArray(raw) || raw.length === 0) {
    return { ok: false, errors: ["services must be a non-empty array"] };
  }

  const allowed = new Set(allowedTypes.map((t) => t.toUpperCase()));
  const services: AbdmServiceDefinition[] = [];
  const errors: string[] = [];

  raw.forEach((entry, index) => {
    const result = validateServiceEntry(entry, index, allowed);
    errors.push(...result.errors);
    if (result.service) services.push(result.service);
  });

  if (errors.length > 0) return { ok: false, errors };
  return { ok: true, errors, services };
}

// ----------------------------------------------------------------------------
// Callback metadata + persistence
// ----------------------------------------------------------------------------

export interface CallbackRow {
  hospital_id: string | null;
  callback_path: string;
  request_id: string | null;
  transaction_id: string | null;
  callback_type: string;
  payload: Record<string, unknown>;
  processing_status: string;
  retry_count: number;
  error_message: string | null;
  gateway_timestamp: string | null;
  received_at: string;
  created_at: string;
}

/**
 * Builds the database row for an incoming ABDM callback.
 *
 * SECURITY:
 *  * Authorization headers are intentionally not part of this function's input.
 *  * `hospital_id` is NOT taken from the callback body. A client-supplied
 *    hospital id is untrusted for RLS ownership; callbacks are stored with
 *    `hospital_id = null` until a deterministic server-side mapping (for
 *    example ABDM HIP/HIU id -> hospital) is specified by the official docs.
 */
export function buildCallbackRow(input: {
  subpath: string;
  body: Record<string, unknown>;
  requestId?: string;
  transactionId?: string;
  callbackType?: string;
  gatewayTimestamp?: string;
  receivedAt?: string;
}): CallbackRow {
  const receivedAt = input.receivedAt ?? new Date().toISOString();
  const body = input.body ?? {};

  return {
    hospital_id: null,
    callback_path: input.subpath || "/",
    request_id: input.requestId ?? null,
    transaction_id: input.transactionId ?? null,
    callback_type: input.callbackType ?? "unknown",
    payload: sanitizePayload(body) as Record<string, unknown>,
    processing_status: "pending",
    retry_count: 0,
    error_message: null,
    gateway_timestamp: input.gatewayTimestamp ?? null,
    received_at: receivedAt,
    created_at: receivedAt,
  };
}

/** Reads callback request-id / timestamp style headers case-insensitively. */
export function readHeader(
  headers: Headers,
  ...names: string[]
): string | undefined {
  for (const name of names) {
    const value = headers.get(name);
    if (value && value.trim()) return value.trim();
  }
  return undefined;
}

export interface CallbackStore {
  insert(
    row: CallbackRow,
  ): Promise<{ error: { code?: string; message: string } | null }>;
}

export type PersistCallbackResult = "inserted" | "duplicate";

/**
 * Persists a callback row. A unique-constraint violation (duplicate
 * request_id + callback_path) is treated as a successful idempotent no-op so
 * ABDM retries never produce duplicate rows.
 */
export async function persistCallback(
  store: CallbackStore,
  row: CallbackRow,
): Promise<PersistCallbackResult> {
  const { error } = await store.insert(row);
  if (!error) return "inserted";
  if (error.code === "23505") return "duplicate";
  throw new Error(`callback persistence failed: ${error.message}`);
}

// ----------------------------------------------------------------------------
// Misc helpers
// ----------------------------------------------------------------------------

export function asRecord(value: unknown): Record<string, unknown> {
  if (typeof value === "object" && value !== null && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }
  return {};
}

export function parsePositiveInt(value: unknown, fallback: number): number {
  if (typeof value === "number" && Number.isFinite(value) && value > 0) {
    return Math.floor(value);
  }
  if (typeof value === "string") {
    const parsed = Number.parseInt(value, 10);
    if (Number.isFinite(parsed) && parsed > 0) return parsed;
  }
  return fallback;
}
