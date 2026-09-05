// ============================================================================
// Deno tests for the HFR facility/HIP linkage (production POST `services`).
//
// Run locally with:
//   cd supabase/functions/abdm-gateway && deno test --allow-read --allow-net .
//
// These tests never call live Supabase or live ABDM/HFR services. Supabase
// auth is injected as a fake and every upstream service is a mocked fetch.
// ============================================================================

import {
  type AuthenticatedUser,
  type HospitalAbdmSettings,
  handleRequest,
  type RequestDeps,
} from "./handler.ts";
import type { TokenCacheRef, V3TokenCacheRef } from "./core.ts";

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

const envWithBridge = {
  ABDM_CLIENT_ID: "sbx-client-id",
  ABDM_CLIENT_SECRET: "sbx-client-secret",
  ABDM_BRIDGE_ID: "bridge-1",
};

const settings: HospitalAbdmSettings = {
  facilityId: "IN2810014366",
  facilityName: "MediFlux Hospital",
  hipName: "Goverdhan",
};

function jsonResponse(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function sessionOkResponse(accessToken: string): Response {
  return jsonResponse({ accessToken, expiresIn: 3600 });
}

function hfrOkResponse(): Response {
  return jsonResponse({ status: "accepted" });
}

function serviceByIdOkResponse(): Response {
  return jsonResponse({
    serviceId: "IN2810014366",
    bridgeId: "bridge-1",
    name: "MediFlux",
    isHip: true,
    isHiu: false,
    active: true,
  });
}

function bridgeServicesOkResponse(
  liveBridgeId = "bridge-1",
): Response {
  return jsonResponse({
    bridge: { id: liveBridgeId, url: "https://cb.example/abdm" },
    services: [
      {
        id: "IN2810014366",
        name: "MediFlux",
        types: ["HIP"],
        active: true,
      },
    ],
  });
}

function requestDeps(
  fetchImpl: typeof fetch,
  legacyCache: TokenCacheRef,
  v3Cache: V3TokenCacheRef,
  store: RequestDeps["hospitalAbdmSettingsStore"] = {
    async getByHospitalId() {
      return settings;
    },
  },
): RequestDeps {
  return {
    env: envWithBridge,
    fetchImpl,
    authenticate: async () => adminUser(),
    persistCallbackRow: async () => {},
    tokenCache: legacyCache,
    v3TokenCache: v3Cache,
    hospitalAbdmSettingsStore: store,
  };
}

function servicesRequest(body: Record<string, unknown> = {
  action: "services",
}): Request {
  return new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function runHfr(
  gatewayHandler: (
    url: string,
    method: string,
    headers: Headers,
    body: unknown,
  ) => Response,
  legacyCache?: TokenCacheRef,
  v3Cache?: V3TokenCacheRef,
  body?: Record<string, unknown>,
): Promise<{ res: Response; calls: CapturedCall[]; legacy: TokenCacheRef; v3: V3TokenCacheRef }> {
  const { fetchImpl, calls } = recordingFetch(gatewayHandler);
  const legacy = legacyCache ?? { current: null };
  const v3 = v3Cache ?? { current: null };
  const res = await handleRequest(
    servicesRequest(body),
    requestDeps(fetchImpl, legacy, v3),
  );
  return { res, calls, legacy, v3 };
}

// ----------------------------------------------------------------------------
// 1. Facility id validation (IN + 10 digits)
// ----------------------------------------------------------------------------

Deno.test("hfr: invalid facility id causes zero HFR network calls", async () => {
  const { fetchImpl, calls } = recordingFetch(() => {
    throw new Error("no upstream call expected for invalid facility id");
  });

  const res = await handleRequest(
    servicesRequest(),
    requestDeps(fetchImpl, { current: null }, { current: null }, {
      async getByHospitalId() {
        return { facilityId: "HFR-123", facilityName: "MediFlux", hipName: "Goverdhan" };
      },
    }),
  );

  assertEquals(res.status, 400);
  assertEquals(calls.length, 0);
});

// ----------------------------------------------------------------------------
// 2. HIP name validation (letters/digits/spaces only, max 15)
// ----------------------------------------------------------------------------

Deno.test("hfr: invalid HIP name causes zero HFR network calls", async () => {
  const { fetchImpl, calls } = recordingFetch(() => {
    throw new Error("no upstream call expected for invalid HIP name");
  });

  const res = await handleRequest(
    servicesRequest(),
    requestDeps(fetchImpl, { current: null }, { current: null }, {
      async getByHospitalId() {
        return {
          facilityId: "IN2810014366",
          facilityName: "MediFlux",
          hipName: "Goverdhan-Hosp",
        };
      },
    }),
  );

  assertEquals(res.status, 400);
  assertEquals(calls.length, 0);
});

// ----------------------------------------------------------------------------
// 3. Exact HFR endpoint, exact payload, canonical V3 token
// ----------------------------------------------------------------------------

Deno.test("hfr: linkage calls exactly POST https://apihspsbx.abdm.gov.in/v4/int/v1/bridges/MutipleHRPAddUpdateServices", async () => {
  const { res, calls } = await runHfr((url) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return bridgeServicesOkResponse();
    }
    if (url.endsWith("/v1/bridges/MutipleHRPAddUpdateServices")) {
      return hfrOkResponse();
    }
    if (url.includes("/bridge-service/serviceId/IN2810014366")) {
      return serviceByIdOkResponse();
    }
    throw new Error(`unexpected call: ${url}`);
  });

  assertEquals(res.status, 200);
  const hfrCalls = calls.filter((c) => c.url.includes("apihspsbx"));
  assertEquals(hfrCalls.length, 1);
  assertEquals(hfrCalls[0].method, "POST");
  assertEquals(
    hfrCalls[0].url,
    "https://apihspsbx.abdm.gov.in/v4/int/v1/bridges/MutipleHRPAddUpdateServices",
  );
});

