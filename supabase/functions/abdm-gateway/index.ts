// ============================================================================
// ABDM Gateway Edge Function — Supabase wiring entrypoint
// ----------------------------------------------------------------------------
// Deploy:  supabase functions deploy abdm-gateway
//
// FUNCTION CONFIG (Supabase)
//   This function receives PUBLIC ABDM callbacks, so platform JWT verification
//   must be disabled for it:
//
//     # supabase/config.toml
//     [functions.abdm-gateway]
//     verify_jwt = false
//
//   Every protected action (`session`, `bridge`, `services`, `health`)
//   manually validates the Supabase user JWT (see requireUser below), and
//   `session`/`bridge`/`services` additionally require an owner/super-admin
//   role. Callback POST routes stay public but can never reach an
//   administrative action.
//
// Secrets (set in Supabase Dashboard → Edge Functions → Secrets, never commit):
//   ABDM_CLIENT_ID
//   ABDM_CLIENT_SECRET
//   ABDM_BASE_URL              (default https://dev.abdm.gov.in)
//   ABDM_BRIDGE_ID
//   ABDM_HIP_ID
//   ABDM_HIU_ID
//   ABDM_CALLBACK_BASE_URL
//   ABDM_SESSION_PATH          (default /gateway/v1/sessions — confirm docs)
//   ABDM_BRIDGE_PATH           (default /gateway/v1/bridges)
//   ABDM_SERVICES_PATH         (default /gateway/v1/bridges/addUpdateServices)
//   ABDM_GET_SERVICES_PATH     (default /gateway/v1/bridges/getServices)
//   ABDM_SERVICE_TYPES         (default HIP,HIU — confirm onboarding email)
//
// Non-secret configuration (safe to set in the dashboard):
//   ABDM_CM_ID                Bridge-management X-CM-ID value. Defaults to
//                             "sbx" ONLY when ABDM_BASE_URL hostname is
//                             dev.abdm.gov.in. Set empty to disable. Never
//                             read from the request body/query.
//
// The raw ABDM token never leaves this function. It is used only for outgoing
// Bridge / service-management requests and cached in worker memory with an
// expiration safety margin.
// ============================================================================

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import {
  createClient,
  type SupabaseClient,
} from "https://esm.sh/@supabase/supabase-js@2";
import {
  handleRequest,
  type AuthenticatedUser,
  type HospitalAbdmSettingsStore,
  type M1TransactionStore,
  type M2FhirSourceStore,
  type M2HospitalStore,
} from "./handler.ts";
import { HttpError, persistCallback, type CallbackRow } from "./core.ts";
import {
  extractCareContextRefs,
  type M2CareContextStore,
  type M2ConsentArtefactRow,
  type M2ConsentStore,
  type M2DataTransferJobStore,
  type M2DataTransferJobRow,
  type M2FhirBundleSource,
  type M2Hospital,
  type M2LinkInitPersistRecord,
  type M2RequestStore,
  type M2RequestRow,
} from "./m2.ts";

// ----------------------------------------------------------------------------
// Real Supabase/ABDM wiring (used when running inside Supabase Edge Runtime)
// ----------------------------------------------------------------------------

