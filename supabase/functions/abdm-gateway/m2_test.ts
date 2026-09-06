// ============================================================================
// Deno tests for ABDM V3 M2 HIP (discover, link, consent, health information).
//
// Run locally with:
//   cd supabase/functions/abdm-gateway && deno test --allow-read --allow-net .
//
// These tests use mocked fetch + in-memory stores ONLY and never call the live
// ABDM Sandbox. The official V3 M2 contract paths/bodies come from the NHA
// ABDM-wrapper v3 source.
// ============================================================================

import { SlidingWindowRateLimiter } from "./core.ts";
import {
  buildFhirBundleFromSource,
  extractCareContextRefs,
  groupCareContextsByHiType,
  m2CallbackTypeForSubpath,
  M2_ERROR_CODES,
  type M2CareContextStore,
  type M2ConsentArtefactRow,
  type M2ConsentStore,
  type M2DataTransferJobRow,
  type M2DataTransferJobStore,
  type M2FhirBundleSource,
  type M2Hospital,
  type M2LinkInitPersistRecord,
  type M2LinkInitRecord,
  type M2RequestRow,
  type M2RequestStore,
  type M2InsertResult,
  V3_M2_CB_CONSENT_NOTIFY,
  V3_M2_CB_DISCOVER,
  V3_M2_CB_HEALTH_INFORMATION_REQUEST,
  V3_M2_CB_LINK_CONFIRM,
  V3_M2_CB_LINK_INIT,
  V3_M2_CONSENT_ON_NOTIFY_PATH,
  V3_M2_HEALTH_INFORMATION_ON_REQUEST_PATH,
  V3_M2_ON_CONFIRM_PATH,
  V3_M2_ON_DISCOVER_PATH,
  V3_M2_ON_INIT_PATH,
  validateM2ConsentNotification,
  validateM2DiscoverRequest,
  validateM2HealthInformationRequest,
  validateM2LinkConfirmRequest,
  validateM2LinkInitRequest,
} from "./m2.ts";
import {
  handleRequest,
  type M2FhirSourceStore,
  type M2HospitalStore,
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

function assertStringContains(value: string, needle: string, message = ""): void {
  if (!value.includes(needle)) {
    throw new Error(`${message ? message + " — " : ""}"${value}" does not contain "${needle}"`);
  }
}

const envWithSecrets = {
  ABDM_CLIENT_ID: "sbx-client-id",
  ABDM_CLIENT_SECRET: "sbx-client-secret",
};

// ----------------------------------------------------------------------------
// Mock gateway fetch
// ----------------------------------------------------------------------------

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

function m2GatewayFetch(): { fetchImpl: typeof fetch; calls: CapturedCall[] } {
  return recordingFetch((url) => {
    if (url.includes("/api/hiecm/gateway/v3/sessions")) {
      return new Response(
        JSON.stringify({ accessToken: "v3-test-token", expiresIn: 3600 }),
        { status: 200, headers: { "Content-Type": "application/json" } },
      );
    }
    return new Response(JSON.stringify({ status: "SUCCESS" }), {
      status: 202,
      headers: { "Content-Type": "application/json" },
    });
  });
}

function m2OutboundCalls(calls: CapturedCall[]): CapturedCall[] {
  return calls.filter((call) =>
    call.url.includes("/api/hiecm/") &&
    !call.url.includes("/gateway/v3/sessions")
  );
}

// ----------------------------------------------------------------------------
// In-memory M2 stores
// ----------------------------------------------------------------------------

class InMemoryM2RequestStore implements M2RequestStore {
  rows: Array<M2RequestRow & { linkInit?: M2LinkInitPersistRecord }> = [];

  async insert(row: M2RequestRow): Promise<M2InsertResult> {
    if (row.request_id) {
      const existing = this.rows.find((r) =>
        r.request_id === row.request_id && r.request_type === row.request_type
      );
      if (existing) return "duplicate";
    }
    this.rows.push({ ...row });
    return "inserted";
  }

  async updateLinkInit(requestId: string, record: M2LinkInitPersistRecord) {
    const row = this.rows.find((r) => r.request_id === requestId);
    if (!row) throw new Error("link-init row not found");
    row.link_ref_number = record.linkRefNumber;
    row.token_hash = record.tokenHash;
    row.expires_at = record.expiresAt;
    row.linkInit = record;
  }

  async findLinkInitByLinkRef(linkRefNumber: string): Promise<M2LinkInitRecord | null> {
    const row = this.rows.find((r) =>
      r.link_ref_number === linkRefNumber && r.request_type === "linkInit"
    );
    if (!row || !row.linkInit) return null;
    return {
      request_id: row.request_id,
      transaction_id: row.transaction_id,
      abha_address: row.linkInit.abhaAddress,
      link_ref_number: row.linkInit.linkRefNumber,
      token_hash: row.linkInit.tokenHash,
      expires_at: row.linkInit.expiresAt,
      care_context_refs: row.linkInit.careContextRefs,
    };
  }

  async markProcessed(
    requestId: string,
    requestType: string,
    status: string,
    responsePayload: Record<string, unknown> | null,
    errorCode?: string | null,
    errorMessage?: string | null,
  ) {
    const row = this.rows.find((r) =>
      r.request_id === requestId && r.request_type === requestType
    );
    if (!row) return;
    row.status = status;
    row.response_payload = responsePayload;
    row.error_code = errorCode ?? null;
    row.error_message = errorMessage ?? null;
  }
}

class InMemoryM2CareContextStore implements M2CareContextStore {
  patients: Array<{
    hospitalId: string;
    abhaAddress: string;
    reference: string;
    display: string;
  }> = [];
  careContexts: Array<{
    hospitalId: string;
    abhaAddress: string;
    referenceNumber: string;
    display: string;
    hiType: string;
    linked: boolean;
  }> = [];
  markedLinked: string[] = [];

  async findUnlinkedByAbha(abhaId: string, hospitalId: string) {
    const patient = this.patients.find((p) =>
      p.hospitalId === hospitalId && p.abhaAddress === abhaId
    );
    if (!patient) return null;
    const contexts = this.careContexts
      .filter((c) =>
        c.hospitalId === hospitalId && c.abhaAddress === abhaId && !c.linked
      )
      .map((c) => ({
        referenceNumber: c.referenceNumber,
        display: c.display,
        hiType: c.hiType,
      }));
    return {
      patientReference: patient.reference,
      patientDisplay: patient.display,
      careContexts: contexts,
    };
  }

  async findForReferences(abhaId: string, careContextRefs: string[], hospitalId: string) {
    return this.careContexts
      .filter((c) =>
        c.hospitalId === hospitalId &&
        c.abhaAddress === abhaId &&
        careContextRefs.includes(c.referenceNumber)
      )
      .map((c) => ({
        referenceNumber: c.referenceNumber,
        display: c.display,
        hiType: c.hiType,
      }));
  }

  async markLinked(abhaId: string, careContextRefs: string[], hospitalId: string) {
    for (const context of this.careContexts) {
      if (
        context.hospitalId === hospitalId &&
        context.abhaAddress === abhaId &&
        careContextRefs.includes(context.referenceNumber)
      ) {
        context.linked = true;
        this.markedLinked.push(context.referenceNumber);
      }
    }
  }
}

class InMemoryM2ConsentStore implements M2ConsentStore {
  rows = new Map<string, M2ConsentArtefactRow>();

  async upsert(row: M2ConsentArtefactRow) {
    this.rows.set(row.consent_id, row);
    return { error: null };
  }

  async findByConsentId(consentId: string) {
    return this.rows.get(consentId) ?? null;
  }
}

class InMemoryM2DataTransferJobStore implements M2DataTransferJobStore {
  jobs: M2DataTransferJobRow[] = [];

  async upsert(row: M2DataTransferJobRow) {
    const existing = this.jobs.findIndex((j) => j.transaction_id === row.transaction_id);
    if (existing >= 0) this.jobs[existing] = row;
    else this.jobs.push(row);
    return { error: null };
  }
}

const hospitalA: M2Hospital = {
  hospitalId: "hospital-a",
  facilityId: "IN0000000001",
  facilityName: "Mediflux Test Hospital",
  hipName: "MEDIFLUX",
};

const hospitalB: M2Hospital = {
  hospitalId: "hospital-b",
  facilityId: "IN0000000002",
  facilityName: "Other Hospital",
  hipName: "OTHER",
};

class InMemoryM2HospitalStore implements M2HospitalStore {
  async findByHipId(hipId: string): Promise<M2Hospital | null> {
    if (hipId === hospitalA.facilityId) return hospitalA;
    if (hipId === hospitalB.facilityId) return hospitalB;
    return null;
  }
}

function m2Deps(input: {
  fetchImpl: typeof fetch;
  hospitalStore?: M2HospitalStore;
  requestStore?: M2RequestStore;
  careContextStore?: M2CareContextStore;
  consentStore?: M2ConsentStore;
  dataTransferJobStore?: M2DataTransferJobStore;
  fhirSourceStore?: M2FhirSourceStore;
  linkNotifier?: RequestDeps["m2LinkNotifier"];
  dataTransferEnabled?: boolean;
  rateLimiter?: SlidingWindowRateLimiter;
}): RequestDeps {
  return {
    env: envWithSecrets,
    fetchImpl: input.fetchImpl,
    authenticate: async () => {
      throw new Error("M2 callbacks must never require a user session");
    },
    persistCallbackRow: async () => {},
    callbackRateLimiter: input.rateLimiter ?? new SlidingWindowRateLimiter(60_000, 1000),
    v3TokenCache: { current: null },
    m2HospitalStore: input.hospitalStore ?? new InMemoryM2HospitalStore(),
    m2RequestStore: input.requestStore ?? new InMemoryM2RequestStore(),
    m2CareContextStore: input.careContextStore ?? new InMemoryM2CareContextStore(),
    m2ConsentStore: input.consentStore ?? new InMemoryM2ConsentStore(),
    m2DataTransferJobStore: input.dataTransferJobStore ?? new InMemoryM2DataTransferJobStore(),
    m2LinkNotifier: input.linkNotifier ?? undefined,
    m2Encryptor: undefined,
    m2FhirSourceStore: input.fhirSourceStore ?? undefined,
    m2DataTransferEnabled: input.dataTransferEnabled === true,
  };
}

function m2Request(
  subpath: string,
  body: Record<string, unknown>,
  headers: Record<string, string> = {},
): Request {
  return new Request(
    `https://x.supabase.co/functions/v1/abdm-gateway${subpath}`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-HIP-ID": hospitalA.facilityId,
        ...headers,
      },
      body: JSON.stringify(body),
    },
  );
}

