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
  buildCallbackRow,
  buildGatewayHeaders,
  getSubpath,
  isAdminRole,
  isReservedSubpath,
  parsePositiveInt,
  persistCallback,
  readConfig,
  readJsonBody,
  resolveBridgePath,
  resolveInternalAction,
  sanitizePayload,
  validateServicesPayload,
  type CallbackRow,
  type GatewayConfig,
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

Deno.test("resolveBridgePath does not append a bridge id", () => {
  assertEquals(resolveBridgePath(makeConfig()), "/gateway/v1/bridges");
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
