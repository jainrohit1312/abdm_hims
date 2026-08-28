// ======================================================================
// HIMS - send-fcm Edge Function (Firebase Admin SDK on Supabase)
// ----------------------------------------------------------------------
// Flutter app ke `push_notification_service.dart` se invoke hoti hai aur
// Firebase Admin SDK (Node.js `firebase-admin`) use karke
// `hospital_{hospitalId}` topic par `messaging().send()` call karti hai.
//
// NOTE: Ye wahi kaam hai jo Dart `firebase_admin` package ka
// `ServiceAccount.fromJson()` + `messaging().send()` flow karta hai —
// Node.js Admin SDK mein service-account JSON `cert(serviceAccount)` ke
// through load hota hai. Private key server-side secret ke roop mein rehti
// hai (client app mein kabhi bundle nahi hoti).
//
// Deploy steps:
//   1. supabase functions deploy send-fcm
//   2. supabase secrets set FIREBASE_ADMIN_SDK_JSON="$(cat assets/config/firebase_admin_sdk.json)"
// ======================================================================

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { cert, getApps, initializeApp } from "npm:firebase-admin@12.4.0/app";
import { getMessaging } from "npm:firebase-admin@12.4.0/messaging";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

interface SendFcmPayload {
  hospital_id: string;
  topic?: string;
  title: string;
  message: string;
  notification_type?: string;
  link_url?: string;
  target_roles?: string[];
}

serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({ error: "Method not allowed" }),
      {
        status: 405,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }

  try {
    const body: SendFcmPayload = await req.json();
    const {
      hospital_id,
      topic,
      title,
      message,
      notification_type = "info",
      link_url = "",
      target_roles = [],
    } = body;

    if (!hospital_id || !title || !message) {
      return new Response(
        JSON.stringify({
          error: "Missing required fields: hospital_id, title, message",
        }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    // -- Auth: Supabase JWT verify + hospital scope check -------------------
    // Sirf usi hospital ka staff apne hospital ke topic par push bhej sakta
    // hai (cross-tenant push spam roka jaata hai).
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const authHeader = req.headers.get("Authorization") ?? "";

    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } },
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const {
      data: { user },
      error: authError,
    } = await supabase.auth.getUser();
    if (authError || !user) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { data: staffRow } = await supabase
      .from("users")
      .select("hospital_id")
      .eq("auth_id", user.id)
      .maybeSingle();

    if (!staffRow || staffRow.hospital_id !== hospital_id) {
      return new Response(
        JSON.stringify({ error: "Forbidden: hospital mismatch" }),
        {
          status: 403,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    // -- Firebase Admin SDK init -------------------------------------------
    // `assets/config/firebase_admin_sdk.json` ki poori content Edge Function
    // secret `FIREBASE_ADMIN_SDK_JSON` mein set karo.
    const serviceAccountJson = Deno.env.get("FIREBASE_ADMIN_SDK_JSON");
    if (!serviceAccountJson) {
      return new Response(
        JSON.stringify({
          error: "FIREBASE_ADMIN_SDK_JSON secret is not set",
        }),
        {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    const serviceAccount = JSON.parse(serviceAccountJson);

    if (getApps().length === 0) {
      initializeApp({
        credential: cert(serviceAccount),
        projectId: serviceAccount.project_id,
      });
    }

    const messaging = getMessaging();
    const fcmTopic =
      topic && topic.length > 0 ? topic : `hospital_${hospital_id}`;

    // -- Send notification ---------------------------------------------------
    const messageId = await messaging.send({
      topic: fcmTopic,
      notification: {
        title,
        body: message,
      },
      android: {
        priority: "high",
        notification: {
          channelId: "hims_notifications",
          sound: "default",
        },
      },
      apns: {
        headers: { "apns-priority": "10" },
        payload: { aps: { sound: "default" } },
      },
      data: {
        hospital_id,
        notification_type,
        link_url,
        target_roles: JSON.stringify(target_roles ?? []),
        click_action: "FLUTTER_NOTIFICATION_CLICK",
      },
    });

    return new Response(
      JSON.stringify({
        success: true,
        message_id: messageId,
        topic: fcmTopic,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (error) {
    console.error("send-fcm error:", error);
    return new Response(
      JSON.stringify({ error: error.message || "Internal server error" }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }
});
