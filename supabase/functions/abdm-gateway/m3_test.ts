// ============================================================================
// Deno tests for ABDM V3 M3 HIU (consent request, callbacks, health-information
// request, encrypted data push, decryption abstraction, FHIR validation).
//
// Run locally with:
//   cd supabase/functions/abdm-gateway && deno test --allow-read --allow-net .
//
// These tests use mocked fetch + in-memory stores ONLY and never call the live
// ABDM Sandbox. The official V3 M3 contract paths/bodies come from the NHA
// ABDM-wrapper v3 source.
// ============================================================================

import { SlidingWindowRateLimiter } from "./core.ts";
import {
  type M3ConsentArtefactRow,
  type M3ConsentRequestRow,
  type M3ConsentRequestStore,
  type M3ConsentStore,
  type M3DataPageRow,
  type M3DataPageStore,
  type M3FhirRecordStore,
  type M3HiRequestRow,
  type M3HiRequestStore,
  type M3ImportedFhirRecord,
  type M3Decryptor,
  type M3KeypairProvider,
  type M3PrivateKeyStore,
  M3_ERROR_CODES,
  M3_HI_REQUEST_STATUS,
  M3_PAGE_STATUS,
  buildM3ConsentInitBody,
  buildM3HealthInformationRequestBody,
  buildM3HealthInformationNotifyBody,
  fetchM3ConsentStatus,
  freshM3RequestId,
  hiTypeForFhirResourceType,
  isM3DataPushSubpath,
  m3CallbackTypeForSubpath,
  processM3DataPush,
  requestM3HealthInformation,
  submitM3ConsentRequest,
  unavailableM3Decryptor,
  validateM3ConsentNotify,
  validateM3ConsentOnFetch,
  validateM3ConsentOnInit,
  validateM3ConsentOnStatus,
  validateM3ConsentRequestInput,
  validateM3DataPush,
  validateM3FhirPayload,
  validateM3HealthInformationOnRequest,
  validateM3KeyMaterial,
  V3_M3_CB_CONSENT_NOTIFY,
  V3_M3_CB_CONSENT_ON_FETCH,
  V3_M3_CB_CONSENT_ON_INIT,
  V3_M3_CB_CONSENT_ON_STATUS,
  V3_M3_CB_HEALTH_INFORMATION_ON_REQUEST,
  V3_M3_CONSENT_INIT_PATH,
  V3_M3_CONSENT_STATUS_PATH,
  V3_M3_DATA_PUSH_PATH,
  V3_M3_HEALTH_INFORMATION_REQUEST_PATH,
  V3_M3_HEALTH_INFORMATION_NOTIFY_PATH,
  V3_M3_HIU_ID_HEADER,
} from "./m3.ts";
import {
  type M2Hospital,
} from "./m2.ts";
import {
  handleRequest,
  type AuthenticatedUser,
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
  ABDM_HIU_ID: "HIU-001",
  ABDM_CALLBACK_BASE_URL: "https://cb.example/functions/v1/abdm-gateway",
};

function b64(value: string): string {
  return btoa(value);
}

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

function m3GatewayFetch(): { fetchImpl: typeof fetch; calls: CapturedCall[] } {
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

function m3OutboundCalls(calls: CapturedCall[]): CapturedCall[] {
  return calls.filter((call) =>
    call.url.includes("/api/hiecm/") &&
    !call.url.includes("/gateway/v3/sessions")
  );
}

// ----------------------------------------------------------------------------
// In-memory M3 stores
// ----------------------------------------------------------------------------

class InMemoryM3ConsentRequestStore implements M3ConsentRequestStore {
  rows: M3ConsentRequestRow[] = [];

  async insert(row: M3ConsentRequestRow): Promise<"inserted" | "duplicate"> {
    if (this.rows.some((r) => r.request_id === row.request_id)) return "duplicate";
    this.rows.push({ ...row });
    return "inserted";
  }

  async updateByRequestId(requestId: string, patch: Partial<M3ConsentRequestRow>) {
    const row = this.rows.find((r) => r.request_id === requestId);
    if (!row) throw new Error("consent request row not found");
    Object.assign(row, patch);
  }

  async findByRequestId(requestId: string) {
    return this.rows.find((r) => r.request_id === requestId) ?? null;
  }

  async findByConsentRequestId(consentRequestId: string) {
    return this.rows.find((r) => r.consent_request_id === consentRequestId) ?? null;
  }
}

class InMemoryM3ConsentStore implements M3ConsentStore {
  rows: M3ConsentArtefactRow[] = [];

  async upsert(row: M3ConsentArtefactRow) {
    const existing = this.rows.find((r) => r.consent_id === row.consent_id);
    if (existing) Object.assign(existing, row);
    else this.rows.push({ ...row });
    return { error: null };
  }

  async findByConsentId(consentId: string) {
    return this.rows.find((r) => r.consent_id === consentId) ?? null;
  }
}

class InMemoryM3HiRequestStore implements M3HiRequestStore {
  rows: M3HiRequestRow[] = [];

  async insert(row: M3HiRequestRow): Promise<"inserted" | "duplicate"> {
    if (this.rows.some((r) => r.request_id === row.request_id)) return "duplicate";
    this.rows.push({ ...row });
    return "inserted";
  }

  async updateByRequestId(requestId: string, patch: Partial<M3HiRequestRow>) {
    const row = this.rows.find((r) => r.request_id === requestId);
    if (!row) throw new Error("hi request row not found");
    Object.assign(row, patch);
  }

  async updateByTransactionId(transactionId: string, patch: Partial<M3HiRequestRow>) {
    const row = this.rows.find((r) => r.transaction_id === transactionId);
    if (!row) throw new Error("hi request row not found");
    Object.assign(row, patch);
  }

  async findByRequestId(requestId: string) {
    return this.rows.find((r) => r.request_id === requestId) ?? null;
  }

  async findByTransactionId(transactionId: string) {
    return this.rows.find((r) => r.transaction_id === transactionId) ?? null;
  }
}

class InMemoryM3DataPageStore implements M3DataPageStore {
  rows: M3DataPageRow[] = [];

  async insertPage(row: M3DataPageRow): Promise<"inserted" | "duplicate"> {
    if (this.rows.some((r) =>
      r.transaction_id === row.transaction_id && r.page_number === row.page_number
    )) return "duplicate";
    this.rows.push({ ...row });
    return "inserted";
  }

  async listByTransactionId(transactionId: string) {
    return this.rows
      .filter((r) => r.transaction_id === transactionId)
      .sort((a, b) => a.page_number - b.page_number);
  }

  async markProcessing(_transactionId: string, _pageNumber: number) {}

  async markProcessed(transactionId: string, pageNumber: number, status: M3DataPageRow["status"], errorCode?: string | null, errorMessage?: string | null) {
    const row = this.rows.find((r) =>
      r.transaction_id === transactionId && r.page_number === pageNumber
    );
    if (row) Object.assign(row, { status, error_code: errorCode ?? null, error_message: errorMessage ?? null });
  }
}

class InMemoryM3FhirRecordStore implements M3FhirRecordStore {
  rows: M3ImportedFhirRecord[] = [];

  async insertImported(record: M3ImportedFhirRecord): Promise<"inserted" | "duplicate" | "error"> {
    const duplicate = this.rows.some((r) =>
      r.transaction_id === record.transaction_id &&
      r.care_context_reference === record.care_context_reference &&
      r.record_id === record.record_id
    );
    if (duplicate) return "duplicate";
    this.rows.push({ ...record });
    return "inserted";
  }
}

class InMemoryM3PrivateKeyStore implements M3PrivateKeyStore {
  available = true;
  keys = new Map<string, { privateKeyBase64: string; nonceBase64: string; expiresAt: string }>();

  async save(transactionId: string, privateKeyBase64: string, nonceBase64: string, expiresAtIso: string) {
    this.keys.set(transactionId, { privateKeyBase64, nonceBase64, expiresAt: expiresAtIso });
    return { ok: true };
  }

  async get(transactionId: string) {
    return this.keys.get(transactionId) ?? null;
  }

  async delete(transactionId: string) {
    this.keys.delete(transactionId);
  }
}

const mockKeypairProvider: M3KeypairProvider = {
  available: true,
  async generate() {
    return {
      ok: true,
      privateKeyBase64: b64("hiu-private-key-32-bytes-xxxxx"),
      publicKeyBase64: b64("hiu-public-key-32-bytes-xxxxxx"),
      nonceBase64: b64("hiu-nonce-32-bytes-xxxxxxxxxxx"),
      parameters: "Curve25519/32byte random key",
    };
  },
};

function mockDecryptor(plaintext: string): M3Decryptor {
  return {
    available: true,
    async decrypt() {
      return { ok: true, plaintext };
    },
  };
}

/** Returns a distinct FHIR resource id for each page marker. */
function pageAwareDecryptor(): M3Decryptor {
  return {
    available: true,
    async decrypt(input) {
      const marker = atob(input.encryptedContent);
      const id = marker.includes("page-1") ? "dr-2" : "dr-1";
      return {
        ok: true,
        plaintext: JSON.stringify({
          resourceType: "DiagnosticReport",
          id,
          status: "final",
        }),
      };
    },
  };
}

function failingDecryptor(code: string, error: string): M3Decryptor {
  return {
    available: true,
    async decrypt() {
      return { ok: false, code, error };
    },
  };
}

// ----------------------------------------------------------------------------
// Shared fixtures
// ----------------------------------------------------------------------------

const hospital: M2Hospital = {
  hospitalId: "hosp-1",
  facilityId: "HIU-001",
  facilityName: "MediFlux HIU",
  hipName: "",
};

function adminUser(): AuthenticatedUser {
  return {
    authId: "auth-1",
    userId: "user-1",
    role: "admin",
    hospitalId: "hosp-1",
  };
}

function noHospitalUser(): AuthenticatedUser {
  return { authId: "auth-2", userId: "user-2", role: "doctor", hospitalId: null };
}

const inMemoryHospitalStore: M2HospitalStore = {
  async findByHipId(hipId: string) {
    return hipId === "HIU-001" ? hospital : null;
  },
};

const hospitalSettings = {
  async getByHospitalId(hospitalId: string) {
    if (hospitalId !== "hosp-1") return null;
    return {
      facilityId: "HIU-001",
      facilityName: "MediFlux HIU",
      hipName: "",
    };
  },
};

function seededConsent(overrides: Partial<M3ConsentArtefactRow> = {}): M3ConsentArtefactRow {
  const now = Date.now();
  return {
    hospital_id: "hosp-1",
    patient_id: "patient-1",
    abha_id: "user@sbx",
    consent_id: "consent-1",
    hip_id: "HIP-001",
    hiu_id: "HIU-001",
    purpose: "Care Management",
    data_from: new Date(now - 30 * 24 * 3600 * 1000).toISOString(),
    data_to: new Date(now + 30 * 24 * 3600 * 1000).toISOString(),
    status: "granted",
    granted_at: new Date(now - 1000).toISOString(),
    expires_at: new Date(now + 60 * 24 * 3600 * 1000).toISOString(),
    care_context_references: ["cc-1"],
    hi_types: ["DiagnosticReport"],
    ...overrides,
  };
}

function seededHiRequest(overrides: Partial<M3HiRequestRow> = {}): M3HiRequestRow {
  return {
    hospital_id: "hosp-1",
    patient_id: "patient-1",
    consent_id: "consent-1",
    request_id: "hi-req-1",
    transaction_id: "txn-1",
    hip_id: "HIP-001",
    hiu_id: "HIU-001",
    status: M3_HI_REQUEST_STATUS.WAITING_FOR_DATA,
    requested_from: new Date(Date.now() - 30 * 24 * 3600 * 1000).toISOString(),
    requested_to: new Date(Date.now() + 30 * 24 * 3600 * 1000).toISOString(),
    hi_types: ["DiagnosticReport"],
    care_context_references: ["cc-1"],
    key_material: {},
    expected_pages: null,
    received_pages: 0,
    error_code: null,
    error_message: null,
    submitted_at: null,
    completed_at: null,
    ...overrides,
  };
}

interface M3Stores {
  consentRequestStore: InMemoryM3ConsentRequestStore;
  consentStore: InMemoryM3ConsentStore;
  hiRequestStore: InMemoryM3HiRequestStore;
  dataPageStore: InMemoryM3DataPageStore;
  fhirRecordStore: InMemoryM3FhirRecordStore;
  privateKeyStore: InMemoryM3PrivateKeyStore;
}

function m3Stores(): M3Stores {
  return {
    consentRequestStore: new InMemoryM3ConsentRequestStore(),
    consentStore: new InMemoryM3ConsentStore(),
    hiRequestStore: new InMemoryM3HiRequestStore(),
    dataPageStore: new InMemoryM3DataPageStore(),
    fhirRecordStore: new InMemoryM3FhirRecordStore(),
    privateKeyStore: new InMemoryM3PrivateKeyStore(),
  };
}

function m3Deps(
  fetchImpl: typeof fetch,
  stores: M3Stores,
  options: {
    user?: AuthenticatedUser;
    dataImportEnabled?: boolean;
    decryptor?: M3Decryptor | null;
    keypairProvider?: M3KeypairProvider | null;
    env?: Record<string, string | undefined>;
    callbackRateLimiter?: RequestDeps["callbackRateLimiter"];
    m3RateLimiter?: RequestDeps["m3RateLimiter"];
  } = {},
): RequestDeps {
  return {
    env: options.env ?? envWithSecrets,
    fetchImpl,
    authenticate: async () => options.user ?? adminUser(),
    persistCallbackRow: async () => {},
    v3TokenCache: { current: null },
    hospitalAbdmSettingsStore: hospitalSettings,
    m2HospitalStore: inMemoryHospitalStore,
    m3ConsentRequestStore: stores.consentRequestStore,
    m3ConsentStore: stores.consentStore,
    m3HiRequestStore: stores.hiRequestStore,
    m3DataPageStore: stores.dataPageStore,
    m3FhirRecordStore: stores.fhirRecordStore,
    m3KeypairProvider: options.keypairProvider ?? null,
    m3PrivateKeyStore: stores.privateKeyStore,
    m3Decryptor: options.decryptor ?? null,
    m3DataImportEnabled: options.dataImportEnabled === true,
    callbackRateLimiter: options.callbackRateLimiter,
    // Fresh per-test M3 rate limiter so tests never bleed window state.
    m3RateLimiter: options.m3RateLimiter ?? new SlidingWindowRateLimiter(60_000, 1000),
  };
}

function consentPayload(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  const now = Date.now();
  return {
    patientId: "patient-1",
    abhaAddress: "user@sbx",
    purpose: "Care Management",
    dataFrom: new Date(now - 30 * 24 * 3600 * 1000).toISOString(),
    dataTo: new Date(now + 30 * 24 * 3600 * 1000).toISOString(),
    hiTypes: ["DiagnosticReport", "Prescription"],
    ...overrides,
  };
}

function dataPushBody(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    pageNumber: 0,
    pageCount: 1,
    transactionId: "txn-1",
    entries: [{
      content: b64("encrypted-fhir-content"),
      media: "application/fhir+json",
      checksum: b64("checksum-bytes"),
      careContextReference: "cc-1",
    }],
    keyMaterial: {
      cryptoAlg: "ECDH",
      curve: "curve25519",
      dhPublicKey: {
        expiry: new Date(Date.now() + 60 * 24 * 3600 * 1000).toISOString(),
        parameters: "Curve25519/32byte random key",
        keyValue: b64("hip-public-key-32-bytes-xxxx"),
      },
      nonce: b64("hip-nonce-32-bytes-xxxxxxxxxx"),
    },
    ...overrides,
  };
}

