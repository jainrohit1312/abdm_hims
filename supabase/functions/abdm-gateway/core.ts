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
   * Official service types accepted for `services[].type`. Configurable via
   * ABDM_SERVICE_TYPES (comma-separated). Defaults to HIP,HIU — REQUIRES
   * CONFIRMATION from the onboarding email / current official docs.
   */
  allowedServiceTypes: string[];
  /** Seconds subtracted from token expiry before it is considered stale. */
  tokenSafetyMarginSeconds: number;
}

export interface ConfigResult {
  ok: boolean;
  config?: GatewayConfig;
  missing: string[];
}

/** Secret names that MUST exist only as Supabase Edge Function secrets. */
export const REQUIRED_SECRET_NAMES = ["ABDM_CLIENT_ID", "ABDM_CLIENT_SECRET"] as const;

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
  for (const name of REQUIRED_SECRET_NAMES) {
    const value = (env[name] ?? "").trim();
    if (!value) missing.push(name);
  }

  const clientId = (env["ABDM_CLIENT_ID"] ?? "").trim();
  const clientSecret = (env["ABDM_CLIENT_SECRET"] ?? "").trim();

  const config: GatewayConfig = {
    baseUrl: (env["ABDM_BASE_URL"] ?? "https://dev.abdm.gov.in").trim(),
    clientId,
    clientSecret,
    bridgeId: (env["ABDM_BRIDGE_ID"] ?? "").trim(),
    hipId: (env["ABDM_HIP_ID"] ?? "").trim(),
    hiuId: (env["ABDM_HIU_ID"] ?? "").trim(),
    callbackBaseUrl: (env["ABDM_CALLBACK_BASE_URL"] ?? "").trim(),
    sessionPath: (env["ABDM_SESSION_PATH"] ?? "/gateway/v1/sessions").trim(),
    bridgePath: (env["ABDM_BRIDGE_PATH"] ?? "/gateway/v1/bridges").trim(),
    servicesPath:
      (env["ABDM_SERVICES_PATH"] ?? "/gateway/v1/bridges/addUpdateServices").trim(),
    getServicesPath:
      (env["ABDM_GET_SERVICES_PATH"] ?? "/gateway/v1/bridges/getServices").trim(),
    allowedServiceTypes: csv(env["ABDM_SERVICE_TYPES"] ?? "HIP,HIU"),
    tokenSafetyMarginSeconds: 120,
  };

  return { ok: missing.length === 0, config, missing };
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
        `${(numeric >>> 24) & 0xff}.${(numeric >>> 16) & 0xff}.${(numeric >>> 8) & 0xff}.${numeric & 0xff}`,
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
          `${(value >>> 24) & 0xff}.${(value >>> 16) & 0xff}.${(value >>> 8) & 0xff}.${value & 0xff}`,
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

export interface GatewayHttpResponse {
  ok: boolean;
  status: number;
  data: unknown;
}

export class GatewayError extends Error {
  readonly status: number;
  readonly body: unknown;

  constructor(status: number, message: string, body?: unknown) {
    super(message);
    this.status = status;
    this.body = body;
  }
}

export class HttpError extends Error {
  readonly status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

/**
 * Headers for every authenticated ABDM gateway request. Per the current
 * WorkingWithABDMapi authentication documentation, gateway requests carry
 * `Authorization: Bearer <access-token>` and `Content-Type: application/json`.
 * (The session-creation call itself sends ONLY Content-Type — it authenticates
 * with the clientId/clientSecret body.)
 */
export function buildGatewayHeaders(token: string): Record<string, string> {
  return {
    "Content-Type": "application/json",
    Authorization: `Bearer ${token}`,
  };
}

export async function safeFetchJson(
  fetchImpl: FetchImpl,
  url: string,
  init: RequestInit,
): Promise<GatewayHttpResponse> {
  let response: Response;
  try {
    response = await fetchImpl(url, init);
  } catch (error) {
    throw new GatewayError(0, `ABDM gateway unreachable: ${(error as Error)?.message ?? String(error)}`);
  }

  let data: unknown = null;
  try {
    data = await response.json();
  } catch (_) {
    data = null;
  }

  return { ok: response.ok, status: response.status, data };
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
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
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
 * Returns a cached ABDM access token when it is still valid (minus the safety
 * margin), otherwise POSTs to the configured ABDM session endpoint and caches
 * the new token. The token never leaves this module in raw form except through
 * the return value, which callers use only for outgoing gateway requests.
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
    );
  }

  const body = asRecord(response.data);
  const accessToken =
    (body["accessToken"] as string | undefined) ??
    (body["token"] as string | undefined) ??
    "";
  if (!accessToken) {
    throw new GatewayError(response.status, "ABDM session response did not contain an access token");
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
 * Performs an authenticated ABDM gateway request. On a 401 the cached token is
 * invalidated and exactly one retry with a fresh session is attempted.
 * Returns the parsed JSON response (already sanitized for any token-like
 * fields that the gateway might echo back).
 */
export async function gatewayRequest(
  fetchImpl: FetchImpl,
  config: GatewayConfig,
  cache: TokenCacheRef,
  method: "GET" | "POST" | "PATCH" | "PUT",
  path: string,
  body?: unknown,
): Promise<GatewayHttpResponse> {
  async function send(token: string): Promise<GatewayHttpResponse> {
    return safeFetchJson(fetchImpl, `${config.baseUrl}${path}`, {
      method,
      headers: buildGatewayHeaders(token),
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  }

  let response = await send(await getAccessToken(fetchImpl, config, cache));
  if (response.status === 401) {
    cache.current = null;
    response = await send(await getAccessToken(fetchImpl, config, cache));
  }

  return {
    ok: response.ok,
    status: response.status,
    data: sanitizePayload(response.data),
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
    return value.length > 10_000 ? `${value.slice(0, 10_000)}...[truncated]` : value;
  }
  if (typeof value === "number" || typeof value === "boolean") return value;
  if (typeof value === "bigint") return value.toString();
  if (Array.isArray(value)) {
    return value.map((entry) => sanitizePayload(entry, depth + 1));
  }
  if (typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [key, entry] of Object.entries(value as Record<string, unknown>)) {
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

export type InternalAction = "session" | "bridge" | "services" | "health";

const RESERVED_SUBPATHS = new Set([
  "/session",
  "/bridge",
  "/services",
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
  if (path === "/bridge" && m === "PATCH") return "bridge";
  if (path === "/services" && (m === "POST" || m === "GET")) return "services";
  if (path === "/health" && m === "GET") return "health";

  if (!path) {
    const action = (bodyAction ?? queryAction ?? "").toLowerCase();
    if (action === "session" && m === "POST") return "session";
    if (action === "bridge" && m === "PATCH") return "bridge";
    if (action === "services" && (m === "POST" || m === "GET")) return "services";
    if (action === "health" && m === "GET") return "health";
  }

  return null;
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
      `${prefix}.type must be one of the official service types: ${[...allowedTypes].join(", ")}`,
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
export function readHeader(headers: Headers, ...names: string[]): string | undefined {
  for (const name of names) {
    const value = headers.get(name);
    if (value && value.trim()) return value.trim();
  }
  return undefined;
}

export interface CallbackStore {
  insert(row: CallbackRow): Promise<{ error: { code?: string; message: string } | null }>;
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
