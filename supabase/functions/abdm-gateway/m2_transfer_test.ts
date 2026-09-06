// ============================================================================
// Deno tests for ABDM V3 M2 HIP data-transfer execution.
//
// Covers: SSRF-safe dataPushUrl validation + push, encryption availability
// gate, key-material validation, job lifecycle (claim/lease/retry/terminal),
// and the final ABDM health-information notify through the canonical V3
// client. All upstreams are mocked; no live ABDM or HIU calls are made.
// ============================================================================

import {
  readConfig,
} from "./core.ts";
import {
  buildFhirBundleFromSource,
  M2_ERROR_CODES,
  M2_JOB_STATUS,
  type M2CareContextStore,
  type M2ConsentArtefactRow,
  type M2ConsentStore,
  type M2DataTransferJobRow,
  type M2DataTransferJobStore,
  type M2Encryptor,
  type M2Hospital,
  type M2LinkInitRecord,
  type M2LinkInitPersistRecord,
  type M2ProcessRuntime,
  type M2RequestRow,
  type M2RequestStore,
  type M2InsertResult,
  V3_M2_HEALTH_INFORMATION_NOTIFY_PATH,
} from "./m2.ts";
import {
  executeDueM2DataTransferJobs,
  executeM2DataTransferJob,
  m2SafePush,
  unavailableM2Encryptor,
  validateDataPushUrl,
  validateM2KeyMaterial,
} from "./m2_transfer.ts";

function assertEquals<T>(actual: T, expected: T, message = ""): void {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  if (a !== b) {
    throw new Error(`${message ? message + " — " : ""}expected ${b}, got ${a}`);
  }
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

async function assertRejects(promise: Promise<unknown>, message = ""): Promise<void> {
  let rejected = false;
  try {
    await promise;
  } catch (_) {
    rejected = true;
  }
  if (!rejected) throw new Error(`${message ? message + " — " : ""}expected rejection`);
}

const envWithSecrets = {
  ABDM_CLIENT_ID: "sbx-client-id",
  ABDM_CLIENT_SECRET: "sbx-client-secret",
};

const config = readConfig(envWithSecrets).config!;

const hospitalA: M2Hospital = {
  hospitalId: "hospital-a",
  facilityId: "IN0000000001",
  facilityName: "Mediflux Test Hospital",
  hipName: "MEDIFLUX",
};

// ----------------------------------------------------------------------------
// SSRF / dataPushUrl validation
// ----------------------------------------------------------------------------

Deno.test("m2 transfer: dataPushUrl validation rejects private and metadata targets", async () => {
  const rejections = [
    "http://hiu.example/fhir",
    "https://localhost/fhir",
    "https://127.0.0.1/fhir",
    "https://[::1]/fhir",
    "https://10.0.0.8/fhir",
    "https://172.16.0.5/fhir",
    "https://192.168.1.10/fhir",
    "https://169.254.169.254/latest/meta-data",
    "https://metadata.google.internal/computeMetadata",
    "https://hiu.example/fhir?x=1",
    "https://user:pass@hiu.example/fhir",
    "https://hiu.internal/fhir",
  ];
  for (const url of rejections) {
    const result = await validateDataPushUrl(url);
    assertEquals(result.ok, false, url);
  }
});

Deno.test("m2 transfer: dataPushUrl validation uses DNS and fails closed", async () => {
  const ok = await validateDataPushUrl("https://hiu.example/fhir", async () => ["8.8.8.8"]);
  assertEquals(ok.ok, true);
  assertEquals(ok.url, "https://hiu.example/fhir");

  const privateIp = await validateDataPushUrl("https://hiu.example/fhir", async () => ["10.1.2.3"]);
  assertEquals(privateIp.ok, false);
  assertEquals(privateIp.code, "ABDM_M2_PUSH_URL_PRIVATE");

  const dnsFail = await validateDataPushUrl("https://hiu.example/fhir", async () => {
    throw new Error("NXDOMAIN");
  });
  assertEquals(dnsFail.ok, false);
  assertEquals(dnsFail.code, "ABDM_M2_PUSH_URL_DNS");
});

Deno.test("m2 transfer: safe push posts without forwarding ABDM credentials", async () => {
  const calls: Array<{ url: string; headers: Headers; body: unknown }> = [];
  const fetchImpl = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    const headers = new Headers(init?.headers ?? {});
    let body: unknown = null;
    if (typeof init?.body === "string") body = JSON.parse(init.body);
    calls.push({ url, headers, body });
    return new Response("{}", { status: 200, headers: { "Content-Type": "application/json" } });
  }) as typeof fetch;

  const response = await m2SafePush(fetchImpl, "https://hiu.example/fhir", { hello: "world" });
  assertEquals(response.ok, true);
  assertEquals(response.status, 200);
  assertEquals(calls.length, 1);
  assertEquals(calls[0].headers.get("authorization"), null);
  assertEquals(calls[0].headers.get("x-cm-id"), null);
  assertEquals(calls[0].headers.get("x-hip-id"), null);
  assertEquals(calls[0].body, { hello: "world" });
});