const DISCOVER_BODY = {
  requestId: "req-discover-1",
  transactionId: "txn-discover-1",
  timestamp: "2026-09-06T00:00:00.000Z",
  patient: {
    id: "patient1@sbx",
    name: "Rahul Sharma",
    gender: "M",
    yearOfBirth: "1990",
  },
};

const LINK_INIT_BODY = {
  requestId: "req-link-1",
  transactionId: "txn-link-1",
  abhaAddress: "patient1@sbx",
  patient: [
    {
      referenceNumber: "UHID-001",
      display: "Rahul Sharma",
      careContexts: [
        { referenceNumber: "CC-OPD-1", display: "OPD Visit" },
      ],
    },
  ],
};

const CONSENT_NOTIFY_BODY = {
  requestId: "req-consent-1",
  timestamp: "2026-09-06T00:00:00.000Z",
  notification: {
    consentId: "consent-1",
    status: "GRANTED",
    signature: "sig",
    consentDetail: {
      schemaVersion: "1.0",
      consentId: "consent-1",
      patient: { id: "patient1@sbx" },
      careContexts: [{ careContextReference: "CC-OPD-1" }],
      hiTypes: ["OPConsultation"],
      purpose: { text: "Care management" },
      hip: { id: "IN0000000001" },
      hiu: { id: "HIU-1" },
      permission: {
        accessMode: "VIEW",
        dateRange: { from: "2026-01-01T00:00:00.000Z", to: "2026-12-31T00:00:00.000Z" },
        dataEraseAt: "2027-01-01T00:00:00.000Z",
        frequency: { unit: "HOUR", value: 1, repeats: 0 },
      },
    },
  },
};