Deno.test("hfr: payload contains exactly facilityId, facilityName and HRP[] fields", async () => {
  const { calls } = await runHfr((url) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return bridgeServicesOkResponse();
    }
    if (url.endsWith("/v1/bridges/MutipleHRPAddUpdateServices")) {
      return hfrOkResponse();
    }
    if (url.includes("/bridge-service/serviceId/IN2810014366")) {
      return serviceByIdOkResponse();
    }
    throw new Error(`unexpected call: ${url}`);
  });

  const hfrCall = calls.find((c) => c.url.includes("apihspsbx"));
  assert(hfrCall, "HFR call must exist");
  assertEquals(hfrCall.body, {
    facilityId: "IN2810014366",
    facilityName: "MediFlux Hospital",
    HRP: [
      {
        bridgeId: "bridge-1",
        hipName: "Goverdhan",
        type: "HIP",
        active: true,
      },
    ],
  });
  const body = hfrCall.body as Record<string, unknown>;
  const hrp = body["HRP"] as Record<string, unknown>[];
  assertEquals(hrp.length, 1);
  assertEquals(hrp[0]["type"], "HIP");
  assertEquals(hrp[0]["active"], true);
});

Deno.test("hfr: Bearer token is sourced from the canonical V3 token cache and legacy cache stays untouched", async () => {
  const legacy: TokenCacheRef = {
    current: { accessToken: "legacy-cached-token", expiresAt: Date.now() + 60_000 },
  };
  const { calls, legacy: legacyCache, v3 } = await runHfr(
    (url) => {
      if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
        return sessionOkResponse("fresh-v3-token");
      }
      if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
        return bridgeServicesOkResponse();
      }
      if (url.endsWith("/v1/bridges/MutipleHRPAddUpdateServices")) {
        return hfrOkResponse();
      }
      if (url.includes("/bridge-service/serviceId/IN2810014366")) {
        return serviceByIdOkResponse();
      }
      throw new Error(`unexpected call: ${url}`);
    },
    legacy,
    { current: null },
  );

  const hfrCall = calls.find((c) => c.url.includes("apihspsbx"));
  assert(hfrCall, "HFR call must exist");
  assertEquals(hfrCall.headers.get("Authorization"), "Bearer fresh-v3-token");
  assertEquals(hfrCall.headers.get("Content-Type"), "application/json");
  assert(hfrCall.headers.get("REQUEST-ID"), "fresh REQUEST-ID required");
  assert(hfrCall.headers.get("TIMESTAMP"), "fresh TIMESTAMP required");

  // The deprecated v0.5/v1 cache must be completely untouched.
  assertEquals(legacyCache.current?.accessToken, "legacy-cached-token");
  assertEquals(v3.current?.accessToken, "fresh-v3-token");
});

