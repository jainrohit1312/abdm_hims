// ============================================================================
// Deno tests for the isolated diagnoseV3Gateway action in abdm-gateway.
//
// Run locally with:
//   cd supabase/functions/abdm-gateway && deno test --allow-read --allow-net .
//
// These tests never call live Supabase or live ABDM services. Supabase auth is
// injected as a fake and the ABDM gateway is a mocked fetch.
// ============================================================================

import { HttpError, SlidingWindowRateLimiter } from "./core.ts";
import { handleRequest } from "./handler.ts";
import type { AuthenticatedUser, RequestDeps } from "./handler.ts";
import type { TokenCacheRef } from "./core.ts";

function assertEquals<T>(actual: T, expected: T, message = ""): void {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  if (a !== b) {
    throw new Error(
      `${message ? message + " — " : ""}expected ${b}, got ${a}`,
    );
  }
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

interface CapturedCall {
  url: string;
  method: string;
  headers: Headers;
  body: unknown;
}

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const TIMESTAMP_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;

function recordingFetch(
  gatewayHandler: (
    url: string,
    method: string,
    headers: Headers,
    body: unknown,
  ) => Response,
): { fetchImpl: typeof fetch; calls: CapturedCall[] } {
  const calls: CapturedCall[] = [];
  const fetchImpl = (async (
    input: string | URL | Request,
    init?: RequestInit,
  ) => {
    const url = typeof input === "string"
      ? input
      : input instanceof URL
      ? input.toString()
      : input.url;
    const method = init?.method ?? "GET";
    const headers = new Headers(init?.headers ?? {});
    let body: unknown = null;
    if (typeof init?.body === "string") {
      try {
        body = JSON.parse(init.body);
      } catch (_) {
        body = init.body;
      }
    }
    calls.push({ url, method, headers, body });
    return gatewayHandler(url, method, headers, body);
  }) as typeof fetch;
  return { fetchImpl, calls };
}

function adminUser(): AuthenticatedUser {
  return {
    authId: "auth-1",
    userId: "user-1",
    role: "admin",
    hospitalId: "hosp-1",
  };
}

function superAdminUser(): AuthenticatedUser {
  return {
    authId: "auth-2",
    userId: "user-2",
    role: "super_admin",
    hospitalId: "hosp-1",
  };
}

function doctorUser(): AuthenticatedUser {
  return {
    authId: "auth-3",
    userId: "user-3",
    role: "doctor",
    hospitalId: "hosp-1",
  };
}

const envWithSecrets = {
  ABDM_CLIENT_ID: "sbx-client-id",
  ABDM_CLIENT_SECRET: "sbx-client-secret",
};

function freshTokenCache(): TokenCacheRef {
  return { current: null };
}

function deps(
  fetchImpl: typeof fetch,
  authenticate: RequestDeps["authenticate"],
  env: Record<string, string | undefined> = envWithSecrets,
  tokenCache?: TokenCacheRef,
): RequestDeps {
  return {
    env,
    fetchImpl,
    authenticate,
    persistCallbackRow: async () => {},
    tokenCache,
    // Fresh per-test V3 cache so the production V3 flows never share state.
    v3TokenCache: { current: null },
    // Fresh per-test limiter so the module-level worker-local default never
    // leaks state across tests.
    v3DiagnosticRateLimiter: new SlidingWindowRateLimiter(60_000, 1000),
  };
}

function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function v3Post(body: Record<string, unknown>): Request {
  return new Request("https://example.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

function sessionOkResponse(accessToken: string): Response {
  return jsonResponse({ accessToken, expiresIn: 3600 });
}

function servicesOkResponse(services: unknown): Response {
  return jsonResponse(services);
}

async function runV3(
  fetchImpl: typeof fetch,
  authenticate: RequestDeps["authenticate"],
  tokenCache?: TokenCacheRef,
  body: Record<string, unknown> = { action: "diagnoseV3Gateway" },
): Promise<Response> {
  return handleRequest(
    v3Post(body),
    deps(fetchImpl, authenticate, envWithSecrets, tokenCache),
  );
}

async function runV3Inspect(
  fetchImpl: typeof fetch,
  authenticate: RequestDeps["authenticate"],
  tokenCache?: TokenCacheRef,
): Promise<Response> {
  return runV3(
    fetchImpl,
    authenticate,
    tokenCache,
    { action: "inspectV3Bridge" },
  );
}

function parseBody(response: Response): Promise<Record<string, unknown>> {
  return response.json() as Promise<Record<string, unknown>>;
}

// ----------------------------------------------------------------------------
// Authorization / routing
// ----------------------------------------------------------------------------

Deno.test("v3: no JWT -> 401 and no ABDM request", async () => {
  const { fetchImpl, calls } = recordingFetch(() => {
    throw new Error("ABDM gateway must not be called without a Supabase JWT");
  });

  const response = await runV3(fetchImpl, async () => {
    throw new HttpError(401, "Missing bearer token");
  });

  assertEquals(response.status, 401);
  assertEquals(calls.length, 0);
});

Deno.test("v3: authenticated non-admin -> 403 and no ABDM request", async () => {
  const { fetchImpl, calls } = recordingFetch(() => {
    throw new Error("ABDM gateway must not be called for non-admin users");
  });

  const response = await runV3(fetchImpl, async () => doctorUser());

  assertEquals(response.status, 403);
  assertEquals(calls.length, 0);
});

Deno.test("v3: reserved subpath is protected, never a public callback", async () => {
  const { fetchImpl, calls } = recordingFetch(() => {
    throw new Error("ABDM gateway must not be called");
  });

  const request = new Request(
    "https://example.supabase.co/functions/v1/abdm-gateway/diagnoseV3Gateway",
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "diagnoseV3Gateway" }),
    },
  );
  const response = await handleRequest(
    request,
    deps(fetchImpl, async () => {
      throw new HttpError(401, "Missing bearer token");
    }),
  );

  // A public callback would return 200 ACK without authentication. The V3
  // diagnostic path is a protected internal action, so it must demand a JWT.
  assertEquals(response.status, 401);
  assertEquals(calls.length, 0);
});