const HEALTH_INFORMATION_BODY = {
  requestId: "req-hi-1",
  timestamp: "2026-09-06T00:00:00.000Z",
  transactionId: "txn-hi-1",
  hiRequest: {
    consent: { id: "consent-1" },
    dateRange: { from: "2026-01-01T00:00:00.000Z", to: "2026-12-31T00:00:00.000Z" },
    dataPushUrl: "https://hiu.example/fhir/v3/transfer",
    keyMaterial: {
      cryptoAlg: "ECDH",
      curve: "curve25519",
      dhPublicKey: {
        expiry: "2026-09-06T01:00:00.000Z",
        parameters: "prime256v1",
        keyValue: "base64-public-key",
      },
      nonce: "nonce-1",
    },
  },
};

// ----------------------------------------------------------------------------
// Unit tests: contract mapping + validators + builders
// ----------------------------------------------------------------------------

Deno.test("m2: inbound callback subpath maps to canonical V3 M2 types", () => {
  assertEquals(m2CallbackTypeForSubpath(V3_M2_CB_DISCOVER), "discover");
  assertEquals(m2CallbackTypeForSubpath(V3_M2_CB_LINK_INIT), "linkInit");
  assertEquals(m2CallbackTypeForSubpath(V3_M2_CB_LINK_CONFIRM), "linkConfirm");
  assertEquals(m2CallbackTypeForSubpath(V3_M2_CB_CONSENT_NOTIFY), "consentNotify");
  assertEquals(
    m2CallbackTypeForSubpath(V3_M2_CB_HEALTH_INFORMATION_REQUEST),
    "healthInformationRequest",
  );
  assertEquals(m2CallbackTypeForSubpath("/api/v3/hip/patient/care-context/discover/"), "discover");
  assertEquals(m2CallbackTypeForSubpath("/v0.5/patients/discover"), null);
  assertEquals(m2CallbackTypeForSubpath("/v1/links/link/init"), null);
});

Deno.test("m2: discover validator accepts valid request and rejects missing fields", () => {
  const valid = validateM2DiscoverRequest(DISCOVER_BODY, hospitalA.facilityId);
  assertEquals(valid.ok, true);
  assertEquals(valid.value?.patientId, "patient1@sbx");

  const missingPatient = validateM2DiscoverRequest(
    { ...DISCOVER_BODY, patient: {} },
    hospitalA.facilityId,
  );
  assertEquals(missingPatient.ok, false);
  assert(missingPatient.errors.length > 0, "expected patient.id error");

  const missingHip = validateM2DiscoverRequest(DISCOVER_BODY, "");
  assertEquals(missingHip.ok, false);
});

Deno.test("m2: link validators enforce mandatory fields", () => {
  const init = validateM2LinkInitRequest(LINK_INIT_BODY);
  assertEquals(init.ok, true);
  assertEquals(init.value?.careContextRefs, ["CC-OPD-1"]);

  const initBad = validateM2LinkInitRequest({ ...LINK_INIT_BODY, abhaAddress: "" });
  assertEquals(initBad.ok, false);

  const confirm = validateM2LinkConfirmRequest({
    requestId: "req-link-2",
    confirmation: { linkRefNumber: "ref-1", token: "123456" },
  });
  assertEquals(confirm.ok, true);

  const confirmBad = validateM2LinkConfirmRequest({
    requestId: "req-link-2",
    confirmation: { linkRefNumber: "ref-1" },
  });
  assertEquals(confirmBad.ok, false);
});

