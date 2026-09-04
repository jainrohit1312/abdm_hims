// ============================================================================
// Deno handler-level tests for the abdm-gateway Edge Function.
//
// Run locally with:
//   cd supabase/functions/abdm-gateway && deno test --allow-read --allow-net .
//
// These tests never call live Supabase or live ABDM services. Supabase auth is
// injected as a fake and the ABDM gateway is a mocked fetch.
// ============================================================================

import { HttpError } from "./core.ts";
import {
  handleRequest,
  type AuthenticatedUser,
  type RequestDeps,
} from "./handler.ts";
import type { CallbackRow, TokenCacheRef } from "./core.ts";

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

function recordingFetch(
  gatewayHandler: (url: string, method: string, headers: Headers, body: unknown) => Response,
): { fetchImpl: typeof fetch; calls: CapturedCall[] } {
  const calls: CapturedCall[] = [];
  const fetchImpl = (async (input: string | URL | Request, init?: RequestInit) => {
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
  return { authId: "auth-1", userId: "user-1", role: "admin", hospitalId: null };
}

function doctorUser(): AuthenticatedUser {
  return { authId: "auth-2", userId: "user-2", role: "doctor", hospitalId: null };
}

const envWithSecrets = {
  ABDM_CLIENT_ID: "client-id",
  ABDM_CLIENT_SECRET: "client-secret",
  ABDM_CALLBACK_BASE_URL: "https://cb.example/abdm",
};

function gatewayResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function deps(
  fetchImpl: typeof fetch,
  authenticate: RequestDeps["authenticate"],
  persistCallbackRow: RequestDeps["persistCallbackRow"],
  env: Record<string, string | undefined> = {},
  tokenCache?: TokenCacheRef,
): RequestDeps {
  return { env, fetchImpl, authenticate, persistCallbackRow, tokenCache };
}

function freshTokenCache(): TokenCacheRef {
  return { current: null };
}

// ----------------------------------------------------------------------------
// 1. Public callbacks (no Supabase JWT)
// ----------------------------------------------------------------------------

Deno.test("callback succeeds without a Supabase JWT and is persisted sanitized", async () => {
  let authCalled = false;
  const rows: CallbackRow[] = [];

  const requestDeps = deps(
    recordingFetch(() => {
      throw new Error("ABDM gateway must not be called for callbacks");
    }).fetchImpl,
    async () => {
      authCalled = true;
      throw new Error("auth must not be called for public callbacks");
    },
    async (row) => {
      rows.push(row);
    },
  );

  const req = new Request(
    "https://x.supabase.co/functions/v1/abdm-gateway/v0.5/patients/status/notify",
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "request-id": "req-1",
        timestamp: "2026-09-04T10:00:00.000Z",
      },
      body: JSON.stringify({
        requestId: "req-1",
        accessToken: "should-be-redacted",
        patient: { id: "P1", name: "Rahul" },
      }),
    },
  );

  const res = await handleRequest(req, requestDeps);

  assertEquals(res.status, 200);
  assertEquals(await res.json(), { status: "ACK" });
  assert(!authCalled, "public callback must not trigger Supabase auth");
  assertEquals(rows.length, 1);
  assertEquals(rows[0].callback_path, "/v0.5/patients/status/notify");
  assertEquals(rows[0].hospital_id, null);
  assertEquals(rows[0].gateway_timestamp, "2026-09-04T10:00:00.000Z");
  assertEquals((rows[0].payload as Record<string, unknown>)["accessToken"], "[REDACTED]");
});

Deno.test("public callback cannot trigger an administrative action via JSON action", async () => {
  let authCalled = false;
  const rows: CallbackRow[] = [];

  const requestDeps = deps(
    recordingFetch(() => {
      throw new Error("ABDM gateway must not be called");
    }).fetchImpl,
    async () => {
      authCalled = true;
      throw new Error("auth must not be called");
    },
    async (row) => {
      rows.push(row);
    },
  );

  const req = new Request(
    "https://x.supabase.co/functions/v1/abdm-gateway/v0.5/notify",
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "session" }),
    },
  );

  const res = await handleRequest(req, requestDeps);

  assertEquals(res.status, 200, "callback subpath must stay a callback");
  assert(!authCalled, "public callback must not trigger Supabase auth");
  assertEquals(rows.length, 1);
  assertEquals(rows[0].callback_path, "/v0.5/notify");
});

Deno.test("root POST without a callback subpath is rejected", async () => {
  const requestDeps = deps(
    recordingFetch(() => {
      throw new Error("gateway must not be called");
    }).fetchImpl,
    async () => {
      throw new HttpError(401, "Invalid or expired user session");
    },
    async () => {},
    envWithSecrets,
  );

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "session" }),
  });

  const res = await handleRequest(req, requestDeps);
  // `action: session` on the bare function URL resolves to a protected action
  // and fails on missing JWT — it is never treated as a public callback.
  assertEquals(res.status, 401);
});

Deno.test("reserved internal path with wrong method is never a callback", async () => {
  let persisted = false;
  let authCalled = false;

  const requestDeps = deps(
    recordingFetch(() => {
      throw new Error("gateway must not be called");
    }).fetchImpl,
    async () => {
      authCalled = true;
      throw new Error("auth must not be called");
    },
    async () => {
      persisted = true;
    },
  );

  const req = new Request(
    "https://x.supabase.co/functions/v1/abdm-gateway/bridge",
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "session" }),
    },
  );

  const res = await handleRequest(req, requestDeps);

  assertEquals(res.status, 405);
  assert(!authCalled, "reserved path with wrong method must not require auth");
  assert(!persisted, "reserved path with wrong method must not persist a callback");
});