// ----------------------------------------------------------------------------
// Exact upstream contract
// ----------------------------------------------------------------------------

Deno.test("v3: session POST uses the exact method/path/body/headers", async () => {
  const { fetchImpl, calls } = recordingFetch((url) => {
    if (url.includes("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.includes("/api/hiecm/gateway/v3/bridge-services")) {
      return servicesOkResponse([]);
    }
    throw new Error(`unexpected ABDM URL: ${url}`);
  });

  const response = await runV3(fetchImpl, async () => adminUser());
  const result = await parseBody(response);

  assertEquals(response.status, 200);
  assertEquals(result["sessionSucceeded"], true);
  assertEquals(calls.length, 2);

  const sessionCall = calls[0];
  assertEquals(sessionCall.method, "POST");
  assertEquals(
    sessionCall.url,
    "https://dev.abdm.gov.in/api/hiecm/gateway/v3/sessions",
  );
  assertEquals(sessionCall.headers.get("Content-Type"), "application/json");
  assertEquals(sessionCall.headers.get("X-CM-ID"), "sbx");
  assertEquals(sessionCall.headers.get("Authorization"), null);
  assertEquals(sessionCall.body, {
    clientId: "sbx-client-id",
    clientSecret: "sbx-client-secret",
    grantType: "client_credentials",
  });
});

Deno.test("v3: session and services requests carry fresh UUID + current timestamp", async () => {
  const before = Date.now();
  const { fetchImpl, calls } = recordingFetch((url) => {
    if (url.includes("/sessions")) return sessionOkResponse("fresh-v3-token");
    if (url.includes("/bridge-services")) return servicesOkResponse([]);
    throw new Error(`unexpected ABDM URL: ${url}`);
  });

  const response = await runV3(fetchImpl, async () => adminUser());
  assertEquals(response.status, 200);
  assertEquals(calls.length, 2);

  const requestIds = new Set<string>();
  for (const call of calls) {
    const requestId = call.headers.get("REQUEST-ID") ?? "";
    assert(
      UUID_PATTERN.test(requestId),
      `fresh UUID expected, got ${requestId}`,
    );
    requestIds.add(requestId);

    const timestamp = call.headers.get("TIMESTAMP") ?? "";
    assert(
      TIMESTAMP_PATTERN.test(timestamp),
      `ISO-8601 UTC timestamp expected, got ${timestamp}`,
    );
    const parsed = Date.parse(timestamp);
    assert(
      parsed >= before - 1000 && parsed <= Date.now() + 1000,
      "timestamp must be current UTC time",
    );
  }
  assertEquals(requestIds.size, 2);
});

Deno.test("v3: services GET uses only the fresh V3 token, never the legacy cache", async () => {
  const legacyExpiresAt = Date.now() + 60_000;
  const legacyCache: TokenCacheRef = {
    current: {
      accessToken: "legacy-cached-token",
      expiresAt: legacyExpiresAt,
    },
  };
  const { fetchImpl, calls } = recordingFetch((url) => {
    if (url.includes("/sessions")) return sessionOkResponse("fresh-v3-token");
    if (url.includes("/bridge-services")) return servicesOkResponse([]);
    throw new Error(`unexpected ABDM URL: ${url}`);
  });

  const response = await runV3(fetchImpl, async () => adminUser(), legacyCache);
  const result = await parseBody(response);

  assertEquals(response.status, 200);
  assertEquals(result["sessionSucceeded"], true);
  assertEquals(calls.length, 2);

  const servicesCall = calls[1];
  assertEquals(servicesCall.method, "GET");
  assertEquals(
    servicesCall.url,
    "https://dev.abdm.gov.in/api/hiecm/gateway/v3/bridge-services",
  );
  assertEquals(
    servicesCall.headers.get("Authorization"),
    "Bearer fresh-v3-token",
  );
  assertEquals(servicesCall.headers.get("X-CM-ID"), "sbx");
  assertEquals(servicesCall.body, null);

  // The legacy cache record must be untouched by the diagnostic.
  assertEquals(legacyCache.current?.accessToken, "legacy-cached-token");
  assertEquals(legacyCache.current?.expiresAt, legacyExpiresAt);
});

Deno.test("v3: diagnostic never performs Bridge PATCH or addUpdateServices POST", async () => {
  const { fetchImpl, calls } = recordingFetch((url) => {
    if (url.includes("/sessions")) return sessionOkResponse("fresh-v3-token");
    if (url.includes("/bridge-services")) return servicesOkResponse([]);
    throw new Error(`unexpected ABDM URL: ${url}`);
  });

  await runV3(fetchImpl, async () => adminUser());

  assertEquals(calls.length, 2);
  for (const call of calls) {
    assert(call.method !== "PATCH", "Bridge PATCH must never be called");
    assert(
      !call.url.includes("addUpdateServices"),
      "addUpdateServices must never be called",
    );
    assert(
      !call.url.includes("/bridge/url"),
      "bridge/url must never be called",
    );
  }
});

Deno.test("v3: client cannot override origin/path/headers/credentials/CM/token", async () => {
  const { fetchImpl, calls } = recordingFetch(() => {
    throw new Error("ABDM gateway must not be called");
  });

  const response = await runV3(
    fetchImpl,
    async () => adminUser(),
    undefined,
    {
      action: "diagnoseV3Gateway",
      baseUrl: "https://evil.example",
      path: "/custom",
      headers: { Authorization: "Bearer attacker" },
      credentials: "include",
      cmId: "prod",
      accessToken: "attacker-token",
    },
  );

  assertEquals(response.status, 400);
  assertEquals(calls.length, 0);
});

// ----------------------------------------------------------------------------
// Stage-specific failure classification
// ----------------------------------------------------------------------------

Deno.test("v3: session HTTP error prevents the services GET", async () => {
  const { fetchImpl, calls } = recordingFetch(() => jsonResponse({}, 401));

  const response = await runV3(fetchImpl, async () => adminUser());
  const result = await parseBody(response);

  assertEquals(response.status, 200);
  assertEquals(result["sessionSucceeded"], false);
  assertEquals(result["servicesSucceeded"], false);
  assertEquals(result["stage"], "session");
  assertEquals(result["code"], "ABDM_V3_SESSION_401");
  assertEquals(result["sessionUpstreamStatus"], 401);
  assertEquals(result["servicesUpstreamStatus"], null);
  assertEquals(calls.length, 1);
});

Deno.test("v3: services HTTP 403 preserves stage/status and does not claim provisioning", async () => {
  const { fetchImpl, calls } = recordingFetch((url) => {
    if (url.includes("/sessions")) return sessionOkResponse("fresh-v3-token");
    if (url.includes("/bridge-services")) return jsonResponse({}, 403);
    throw new Error(`unexpected ABDM URL: ${url}`);
  });

  const response = await runV3(fetchImpl, async () => adminUser());
  const result = await parseBody(response);

  assertEquals(response.status, 200);
  assertEquals(result["sessionSucceeded"], true);
  assertEquals(result["sessionUpstreamStatus"], 200);
  assertEquals(result["servicesSucceeded"], false);
  assertEquals(result["servicesUpstreamStatus"], 403);
  assertEquals(result["stage"], "services");
  assertEquals(result["code"], "ABDM_V3_SERVICES_403");
  const message = String(result["message"]);
  assert(
    message.includes("access was denied for this request"),
    "services 403 must say access was denied for this request",
  );
  assert(
    !message.toLowerCase().includes("provisioning") &&
      !message.toLowerCase().includes("onboarding"),
    "must not claim onboarding/provisioning is incomplete",
  );
  assertEquals(calls.length, 2);
});

Deno.test("v3: session network failure maps to ABDM_V3_SESSION_NETWORK", async () => {
  const { fetchImpl } = recordingFetch(() => {
    throw new TypeError("fetch failed");
  });

  const response = await runV3(fetchImpl, async () => adminUser());
  const result = await parseBody(response);

  assertEquals(result["code"], "ABDM_V3_SESSION_NETWORK");
  assertEquals(result["category"], "network");
  assertEquals(result["sessionUpstreamStatus"], null);
  assertEquals(result["stage"], "session");
});

Deno.test("v3: session timeout maps to ABDM_V3_SESSION_TIMEOUT", async () => {
  const { fetchImpl } = recordingFetch(() => {
    throw new DOMException("The operation timed out", "TimeoutError");
  });

  const response = await runV3(fetchImpl, async () => adminUser());
  const result = await parseBody(response);

  assertEquals(result["code"], "ABDM_V3_SESSION_TIMEOUT");
  assertEquals(result["category"], "timeout");
  assertEquals(result["sessionUpstreamStatus"], null);
});

Deno.test("v3: services network failure keeps sessionSucceeded true and stage services", async () => {
  const { fetchImpl } = recordingFetch((url) => {
    if (url.includes("/sessions")) return sessionOkResponse("fresh-v3-token");
    throw new TypeError("fetch failed");
  });

  const response = await runV3(fetchImpl, async () => adminUser());
  const result = await parseBody(response);

  assertEquals(result["sessionSucceeded"], true);
  assertEquals(result["servicesSucceeded"], false);
  assertEquals(result["stage"], "services");
  assertEquals(result["code"], "ABDM_V3_SERVICES_NETWORK");
  assertEquals(result["servicesUpstreamStatus"], null);
});

// ----------------------------------------------------------------------------
// Protocol (malformed/unexpected) responses
// ----------------------------------------------------------------------------

Deno.test("v3: 2xx session without a non-empty accessToken is a protocol failure", async () => {
  const { fetchImpl } = recordingFetch(() => jsonResponse({}, 200));

  const response = await runV3(fetchImpl, async () => adminUser());
  const result = await parseBody(response);

  assertEquals(result["sessionSucceeded"], false);
  assertEquals(result["stage"], "session");
  assertEquals(result["code"], "ABDM_V3_PROTOCOL_ERROR");
  assertEquals(result["sessionUpstreamStatus"], 200);
});

Deno.test("v3: 2xx session with the wrong token field is a protocol failure", async () => {
  const { fetchImpl } = recordingFetch(() =>
    jsonResponse({ token: "not-the-documented-field" }, 200)
  );

  const response = await runV3(fetchImpl, async () => adminUser());
  const result = await parseBody(response);

  assertEquals(result["code"], "ABDM_V3_PROTOCOL_ERROR");
});

Deno.test("v3: unexpected services response shape is protocol error, not zero services", async () => {
  const { fetchImpl } = recordingFetch((url) => {
    if (url.includes("/sessions")) return sessionOkResponse("fresh-v3-token");
    if (url.includes("/bridge-services")) {
      return jsonResponse({ foo: "bar" }, 200);
    }
    throw new Error(`unexpected ABDM URL: ${url}`);
  });

  const response = await runV3(fetchImpl, async () => adminUser());
  const result = await parseBody(response);

  assertEquals(result["servicesSucceeded"], false);
  assertEquals(result["stage"], "services");
  assertEquals(result["code"], "ABDM_V3_PROTOCOL_ERROR");
  assertEquals(result["serviceCount"], null);
});

Deno.test("v3: recognized empty service list succeeds with serviceCount 0", async () => {
  const { fetchImpl } = recordingFetch((url) => {
    if (url.includes("/sessions")) return sessionOkResponse("fresh-v3-token");
    if (url.includes("/bridge-services")) return servicesOkResponse([]);
    throw new Error(`unexpected ABDM URL: ${url}`);
  });

  const response = await runV3(fetchImpl, async () => adminUser());
  const result = await parseBody(response);

  assertEquals(result["sessionSucceeded"], true);
  assertEquals(result["servicesSucceeded"], true);
  assertEquals(result["serviceCount"], 0);
  assertEquals(result["stage"], "complete");
  assertEquals(result["code"], "ABDM_V3_OK");
});

Deno.test("v3: recognized non-empty service list returns sanitized id/name/types/active", async () => {
  const { fetchImpl } = recordingFetch((url) => {
    if (url.includes("/sessions")) return sessionOkResponse("fresh-v3-token");
    if (url.includes("/bridge-services")) {
      return servicesOkResponse([
        {
          id: "hip-1",
          name: "Demo HIP",
          type: "HIP",
          active: true,
          alias: ["Demo"],
          endpoints: [{ address: "https://cb.example" }],
          accessToken: "must-be-redacted",
          clientSecret: "must-be-redacted",
        },
      ]);
    }
    throw new Error(`unexpected ABDM URL: ${url}`);
  });

  const response = await runV3(fetchImpl, async () => adminUser());
  const result = await parseBody(response);

  assertEquals(result["servicesSucceeded"], true);
  assertEquals(result["serviceCount"], 1);
  const services = result["services"] as Record<string, unknown>[];
  assertEquals(services.length, 1);
  assertEquals(services[0], {
    id: "hip-1",
    name: "Demo HIP",
    types: ["HIP"],
    active: true,
    endpoints: [{ address: "https://cb.example" }],
  });
  const rawBody = JSON.stringify(result);
  assert(!rawBody.includes("must-be-redacted"), "token/secret leaked");
  assert(!rawBody.includes("fresh-v3-token"), "V3 token leaked");
  assert(!rawBody.includes("sbx-client-secret"), "client secret leaked");
});

// ----------------------------------------------------------------------------
// Retry / sequence guarantees
// ----------------------------------------------------------------------------

Deno.test("v3: 401/403 are never retried and the sequence is at most 2 calls", async () => {
  const { fetchImpl, calls } = recordingFetch((url) => {
    if (url.includes("/sessions")) return sessionOkResponse("fresh-v3-token");
    return jsonResponse({}, 403);
  });

  const response = await runV3(fetchImpl, async () => adminUser());
  const result = await parseBody(response);

  assertEquals(result["code"], "ABDM_V3_SERVICES_403");
  assertEquals(calls.length, 2);
});

Deno.test("v3: super_admin role is also authorized", async () => {
  const { fetchImpl } = recordingFetch((url) => {
    if (url.includes("/sessions")) return sessionOkResponse("fresh-v3-token");
    if (url.includes("/bridge-services")) return servicesOkResponse([]);
    throw new Error(`unexpected ABDM URL: ${url}`);
  });

  const response = await runV3(fetchImpl, async () => superAdminUser());
  assertEquals(response.status, 200);
});

// ----------------------------------------------------------------------------
// Read-only V3 bridge inspection (inspectV3Bridge)
// ----------------------------------------------------------------------------

Deno.test("v3 bridge inspect: bridge present + services empty", async () => {
  const { fetchImpl } = recordingFetch((url) => {
    if (url.includes("/sessions")) return sessionOkResponse("fresh-v3-token");
    if (url.includes("/bridge-services")) {
      return jsonResponse({
        bridge: { url: "https://cb.example/abdm" },
        services: [],
      });
    }
    throw new Error(`unexpected ABDM URL: ${url}`);
  });

  const response = await runV3Inspect(fetchImpl, async () => adminUser());
  const result = await parseBody(response);
  const envelope = result["envelope"] as Record<string, unknown>;
  const bridge = envelope["bridge"] as Record<string, unknown>;
  const bridgeUrl = envelope["bridgeUrl"] as Record<string, unknown>;
  const services = envelope["services"] as Record<string, unknown>;

  assertEquals(response.status, 200);
  assertEquals(result["operation"], "inspectV3Bridge");
  assertEquals(result["sessionSucceeded"], true);
  assertEquals(result["servicesSucceeded"], true);
  assertEquals(envelope["topLevelType"], "object");
  assertEquals(envelope["topLevelFieldNames"], ["bridge", "services"]);
  assertEquals(bridge["exists"], true);
  assertEquals(bridge["fieldNames"], ["url"]);
  assertEquals(bridgeUrl["exists"], true);
  assertEquals(bridgeUrl["value"], "https://cb.example/abdm");
  assertEquals(services["exists"], true);
  assertEquals(services["length"], 0);
  assertEquals(envelope["unknownEnvelopeFieldNames"], []);
});

Deno.test("v3 bridge inspect: bridge present + services populated and sanitized", async () => {
  const { fetchImpl } = recordingFetch((url) => {
    if (url.includes("/sessions")) return sessionOkResponse("fresh-v3-token");
    if (url.includes("/bridge-services")) {
      return jsonResponse({
        bridge: {
          hostUrl: "https://cb.example/abdm?token=abc",
          facilities: ["facility-1"],
        },
        services: [
          {
            id: "hip-1",
            name: "Demo HIP",
            type: "HIP",
            active: true,
            alias: ["Demo"],
            accessToken: "must-be-redacted",
          },
        ],
      });
    }
    throw new Error(`unexpected ABDM URL: ${url}`);
  });

  const response = await runV3Inspect(fetchImpl, async () => adminUser());
  const result = await parseBody(response);
  const envelope = result["envelope"] as Record<string, unknown>;
  const bridge = envelope["bridge"] as Record<string, unknown>;
  const bridgeUrl = envelope["bridgeUrl"] as Record<string, unknown>;
  const services = envelope["services"] as Record<string, unknown>;
  const items = services["items"] as Record<string, unknown>[];

  assertEquals(envelope["topLevelType"], "object");
  assertEquals(bridge["exists"], true);
  assertEquals(bridge["fieldNames"], ["hostUrl", "facilities"]);
  assertEquals(bridgeUrl["exists"], true);
  // Query strings are dropped and the value stays safe.
  assertEquals(bridgeUrl["value"], "https://cb.example/abdm");
  assertEquals(services["exists"], true);
  assertEquals(services["length"], 1);
  assertEquals(items[0], {
    id: "hip-1",
    name: "Demo HIP",
    types: ["HIP"],
    active: true,
  });
  const rawBody = JSON.stringify(result);
  assert(!rawBody.includes("must-be-redacted"), "service token leaked");
  assert(!rawBody.includes("token=abc"), "URL query leaked");
});

Deno.test("v3 bridge inspect: bridge absent is reported truthfully", async () => {
  const { fetchImpl } = recordingFetch((url) => {
    if (url.includes("/sessions")) return sessionOkResponse("fresh-v3-token");
    if (url.includes("/bridge-services")) {
      return jsonResponse({ services: [] });
    }
    throw new Error(`unexpected ABDM URL: ${url}`);
  });

  const response = await runV3Inspect(fetchImpl, async () => adminUser());
  const result = await parseBody(response);
  const envelope = result["envelope"] as Record<string, unknown>;
  const bridge = envelope["bridge"] as Record<string, unknown>;
  const bridgeUrl = envelope["bridgeUrl"] as Record<string, unknown>;
  const services = envelope["services"] as Record<string, unknown>;

  assertEquals(bridge["exists"], false);
  assertEquals(bridge["fieldNames"], []);
  assertEquals(bridgeUrl["exists"], false);
  assertEquals(bridgeUrl["value"], null);
  assertEquals(services["exists"], true);
  assertEquals(services["length"], 0);
  assertEquals(envelope["unknownEnvelopeFieldNames"], []);
});

Deno.test("v3 bridge inspect: unexpected envelope fields are surfaced", async () => {
  const { fetchImpl } = recordingFetch((url) => {
    if (url.includes("/sessions")) return sessionOkResponse("fresh-v3-token");
    if (url.includes("/bridge-services")) {
      return jsonResponse({ foo: "bar", baz: [1, 2] });
    }
    throw new Error(`unexpected ABDM URL: ${url}`);
  });

  const response = await runV3Inspect(fetchImpl, async () => adminUser());
  const result = await parseBody(response);
  const envelope = result["envelope"] as Record<string, unknown>;
  const bridge = envelope["bridge"] as Record<string, unknown>;
  const services = envelope["services"] as Record<string, unknown>;

  assertEquals(envelope["topLevelType"], "object");
  assertEquals(envelope["topLevelFieldNames"], ["foo", "baz"]);
  assertEquals(envelope["unknownEnvelopeFieldNames"], ["foo", "baz"]);
  assertEquals(bridge["exists"], false);
  assertEquals(services["exists"], false);
});

Deno.test("v3 bridge inspect: never echoes tokens, secrets, cookies or clientId names", async () => {
  const { fetchImpl } = recordingFetch((url) => {
    if (url.includes("/sessions")) return sessionOkResponse("fresh-v3-token");
    if (url.includes("/bridge-services")) {
      return jsonResponse({
        accessToken: "top-secret-token",
        clientSecret: "top-secret-client-secret",
        clientId: "top-secret-client-id",
        cookie: "session-cookie-value",
        bridge: { url: "https://cb.example/x?token=abc", clientSecret: "s2" },
        services: [],
      });
    }
    throw new Error(`unexpected ABDM URL: ${url}`);
  });

  const response = await runV3Inspect(fetchImpl, async () => adminUser());
  const result = await parseBody(response);
  const rawBody = JSON.stringify(result);
  const envelope = result["envelope"] as Record<string, unknown>;

  assertEquals(envelope["topLevelFieldNames"], ["bridge", "services"]);
  assert(!rawBody.includes("accessToken"), "accessToken field name leaked");
  assert(!rawBody.includes("clientSecret"), "clientSecret field name leaked");
  assert(!rawBody.includes("clientId"), "clientId field name leaked");
  assert(!rawBody.includes("cookie"), "cookie field name leaked");
  assert(!rawBody.includes("top-secret-token"), "token value leaked");
  assert(!rawBody.includes("top-secret-client-secret"), "secret value leaked");
  assert(!rawBody.includes("top-secret-client-id"), "client id value leaked");
  assert(!rawBody.includes("session-cookie-value"), "cookie value leaked");
  assert(!rawBody.includes("s2"), "nested secret leaked");
  assert(!rawBody.includes("token=abc"), "URL query leaked");
});

Deno.test("v3 bridge inspect: never performs any mutation request", async () => {
  const { fetchImpl, calls } = recordingFetch((url) => {
    if (url.includes("/sessions")) return sessionOkResponse("fresh-v3-token");
    if (url.includes("/bridge-services")) {
      return jsonResponse({
        bridge: { url: "https://cb.example/abdm" },
        services: [],
      });
    }
    throw new Error(`unexpected ABDM URL: ${url}`);
  });

  await runV3Inspect(fetchImpl, async () => adminUser());

  assertEquals(calls.length, 2);
  assertEquals(calls[0].method, "POST");
  assertEquals(calls[1].method, "GET");
  for (const call of calls) {
    assert(call.method !== "PATCH", "PATCH mutation must never be called");
    assert(call.method !== "PUT", "PUT mutation must never be called");
    assert(
      !call.url.includes("/bridge/url"),
      "bridge/url mutation must never be called",
    );
    assert(
      !call.url.includes("addUpdateServices"),
      "addUpdateServices must never be called",
    );
  }
});

Deno.test("v3 bridge inspect: legacy cache remains unchanged", async () => {
  const legacyExpiresAt = Date.now() + 60_000;
  const legacyCache: TokenCacheRef = {
    current: {
      accessToken: "legacy-cached-token",
      expiresAt: legacyExpiresAt,
    },
  };
  const { fetchImpl } = recordingFetch((url) => {
    if (url.includes("/sessions")) return sessionOkResponse("fresh-v3-token");
    if (url.includes("/bridge-services")) return servicesOkResponse([]);
    throw new Error(`unexpected ABDM URL: ${url}`);
  });

  const response = await runV3Inspect(
    fetchImpl,
    async () => adminUser(),
    legacyCache,
  );
  assertEquals(response.status, 200);
  assertEquals(legacyCache.current?.accessToken, "legacy-cached-token");
  assertEquals(legacyCache.current?.expiresAt, legacyExpiresAt);
});

Deno.test("v3 bridge inspect: session error prevents the services GET", async () => {
  const { fetchImpl, calls } = recordingFetch(() => jsonResponse({}, 401));

  const response = await runV3Inspect(fetchImpl, async () => adminUser());
  const result = await parseBody(response);

  assertEquals(result["sessionSucceeded"], false);
  assertEquals(result["stage"], "session");
  assertEquals(result["code"], "ABDM_V3_SESSION_401");
  assertEquals(result["envelope"], null);
  assertEquals(calls.length, 1);
});

Deno.test("v3 bridge inspect: no JWT -> 401 and no ABDM request", async () => {
  const { fetchImpl, calls } = recordingFetch(() => {
    throw new Error("ABDM gateway must not be called without a Supabase JWT");
  });

  const response = await runV3Inspect(fetchImpl, async () => {
    throw new HttpError(401, "Missing bearer token");
  });

  assertEquals(response.status, 401);
  assertEquals(calls.length, 0);
});

Deno.test("v3 bridge inspect: non-admin -> 403 and no ABDM request", async () => {
  const { fetchImpl, calls } = recordingFetch(() => {
    throw new Error("ABDM gateway must not be called for non-admin users");
  });

  const response = await runV3Inspect(fetchImpl, async () => doctorUser());

  assertEquals(response.status, 403);
  assertEquals(calls.length, 0);
});

// ----------------------------------------------------------------------------
// Canonical V3 production flow regression (session + getServices)
// ----------------------------------------------------------------------------

Deno.test("v3: production session action uses the canonical V3 session flow", async () => {
  const { fetchImpl, calls } = recordingFetch((url) => {
    if (url.includes("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    throw new Error(`unexpected ABDM URL: ${url}`);
  });

  const response = await handleRequest(
    v3Post({ action: "session" }),
    deps(fetchImpl, async () => adminUser(), envWithSecrets, freshTokenCache()),
  );
  const result = await parseBody(response);

  assertEquals(response.status, 200);
  assertEquals(result["status"], "connected");
  assertEquals(result["baseUrl"], "https://dev.abdm.gov.in");
  assertEquals(calls.length, 1);
  assertEquals(calls[0].method, "POST");
  assertEquals(
    calls[0].url,
    "https://dev.abdm.gov.in/api/hiecm/gateway/v3/sessions",
  );
  assertEquals(calls[0].body, {
    clientId: "sbx-client-id",
    clientSecret: "sbx-client-secret",
    grantType: "client_credentials",
  });
  assertEquals(calls[0].headers.get("X-CM-ID"), "sbx");
  assertEquals(calls[0].headers.get("Authorization"), null);
});

Deno.test("v3: production getServices action uses the canonical V3 bridge-services flow", async () => {
  const { fetchImpl, calls } = recordingFetch((url) => {
    if (url.includes("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.includes("/api/hiecm/gateway/v3/bridge-services")) {
      return jsonResponse(
        { bridge: { url: "https://cb.example/abdm" }, services: [] },
        200,
      );
    }
    throw new Error(`unexpected ABDM URL: ${url}`);
  });

  const response = await handleRequest(
    v3Post({ action: "getServices" }),
    deps(fetchImpl, async () => adminUser(), envWithSecrets, freshTokenCache()),
  );
  const result = await parseBody(response);

  assertEquals(response.status, 200);
  assertEquals(result["status"], "services_fetched_v3");
  assertEquals(calls.length, 2);
  assertEquals(calls[1].method, "GET");
  assertEquals(
    calls[1].url,
    "https://dev.abdm.gov.in/api/hiecm/gateway/v3/bridge-services",
  );
  assertEquals(calls[1].headers.get("Authorization"), "Bearer fresh-v3-token");
});