Deno.test("m2: consent + health-information validators enforce mandatory fields", () => {
  const consent = validateM2ConsentNotification(CONSENT_NOTIFY_BODY);
  assertEquals(consent.ok, true);
  assertEquals(consent.value?.careContextRefs, ["CC-OPD-1"]);
  assertEquals(consent.value?.status, "GRANTED");

  const consentBad = validateM2ConsentNotification({
    ...CONSENT_NOTIFY_BODY,
    notification: { consentId: "", status: "GRANTED", consentDetail: {} },
  });
  assertEquals(consentBad.ok, false);

  const hi = validateM2HealthInformationRequest(HEALTH_INFORMATION_BODY);
  assertEquals(hi.ok, true);
  assertEquals(hi.value?.consentId, "consent-1");
  assertEquals(hi.value?.keyMaterial.dhPublicKey.keyValue, "base64-public-key");

  const hiBad = validateM2HealthInformationRequest({
    ...HEALTH_INFORMATION_BODY,
    hiRequest: { ...HEALTH_INFORMATION_BODY.hiRequest, dataPushUrl: "" },
  });
  assertEquals(hiBad.ok, false);
});

Deno.test("m2: care-context grouping and reference extraction", () => {
  const grouped = groupCareContextsByHiType("UHID-001", "Rahul Sharma", [
    { referenceNumber: "CC-1", display: "OPD", hiType: "OPConsultation" },
    { referenceNumber: "CC-2", display: "OPD 2", hiType: "OPConsultation" },
    { referenceNumber: "CC-3", display: "Rx", hiType: "Prescription" },
  ]);
  assertEquals(grouped.length, 2);
  assertEquals(grouped[0].count, 2);
  assertEquals(grouped[1].hiType, "Prescription");

  const refs = extractCareContextRefs([
    { careContextReference: "A" },
    { referenceNumber: "B" },
    { careContextReference: "A" },
  ]);
  assertEquals(refs, ["A", "B"]);
});

Deno.test("m2: FHIR bundle builder is safe and ABDM-shaped", () => {
  const source: M2FhirBundleSource = {
    patient: {
      abhaId: "91-1234-5678-9012",
      abhaAddress: "patient1@sbx",
      name: "Rahul Sharma",
      gender: "male",
      dateOfBirth: "1990-05-15",
    },
    careContexts: [
      {
        recordType: "opd_visit",
        recordId: "opd-1",
        display: "OPD Visit",
        careContextReference: "CC-OPD-1",
        dateTime: "2026-09-06T00:00:00.000Z",
      },
      {
        recordType: "prescription",
        recordId: "rx-1",
        display: "Prescription",
        careContextReference: "CC-RX-1",
        dateTime: "2026-09-06T00:00:00.000Z",
      },
    ],
  };
  const result = buildFhirBundleFromSource(source);
  assertEquals(result.ok, true);
  const bundle = result.bundle as Record<string, unknown>;
  assertEquals(bundle["resourceType"], "Bundle");
  assertEquals(bundle["type"], "document");
  const entries = bundle["entry"] as Array<Record<string, unknown>>;
  assertEquals(entries.length, 3);
  const resources = entries.map((entry) =>
    (entry["resource"] as Record<string, unknown>)["resourceType"]
  );
  assertEquals(resources, ["Patient", "Encounter", "MedicationRequest"]);

  const missingPatient = buildFhirBundleFromSource({
    patient: { abhaId: "" },
    careContexts: source.careContexts,
  });
  assertEquals(missingPatient.ok, false);

  const missingClinical = buildFhirBundleFromSource({
    patient: source.patient,
    careContexts: [],
  });
  assertEquals(missingClinical.ok, false);
});

// ----------------------------------------------------------------------------
// Handler-level tests: official V3 M2 callback routing
// ----------------------------------------------------------------------------

function baseCareContextStore(): InMemoryM2CareContextStore {
  const store = new InMemoryM2CareContextStore();
  store.patients.push({
    hospitalId: hospitalA.hospitalId,
    abhaAddress: "patient1@sbx",
    reference: "UHID-001",
    display: "Rahul Sharma",
  });
  store.careContexts.push({
    hospitalId: hospitalA.hospitalId,
    abhaAddress: "patient1@sbx",
    referenceNumber: "CC-OPD-1",
    display: "OPD Visit",
    hiType: "OPConsultation",
    linked: false,
  });
  store.careContexts.push({
    hospitalId: hospitalA.hospitalId,
    abhaAddress: "patient1@sbx",
    referenceNumber: "CC-RX-1",
    display: "Prescription",
    hiType: "Prescription",
    linked: false,
  });
  return store;
}

function baseConsentStore(): InMemoryM2ConsentStore {
  const store = new InMemoryM2ConsentStore();
  store.rows.set("consent-1", {
    hospital_id: hospitalA.hospitalId,
    patient_id: "patient-1",
    abha_id: "patient1@sbx",
    consent_id: "consent-1",
    hip_id: hospitalA.facilityId,
    hiu_id: "HIU-1",
    purpose: "Care management",
    data_from: "2026-01-01T00:00:00.000Z",
    data_to: "2026-12-31T00:00:00.000Z",
    status: "granted",
    granted_at: "2026-09-06T00:00:00.000Z",
    expires_at: "2027-01-01T00:00:00.000Z",
    care_context_references: ["CC-OPD-1"],
  });
  return store;
}