const FHIR_DIAGNOSTIC_REPORT = JSON.stringify({
  resourceType: "DiagnosticReport",
  id: "dr-1",
  status: "final",
  code: { text: "Blood test" },
  subject: { reference: "Patient/patient-1" },
});

// ============================================================================
// 1. Validators and builders
// ============================================================================

Deno.test("m3: validateM3ConsentRequestInput accepts a valid consent request", () => {
  const input = {
    hospitalId: "hosp-1",
    patientId: "patient-1",
    abhaAddress: "user@sbx",
    purposeText: "Care Management",
    purposeCode: "CAREMGT",
    purposeRefUri: "https://abdm.gov.in/purposes/care-mgmt",
    hiTypes: ["DiagnosticReport", "Prescription"],
    dateFrom: "2024-01-01T00:00:00.000Z",
    dateTo: "2024-06-01T00:00:00.000Z",
    dataEraseAt: "2024-09-01T00:00:00.000Z",
    accessMode: "VIEW",
    frequencyUnit: "HOUR",
    frequencyValue: 1,
    frequencyRepeats: 0,
    hipId: null,
    careContexts: [],
    requesterName: "MediFlux",
    requesterIdentifierType: "REGNO",
    requesterIdentifierValue: "HIU-001",
    requesterIdentifierSystem: "https://hfr.abdm.gov.in",
  };
  const result = validateM3ConsentRequestInput(input, ["abdm", "sbx"]);
  assertEquals(result.ok, true);
});

Deno.test("m3: validateM3ConsentRequestInput rejects an invalid ABHA address", () => {
  const input = {
    hospitalId: "hosp-1",
    patientId: "patient-1",
    abhaAddress: "not-an-abha",
    purposeText: "Care Management",
    purposeCode: "CAREMGT",
    purposeRefUri: "https://abdm.gov.in/purposes/care-mgmt",
    hiTypes: ["DiagnosticReport"],
    dateFrom: "2024-01-01T00:00:00.000Z",
    dateTo: "2024-06-01T00:00:00.000Z",
    dataEraseAt: "2024-09-01T00:00:00.000Z",
    accessMode: "VIEW",
    frequencyUnit: "HOUR",
    frequencyValue: 1,
    frequencyRepeats: 0,
    hipId: null,
    careContexts: [],
    requesterName: "MediFlux",
    requesterIdentifierType: "REGNO",
    requesterIdentifierValue: "HIU-001",
    requesterIdentifierSystem: "https://hfr.abdm.gov.in",
  };
  const result = validateM3ConsentRequestInput(input, ["abdm", "sbx"]);
  assertEquals(result.ok, false);
  assert(result.errors.some((e) => e.includes("abhaAddress")), "expected abhaAddress error");
});

Deno.test("m3: validateM3ConsentRequestInput rejects an invalid date range", () => {
  const input = {
    hospitalId: "hosp-1",
    patientId: "patient-1",
    abhaAddress: "user@sbx",
    purposeText: "Care Management",
    purposeCode: "CAREMGT",
    purposeRefUri: "https://abdm.gov.in/purposes/care-mgmt",
    hiTypes: ["DiagnosticReport"],
    dateFrom: "2024-06-01T00:00:00.000Z",
    dateTo: "2024-01-01T00:00:00.000Z",
    dataEraseAt: "2024-09-01T00:00:00.000Z",
    accessMode: "VIEW",
    frequencyUnit: "HOUR",
    frequencyValue: 1,
    frequencyRepeats: 0,
    hipId: null,
    careContexts: [],
    requesterName: "MediFlux",
    requesterIdentifierType: "REGNO",
    requesterIdentifierValue: "HIU-001",
    requesterIdentifierSystem: "https://hfr.abdm.gov.in",
  };
  const result = validateM3ConsentRequestInput(input, ["abdm", "sbx"]);
  assertEquals(result.ok, false);
  assert(result.errors.some((e) => e.includes("dateFrom")), "expected dateFrom error");
});

Deno.test("m3: validateM3ConsentRequestInput rejects an invalid HI type", () => {
  const input = {
    hospitalId: "hosp-1",
    patientId: "patient-1",
    abhaAddress: "user@sbx",
    purposeText: "Care Management",
    purposeCode: "CAREMGT",
    purposeRefUri: "https://abdm.gov.in/purposes/care-mgmt",
    hiTypes: ["NotAHiType"],
    dateFrom: "2024-01-01T00:00:00.000Z",
    dateTo: "2024-06-01T00:00:00.000Z",
    dataEraseAt: "2024-09-01T00:00:00.000Z",
    accessMode: "VIEW",
    frequencyUnit: "HOUR",
    frequencyValue: 1,
    frequencyRepeats: 0,
    hipId: null,
    careContexts: [],
    requesterName: "MediFlux",
    requesterIdentifierType: "REGNO",
    requesterIdentifierValue: "HIU-001",
    requesterIdentifierSystem: "https://hfr.abdm.gov.in",
  };
  const result = validateM3ConsentRequestInput(input, ["abdm", "sbx"]);
  assertEquals(result.ok, false);
  assert(result.errors.some((e) => e.includes("HI type")), "expected HI type error");
});

