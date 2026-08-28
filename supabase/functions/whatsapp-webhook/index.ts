// ======================================================================
// HIMS - whatsapp-webhook Edge Function (Meta WhatsApp Cloud API)
// ----------------------------------------------------------------------
// Meta WhatsApp Business Platform webhook handler. Meta calls this URL
// with two kinds of requests:
//
//   GET  - subscription verification (hub.mode/hub.verify_token/hub.challenge)
//   POST - message status updates (sent/delivered/read/failed)
//
// Multi-tenant mapping:
//   The webhook payload contains `metadata.phone_number_id` which is matched
//   against `whatsapp_settings.phone_number_id` to resolve the hospital.
//   `whatsapp_messages` rows are then updated by their Meta message id.
//
// Deploy steps:
//   1. supabase functions deploy whatsapp-webhook --no-verify-jwt
//   2. supabase secrets set WHATSAPP_WEBHOOK_VERIFY_TOKEN="your-token"
//   3. supabase secrets set WHATSAPP_APP_SECRET="your-meta-app-secret" (optional, enables HMAC validation)
//   4. Meta App Dashboard -> WhatsApp -> Configuration -> Webhook:
//        Callback URL: https://<project-ref>.supabase.co/functions/v1/whatsapp-webhook
//        Verify token: same as WHATSAPP_WEBHOOK_VERIFY_TOKEN
// ======================================================================

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-hub-signature-256",
};

interface WhatsappStatus {
  id: string;
  status: string;
  timestamp?: string;
  recipient_id?: string;
  errors?: Array<{ code?: number; title?: string }>;
}