const fhirSourceStore: M2FhirSourceStore = {
  async fetchForConsent(abhaId, refs) {
    if (abhaId !== "patient1@sbx" || refs.length === 0) return null;
    return {
      patient: {
        abhaId,
        abhaAddress: "patient1@sbx",
        name: "Rahul Sharma",
        gender: "male",
        dateOfBirth: "1990-05-15",
      },
      careContexts: refs.map((ref) => ({
        recordType: "opd_visit",
        recordId: ref,
        display: "OPD Visit",
        careContextReference: ref,
        dateTime: "2026-09-06T00:00:00.000Z",
      })),
    };
  },
};

Deno.test("m2: discover callback posts official V3 on-discover and ACKs 200", async () => {
  const { fetchImpl, calls } = m2GatewayFetch();
  const requestStore = new InMemoryM2RequestStore();
  const deps = m2Deps({
    fetchImpl,
    requestStore,
    careContextStore: baseCareContextStore(),
    consentStore: baseConsentStore(),
  });
  const response = await handleRequest(
    m2Request(V3_M2_CB_DISCOVER, DISCOVER_BODY),
    deps,
  );
  assertEquals(response.status, 200);

  const outbound = m2OutboundCalls(calls);
  assertEquals(outbound.length, 1);
  assertEquals(
    outbound[0].url,
    `https://dev.abdm.gov.in${V3_M2_ON_DISCOVER_PATH}`,
  );
  assertEquals(outbound[0].headers.get("x-hip-id"), hospitalA.facilityId);
  assertEquals(outbound[0].headers.get("authorization"), "Bearer v3-test-token");
  const body = outbound[0].body as Record<string, unknown>;
  assertEquals(body["transactionId"], "txn-discover-1");
  const patients = body["patient"] as Array<Record<string, unknown>>;
  assertEquals(patients.length, 2);
  assertEquals(patients[0]["referenceNumber"], "UHID-001");
  assertEquals(patients[0]["careContexts"], [
    { referenceNumber: "CC-OPD-1", display: "OPD Visit", hiType: "OPConsultation" },
  ]);
  assertEquals(patients[1]["careContexts"], [
    { referenceNumber: "CC-RX-1", display: "Prescription", hiType: "Prescription" },
  ]);

  const stored = requestStore.rows[0];
  assertEquals(stored.request_type, "discover");
  assertEquals(stored.status, "on_discover_sent");
  const storedPayload = stored.payload as Record<string, unknown>;
  const storedPatient = storedPayload["patient"] as Record<string, unknown>;
  assertEquals(storedPatient["id"], "patient1@sbx");
});

Deno.test("m2: discover for unknown patient sends on-discover error", async () => {
  const { fetchImpl, calls } = m2GatewayFetch();
  const deps = m2Deps({
    fetchImpl,
    careContextStore: new InMemoryM2CareContextStore(),
    consentStore: baseConsentStore(),
  });
  const response = await handleRequest(
    m2Request(V3_M2_CB_DISCOVER, {
      ...DISCOVER_BODY,
      requestId: "req-discover-2",
    }),
    deps,
  );
  assertEquals(response.status, 200);
  const outbound = m2OutboundCalls(calls);
  assertEquals(outbound.length, 1);
  const body = outbound[0].body as Record<string, unknown>;
  const error = body["error"] as Record<string, unknown>;
  assertEquals(error["code"], M2_ERROR_CODES.PATIENT_NOT_FOUND);
});

Deno.test("m2: malformed discover callback is rejected with 400", async () => {
  const { fetchImpl, calls } = m2GatewayFetch();
  const deps = m2Deps({ fetchImpl });
  const response = await handleRequest(
    m2Request(V3_M2_CB_DISCOVER, { requestId: "req-bad" }),
    deps,
  );
  assertEquals(response.status, 400);
  assertEquals(m2OutboundCalls(calls).length, 0);
});

Deno.test("m2: unknown X-HIP-ID resolves to 404 and never calls the gateway", async () => {
  const { fetchImpl, calls } = m2GatewayFetch();
  const requestStore = new InMemoryM2RequestStore();
  const deps = m2Deps({ fetchImpl, requestStore });
  const response = await handleRequest(
    m2Request(
      V3_M2_CB_DISCOVER,
      { ...DISCOVER_BODY, requestId: "req-no-hip" },
      { "X-HIP-ID": "IN9999999999" },
    ),
    deps,
  );
  assertEquals(response.status, 404);
  assertEquals(m2OutboundCalls(calls).length, 0);
  assertEquals(requestStore.rows[0].error_code, M2_ERROR_CODES.HIP_NOT_FOUND);
});

Deno.test("m2: duplicate discover callback is idempotent (single outbound)", async () => {
  const { fetchImpl, calls } = m2GatewayFetch();
  const deps = m2Deps({
    fetchImpl,
    careContextStore: baseCareContextStore(),
    consentStore: baseConsentStore(),
  });
  const request = m2Request(V3_M2_CB_DISCOVER, DISCOVER_BODY);
  const first = await handleRequest(request.clone(), deps);
  const second = await handleRequest(request, deps);
  assertEquals(first.status, 200);
  assertEquals(second.status, 200);
  assertEquals(m2OutboundCalls(calls).length, 1);
});