// ----------------------------------------------------------------------------
// 2. Protected actions fail without JWT
// ----------------------------------------------------------------------------

Deno.test("session action fails without JWT", async () => {
  const requestDeps = deps(
    recordingFetch(() => {
      throw new Error("ABDM gateway must not be called");
    }).fetchImpl,
    async () => {
      throw new HttpError(401, "Invalid or expired user session");
    },
    async () => {},
    envWithSecrets,
  );

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "session" }),
  });

  const res = await handleRequest(req, requestDeps);
  assertEquals(res.status, 401);
});

Deno.test("bridge action fails without JWT", async () => {
  const requestDeps = deps(
    recordingFetch(() => {
      throw new Error("ABDM gateway must not be called");
    }).fetchImpl,
    async () => {
      throw new HttpError(401, "Invalid or expired user session");
    },
    async () => {},
    envWithSecrets,
  );

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "bridge", callbackUrl: "https://cb.example" }),
  });

  const res = await handleRequest(req, requestDeps);
  assertEquals(res.status, 401);
});

Deno.test("services action fails without JWT", async () => {
  const requestDeps = deps(
    recordingFetch(() => {
      throw new Error("ABDM gateway must not be called");
    }).fetchImpl,
    async () => {
      throw new HttpError(401, "Invalid or expired user session");
    },
    async () => {},
    envWithSecrets,
  );

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      action: "services",
      services: [
        {
          id: "hip-1",
          name: "HIP",
          type: "HIP",
          active: true,
          alias: [],
          endpoints: [{ address: "https://e", connectionType: "https", use: "X" }],
        },
      ],
    }),
  });

  const res = await handleRequest(req, requestDeps);
  assertEquals(res.status, 401);
});

Deno.test("non-owner authenticated user receives 403 for session", async () => {
  const requestDeps = deps(
    recordingFetch(() => {
      throw new Error("ABDM gateway must not be called for non-owner");
    }).fetchImpl,
    async () => doctorUser(),
    async () => {},
    envWithSecrets,
  );

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "session" }),
  });

  const res = await handleRequest(req, requestDeps);
  assertEquals(res.status, 403);
  assertEquals((await res.json())["error"], "Owner / super-admin role required for this action");
});

// ----------------------------------------------------------------------------
// 3. Exact Bridge / addUpdateServices / getServices contracts
// ----------------------------------------------------------------------------

Deno.test("bridge update uses PATCH /gateway/v1/bridges with exact url body from the secret", async () => {
  const { fetchImpl, calls } = recordingFetch((url, method) => {
    if (url.endsWith("/gateway/v1/sessions")) {
      return gatewayResponse({ accessToken: "abdm-token", expiresIn: 3600 });
    }
    if (url.endsWith("/gateway/v1/bridges") && method === "PATCH") {
      return gatewayResponse({ ok: true });
    }
    throw new Error(`unexpected gateway call: ${method} ${url}`);
  });

  const requestDeps = deps(fetchImpl, async () => adminUser(), async () => {}, envWithSecrets, freshTokenCache());

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "bridge" }),
  });

  const res = await handleRequest(req, requestDeps);
  assertEquals(res.status, 200);
  const resBody = await res.json() as Record<string, unknown>;
  assertEquals(resBody["status"], "bridge_configured");
  assertEquals(resBody["callbackUrl"], "https://cb.example/abdm");

  const bridgeCall = calls.find((c) => c.url.endsWith("/gateway/v1/bridges"));
  assert(bridgeCall, "bridge endpoint must be called");
  assertEquals(bridgeCall.method, "PATCH");
  assertEquals(bridgeCall.body, { url: "https://cb.example/abdm" });
  assertEquals(
    bridgeCall.headers.get("Authorization"),
    "Bearer abdm-token",
    "gateway request must carry Authorization Bearer",
  );
});

Deno.test("addUpdateServices uses the exact array body with address/connectionType/use", async () => {
  const { fetchImpl, calls } = recordingFetch((url, method) => {
    if (url.endsWith("/gateway/v1/sessions")) {
      return gatewayResponse({ accessToken: "abdm-token", expiresIn: 3600 });
    }
    if (url.endsWith("/gateway/v1/bridges/addUpdateServices") && method === "POST") {
      return gatewayResponse([]);
    }
    throw new Error(`unexpected gateway call: ${method} ${url}`);
  });

  const requestDeps = deps(fetchImpl, async () => adminUser(), async () => {}, envWithSecrets, freshTokenCache());

  const servicePayload = {
    id: "hip-1",
    name: "Demo HIP",
    type: "HIP",
    active: true,
    alias: ["Demo"],
    endpoints: [
      {
        address: "https://cb.example/abdm/patients/status/notify",
        connectionType: "https",
        use: "PATIENT_STATUS_NOTIFY",
      },
    ],
  };

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "services", services: [servicePayload] }),
  });

  const res = await handleRequest(req, requestDeps);
  assertEquals(res.status, 200);

  const servicesCall = calls.find((c) =>
    c.url.endsWith("/gateway/v1/bridges/addUpdateServices")
  );
  assert(servicesCall, "addUpdateServices endpoint must be called");
  assertEquals(servicesCall.method, "POST");
  assertEquals(servicesCall.body, [servicePayload]);
  assertEquals(servicesCall.headers.get("Authorization"), "Bearer abdm-token");
});