// ----------------------------------------------------------------------------
// 4. Bridge id verification against live V3 bridge-services envelope
// ----------------------------------------------------------------------------

Deno.test("hfr: configured bridge id matching live bridge.id lets linkage proceed", async () => {
  const { calls } = await runHfr((url) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return bridgeServicesOkResponse("bridge-1");
    }
    if (url.endsWith("/v1/bridges/MutipleHRPAddUpdateServices")) {
      return hfrOkResponse();
    }
    if (url.includes("/bridge-service/serviceId/IN2810014366")) {
      return serviceByIdOkResponse();
    }
    throw new Error(`unexpected call: ${url}`);
  });

  const hfrCalls = calls.filter((c) => c.url.includes("apihspsbx"));
  assertEquals(hfrCalls.length, 1, "matching bridge id must allow the HFR POST");
});

Deno.test("hfr: bridge id mismatch returns ABDM_BRIDGE_ID_MISMATCH and performs no HFR POST", async () => {
  const { res, calls } = await runHfr((url) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return bridgeServicesOkResponse("live-bridge-different");
    }
    throw new Error(`unexpected call: ${url}`);
  });

  const body = await res.json() as Record<string, unknown>;
  assertEquals(res.status, 502);
  assertEquals(body["code"], "ABDM_BRIDGE_ID_MISMATCH");
  assert(body["supportReference"], "supportReference required");
  assertEquals(calls.filter((c) => c.url.includes("apihspsbx")).length, 0);
  assert(
    !calls.some((c) => c.url.includes("/gateway/v1/")),
    "legacy gateway must never be called",
  );
});

Deno.test("hfr: missing bridge.id returns ABDM_BRIDGE_ID_UNAVAILABLE and performs no HFR POST", async () => {
  const { res, calls } = await runHfr((url) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return jsonResponse({ services: [] });
    }
    throw new Error(`unexpected call: ${url}`);
  });

  const body = await res.json() as Record<string, unknown>;
  assertEquals(res.status, 502);
  assertEquals(body["code"], "ABDM_BRIDGE_ID_UNAVAILABLE");
  assertEquals(calls.filter((c) => c.url.includes("apihspsbx")).length, 0);
});

Deno.test("hfr: bridge id mismatch never exposes token or secret", async () => {
  const { res } = await runHfr((url) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return bridgeServicesOkResponse("live-bridge-different");
    }
    throw new Error(`unexpected call: ${url}`);
  });

  const text = await res.text();
  assert(!text.includes("fresh-v3-token"), "V3 token leaked");
  assert(!text.includes("sbx-client-secret"), "client secret leaked");
});

// ----------------------------------------------------------------------------
// 5. 401/403 -> HFR_AUTH_REJECTED, never a legacy fallback
// ----------------------------------------------------------------------------

Deno.test("hfr: 401/403 does not retry or fall back to legacy addUpdateServices", async () => {
  const { res, calls } = await runHfr((url, method) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return bridgeServicesOkResponse();
    }
    if (url.endsWith("/v1/bridges/MutipleHRPAddUpdateServices")) {
      return jsonResponse({ error: "unauthorized" }, 403);
    }
    throw new Error(`unexpected call: ${method} ${url}`);
  });

  const body = await res.json() as Record<string, unknown>;
  assertEquals(res.status, 502);
  assertEquals(body["code"], "HFR_AUTH_REJECTED");
  assertEquals(body["upstreamStatus"], 403);
  assert(body["error"] as string, "sanitized error message required");

  assertEquals(calls.length, 3); // session + bridge verify + HFR only
  assert(
    !calls.some((c) => c.url.includes("/gateway/v1/")),
    "legacy v0.5/v1 gateway must never be called",
  );
});

// ----------------------------------------------------------------------------
// 6. Verification schema: by-id isHip and bridge-services types[] are independent
// ----------------------------------------------------------------------------