Deno.test("m2: link init with working notifier sends official on-init and stores token hash only", async () => {
  const { fetchImpl, calls } = m2GatewayFetch();
  const requestStore = new InMemoryM2RequestStore();
  const deps = m2Deps({
    fetchImpl,
    requestStore,
    careContextStore: baseCareContextStore(),
    consentStore: baseConsentStore(),
    linkNotifier: {
      async sendOtp() {
        return { ok: true };
      },
    },
  });
  const response = await handleRequest(
    m2Request(V3_M2_CB_LINK_INIT, LINK_INIT_BODY),
    deps,
  );
  assertEquals(response.status, 200);
  const outbound = m2OutboundCalls(calls);
  assertEquals(outbound.length, 1);
  assertEquals(outbound[0].url, `https://dev.abdm.gov.in${V3_M2_ON_INIT_PATH}`);
  const body = outbound[0].body as Record<string, unknown>;
  const link = body["link"] as Record<string, unknown>;
  assert(link["referenceNumber"], "link reference must exist");

  const stored = requestStore.rows[0];
  assert(stored.token_hash, "token hash must be persisted");
  assertStringContains(stored.token_hash, "", "hash must not be empty");
  assert(!JSON.stringify(stored.payload).includes("token"), "raw token must never be persisted");
});

Deno.test("m2: link init without notifier sends on-init error", async () => {
  const { fetchImpl, calls } = m2GatewayFetch();
  const deps = m2Deps({
    fetchImpl,
    careContextStore: baseCareContextStore(),
    consentStore: baseConsentStore(),
    linkNotifier: undefined,
  });
  const response = await handleRequest(
    m2Request(V3_M2_CB_LINK_INIT, { ...LINK_INIT_BODY, requestId: "req-link-3" }),
    deps,
  );
  assertEquals(response.status, 200);
  const outbound = m2OutboundCalls(calls);
  assertEquals(outbound.length, 1);
  const body = outbound[0].body as Record<string, unknown>;
  assertEquals((body["error"] as Record<string, unknown>)["code"], M2_ERROR_CODES.OTP_SEND_FAILED);
});

Deno.test("m2: link confirm with valid token links care contexts and sends on-confirm", async () => {
  const { fetchImpl, calls } = m2GatewayFetch();
  const requestStore = new InMemoryM2RequestStore();
  const careContextStore = baseCareContextStore();
  // Seed a link-init record: generate token, store hash in both the row and the
  // store lookup path used by the handler.
  const token = "123456";
  const tokenHash = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(token),
  ).then((digest) =>
    [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("")
  );
  const linkRef = "link-ref-1";
  const seedRow: M2RequestRow = {
    hospital_id: hospitalA.hospitalId,
    request_id: "req-link-seed",
    transaction_id: "txn-link-1",
    request_type: "linkInit",
    callback_path: V3_M2_CB_LINK_INIT,
    status: "link_init_sent",
    payload: LINK_INIT_BODY,
    link_ref_number: linkRef,
    token_hash: tokenHash,
    expires_at: new Date(Date.now() + 60_000).toISOString(),
    received_at: new Date().toISOString(),
  };
  const linkInitRecord: M2LinkInitPersistRecord = {
    linkRefNumber: linkRef,
    tokenHash,
    expiresAt: seedRow.expires_at!,
    abhaAddress: "patient1@sbx",
    careContextRefs: ["CC-OPD-1"],
  };
  (seedRow as unknown as { linkInit: M2LinkInitPersistRecord }).linkInit = linkInitRecord;
  requestStore.rows.push(seedRow as never);

  const deps = m2Deps({
    fetchImpl,
    requestStore,
    careContextStore,
    consentStore: baseConsentStore(),
  });
  const response = await handleRequest(
    m2Request(V3_M2_CB_LINK_CONFIRM, {
      requestId: "req-confirm-1",
      confirmation: { linkRefNumber: linkRef, token },
    }),
    deps,
  );
  assertEquals(response.status, 200);
  assertEquals(careContextStore.markedLinked, ["CC-OPD-1"]);
  const outbound = m2OutboundCalls(calls);
  assertEquals(outbound.length, 1);
  assertEquals(outbound[0].url, `https://dev.abdm.gov.in${V3_M2_ON_CONFIRM_PATH}`);
  const body = outbound[0].body as Record<string, unknown>;
  assertEquals((body["patient"] as unknown[]).length, 1);
});

