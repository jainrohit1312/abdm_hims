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

Deno.test("bridge update uses PATCH /gateway/v1/bridges with exact url body", async () => {
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
    body: JSON.stringify({ action: "bridge", callbackUrl: "https://cb.example/abdm" }),
  });

  const res = await handleRequest(req, requestDeps);
  assertEquals(res.status, 200);

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
    body: JSON.stringify({ action: "bridge", callbackUrl: "https://cb.example" }),
  });

  const res = await handleRequest(req, requestDeps);
  const body = await res.json();

  assertEquals(res.status, 200);
  const gateway = (body as Record<string, unknown>)["gateway"] as Record<string, unknown>;
  assertEquals(gateway["accessToken"], "[REDACTED]");
  assertEquals(JSON.stringify(body).includes("echoed-token"), false);
});
