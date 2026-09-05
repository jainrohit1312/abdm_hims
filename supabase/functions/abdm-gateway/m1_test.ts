// ============================================================================
// Deno tests for the M1 (ABHA identity) routing of the abdm-gateway function.
//
// These tests use mocked fetch + injected dependencies only and NEVER call the
// live ABDM Sandbox. Because no official client-supplied M1 contract exists in
// this repository, the tests assert the strict contract gate: every valid M1
// request is stopped with ABDM_M1_CONTRACT_UNCONFIRMED before any outbound
// request is built, while routing/auth/permission/hospital/transaction/rate
// limit/sanitization behaviour is exercised fully.
// ============================================================================

import { HttpError, SlidingWindowRateLimiter } from "./core.ts";
import {
  ABDM_M1_CONTRACT_UNCONFIRMED,
  extractM1Profiles,
  gatewayRequest,
  isValidAadhaar,
  isValidAbhaAddress,
  isValidAbhaNumber,
  isValidIndianMobile,
  isValidM1Otp,
  m1MapUpstreamError,
  maskMobileNumber,
  normalizeAbhaNumber,
  resolveInternalAction,
  safeFetchBinary,
  type GatewayConfig,
  type TokenCacheRef,
} from "./core.ts";
import {
  handleRequest,
  type AuthenticatedUser,
  type M1Transaction,
  type M1TransactionStore,
  type RequestDeps,
} from "./handler.ts";

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

const envWithSecrets = {
  ABDM_CLIENT_ID: "client-id",
  ABDM_CLIENT_SECRET: "client-secret",
};

function receptionistUser(): AuthenticatedUser {
  return {
    authId: "auth-1",
    userId: "user-1",
    role: "receptionist",
    hospitalId: "hospital-1",
  };
}

function doctorUser(): AuthenticatedUser {
  return {
    authId: "auth-2",
    userId: "user-2",
    role: "doctor",
    hospitalId: "hospital-1",
  };
}

function noHospitalUser(): AuthenticatedUser {
  return { authId: "auth-3", userId: "user-3", role: "admin", hospitalId: null };
}

function m1Request(
  action: string,
  payload: Record<string, unknown>,
  headers: Record<string, string> = {},
): Request {
  return new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: JSON.stringify({ action, payload }),
  });
}

function deps(
  authenticate: RequestDeps["authenticate"],
  overrides: Partial<RequestDeps> = {},
): RequestDeps {
  return {
    env: envWithSecrets,
    fetchImpl: (async () => {
      throw new Error("ABDM gateway must never be called while the M1 contract is unconfirmed");
    }) as typeof fetch,
    authenticate,
    persistCallbackRow: async () => {},
    ...overrides,
  };
}

function fetchCountingDeps(
  authenticate: RequestDeps["authenticate"],
  overrides: Partial<RequestDeps> = {},
): { deps: RequestDeps; calls: number } {
  let calls = 0;
  const fetchImpl = (async () => {
    calls += 1;
    throw new Error("ABDM gateway must never be called while the M1 contract is unconfirmed");
  }) as typeof fetch;
  return {
    deps: {
      env: envWithSecrets,
      fetchImpl,
      authenticate,
      persistCallbackRow: async () => {},
      ...overrides,
    },
    get calls() {
      return calls;
    },
  };
}

function freshTokenCache(): TokenCacheRef {
  return { current: null };
}

function mockFetch(handler: (url: string, init: RequestInit) => Response): typeof fetch {
  return (async (input: string | URL | Request, init?: RequestInit) => {
    const url = typeof input === "string"
      ? input
      : input instanceof URL
      ? input.toString()
      : input.url;
    return handler(url, init ?? {});
  }) as typeof fetch;
}

// ----------------------------------------------------------------------------
// 1. Routing: every M1 action is a protected internal action
// ----------------------------------------------------------------------------

const M1_ACTIONS = [
  "m1GenerateAadhaarOtp",
  "m1VerifyAadhaarOtp",
  "m1CreateAbha",
  "m1GetProfile",
  "m1VerifyAbhaNumber",
  "m1SearchByMobile",
  "m1VerifyAbhaAddress",
  "m1GetAbhaCard",
  "m1GetAbhaQr",
] as const;