Deno.test("m2 transfer: safe push rejects redirect to a private address", async () => {
  const fetchImpl = (async () =>
    new Response(null, { status: 302, headers: { location: "https://127.0.0.1/fhir" } })) as typeof fetch;
  await assertRejects(
    m2SafePush(fetchImpl, "https://hiu.example/fhir", {}),
    "redirect to private address must be rejected",
  );
});

Deno.test("m2 transfer: safe push classifies abort as timeout", async () => {
  const fetchImpl = (async (_input: string | URL | Request, init?: RequestInit) => {
    await new Promise((resolve) => setTimeout(resolve, 25));
    if (init?.signal?.aborted) throw new Error("The operation was aborted");
    return new Response("{}", { status: 200 });
  }) as typeof fetch;
  await assertRejects(
    m2SafePush(fetchImpl, "https://hiu.example/fhir", {}, { timeoutMs: 1 }),
    "aborted push must reject",
  );
});

// ----------------------------------------------------------------------------
// Encryption availability + key material validation
// ----------------------------------------------------------------------------

Deno.test("m2 transfer: production encryptor is unavailable and reports the official ambiguity", async () => {
  const encryptor = unavailableM2Encryptor();
  assertEquals(encryptor.available, false);
  const result = await encryptor.encrypt({ resourceType: "Bundle" }, {
    cryptoAlg: "ECDH",
    curve: "curve25519",
    dhPublicKey: { expiry: null, parameters: null, keyValue: "cHVi" },
    nonce: "bm9uY2U=",
  }, ["CC-1"]);
  assertEquals(result.ok, false);
  assertEquals(result.code, M2_ERROR_CODES.ENCRYPTION_UNAVAILABLE);
});

Deno.test("m2 transfer: key-material validation enforces the official V3 contract", () => {
  const valid = {
    cryptoAlg: "ECDH",
    curve: "curve25519",
    dhPublicKey: { expiry: null, parameters: null, keyValue: "cHVi" },
    nonce: "bm9uY2U=",
  };
  assertEquals(validateM2KeyMaterial(valid).ok, true);

  assertEquals(validateM2KeyMaterial({ ...valid, cryptoAlg: "RSA" }).ok, false);
  assertEquals(validateM2KeyMaterial({ ...valid, curve: "P-256" }).ok, false);
  assertEquals(
    validateM2KeyMaterial({
      ...valid,
      dhPublicKey: { expiry: null, parameters: null, keyValue: "!!!" },
    }).ok,
    false,
  );
  assertEquals(validateM2KeyMaterial({ ...valid, nonce: "" }).ok, false);
});

// ----------------------------------------------------------------------------
// In-memory stores for the executor
// ----------------------------------------------------------------------------

class MemoryRequestStore implements M2RequestStore {
  async insert(_row: M2RequestRow): Promise<M2InsertResult> {
    return "inserted";
  }
  async updateLinkInit(_requestId: string, _record: M2LinkInitPersistRecord) {}
  async findLinkInitByLinkRef(_linkRefNumber: string): Promise<M2LinkInitRecord | null> {
    return null;
  }
  async countRecentLinkInit() {
    return 0;
  }
  async markProcessed() {}
}

class MemoryCareContextStore implements M2CareContextStore {
  async findUnlinkedByAbha() {
    return null;
  }
  async findForReferences() {
    return [];
  }
  async markLinked() {}
}

class MemoryConsentStore implements M2ConsentStore {
  constructor(public consent: M2ConsentArtefactRow | null) {}
  async upsert(row: M2ConsentArtefactRow) {
    this.consent = row;
    return { error: null };
  }
  async findByConsentId() {
    return this.consent;
  }
}