Deno.test("hfr: verified state requires by-id isHip AND bridge-services types[] HIP", async () => {
  const { res } = await runHfr((url) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return bridgeServicesOkResponse();
    }
    if (url.endsWith("/v1/bridges/MutipleHRPAddUpdateServices")) {
      return hfrOkResponse();
    }
    if (url.includes("/bridge-service/serviceId/IN2810014366")) {
      return serviceByIdOkResponse();
    }
    throw new Error(`unexpected call: ${url}`);
  });

  const body = await res.json() as Record<string, unknown>;
  assertEquals(res.status, 200);
  assertEquals(body["status"], "linkage_verified");
  const verification = body["verification"] as Record<string, unknown>;
  const byId = verification["byId"] as Record<string, unknown>;
  const bridgeServices = verification["bridgeServices"] as Record<string, unknown>;
  assertEquals(byId["serviceIdMatches"], true);
  assertEquals(byId["bridgeIdMatches"], true);
  assertEquals(byId["isHip"], true);
  assertEquals(byId["active"], true);
  assertEquals(bridgeServices["containsFacility"], true);
  assertEquals(bridgeServices["containsHipType"], true);
  assertEquals(bridgeServices["active"], true);
});

Deno.test("hfr: by-id isHip false makes verification pending even when types[] contains HIP", async () => {
  const { res } = await runHfr((url) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return bridgeServicesOkResponse();
    }
    if (url.endsWith("/v1/bridges/MutipleHRPAddUpdateServices")) {
      return hfrOkResponse();
    }
    if (url.includes("/bridge-service/serviceId/IN2810014366")) {
      return jsonResponse({
        serviceId: "IN2810014366",
        bridgeId: "bridge-1",
        name: "MediFlux",
        isHip: false,
        isHiu: true,
        active: true,
      });
    }
    throw new Error(`unexpected call: ${url}`);
  });

  const body = await res.json() as Record<string, unknown>;
  assertEquals(body["status"], "linkage_accepted_verification_pending");
  const verification = body["verification"] as Record<string, unknown>;
  const byId = verification["byId"] as Record<string, unknown>;
  const bridgeServices = verification["bridgeServices"] as Record<string, unknown>;
  assertEquals(byId["isHip"], false);
  assertEquals(bridgeServices["containsHipType"], true);
});

Deno.test("hfr: bridge-services types[] without HIP makes verification pending even when by-id isHip is true", async () => {
  const { res } = await runHfr((url) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return jsonResponse({
        bridge: { id: "bridge-1" },
        services: [
          { id: "IN2810014366", name: "MediFlux", types: ["HIU"], active: true },
        ],
      });
    }
    if (url.endsWith("/v1/bridges/MutipleHRPAddUpdateServices")) {
      return hfrOkResponse();
    }
    if (url.includes("/bridge-service/serviceId/IN2810014366")) {
      return serviceByIdOkResponse();
    }
    throw new Error(`unexpected call: ${url}`);
  });

  const body = await res.json() as Record<string, unknown>;
  assertEquals(body["status"], "linkage_accepted_verification_pending");
  const verification = body["verification"] as Record<string, unknown>;
  const byId = verification["byId"] as Record<string, unknown>;
  const bridgeServices = verification["bridgeServices"] as Record<string, unknown>;
  assertEquals(byId["isHip"], true);
  assertEquals(bridgeServices["containsHipType"], false);
});

Deno.test("hfr: accepted but not yet propagated returns linkage_accepted_verification_pending", async () => {
  const { res, calls } = await runHfr((url) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return jsonResponse({ bridge: { id: "bridge-1" }, services: [] });
    }
    if (url.endsWith("/v1/bridges/MutipleHRPAddUpdateServices")) {
      return hfrOkResponse();
    }
    if (url.includes("/bridge-service/serviceId/IN2810014366")) {
      return jsonResponse({ error: "not found" }, 404);
    }
    throw new Error(`unexpected call: ${url}`);
  });

  const body = await res.json() as Record<string, unknown>;
  assertEquals(res.status, 200);
  assertEquals(body["status"], "linkage_accepted_verification_pending");
  assertEquals(body["code"], "HFR_LINKAGE_PENDING");

  const byIdCalls = calls.filter((c) => c.url.includes("/bridge-service/serviceId/"));
  assertEquals(byIdCalls.length, 1, "still exactly one verification attempt");
});

// ----------------------------------------------------------------------------
// 7. No token / client secret exposure
// ----------------------------------------------------------------------------