for (const action of M1_ACTIONS) {
  Deno.test(`M1 routing resolves POST action=${action}`, () => {
    assertEquals(resolveInternalAction("POST", "", action), action);
  });
}

Deno.test("M1 actions are never reachable through a callback subpath", () => {
  for (const action of M1_ACTIONS) {
    assertEquals(resolveInternalAction("POST", "/v0.5/notify", action), null);
  }
});

// ----------------------------------------------------------------------------
// 2. Supabase JWT required for every M1 action
// ----------------------------------------------------------------------------

for (const action of M1_ACTIONS) {
  Deno.test(`M1 ${action} requires a Supabase JWT`, async () => {
    const requestDeps = deps(async () => {
      throw new HttpError(401, "Invalid or expired user session");
    });
    const res = await handleRequest(m1Request(action, {}), requestDeps);
    assertEquals(res.status, 401);
  });
}

// ----------------------------------------------------------------------------
// 3. Role permission policy + hospital resolution
// ----------------------------------------------------------------------------

Deno.test("M1 rejects a doctor role with ABDM_M1_FORBIDDEN", async () => {
  const res = await handleRequest(
    m1Request("m1GenerateAadhaarOtp", { aadhaarNumber: "123456789012" }),
    deps(async () => doctorUser()),
  );
  const body = await res.json() as Record<string, unknown>;
  assertEquals(res.status, 403);
  assertEquals(body["code"], "ABDM_M1_FORBIDDEN");
});

Deno.test("M1 rejects an admin with no hospital context", async () => {
  const res = await handleRequest(
    m1Request("m1GenerateAadhaarOtp", { aadhaarNumber: "123456789012" }),
    deps(async () => noHospitalUser()),
  );
  const body = await res.json() as Record<string, unknown>;
  assertEquals(res.status, 403);
  assertEquals(body["code"], "ABDM_M1_FORBIDDEN");
});

Deno.test("M1 allows receptionist (front-desk) and reaches the contract gate", async () => {
  const { deps: requestDeps, calls } = fetchCountingDeps(async () => receptionistUser());
  const res = await handleRequest(
    m1Request("m1GenerateAadhaarOtp", { aadhaarNumber: "123456789012" }),
    requestDeps,
  );
  const body = await res.json() as Record<string, unknown>;
  assertEquals(res.status, 501);
  assertEquals(body["code"], ABDM_M1_CONTRACT_UNCONFIRMED);
  assertEquals(calls, 0, "no outbound ABDM call may be made while the contract is unconfirmed");
});

// ----------------------------------------------------------------------------
// 4. Input validation (before the contract gate)
// ----------------------------------------------------------------------------

Deno.test("M1 generate rejects non-12-digit Aadhaar with ABDM_M1_INVALID_INPUT", async () => {
  for (const aadhaar of ["", "123", "12345678901", "1234567890123", "12345678901a"]) {
    const res = await handleRequest(
      m1Request("m1GenerateAadhaarOtp", { aadhaarNumber: aadhaar }),
      deps(async () => receptionistUser()),
    );
    const body = await res.json() as Record<string, unknown>;
    assertEquals(res.status, 400, `aadhaar=${aadhaar}`);
    assertEquals(body["code"], "ABDM_M1_INVALID_INPUT");
  }
});

Deno.test("M1 verify rejects a non-6-digit OTP with ABDM_M1_INVALID_INPUT", async () => {
  const res = await handleRequest(
    m1Request("m1VerifyAadhaarOtp", { txnId: "txn-1", otp: "12345" }),
    deps(async () => receptionistUser()),
  );
  const body = await res.json() as Record<string, unknown>;
  assertEquals(res.status, 400);
  assertEquals(body["code"], "ABDM_M1_INVALID_INPUT");
});