Deno.test("getServices uses GET /gateway/v1/bridges/getServices", async () => {
  const { fetchImpl, calls } = recordingFetch((url, method) => {
    if (url.endsWith("/gateway/v1/sessions")) {
      return gatewayResponse({ accessToken: "abdm-token", expiresIn: 3600 });
    }
    if (url.endsWith("/gateway/v1/bridges/getServices") && method === "GET") {
      return gatewayResponse([]);
    }
    throw new Error(`unexpected gateway call: ${method} ${url}`);
  });

  const requestDeps = deps(fetchImpl, async () => adminUser(), async () => {}, envWithSecrets, freshTokenCache());

  const req = new Request(
    "https://x.supabase.co/functions/v1/abdm-gateway?action=services",
    { method: "GET" },
  );

  const res = await handleRequest(req, requestDeps);
  assertEquals(res.status, 200);

  const getCall = calls.find((c) => c.url.endsWith("/gateway/v1/bridges/getServices"));
  assert(getCall, "getServices endpoint must be called");
  assertEquals(getCall.method, "GET");
  assertEquals(getCall.headers.get("Authorization"), "Bearer abdm-token");
});

// ----------------------------------------------------------------------------
// 4. Secrets and access tokens remain redacted
// ----------------------------------------------------------------------------

Deno.test("session response never returns the raw ABDM token", async () => {
  const { fetchImpl } = recordingFetch((url) => {
    if (url.endsWith("/gateway/v1/sessions")) {
      return gatewayResponse({ accessToken: "super-secret-abdm-token", expiresIn: 3600 });
    }
    throw new Error(`unexpected gateway call: ${url}`);
  });

  const requestDeps = deps(fetchImpl, async () => adminUser(), async () => {}, envWithSecrets, freshTokenCache());

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "session" }),
  });

  const res = await handleRequest(req, requestDeps);
  const text = await res.text();

  assert(!text.includes("super-secret-abdm-token"), "raw token must never be returned");
  assert(!text.includes("accessToken"), "accessToken key must never be returned");
  assertEquals(res.status, 200);
});

Deno.test("session maps ABDM auth rejection to a sanitized 502 message", async () => {
  const { fetchImpl } = recordingFetch((url) => {
    if (url.endsWith("/gateway/v1/sessions")) {
      return gatewayResponse({ error: "invalid_client" }, 401);
    }
    throw new Error(`unexpected gateway call: ${url}`);
  });

  const requestDeps = deps(fetchImpl, async () => adminUser(), async () => {}, envWithSecrets, freshTokenCache());

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "session" }),
  });

  const res = await handleRequest(req, requestDeps);
  const text = await res.text();

  assertEquals(res.status, 502);
  assert(
    text.includes("ABDM authentication rejected: verify Client ID/rotated Client Secret"),
    "ABDM 401 must surface as a sanitized authentication-rejection message",
  );
  assert(!text.includes("client-id"), "client id must never leak");
  assert(!text.includes("client-secret"), "client secret must never leak");
});

Deno.test("session maps ABDM 404 to the v0.5 endpoint override message", async () => {
  const { fetchImpl } = recordingFetch((url) => {
    if (url.endsWith("/gateway/v1/sessions")) {
      return gatewayResponse({ error: "not found" }, 404);
    }
    throw new Error(`unexpected gateway call: ${url}`);
  });

  const requestDeps = deps(fetchImpl, async () => adminUser(), async () => {}, envWithSecrets, freshTokenCache());

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "session" }),
  });

  const res = await handleRequest(req, requestDeps);
  const text = await res.text();

  assertEquals(res.status, 502);
  assert(
    text.includes("ABDM session endpoint may need v0.5 override"),
    "ABDM 404 must surface as the v0.5 endpoint override message",
  );
});

Deno.test("gateway responses echoed to Flutter are sanitized", async () => {
  const { fetchImpl } = recordingFetch((url) => {
    if (url.endsWith("/gateway/v1/sessions")) {
      return gatewayResponse({ accessToken: "abdm-token", expiresIn: 3600 });
    }
    if (url.endsWith("/gateway/v1/bridges")) {
      return gatewayResponse({ accessToken: "echoed-token", status: "ok" });
    }
    throw new Error(`unexpected gateway call: ${url}`);
  });

  const requestDeps = deps(fetchImpl, async () => adminUser(), async () => {}, envWithSecrets, freshTokenCache());

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "bridge" }),
  });

  const res = await handleRequest(req, requestDeps);
  const body = await res.json();

  assertEquals(res.status, 200);
  const gateway = (body as Record<string, unknown>)[
    "gateway"
  ] as Record<string, unknown>;
  assertEquals(gateway["accessToken"], "[REDACTED]");
  assertEquals(JSON.stringify(body).includes("echoed-token"), false);
});

Deno.test("bridge rejects a client-supplied callbackUrl without calling the gateway", async () => {
  const { fetchImpl, calls } = recordingFetch(() => {
    throw new Error("ABDM gateway must not be called when callbackUrl is supplied by the client");
  });

  const requestDeps = deps(fetchImpl, async () => adminUser(), async () => {}, envWithSecrets, freshTokenCache());

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "bridge", callbackUrl: "https://evil.example/steal" }),
  });

  const res = await handleRequest(req, requestDeps);
  const body = await res.json();

  assertEquals(res.status, 400);
  assert(
    String((body as Record<string, unknown>)["error"]).includes("not allowed"),
    "client-supplied callbackUrl must be rejected",
  );
  assertEquals(calls.length, 0, "gateway must never be called");
});