Deno.test("m3: validateM3ConsentRequestInput rejects a missing purpose", () => {
  const input = {
    hospitalId: "hosp-1",
    patientId: "patient-1",
    abhaAddress: "user@sbx",
    purposeText: "",
    purposeCode: "CAREMGT",
    purposeRefUri: "https://abdm.gov.in/purposes/care-mgmt",
    hiTypes: ["DiagnosticReport"],
    dateFrom: "2024-01-01T00:00:00.000Z",
    dateTo: "2024-06-01T00:00:00.000Z",
    dataEraseAt: "2024-09-01T00:00:00.000Z",
    accessMode: "VIEW",
    frequencyUnit: "HOUR",
    frequencyValue: 1,
    frequencyRepeats: 0,
    hipId: null,
    careContexts: [],
    requesterName: "MediFlux",
    requesterIdentifierType: "REGNO",
    requesterIdentifierValue: "HIU-001",
    requesterIdentifierSystem: "https://hfr.abdm.gov.in",
  };
  const result = validateM3ConsentRequestInput(input, ["abdm", "sbx"]);
  assertEquals(result.ok, false);
  assert(result.errors.some((e) => e.includes("purpose")), "expected purpose error");
});

Deno.test("m3: validateM3ConsentRequestInput rejects an invalid frequency", () => {
  const input = {
    hospitalId: "hosp-1",
    patientId: "patient-1",
    abhaAddress: "user@sbx",
    purposeText: "Care Management",
    purposeCode: "CAREMGT",
    purposeRefUri: "https://abdm.gov.in/purposes/care-mgmt",
    hiTypes: ["DiagnosticReport"],
    dateFrom: "2024-01-01T00:00:00.000Z",
    dateTo: "2024-06-01T00:00:00.000Z",
    dataEraseAt: "2024-09-01T00:00:00.000Z",
    accessMode: "VIEW",
    frequencyUnit: "FORTNIGHT",
    frequencyValue: 1,
    frequencyRepeats: 0,
    hipId: null,
    careContexts: [],
    requesterName: "MediFlux",
    requesterIdentifierType: "REGNO",
    requesterIdentifierValue: "HIU-001",
    requesterIdentifierSystem: "https://hfr.abdm.gov.in",
  };
  const result = validateM3ConsentRequestInput(input, ["abdm", "sbx"]);
  assertEquals(result.ok, false);
  assert(result.errors.some((e) => e.includes("frequency")), "expected frequency error");
});

Deno.test("m3: buildM3ConsentInitBody matches the official V3 shape", () => {
  const body = buildM3ConsentInitBody({
    requestId: "req-1",
    timestamp: "2026-09-06T00:00:00.000Z",
    hiuId: "HIU-001",
    abhaAddress: "user@sbx",
    purposeText: "Care Management",
    purposeCode: "CAREMGT",
    purposeRefUri: "https://abdm.gov.in/purposes/care-mgmt",
    hiTypes: ["DiagnosticReport"],
    dateFrom: "2024-01-01T00:00:00.000Z",
    dateTo: "2024-06-01T00:00:00.000Z",
    dataEraseAt: "2024-09-01T00:00:00.000Z",
    accessMode: "VIEW",
    frequencyUnit: "HOUR",
    frequencyValue: 1,
    frequencyRepeats: 0,
    hipId: null,
    careContexts: [],
    requesterName: "MediFlux",
    requesterIdentifierType: "REGNO",
    requesterIdentifierValue: "HIU-001",
    requesterIdentifierSystem: "https://hfr.abdm.gov.in",
  });
  const consent = body["consent"] as Record<string, unknown>;
  assertEquals(consent["patient"], { id: "user@sbx" });
  assertEquals(consent["hiu"], { id: "HIU-001" });
  assertEquals(consent["hiTypes"], ["DiagnosticReport"]);
  assert(!("hip" in consent), "hip must be omitted when not requested");
  assert(!("careContexts" in consent), "careContexts must be omitted when empty");
  const permission = consent["permission"] as Record<string, unknown>;
  assertEquals(permission["accessMode"], "VIEW");
  assertEquals(permission["frequency"], { unit: "HOUR", value: 1, repeats: 0 });
});

Deno.test("m3: buildM3HealthInformationRequestBody matches the official V3 shape", () => {
  const body = buildM3HealthInformationRequestBody({
    requestId: "req-1",
    timestamp: "2026-09-06T00:00:00.000Z",
    consentId: "consent-1",
    dateFrom: "2024-01-01T00:00:00.000Z",
    dateTo: "2024-06-01T00:00:00.000Z",
    dataPushUrl: "https://cb.example/functions/v1/abdm-gateway/api/v3/hiu/health-information/transfer",
    keyMaterial: { cryptoAlg: "ECDH", curve: "curve25519" },
  });
  const hiRequest = body["hiRequest"] as Record<string, unknown>;
  assertEquals(hiRequest["consent"], { id: "consent-1" });
  assertEquals(hiRequest["dateRange"], { from: "2024-01-01T00:00:00.000Z", to: "2024-06-01T00:00:00.000Z" });
  assert(typeof hiRequest["dataPushUrl"] === "string", "dataPushUrl must be present");
});

Deno.test("m3: inbound consent callback validators accept official shapes", () => {
  const onInit = validateM3ConsentOnInit({
    response: { requestId: "req-1" },
    consentRequest: { id: "gateway-consent-1" },
  });
  assertEquals(onInit.ok, true);
  assertEquals(onInit.value?.consentRequestId, "gateway-consent-1");

  const onStatus = validateM3ConsentOnStatus({
    response: { requestId: "req-1" },
    consentRequest: {
      status: "GRANTED",
      consentArtefacts: [{ id: "consent-1", hipId: "HIP-001", careContextReference: ["cc-1"] }],
    },
  });
  assertEquals(onStatus.ok, true);
  assertEquals(onStatus.value?.status, "GRANTED");

  const notify = validateM3ConsentNotify({
    requestId: "cb-1",
    timestamp: "2026-09-06T00:00:00.000Z",
    notification: {
      consentRequestId: "gateway-consent-1",
      status: "GRANTED",
      consentArtefacts: [{ id: "consent-1", hipId: "HIP-001", careContextReference: ["cc-1"] }],
    },
  });
  assertEquals(notify.ok, true);
  assertEquals(notify.value?.consentArtefacts[0].id, "consent-1");

  const onFetch = validateM3ConsentOnFetch({
    response: { requestId: "cb-1" },
    consent: {
      status: "GRANTED",
      consentDetail: {
        consentId: "consent-1",
        patient: { id: "user@sbx" },
        hip: { id: "HIP-001" },
        hiu: { id: "HIU-001" },
        purpose: { text: "Care Management" },
        permission: { dateRange: { from: "2024-01-01", to: "2024-06-01" }, dataEraseAt: "2024-09-01" },
        careContexts: [{ careContextReference: "cc-1" }],
        hiTypes: ["DiagnosticReport"],
      },
    },
  });
  assertEquals(onFetch.ok, true);
  assertEquals(onFetch.value?.careContextReferences, ["cc-1"]);

  const onRequest = validateM3HealthInformationOnRequest({
    response: { requestId: "hi-req-1" },
    hiRequest: { transactionId: "txn-1", sessionStatus: "ACKNOWLEDGED" },
  });
  assertEquals(onRequest.ok, true);
  assertEquals(onRequest.value?.transactionId, "txn-1");
});

Deno.test("m3: inbound consent callback validators reject malformed bodies", () => {
  assertEquals(validateM3ConsentOnInit({}).ok, false);
  assertEquals(validateM3ConsentOnStatus({}).ok, false);
  assertEquals(validateM3ConsentNotify({}).ok, false);
  assertEquals(validateM3ConsentOnFetch({}).ok, false);
  assertEquals(validateM3HealthInformationOnRequest({}).ok, false);
});

Deno.test("m3: validateM3DataPush validates official entries and key material", () => {
  const valid = validateM3DataPush(dataPushBody());
  assertEquals(valid.ok, true);
  assertEquals(valid.value?.pageNumber, 0);
  assertEquals(valid.value?.entries.length, 1);

  const badBase64 = validateM3DataPush(dataPushBody({
    entries: [{ content: "!!!not-base64!!!", media: "application/fhir+json", checksum: "x", careContextReference: "cc-1" }],
  }));
  assertEquals(badBase64.ok, false);
  assert(badBase64.errors.some((e) => e.includes("base64")), "expected base64 error");

  const badMedia = validateM3DataPush(dataPushBody({
    entries: [{ content: b64("x"), media: "application/pdf", checksum: "x", careContextReference: "cc-1" }],
  }));
  assertEquals(badMedia.ok, false);
  assert(badMedia.errors.some((e) => e.includes("media")), "expected media error");

  const badPage = validateM3DataPush(dataPushBody({ pageNumber: 5, pageCount: 2 }));
  assertEquals(badPage.ok, false);

  const badKey = validateM3DataPush(dataPushBody({
    keyMaterial: { cryptoAlg: "RSA", curve: "curve25519" },
  }));
  assertEquals(badKey.ok, false);
  assert(badKey.errors.some((e) => e.includes("cryptoAlg")), "expected cryptoAlg error");
});

Deno.test("m3: validateM3KeyMaterial accepts the official ECDH curve25519 schema", () => {
  const valid = validateM3KeyMaterial({
    cryptoAlg: "ECDH",
    curve: "curve25519",
    dhPublicKey: { expiry: null, parameters: "Curve25519/32byte random key", keyValue: b64("public-key-bytes") },
    nonce: b64("nonce-bytes"),
  });
  assertEquals(valid.ok, true);

  const invalid = validateM3KeyMaterial({
    cryptoAlg: "RSA",
    curve: "curve25519",
    dhPublicKey: { expiry: null, parameters: null, keyValue: b64("public-key-bytes") },
    nonce: b64("nonce-bytes"),
  });
  assertEquals(invalid.ok, false);
  assertStringContains(invalid.error ?? "", "cryptoAlg");
});

Deno.test("m3: validateM3FhirPayload validates bundles and resources", () => {
  const bundle = validateM3FhirPayload({
    resourceType: "Bundle",
    type: "searchset",
    entry: [{ resource: { resourceType: "DiagnosticReport", id: "dr-1" } }],
  });
  assertEquals(bundle.ok, true);
  assertEquals(bundle.clinicalResources?.length, 1);

  const single = validateM3FhirPayload({ resourceType: "DiagnosticReport", id: "dr-1" });
  assertEquals(single.ok, true);

  assertEquals(validateM3FhirPayload(null).ok, false);
  assertEquals(validateM3FhirPayload({}).ok, false);
  assertEquals(validateM3FhirPayload({ resourceType: "UnknownResource", id: "x" }).ok, false);
  assertEquals(validateM3FhirPayload({ resourceType: "DiagnosticReport" }).ok, false);
});

Deno.test("m3: hiTypeForFhirResourceType maps official resource types", () => {
  assertEquals(hiTypeForFhirResourceType("DiagnosticReport"), "DiagnosticReport");
  assertEquals(hiTypeForFhirResourceType("MedicationRequest"), "Prescription");
  assertEquals(hiTypeForFhirResourceType("Encounter"), "OPConsultation");
  assertEquals(hiTypeForFhirResourceType("Organization"), null);
});