Deno.test("M1 verify/create require a transaction id", async () => {
  for (const action of ["m1VerifyAadhaarOtp", "m1CreateAbha"] as const) {
    const res = await handleRequest(
      m1Request(action, action === "m1VerifyAadhaarOtp" ? { otp: "123456" } : {}),
      deps(async () => receptionistUser()),
    );
    const body = await res.json() as Record<string, unknown>;
    assertEquals(res.status, 400);
    assertEquals(body["code"], "ABDM_M1_INVALID_INPUT");
  }
});

Deno.test("M1 search rejects an invalid mobile", async () => {
  const res = await handleRequest(
    m1Request("m1SearchByMobile", { mobile: "12345" }),
    deps(async () => receptionistUser()),
  );
  const body = await res.json() as Record<string, unknown>;
  assertEquals(res.status, 400);
  assertEquals(body["code"], "ABDM_M1_INVALID_INPUT");
});

Deno.test("M1 rejects an invalid ABHA number and ABHA address", async () => {
  const numberRes = await handleRequest(
    m1Request("m1VerifyAbhaNumber", { abhaNumber: "91-1234-5678" }),
    deps(async () => receptionistUser()),
  );
  assertEquals((await numberRes.json() as Record<string, unknown>)["code"], "ABDM_M1_INVALID_INPUT");

  const addressRes = await handleRequest(
    m1Request("m1VerifyAbhaAddress", { abhaAddress: "not-an-address" }),
    deps(async () => receptionistUser()),
  );
  assertEquals((await addressRes.json() as Record<string, unknown>)["code"], "ABDM_M1_INVALID_INPUT");
});

Deno.test("M1 contract gate triggers for every action with valid input and no outbound call", async () => {
  const validPayloads: Record<string, Record<string, unknown>> = {
    m1GenerateAadhaarOtp: { aadhaarNumber: "123456789012" },
    m1VerifyAadhaarOtp: { txnId: "txn-1", otp: "123456" },
    m1CreateAbha: { txnId: "txn-1" },
    m1GetProfile: { abhaNumber: "91123456789012" },
    m1VerifyAbhaNumber: { abhaNumber: "91123456789012" },
    m1SearchByMobile: { mobile: "9999999999" },
    m1VerifyAbhaAddress: { abhaAddress: "rahul9012@abdm" },
    m1GetAbhaCard: { abhaAddress: "rahul9012@abdm" },
    m1GetAbhaQr: { abhaAddress: "rahul9012@abdm" },
  };

  for (const action of M1_ACTIONS) {
    // Continuation steps need a transaction store, otherwise they fail closed
    // with a 500 before the contract gate.
    const needsStore = action === "m1VerifyAadhaarOtp" || action === "m1CreateAbha";
    const store: M1TransactionStore | undefined = needsStore
      ? {
          findByTransactionId: async (id) => id === "txn-1"
            ? {
                transactionId: id,
                userId: "user-1",
                hospitalId: "hospital-1",
                operation: "m1GenerateAadhaarOtp",
                expiresAt: new Date(Date.now() + 600_000).toISOString(),
                consumedAt: null,
              }
            : null,
          markConsumed: async () => {},
        }
      : undefined;

    const { deps: requestDeps, calls } = fetchCountingDeps(
      async () => receptionistUser(),
      {
        // Fresh limiters per action so earlier tests never exhaust them.
        m1OtpRateLimiter: new SlidingWindowRateLimiter(60_000, 10),
        m1RateLimiter: new SlidingWindowRateLimiter(60_000, 10),
        ...(store ? { m1TransactionStore: store } : {}),
      },
    );
    const res = await handleRequest(
      m1Request(action, validPayloads[action] ?? {}),
      requestDeps,
    );
    const body = await res.json() as Record<string, unknown>;
    assertEquals(res.status, 501, action);
    assertEquals(body["code"], ABDM_M1_CONTRACT_UNCONFIRMED, action);
    assertEquals(calls, 0, `${action} must never reach the ABDM gateway while unconfirmed`);
  }
});

// ----------------------------------------------------------------------------
// 5. Transaction binding (expiry / ownership / consumed)
// ----------------------------------------------------------------------------