Deno.test("m2: link confirm with wrong token sends ABDM-1035 error and does not link", async () => {
  const { fetchImpl, calls } = m2GatewayFetch();
  const requestStore = new InMemoryM2RequestStore();
  const careContextStore = baseCareContextStore();
  const seedRow: M2RequestRow = {
    hospital_id: hospitalA.hospitalId,
    request_id: "req-link-seed-wrong",
    transaction_id: "txn-link-1",
    request_type: "linkInit",
    callback_path: V3_M2_CB_LINK_INIT,
    status: "link_init_sent",
    payload: LINK_INIT_BODY,
    link_ref_number: "link-ref-wrong",
    token_hash: "abc",
    expires_at: new Date(Date.now() + 60_000).toISOString(),
    received_at: new Date().toISOString(),
  };
  (seedRow as unknown as { linkInit: M2LinkInitPersistRecord }).linkInit = {
    linkRefNumber: "link-ref-wrong",
    tokenHash: "abc",
    expiresAt: seedRow.expires_at!,
    abhaAddress: "patient1@sbx",
    careContextRefs: ["CC-OPD-1"],
  };
  requestStore.rows.push(seedRow as never);

  const deps = m2Deps({
    fetchImpl,
    requestStore,
    careContextStore,
    consentStore: baseConsentStore(),
  });
  const response = await handleRequest(
    m2Request(V3_M2_CB_LINK_CONFIRM, {
      requestId: "req-confirm-2",
      confirmation: { linkRefNumber: "link-ref-wrong", token: "000000" },
    }),
    deps,
  );
  assertEquals(response.status, 200);
  assertEquals(careContextStore.markedLinked, []);
  const outbound = m2OutboundCalls(calls);
  assertEquals(outbound.length, 1);
  const body = outbound[0].body as Record<string, unknown>;
  assertEquals((body["error"] as Record<string, unknown>)["code"], M2_ERROR_CODES.INVALID_TOKEN);
});

Deno.test("m2: link confirm persists redacted token in event payload", async () => {
  const { fetchImpl } = m2GatewayFetch();
  const requestStore = new InMemoryM2RequestStore();
  const deps = m2Deps({
    fetchImpl,
    requestStore,
    careContextStore: baseCareContextStore(),
    consentStore: baseConsentStore(),
  });
  await handleRequest(
    m2Request(V3_M2_CB_LINK_CONFIRM, {
      requestId: "req-confirm-redact",
      confirmation: { linkRefNumber: "missing", token: "123456" },
    }),
    deps,
  );
  const stored = requestStore.rows[0];
  const storedPayload = stored.payload as Record<string, unknown>;
  const storedConfirmation = storedPayload["confirmation"] as Record<string, unknown>;
  assertEquals(storedConfirmation["token"], "[REDACTED]");
});

Deno.test("m2: consent notify upserts artefact and posts official on-notify ACK", async () => {
  const { fetchImpl, calls } = m2GatewayFetch();
  const consentStore = new InMemoryM2ConsentStore();
  const deps = m2Deps({
    fetchImpl,
    consentStore,
    careContextStore: baseCareContextStore(),
  });
  const response = await handleRequest(
    m2Request(V3_M2_CB_CONSENT_NOTIFY, CONSENT_NOTIFY_BODY),
    deps,
  );
  assertEquals(response.status, 202);
  const saved = consentStore.rows.get("consent-1");
  assert(saved, "consent artefact must be persisted");
  assertEquals(saved.care_context_references, ["CC-OPD-1"]);
  assertEquals(saved.status, "granted");

  const outbound = m2OutboundCalls(calls);
  assertEquals(outbound.length, 1);
  assertEquals(outbound[0].url, `https://dev.abdm.gov.in${V3_M2_CONSENT_ON_NOTIFY_PATH}`);
  const body = outbound[0].body as Record<string, unknown>;
  assertEquals(
    (body["acknowledgement"] as Record<string, unknown>)["consentId"],
    "consent-1",
  );
});

Deno.test("m2: health-information request with valid consent creates gated job + ACK", async () => {
  const { fetchImpl, calls } = m2GatewayFetch();
  const jobStore = new InMemoryM2DataTransferJobStore();
  const deps = m2Deps({
    fetchImpl,
    careContextStore: baseCareContextStore(),
    consentStore: baseConsentStore(),
    dataTransferJobStore: jobStore,
    fhirSourceStore,
    dataTransferEnabled: false,
  });
  const response = await handleRequest(
    m2Request(V3_M2_CB_HEALTH_INFORMATION_REQUEST, HEALTH_INFORMATION_BODY),
    deps,
  );
  assertEquals(response.status, 202);
  const outbound = m2OutboundCalls(calls);
  assertEquals(outbound.length, 1);
  assertEquals(
    outbound[0].url,
    `https://dev.abdm.gov.in${V3_M2_HEALTH_INFORMATION_ON_REQUEST_PATH}`,
  );
  const body = outbound[0].body as Record<string, unknown>;
  assertEquals(
    (body["hiRequest"] as Record<string, unknown>)["sessionStatus"],
    "ACKNOWLEDGED",
  );

  assertEquals(jobStore.jobs.length, 1);
  const job = jobStore.jobs[0];
  assertEquals(job.transaction_id, "txn-hi-1");
  assertEquals(job.status, "blocked_safe");
  assertEquals(job.error_code, M2_ERROR_CODES.TRANSFER_GATED);
  assert(job.fhir_bundle, "FHIR bundle must be built even when transfer is gated");
});