Deno.test("bridge rejects a client-supplied url field without calling the gateway", async () => {
  const { fetchImpl, calls } = recordingFetch(() => {
    throw new Error("ABDM gateway must not be called when url is supplied by the client");
  });

  const requestDeps = deps(fetchImpl, async () => adminUser(), async () => {}, envWithSecrets, freshTokenCache());

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "bridge", url: "https://evil.example/steal" }),
  });

  const res = await handleRequest(req, requestDeps);
  const body = await res.json();

  assertEquals(res.status, 400);
  assert(
    String((body as Record<string, unknown>)["error"]).includes("not allowed"),
    "client-supplied url must be rejected",
  );
  assertEquals(calls.length, 0, "gateway must never be called");
});

Deno.test("bridge fails sanitized when ABDM_CALLBACK_BASE_URL is missing", async () => {
  const { fetchImpl, calls } = recordingFetch(() => {
    throw new Error("ABDM gateway must not be called without a callback secret");
  });

  const env = { ABDM_CLIENT_ID: "client-id", ABDM_CLIENT_SECRET: "client-secret" };
  const requestDeps = deps(fetchImpl, async () => adminUser(), async () => {}, env, freshTokenCache());

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "bridge" }),
  });

  const res = await handleRequest(req, requestDeps);
  const body = await res.json();

  assertEquals(res.status, 500);
  assert(
    String((body as Record<string, unknown>)["error"]).includes(
      "Missing ABDM_CALLBACK_BASE_URL",
    ),
    "missing callback secret must surface a clear error",
  );
  assertEquals(calls.length, 0, "gateway must never be called");
});

Deno.test("bridge rejects a non-HTTPS ABDM_CALLBACK_BASE_URL", async () => {
  const { fetchImpl, calls } = recordingFetch(() => {
    throw new Error("ABDM gateway must not be called for an invalid callback URL");
  });

  const env = {
    ABDM_CLIENT_ID: "client-id",
    ABDM_CLIENT_SECRET: "client-secret",
    ABDM_CALLBACK_BASE_URL: "http://cb.example/abdm",
  };
  const requestDeps = deps(fetchImpl, async () => adminUser(), async () => {}, env, freshTokenCache());

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "bridge" }),
  });

  const res = await handleRequest(req, requestDeps);
  const body = await res.json();

  assertEquals(res.status, 400);
  assert(
    String((body as Record<string, unknown>)["error"]).includes("HTTPS"),
    "non-HTTPS callback URL must be rejected",
  );
  assertEquals(calls.length, 0, "gateway must never be called");
});

Deno.test("bridge rejects a localhost ABDM_CALLBACK_BASE_URL", async () => {
  const { fetchImpl, calls } = recordingFetch(() => {
    throw new Error("ABDM gateway must not be called for a local callback URL");
  });

  const env = {
    ABDM_CLIENT_ID: "client-id",
    ABDM_CLIENT_SECRET: "client-secret",
    ABDM_CALLBACK_BASE_URL: "https://localhost/abdm",
  };
  const requestDeps = deps(fetchImpl, async () => adminUser(), async () => {}, env, freshTokenCache());

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "bridge" }),
  });

  const res = await handleRequest(req, requestDeps);
  const body = await res.json();

  assertEquals(res.status, 400);
  assert(
    String((body as Record<string, unknown>)["error"]).includes("localhost"),
    "localhost callback URL must be rejected",
  );
  assertEquals(calls.length, 0, "gateway must never be called");
});

Deno.test("bridge rejects a private-IP ABDM_CALLBACK_BASE_URL", async () => {
  const { fetchImpl, calls } = recordingFetch(() => {
    throw new Error("ABDM gateway must not be called for a private-IP callback URL");
  });

  const env = {
    ABDM_CLIENT_ID: "client-id",
    ABDM_CLIENT_SECRET: "client-secret",
    ABDM_CALLBACK_BASE_URL: "https://10.0.0.5/abdm",
  };
  const requestDeps = deps(fetchImpl, async () => adminUser(), async () => {}, env, freshTokenCache());

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "bridge" }),
  });

  const res = await handleRequest(req, requestDeps);
  const body = await res.json();

  assertEquals(res.status, 400);
  assert(
    String((body as Record<string, unknown>)["error"]).includes("private/local IP"),
    "private-IP callback URL must be rejected",
  );
  assertEquals(calls.length, 0, "gateway must never be called");
});

Deno.test("bridge success response never returns the raw ABDM token or client secret", async () => {
  const { fetchImpl } = recordingFetch((url) => {
    if (url.endsWith("/gateway/v1/sessions")) {
      return gatewayResponse({ accessToken: "super-secret-abdm-token", expiresIn: 3600 });
    }
    if (url.endsWith("/gateway/v1/bridges")) {
      return gatewayResponse({ ok: true });
    }
    throw new Error(`unexpected gateway call: ${url}`);
  });

  const requestDeps = deps(fetchImpl, async () => adminUser(), async () => {}, envWithSecrets, freshTokenCache());

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "bridge" }),
  });

  const res = await handleRequest(req, requestDeps);
  const text = await res.text();

  assertEquals(res.status, 200);
  assert(!text.includes("super-secret-abdm-token"), "raw ABDM token must never be returned");
  assert(!text.includes("client-secret"), "client secret must never be returned");
  assert(!text.includes("accessToken"), "accessToken key must never be returned");
});

// ----------------------------------------------------------------------------
// 5. Bridge failure diagnostics (timeout / network / upstream HTTP statuses)
// ----------------------------------------------------------------------------