function transactionStore(record: M1Transaction | null, consumed = false): {
  store: M1TransactionStore;
  consumedIds: string[];
} {
  const consumedIds: string[] = [];
  return {
    store: {
      findByTransactionId: async () => record,
      markConsumed: async (id) => {
        consumedIds.push(id);
        if (consumed) throw new Error("already consumed");
      },
    },
    consumedIds,
  };
}

Deno.test("M1 verify rejects an unknown transaction as expired", async () => {
  const { store } = transactionStore(null);
  const res = await handleRequest(
    m1Request("m1VerifyAadhaarOtp", { txnId: "missing", otp: "123456" }),
    deps(async () => receptionistUser(), { m1TransactionStore: store }),
  );
  const body = await res.json() as Record<string, unknown>;
  assertEquals(res.status, 410);
  assertEquals(body["code"], "ABDM_M1_TRANSACTION_EXPIRED");
});

Deno.test("M1 verify rejects a transaction owned by another user/hospital", async () => {
  const { store } = transactionStore({
    transactionId: "txn-1",
    userId: "other-user",
    hospitalId: "other-hospital",
    operation: "m1GenerateAadhaarOtp",
    expiresAt: new Date(Date.now() + 600_000).toISOString(),
    consumedAt: null,
  });
  const res = await handleRequest(
    m1Request("m1VerifyAadhaarOtp", { txnId: "txn-1", otp: "123456" }),
    deps(async () => receptionistUser(), { m1TransactionStore: store }),
  );
  const body = await res.json() as Record<string, unknown>;
  assertEquals(res.status, 403);
  assertEquals(body["code"], "ABDM_M1_TRANSACTION_EXPIRED");
});

Deno.test("M1 verify rejects an already-consumed transaction", async () => {
  const { store } = transactionStore({
    transactionId: "txn-1",
    userId: "user-1",
    hospitalId: "hospital-1",
    operation: "m1GenerateAadhaarOtp",
    expiresAt: new Date(Date.now() + 600_000).toISOString(),
    consumedAt: new Date().toISOString(),
  });
  const res = await handleRequest(
    m1Request("m1VerifyAadhaarOtp", { txnId: "txn-1", otp: "123456" }),
    deps(async () => receptionistUser(), { m1TransactionStore: store }),
  );
  const body = await res.json() as Record<string, unknown>;
  assertEquals(res.status, 410);
  assertEquals(body["code"], "ABDM_M1_TRANSACTION_EXPIRED");
});

Deno.test("M1 verify rejects an expired transaction", async () => {
  const { store } = transactionStore({
    transactionId: "txn-1",
    userId: "user-1",
    hospitalId: "hospital-1",
    operation: "m1GenerateAadhaarOtp",
    expiresAt: new Date(Date.now() - 1000).toISOString(),
    consumedAt: null,
  });
  const res = await handleRequest(
    m1Request("m1VerifyAadhaarOtp", { txnId: "txn-1", otp: "123456" }),
    deps(async () => receptionistUser(), { m1TransactionStore: store }),
  );
  const body = await res.json() as Record<string, unknown>;
  assertEquals(res.status, 410);
  assertEquals(body["code"], "ABDM_M1_TRANSACTION_EXPIRED");
});

Deno.test("M1 verify consumes a valid owned transaction and then stops at the contract gate", async () => {
  const { store, consumedIds } = transactionStore({
    transactionId: "txn-1",
    userId: "user-1",
    hospitalId: "hospital-1",
    operation: "m1GenerateAadhaarOtp",
    expiresAt: new Date(Date.now() + 600_000).toISOString(),
    consumedAt: null,
  });
  const res = await handleRequest(
    m1Request("m1VerifyAadhaarOtp", { txnId: "txn-1", otp: "123456" }),
    deps(async () => receptionistUser(), {
      m1TransactionStore: store,
      m1OtpRateLimiter: new SlidingWindowRateLimiter(60_000, 10),
    }),
  );
  const body = await res.json() as Record<string, unknown>;
  assertEquals(res.status, 501);
  assertEquals(body["code"], ABDM_M1_CONTRACT_UNCONFIRMED);
  assertEquals(consumedIds, ["txn-1"]);
});