Deno.test("m3: callback subpath mapping covers every official V3 M3 path", () => {
  assertEquals(m3CallbackTypeForSubpath(V3_M3_CB_CONSENT_ON_INIT), "consentOnInit");
  assertEquals(m3CallbackTypeForSubpath(V3_M3_CB_CONSENT_ON_STATUS), "consentOnStatus");
  assertEquals(m3CallbackTypeForSubpath(V3_M3_CB_CONSENT_NOTIFY), "consentNotify");
  assertEquals(m3CallbackTypeForSubpath(V3_M3_CB_CONSENT_ON_FETCH), "consentOnFetch");
  assertEquals(m3CallbackTypeForSubpath(V3_M3_CB_HEALTH_INFORMATION_ON_REQUEST), "healthInformationOnRequest");
  assertEquals(isM3DataPushSubpath(V3_M3_DATA_PUSH_PATH), true);
  assertEquals(isM3DataPushSubpath("/api/v3/hiu/consent/request/notify"), false);
});

// ============================================================================
// 2. Consent request internal action
// ============================================================================

Deno.test("m3: consent request posts the official init body with X-HIU-ID", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  const deps = m3Deps(fetchImpl, stores);

  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "m3ConsentRequest", payload: consentPayload() }),
  });
  const res = await handleRequest(req, deps);
  assertEquals(res.status, 200);
  const resBody = await res.json() as Record<string, unknown>;
  assertEquals(resBody["status"], "submitted");
  assert(typeof resBody["requestId"] === "string", "requestId must be returned");

  const outbound = m3OutboundCalls(calls);
  assertEquals(outbound.length, 1);
  assertEquals(outbound[0].url, `https://dev.abdm.gov.in${V3_M3_CONSENT_INIT_PATH}`);
  assertEquals(outbound[0].method, "POST");
  assertEquals(outbound[0].headers.get(V3_M3_HIU_ID_HEADER), "HIU-001");
  const body = outbound[0].body as Record<string, unknown>;
  assertEquals((body["consent"] as Record<string, unknown>)["hiu"], { id: "HIU-001" });
  assertEquals(stores.consentRequestStore.rows.length, 1);
  assertEquals(stores.consentRequestStore.rows[0].status, "submitted");
});

Deno.test("m3: consent request rejects an invalid ABHA without any upstream call", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  const deps = m3Deps(fetchImpl, stores);
  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "m3ConsentRequest", payload: consentPayload({ abhaAddress: "bad" }) }),
  });
  const res = await handleRequest(req, deps);
  assertEquals(res.status, 400);
  const resBody = await res.json() as Record<string, unknown>;
  assertEquals(resBody["code"], M3_ERROR_CODES.INVALID_REQUEST);
  assertEquals(m3OutboundCalls(calls).length, 0);
});

Deno.test("m3: consent request rejects an invalid date range", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  const deps = m3Deps(fetchImpl, stores);
  const payload = consentPayload({
    dataFrom: "2025-06-01T00:00:00.000Z",
    dataTo: "2024-01-01T00:00:00.000Z",
  });
  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "m3ConsentRequest", payload }),
  });
  const res = await handleRequest(req, deps);
  assertEquals(res.status, 400);
  assertEquals(m3OutboundCalls(calls).length, 0);
});

Deno.test("m3: consent request rejects an invalid HI type", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  const deps = m3Deps(fetchImpl, stores);
  const payload = consentPayload({ hiTypes: ["DiagnosticReport", "NotAHiType"] });
  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "m3ConsentRequest", payload }),
  });
  const res = await handleRequest(req, deps);
  assertEquals(res.status, 400);
  assertEquals(m3OutboundCalls(calls).length, 0);
});

Deno.test("m3: consent request rejects a missing purpose", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  const deps = m3Deps(fetchImpl, stores);
  const payload = consentPayload({ purpose: "" });
  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "m3ConsentRequest", payload }),
  });
  const res = await handleRequest(req, deps);
  assertEquals(res.status, 400);
  assertEquals(m3OutboundCalls(calls).length, 0);
});

Deno.test("m3: consent request rejects a user without a hospital", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  const deps = m3Deps(fetchImpl, stores, { user: noHospitalUser() });
  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "m3ConsentRequest", payload: consentPayload() }),
  });
  const res = await handleRequest(req, deps);
  assertEquals(res.status, 403);
  assertEquals(m3OutboundCalls(calls).length, 0);
});

Deno.test("m3: consent request enforces the per-user rate limit", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  const limiter = { allow: () => false } as unknown as RequestDeps["m3RateLimiter"];
  const deps = m3Deps(fetchImpl, stores, { m3RateLimiter: limiter });
  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "m3ConsentRequest", payload: consentPayload() }),
  });
  const res = await handleRequest(req, deps);
  assertEquals(res.status, 429);
  assertEquals(m3OutboundCalls(calls).length, 0);
});

Deno.test("m3: consent request maps upstream failures to sanitized errors", async () => {
  for (const status of [400, 401, 403, 429, 500]) {
    const { fetchImpl, calls } = recordingFetch((url) => {
      if (url.includes("/api/hiecm/gateway/v3/sessions")) {
        return new Response(JSON.stringify({ accessToken: "t", expiresIn: 3600 }), { status: 200 });
      }
      return new Response(JSON.stringify({ error: { code: "UPSTREAM" } }), { status });
    });
    const stores = m3Stores();
    const deps = m3Deps(fetchImpl, stores);
    const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "m3ConsentRequest", payload: consentPayload() }),
    });
    const res = await handleRequest(req, deps);
    assert(res.status >= 400, `expected error status for upstream ${status}`);
    const resBody = await res.json() as Record<string, unknown>;
    assertEquals(resBody["code"], `ABDM_M3_CONSENT_UPSTREAM_${status}`);
    assert(!JSON.stringify(resBody).includes("v3-test-token"), "token must not leak");
    assert(!JSON.stringify(resBody).includes("sbx-client-secret"), "client secret must not leak");
    assertEquals(stores.consentRequestStore.rows[0].status, "failed");
    calls.length = 0;
  }
});

Deno.test("m3: consent request maps a network failure to a 502 sanitized error", async () => {
  const { fetchImpl, calls } = recordingFetch((url) => {
    if (url.includes("/api/hiecm/gateway/v3/sessions")) {
      return new Response(JSON.stringify({ accessToken: "t", expiresIn: 3600 }), { status: 200 });
    }
    throw new Error("network down clientSecret=leak");
  });
  const stores = m3Stores();
  const deps = m3Deps(fetchImpl, stores);
  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "m3ConsentRequest", payload: consentPayload() }),
  });
  const res = await handleRequest(req, deps);
  assertEquals(res.status, 502);
  const resBody = await res.json() as Record<string, unknown>;
  assertEquals(resBody["code"], "ABDM_M3_CONSENT_UPSTREAM_FAILED");
  assert(!JSON.stringify(resBody).includes("clientSecret"), "secret must be redacted");
  assertEquals(stores.consentRequestStore.rows[0].status, "failed");
  assertEquals(m3OutboundCalls(calls).length, 1);
});

Deno.test("m3: duplicate consent request is an idempotent replay", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  const existing: M3ConsentRequestRow = {
    hospital_id: "hosp-1",
    patient_id: "patient-1",
    request_id: "existing-req",
    consent_request_id: "gateway-consent-1",
    abha_address: "user@sbx",
    status: "submitted",
    purpose_text: "Care Management",
    purpose_code: "CAREMGT",
    hi_types: ["DiagnosticReport"],
    date_from: null,
    date_to: null,
    data_erase_at: null,
    frequency: {},
    hip_id: null,
    hiu_id: "HIU-001",
    error_code: null,
    error_message: null,
    submitted_at: null,
    responded_at: null,
  };
  const duplicateStore: M3ConsentRequestStore = {
    insert: async () => "duplicate",
    updateByRequestId: async () => {},
    findByRequestId: async () => existing,
    findByConsentRequestId: async () => existing,
  };
  const deps: RequestDeps = {
    env: envWithSecrets,
    fetchImpl,
    authenticate: async () => adminUser(),
    persistCallbackRow: async () => {},
    v3TokenCache: { current: null },
    hospitalAbdmSettingsStore: hospitalSettings,
    m3ConsentRequestStore: duplicateStore,
    m3ConsentStore: stores.consentStore,
    m3HiRequestStore: stores.hiRequestStore,
    m3DataPageStore: stores.dataPageStore,
    m3FhirRecordStore: stores.fhirRecordStore,
    m3KeypairProvider: null,
    m3PrivateKeyStore: stores.privateKeyStore,
    m3Decryptor: null,
    m3DataImportEnabled: false,
  };
  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "m3ConsentRequest", payload: consentPayload() }),
  });
  const res = await handleRequest(req, deps);
  assertEquals(res.status, 200);
  const resBody = await res.json() as Record<string, unknown>;
  assertEquals(resBody["consentRequestId"], "gateway-consent-1");
  assertEquals(m3OutboundCalls(calls).length, 0);
});

Deno.test("m3: consent status reports local state before the gateway returns a consent-request id", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentRequestStore.rows.push({
    hospital_id: "hosp-1",
    patient_id: "patient-1",
    request_id: "req-local",
    consent_request_id: null,
    abha_address: "user@sbx",
    status: "submitted",
    purpose_text: "Care Management",
    purpose_code: "CAREMGT",
    hi_types: [],
    date_from: null,
    date_to: null,
    data_erase_at: null,
    frequency: {},
    hip_id: null,
    hiu_id: "HIU-001",
    error_code: null,
    error_message: null,
    submitted_at: null,
    responded_at: null,
  });
  const deps = m3Deps(fetchImpl, stores);
  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "m3ConsentStatus", payload: { requestId: "req-local" } }),
  });
  const res = await handleRequest(req, deps);
  assertEquals(res.status, 200);
  const resBody = await res.json() as Record<string, unknown>;
  assertEquals(resBody["status"], "submitted");
  assertEquals(m3OutboundCalls(calls).length, 0);
});

Deno.test("m3: consent status posts the official status body once the gateway id is known", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentRequestStore.rows.push({
    hospital_id: "hosp-1",
    patient_id: "patient-1",
    request_id: "req-local",
    consent_request_id: "gateway-consent-1",
    abha_address: "user@sbx",
    status: "submitted",
    purpose_text: "Care Management",
    purpose_code: "CAREMGT",
    hi_types: [],
    date_from: null,
    date_to: null,
    data_erase_at: null,
    frequency: {},
    hip_id: null,
    hiu_id: "HIU-001",
    error_code: null,
    error_message: null,
    submitted_at: null,
    responded_at: null,
  });
  const deps = m3Deps(fetchImpl, stores);
  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "m3ConsentStatus", payload: { requestId: "req-local" } }),
  });
  const res = await handleRequest(req, deps);
  assertEquals(res.status, 200);
  const outbound = m3OutboundCalls(calls);
  assertEquals(outbound.length, 1);
  assertEquals(outbound[0].url, `https://dev.abdm.gov.in${V3_M3_CONSENT_STATUS_PATH}`);
  assertEquals((outbound[0].body as Record<string, unknown>)["consentRequestId"], "gateway-consent-1");
});

