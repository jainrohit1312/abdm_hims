// ============================================================================
// Deno unit tests for the abdm-gateway core logic.
//
// Run locally with:
//   cd supabase/functions/abdm-gateway && deno test --allow-read --allow-net .
//
// These tests use mocked ABDM HTTP responses and never call the live ABDM
// Sandbox automatically.
// ============================================================================

import {
  MAX_BODY_BYTES,
  SlidingWindowRateLimiter,
  acquireAccessToken,
  buildBridgeGatewayDiagnostic,
  buildBridgeHttpDiagnostic,
  buildCallbackRow,
  buildGatewayHeaders,
  buildGetServicesGatewayDiagnostic,
  buildGetServicesHttpDiagnostic,
  defaultCmIdForBaseUrl,
  extractSanitizedServices,
  extractSanitizedUpstreamError,
  gatewayRequest,
  getSubpath,
  isAdminRole,
  isLocalOrPrivateHost,
  isReservedSubpath,
  isValidCmId,
  parsePositiveInt,
  persistCallback,
  readConfig,
  readJsonBody,
  redactSensitiveText,
  resolveBridgePath,
  resolvedCmId,
  resolveInternalAction,
  sanitizePayload,
  validateCallbackBaseUrl,
  validateServicesPayload,
  GatewayError,
  type CallbackRow,
  type GatewayConfig,
  type GatewayHttpResponse,
  type TokenCacheRef,
} from "./core.ts";

function assertEquals<T>(actual: T, expected: T, message = ""): void {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  if (a !== b) {
    throw new Error(
      `${message ? message + " — " : ""}expected ${b}, got ${a}`,
    );
  }
}

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function makeConfig(overrides: Partial<GatewayConfig> = {}): GatewayConfig {
  return {
    baseUrl: "https://dev.abdm.gov.in",
    clientId: "test-client-id",
    clientSecret: "test-client-secret",
    bridgeId: "test-bridge-id",
    hipId: "test-hip-id",
    hiuId: "test-hiu-id",
    callbackBaseUrl: "https://example.supabase.co/functions/v1/abdm-gateway",
    sessionPath: "/gateway/v1/sessions",
    bridgePath: "/gateway/v1/bridges",
    servicesPath: "/gateway/v1/bridges/addUpdateServices",
    getServicesPath: "/gateway/v1/bridges/getServices",
    allowedServiceTypes: ["HIP", "HIU"],
    cmId: "sbx",
    tokenSafetyMarginSeconds: 120,
    ...overrides,
  };
}

function mockFetch(
  handler: (url: string, init: RequestInit) => Response,
): typeof fetch {
  const fn = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = typeof input === "string"
      ? input
      : input instanceof URL
      ? input.toString()
      : input.url;
    return handler(url, init ?? {});
  }) as typeof fetch;
  return fn;
}