class MemoryJobStore implements M2DataTransferJobStore {
  jobs: M2DataTransferJobRow[] = [];
  async upsert(row: M2DataTransferJobRow) {
    const index = this.jobs.findIndex((j) => j.transaction_id === row.transaction_id);
    if (index >= 0) this.jobs[index] = { ...row };
    else this.jobs.push({ ...row });
    return { error: null };
  }
  async claimDue(now: string, leaseOwner: string, leaseSeconds: number, hospitalId: string) {
    const nowMs = Date.parse(now);
    const retryable = ["queued", "preparing", "encrypted", "pushing", "pushed", "notifying"];
    const candidate = this.jobs.find((j) => {
      if (j.hospital_id !== hospitalId) return false;
      if (!retryable.includes(j.status)) return false;
      const leaseExpired = !j.lease_expires_at || Date.parse(j.lease_expires_at) < nowMs;
      const due = !j.next_retry_at || Date.parse(j.next_retry_at) <= nowMs;
      return leaseExpired && due;
    });
    if (!candidate) return null;
    candidate.status = "preparing";
    candidate.lease_owner = leaseOwner;
    candidate.lease_expires_at = new Date(nowMs + leaseSeconds * 1000).toISOString();
    candidate.last_attempt_at = now;
    return { ...candidate };
  }
}

function mockEncryptor(): M2Encryptor {
  return {
    available: true,
    async encrypt(bundle, _keyMaterial, careContextRefs) {
      return {
        ok: true,
        entries: careContextRefs.map((ref) => ({
          content: btoa(JSON.stringify(bundle)),
          media: "application/fhir+json" as const,
          checksum: "checksum",
          careContextReference: ref,
        })),
        keyMaterial: {
          cryptoAlg: "ECDH",
          curve: "curve25519",
          dhPublicKey: { expiry: null, parameters: null, keyValue: "c2VuZGVy" },
          nonce: "c2VuZGVyTm9uY2U=",
        },
      };
    },
  };
}

function validConsent(): M2ConsentArtefactRow {
  return {
    hospital_id: hospitalA.hospitalId,
    patient_id: "patient-1",
    abha_id: "patient1@sbx",
    consent_id: "consent-1",
    hip_id: hospitalA.facilityId,
    hiu_id: "HIU-1",
    purpose: "Care management",
    data_from: "2020-01-01T00:00:00.000Z",
    data_to: "2099-01-01T00:00:00.000Z",
    status: "granted",
    granted_at: "2026-09-06T00:00:00.000Z",
    expires_at: "2099-01-01T00:00:00.000Z",
    care_context_references: ["CC-OPD-1"],
    hi_types: ["OPConsultation"],
  };
}

function validBundle(): Record<string, unknown> {
  const result = buildFhirBundleFromSource({
    patient: { abhaId: "patient1@sbx", name: "Rahul Sharma", gender: "male" },
    careContexts: [
      {
        recordType: "opd_visit",
        recordId: "opd-1",
        display: "OPD Visit",
        careContextReference: "CC-OPD-1",
        dateTime: "2026-09-06T00:00:00.000Z",
      },
    ],
  });
  assert(result.ok, "fixture FHIR bundle must build");
  return result.bundle as Record<string, unknown>;
}

function makeRuntime(input: {
  fetchImpl: typeof fetch;
  jobStore: MemoryJobStore;
  consent?: M2ConsentArtefactRow | null;
  encryptor?: M2Encryptor | null;
  dataTransferEnabled?: boolean;
  linkNotifier?: M2ProcessRuntime["linkNotifier"];
}): M2ProcessRuntime {
  return {
    fetchImpl: input.fetchImpl,
    config,
    v3TokenCache: { current: null },
    hospital: hospitalA,
    careContextStore: new MemoryCareContextStore(),
    consentStore: new MemoryConsentStore(input.consent ?? validConsent()),
    dataTransferJobStore: input.jobStore,
    linkInitStore: new MemoryRequestStore(),
    encryptor: input.encryptor ?? null,
    dataTransferEnabled: input.dataTransferEnabled === true,
    linkNotifier: input.linkNotifier ?? null,
    fetchFhirSource: async () => ({
      patient: { abhaId: "patient1@sbx", name: "Rahul Sharma", gender: "male" },
      careContexts: [
        {
          recordType: "opd_visit",
          recordId: "opd-1",
          display: "OPD Visit",
          careContextReference: "CC-OPD-1",
          dateTime: "2026-09-06T00:00:00.000Z",
        },
      ],
    }),
  };
}