Deno.test("m3: consent status rejects an unknown request", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  const deps = m3Deps(fetchImpl, stores);
  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "m3ConsentStatus", payload: { requestId: "missing" } }),
  });
  const res = await handleRequest(req, deps);
  assertEquals(res.status, 404);
  assertEquals(m3OutboundCalls(calls).length, 0);
});

// ============================================================================
// 3. Consent callbacks (ABDM gateway -> HIU)
// ============================================================================

function callbackRequest(subpath: string, body: unknown, headers: Record<string, string> = {}): Request {
  return new Request(`https://x.supabase.co/functions/v1/abdm-gateway${subpath}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
}

Deno.test("m3: consent on-init callback persists the gateway consent-request id", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentRequestStore.rows.push({
    hospital_id: "hosp-1",
    patient_id: "patient-1",
    request_id: "req-1",
    consent_request_id: null,
    abha_address: "user@sbx",
    status: "submitted",
    purpose_text: null,
    purpose_code: null,
    hi_types: [],
    date_from: null,
    date_to: null,
    data_erase_at: null,
    frequency: {},
    hip_id: null,
    hiu_id: "HIU-001",
    error_code: null,
    error_message: null,
    submitted_at: null,
    responded_at: null,
  });
  const deps = m3Deps(fetchImpl, stores);
  const res = await handleRequest(callbackRequest(V3_M3_CB_CONSENT_ON_INIT, {
    response: { requestId: "req-1" },
    consentRequest: { id: "gateway-consent-1" },
  }, { "X-HIU-ID": "HIU-001" }), deps);
  assertEquals(res.status, 202);
  assertEquals(stores.consentRequestStore.rows[0].consent_request_id, "gateway-consent-1");
  assertEquals(stores.consentRequestStore.rows[0].status, "pending");
});

Deno.test("m3: consent on-status callback persists granted status", async () => {
  const { fetchImpl } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentRequestStore.rows.push({
    hospital_id: "hosp-1",
    patient_id: "patient-1",
    request_id: "req-1",
    consent_request_id: "gateway-consent-1",
    abha_address: "user@sbx",
    status: "pending",
    purpose_text: null,
    purpose_code: null,
    hi_types: [],
    date_from: null,
    date_to: null,
    data_erase_at: null,
    frequency: {},
    hip_id: null,
    hiu_id: "HIU-001",
    error_code: null,
    error_message: null,
    submitted_at: null,
    responded_at: null,
  });
  const deps = m3Deps(fetchImpl, stores);
  const res = await handleRequest(callbackRequest(V3_M3_CB_CONSENT_ON_STATUS, {
    response: { requestId: "req-1" },
    consentRequest: { status: "GRANTED", consentArtefacts: [] },
  }, { "X-HIU-ID": "HIU-001" }), deps);
  assertEquals(res.status, 202);
  assertEquals(stores.consentRequestStore.rows[0].status, "granted");
});

Deno.test("m3: consent notify callback grants, persists artefact and ACKs the gateway", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentRequestStore.rows.push({
    hospital_id: "hosp-1",
    patient_id: "patient-1",
    request_id: "req-1",
    consent_request_id: "gateway-consent-1",
    abha_address: "user@sbx",
    status: "pending",
    purpose_text: null,
    purpose_code: null,
    hi_types: [],
    date_from: null,
    date_to: null,
    data_erase_at: null,
    frequency: {},
    hip_id: null,
    hiu_id: "HIU-001",
    error_code: null,
    error_message: null,
    submitted_at: null,
    responded_at: null,
  });
  stores.consentStore.rows.push(seededConsent({ consent_id: "consent-1", patient_id: "patient-1" }));
  const deps = m3Deps(fetchImpl, stores);
  const res = await handleRequest(callbackRequest(V3_M3_CB_CONSENT_NOTIFY, {
    requestId: "cb-1",
    timestamp: "2026-09-06T00:00:00.000Z",
    notification: {
      consentRequestId: "gateway-consent-1",
      status: "GRANTED",
      consentArtefacts: [{ id: "consent-1", hipId: "HIP-001", careContextReference: ["cc-1"] }],
    },
  }, { "X-HIU-ID": "HIU-001" }), deps);
  assertEquals(res.status, 202);
  assertEquals(stores.consentRequestStore.rows[0].status, "granted");
  assertEquals((await stores.consentStore.findByConsentId("consent-1")) !== null, true);
  const outbound = m3OutboundCalls(calls);
  assertEquals(outbound.length, 1);
  assertStringContains(outbound[0].url, "/api/hiecm/consent/v3/request/hiu/on-notify");
  const ack = outbound[0].body as Record<string, unknown>;
  assertEquals(ack["acknowledgement"], [{ status: "OK", consentId: "consent-1" }]);
});

Deno.test("m3: consent notify denied/revoked/expired update the request state", async () => {
  for (const status of ["DENIED", "REVOKED", "EXPIRED"]) {
    const { fetchImpl } = m3GatewayFetch();
    const stores = m3Stores();
    stores.consentRequestStore.rows.push({
      hospital_id: "hosp-1",
      patient_id: "patient-1",
      request_id: "req-1",
      consent_request_id: "gateway-consent-1",
      abha_address: "user@sbx",
      status: "pending",
      purpose_text: null,
      purpose_code: null,
      hi_types: [],
      date_from: null,
      date_to: null,
      data_erase_at: null,
      frequency: {},
      hip_id: null,
      hiu_id: "HIU-001",
      error_code: null,
      error_message: null,
      submitted_at: null,
      responded_at: null,
    });
    const deps = m3Deps(fetchImpl, stores);
    const res = await handleRequest(callbackRequest(V3_M3_CB_CONSENT_NOTIFY, {
      requestId: "cb-1",
      timestamp: "2026-09-06T00:00:00.000Z",
      notification: {
        consentRequestId: "gateway-consent-1",
        status,
        consentArtefacts: [{ id: "consent-1", hipId: "HIP-001", careContextReference: ["cc-1"] }],
      },
    }, { "X-HIU-ID": "HIU-001" }), deps);
    assertEquals(res.status, 202);
    assertEquals(stores.consentRequestStore.rows[0].status, status.toLowerCase());
  }
});

Deno.test("m3: malformed consent callback returns 400", async () => {
  const { fetchImpl } = m3GatewayFetch();
  const stores = m3Stores();
  const deps = m3Deps(fetchImpl, stores);
  const res = await handleRequest(callbackRequest(V3_M3_CB_CONSENT_ON_INIT, {}, { "X-HIU-ID": "HIU-001" }), deps);
  assertEquals(res.status, 400);
  const body = await res.json() as Record<string, unknown>;
  assertEquals((body["error"] as Record<string, unknown>)["code"], M3_ERROR_CODES.INVALID_REQUEST);
});

Deno.test("m3: unknown consent notify request is acknowledged without failing", async () => {
  const { fetchImpl } = m3GatewayFetch();
  const stores = m3Stores();
  const deps = m3Deps(fetchImpl, stores);
  const res = await handleRequest(callbackRequest(V3_M3_CB_CONSENT_NOTIFY, {
    requestId: "cb-1",
    timestamp: "2026-09-06T00:00:00.000Z",
    notification: {
      consentRequestId: "unknown-gateway-id",
      status: "GRANTED",
      consentArtefacts: [{ id: "consent-1" }],
    },
  }, { "X-HIU-ID": "HIU-001" }), deps);
  assertEquals(res.status, 202);
});

Deno.test("m3: duplicate consent notify callback is an idempotent replay", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentRequestStore.rows.push({
    hospital_id: "hosp-1",
    patient_id: "patient-1",
    request_id: "req-1",
    consent_request_id: "gateway-consent-1",
    abha_address: "user@sbx",
    status: "pending",
    purpose_text: null,
    purpose_code: null,
    hi_types: [],
    date_from: null,
    date_to: null,
    data_erase_at: null,
    frequency: {},
    hip_id: null,
    hiu_id: "HIU-001",
    error_code: null,
    error_message: null,
    submitted_at: null,
    responded_at: null,
  });
  stores.consentStore.rows.push(seededConsent({ consent_id: "consent-1", patient_id: "patient-1" }));
  const deps = m3Deps(fetchImpl, stores);
  const body = {
    requestId: "cb-1",
    timestamp: "2026-09-06T00:00:00.000Z",
    notification: {
      consentRequestId: "gateway-consent-1",
      status: "GRANTED",
      consentArtefacts: [{ id: "consent-1", hipId: "HIP-001", careContextReference: ["cc-1"] }],
    },
  };
  const req1 = callbackRequest(V3_M3_CB_CONSENT_NOTIFY, body, { "X-HIU-ID": "HIU-001" });
  const req2 = callbackRequest(V3_M3_CB_CONSENT_NOTIFY, body, { "X-HIU-ID": "HIU-001" });
  assertEquals((await handleRequest(req1, deps)).status, 202);
  assertEquals((await handleRequest(req2, deps)).status, 202);
  assertEquals(stores.consentRequestStore.rows[0].status, "granted");
  assertEquals(stores.consentStore.rows.length, 1);
});

Deno.test("m3: consent callback with an unresolved X-HIU-ID returns 404", async () => {
  const { fetchImpl } = m3GatewayFetch();
  const stores = m3Stores();
  const deps = m3Deps(fetchImpl, stores);
  const res = await handleRequest(callbackRequest(V3_M3_CB_CONSENT_ON_INIT, {
    response: { requestId: "req-1" },
    consentRequest: { id: "gateway-consent-1" },
  }, { "X-HIU-ID": "UNKNOWN-HIU" }), deps);
  assertEquals(res.status, 404);
});

Deno.test("m3: consent on-fetch callback persists the full artefact", async () => {
  const { fetchImpl } = m3GatewayFetch();
  const stores = m3Stores();
  const deps = m3Deps(fetchImpl, stores);
  const res = await handleRequest(callbackRequest(V3_M3_CB_CONSENT_ON_FETCH, {
    response: { requestId: "cb-1" },
    consent: {
      status: "GRANTED",
      consentDetail: {
        consentId: "consent-2",
        patient: { id: "user@sbx" },
        hip: { id: "HIP-001" },
        hiu: { id: "HIU-001" },
        purpose: { text: "Care Management" },
        permission: {
          dateRange: { from: "2024-01-01T00:00:00.000Z", to: "2024-06-01T00:00:00.000Z" },
          dataEraseAt: "2024-09-01T00:00:00.000Z",
        },
        careContexts: [{ careContextReference: "cc-1" }],
        hiTypes: ["DiagnosticReport"],
      },
    },
  }, { "X-HIU-ID": "HIU-001" }), deps);
  assertEquals(res.status, 202);
  const saved = await stores.consentStore.findByConsentId("consent-2");
  assertEquals(saved?.status, "granted");
  assertEquals(saved?.hi_types, ["DiagnosticReport"]);
  assertEquals(saved?.care_context_references, ["cc-1"]);
});

Deno.test("m3: health-information on-request callback binds the transaction id", async () => {
  const { fetchImpl } = m3GatewayFetch();
  const stores = m3Stores();
  stores.hiRequestStore.rows.push(seededHiRequest({ transaction_id: null }));
  const deps = m3Deps(fetchImpl, stores);
  const res = await handleRequest(callbackRequest(V3_M3_CB_HEALTH_INFORMATION_ON_REQUEST, {
    response: { requestId: "hi-req-1" },
    hiRequest: { transactionId: "txn-1", sessionStatus: "ACKNOWLEDGED" },
  }, { "X-HIU-ID": "HIU-001" }), deps);
  assertEquals(res.status, 202);
  assertEquals(stores.hiRequestStore.rows[0].transaction_id, "txn-1");
  assertEquals(stores.hiRequestStore.rows[0].status, M3_HI_REQUEST_STATUS.WAITING_FOR_DATA);
});

Deno.test("m3: health-information on-request callback for an unknown request ACKs without failure", async () => {
  const { fetchImpl } = m3GatewayFetch();
  const stores = m3Stores();
  const deps = m3Deps(fetchImpl, stores);
  const res = await handleRequest(callbackRequest(V3_M3_CB_HEALTH_INFORMATION_ON_REQUEST, {
    response: { requestId: "unknown" },
    hiRequest: { transactionId: "txn-1", sessionStatus: "ACKNOWLEDGED" },
  }, { "X-HIU-ID": "HIU-001" }), deps);
  assertEquals(res.status, 202);
});

// ============================================================================
// 4. Health-information request internal action
// ============================================================================

Deno.test("m3: health-information request stays gated while data import is disabled", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentStore.rows.push(seededConsent());
  const deps = m3Deps(fetchImpl, stores);
  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "m3HealthInformationRequest", payload: { consentId: "consent-1" } }),
  });
  const res = await handleRequest(req, deps);
  assertEquals(res.status, 501);
  const resBody = await res.json() as Record<string, unknown>;
  assertEquals(resBody["code"], M3_ERROR_CODES.DATA_IMPORT_GATED);
  assertEquals(m3OutboundCalls(calls).length, 0);
});

Deno.test("m3: health-information request posts the official body when import is enabled", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentStore.rows.push(seededConsent());
  const deps = m3Deps(fetchImpl, stores, {
    dataImportEnabled: true,
    keypairProvider: mockKeypairProvider,
    decryptor: mockDecryptor(FHIR_DIAGNOSTIC_REPORT),
  });
  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "m3HealthInformationRequest", payload: { consentId: "consent-1" } }),
  });
  const res = await handleRequest(req, deps);
  assertEquals(res.status, 200);
  const resBody = await res.json() as Record<string, unknown>;
  assertEquals(resBody["status"], "request_submitted");

  const outbound = m3OutboundCalls(calls);
  assertEquals(outbound.length, 1);
  assertEquals(outbound[0].url, `https://dev.abdm.gov.in${V3_M3_HEALTH_INFORMATION_REQUEST_PATH}`);
  assertEquals(outbound[0].headers.get(V3_M3_HIU_ID_HEADER), "HIU-001");
  const body = outbound[0].body as Record<string, unknown>;
  const hiRequest = body["hiRequest"] as Record<string, unknown>;
  assertEquals((hiRequest["consent"] as Record<string, unknown>)["id"], "consent-1");
  assertStringContains(String(hiRequest["dataPushUrl"]), V3_M3_DATA_PUSH_PATH);
  const keyMaterial = hiRequest["keyMaterial"] as Record<string, unknown>;
  assertEquals(keyMaterial["cryptoAlg"], "ECDH");
  assertEquals(keyMaterial["curve"], "curve25519");
  assert(!JSON.stringify(keyMaterial).includes("private"), "private key must never leave the server");
  assertEquals(stores.hiRequestStore.rows.length, 1);
  assertEquals(stores.privateKeyStore.keys.has(stores.hiRequestStore.rows[0].request_id), true);
});

