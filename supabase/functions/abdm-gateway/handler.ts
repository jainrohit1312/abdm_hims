// ============================================================================
// ABDM Gateway Edge Function — request handler (testable, no Supabase SDK)
// ----------------------------------------------------------------------------
// This module contains the full HTTP request handling logic and depends only
// on `core.ts` + the injected dependencies in `RequestDeps`, so `deno test`
// can exercise routing, auth and ABDM contract behaviour without loading the
// Supabase JS SDK.
// ============================================================================

import {
  FUNCTION_NAME,
  MAX_BODY_BYTES,
  SlidingWindowRateLimiter,
  acquireAccessToken,
  buildCallbackRow,
  gatewayRequest,
  getSubpath,
  isAdminRole,
  isReservedSubpath,
  maskClientId,
  persistCallback,
  readConfig,
  readHeader,
  readJsonBody,
  resolveBridgePath,
  resolveInternalAction,
  sanitizePayload,
  validateCallbackBaseUrl,
  validateServicesPayload,
  type CallbackRow,
  type FetchImpl,
  type GatewayConfig,
  type InternalAction,
  type TokenCacheRef,
  type TokenRecord,
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
}

// Default worker-scoped ABDM token cache (memory only, never returned).
const defaultTokenCache: TokenCacheRef = { current: null };

// Default best-effort per-worker limiter: 120 public callbacks/minute/IP.
const defaultCallbackRateLimiter = new SlidingWindowRateLimiter(60_000, 120);

// ----------------------------------------------------------------------------
// Request handler
// ----------------------------------------------------------------------------

export async function handleRequest(
  req: Request,
  deps: RequestDeps,
): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
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
    req.method,
    subpath,
    typeof body["action"] === "string" ? (body["action"] as string) : undefined,
    queryAction,
  );

  try {
    if (action) {
      return await handleInternalAction(req, action, body, deps);
    }

    if (req.method === "POST") {
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
      { error: "Not found. Use /session, /bridge, /services, /health or POST a callback subpath." },
      404,
    );
  } catch (error) {
    // SECURITY: never log request bodies / headers — only the safe message.
    const message = error instanceof Error ? error.message : String(error);
    const status = error instanceof HttpError ? error.status : 500;
    console.error(`abdm-gateway error (status ${status}): ${message}`);
    return jsonResponse({ error: message }, status);
  }
}

// ----------------------------------------------------------------------------
// Internal (protected) actions
// ----------------------------------------------------------------------------

async function handleInternalAction(
  req: Request,
  action: InternalAction,
  body: Record<string, unknown>,
  deps: RequestDeps,
): Promise<Response> {
  const config = requireConfig(deps.env);

  // Every internal action requires a valid HIMS user session (manual JWT
  // validation because this function is deployed with verify_jwt = false).
  const user = await deps.authenticate(req, deps.env);

  // Session / Bridge / Services are owner-only (hospital admin / super_admin).
  if (action !== "health") {
    requireAdmin(user.role);
  }

  switch (action) {
    case "session":
      return handleSession(config, deps);
    case "bridge":
      return handleBridge(config, body, deps);
    case "services":
      return req.method === "GET"
        ? handleGetServices(config, deps)
        : handlePostServices(config, body, deps);
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
    throw new HttpError(
      500,
      `Missing Edge Function secrets: ${result.missing.join(", ")}`,
    );
  }
  return result.config;
}

function requireAdmin(role: string): void {
  if (!isAdminRole(role)) {
    throw new HttpError(403, "Owner / super-admin role required for this action");
  }
}

async function handleSession(
  config: GatewayConfig,
  deps: RequestDeps,
): Promise<Response> {
  const tokenCache = deps.tokenCache ?? defaultTokenCache;
  let record: TokenRecord;
  try {
    record = await acquireAccessToken(deps.fetchImpl, config, tokenCache);
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
    baseUrl: config.baseUrl,
    clientId: maskClientId(config.clientId),
    sessionValidForSeconds: remainingSeconds,
    note: "ABDM session established server-side. The raw token is never returned.",
  });
}

function sessionGatewayError(error: GatewayError): HttpError {
  if (error.status === 401 || error.status === 403) {
    return new HttpError(
      502,
      "ABDM authentication rejected: verify Client ID/rotated Client Secret",
    );
  }
  if (error.status === 404 || error.status === 405) {
    return new HttpError(502, "ABDM session endpoint may need v0.5 override");
  }
  if (error.status === 0) {
    return new HttpError(
      502,
      "ABDM gateway unavailable. Check network connectivity and try again.",
    );
  }
  return new HttpError(
    502,
    `ABDM session request failed with status ${error.status}`,
  );
}

async function handleBridge(
  config: GatewayConfig,
  body: Record<string, unknown>,
  deps: RequestDeps,
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
    throw new HttpError(400, validation.error ?? "Invalid ABDM_CALLBACK_BASE_URL");
  }

  const gatewayBody: Record<string, unknown> = {
    url: config.callbackBaseUrl.trim(),
  };

  const response = await gatewayRequest(
    deps.fetchImpl,
    config,
    deps.tokenCache ?? defaultTokenCache,
    "PATCH",
    resolveBridgePath(config),
    gatewayBody,
  );

  if (!response.ok) {
    throw new HttpError(
      response.status || 502,
      `ABDM bridge update failed (${response.status})`,
    );
  }

  return jsonResponse({
    status: "bridge_configured",
    baseUrl: config.baseUrl,
    callbackUrl: config.callbackBaseUrl.trim(),
    gateway: sanitizePayload(response.data),
  });
}

async function handleGetServices(
  config: GatewayConfig,
  deps: RequestDeps,
): Promise<Response> {
  const response = await gatewayRequest(
    deps.fetchImpl,
    config,
    deps.tokenCache ?? defaultTokenCache,
    "GET",
    config.getServicesPath,
  );

  if (!response.ok) {
    throw new HttpError(
      response.status || 502,
      `ABDM getServices failed (${response.status})`,
    );
  }

  return jsonResponse({
    status: "services_fetched",
    gateway: sanitizePayload(response.data),
  });
}

async function handlePostServices(
  config: GatewayConfig,
  body: Record<string, unknown>,
  deps: RequestDeps,
): Promise<Response> {
  const validation = validateServicesPayload(body, config.allowedServiceTypes);
  if (!validation.ok || !validation.services) {
    throw new HttpError(400, validation.errors.join("; "));
  }

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

  const clientIp =
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
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
  ) ?? (body["requestId"] as string | undefined) ?? (body["request_id"] as string | undefined);

  const transactionId =
    (body["transactionId"] as string | undefined) ??
    (body["transaction_id"] as string | undefined) ??
    readHeader(req.headers, "transaction-id", "x-transaction-id");

  const callbackType =
    (body["callbackType"] as string | undefined) ??
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