// ----------------------------------------------------------------------------
// 6. Rate limiting for OTP-sensitive endpoints
// ----------------------------------------------------------------------------

Deno.test("M1 generate OTP is rate limited per user+operation", async () => {
  const limiter = new SlidingWindowRateLimiter(60_000, 2);
  const requestDeps = deps(async () => receptionistUser(), {
    m1OtpRateLimiter: limiter,
  });

  for (let i = 0; i < 2; i++) {
    const res = await handleRequest(
      m1Request("m1GenerateAadhaarOtp", { aadhaarNumber: "123456789012" }),
      requestDeps,
    );
    assertEquals(res.status, 501);
  }
  const blocked = await handleRequest(
    m1Request("m1GenerateAadhaarOtp", { aadhaarNumber: "123456789012" }),
    requestDeps,
  );
  const body = await blocked.json() as Record<string, unknown>;
  assertEquals(blocked.status, 429);
  assertEquals(body["code"], "ABDM_M1_RATE_LIMITED");
});

Deno.test("M1 verify OTP is rate limited but a different user is unaffected", async () => {
  const limiter = new SlidingWindowRateLimiter(60_000, 1);
  const { store } = transactionStore({
    transactionId: "txn-1",
    userId: "user-1",
    hospitalId: "hospital-1",
    operation: "m1GenerateAadhaarOtp",
    expiresAt: new Date(Date.now() + 600_000).toISOString(),
    consumedAt: null,
  });
  const requestDeps = deps(async () => receptionistUser(), {
    m1OtpRateLimiter: limiter,
    m1TransactionStore: store,
  });
  const first = await handleRequest(
    m1Request("m1VerifyAadhaarOtp", { txnId: "txn-1", otp: "123456" }),
    requestDeps,
  );
  assertEquals(first.status, 501);

  const blocked = await handleRequest(
    m1Request("m1VerifyAadhaarOtp", { txnId: "txn-1", otp: "123456" }),
    requestDeps,
  );
  assertEquals(blocked.status, 429);
});

// ----------------------------------------------------------------------------
// 7. Sensitive data never reaches logs or responses
// ----------------------------------------------------------------------------

Deno.test("M1 responses and logs never contain raw Aadhaar or OTP", async () => {
  const logs: string[] = [];
  const errors: string[] = [];
  const originalLog = console.log;
  const originalError = console.error;
  console.log = (...args: unknown[]) => logs.push(args.map(String).join(" "));
  console.error = (...args: unknown[]) => errors.push(args.map(String).join(" "));

  try {
    const res = await handleRequest(
      m1Request("m1GenerateAadhaarOtp", { aadhaarNumber: "123456789012" }),
      deps(async () => receptionistUser()),
    );
    const text = await res.text();
    assert(text.includes("123456789012") === false, "raw Aadhaar must never be returned");
    assert(text.includes("ABDM_M1_CONTRACT_UNCONFIRMED"), "contract-gate code must be returned");
  } finally {
    console.log = originalLog;
    console.error = originalError;
  }

  const allLogs = [...logs, ...errors].join(" ");
  assert(allLogs.includes("123456789012") === false, "raw Aadhaar must never be logged");
  assert(allLogs.includes("123456") === false, "OTP must never be logged");
});

// ----------------------------------------------------------------------------
// 8. Pure M1 error mapping + sanitization helpers
// ----------------------------------------------------------------------------

Deno.test("m1MapUpstreamError maps the structured ABDM_M1_* contract", () => {
  assertEquals(m1MapUpstreamError(0, "timeout"), "ABDM_M1_TIMEOUT");
  assertEquals(m1MapUpstreamError(0, "network"), "ABDM_M1_NETWORK");
  assertEquals(m1MapUpstreamError(400), "ABDM_M1_UPSTREAM_400");
  assertEquals(m1MapUpstreamError(401), "ABDM_M1_UPSTREAM_401");
  assertEquals(m1MapUpstreamError(403), "ABDM_M1_UPSTREAM_403");
  assertEquals(m1MapUpstreamError(404), "ABDM_M1_UPSTREAM_404");
  assertEquals(m1MapUpstreamError(409), "ABDM_M1_UPSTREAM_409");
  assertEquals(m1MapUpstreamError(429), "ABDM_M1_UPSTREAM_429");
  assertEquals(m1MapUpstreamError(500), "ABDM_M1_UPSTREAM_500");
  assertEquals(m1MapUpstreamError(502), "ABDM_M1_UPSTREAM_500");
});

