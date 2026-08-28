// Follow this setup guide to integrate the Deno runtime with Supabase:
// https://supabase.com/docs/guides/functions

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

interface AdminUserPayload {
  email: string;
  password: string;
  firstName: string;
  lastName: string;
  role?: string;
  hospitalCode?: string;
}

serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // Only allow POST
    if (req.method !== "POST") {
      return new Response(
        JSON.stringify({ error: "Method not allowed" }),
        { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Parse request body
    const body: AdminUserPayload = await req.json();
    const {
      email,
      password,
      firstName,
      lastName,
      role = "admin",
      hospitalCode = "HIMS",
    } = body;

    // Validate required fields
    if (!email || !password || !firstName || !lastName) {
      return new Response(
        JSON.stringify({ error: "Missing required fields: email, password, firstName, lastName" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Create Supabase client with SERVICE_ROLE key (has admin privileges)
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "http://127.0.0.1:54321";
    const supabaseServiceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    
    if (!supabaseServiceRoleKey) {
      return new Response(
        JSON.stringify({ error: "SUPABASE_SERVICE_ROLE_KEY environment variable is required" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const supabaseAdmin = createClient(supabaseUrl, supabaseServiceRoleKey, {
      auth: {
        autoRefreshToken: false,
        persistSession: false,
      },
    });

    // Step 1: Create auth user via Admin API (GoTrue handles hashing correctly)
    const { data: authUser, error: authError } = await supabaseAdmin.auth.admin.createUser({
      email,
      password,
      email_confirm: true, // Skip email verification
      user_metadata: {
        role,
        first_name: firstName,
        last_name: lastName,
      },
    });

    if (authError) {
      // If user already exists, that's acceptable
      if (authError.message?.includes("already exists") || 
          authError.message?.includes("duplicate")) {
        console.log(`User ${email} already exists, proceeding to link...`);
      } else {
        return new Response(
          JSON.stringify({ error: authError.message }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }
    }

    const authUserId = authUser?.user?.id;
    
    // Step 2: Link to public.users table if we have the auth id
    if (authUserId) {
      const { error: linkError } = await supabaseAdmin
        .from("users")
        .upsert(
          {
            auth_id: authUserId,
            hospital_id: await getHospitalId(supabaseAdmin, hospitalCode),
            first_name: firstName,
            last_name: lastName,
            email: email,
            role: role,
            is_active: true,
          },
          { onConflict: "email" }
        );

      if (linkError) {
        console.error("Error linking admin to users table:", linkError);
        // Non-fatal — auth user was created successfully
      }
    }

    return new Response(
      JSON.stringify({
        success: true,
        message: `Admin user ${email} created successfully`,
        user: authUser?.user,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("Unexpected error:", error);
    return new Response(
      JSON.stringify({ error: error.message || "Internal server error" }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});

/**
 * Get hospital ID by code
 */
async function getHospitalId(
  supabaseAdmin: ReturnType<typeof createClient>,
  hospitalCode: string
): Promise<string | null> {
  const { data } = await supabaseAdmin
    .from("hospitals")
    .select("id")
    .eq("code", hospitalCode)
    .single();
  return data?.id ?? null;
}