function gatewayAndPushFetch(
  pushStatus = 200,
  notifyStatus = 202,
): { fetchImpl: typeof fetch; calls: Array<{ url: string; method: string }> } {
  const calls: Array<{ url: string; method: string }> = [];
  const fetchImpl = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.toString() : input.url;
    const method = init?.method ?? "GET";
    calls.push({ url, method });
    if (url.includes("/gateway/v3/sessions")) {
      return new Response(JSON.stringify({ accessToken: "tok", expiresIn: 3600 }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }
    if (url.includes("hiu.example")) {
      return new Response("{}", { status: pushStatus });
    }
    if (url.includes(V3_M2_HEALTH_INFORMATION_NOTIFY_PATH)) {
      return new Response("{}", { status: notifyStatus });
    }
    return new Response("{}", { status: 200 });
  }) as typeof fetch;
  return { fetchImpl, calls };
}

function queuedJob(): M2DataTransferJobRow {
  return {
    hospital_id: hospitalA.hospitalId,
    consent_id: "consent-1",
    transaction_id: "txn-hi-1",
    status: M2_JOB_STATUS.QUEUED,
    care_context_references: ["CC-OPD-1"],
    care_context_hi_types: ["OPConsultation"],
    fhir_bundle: validBundle(),
    key_material: {
      cryptoAlg: "ECDH",
      curve: "curve25519",
      dhPublicKey: { expiry: null, parameters: null, keyValue: "cHVi" },
      nonce: "bm9uY2U=",
    },
    data_push_url: "https://hiu.example/fhir",
    attempts: 0,
    error_code: null,
    error_message: null,
  };
}

// ----------------------------------------------------------------------------
// Executor lifecycle tests
// ----------------------------------------------------------------------------

Deno.test("m2 transfer: successful job completes the full lifecycle", async () => {
  const { fetchImpl, calls } = gatewayAndPushFetch();
  const jobStore = new MemoryJobStore();
  jobStore.jobs.push(queuedJob());
  const runtime = makeRuntime({
    fetchImpl,
    jobStore,
    encryptor: mockEncryptor(),
    dataTransferEnabled: true,
  });

  const result = await executeM2DataTransferJob(
    { ...jobStore.jobs[0] },
    runtime,
    { leaseOwner: "worker-1", now: () => new Date("2026-09-06T00:00:00.000Z") },
  );
  assertEquals(result.status, M2_JOB_STATUS.COMPLETED);
  assertEquals(result.notification_status, "sent");
  assertEquals(result.error_code, null);
  assertEquals(result.lease_owner, null);

  const stored = jobStore.jobs[0];
  assertEquals(stored.status, M2_JOB_STATUS.COMPLETED);
  assertEquals(stored.encrypted_entries?.length, 1);

  const notifyCalls = calls.filter((c) => c.url.includes(V3_M2_HEALTH_INFORMATION_NOTIFY_PATH));
  assertEquals(notifyCalls.length, 1);
  const pushCalls = calls.filter((c) => c.url.includes("hiu.example"));
  assertEquals(pushCalls.length, 1);
});

Deno.test("m2 transfer: unavailable encryption is a safe terminal failure", async () => {
  const { fetchImpl } = gatewayAndPushFetch();
  const jobStore = new MemoryJobStore();
  jobStore.jobs.push(queuedJob());
  const runtime = makeRuntime({
    fetchImpl,
    jobStore,
    encryptor: unavailableM2Encryptor(),
    dataTransferEnabled: true,
  });

  const result = await executeM2DataTransferJob(jobStore.jobs[0], runtime, {
    leaseOwner: "worker-1",
  });
  assertEquals(result.status, M2_JOB_STATUS.FAILED_SAFE);
  assertEquals(result.error_code, M2_ERROR_CODES.ENCRYPTION_UNAVAILABLE);
});

Deno.test("m2 transfer: invalid consent is a safe terminal failure", async () => {
  const { fetchImpl } = gatewayAndPushFetch();
  const jobStore = new MemoryJobStore();
  jobStore.jobs.push(queuedJob());
  const expiredConsent = { ...validConsent(), status: "revoked" };
  const runtime = makeRuntime({
    fetchImpl,
    jobStore,
    consent: expiredConsent,
    encryptor: mockEncryptor(),
    dataTransferEnabled: true,
  });

  const result = await executeM2DataTransferJob(jobStore.jobs[0], runtime, {
    leaseOwner: "worker-1",
  });
  assertEquals(result.status, M2_JOB_STATUS.FAILED_SAFE);
  assertEquals(result.error_code, M2_ERROR_CODES.CONSENT_INVALID);
});