Deno.test("m3: health-information request rejects an expired consent", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  const past = new Date(Date.now() - 60 * 24 * 3600 * 1000).toISOString();
  stores.consentStore.rows.push(seededConsent({
    status: "granted",
    data_to: past,
    expires_at: past,
  }));
  const deps = m3Deps(fetchImpl, stores, {
    dataImportEnabled: true,
    keypairProvider: mockKeypairProvider,
    decryptor: mockDecryptor(FHIR_DIAGNOSTIC_REPORT),
  });
  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "m3HealthInformationRequest", payload: { consentId: "consent-1" } }),
  });
  const res = await handleRequest(req, deps);
  assertEquals(res.status, 400);
  const resBody = await res.json() as Record<string, unknown>;
  assertEquals(resBody["code"], M3_ERROR_CODES.CONSENT_EXPIRED);
  assertEquals(m3OutboundCalls(calls).length, 0);
});

Deno.test("m3: health-information request rejects a revoked consent", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentStore.rows.push(seededConsent({ status: "revoked" }));
  const deps = m3Deps(fetchImpl, stores, {
    dataImportEnabled: true,
    keypairProvider: mockKeypairProvider,
    decryptor: mockDecryptor(FHIR_DIAGNOSTIC_REPORT),
  });
  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "m3HealthInformationRequest", payload: { consentId: "consent-1" } }),
  });
  const res = await handleRequest(req, deps);
  assertEquals(res.status, 400);
  assertEquals(m3OutboundCalls(calls).length, 0);
});

Deno.test("m3: health-information request fails safe on upstream rejection and deletes the private key", async () => {
  const { fetchImpl } = recordingFetch((url) => {
    if (url.includes("/api/hiecm/gateway/v3/sessions")) {
      return new Response(JSON.stringify({ accessToken: "t", expiresIn: 3600 }), { status: 200 });
    }
    return new Response(JSON.stringify({ error: { code: "BAD" } }), { status: 400 });
  });
  const stores = m3Stores();
  stores.consentStore.rows.push(seededConsent());
  const deps = m3Deps(fetchImpl, stores, {
    dataImportEnabled: true,
    keypairProvider: mockKeypairProvider,
    decryptor: mockDecryptor(FHIR_DIAGNOSTIC_REPORT),
  });
  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "m3HealthInformationRequest", payload: { consentId: "consent-1" } }),
  });
  const res = await handleRequest(req, deps);
  assertEquals(res.status, 400);
  assertEquals(stores.hiRequestStore.rows.length, 1);
  assertEquals(stores.hiRequestStore.rows[0].status, M3_HI_REQUEST_STATUS.FAILED_SAFE);
  assertEquals(stores.privateKeyStore.keys.size, 0);
});

// ============================================================================
// 5. Encrypted data push (HIP -> HIU)
// ============================================================================

function dataPushDeps(options: {
  fetchImpl: typeof fetch;
  stores: M3Stores;
  decryptor?: M3Decryptor | null;
  dataImportEnabled?: boolean;
}): RequestDeps {
  return {
    env: envWithSecrets,
    fetchImpl: options.fetchImpl,
    authenticate: async () => adminUser(),
    persistCallbackRow: async () => {},
    v3TokenCache: { current: null },
    hospitalAbdmSettingsStore: hospitalSettings,
    m2HospitalStore: inMemoryHospitalStore,
    m3ConsentRequestStore: options.stores.consentRequestStore,
    m3ConsentStore: options.stores.consentStore,
    m3HiRequestStore: options.stores.hiRequestStore,
    m3DataPageStore: options.stores.dataPageStore,
    m3FhirRecordStore: options.stores.fhirRecordStore,
    m3KeypairProvider: mockKeypairProvider,
    m3PrivateKeyStore: options.stores.privateKeyStore,
    m3Decryptor: options.decryptor ?? null,
    m3DataImportEnabled: options.dataImportEnabled === true,
  };
}

Deno.test("m3: single-page data push decrypts, persists FHIR and notifies the gateway", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentStore.rows.push(seededConsent());
  stores.hiRequestStore.rows.push(seededHiRequest());
  await stores.privateKeyStore.save(
    "hi-req-1",
    b64("hiu-private-key"),
    b64("hiu-nonce"),
    new Date(Date.now() + 86400000).toISOString(),
  );
  const deps = dataPushDeps({
    fetchImpl,
    stores,
    dataImportEnabled: true,
    decryptor: mockDecryptor(FHIR_DIAGNOSTIC_REPORT),
  });
  const res = await handleRequest(callbackRequest(V3_M3_DATA_PUSH_PATH, dataPushBody()), deps);
  assertEquals(res.status, 200);
  assertEquals(stores.dataPageStore.rows.length, 1);
  assertEquals(stores.fhirRecordStore.rows.length, 1);
  assertEquals(stores.fhirRecordStore.rows[0].resource_type, "DiagnosticReport");
  assertEquals(stores.fhirRecordStore.rows[0].hospital_id, "hosp-1");
  assertEquals(stores.hiRequestStore.rows[0].status, M3_HI_REQUEST_STATUS.COMPLETED);
  const outbound = m3OutboundCalls(calls);
  assertEquals(outbound.length, 1);
  assertEquals(outbound[0].url, `https://dev.abdm.gov.in${V3_M3_HEALTH_INFORMATION_NOTIFY_PATH}`);
  const notification = (outbound[0].body as Record<string, unknown>)["notification"] as Record<string, unknown>;
  assertEquals((notification["statusNotification"] as Record<string, unknown>)["sessionStatus"], "TRANSFERRED");
});