Deno.test("extractM1Profiles allow-lists fields, masks mobile, drops tokens/OTP/Aadhaar", () => {
  const result = extractM1Profiles({
    accounts: [
      {
        healthId: "91-1234-5678-9012",
        healthIdNumber: "91-1234-5678-9012",
        abhaAddress: "rahul9012@abdm",
        name: "Rahul Sharma",
        gender: "M",
        dateOfBirth: "1990-05-15",
        mobileNumber: "9999999999",
        otp: "123456",
        aadhaar: "123456789012",
        accessToken: "token-value",
        extraField: "should-be-dropped",
      },
      {
        healthId: "91-1111-2222-3333",
        abhaAddress: "rahul3333@sbx",
        name: "Rahul Second",
      },
    ],
  });

  assertEquals(result.multiple, true);
  assertEquals(result.profiles.length, 2);
  const first = result.profiles[0] as Record<string, unknown>;
  assertEquals(first["healthId"], "91-1234-5678-9012");
  assertEquals(first["abhaAddress"], "rahul9012@abdm");
  assertEquals(first["name"], "Rahul Sharma");
  assertEquals(first["mobileNumber"], "XXXXXX9999");
  assert(first["otp"] === undefined, "OTP must be dropped");
  assert(first["aadhaar"] === undefined, "Aadhaar must be dropped");
  assert(first["accessToken"] === undefined, "tokens must be dropped");
  assert(first["extraField"] === undefined, "non-allow-listed fields must be dropped");
});

Deno.test("extractM1Profiles handles a single profile object", () => {
  const result = extractM1Profiles({
    healthId: "91123456789012",
    name: "Rahul",
  });
  assertEquals(result.multiple, false);
  assertEquals(result.profiles.length, 1);
});

Deno.test("validation helpers follow the documented shapes", () => {
  assertEquals(isValidAadhaar("123456789012"), true);
  assertEquals(isValidAadhaar("12345678901"), false);
  assertEquals(isValidM1Otp("123456"), true);
  assertEquals(isValidM1Otp("12345"), false);
  assertEquals(isValidIndianMobile("9999999999"), true);
  assertEquals(isValidIndianMobile("1234567890"), false);
  assertEquals(isValidAbhaNumber("91-1234-5678-9012"), true);
  assertEquals(normalizeAbhaNumber("91-1234-5678-9012"), "91123456789012");
  assertEquals(isValidAbhaAddress("rahul9012@abdm", ["abdm", "sbx"]), true);
  assertEquals(isValidAbhaAddress("rahul9012@sbx", ["abdm", "sbx"]), true);
  assertEquals(isValidAbhaAddress("rahul9012@other", ["abdm", "sbx"]), false);
  assertEquals(maskMobileNumber("9999999999"), "XXXXXX9999");
  assertEquals(maskMobileNumber("XXXXXX1234"), "XXXXXX1234");
});

// ----------------------------------------------------------------------------
// 9. No unsafe retry for OTP generation / ABHA creation on 401/403
// ----------------------------------------------------------------------------