async function requireUser(
  req: Request,
  env: Record<string, string | undefined>,
): Promise<AuthenticatedUser> {
  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.startsWith("Bearer ")
    ? authHeader.slice("Bearer ".length).trim()
    : "";
  if (!token) throw new HttpError(401, "Missing bearer token");

  const supabaseUrl = env["SUPABASE_URL"] ?? "";
  const anonKey = env["SUPABASE_ANON_KEY"] ?? "";
  if (!supabaseUrl || !anonKey) {
    throw new HttpError(500, "SUPABASE_URL / SUPABASE_ANON_KEY not configured");
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { data: authData, error: authError } = await userClient.auth.getUser(
    token,
  );
  if (authError || !authData.user) {
    throw new HttpError(401, "Invalid or expired user session");
  }

  const { data: userRow, error: userError } = await userClient
    .from("users")
    .select("id, role, hospital_id, is_active")
    .eq("auth_id", authData.user.id)
    .maybeSingle();

  if (userError || !userRow) {
    throw new HttpError(403, "No HIMS user record found for this account");
  }
  if (userRow["is_active"] !== true) {
    throw new HttpError(403, "User account is inactive");
  }

  return {
    authId: authData.user.id,
    userId: String(userRow["id"]),
    role: String(userRow["role"] ?? ""),
    hospitalId: userRow["hospital_id"]
      ? String(userRow["hospital_id"])
      : null,
  };
}

async function persistCallbackRow(
  row: CallbackRow,
  env: Record<string, string | undefined>,
): Promise<void> {
  try {
    const adminClient = createServiceRoleClient(env);

    const result = await persistCallback(
      {
        insert: async (record) => {
          const { error } = await adminClient
            .from("abdm_gateway_callbacks")
            .insert(record);
          return { error: error ? { code: error.code, message: error.message } : null };
        },
      },
      row,
    );

    console.log(
      `abdm-gateway callback ${result}: path=${row.callback_path} request_id=${row.request_id}`,
    );
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(
      `abdm-gateway callback persistence error (request_id=${row.request_id}): ${message}`,
    );
  }
}

function createServiceRoleClient(
  env: Record<string, string | undefined>,
): SupabaseClient {
  const supabaseUrl = env["SUPABASE_URL"] ?? "";
  const serviceRoleKey = env["SUPABASE_SERVICE_ROLE_KEY"] ?? "";
  if (!supabaseUrl || !serviceRoleKey) {
    throw new Error(
      "Missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY for service-role access",
    );
  }
  return createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}

/**
 * Server-side M1 transaction binding backed by `abdm_m1_transactions`.
 *
 * A browser-supplied ABDM `txnId` is validated against the row owned by the
 * current HIMS user + hospital + operation before any continuation step
 * (OTP verification / ABHA creation) may proceed. OTP and raw Aadhaar are
 * never stored in this table.
 */
function m1TransactionStoreFor(
  env: Record<string, string | undefined>,
): M1TransactionStore {
  return {
    async findByTransactionId(transactionId) {
      const adminClient = createServiceRoleClient(env);
      const { data, error } = await adminClient
        .from("abdm_m1_transactions")
        .select(
          "transaction_id, user_id, hospital_id, operation, expires_at, consumed_at",
        )
        .eq("transaction_id", transactionId)
        .maybeSingle();
      if (error) {
        throw new Error(`M1 transaction lookup failed: ${error.message}`);
      }
      if (!data) return null;
      return {
        transactionId: String(data["transaction_id"]),
        userId: String(data["user_id"]),
        hospitalId: String(data["hospital_id"]),
        operation: String(data["operation"]),
        expiresAt: String(data["expires_at"]),
        consumedAt: data["consumed_at"] ? String(data["consumed_at"]) : null,
      };
    },
    async markConsumed(transactionId) {
      const adminClient = createServiceRoleClient(env);
      const { error } = await adminClient
        .from("abdm_m1_transactions")
        .update({ consumed_at: new Date().toISOString() })
        .eq("transaction_id", transactionId)
        .is("consumed_at", null);
      if (error) {
        throw new Error(`M1 transaction consume failed: ${error.message}`);
      }
    },
  };
}

/**
 * Server-side hospital ABDM/HFR settings backed by the `hospitals` table.
 *
 * facilityId is `hospitals.hfr_facility_id` (HFR facility id used as the ABDM
 * V3 service-id), facilityName is `hospitals.name`, and hipName is the
 * per-facility `hospitals.abdm_hip_name`. These values are never accepted from
 * the Flutter client.
 */
function hospitalAbdmSettingsStoreFor(
  env: Record<string, string | undefined>,
): HospitalAbdmSettingsStore {
  return {
    async getByHospitalId(hospitalId) {
      const adminClient = createServiceRoleClient(env);
      const { data, error } = await adminClient
        .from("hospitals")
        .select("name, hfr_facility_id, abdm_hip_name")
        .eq("id", hospitalId)
        .maybeSingle();
      if (error) {
        throw new Error(`Hospital ABDM settings lookup failed: ${error.message}`);
      }
      if (!data) return null;
      return {
        facilityId: data["hfr_facility_id"]
          ? String(data["hfr_facility_id"])
          : "",
        facilityName: data["name"] ? String(data["name"]) : "",
        hipName: data["abdm_hip_name"] ? String(data["abdm_hip_name"]) : "",
      };
    },
  };
}

// ----------------------------------------------------------------------------
// M2 HIP production stores (service-role only)
// ----------------------------------------------------------------------------

function m2HiTypeForRecordType(recordType: string): string {
  switch (recordType.toLowerCase()) {
    case "opd_visit":
    case "consultation":
      return "OPConsultation";
    case "prescription":
      return "Prescription";
    case "lab_report":
    case "diagnostic_report":
      return "DiagnosticReport";
    case "discharge_summary":
      return "DischargeSummary";
    case "immunization":
      return "ImmunizationRecord";
    case "wellness_record":
      return "WellnessRecord";
    default:
      return "HealthDocumentRecord";
  }
}

function m2PatientByName(row: Record<string, unknown>): string {
  const first = row["first_name"] ? String(row["first_name"]) : "";
  const last = row["last_name"] ? String(row["last_name"]) : "";
  return `${first} ${last}`.trim();
}

async function m2FindPatientByAbha(
  adminClient: SupabaseClient,
  abhaId: string,
  hospitalId: string,
): Promise<Record<string, unknown> | null> {
  const byAbhaId = await adminClient
    .from("patients")
    .select("id, uhid, first_name, last_name, gender, date_of_birth, abha_id, abha_address")
    .eq("hospital_id", hospitalId)
    .eq("abha_id", abhaId)
    .maybeSingle();
  if (!byAbhaId.error && byAbhaId.data) return byAbhaId.data as Record<string, unknown>;

  const byAbhaAddress = await adminClient
    .from("patients")
    .select("id, uhid, first_name, last_name, gender, date_of_birth, abha_id, abha_address")
    .eq("hospital_id", hospitalId)
    .eq("abha_address", abhaId)
    .maybeSingle();
  if (!byAbhaAddress.error && byAbhaAddress.data) {
    return byAbhaAddress.data as Record<string, unknown>;
  }
  return null;
}

function m2HospitalStoreFor(
  env: Record<string, string | undefined>,
): M2HospitalStore {
  return {
    async findByHipId(hipId) {
      const adminClient = createServiceRoleClient(env);
      const { data, error } = await adminClient
        .from("hospitals")
        .select("id, name, hfr_facility_id, abdm_hip_name")
        .eq("hfr_facility_id", hipId.trim())
        .maybeSingle();
      if (error) {
        throw new Error(`M2 hospital lookup failed: ${error.message}`);
      }
      if (!data) return null;
      const hospital: M2Hospital = {
        hospitalId: String(data["id"]),
        facilityId: data["hfr_facility_id"]
          ? String(data["hfr_facility_id"])
          : hipId.trim(),
        facilityName: data["name"] ? String(data["name"]) : "",
        hipName: data["abdm_hip_name"] ? String(data["abdm_hip_name"]) : "",
      };
      return hospital;
    },
  };
}

function m2RequestStoreFor(
  env: Record<string, string | undefined>,
): M2RequestStore {
  function parseLinkInitPayload(payload: unknown): {
    abhaAddress: string | null;
    careContextRefs: string[];
  } {
    if (typeof payload !== "object" || payload === null) {
      return { abhaAddress: null, careContextRefs: [] };
    }
    const record = payload as Record<string, unknown>;
    const abhaAddress = typeof record["abhaAddress"] === "string"
      ? record["abhaAddress"].trim()
      : null;
    const patients = Array.isArray(record["patient"]) ? record["patient"] : [];
    const first = Array.isArray(patients) && patients.length > 0 &&
        typeof patients[0] === "object" && patients[0] !== null
      ? patients[0] as Record<string, unknown>
      : {};
    return {
      abhaAddress,
      careContextRefs: extractCareContextRefs(first["careContexts"]),
    };
  }

  return {
    async insert(row: M2RequestRow) {
      const adminClient = createServiceRoleClient(env);
      const { error } = await adminClient
        .from("abdm_m2_requests")
        .insert({
          hospital_id: row.hospital_id,
          request_id: row.request_id,
          transaction_id: row.transaction_id,
          request_type: row.request_type,
          callback_path: row.callback_path,
          status: row.status,
          payload: row.payload,
          received_at: row.received_at,
        });
      if (!error) return "inserted";
      if (error.code === "23505") return "duplicate";
      throw new Error(`M2 request insert failed: ${error.message}`);
    },
    async updateLinkInit(requestId, record: M2LinkInitPersistRecord) {
      const adminClient = createServiceRoleClient(env);
      const { error } = await adminClient
        .from("abdm_m2_requests")
        .update({
          link_ref_number: record.linkRefNumber,
          token_hash: record.tokenHash,
          expires_at: record.expiresAt,
        })
        .eq("request_id", requestId)
        .eq("request_type", "linkInit");
      if (error) {
        throw new Error(`M2 link-init update failed: ${error.message}`);
      }
    },
    async findLinkInitByLinkRef(linkRefNumber) {
      const adminClient = createServiceRoleClient(env);
      const { data, error } = await adminClient
        .from("abdm_m2_requests")
        .select("request_id, transaction_id, payload, link_ref_number, token_hash, expires_at")
        .eq("link_ref_number", linkRefNumber)
        .eq("request_type", "linkInit")
        .maybeSingle();
      if (error) {
        throw new Error(`M2 link-init lookup failed: ${error.message}`);
      }
      if (!data) return null;
      const parsed = parseLinkInitPayload(data["payload"]);
      return {
        request_id: data["request_id"] ? String(data["request_id"]) : null,
        transaction_id: data["transaction_id"]
          ? String(data["transaction_id"])
          : null,
        abha_address: parsed.abhaAddress,
        link_ref_number: data["link_ref_number"]
          ? String(data["link_ref_number"])
          : "",
        token_hash: data["token_hash"] ? String(data["token_hash"]) : "",
        expires_at: data["expires_at"] ? String(data["expires_at"]) : null,
        care_context_refs: parsed.careContextRefs,
      };
    },
    async markProcessed(requestId, requestType, status, responsePayload, errorCode, errorMessage) {
      const adminClient = createServiceRoleClient(env);
      const { error } = await adminClient
        .from("abdm_m2_requests")
        .update({
          status,
          response_payload: responsePayload ?? null,
          error_code: errorCode ?? null,
          error_message: errorMessage ?? null,
          processed_at: new Date().toISOString(),
        })
        .eq("request_id", requestId)
        .eq("request_type", requestType);
      if (error) {
        throw new Error(`M2 request markProcessed failed: ${error.message}`);
      }
    },
  };
}

function m2CareContextStoreFor(
  env: Record<string, string | undefined>,
): M2CareContextStore {
  function mapCareContext(row: Record<string, unknown>) {
    const recordType = row["record_type"] ? String(row["record_type"]) : "HealthDocumentRecord";
    return {
      referenceNumber: row["care_context_id"] ? String(row["care_context_id"]) : "",
      display: recordType,
      hiType: m2HiTypeForRecordType(recordType),
    };
  }

  return {
    async findUnlinkedByAbha(abhaId, hospitalId) {
      const adminClient = createServiceRoleClient(env);
      const patient = await m2FindPatientByAbha(adminClient, abhaId, hospitalId);
      if (!patient) return null;
      const patientId = String(patient["id"]);
      const { data, error } = await adminClient
        .from("care_contexts")
        .select("care_context_id, record_type, record_id, is_linked")
        .eq("patient_id", patientId)
        .eq("hospital_id", hospitalId);
      if (error) {
        throw new Error(`M2 care-context lookup failed: ${error.message}`);
      }
      const careContexts = (data ?? [])
        .filter((row) => row["is_linked"] !== true)
        .map((row) => mapCareContext(row as Record<string, unknown>))
        .filter((context) => context.referenceNumber !== "");
      if (careContexts.length === 0) {
        return {
          patientReference: patient["uhid"] ? String(patient["uhid"]) : patientId,
          patientDisplay: m2PatientByName(patient),
          careContexts: [],
        };
      }
      return {
        patientReference: patient["uhid"] ? String(patient["uhid"]) : patientId,
        patientDisplay: m2PatientByName(patient),
        careContexts,
      };
    },
    async findForReferences(abhaId, careContextRefs, hospitalId) {
      if (careContextRefs.length === 0) return [];
      const adminClient = createServiceRoleClient(env);
      const patient = await m2FindPatientByAbha(adminClient, abhaId, hospitalId);
      if (!patient) return [];
      const { data, error } = await adminClient
        .from("care_contexts")
        .select("care_context_id, record_type, record_id, is_linked")
        .eq("patient_id", String(patient["id"]))
        .eq("hospital_id", hospitalId)
        .in("care_context_id", careContextRefs);
      if (error) {
        throw new Error(`M2 care-context reference lookup failed: ${error.message}`);
      }
      return (data ?? []).map((row) => mapCareContext(row as Record<string, unknown>));
    },
    async markLinked(abhaId, careContextRefs, hospitalId) {
      if (careContextRefs.length === 0) return;
      const adminClient = createServiceRoleClient(env);
      const patient = await m2FindPatientByAbha(adminClient, abhaId, hospitalId);
      if (!patient) return;
      const { error } = await adminClient
        .from("care_contexts")
        .update({ is_linked: true, linked_at: new Date().toISOString() })
        .eq("patient_id", String(patient["id"]))
        .eq("hospital_id", hospitalId)
        .in("care_context_id", careContextRefs);
      if (error) {
        throw new Error(`M2 care-context markLinked failed: ${error.message}`);
      }
    },
  };
}

function m2ConsentStoreFor(
  env: Record<string, string | undefined>,
): M2ConsentStore {
  function mapConsentRow(data: Record<string, unknown>): M2ConsentArtefactRow {
    const refs = Array.isArray(data["care_context_references"])
      ? (data["care_context_references"] as unknown[]).map((v) => String(v))
      : [];
    return {
      hospital_id: data["hospital_id"] ? String(data["hospital_id"]) : "",
      patient_id: data["patient_id"] ? String(data["patient_id"]) : null,
      abha_id: data["abha_id"] ? String(data["abha_id"]) : "",
      consent_id: data["consent_id"] ? String(data["consent_id"]) : "",
      hip_id: data["hip_id"] ? String(data["hip_id"]) : null,
      hiu_id: data["hiu_id"] ? String(data["hiu_id"]) : null,
      purpose: data["purpose"] ? String(data["purpose"]) : null,
      data_from: data["data_from"] ? String(data["data_from"]) : null,
      data_to: data["data_to"] ? String(data["data_to"]) : null,
      status: data["status"] ? String(data["status"]) : "unknown",
      granted_at: data["granted_at"] ? String(data["granted_at"]) : null,
      expires_at: data["expires_at"] ? String(data["expires_at"]) : null,
      care_context_references: refs,
    };
  }

  return {
    async upsert(row) {
      const adminClient = createServiceRoleClient(env);
      let patientId: string | null = row.patient_id ?? null;
      if (!patientId && row.abha_id) {
        const patient = await m2FindPatientByAbha(
          adminClient,
          row.abha_id,
          row.hospital_id,
        );
        patientId = patient ? String(patient["id"]) : null;
      }
      if (!patientId) {
        return {
          error: {
            code: "M2_PATIENT_NOT_FOUND",
            message: "Consent patient could not be resolved from ABHA id",
          },
        };
      }
      const { error } = await adminClient
        .from("consent_artefacts")
        .upsert({
          hospital_id: row.hospital_id,
          patient_id: patientId,
          abha_id: row.abha_id,
          consent_id: row.consent_id,
          hip_id: row.hip_id,
          hiu_id: row.hiu_id,
          purpose: row.purpose,
          data_from: row.data_from,
          data_to: row.data_to,
          status: row.status,
          granted_at: row.granted_at,
          expires_at: row.expires_at,
          care_context_references: row.care_context_references,
          updated_at: new Date().toISOString(),
        }, { onConflict: "consent_id" });
      return { error: error ? { code: error.code, message: error.message } : null };
    },
    async findByConsentId(consentId) {
      const adminClient = createServiceRoleClient(env);
      const { data, error } = await adminClient
        .from("consent_artefacts")
        .select("hospital_id, patient_id, abha_id, consent_id, hip_id, hiu_id, purpose, data_from, data_to, status, granted_at, expires_at, care_context_references")
        .eq("consent_id", consentId)
        .maybeSingle();
      if (error) {
        throw new Error(`M2 consent lookup failed: ${error.message}`);
      }
      if (!data) return null;
      return mapConsentRow(data as Record<string, unknown>);
    },
  };
}

function m2DataTransferJobStoreFor(
  env: Record<string, string | undefined>,
): M2DataTransferJobStore {
  return {
    async upsert(row: M2DataTransferJobRow) {
      const adminClient = createServiceRoleClient(env);
      const { error } = await adminClient
        .from("abdm_data_transfer_jobs")
        .upsert({
          hospital_id: row.hospital_id,
          consent_id: row.consent_id,
          transaction_id: row.transaction_id,
          status: row.status,
          care_context_references: row.care_context_references,
          fhir_bundle: row.fhir_bundle,
          key_material: row.key_material,
          data_push_url: row.data_push_url,
          attempts: row.attempts,
          error_code: row.error_code,
          error_message: row.error_message,
          updated_at: new Date().toISOString(),
        }, { onConflict: "transaction_id" });
      return { error: error ? { code: error.code, message: error.message } : null };
    },
  };
}

function m2FhirSourceStoreFor(
  env: Record<string, string | undefined>,
): M2FhirSourceStore {
  return {
    async fetchForConsent(abhaId, careContextRefs, hospitalId) {
      if (!abhaId || careContextRefs.length === 0) return null;
      const adminClient = createServiceRoleClient(env);
      const patient = await m2FindPatientByAbha(adminClient, abhaId, hospitalId);
      if (!patient) return null;
      const { data, error } = await adminClient
        .from("care_contexts")
        .select("care_context_id, record_type, record_id, created_at")
        .eq("patient_id", String(patient["id"]))
        .eq("hospital_id", hospitalId)
        .in("care_context_id", careContextRefs);
      if (error) {
        throw new Error(`M2 FHIR source lookup failed: ${error.message}`);
      }
      const careContexts = (data ?? []).map((row) => ({
        recordType: row["record_type"] ? String(row["record_type"]) : "HealthDocumentRecord",
        recordId: row["record_id"] ? String(row["record_id"]) : "",
        display: row["record_type"] ? String(row["record_type"]) : "Health record",
        careContextReference: row["care_context_id"] ? String(row["care_context_id"]) : "",
        dateTime: row["created_at"] ? String(row["created_at"]) : null,
      })).filter((context) => context.careContextReference !== "");
      if (careContexts.length === 0) return null;
      const source: M2FhirBundleSource = {
        patient: {
          abhaId,
          abhaAddress: patient["abha_address"] ? String(patient["abha_address"]) : null,
          name: m2PatientByName(patient) || null,
          gender: patient["gender"] ? String(patient["gender"]) : null,
          dateOfBirth: patient["date_of_birth"] ? String(patient["date_of_birth"]) : null,
        },
        careContexts,
      };
      return source;
    },
  };
}

// Only start the server when this file is the actual entrypoint (not when it
// is imported by `deno test`).
if (import.meta.main) {
  serve((req: Request) =>
    handleRequest(req, {
      env: Deno.env.toObject(),
      fetchImpl: globalThis.fetch,
      authenticate: requireUser,
      persistCallbackRow: (row) =>
        persistCallbackRow(row, Deno.env.toObject()),
      m1TransactionStore: m1TransactionStoreFor(Deno.env.toObject()),
      hospitalAbdmSettingsStore: hospitalAbdmSettingsStoreFor(
        Deno.env.toObject(),
      ),
      m2HospitalStore: m2HospitalStoreFor(Deno.env.toObject()),
      m2RequestStore: m2RequestStoreFor(Deno.env.toObject()),
      m2CareContextStore: m2CareContextStoreFor(Deno.env.toObject()),
      m2ConsentStore: m2ConsentStoreFor(Deno.env.toObject()),
      m2DataTransferJobStore: m2DataTransferJobStoreFor(Deno.env.toObject()),
      m2FhirSourceStore: m2FhirSourceStoreFor(Deno.env.toObject()),
      // Live health-information transfer stays gated until HIP linkage,
      // consent and encryption prerequisites are all satisfied. Operators may
      // set ABDM_M2_DATA_TRANSFER_ENABLED=true only after those exist.
      m2DataTransferEnabled:
        (Deno.env.get("ABDM_M2_DATA_TRANSFER_ENABLED") ?? "false") === "true",
    }));
}