Deno.test("m3: multi-page data push waits for all pages and accepts out-of-order receipt", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentStore.rows.push(seededConsent());
  stores.hiRequestStore.rows.push(seededHiRequest());
  await stores.privateKeyStore.save(
    "hi-req-1",
    b64("hiu-private-key"),
    b64("hiu-nonce"),
    new Date(Date.now() + 86400000).toISOString(),
  );
  const deps = dataPushDeps({
    fetchImpl,
    stores,
    dataImportEnabled: true,
    decryptor: pageAwareDecryptor(),
  });
  const page1 = handleRequest(callbackRequest(V3_M3_DATA_PUSH_PATH, dataPushBody({
    pageNumber: 1,
    pageCount: 2,
    entries: [{
      content: b64("page-1-encrypted"),
      media: "application/fhir+json",
      checksum: b64("checksum"),
      careContextReference: "cc-1",
    }],
  })), deps);
  assertEquals((await page1).status, 200);
  assertEquals(stores.fhirRecordStore.rows.length, 0, "must not finalize before all pages arrive");

  const page0 = handleRequest(callbackRequest(V3_M3_DATA_PUSH_PATH, dataPushBody({
    pageNumber: 0,
    pageCount: 2,
  })), deps);
  assertEquals((await page0).status, 200);
  assertEquals(stores.dataPageStore.rows.length, 2);
  assertEquals(stores.hiRequestStore.rows[0].status, M3_HI_REQUEST_STATUS.COMPLETED);
  assertEquals(stores.fhirRecordStore.rows.length, 2);
  assertEquals(m3OutboundCalls(calls).length, 1);
});

Deno.test("m3: duplicate data page is an idempotent replay", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentStore.rows.push(seededConsent());
  stores.hiRequestStore.rows.push(seededHiRequest());
  await stores.privateKeyStore.save(
    "hi-req-1",
    b64("hiu-private-key"),
    b64("hiu-nonce"),
    new Date(Date.now() + 86400000).toISOString(),
  );
  const deps = dataPushDeps({
    fetchImpl,
    stores,
    dataImportEnabled: true,
    decryptor: mockDecryptor(FHIR_DIAGNOSTIC_REPORT),
  });
  const body = dataPushBody();
  const req1 = callbackRequest(V3_M3_DATA_PUSH_PATH, body);
  const req2 = callbackRequest(V3_M3_DATA_PUSH_PATH, body);
  assertEquals((await handleRequest(req1, deps)).status, 200);
  assertEquals((await handleRequest(req2, deps)).status, 200);
  assertEquals(stores.dataPageStore.rows.length, 1);
  assertEquals(stores.fhirRecordStore.rows.length, 1);
  assertEquals(m3OutboundCalls(calls).length, 1);
});

Deno.test("m3: data push rejects an inconsistent pageCount", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentStore.rows.push(seededConsent());
  stores.hiRequestStore.rows.push(seededHiRequest({ expected_pages: 3 }));
  const deps = dataPushDeps({
    fetchImpl,
    stores,
    dataImportEnabled: true,
    decryptor: mockDecryptor(FHIR_DIAGNOSTIC_REPORT),
  });
  const res = await handleRequest(callbackRequest(V3_M3_DATA_PUSH_PATH, dataPushBody({ pageCount: 2 })), deps);
  assertEquals(res.status, 400);
  assertEquals(m3OutboundCalls(calls).length, 0);
});

Deno.test("m3: data push rejects an unknown transaction", async () => {
  const { fetchImpl } = m3GatewayFetch();
  const stores = m3Stores();
  const deps = dataPushDeps({ fetchImpl, stores, dataImportEnabled: true, decryptor: mockDecryptor(FHIR_DIAGNOSTIC_REPORT) });
  const res = await handleRequest(callbackRequest(V3_M3_DATA_PUSH_PATH, dataPushBody({ transactionId: "unknown" })), deps);
  assertEquals(res.status, 400);
  const body = await res.json() as Record<string, unknown>;
  assertEquals((body["error"] as Record<string, unknown>)["code"], M3_ERROR_CODES.TRANSACTION_UNKNOWN);
});

Deno.test("m3: data push rejects a transaction whose consent is no longer valid", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentStore.rows.push(seededConsent({ status: "revoked" }));
  stores.hiRequestStore.rows.push(seededHiRequest());
  const deps = dataPushDeps({
    fetchImpl,
    stores,
    dataImportEnabled: true,
    decryptor: mockDecryptor(FHIR_DIAGNOSTIC_REPORT),
  });
  const res = await handleRequest(callbackRequest(V3_M3_DATA_PUSH_PATH, dataPushBody()), deps);
  assertEquals(res.status, 400);
  assertEquals(stores.hiRequestStore.rows[0].status, M3_HI_REQUEST_STATUS.FAILED_SAFE);
  assertEquals(m3OutboundCalls(calls).length, 0);
});