Deno.test("hfr: no token or client secret is exposed in the response", async () => {
  const { res } = await runHfr((url) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return bridgeServicesOkResponse();
    }
    if (url.endsWith("/v1/bridges/MutipleHRPAddUpdateServices")) {
      return jsonResponse({
        accessToken: "upstream-must-be-redacted",
        clientSecret: "upstream-secret-must-be-redacted",
      });
    }
    if (url.includes("/bridge-service/serviceId/IN2810014366")) {
      return serviceByIdOkResponse();
    }
    throw new Error(`unexpected call: ${url}`);
  });

  const text = await res.text();
  assert(!text.includes("fresh-v3-token"), "V3 token leaked");
  assert(!text.includes("sbx-client-secret"), "client secret leaked");
  assert(!text.includes("upstream-must-be-redacted"), "upstream token leaked");
  assert(!text.includes("upstream-secret-must-be-redacted"), "upstream secret leaked");
});

// ----------------------------------------------------------------------------
// Client-supplied overrides / config validation
// ----------------------------------------------------------------------------

Deno.test("hfr: client-supplied facility fields are rejected before any ABDM/HFR call", async () => {
  const { fetchImpl, calls } = recordingFetch(() => {
    throw new Error("no upstream call expected");
  });
  const res = await handleRequest(
    servicesRequest({
      action: "services",
      facilityId: "ATTACKER",
      bridgeId: "ATTACKER",
      hipName: "ATTACKER",
    }),
    requestDeps(fetchImpl, { current: null }, { current: null }),
  );
  assertEquals(res.status, 400);
  assertEquals(calls.length, 0);
});

Deno.test("hfr: missing ABDM_BRIDGE_ID is rejected before any upstream call", async () => {
  const { fetchImpl, calls } = recordingFetch(() => {
    throw new Error("no upstream call expected");
  });
  const deps: RequestDeps = {
    env: {
      ABDM_CLIENT_ID: "sbx-client-id",
      ABDM_CLIENT_SECRET: "sbx-client-secret",
    },
    fetchImpl,
    authenticate: async () => adminUser(),
    persistCallbackRow: async () => {},
    tokenCache: { current: null },
    v3TokenCache: { current: null },
    hospitalAbdmSettingsStore: {
      async getByHospitalId() {
        return settings;
      },
    },
  };
  const res = await handleRequest(servicesRequest(), deps);
  assertEquals(res.status, 400);
  assertEquals(calls.length, 0);
});

// ----------------------------------------------------------------------------
// 8. linkage_verified requires bridgeIdMatches === true
// ----------------------------------------------------------------------------

Deno.test("hfr: by-id bridgeId mismatch makes verification pending even when all other checks pass", async () => {
  const { res } = await runHfr((url) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return bridgeServicesOkResponse("bridge-1"); // preflight passes
    }
    if (url.endsWith("/v1/bridges/MutipleHRPAddUpdateServices")) {
      return hfrOkResponse();
    }
    if (url.includes("/bridge-service/serviceId/IN2810014366")) {
      return jsonResponse({
        serviceId: "IN2810014366",
        bridgeId: "bridge-different",
        name: "MediFlux",
        isHip: true,
        isHiu: false,
        active: true,
      });
    }
    throw new Error(`unexpected call: ${url}`);
  });

  const body = await res.json() as Record<string, unknown>;
  assertEquals(res.status, 200);
  assertEquals(body["status"], "linkage_accepted_verification_pending");
  assertEquals(body["code"], "HFR_LINKAGE_PENDING");
  const verification = body["verification"] as Record<string, unknown>;
  const byId = verification["byId"] as Record<string, unknown>;
  assertEquals(byId["bridgeIdMatches"], false);
});

Deno.test("hfr: missing/null by-id bridgeId makes verification pending", async () => {
  const { res } = await runHfr((url) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return bridgeServicesOkResponse("bridge-1"); // preflight passes
    }
    if (url.endsWith("/v1/bridges/MutipleHRPAddUpdateServices")) {
      return hfrOkResponse();
    }
    if (url.includes("/bridge-service/serviceId/IN2810014366")) {
      return jsonResponse({
        serviceId: "IN2810014366",
        name: "MediFlux",
        isHip: true,
        isHiu: false,
        active: true,
      });
    }
    throw new Error(`unexpected call: ${url}`);
  });

  const body = await res.json() as Record<string, unknown>;
  assertEquals(res.status, 200);
  assertEquals(body["status"], "linkage_accepted_verification_pending");
  assertEquals(body["code"], "HFR_LINKAGE_PENDING");
  const verification = body["verification"] as Record<string, unknown>;
  const byId = verification["byId"] as Record<string, unknown>;
  assertEquals(byId["bridgeIdMatches"], null);
});