Deno.test("m2: health-information request with unknown consent sends on-request error", async () => {
  const { fetchImpl, calls } = m2GatewayFetch();
  const deps = m2Deps({
    fetchImpl,
    careContextStore: baseCareContextStore(),
    consentStore: new InMemoryM2ConsentStore(),
    fhirSourceStore,
  });
  const response = await handleRequest(
    m2Request(V3_M2_CB_HEALTH_INFORMATION_REQUEST, HEALTH_INFORMATION_BODY),
    deps,
  );
  assertEquals(response.status, 202);
  const outbound = m2OutboundCalls(calls);
  assertEquals(outbound.length, 1);
  const body = outbound[0].body as Record<string, unknown>;
  assertEquals((body["error"] as Record<string, unknown>)["code"], M2_ERROR_CODES.CONSENT_INVALID);
});

Deno.test("m2: health-information request with absent source data fails safe", async () => {
  const { fetchImpl, calls } = m2GatewayFetch();
  const jobStore = new InMemoryM2DataTransferJobStore();
  const deps = m2Deps({
    fetchImpl,
    careContextStore: baseCareContextStore(),
    consentStore: baseConsentStore(),
    dataTransferJobStore: jobStore,
    fhirSourceStore: { async fetchForConsent() { return null; } },
  });
  const response = await handleRequest(
    m2Request(V3_M2_CB_HEALTH_INFORMATION_REQUEST, HEALTH_INFORMATION_BODY),
    deps,
  );
  assertEquals(response.status, 202);
  assertEquals(jobStore.jobs.length, 1);
  assertEquals(jobStore.jobs[0].status, "failed_safe");
  assertEquals(jobStore.jobs[0].error_code, M2_ERROR_CODES.SOURCE_DATA_ABSENT);
  // Gateway is still ACKed; the job records the safe failure.
  assertEquals(m2OutboundCalls(calls).length, 1);
});

Deno.test("m2: upstream session 5xx still ACKs the inbound callback", async () => {
  const { fetchImpl, calls } = recordingFetch((url) => {
    if (url.includes("/gateway/v3/sessions")) {
      return new Response(JSON.stringify({ error: { code: "UPSTREAM", message: "down" } }), {
        status: 503,
        headers: { "Content-Type": "application/json" },
      });
    }
    return new Response("{}", { status: 202 });
  });
  const deps = m2Deps({
    fetchImpl,
    careContextStore: baseCareContextStore(),
    consentStore: baseConsentStore(),
  });
  const response = await handleRequest(
    m2Request(V3_M2_CB_DISCOVER, DISCOVER_BODY),
    deps,
  );
  // The inbound callback itself is still acknowledged; the outbound failure is
  // swallowed and logged (never returned to the gateway).
  assertEquals(response.status, 200);
  assertEquals(m2OutboundCalls(calls).length, 0);
});

Deno.test("m2: upstream M2 endpoint network failure still ACKs the inbound callback", async () => {
  const { fetchImpl, calls } = recordingFetch((url) => {
    if (url.includes("/gateway/v3/sessions")) {
      return new Response(JSON.stringify({ accessToken: "tok", expiresIn: 3600 }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }
    throw new Error("connection refused");
  });
  const deps = m2Deps({
    fetchImpl,
    careContextStore: baseCareContextStore(),
    consentStore: baseConsentStore(),
  });
  const response = await handleRequest(
    m2Request(V3_M2_CB_DISCOVER, { ...DISCOVER_BODY, requestId: "req-network" }),
    deps,
  );
  assertEquals(response.status, 200);
  assertEquals(m2OutboundCalls(calls).length, 1);
});

Deno.test("m2: non-M2 callbacks keep the legacy generic ACK path", async () => {
  const { fetchImpl, calls } = m2GatewayFetch();
  const deps = m2Deps({ fetchImpl });
  const response = await handleRequest(
    m2Request("/v0.5/users/auth/on-fetch-modes", { requestId: "legacy-1" }),
    deps,
  );
  assertEquals(response.status, 200);
  const text = await response.text();
  assertEquals(text, JSON.stringify({ status: "ACK" }));
  assertEquals(m2OutboundCalls(calls).length, 0);
});

Deno.test("m2: ack-only V3 callback is persisted and acknowledged", async () => {
  const { fetchImpl, calls } = m2GatewayFetch();
  const requestStore = new InMemoryM2RequestStore();
  const deps = m2Deps({ fetchImpl, requestStore });
  const response = await handleRequest(
    m2Request("/api/v3/links/context/on-notify", { requestId: "req-ack-1", status: "OK" }),
    deps,
  );
  assertEquals(response.status, 200);
  assertEquals(requestStore.rows[0].request_type, "linkOnNotify");
  assertEquals(m2OutboundCalls(calls).length, 0);
});

Deno.test("m2: callback rate limiter still protects M2 routes", async () => {
  const { fetchImpl, calls } = m2GatewayFetch();
  const limiter = new SlidingWindowRateLimiter(60_000, 2);
  const deps = m2Deps({
    fetchImpl,
    careContextStore: baseCareContextStore(),
    consentStore: baseConsentStore(),
    rateLimiter: limiter,
  });
  const request = () =>
    m2Request(V3_M2_CB_DISCOVER, {
      ...DISCOVER_BODY,
      requestId: `req-${crypto.randomUUID()}`,
    });
  await handleRequest(request(), deps);
  await handleRequest(request(), deps);
  const third = await handleRequest(request(), deps);
  assertEquals(third.status, 429);
  assertEquals(m2OutboundCalls(calls).length, 2);
});