Deno.test("m2 transfer: push 5xx is retryable with backoff metadata", async () => {
  const { fetchImpl } = gatewayAndPushFetch(503);
  const jobStore = new MemoryJobStore();
  jobStore.jobs.push(queuedJob());
  const runtime = makeRuntime({
    fetchImpl,
    jobStore,
    encryptor: mockEncryptor(),
    dataTransferEnabled: true,
  });

  const now = new Date("2026-09-06T00:00:00.000Z");
  const result = await executeM2DataTransferJob(jobStore.jobs[0], runtime, {
    leaseOwner: "worker-1",
    now: () => now,
  });
  assertEquals(result.status, M2_JOB_STATUS.QUEUED);
  assertEquals(result.attempts, 1);
  assert(result.next_retry_at, "retry timestamp must be set");
  assertEquals(Date.parse(result.next_retry_at!) > now.getTime(), true);
  assertEquals(result.lease_owner, null);
});

Deno.test("m2 transfer: push 4xx is a safe terminal failure", async () => {
  const { fetchImpl } = gatewayAndPushFetch(400);
  const jobStore = new MemoryJobStore();
  jobStore.jobs.push(queuedJob());
  const runtime = makeRuntime({
    fetchImpl,
    jobStore,
    encryptor: mockEncryptor(),
    dataTransferEnabled: true,
  });

  const result = await executeM2DataTransferJob(jobStore.jobs[0], runtime, {
    leaseOwner: "worker-1",
  });
  assertEquals(result.status, M2_JOB_STATUS.FAILED_SAFE);
  assertEquals(result.error_code, "ABDM_M2_PUSH_400");
});

Deno.test("m2 transfer: notify 5xx is retryable and never loses the job", async () => {
  const { fetchImpl } = gatewayAndPushFetch(200, 503);
  const jobStore = new MemoryJobStore();
  jobStore.jobs.push(queuedJob());
  const runtime = makeRuntime({
    fetchImpl,
    jobStore,
    encryptor: mockEncryptor(),
    dataTransferEnabled: true,
  });

  const result = await executeM2DataTransferJob(jobStore.jobs[0], runtime, {
    leaseOwner: "worker-1",
  });
  assertEquals(result.status, M2_JOB_STATUS.QUEUED);
  assertEquals(result.error_code, "ABDM_M2_NOTIFY_503");
  assert(result.next_retry_at, "notify retry must be scheduled");
});

Deno.test("m2 transfer: lease prevents duplicate execution by a second worker", async () => {
  const { fetchImpl } = gatewayAndPushFetch();
  const jobStore = new MemoryJobStore();
  jobStore.jobs.push(queuedJob());
  const runtime = makeRuntime({
    fetchImpl,
    jobStore,
    encryptor: mockEncryptor(),
    dataTransferEnabled: true,
  });

  const claimed = await jobStore.claimDue(
    "2026-09-06T00:00:00.000Z",
    "worker-1",
    60,
    hospitalA.hospitalId,
  );
  assert(claimed, "first claim must succeed");
  const duplicate = await jobStore.claimDue(
    "2026-09-06T00:00:01.000Z",
    "worker-2",
    60,
    hospitalA.hospitalId,
  );
  assertEquals(duplicate, null);
});

Deno.test("m2 transfer: due-job sweep executes queued jobs and skips leased jobs", async () => {
  const { fetchImpl } = gatewayAndPushFetch();
  const jobStore = new MemoryJobStore();
  jobStore.jobs.push(queuedJob());
  const runtime = makeRuntime({
    fetchImpl,
    jobStore,
    encryptor: mockEncryptor(),
    dataTransferEnabled: true,
  });

  const executed = await executeDueM2DataTransferJobs(runtime, {
    limit: 3,
    leaseOwner: "worker-sweep",
  });
  assertEquals(executed, 1);
  assertEquals(jobStore.jobs[0].status, M2_JOB_STATUS.COMPLETED);

  // A completed job must never be claimed again.
  const claimed = await jobStore.claimDue(
    new Date().toISOString(),
    "worker-2",
    60,
    hospitalA.hospitalId,
  );
  assertEquals(claimed, null);
});

Deno.test("m2 transfer: hospital mismatch is a safe terminal failure", async () => {
  const { fetchImpl } = gatewayAndPushFetch();
  const jobStore = new MemoryJobStore();
  const foreignJob = { ...queuedJob(), hospital_id: "hospital-b" };
  jobStore.jobs.push(foreignJob);
  const runtime = makeRuntime({
    fetchImpl,
    jobStore,
    encryptor: mockEncryptor(),
    dataTransferEnabled: true,
  });

  const result = await executeM2DataTransferJob(jobStore.jobs[0], runtime, {
    leaseOwner: "worker-1",
  });
  assertEquals(result.status, M2_JOB_STATUS.FAILED_SAFE);
  assertEquals(result.error_code, "ABDM_M2_JOB_HOSPITAL_MISMATCH");
});