Deno.test("hfr: by-id bridgeId match is required and allows verified when all checks pass", async () => {
  const { res } = await runHfr((url) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return bridgeServicesOkResponse("bridge-1");
    }
    if (url.endsWith("/v1/bridges/MutipleHRPAddUpdateServices")) {
      return hfrOkResponse();
    }
    if (url.includes("/bridge-service/serviceId/IN2810014366")) {
      return serviceByIdOkResponse(); // bridgeId: "bridge-1"
    }
    throw new Error(`unexpected call: ${url}`);
  });

  const body = await res.json() as Record<string, unknown>;
  assertEquals(body["status"], "linkage_verified");
  const verification = body["verification"] as Record<string, unknown>;
  const byId = verification["byId"] as Record<string, unknown>;
  assertEquals(byId["bridgeIdMatches"], true);
});

// ----------------------------------------------------------------------------
// 9. HFR upstream response diagnostics + semantic acceptance
// ----------------------------------------------------------------------------

Deno.test("hfr: HTTP 200 with explicit success body includes sanitized hfrUpstream summary", async () => {
  const { res, calls } = await runHfr((url) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return bridgeServicesOkResponse("bridge-1");
    }
    if (url.endsWith("/v1/bridges/MutipleHRPAddUpdateServices")) {
      return jsonResponse({
        status: "accepted",
        code: "SUCCESS",
        message: "Facility service accepted",
        facilityId: "IN2810014366",
        bridgeId: "bridge-1",
      });
    }
    if (url.includes("/bridge-service/serviceId/IN2810014366")) {
      return serviceByIdOkResponse();
    }
    throw new Error(`unexpected call: ${url}`);
  });

  const body = await res.json() as Record<string, unknown>;
  assertEquals(res.status, 200);
  assertEquals(body["status"], "linkage_verified");

  const hfrUpstream = body["hfrUpstream"] as Record<string, unknown>;
  assert(hfrUpstream, "hfrUpstream summary must be present");
  assertEquals(hfrUpstream["status"], 200);
  assertEquals(hfrUpstream["bodyType"], "json");
  assertEquals(hfrUpstream["code"], "SUCCESS");
  assertEquals(hfrUpstream["statusField"], "accepted");
  assertEquals(hfrUpstream["facilityId"], "IN2810014366");
  assertEquals(hfrUpstream["bridgeId"], "bridge-1");

  // Exactly one HFR POST; no retries.
  assertEquals(calls.filter((c) => c.url.includes("apihspsbx")).length, 1);
});

Deno.test("hfr: HTTP 200 with explicit failure/error body returns HFR_LINKAGE_REJECTED and skips verification", async () => {
  const { res, calls } = await runHfr((url) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return bridgeServicesOkResponse("bridge-1");
    }
    if (url.endsWith("/v1/bridges/MutipleHRPAddUpdateServices")) {
      return jsonResponse({
        status: "200",
        code: "ERROR",
        message: "Facility validation failed",
        error: "Invalid facility id",
      });
    }
    throw new Error(`unexpected call: ${url}`);
  });

  const body = await res.json() as Record<string, unknown>;
  assertEquals(res.status, 502);
  assertEquals(body["code"], "HFR_LINKAGE_REJECTED");

  const hfrUpstream = body["hfrUpstream"] as Record<string, unknown>;
  assert(hfrUpstream, "hfrUpstream summary must be present");
  assertEquals(hfrUpstream["status"], 200);
  assertEquals(hfrUpstream["code"], "ERROR");

  // No verification calls after a semantically rejected 200 body.
  assertEquals(
    calls.filter((c) => c.url.includes("/bridge-service/serviceId/")).length,
    0,
  );
});

Deno.test("hfr: non-2xx HFR response includes sanitized hfrUpstream summary", async () => {
  const { res } = await runHfr((url) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return bridgeServicesOkResponse("bridge-1");
    }
    if (url.endsWith("/v1/bridges/MutipleHRPAddUpdateServices")) {
      return jsonResponse({
        status: "error",
        message: "Internal server error",
        error: "upstream exploded",
      }, 500);
    }
    throw new Error(`unexpected call: ${url}`);
  });

  const body = await res.json() as Record<string, unknown>;
  assertEquals(res.status, 502);
  assertEquals(body["code"], "HFR_LINKAGE_500");
  const hfrUpstream = body["hfrUpstream"] as Record<string, unknown>;
  assert(hfrUpstream, "hfrUpstream summary must be present");
  assertEquals(hfrUpstream["status"], 500);
  assertEquals(hfrUpstream["statusField"], "error");
});

