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
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  handleRequest,
  type AuthenticatedUser,
} from "./handler.ts";
import { HttpError, persistCallback, type CallbackRow } from "./core.ts";

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
    const supabaseUrl = env["SUPABASE_URL"] ?? "";
    const serviceRoleKey = env["SUPABASE_SERVICE_ROLE_KEY"] ?? "";
    if (!supabaseUrl || !serviceRoleKey) {
      console.error(
        `abdm-gateway callback not persisted: missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY (request_id=${row.request_id})`,
      );
      return;
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

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
    }));
}