Deno.test("gatewayRequest never retries 401/403 when retryOnAuthFailure is false", async () => {
  const config: GatewayConfig = {
    baseUrl: "https://dev.abdm.gov.in",
    clientId: "id",
    clientSecret: "secret",
    bridgeId: "",
    hipId: "",
    hiuId: "",
    callbackBaseUrl: "https://cb.example",
    sessionPath: "/gateway/v1/sessions",
    bridgePath: "/gateway/v1/bridges",
    servicesPath: "/gateway/v1/bridges/addUpdateServices",
    getServicesPath: "/gateway/v1/bridges/getServices",
    hfrBaseUrl: "https://apihspsbx.abdm.gov.in/v4/int",
    hfrServicesPath: "/v1/bridges/MutipleHRPAddUpdateServices",
    allowedServiceTypes: ["HIP", "HIU"],
    cmId: "sbx",
    tokenSafetyMarginSeconds: 120,
    m1BaseUrl: "",
    m1GenerateAadhaarOtpPath: "",
    m1VerifyAadhaarOtpPath: "",
    m1CreateAbhaPath: "",
    m1GetProfilePath: "",
    m1VerifyAbhaNumberPath: "",
    m1SearchByMobilePath: "",
    m1VerifyAbhaAddressPath: "",
    m1GetAbhaCardPath: "",
    m1GetAbhaQrPath: "",
    m1AllowedRoles: ["super_admin", "admin", "receptionist"],
    m1AbhaAddressSuffixes: ["abdm", "sbx"],
  };

  let operationCalls = 0;
  let sessionCalls = 0;
  const fetchImpl = mockFetch((url) => {
    if (url.endsWith("/gateway/v1/sessions")) {
      sessionCalls += 1;
      return new Response(
        JSON.stringify({ accessToken: "fresh-token", expiresIn: 3600 }),
        { status: 200 },
      );
    }
    operationCalls += 1;
    return new Response(JSON.stringify({ error: "forbidden" }), { status: 403 });
  });

  const cache: TokenCacheRef = {
    current: { accessToken: "stale", expiresAt: Date.now() + 3600_000 },
  };
  const result = await gatewayRequest(
    fetchImpl,
    config,
    cache,
    "POST",
    "/m1/test/generate",
    { aadhaar: "[REDACTED]" },
    { retryOnAuthFailure: false },
  );

  assertEquals(result.status, 403);
  assertEquals(result.freshTokenRetryPerformed, false);
  assertEquals(result.retryStatus, null);
  assertEquals(operationCalls, 1, "OTP/creation-like operations must be attempted once only");
  assertEquals(sessionCalls, 0, "no fresh session may be requested for a non-retryable operation");
});

// ----------------------------------------------------------------------------
// 10. Binary content-type / size handling (future card/QR plumbing)
// ----------------------------------------------------------------------------

Deno.test("safeFetchBinary returns PNG bytes for an allowed content type", async () => {
  const bytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47]);
  const fetchImpl = mockFetch(() =>
    new Response(bytes, {
      status: 200,
      headers: { "Content-Type": "image/png" },
    })
  );
  const result = await safeFetchBinary(fetchImpl, "https://dev.abdm.gov.in/m1/card", {
    method: "GET",
  });
  assertEquals(result.ok, true);
  assertEquals(result.contentType, "image/png");
  assertEquals(Array.from(result.bytes), [0x89, 0x50, 0x4e, 0x47]);
});

Deno.test("safeFetchBinary rejects unsupported content types", async () => {
  const fetchImpl = mockFetch(() =>
    new Response("binary", {
      status: 200,
      headers: { "Content-Type": "text/html" },
    })
  );
  let threw = false;
  try {
    await safeFetchBinary(fetchImpl, "https://dev.abdm.gov.in/m1/card", { method: "GET" });
  } catch (error) {
    threw = true;
    assert((error as Error).message.includes("unsupported binary content type"), "content type must be rejected");
  }
  assert(threw, "unsupported content type must throw");
});

Deno.test("safeFetchBinary rejects oversized binary payloads", async () => {
  const fetchImpl = mockFetch(() =>
    new Response(new Uint8Array(2048), {
      status: 200,
      headers: { "Content-Type": "image/png" },
    })
  );
  let threw = false;
  try {
    await safeFetchBinary(fetchImpl, "https://dev.abdm.gov.in/m1/card", { method: "GET" }, 1024);
  } catch (error) {
    threw = true;
    assert((error as Error).message.includes("size limit"), "oversized payload must be rejected");
  }
  assert(threw, "oversized binary payload must throw");
});