Deno.test("hfr: malformed/non-JSON 200 response returns HFR_LINKAGE_UNRECOGNIZED with truncated text", async () => {
  const { res, calls } = await runHfr((url) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return bridgeServicesOkResponse("bridge-1");
    }
    if (url.endsWith("/v1/bridges/MutipleHRPAddUpdateServices")) {
      return new Response("plain text body that is not json", {
        status: 200,
        headers: { "Content-Type": "text/plain" },
      });
    }
    throw new Error(`unexpected call: ${url}`);
  });

  const body = await res.json() as Record<string, unknown>;
  assertEquals(res.status, 502);
  assertEquals(body["code"], "HFR_LINKAGE_UNRECOGNIZED");
  const hfrUpstream = body["hfrUpstream"] as Record<string, unknown>;
  assert(hfrUpstream, "hfrUpstream summary must be present");
  assertEquals(hfrUpstream["status"], 200);
  assertEquals(hfrUpstream["bodyType"], "text");
  assertEquals(hfrUpstream["message"], "plain text body that is not json");

  assertEquals(
    calls.filter((c) => c.url.includes("/bridge-service/serviceId/")).length,
    0,
  );
});

Deno.test("hfr: diagnostics never leak tokens, secrets, Aadhaar or OTP", async () => {
  const { res } = await runHfr((url) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return bridgeServicesOkResponse("bridge-1");
    }
    if (url.endsWith("/v1/bridges/MutipleHRPAddUpdateServices")) {
      return jsonResponse({
        status: "error",
        message: "rejected",
        accessToken: "hfr-access-token",
        clientSecret: "hfr-client-secret",
        aadhaar: "123456789012",
        otp: "123456",
        patient: { name: "Rahul" },
      });
    }
    throw new Error(`unexpected call: ${url}`);
  });

  const text = await res.text();
  assert(!text.includes("hfr-access-token"), "token leaked");
  assert(!text.includes("hfr-client-secret"), "client secret leaked");
  assert(!text.includes("123456789012"), "Aadhaar leaked");
  assert(!text.includes("123456"), "OTP leaked");
  assert(!text.includes("Rahul"), "patient data leaked");
});

// ----------------------------------------------------------------------------
// 10. HFR upstream response SHAPE diagnostics
// ----------------------------------------------------------------------------

Deno.test("hfr shape: root object exposes top-level and nested data keys", async () => {
  const { res } = await runHfr((url) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return bridgeServicesOkResponse("bridge-1");
    }
    if (url.endsWith("/v1/bridges/MutipleHRPAddUpdateServices")) {
      return jsonResponse({
        status: "accepted",
        data: { facilityId: "IN2810014366", status: "success" },
      });
    }
    if (url.includes("/bridge-service/serviceId/IN2810014366")) {
      return serviceByIdOkResponse();
    }
    throw new Error(`unexpected call: ${url}`);
  });

  const body = await res.json() as Record<string, unknown>;
  assertEquals(body["status"], "linkage_verified");
  const shape = body["hfrUpstreamShape"] as Record<string, unknown>;
  assert(shape, "hfrUpstreamShape must be present");
  assertEquals(shape["rootType"], "object");
  assertEquals(shape["topLevelKeys"], ["status", "data"]);
  assertEquals(shape["arrayLength"], null);
  assertEquals(shape["firstItemType"], null);
  assertEquals(shape["firstItemKeys"], []);
  assertEquals(shape["dataType"], "object");
  assertEquals(shape["dataKeys"], ["facilityId", "status"]);
  assertEquals(shape["resultType"], "null");
  assertEquals(shape["resultKeys"], []);
});

Deno.test("hfr shape: root array exposes length and first item keys", async () => {
  const { res } = await runHfr((url) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return bridgeServicesOkResponse("bridge-1");
    }
    if (url.endsWith("/v1/bridges/MutipleHRPAddUpdateServices")) {
      return jsonResponse([{ id: "1", name: "one" }, { id: "2", name: "two" }]);
    }
    throw new Error(`unexpected call: ${url}`);
  });

  const body = await res.json() as Record<string, unknown>;
  assertEquals(body["code"], "HFR_LINKAGE_UNRECOGNIZED");
  const shape = body["hfrUpstreamShape"] as Record<string, unknown>;
  assert(shape, "hfrUpstreamShape must be present");
  assertEquals(shape["rootType"], "array");
  assertEquals(shape["arrayLength"], 2);
  assertEquals(shape["firstItemType"], "object");
  assertEquals(shape["firstItemKeys"], ["id", "name"]);
  assertEquals(shape["topLevelKeys"], []);
});