type BridgeHandler = (url: string, method: string, headers: Headers, body: unknown) => Response;

async function runBridgeRequest(
  bridgeHandler: BridgeHandler,
  env: Record<string, string | undefined> = envWithSecrets,
): Promise<{ res: Response; body: Record<string, unknown>; logs: string[]; errors: string[] }> {
  const { fetchImpl } = recordingFetch((url, method, headers, body) => {
    if (url.endsWith("/gateway/v1/sessions")) {
      return gatewayResponse({ accessToken: "abdm-token", expiresIn: 3600 });
    }
    return bridgeHandler(url, method, headers, body);
  });

  const logs: string[] = [];
  const errors: string[] = [];
  const originalLog = console.log;
  const originalError = console.error;
  console.log = (...args: unknown[]) => {
    logs.push(args.map(String).join(" "));
  };
  console.error = (...args: unknown[]) => {
    errors.push(args.map(String).join(" "));
  };

  try {
    const requestDeps = deps(
      fetchImpl,
      async () => adminUser(),
      async () => {},
      env,
      freshTokenCache(),
    );
    const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
      method: "PATCH",
      headers: { "Content-Type": "application/json", "x-request-id": "corr-123" },
      body: JSON.stringify({ action: "bridge" }),
    });
    const res = await handleRequest(req, requestDeps);
    const body = await res.json() as Record<string, unknown>;
    return { res, body, logs, errors };
  } finally {
    console.log = originalLog;
    console.error = originalError;
  }
}

function assertBridgeDiagnostic(
  body: Record<string, unknown>,
  code: string,
  upstreamStatus: number | null,
): void {
  assertEquals(body["code"], code);
  assertEquals(body["upstreamStatus"] ?? null, upstreamStatus);
  assert(typeof body["error"] === "string" && (body["error"] as string).length > 0, "error must be a non-empty sanitized string");
}

Deno.test("bridge maps an actual fetch network exception to ABDM_BRIDGE_NETWORK", async () => {
  const { res, body, logs, errors } = await runBridgeRequest(() => {
    throw new TypeError("fetch failed");
  });

  assertEquals(res.status, 502);
  assertBridgeDiagnostic(body, "ABDM_BRIDGE_NETWORK", null);
  assert(
    String(body["error"]).includes("unreachable"),
    "network failure must be described as unreachable",
  );
  assert(JSON.stringify(body).includes("fetch failed") === false, "raw network error must not be returned");

  const allLogs = [...logs, ...errors].join(" ");
  assert(allLogs.includes("bridge_update"), "structured bridge log must be emitted");
  assert(allLogs.includes("category") && allLogs.includes("network"), "network category must be logged");
  assert(allLogs.includes("abdm-token") === false, "ABDM token must not be logged");
  assert(allLogs.includes("client-secret") === false, "client secret must not be logged");
});

Deno.test("bridge maps a fetch timeout to ABDM_BRIDGE_TIMEOUT", async () => {
  const { res, body, logs } = await runBridgeRequest(() => {
    throw new DOMException("The operation timed out.", "TimeoutError");
  });

  assertEquals(res.status, 502);
  assertBridgeDiagnostic(body, "ABDM_BRIDGE_TIMEOUT", null);
  assert(String(body["error"]).includes("timed out"), "timeout message must mention timed out");

  const allLogs = logs.join(" ");
  assert(allLogs.includes("category") && allLogs.includes("timeout"), "timeout category must be logged");
  assert(allLogs.includes("abdm-token") === false, "ABDM token must not be logged");
});

for (const status of [400, 401, 403, 404, 405, 500]) {
  Deno.test(`bridge maps upstream ${status} to ABDM_BRIDGE_${status} (never a network timeout)`, async () => {
    const { res, body, logs, errors } = await runBridgeRequest(() => {
      return gatewayResponse(
        {
          error: {
            code: `UPSTREAM_${status}`,
            message: `upstream rejected ${status}`,
          },
        },
        status,
      );
    });

    assertEquals(res.status, 502);
    assertBridgeDiagnostic(body, `ABDM_BRIDGE_${status}`, status);
    const text = JSON.stringify(body);
    assert(text.includes("network") === false && text.includes("timeout") === false,
      "HTTP upstream errors must never be described as network/timeout");
    assert(String(body["error"]).includes(`HTTP ${status}`), "error must mention upstream status");

    const allLogs = [...logs, ...errors].join(" ");
    assert(allLogs.includes(`"upstreamStatus":${status}`), "upstream status must be logged");
    assert(allLogs.includes("abdm-token") === false, "ABDM token must not be logged");
    assert(allLogs.includes("client-secret") === false, "client secret must not be logged");
  });
}

Deno.test("bridge failure diagnostics never leak tokens or secrets in logs or responses", async () => {
  const { body, logs, errors } = await runBridgeRequest(() => {
    return gatewayResponse({
      error: {
        code: "BAD",
        message: "bad secret client-secret and token abdm-token",
      },
      accessToken: "abdm-token",
      clientSecret: "client-secret",
    }, 400);
  });

  const responseText = JSON.stringify(body);
  assert(responseText.includes("abdm-token") === false, "token must not be returned");
  assert(responseText.includes("client-secret") === false, "secret must not be returned");

  const allLogs = [...logs, ...errors].join(" ");
  assert(allLogs.includes("abdm-token") === false, "token must not be logged");
  assert(allLogs.includes("client-secret") === false, "secret must not be logged");
});

// ----------------------------------------------------------------------------
// 6. CORS preflight (browser flow for the PATCH Bridge action)
// ----------------------------------------------------------------------------

