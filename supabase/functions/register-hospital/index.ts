// ======================================================================
// HIMS - Hospital Registration Edge Function
//
// Creates the hospital + first admin in one service-role call:
//   1. Auth user (email_confirm: true => Supabase sends NO email, so the
//      free-plan email rate limit can never block registration).
//   2. hospitals row (unique `code` auto-generated).
//   3. users row linking the admin to the hospital.
//
// Deploy:
//   supabase functions deploy register-hospital
// (SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are auto-injected by Supabase.)
// ======================================================================

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  try {
    const body = await req.json();
    const {
      hospital_name,
      address,
      city,
      state,
      pincode,
      phone,
      email,
      registration_number,
      logo_url,
      admin_first_name,
      admin_last_name,
      admin_email,
      admin_password,
      admin_role = "admin",
    } = body;

    if (!hospital_name || !admin_first_name || !admin_email || !admin_password) {
      return new Response(
        JSON.stringify({
          error:
            "Missing required fields: hospital_name, admin_first_name, admin_email, admin_password",
        }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    if (!supabaseUrl || !serviceRoleKey) {
      return new Response(
        JSON.stringify({
          error: "SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY not configured",
        }),
        {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    // 1. Find-or-create the auth user. email_confirm: true => no email sent.
    let authUserId: string | undefined;

    const { data: created, error: createError } =
      await supabaseAdmin.auth.admin.createUser({
        email: admin_email,
        password: admin_password,
        email_confirm: true,
        user_metadata: {
          role: admin_role,
          first_name: admin_first_name,
          last_name: admin_last_name ?? "",
        },
      });

    if (createError) {
      const message = (createError.message ?? "").toLowerCase();
      if (message.includes("already") || message.includes("duplicate")) {
        // The email already exists in Auth (e.g. from a previous failed
        // attempt). Find its id and reset the password/confirm state.
        const existing = await findUserByEmail(supabaseAdmin, admin_email);
        if (!existing) {
          return new Response(
            JSON.stringify({
              error:
                "This admin email is already registered. Use a different email or login with this email.",
            }),
            {
              status: 409,
              headers: { ...corsHeaders, "Content-Type": "application/json" },
            },
          );
        }
        authUserId = existing.id;
        await supabaseAdmin.auth.admin.updateUserById(authUserId, {
          password: admin_password,
          email_confirm: true,
          user_metadata: {
            role: admin_role,
            first_name: admin_first_name,
            last_name: admin_last_name ?? "",
          },
        });
      } else {
        return new Response(JSON.stringify({ error: createError.message }), {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
    } else {
      authUserId = created?.user?.id;
    }

    if (!authUserId) {
      return new Response(
        JSON.stringify({ error: "Could not create the auth user" }),
        {
          status: 500,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    // 2. Create the hospital row (`code` is NOT NULL + UNIQUE).
    const { data: hospital, error: hospitalError } = await supabaseAdmin
      .from("hospitals")
      .insert({
        name: hospital_name,
        code: `HOSP${Date.now()}`,
        address: address ?? null,
        city: city ?? null,
        state: state ?? null,
        pincode: pincode ?? null,
        phone: phone ?? null,
        email: email ?? null,
        registration_number: registration_number ?? null,
        logo_url: logo_url ?? null,
        is_active: true,
      })
      .select()
      .single();

    if (hospitalError) {
      return new Response(JSON.stringify({ error: hospitalError.message }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // 3. Link the admin to the hospital in public.users.
    const { data: userRow, error: userError } = await supabaseAdmin
      .from("users")
      .insert({
        auth_id: authUserId,
        hospital_id: hospital.id,
        first_name: admin_first_name,
        last_name: admin_last_name || null,
        email: admin_email,
        role: admin_role,
        is_active: true,
      })
      .select()
      .single();

    if (userError) {
      // Clean up the just-created hospital so a retry stays idempotent.
      await supabaseAdmin.from("hospitals").delete().eq("id", hospital.id);
      return new Response(JSON.stringify({ error: userError.message }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    return new Response(
      JSON.stringify({
        success: true,
        hospital_id: hospital.id,
        user_id: userRow.id,
        auth_user_id: authUserId,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } },
    );
  } catch (error) {
    const message = (error as Error)?.message ?? "Internal server error";
    return new Response(JSON.stringify({ error: message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});

/** Paginates auth.users to find an auth id by email. */
async function findUserByEmail(
  supabaseAdmin: ReturnType<typeof createClient>,
  email: string,
): Promise<{ id: string } | null> {
  const target = email.toLowerCase();
  let page = 1;

  while (true) {
    const { data, error } = await supabaseAdmin.auth.admin.listUsers({
      page,
      perPage: 1000,
    });
    if (error) return null;

    const users = (data?.users ?? []) as Array<{ id: string; email?: string }>;
    const found = users.find((u) => u.email?.toLowerCase() === target);
    if (found) return found;

    if (users.length < 1000) return null;
    page += 1;
  }
}