Deno.test("hfr shape: nested result object exposes result keys", async () => {
  const { res } = await runHfr((url) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return bridgeServicesOkResponse("bridge-1");
    }
    if (url.endsWith("/v1/bridges/MutipleHRPAddUpdateServices")) {
      return jsonResponse({
        status: "accepted",
        result: { id: "IN2810014366", bridgeId: "bridge-1" },
      });
    }
    if (url.includes("/bridge-service/serviceId/IN2810014366")) {
      return serviceByIdOkResponse();
    }
    throw new Error(`unexpected call: ${url}`);
  });

  const body = await res.json() as Record<string, unknown>;
  const shape = body["hfrUpstreamShape"] as Record<string, unknown>;
  assert(shape, "hfrUpstreamShape must be present");
  assertEquals(shape["rootType"], "object");
  assertEquals(shape["resultType"], "object");
  assertEquals(shape["resultKeys"], ["id", "bridgeId"]);
  assertEquals(shape["dataType"], "null");
  assertEquals(shape["dataKeys"], []);
});

Deno.test("hfr shape: empty object", async () => {
  const { res } = await runHfr((url) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return bridgeServicesOkResponse("bridge-1");
    }
    if (url.endsWith("/v1/bridges/MutipleHRPAddUpdateServices")) {
      return jsonResponse({});
    }
    throw new Error(`unexpected call: ${url}`);
  });

  const body = await res.json() as Record<string, unknown>;
  assertEquals(body["code"], "HFR_LINKAGE_UNRECOGNIZED");
  const shape = body["hfrUpstreamShape"] as Record<string, unknown>;
  assert(shape, "hfrUpstreamShape must be present");
  assertEquals(shape["rootType"], "object");
  assertEquals(shape["topLevelKeys"], []);
});

Deno.test("hfr shape: empty array", async () => {
  const { res } = await runHfr((url) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return bridgeServicesOkResponse("bridge-1");
    }
    if (url.endsWith("/v1/bridges/MutipleHRPAddUpdateServices")) {
      return jsonResponse([]);
    }
    throw new Error(`unexpected call: ${url}`);
  });

  const body = await res.json() as Record<string, unknown>;
  assertEquals(body["code"], "HFR_LINKAGE_UNRECOGNIZED");
  const shape = body["hfrUpstreamShape"] as Record<string, unknown>;
  assert(shape, "hfrUpstreamShape must be present");
  assertEquals(shape["rootType"], "array");
  assertEquals(shape["arrayLength"], 0);
  assertEquals(shape["firstItemType"], "null");
  assertEquals(shape["firstItemKeys"], []);
});

Deno.test("hfr shape: never leaks primitive sensitive values", async () => {
  const { res } = await runHfr((url) => {
    if (url.endsWith("/api/hiecm/gateway/v3/sessions")) {
      return sessionOkResponse("fresh-v3-token");
    }
    if (url.endsWith("/api/hiecm/gateway/v3/bridge-services")) {
      return bridgeServicesOkResponse("bridge-1");
    }
    if (url.endsWith("/v1/bridges/MutipleHRPAddUpdateServices")) {
      return jsonResponse({
        status: "accepted",
        accessToken: "hfr-access-token",
        clientSecret: "hfr-client-secret",
        aadhaar: "123456789012",
        otp: "123456",
        patient: { name: "Rahul" },
      });
    }
    if (url.includes("/bridge-service/serviceId/IN2810014366")) {
      return serviceByIdOkResponse();
    }
    throw new Error(`unexpected call: ${url}`);
  });

  const text = await res.text();
  assert(!text.includes("hfr-access-token"), "token value leaked");
  assert(!text.includes("hfr-client-secret"), "client secret value leaked");
  assert(!text.includes("123456789012"), "Aadhaar value leaked");
  assert(!text.includes("123456"), "OTP value leaked");
  assert(!text.includes("Rahul"), "patient data leaked");
});