Deno.test("OPTIONS preflight returns 204 without auth and advertises lowercase patch", async () => {
  let authCalled = false;

  const requestDeps = deps(
    recordingFetch(() => {
      throw new Error("preflight must not call the ABDM gateway");
    }).fetchImpl,
    async () => {
      authCalled = true;
      throw new Error("preflight must not require Supabase auth");
    },
    async () => {},
  );

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "OPTIONS",
    headers: {
      // The Supabase Flutter/Web Functions client sends the method token in
      // lowercase; the Edge Function must advertise that exact token.
      "Access-Control-Request-Method": "patch",
      "Access-Control-Request-Headers": "authorization, content-type",
    },
  });

  const res = await handleRequest(req, requestDeps);

  assertEquals(res.status, 204);
  assert(!authCalled, "OPTIONS must never trigger Supabase auth");

  assertEquals(res.headers.get("Access-Control-Allow-Origin"), "*");
  const allowMethods = res.headers.get("Access-Control-Allow-Methods") ?? "";
  assert(allowMethods.includes("patch"), "lowercase patch must be advertised");
  assert(allowMethods.includes("PATCH"), "uppercase PATCH must be advertised");
  assert(allowMethods.includes("GET"), "GET must be advertised");
  assert(allowMethods.includes("POST"), "POST must be advertised");
  assert(allowMethods.includes("OPTIONS"), "OPTIONS must be advertised");

  const allowHeaders = res.headers.get("Access-Control-Allow-Headers") ?? "";
  assert(allowHeaders.includes("authorization"), "authorization must be allowed");
  assert(allowHeaders.includes("content-type"), "content-type must be allowed");
});

Deno.test("preflight with lowercase patch then an authenticated lowercase patch request reaches handleBridge", async () => {
  let authCalled = false;
  const { fetchImpl, calls } = recordingFetch((url, method) => {
    if (url.endsWith("/gateway/v1/sessions")) {
      return gatewayResponse({ accessToken: "abdm-token", expiresIn: 3600 });
    }
    if (url.endsWith("/gateway/v1/bridges") && method === "PATCH") {
      return gatewayResponse({ ok: true });
    }
    throw new Error(`unexpected gateway call: ${method} ${url}`);
  });

  const requestDeps = deps(
    fetchImpl,
    async () => {
      authCalled = true;
      return adminUser();
    },
    async () => {},
    envWithSecrets,
    freshTokenCache(),
  );

  // 1. Browser preflight with the exact lowercase token sent by the Supabase
  //    Flutter/Web Functions client.
  const preflight = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "OPTIONS",
    headers: { "Access-Control-Request-Method": "patch" },
  });
  const preflightRes = await handleRequest(preflight, requestDeps);
  assertEquals(preflightRes.status, 204);
  const preflightMethods =
    preflightRes.headers.get("Access-Control-Allow-Methods") ?? "";
  assert(
    preflightMethods.includes("patch"),
    "preflight must advertise the exact lowercase patch token",
  );
  assert(
    preflightMethods.includes("PATCH"),
    "preflight must still advertise uppercase PATCH",
  );

  // 2. The real inbound request may also arrive with a lowercase method.
  const patchReq = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "patch",
    headers: {
      "Content-Type": "application/json",
      Authorization: "Bearer owner-jwt",
    },
    body: JSON.stringify({ action: "bridge" }),
  });
  const res = await handleRequest(patchReq, requestDeps);
  const body = await res.json() as Record<string, unknown>;

  assertEquals(res.status, 200, "lowercase patch must not be rejected with 405");
  assertEquals(body["status"], "bridge_configured");
  assert(authCalled, "lowercase patch must still validate the Supabase JWT through authenticate");
  const bridgeCall = calls.find((c) => c.url.endsWith("/gateway/v1/bridges"));
  assert(bridgeCall, "lowercase patch must reach the ABDM bridge endpoint");
  assertEquals(
    bridgeCall.method,
    "PATCH",
    "outbound ABDM request must remain uppercase PATCH",
  );
});

Deno.test("PATCH bridge remains 403 for a non-admin authenticated user", async () => {
  const { fetchImpl, calls } = recordingFetch(() => {
    throw new Error("non-admin PATCH must not call the ABDM gateway");
  });

  const requestDeps = deps(
    fetchImpl,
    async () => doctorUser(),
    async () => {},
    envWithSecrets,
    freshTokenCache(),
  );

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "bridge" }),
  });

  const res = await handleRequest(req, requestDeps);
  const body = await res.json() as Record<string, unknown>;

  assertEquals(res.status, 403);
  assertEquals(body["error"], "Owner / super-admin role required for this action");
  assertEquals(calls.length, 0, "ABDM gateway must never be called for non-admin");
});

// ----------------------------------------------------------------------------
// 7. Production Flutter flow: inbound POST {"action":"bridge"} -> outbound PATCH
// ----------------------------------------------------------------------------