Deno.test("m3: data push rejects an oversized payload with 413", async () => {
  const { fetchImpl } = m3GatewayFetch();
  const stores = m3Stores();
  const deps = dataPushDeps({ fetchImpl, stores, dataImportEnabled: true, decryptor: mockDecryptor(FHIR_DIAGNOSTIC_REPORT) });
  const huge = "A".repeat(300_000);
  const body = dataPushBody({ entries: [{ content: huge, media: "application/fhir+json", checksum: "x", careContextReference: "cc-1" }] });
  const req = new Request(`https://x.supabase.co/functions/v1/abdm-gateway${V3_M3_DATA_PUSH_PATH}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Content-Length": String(JSON.stringify(body).length) },
    body: JSON.stringify(body),
  });
  const res = await handleRequest(req, deps);
  assertEquals(res.status, 413);
});

Deno.test("m3: data push rejects malformed base64 content", async () => {
  const { fetchImpl } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentStore.rows.push(seededConsent());
  stores.hiRequestStore.rows.push(seededHiRequest());
  const deps = dataPushDeps({ fetchImpl, stores, dataImportEnabled: true, decryptor: mockDecryptor(FHIR_DIAGNOSTIC_REPORT) });
  const res = await handleRequest(callbackRequest(V3_M3_DATA_PUSH_PATH, dataPushBody({
    entries: [{ content: "!!!", media: "application/fhir+json", checksum: "x", careContextReference: "cc-1" }],
  })), deps);
  assertEquals(res.status, 400);
});

Deno.test("m3: data push rejects an invalid media type", async () => {
  const { fetchImpl } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentStore.rows.push(seededConsent());
  stores.hiRequestStore.rows.push(seededHiRequest());
  const deps = dataPushDeps({ fetchImpl, stores, dataImportEnabled: true, decryptor: mockDecryptor(FHIR_DIAGNOSTIC_REPORT) });
  const res = await handleRequest(callbackRequest(V3_M3_DATA_PUSH_PATH, dataPushBody({
    entries: [{ content: b64("x"), media: "text/plain", checksum: "x", careContextReference: "cc-1" }],
  })), deps);
  assertEquals(res.status, 400);
});

Deno.test("m3: data push rejects a care-context outside the consent", async () => {
  const { fetchImpl } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentStore.rows.push(seededConsent());
  stores.hiRequestStore.rows.push(seededHiRequest());
  const deps = dataPushDeps({ fetchImpl, stores, dataImportEnabled: true, decryptor: mockDecryptor(FHIR_DIAGNOSTIC_REPORT) });
  const res = await handleRequest(callbackRequest(V3_M3_DATA_PUSH_PATH, dataPushBody({
    entries: [{ content: b64("x"), media: "application/fhir+json", checksum: "x", careContextReference: "cc-other" }],
  })), deps);
  assertEquals(res.status, 400);
  const body = await res.json() as Record<string, unknown>;
  assertEquals((body["error"] as Record<string, unknown>)["code"], M3_ERROR_CODES.CONSENT_INVALID);
});

Deno.test("m3: data push rejects invalid key material", async () => {
  const { fetchImpl } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentStore.rows.push(seededConsent());
  stores.hiRequestStore.rows.push(seededHiRequest());
  const deps = dataPushDeps({ fetchImpl, stores, dataImportEnabled: true, decryptor: mockDecryptor(FHIR_DIAGNOSTIC_REPORT) });
  const res = await handleRequest(callbackRequest(V3_M3_DATA_PUSH_PATH, dataPushBody({
    keyMaterial: { cryptoAlg: "RSA" },
  })), deps);
  assertEquals(res.status, 400);
});

Deno.test("m3: data push fails safe and notifies FAILED when decryption is unavailable", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentStore.rows.push(seededConsent());
  stores.hiRequestStore.rows.push(seededHiRequest());
  const deps = dataPushDeps({
    fetchImpl,
    stores,
    dataImportEnabled: true,
    decryptor: null,
  });
  const res = await handleRequest(callbackRequest(V3_M3_DATA_PUSH_PATH, dataPushBody()), deps);
  assertEquals(res.status, 200);
  assertEquals(stores.hiRequestStore.rows[0].status, M3_HI_REQUEST_STATUS.FAILED_SAFE);
  assertEquals(stores.hiRequestStore.rows[0].error_code, M3_ERROR_CODES.DECRYPTION_UNAVAILABLE);
  const outbound = m3OutboundCalls(calls);
  assertEquals(outbound.length, 1);
  const notification = (outbound[0].body as Record<string, unknown>)["notification"] as Record<string, unknown>;
  assertEquals((notification["statusNotification"] as Record<string, unknown>)["sessionStatus"], "FAILED");
});

Deno.test("m3: data push fails safe when the decryptor reports a crypto failure", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentStore.rows.push(seededConsent());
  stores.hiRequestStore.rows.push(seededHiRequest());
  await stores.privateKeyStore.save(
    "hi-req-1",
    b64("hiu-private-key"),
    b64("hiu-nonce"),
    new Date(Date.now() + 86400000).toISOString(),
  );
  const deps = dataPushDeps({
    fetchImpl,
    stores,
    dataImportEnabled: true,
    decryptor: failingDecryptor("ABDM_M3_AUTH_TAG_FAILURE", "auth tag mismatch"),
  });
  const res = await handleRequest(callbackRequest(V3_M3_DATA_PUSH_PATH, dataPushBody()), deps);
  assertEquals(res.status, 200);
  assertEquals(stores.hiRequestStore.rows[0].status, M3_HI_REQUEST_STATUS.FAILED_SAFE);
  assertEquals(stores.hiRequestStore.rows[0].error_code, "ABDM_M3_AUTH_TAG_FAILURE");
  assertEquals(stores.fhirRecordStore.rows.length, 0);
  const outbound = m3OutboundCalls(calls);
  assertEquals(outbound.length, 1);
});

Deno.test("m3: data push fails safe when the decrypted payload is malformed JSON", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentStore.rows.push(seededConsent());
  stores.hiRequestStore.rows.push(seededHiRequest());
  await stores.privateKeyStore.save(
    "hi-req-1",
    b64("hiu-private-key"),
    b64("hiu-nonce"),
    new Date(Date.now() + 86400000).toISOString(),
  );
  const deps = dataPushDeps({
    fetchImpl,
    stores,
    dataImportEnabled: true,
    decryptor: mockDecryptor("not-json"),
  });
  const res = await handleRequest(callbackRequest(V3_M3_DATA_PUSH_PATH, dataPushBody()), deps);
  assertEquals(res.status, 200);
  assertEquals(stores.hiRequestStore.rows[0].status, M3_HI_REQUEST_STATUS.FAILED_SAFE);
  assertEquals(stores.hiRequestStore.rows[0].error_code, M3_ERROR_CODES.FHIR_INVALID);
  assertEquals(m3OutboundCalls(calls).length, 1);
});

Deno.test("m3: data push fails safe on an unsupported FHIR resource type", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentStore.rows.push(seededConsent());
  stores.hiRequestStore.rows.push(seededHiRequest());
  await stores.privateKeyStore.save(
    "hi-req-1",
    b64("hiu-private-key"),
    b64("hiu-nonce"),
    new Date(Date.now() + 86400000).toISOString(),
  );
  const deps = dataPushDeps({
    fetchImpl,
    stores,
    dataImportEnabled: true,
    decryptor: mockDecryptor(JSON.stringify({ resourceType: "UnknownResource", id: "x" })),
  });
  const res = await handleRequest(callbackRequest(V3_M3_DATA_PUSH_PATH, dataPushBody()), deps);
  assertEquals(res.status, 200);
  assertEquals(stores.hiRequestStore.rows[0].status, M3_HI_REQUEST_STATUS.FAILED_SAFE);
  assertEquals(stores.fhirRecordStore.rows.length, 0);
  assertEquals(m3OutboundCalls(calls).length, 1);
});

Deno.test("m3: duplicate FHIR records across pages are never inserted twice", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentStore.rows.push(seededConsent());
  stores.hiRequestStore.rows.push(seededHiRequest());
  await stores.privateKeyStore.save(
    "hi-req-1",
    b64("hiu-private-key"),
    b64("hiu-nonce"),
    new Date(Date.now() + 86400000).toISOString(),
  );
  const deps = dataPushDeps({
    fetchImpl,
    stores,
    dataImportEnabled: true,
    decryptor: mockDecryptor(FHIR_DIAGNOSTIC_REPORT),
  });
  const page0 = await handleRequest(callbackRequest(V3_M3_DATA_PUSH_PATH, dataPushBody({
    pageNumber: 0,
    pageCount: 2,
  })), deps);
  assertEquals(page0.status, 200);
  const page1 = await handleRequest(callbackRequest(V3_M3_DATA_PUSH_PATH, dataPushBody({
    pageNumber: 1,
    pageCount: 2,
  })), deps);
  assertEquals(page1.status, 200);
  assertEquals(stores.fhirRecordStore.rows.length, 1, "duplicate resource must be deduplicated");
  assertEquals(stores.hiRequestStore.rows[0].status, M3_HI_REQUEST_STATUS.COMPLETED);
  assertEquals(m3OutboundCalls(calls).length, 1);
});

// ============================================================================
// 6. Decryption abstraction + security guarantees
// ============================================================================

Deno.test("m3: unavailable decryptor returns the specific safe error", async () => {
  const decryptor = unavailableM3Decryptor();
  assertEquals(decryptor.available, false);
  const result = await decryptor.decrypt({
    encryptedContent: b64("x"),
    receiverPrivateKey: b64("private"),
    receiverNonce: b64("nonce"),
    senderKeyMaterial: {
      cryptoAlg: "ECDH",
      curve: "curve25519",
      dhPublicKey: { expiry: null, parameters: null, keyValue: b64("pub") },
      nonce: b64("nonce"),
    },
    transactionContext: "txn-1",
  });
  assertEquals(result.ok, false);
  assertEquals(result.code, M3_ERROR_CODES.DECRYPTION_UNAVAILABLE);
});

Deno.test("m3: live import stays gated when the decryptor is unavailable", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentStore.rows.push(seededConsent());
  stores.hiRequestStore.rows.push(seededHiRequest());
  await stores.privateKeyStore.save(
    "hi-req-1",
    b64("hiu-private-key"),
    b64("hiu-nonce"),
    new Date(Date.now() + 86400000).toISOString(),
  );
  const deps = dataPushDeps({ fetchImpl, stores, dataImportEnabled: false, decryptor: null });
  const res = await handleRequest(callbackRequest(V3_M3_DATA_PUSH_PATH, dataPushBody()), deps);
  assertEquals(res.status, 200);
  assertEquals(stores.hiRequestStore.rows[0].status, M3_HI_REQUEST_STATUS.FAILED_SAFE);
  assertEquals(stores.hiRequestStore.rows[0].error_code, M3_ERROR_CODES.DATA_IMPORT_GATED);
  assertEquals(stores.fhirRecordStore.rows.length, 0);
  assertEquals(m3OutboundCalls(calls).length, 1);
});

Deno.test("m3: responses never leak tokens, secrets, private keys or encrypted content", async () => {
  const { fetchImpl } = recordingFetch((url) => {
    if (url.includes("/api/hiecm/gateway/v3/sessions")) {
      return new Response(JSON.stringify({ accessToken: "v3-secret-token", expiresIn: 3600 }), { status: 200 });
    }
    return new Response(JSON.stringify({ error: { message: "clientSecret=should-not-leak" } }), { status: 401 });
  });
  const stores = m3Stores();
  const deps = m3Deps(fetchImpl, stores);
  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "m3ConsentRequest", payload: consentPayload() }),
  });
  const res = await handleRequest(req, deps);
  const text = await res.text();
  assert(!text.includes("v3-secret-token"), "access token must not leak");
  assert(!text.includes("clientSecret"), "client secret must not leak");
  assert(!text.includes("should-not-leak"), "raw upstream error must not leak");
});

Deno.test("m3: stored key material never contains a private key", async () => {
  const { fetchImpl } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentStore.rows.push(seededConsent());
  const deps = m3Deps(fetchImpl, stores, {
    dataImportEnabled: true,
    keypairProvider: mockKeypairProvider,
    decryptor: mockDecryptor(FHIR_DIAGNOSTIC_REPORT),
  });
  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "m3HealthInformationRequest", payload: { consentId: "consent-1" } }),
  });
  await handleRequest(req, deps);
  const stored = JSON.stringify(stores.hiRequestStore.rows[0].key_material);
  assert(!stored.includes("private"), "private key must not be persisted in key_material");
});

Deno.test("m3: processM3DataPush preserves checksum metadata without inventing verification", async () => {
  const { fetchImpl } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentStore.rows.push(seededConsent());
  stores.hiRequestStore.rows.push(seededHiRequest());
  await stores.privateKeyStore.save(
    "hi-req-1",
    b64("hiu-private-key"),
    b64("hiu-nonce"),
    new Date(Date.now() + 86400000).toISOString(),
  );
  const deps = dataPushDeps({
    fetchImpl,
    stores,
    dataImportEnabled: true,
    decryptor: mockDecryptor(FHIR_DIAGNOSTIC_REPORT),
  });
  await handleRequest(callbackRequest(V3_M3_DATA_PUSH_PATH, dataPushBody()), deps);
  assertEquals(stores.dataPageStore.rows[0].checksum_metadata.length, 1);
  assertEquals(stores.dataPageStore.rows[0].checksum_metadata[0]["checksum"], b64("checksum-bytes"));
});

Deno.test("m3: fetchM3ConsentStatus refuses a foreign hospital request", async () => {
  const { fetchImpl } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentRequestStore.rows.push({
    hospital_id: "other-hosp",
    patient_id: "patient-1",
    request_id: "req-other",
    consent_request_id: null,
    abha_address: "user@sbx",
    status: "submitted",
    purpose_text: null,
    purpose_code: null,
    hi_types: [],
    date_from: null,
    date_to: null,
    data_erase_at: null,
    frequency: {},
    hip_id: null,
    hiu_id: "HIU-001",
    error_code: null,
    error_message: null,
    submitted_at: null,
    responded_at: null,
  });
  const deps = m3Deps(fetchImpl, stores);
  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "m3ConsentStatus", payload: { requestId: "req-other" } }),
  });
  const res = await handleRequest(req, deps);
  assertEquals(res.status, 404);
});

// Direct function-level tests for request correlation + idempotency helpers.

Deno.test("m3: requestM3HealthInformation requires secure key storage before sending", async () => {
  const { fetchImpl, calls } = m3GatewayFetch();
  const stores = m3Stores();
  stores.consentStore.rows.push(seededConsent());
  const refusedStore: M3PrivateKeyStore = {
    available: false,
    save: async () => ({ ok: false, code: M3_ERROR_CODES.PRIVATE_KEY_STORE_UNAVAILABLE, error: "refused" }),
    get: async () => null,
    delete: async () => {},
  };
  const deps: RequestDeps = {
    env: envWithSecrets,
    fetchImpl,
    authenticate: async () => adminUser(),
    persistCallbackRow: async () => {},
    v3TokenCache: { current: null },
    hospitalAbdmSettingsStore: hospitalSettings,
    m3ConsentRequestStore: stores.consentRequestStore,
    m3ConsentStore: stores.consentStore,
    m3HiRequestStore: stores.hiRequestStore,
    m3DataPageStore: stores.dataPageStore,
    m3FhirRecordStore: stores.fhirRecordStore,
    m3KeypairProvider: mockKeypairProvider,
    m3PrivateKeyStore: refusedStore,
    m3Decryptor: mockDecryptor(FHIR_DIAGNOSTIC_REPORT),
    m3DataImportEnabled: true,
  };
  const req = new Request("https://x.supabase.co/functions/v1/abdm-gateway", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "m3HealthInformationRequest", payload: { consentId: "consent-1" } }),
  });
  const res = await handleRequest(req, deps);
  assertEquals(res.status, 501);
  const resBody = await res.json() as Record<string, unknown>;
  assertEquals(resBody["code"], M3_ERROR_CODES.PRIVATE_KEY_STORE_UNAVAILABLE);
  assertEquals(m3OutboundCalls(calls).length, 0);
});

Deno.test("m3: buildM3HealthInformationNotifyBody uses the official HIU notifier shape", () => {
  const body = buildM3HealthInformationNotifyBody({
    requestId: "req-1",
    timestamp: "2026-09-06T00:00:00.000Z",
    consentId: "consent-1",
    transactionId: "txn-1",
    doneAt: "2026-09-06T00:00:01.000Z",
    hiuId: "HIU-001",
    hipId: "HIP-001",
    sessionStatus: "TRANSFERRED",
    statusResponses: [{ careContextReference: "cc-1", hiStatus: "OK", description: "Done" }],
  });
  const notification = body["notification"] as Record<string, unknown>;
  assertEquals(notification["notifier"], { type: "HIU", id: "HIU-001" });
  assertEquals((notification["statusNotification"] as Record<string, unknown>)["hipId"], "HIP-001");
});