async function hmacSha256Hex(secret: string, body: string): Promise<string> {
  const keyBytes = new TextEncoder().encode(secret);
  const bodyBytes = new TextEncoder().encode(body);
  const key = await crypto.subtle.importKey(
    "raw",
    keyBytes,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, bodyBytes);
  const bytes = new Uint8Array(sig);
  let hex = "";
  for (const b of bytes) hex += b.toString(16).padStart(2, "0");
  return hex;
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  // Service-role client bypasses RLS so the webhook can write for any tenant.
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  try {
    const url = new URL(req.url);

    // ---------------------------------------------------------------------
    // GET — Meta webhook verification handshake.
    // ---------------------------------------------------------------------
    if (req.method === "GET") {
      const mode = url.searchParams.get("hub.mode") ?? "";
      const verifyToken = url.searchParams.get("hub.verify_token") ?? "";
      const challenge = url.searchParams.get("hub.challenge") ?? "";
      const configuredToken = Deno.env.get("WHATSAPP_WEBHOOK_VERIFY_TOKEN") ?? "";

      if (mode === "subscribe" && configuredToken && verifyToken === configuredToken) {
        return new Response(challenge, { status: 200, headers: corsHeaders });
      }

      // Fallback: allow a hospital-specific verify token from the settings
      // table (useful when each hospital configures its own Meta app).
      const { data: settingsRows } = await supabase
        .from("whatsapp_settings")
        .select("webhook_verify_token")
        .eq("is_active", true);

      const matches =
        Array.isArray(settingsRows) &&
        settingsRows.some((s: { webhook_verify_token?: string }) =>
          s.webhook_verify_token && s.webhook_verify_token === verifyToken);

      if (mode === "subscribe" && matches) {
        return new Response(challenge, { status: 200, headers: corsHeaders });
      }

      return new Response("Verification failed", { status: 403, headers: corsHeaders });
    }

    if (req.method !== "POST") {
      return new Response(
        JSON.stringify({ error: "Method not allowed" }),
        { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    // ---------------------------------------------------------------------
    // POST — validate HMAC signature (when the app secret is configured),
    // then persist message status updates.
    // ---------------------------------------------------------------------
    const rawBody = await req.text();
    const appSecret = Deno.env.get("WHATSAPP_APP_SECRET");
    const signatureHeader = req.headers.get("x-hub-signature-256") ?? "";

    if (appSecret) {
      if (!signatureHeader.startsWith("sha256=")) {
        return new Response(
          JSON.stringify({ error: "Missing signature" }),
          { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }
      const expected = signatureHeader.substring("sha256=".length);
      const digest = await hmacSha256Hex(appSecret, rawBody);
      if (digest !== expected) {
        return new Response(
          JSON.stringify({ error: "Invalid signature" }),
          { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }
    } else {
      console.warn(
        "WHATSAPP_APP_SECRET is not set — skipping webhook signature validation.",
      );
    }

    const payload = JSON.parse(rawBody || "{}");
    const statuses: WhatsappStatus[] = [];
    const phoneNumberIds = new Set<string>();

    for (const entry of payload?.entry ?? []) {
      for (const change of entry?.changes ?? []) {
        const value = change?.value ?? {};
        const meta = value?.metadata ?? {};
        if (meta?.phone_number_id) phoneNumberIds.add(String(meta.phone_number_id));

        for (const status of value?.statuses ?? []) {
          statuses.push({
            id: String(status?.id ?? ""),
            status: String(status?.status ?? ""),
            timestamp: status?.timestamp ? String(status.timestamp) : undefined,
            recipient_id: status?.recipient_id ? String(status.recipient_id) : undefined,
            errors: Array.isArray(status?.errors) ? status.errors : [],
          });
        }

        // A message entry with errors but no statuses means the send failed.
        for (const message of value?.messages ?? []) {
          if (Array.isArray(message?.errors) && message.errors.length > 0) {
            statuses.push({
              id: String(message?.id ?? ""),
              status: "failed",
              timestamp: message?.timestamp ? String(message.timestamp) : undefined,
              recipient_id: message?.from ? String(message.from) : undefined,
              errors: message.errors,
            });
          }
        }
      }
    }

    if (statuses.length === 0) {
      return new Response(JSON.stringify({ success: true, updated: 0 }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Resolve hospital ids for every phone_number_id seen in this payload.
    const hospitalByPhone = new Map<string, string>();
    if (phoneNumberIds.size > 0) {
      const { data: settingsRows } = await supabase
        .from("whatsapp_settings")
        .select("hospital_id, phone_number_id")
        .in("phone_number_id", Array.from(phoneNumberIds));

      for (const row of settingsRows ?? []) {
        if (row?.phone_number_id && row?.hospital_id) {
          hospitalByPhone.set(String(row.phone_number_id), String(row.hospital_id));
        }
      }
    }

    let updated = 0;
    for (const status of statuses) {
      if (!status.id) continue;

      const normalizedStatus =
        status.status === "delivered"
          ? "delivered"
          : status.status === "read"
            ? "read"
            : status.status === "failed"
              ? "failed"
              : "sent";

      const patch: Record<string, unknown> = { status: normalizedStatus };
      if (normalizedStatus === "delivered" && status.timestamp) {
        patch.delivered_at = new Date(status.timestamp).toISOString();
      }
      if (normalizedStatus === "read" && status.timestamp) {
        patch.read_at = new Date(status.timestamp).toISOString();
      }
      if (normalizedStatus === "failed" && status.errors?.length) {
        patch.error_message = status.errors
          .map((e) => `${e.code ?? ""} ${e.title ?? ""}`.trim())
          .join("; ");
      }

      let query = supabase
        .from("whatsapp_messages")
        .update(patch)
        .eq("message_id", status.id);

      // Tenant guard: if we resolved the hospital from phone_number_id, scope
      // the update to that hospital as well (defence in depth).
      if (status.recipient_id) {
        const hospitalId = hospitalByPhone.get(status.recipient_id);
        if (hospitalId) query = query.eq("hospital_id", hospitalId);
      }

      const { error } = await query;
      if (error) {
        console.error("whatsapp-webhook: update failed for", status.id, error.message);
      } else {
        updated++;
      }
    }

    return new Response(JSON.stringify({ success: true, updated }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (error) {
    console.error("whatsapp-webhook error:", error);
    return new Response(
      JSON.stringify({ error: error?.message ?? "Internal server error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  }
});