Deno.test("POST action=bridge reaches handleBridge and performs an uppercase PATCH outbound", async () => {
  let authCalled = false;
  const { fetchImpl, calls } = recordingFetch((url, method) => {
    if (url.endsWith("/gateway/v1/sessions")) {
      return gatewayResponse({ accessToken: "abdm-token", expiresIn: 3600 });
    }
    if (url.endsWith("/gateway/v1/bridges") && method === "PATCH") {
      return gatewayResponse({ ok: true });
    }
    throw new Error(`unexpected gateway call: ${method} ${url}`);
  });

  const requestDeps = deps(
    fetchImpl,
    async () => {
      authCalled = true;
      return adminUser();
    },
    async () => {},
    envWithSecrets,
    freshTokenCache(),
  );

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: "Bearer owner-jwt",
    },
    body: JSON.stringify({ action: "bridge" }),
  });

  const res = await handleRequest(req, requestDeps);
  const body = await res.json() as Record<string, unknown>;

  assertEquals(res.status, 200, "POST action=bridge must not be rejected");
  assertEquals(body["status"], "bridge_configured");
  assert(authCalled, "POST action=bridge must still validate the Supabase JWT");

  const bridgeCall = calls.find((c) => c.url.endsWith("/gateway/v1/bridges"));
  assert(bridgeCall, "POST action=bridge must reach the ABDM bridge endpoint");
  assertEquals(bridgeCall.method, "PATCH", "outbound ABDM request must be uppercase PATCH");
  assertEquals(
    bridgeCall.body,
    { url: "https://cb.example/abdm" },
    "outbound body must contain only the server-side callback URL",
  );
});

Deno.test("POST action=bridge without JWT returns 401", async () => {
  const { fetchImpl, calls } = recordingFetch(() => {
    throw new Error("ABDM gateway must not be called without a JWT");
  });

  const requestDeps = deps(
    fetchImpl,
    async () => {
      throw new HttpError(401, "Invalid or expired user session");
    },
    async () => {},
    envWithSecrets,
    freshTokenCache(),
  );

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "bridge" }),
  });

  const res = await handleRequest(req, requestDeps);

  assertEquals(res.status, 401);
  assertEquals(calls.length, 0, "ABDM gateway must never be called without a JWT");
});

Deno.test("POST action=bridge as non-admin returns 403", async () => {
  const { fetchImpl, calls } = recordingFetch(() => {
    throw new Error("ABDM gateway must not be called for non-admin");
  });

  const requestDeps = deps(
    fetchImpl,
    async () => doctorUser(),
    async () => {},
    envWithSecrets,
    freshTokenCache(),
  );

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "bridge" }),
  });

  const res = await handleRequest(req, requestDeps);
  const body = await res.json() as Record<string, unknown>;

  assertEquals(res.status, 403);
  assertEquals(body["error"], "Owner / super-admin role required for this action");
  assertEquals(calls.length, 0, "ABDM gateway must never be called for non-admin");
});

// ----------------------------------------------------------------------------
// 8. getServices inspect flow (POST action=getServices -> outbound GET)
// ----------------------------------------------------------------------------

async function runGetServicesRequest(
  getServicesHandler: BridgeHandler,
  authenticate: RequestDeps["authenticate"] = async () => adminUser(),
  env: Record<string, string | undefined> = envWithSecrets,
): Promise<{ res: Response; body: Record<string, unknown>; logs: string[]; errors: string[] }> {
  const { fetchImpl } = recordingFetch((url, method, headers, body) => {
    if (url.endsWith("/gateway/v1/sessions")) {
      return gatewayResponse({ accessToken: "abdm-token", expiresIn: 3600 });
    }
    return getServicesHandler(url, method, headers, body);
  });

  const logs: string[] = [];
  const errors: string[] = [];
  const originalLog = console.log;
  const originalError = console.error;
  console.log = (...args: unknown[]) => {
    logs.push(args.map(String).join(" "));
  };
  console.error = (...args: unknown[]) => {
    errors.push(args.map(String).join(" "));
  };

  try {
    const requestDeps = deps(fetchImpl, authenticate, async () => {}, env, freshTokenCache());
    const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "x-request-id": "corr-456",
        Authorization: "Bearer owner-jwt",
      },
      body: JSON.stringify({ action: "getServices" }),
    });
    const res = await handleRequest(req, requestDeps);
    const body = await res.json() as Record<string, unknown>;
    return { res, body, logs, errors };
  } finally {
    console.log = originalLog;
    console.error = originalError;
  }
}

Deno.test("POST action=getServices reaches the GET /gateway/v1/bridges/getServices contract", async () => {
  let authCalled = false;
  const services = [
    {
      id: "hip-1",
      name: "Demo HIP",
      type: "HIP",
      active: true,
      alias: ["Demo"],
      endpoints: [
        {
          address: "https://cb.example/abdm/patients/status/notify",
          connectionType: "https",
          use: "PATIENT_STATUS_NOTIFY",
        },
      ],
      accessToken: "must-be-dropped",
    },
    {
      id: "hiu-1",
      name: "Demo HIU",
      type: "HIU",
      active: false,
      alias: [],
      endpoints: [],
    },
  ];

  const { fetchImpl, calls } = recordingFetch((url, method) => {
    if (url.endsWith("/gateway/v1/sessions")) {
      return gatewayResponse({ accessToken: "abdm-token", expiresIn: 3600 });
    }
    if (url.endsWith("/gateway/v1/bridges/getServices") && method === "GET") {
      return gatewayResponse(services);
    }
    throw new Error(`unexpected gateway call: ${method} ${url}`);
  });

  const requestDeps = deps(
    fetchImpl,
    async () => {
      authCalled = true;
      return adminUser();
    },
    async () => {},
    envWithSecrets,
    freshTokenCache(),
  );

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "getServices" }),
  });

  const res = await handleRequest(req, requestDeps);
  const body = await res.json() as Record<string, unknown>;

  assertEquals(res.status, 200);
  assertEquals(body["status"], "services_fetched");
  assertEquals(body["upstreamStatus"], 200);
  assertEquals(body["serviceCount"], 2);
  assert(authCalled, "getServices must validate the Supabase JWT");

  const serviceList = body["services"] as Record<string, unknown>[];
  assertEquals(serviceList.length, 2);
  assertEquals(serviceList[0]["id"], "hip-1");
  assertEquals(serviceList[0]["name"], "Demo HIP");
  assertEquals(serviceList[0]["type"], "HIP");
  assertEquals(serviceList[0]["active"], true);
  assertEquals(serviceList[0]["alias"], ["Demo"]);
  assertEquals(
    (serviceList[0]["endpoints"] as Record<string, unknown>[])[0]["address"],
    "https://cb.example/abdm/patients/status/notify",
  );
  assert(JSON.stringify(body).includes("accessToken") === false, "sensitive keys must be dropped");
  assert(JSON.stringify(body).includes("must-be-dropped") === false, "sensitive values must be dropped");

  const getCall = calls.find((c) => c.url.endsWith("/gateway/v1/bridges/getServices"));
  assert(getCall, "getServices endpoint must be called");
  assertEquals(getCall.method, "GET", "outbound ABDM request must be uppercase GET");
  assertEquals(getCall.headers.get("Authorization"), "Bearer abdm-token");
});