function jsonRequest(body: unknown, headers: Record<string, string> = {}): Request {
  return new Request("https://example.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
}

// ----------------------------------------------------------------------------
// 1. Configuration defaults (onboarding-email contract)
// ----------------------------------------------------------------------------

Deno.test("readConfig reports missing ABDM_CLIENT_ID and ABDM_CLIENT_SECRET", () => {
  const result = readConfig({});
  assertEquals(result.ok, false);
  assertEquals(result.missing, ["ABDM_CLIENT_ID", "ABDM_CLIENT_SECRET"]);
});

Deno.test("readConfig uses the reviewed ABDM dev defaults", () => {
  const result = readConfig({
    ABDM_CLIENT_ID: "id",
    ABDM_CLIENT_SECRET: "secret",
  });
  assertEquals(result.ok, true);
  assertEquals(result.config?.baseUrl, "https://dev.abdm.gov.in");
  assertEquals(result.config?.sessionPath, "/gateway/v1/sessions");
  assertEquals(result.config?.bridgePath, "/gateway/v1/bridges");
  assertEquals(
    result.config?.servicesPath,
    "/gateway/v1/bridges/addUpdateServices",
  );
  assertEquals(
    result.config?.getServicesPath,
    "/gateway/v1/bridges/getServices",
  );
  assertEquals(result.config?.allowedServiceTypes, ["HIP", "HIU"]);
});

Deno.test("readConfig honors the production-confirmed ABDM_SESSION_PATH override", () => {
  const result = readConfig({
    ABDM_CLIENT_ID: "id",
    ABDM_CLIENT_SECRET: "secret",
    ABDM_SESSION_PATH: "/gateway/v0.5/sessions",
  });
  assertEquals(result.ok, true);
  assertEquals(result.config?.sessionPath, "/gateway/v0.5/sessions");
});

Deno.test("resolveBridgePath does not append a bridge id", () => {
  assertEquals(resolveBridgePath(makeConfig()), "/gateway/v1/bridges");
});

// ----------------------------------------------------------------------------
// 1a. ABDM_CM_ID configuration + X-CM-ID header builder
// ----------------------------------------------------------------------------

Deno.test("readConfig defaults ABDM_CM_ID to sbx only for dev.abdm.gov.in", () => {
  const dev = readConfig({
    ABDM_CLIENT_ID: "id",
    ABDM_CLIENT_SECRET: "secret",
  });
  assertEquals(dev.ok, true);
  assertEquals(dev.config?.cmId, "sbx");

  const sandbox = readConfig({
    ABDM_CLIENT_ID: "id",
    ABDM_CLIENT_SECRET: "secret",
    ABDM_BASE_URL: "https://sandbox.abdm.gov.in",
  });
  assertEquals(sandbox.ok, true);
  assertEquals(sandbox.config?.cmId, "", "non-dev base URL must default to disabled");

  const abha = readConfig({
    ABDM_CLIENT_ID: "id",
    ABDM_CLIENT_SECRET: "secret",
    ABDM_BASE_URL: "https://abha.abdm.gov.in",
  });
  assertEquals(abha.config?.cmId, "");
});

Deno.test("readConfig allows explicit ABDM_CM_ID override and disable", () => {
  const override = readConfig({
    ABDM_CLIENT_ID: "id",
    ABDM_CLIENT_SECRET: "secret",
    ABDM_BASE_URL: "https://sandbox.abdm.gov.in",
    ABDM_CM_ID: "prod-cm-01",
  });
  assertEquals(override.ok, true);
  assertEquals(override.config?.cmId, "prod-cm-01");

  const disabled = readConfig({
    ABDM_CLIENT_ID: "id",
    ABDM_CLIENT_SECRET: "secret",
    ABDM_CM_ID: "   ",
  });
  assertEquals(disabled.ok, true);
  assertEquals(disabled.config?.cmId, "");
});

Deno.test("readConfig rejects an invalid ABDM_CM_ID value", () => {
  const result = readConfig({
    ABDM_CLIENT_ID: "id",
    ABDM_CLIENT_SECRET: "secret",
    ABDM_CM_ID: "sbx<script>alert(1)</script>",
  });
  assertEquals(result.ok, false);
  assert(result.errors.some((e) => e.includes("ABDM_CM_ID")), "invalid cm id must be reported");
  assertEquals(result.config?.cmId, "");
});

Deno.test("isValidCmId accepts short safe identifiers only", () => {
  assertEquals(isValidCmId("sbx"), true);
  assertEquals(isValidCmId("prod-cm_01:eu"), true);
  assertEquals(isValidCmId("a".repeat(32)), true);
  assertEquals(isValidCmId(""), false);
  assertEquals(isValidCmId("a".repeat(33)), false);
  assertEquals(isValidCmId("sbx\nx"), false);
  assertEquals(isValidCmId("sbx<script>"), false);
  assertEquals(isValidCmId("with space"), false);
});

Deno.test("defaultCmIdForBaseUrl only defaults sbx for the dev gateway", () => {
  assertEquals(defaultCmIdForBaseUrl("https://dev.abdm.gov.in"), "sbx");
  assertEquals(defaultCmIdForBaseUrl("https://dev.abdm.gov.in/gateway"), "sbx");
  assertEquals(defaultCmIdForBaseUrl("https://sandbox.abdm.gov.in"), "");
  assertEquals(defaultCmIdForBaseUrl("https://abha.abdm.gov.in"), "");
});

Deno.test("buildGatewayHeaders adds X-CM-ID only when a validated value is supplied", () => {
  assertEquals(buildGatewayHeaders("tok-123"), {
    "Content-Type": "application/json",
    Authorization: "Bearer tok-123",
  });
  assertEquals(buildGatewayHeaders("tok-123", "sbx"), {
    "Content-Type": "application/json",
    Authorization: "Bearer tok-123",
    "X-CM-ID": "sbx",
  });
  assertEquals(buildGatewayHeaders("tok-123", ""), {
    "Content-Type": "application/json",
    Authorization: "Bearer tok-123",
  });
  assertEquals(buildGatewayHeaders("tok-123", "bad value"), {
    "Content-Type": "application/json",
    Authorization: "Bearer tok-123",
  });
  assertEquals(resolvedCmId(makeConfig({ cmId: "sbx" })), "sbx");
  assertEquals(resolvedCmId(makeConfig({ cmId: "" })), "");
});

// ----------------------------------------------------------------------------
// 1b. Server-side callback URL validation
// ----------------------------------------------------------------------------

Deno.test("validateCallbackBaseUrl accepts a public HTTPS Supabase function URL", () => {
  assertEquals(
    validateCallbackBaseUrl("https://example.supabase.co/functions/v1/abdm-gateway").ok,
    true,
  );
});

Deno.test("validateCallbackBaseUrl rejects empty, non-absolute and non-HTTPS URLs", () => {
  assertEquals(validateCallbackBaseUrl("").ok, false);
  assertEquals(validateCallbackBaseUrl("   ").ok, false);
  assertEquals(validateCallbackBaseUrl("abdm-gateway").ok, false);
  assertEquals(validateCallbackBaseUrl("http://cb.example/abdm").ok, false);
  assertEquals(validateCallbackBaseUrl("ftp://cb.example/abdm").ok, false);
});

Deno.test("validateCallbackBaseUrl rejects localhost and local names", () => {
  assertEquals(validateCallbackBaseUrl("https://localhost/abdm").ok, false);
  assertEquals(validateCallbackBaseUrl("https://api.localhost/abdm").ok, false);
  assertEquals(validateCallbackBaseUrl("https://machine.local/abdm").ok, false);
});

Deno.test("validateCallbackBaseUrl rejects private and local IPv4 addresses", () => {
  assertEquals(validateCallbackBaseUrl("https://10.0.0.5/abdm").ok, false);
  assertEquals(validateCallbackBaseUrl("https://127.0.0.1/abdm").ok, false);
  assertEquals(validateCallbackBaseUrl("https://192.168.1.10/abdm").ok, false);
  assertEquals(validateCallbackBaseUrl("https://172.16.0.2/abdm").ok, false);
  assertEquals(validateCallbackBaseUrl("https://169.254.169.254/abdm").ok, false);
  assertEquals(validateCallbackBaseUrl("https://0.0.0.0/abdm").ok, false);
  assertEquals(validateCallbackBaseUrl("https://2130706433/abdm").ok, false);
});

Deno.test("validateCallbackBaseUrl rejects IPv6 loopback and link-local addresses", () => {
  assertEquals(validateCallbackBaseUrl("https://[::1]/abdm").ok, false);
  assertEquals(validateCallbackBaseUrl("https://[fe80::1]/abdm").ok, false);
  assertEquals(validateCallbackBaseUrl("https://[::ffff:10.0.0.1]/abdm").ok, false);
});

Deno.test("validateCallbackBaseUrl rejects query strings and fragments", () => {
  assertEquals(validateCallbackBaseUrl("https://cb.example/abdm?x=1").ok, false);
  assertEquals(validateCallbackBaseUrl("https://cb.example/abdm#frag").ok, false);
});

Deno.test("isLocalOrPrivateHost classifies private/local hosts only", () => {
  assertEquals(isLocalOrPrivateHost("localhost"), true);
  assertEquals(isLocalOrPrivateHost("10.0.0.5"), true);
  assertEquals(isLocalOrPrivateHost("192.168.1.1"), true);
  assertEquals(isLocalOrPrivateHost("127.0.0.1"), true);
  assertEquals(isLocalOrPrivateHost("example.supabase.co"), false);
  assertEquals(isLocalOrPrivateHost("dev.abdm.gov.in"), false);
});

// ----------------------------------------------------------------------------
// 1c. Bridge diagnostic builders + text redaction
// ----------------------------------------------------------------------------

Deno.test("redactSensitiveText masks JWT and Bearer token values", () => {
  assertEquals(
    redactSensitiveText("failed eyJhbGciOiJIUzI1NiJ9.abc.def and Bearer abcdefghijklmnop"),
    "failed [REDACTED] and Bearer [REDACTED]",
  );
  assertEquals(redactSensitiveText("no secrets here"), "no secrets here");
});

Deno.test("extractSanitizedUpstreamError picks code/message and redacts values", () => {
  const result = extractSanitizedUpstreamError({
    error: {
      code: "INVALID",
      message: "bad request with token eyJhbGciOiJIUzI1NiJ9.abc.def",
    },
    accessToken: "should-not-leak",
  });
  assertEquals(result.code, "INVALID");
  assert(
    result.message?.includes("[REDACTED]") === true,
    "token value inside the message must be redacted",
  );
  assert(result.message?.includes("should-not-leak") === false, "token must not leak");
});

Deno.test("buildBridgeHttpDiagnostic maps upstream statuses to ABDM_BRIDGE codes", () => {
  const response: GatewayHttpResponse = {
    ok: false,
    status: 401,
    data: { error: { code: "UNAUTHORIZED", message: "bad credentials" } },
    contentType: "application/json",
  };
  const diag = buildBridgeHttpDiagnostic(response, makeConfig());
  assertEquals(diag.operation, "bridge_update");
  assertEquals(diag.code, "ABDM_BRIDGE_401");
  assertEquals(diag.upstreamStatus, 401);
  assertEquals(diag.category, "http");
  assertEquals(diag.errorCode, "UNAUTHORIZED");
  assertEquals(diag.errorMessage, "bad credentials");
  assert(diag.message.includes("401"), "client message must mention status");
});

Deno.test("buildBridgeGatewayDiagnostic distinguishes network vs timeout", () => {
  const network = buildBridgeGatewayDiagnostic(
    new GatewayError(0, "ABDM gateway unreachable", undefined, "network", {
      method: "PATCH",
      hostname: "dev.abdm.gov.in",
      pathname: "/gateway/v1/bridges",
    }),
    makeConfig(),
  );
  assertEquals(network.code, "ABDM_BRIDGE_NETWORK");
  assertEquals(network.upstreamStatus, null);
  assertEquals(network.category, "network");

  const timeout = buildBridgeGatewayDiagnostic(
    new GatewayError(0, "ABDM gateway timed out", undefined, "timeout", {
      method: "PATCH",
      hostname: "dev.abdm.gov.in",
      pathname: "/gateway/v1/bridges",
    }),
    makeConfig(),
  );
  assertEquals(timeout.code, "ABDM_BRIDGE_TIMEOUT");
  assertEquals(timeout.category, "timeout");
  assertEquals(timeout.upstreamStatus, null);
});

Deno.test("buildBridgeGatewayDiagnostic never maps an HTTP session failure to network", () => {
  const session404 = buildBridgeGatewayDiagnostic(
    new GatewayError(404, "ABDM session request failed with status 404", undefined, "http", {
      method: "POST",
      hostname: "dev.abdm.gov.in",
      pathname: "/gateway/v1/sessions",
    }),
    makeConfig(),
  );
  assertEquals(session404.code, "ABDM_BRIDGE_404");
  assertEquals(session404.upstreamStatus, 404);
  assertEquals(session404.category, "http");
  assertEquals(session404.method, "POST");
  assertEquals(session404.pathname, "/gateway/v1/sessions");
});

// ----------------------------------------------------------------------------
// 1d. getServices diagnostics + sanitized service list
// ----------------------------------------------------------------------------

Deno.test("extractSanitizedServices keeps only allowed fields and drops secrets", () => {
  const services = extractSanitizedServices([
    {
      id: "hip-1",
      name: "Demo HIP",
      type: "HIP",
      active: true,
      alias: ["Demo"],
      endpoints: [
        { address: "https://cb.example/notify", connectionType: "https", use: "X" },
      ],
      accessToken: "should-be-dropped",
      clientSecret: "should-be-dropped",
    },
    "not-an-object",
  ]);

  assertEquals(services.length, 1);
  const first = services[0] as Record<string, unknown>;
  assertEquals(first["id"], "hip-1");
  assertEquals(first["name"], "Demo HIP");
  assertEquals(first["type"], "HIP");
  assertEquals(first["active"], true);
  assertEquals(first["alias"], ["Demo"]);
  assertEquals(
    ((first["endpoints"] as Record<string, unknown>[])[0])["address"],
    "https://cb.example/notify",
  );
  assert(first["accessToken"] === undefined, "sensitive keys must be dropped");
  assert(first["clientSecret"] === undefined, "sensitive keys must be dropped");
});

Deno.test("buildGetServicesHttpDiagnostic maps a 403 to ABDM_GET_SERVICES_403", () => {
  const response: GatewayHttpResponse = {
    ok: false,
    status: 403,
    data: { error: { code: "FORBIDDEN", message: "Resource forbidden" } },
    contentType: "application/json",
  };
  const diag = buildGetServicesHttpDiagnostic(response, makeConfig());
  assertEquals(diag.operation, "get_services");
  assertEquals(diag.code, "ABDM_GET_SERVICES_403");
  assertEquals(diag.upstreamStatus, 403);
  assertEquals(diag.method, "GET");
  assertEquals(diag.pathname, "/gateway/v1/bridges/getServices");
  assertEquals(diag.errorCode, "FORBIDDEN");
  assertEquals(diag.errorMessage, "Resource forbidden");
});

Deno.test("buildGetServicesGatewayDiagnostic distinguishes network vs timeout", () => {
  const network = buildGetServicesGatewayDiagnostic(
    new GatewayError(0, "ABDM gateway unreachable", undefined, "network", {
      method: "GET",
      hostname: "dev.abdm.gov.in",
      pathname: "/gateway/v1/bridges/getServices",
    }),
    makeConfig(),
  );
  assertEquals(network.code, "ABDM_GET_SERVICES_NETWORK");
  assertEquals(network.category, "network");
  assertEquals(network.upstreamStatus, null);

  const timeout = buildGetServicesGatewayDiagnostic(
    new GatewayError(0, "ABDM gateway timed out", undefined, "timeout", {
      method: "GET",
      hostname: "dev.abdm.gov.in",
      pathname: "/gateway/v1/bridges/getServices",
    }),
    makeConfig(),
  );
  assertEquals(timeout.code, "ABDM_GET_SERVICES_TIMEOUT");
  assertEquals(timeout.category, "timeout");
  assertEquals(timeout.upstreamStatus, null);
});

// ----------------------------------------------------------------------------
// 2. Session generation + caching + API failure
// ----------------------------------------------------------------------------

Deno.test("acquireAccessToken creates a session from a mocked ABDM response", async () => {
  const fetchImpl = mockFetch(() =>
    new Response(
      JSON.stringify({ accessToken: "abdm-token-123", expiresIn: 3600 }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    ));

  const cache: TokenCacheRef = { current: null };
  const record = await acquireAccessToken(fetchImpl, makeConfig(), cache);

  assertEquals(record.accessToken, "abdm-token-123");
  assert(record.expiresAt > Date.now() + 3000 * 1000, "expiry should be ~1h out");
});

Deno.test("acquireAccessToken caches the token and reuses it within the safety margin", async () => {
  let sessionCalls = 0;
  const fetchImpl = mockFetch(() => {
    sessionCalls += 1;
    return new Response(
      JSON.stringify({ accessToken: `token-${sessionCalls}`, expiresIn: 3600 }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  });

  const cache: TokenCacheRef = { current: null };
  const first = await acquireAccessToken(fetchImpl, makeConfig(), cache);
  const second = await acquireAccessToken(fetchImpl, makeConfig(), cache);

  assertEquals(first.accessToken, second.accessToken);
  assertEquals(sessionCalls, 1, "second call must be served from cache");
});

Deno.test("acquireAccessToken refetches after the safety margin expires", async () => {
  let sessionCalls = 0;
  const fetchImpl = mockFetch(() => {
    sessionCalls += 1;
    return new Response(
      JSON.stringify({ accessToken: `token-${sessionCalls}`, expiresIn: 1 }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  });

  const cache: TokenCacheRef = { current: null };
  await acquireAccessToken(fetchImpl, makeConfig(), cache);
  await acquireAccessToken(fetchImpl, makeConfig(), cache);
  assertEquals(sessionCalls, 2, "expired-with-margin token must be refetched");
});

Deno.test("acquireAccessToken throws GatewayError on session API failure", async () => {
  const fetchImpl = mockFetch(() =>
    new Response(JSON.stringify({ error: "invalid_client" }), { status: 401 }));

  const cache: TokenCacheRef = { current: null };
  let threw = false;
  try {
    await acquireAccessToken(fetchImpl, makeConfig(), cache);
  } catch (error) {
    threw = true;
    assert((error as Error).message.includes("401"), "error should mention status");
  }
  assert(threw, "session failure must throw");
});

Deno.test("acquireAccessToken never returns a token when the response has none", async () => {
  const fetchImpl = mockFetch(() =>
    new Response(JSON.stringify({ status: "ok" }), { status: 200 }));

  const cache: TokenCacheRef = { current: null };
  let threw = false;
  try {
    await acquireAccessToken(fetchImpl, makeConfig(), cache);
  } catch (error) {
    threw = true;
    assert(
      (error as Error).message.includes("did not contain an access token"),
      "missing-token response must throw",
    );
  }
  assert(threw, "missing-token response must throw");
});

Deno.test("buildGatewayHeaders adds Authorization Bearer + Content-Type", () => {
  assertEquals(buildGatewayHeaders("tok-123"), {
    "Content-Type": "application/json",
    Authorization: "Bearer tok-123",
  });
});

// ----------------------------------------------------------------------------
// 2a. gatewayRequest single fresh-token retry on 401/403
// ----------------------------------------------------------------------------

function gatewayRequestHarness(
  operation: (url: string, init: RequestInit) => Response,
  cache: TokenCacheRef,
  config = makeConfig(),
) {
  const sessionCalls: string[] = [];
  const operationCalls: { url: string; init: RequestInit }[] = [];
  const fetchImpl = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = typeof input === "string"
      ? input
      : input instanceof URL
      ? input.toString()
      : input.url;
    if (url.endsWith(config.sessionPath)) {
      sessionCalls.push(url);
      return new Response(
        JSON.stringify({ accessToken: `fresh-token-${sessionCalls.length}`, expiresIn: 3600 }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    }
    operationCalls.push({ url, init: init ?? {} });
    return operation(url, init ?? {});
  }) as typeof fetch;

  return { fetchImpl, sessionCalls, operationCalls };
}

Deno.test("gatewayRequest first 403 invalidates cache, fetches a fresh session and retries once", async () => {
  const cache: TokenCacheRef = {
    current: {
      accessToken: "stale-cached-token",
      expiresAt: Date.now() + 3600_000,
    },
  };
  let operationCalls = 0;
  const { fetchImpl, sessionCalls } = gatewayRequestHarness(() => {
    operationCalls += 1;
    return new Response(JSON.stringify({ error: { code: "FORBIDDEN" } }), {
      status: 403,
      headers: { "Content-Type": "application/json" },
    });
  }, cache);

  const result = await gatewayRequest(fetchImpl, makeConfig(), cache, "PATCH", "/gateway/v1/bridges", { url: "https://cb.example/abdm" });

  assertEquals(result.status, 403);
  assertEquals(result.initialStatus, 403);
  assertEquals(result.freshTokenRetryPerformed, true);
  assertEquals(result.retryStatus, 403);
  assertEquals(result.cmContextApplied, true);
  assertEquals(operationCalls, 2, "the operation must be attempted exactly twice");
  assertEquals(sessionCalls.length, 1, "only one fresh session may be requested");
  assert(result.data !== null && !JSON.stringify(result.data).includes("stale-cached-token"), "cached token must not be returned");
});

Deno.test("gatewayRequest retry succeeds on the second attempt", async () => {
  const cache: TokenCacheRef = {
    current: {
      accessToken: "stale-cached-token",
      expiresAt: Date.now() + 3600_000,
    },
  };
  let operationCalls = 0;
  const { fetchImpl } = gatewayRequestHarness(() => {
    operationCalls += 1;
    return operationCalls === 1
      ? new Response(JSON.stringify({ error: "forbidden" }), { status: 403 })
      : new Response(JSON.stringify({ ok: true }), { status: 200 });
  }, cache);

  const result = await gatewayRequest(fetchImpl, makeConfig(), cache, "GET", "/gateway/v1/bridges/getServices");

  assertEquals(result.ok, true);
  assertEquals(result.status, 200);
  assertEquals(result.freshTokenRetryPerformed, true);
  assertEquals(result.retryStatus, 200);
  assertEquals(operationCalls, 2);
});

Deno.test("gatewayRequest never retries 400/404/405/429/500", async () => {
  for (const status of [400, 404, 405, 429, 500]) {
    const cache: TokenCacheRef = {
      current: {
        accessToken: "cached-token",
        expiresAt: Date.now() + 3600_000,
      },
    };
    let operationCalls = 0;
    const { fetchImpl, sessionCalls } = gatewayRequestHarness(() => {
      operationCalls += 1;
      return new Response(JSON.stringify({ error: `status ${status}` }), { status });
    }, cache);

    const result = await gatewayRequest(fetchImpl, makeConfig(), cache, "PATCH", "/gateway/v1/bridges", { url: "https://cb.example/abdm" });

    assertEquals(result.status, status);
    assertEquals(result.freshTokenRetryPerformed, false, `${status} must not be retried`);
    assertEquals(result.retryStatus, null, `${status} must not produce a retry status`);
    assertEquals(operationCalls, 1, `${status} must be attempted once only`);
    assertEquals(sessionCalls.length, 0, `${status} must not trigger a fresh session`);
  }
});

Deno.test("gatewayRequest never retries network or timeout failures", async () => {
  for (const error of [new TypeError("fetch failed"), new DOMException("The operation timed out.", "TimeoutError")]) {
    const cache: TokenCacheRef = {
      current: {
        accessToken: "cached-token",
        expiresAt: Date.now() + 3600_000,
      },
    };
    const { fetchImpl, sessionCalls } = gatewayRequestHarness(() => {
      throw error;
    }, cache);

    let threw: GatewayError | null = null;
    try {
      await gatewayRequest(fetchImpl, makeConfig(), cache, "GET", "/gateway/v1/bridges/getServices");
    } catch (e) {
      threw = e as GatewayError;
    }
    assert(threw !== null, "network/timeout must throw");
    assertEquals(threw!.freshTokenRetryPerformed, false, "network/timeout must not be retried");
    assertEquals(sessionCalls.length, 0, "network/timeout must not trigger a fresh session");
  }
});

Deno.test("gatewayRequest adds X-CM-ID to Bridge-management requests but never to session creation", async () => {
  let bridgeHeaders: Record<string, string> = {};
  let sessionHeaders: Record<string, string> = {};
  const config = makeConfig();
  const fetchImpl = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    if (url.endsWith(config.sessionPath)) {
      sessionHeaders = init?.headers as Record<string, string>;
      return new Response(JSON.stringify({ accessToken: "tok", expiresIn: 3600 }), { status: 200 });
    }
    bridgeHeaders = init?.headers as Record<string, string>;
    return new Response(JSON.stringify({ ok: true }), { status: 200 });
  }) as typeof fetch;

  const cache: TokenCacheRef = { current: null };
  await gatewayRequest(fetchImpl, config, cache, "PATCH", "/gateway/v1/bridges", { url: "https://cb.example/abdm" });

  assertEquals(sessionHeaders["X-CM-ID"] ?? null, null, "session creation must never receive X-CM-ID");
  assertEquals(sessionHeaders["Content-Type"], "application/json");
  assertEquals(bridgeHeaders["X-CM-ID"], "sbx");
  assertEquals(bridgeHeaders["Content-Type"], "application/json");
  assert(bridgeHeaders["Authorization"]?.startsWith("Bearer "), "Authorization must remain Bearer");
});

// ----------------------------------------------------------------------------
// 3. Routing / auth helper
// ----------------------------------------------------------------------------

Deno.test("resolveInternalAction routes path and body action variants", () => {
  assertEquals(resolveInternalAction("POST", "/session"), "session");
  assertEquals(resolveInternalAction("PATCH", "/bridge"), "bridge");
  assertEquals(resolveInternalAction("POST", "/services"), "services");
  assertEquals(resolveInternalAction("GET", "/services"), "services");
  assertEquals(resolveInternalAction("GET", "/health"), "health");
  assertEquals(resolveInternalAction("POST", "", "session"), "session");
  assertEquals(resolveInternalAction("PATCH", "", "bridge"), "bridge");
  assertEquals(resolveInternalAction("GET", "", undefined, "services"), "services");
});

Deno.test("public callback subpaths can never resolve to an administrative action", () => {
  assertEquals(resolveInternalAction("POST", "/gateway/v1/bridges", "session"), null);
  assertEquals(resolveInternalAction("PATCH", "/v0.5/patients/status/notify", "bridge"), null);
  assertEquals(resolveInternalAction("GET", "/v0.5/notify", undefined, "services"), null);
  assertEquals(resolveInternalAction("POST", "/v0.5/notify", "services"), null);
});

Deno.test("getSubpath preserves callback subpaths after the function name", () => {
  assertEquals(
    getSubpath("https://x.supabase.co/functions/v1/abdm-gateway/v0.5/hip/notify"),
    "/v0.5/hip/notify",
  );
  assertEquals(
    getSubpath("https://x.supabase.co/functions/v1/abdm-gateway"),
    "",
  );
});

Deno.test("isAdminRole accepts only admin and super_admin", () => {
  assertEquals(isAdminRole("admin"), true);
  assertEquals(isAdminRole("super_admin"), true);
  assertEquals(isAdminRole("ADMIN"), true);
  assertEquals(isAdminRole("owner"), false);
  assertEquals(isAdminRole("doctor"), false);
  assertEquals(isAdminRole("staff"), false);
  assertEquals(isAdminRole(""), false);
});

Deno.test("isReservedSubpath protects internal action paths", () => {
  assertEquals(isReservedSubpath("/session"), true);
  assertEquals(isReservedSubpath("/bridge"), true);
  assertEquals(isReservedSubpath("/services"), true);
  assertEquals(isReservedSubpath("/health"), true);
  assertEquals(isReservedSubpath("/v0.5/notify"), false);
});

Deno.test("parsePositiveInt falls back safely", () => {
  assertEquals(parsePositiveInt("3600", 42), 3600);
  assertEquals(parsePositiveInt("abc", 42), 42);
  assertEquals(parsePositiveInt(-5, 42), 42);
  assertEquals(parsePositiveInt(null, 42), 42);
});

// ----------------------------------------------------------------------------
// 4. Inbound body reading (size limit + strict JSON)
// ----------------------------------------------------------------------------

Deno.test("readJsonBody accepts a valid JSON object", async () => {
  const result = await readJsonBody(
    jsonRequest({ action: "session" }),
    MAX_BODY_BYTES,
  );
  assertEquals(result.ok, true);
  assertEquals(result.body["action"], "session");
});

Deno.test("readJsonBody rejects malformed JSON", async () => {
  const req = new Request("https://x/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: "{not-json",
  });
  const result = await readJsonBody(req, MAX_BODY_BYTES);
  assertEquals(result.ok, false);
  assertEquals(result.status, 400);
});

Deno.test("readJsonBody rejects oversized payloads", async () => {
  const req = new Request("https://x/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ big: "x".repeat(2048) }),
  });
  const result = await readJsonBody(req, 1024);
  assertEquals(result.ok, false);
  assertEquals(result.status, 413);
});

Deno.test("SlidingWindowRateLimiter allows then blocks", () => {
  const limiter = new SlidingWindowRateLimiter(60_000, 2);
  let now = 1_000;
  assertEquals(limiter.allow("ip-1", now), true);
  assertEquals(limiter.allow("ip-1", now + 1), true);
  assertEquals(limiter.allow("ip-1", now + 2), false);
  assertEquals(limiter.allow("ip-2", now + 2), true);
});

// ----------------------------------------------------------------------------
// 5. Service definition validation (exact addUpdateServices array body)
// ----------------------------------------------------------------------------

Deno.test("validateServicesPayload accepts the exact ABDM service array body", () => {
  const result = validateServicesPayload({
    action: "services",
    services: [
      {
        id: "hip-1",
        name: "Demo HIP",
        type: "HIP",
        active: true,
        alias: ["Demo"],
        endpoints: [
          {
            address: "https://hip.example/patients/status/notify",
            connectionType: "https",
            use: "PATIENT_STATUS_NOTIFY",
          },
        ],
      },
    ],
  }, ["HIP", "HIU"]);

  assertEquals(result.ok, true);
  const service = result.services?.[0];
  assertEquals(service?.id, "hip-1");
  assertEquals(service?.alias, ["Demo"]);
  assertEquals(service?.endpoints[0].address, "https://hip.example/patients/status/notify");
  assertEquals(service?.endpoints[0].connectionType, "https");
  assertEquals(service?.endpoints[0].use, "PATIENT_STATUS_NOTIFY");
});

Deno.test("validateServicesPayload rejects url instead of address", () => {
  const result = validateServicesPayload({
    services: [
      {
        id: "hip-1",
        name: "Demo HIP",
        type: "HIP",
        active: true,
        alias: [],
        endpoints: [{ url: "https://hip.example/notify", connectionType: "https", use: "X" }],
      },
    ],
  }, ["HIP", "HIU"]);

  assertEquals(result.ok, false);
  assert(
    result.errors.some((e) => e.includes("address is required")),
    "address must be required, url must not be accepted",
  );
});

Deno.test("validateServicesPayload rejects non-official service types", () => {
  const result = validateServicesPayload({
    services: [
      {
        id: "x",
        name: "X",
        type: "BOGUS",
        active: true,
        alias: [],
        endpoints: [{ address: "https://e", connectionType: "https", use: "X" }],
      },
    ],
  }, ["HIP", "HIU"]);

  assertEquals(result.ok, false);
  assert(result.errors.some((e) => e.includes("official service types")), "type must be validated");
});

Deno.test("validateServicesPayload rejects missing active/alias/use", () => {
  const result = validateServicesPayload({
    services: [
      {
        id: "x",
        name: "X",
        type: "HIP",
        endpoints: [{ address: "https://e", connectionType: "https" }],
      },
    ],
  }, ["HIP", "HIU"]);

  assertEquals(result.ok, false);
  assert(result.errors.some((e) => e.includes("active must be a boolean")), "active required");
  assert(result.errors.some((e) => e.includes("alias must be an array")), "alias required");
  assert(result.errors.some((e) => e.includes("use is required")), "use required");
});

// ----------------------------------------------------------------------------
// 6. Callback persistence + duplicate handling + payload sanitization
// ----------------------------------------------------------------------------

Deno.test("buildCallbackRow preserves path and never trusts a body hospital_id", () => {
  const row = buildCallbackRow({
    subpath: "/v0.5/patients/status/notify",
    body: {
      requestId: "req-1",
      hospital_id: "11111111-1111-1111-1111-111111111111",
      hospitalId: "22222222-2222-2222-2222-222222222222",
      accessToken: "super-secret-token",
      auth: { clientSecret: "s3cr3t" },
      patient: { id: "P1", name: "Rahul" },
    },
    requestId: "req-1",
    callbackType: "care-context-notify",
  });

  assertEquals(row.callback_path, "/v0.5/patients/status/notify");
  assertEquals(row.hospital_id, null);
  assertEquals(row.request_id, "req-1");
  assertEquals(row.callback_type, "care-context-notify");
  assertEquals((row.payload as Record<string, unknown>)["accessToken"], "[REDACTED]");
  assertEquals(
    ((row.payload as Record<string, unknown>)["auth"] as Record<string, unknown>)["clientSecret"],
    "[REDACTED]",
  );
  assertEquals(
    ((row.payload as Record<string, unknown>)["patient"] as Record<string, unknown>)["name"],
    "Rahul",
  );
});

Deno.test("sanitizePayload redacts OTP/Aadhaar/token keys and keeps safe data", () => {
  const sanitized = sanitizePayload({
    otp: "123456",
    aadhaar: "123456789012",
    "x-token": "tok",
    Authorization: "Bearer tok",
    name: "Rahul",
    nested: [{ access_token: "tok2", ok: true }],
  }) as Record<string, unknown>;

  assertEquals(sanitized["otp"], "[REDACTED]");
  assertEquals(sanitized["aadhaar"], "[REDACTED]");
  assertEquals(sanitized["x-token"], "[REDACTED]");
  assertEquals(sanitized["Authorization"], "[REDACTED]");
  assertEquals(sanitized["name"], "Rahul");
  const nested = (sanitized["nested"] as Record<string, unknown>[])[0];
  assertEquals(nested["access_token"], "[REDACTED]");
  assertEquals(nested["ok"], true);
});

Deno.test("persistCallback inserts a new row", async () => {
  let stored: CallbackRow | null = null;
  const result = await persistCallback(
    {
      insert: async (row) => {
        stored = row;
        return { error: null };
      },
    },
    buildCallbackRow({ subpath: "/cb", body: {} }),
  );
  assertEquals(result, "inserted");
  assert(stored !== null, "store should have received the row");
});

Deno.test("persistCallback treats duplicate request_id + path as idempotent", async () => {
  const result = await persistCallback(
    {
      insert: async () => ({ error: { code: "23505", message: "duplicate" } }),
    },
    buildCallbackRow({ subpath: "/cb", body: {} }),
  );
  assertEquals(result, "duplicate");
});

Deno.test("persistCallback rethrows non-duplicate database errors", async () => {
  let threw = false;
  try {
    await persistCallback(
      {
        insert: async () => ({ error: { code: "42501", message: "denied" } }),
      },
      buildCallbackRow({ subpath: "/cb", body: {} }),
    );
  } catch (_) {
    threw = true;
  }
  assert(threw, "non-duplicate errors must propagate");
});