Deno.test("POST action=getServices without JWT returns 401", async () => {
  const { fetchImpl, calls } = recordingFetch(() => {
    throw new Error("ABDM gateway must not be called without a JWT");
  });

  const requestDeps = deps(
    fetchImpl,
    async () => {
      throw new HttpError(401, "Invalid or expired user session");
    },
    async () => {},
    envWithSecrets,
    freshTokenCache(),
  );

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "getServices" }),
  });

  const res = await handleRequest(req, requestDeps);

  assertEquals(res.status, 401);
  assertEquals(calls.length, 0, "ABDM gateway must never be called without a JWT");
});

Deno.test("POST action=getServices as non-admin returns 403", async () => {
  const { fetchImpl, calls } = recordingFetch(() => {
    throw new Error("ABDM gateway must not be called for non-admin");
  });

  const requestDeps = deps(
    fetchImpl,
    async () => doctorUser(),
    async () => {},
    envWithSecrets,
    freshTokenCache(),
  );

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "getServices" }),
  });

  const res = await handleRequest(req, requestDeps);
  const body = await res.json() as Record<string, unknown>;

  assertEquals(res.status, 403);
  assertEquals(body["error"], "Owner / super-admin role required for this action");
  assertEquals(calls.length, 0, "ABDM gateway must never be called for non-admin");
});

for (const status of [400, 401, 403, 404, 405, 500]) {
  Deno.test(`getServices maps upstream ${status} to ABDM_GET_SERVICES_${status}`, async () => {
    const { res, body, logs, errors } = await runGetServicesRequest(() => {
      return gatewayResponse(
        { error: { code: `UPSTREAM_${status}`, message: `upstream rejected ${status}` } },
        status,
      );
    });

    assertEquals(res.status, 502);
    assertEquals(body["code"], `ABDM_GET_SERVICES_${status}`);
    assertEquals(body["upstreamStatus"], status);
    const text = JSON.stringify(body);
    assert(text.includes("network") === false && text.includes("timeout") === false,
      "HTTP upstream errors must never be described as network/timeout");

    const allLogs = [...logs, ...errors].join(" ");
    assert(allLogs.includes("get_services"), "structured getServices log must be emitted");
    assert(allLogs.includes("abdm-token") === false, "ABDM token must not be logged");
    assert(allLogs.includes("client-secret") === false, "client secret must not be logged");
  });
}

Deno.test("getServices network exception maps to ABDM_GET_SERVICES_NETWORK", async () => {
  const { res, body, logs } = await runGetServicesRequest(() => {
    throw new TypeError("fetch failed");
  });

  assertEquals(res.status, 502);
  assertEquals(body["code"], "ABDM_GET_SERVICES_NETWORK");
  assertEquals(body["upstreamStatus"] ?? null, null);
  assert(String(body["error"]).includes("unreachable"), "network failure must be described as unreachable");
  assert(logs.join(" ").includes("network"), "network category must be logged");
});

Deno.test("getServices timeout maps to ABDM_GET_SERVICES_TIMEOUT", async () => {
  const { res, body, logs } = await runGetServicesRequest(() => {
    throw new DOMException("The operation timed out.", "TimeoutError");
  });

  assertEquals(res.status, 502);
  assertEquals(body["code"], "ABDM_GET_SERVICES_TIMEOUT");
  assertEquals(body["upstreamStatus"] ?? null, null);
  assert(String(body["error"]).includes("timed out"), "timeout message must mention timed out");
  assert(logs.join(" ").includes("timeout"), "timeout category must be logged");
});

Deno.test("getServices diagnostics never leak tokens or secrets in logs or responses", async () => {
  const { body, logs, errors } = await runGetServicesRequest(() => {
    return gatewayResponse({
      error: {
        code: "FORBIDDEN",
        message: "Resource forbidden with client-secret and token abdm-token",
      },
      accessToken: "abdm-token",
      clientSecret: "client-secret",
    }, 403);
  });

  const responseText = JSON.stringify(body);
  assert(responseText.includes("abdm-token") === false, "token must not be returned");
  assert(responseText.includes("client-secret") === false, "secret must not be returned");

  const allLogs = [...logs, ...errors].join(" ");
  assert(allLogs.includes("abdm-token") === false, "token must not be logged");
  assert(allLogs.includes("client-secret") === false, "secret must not be logged");
});
