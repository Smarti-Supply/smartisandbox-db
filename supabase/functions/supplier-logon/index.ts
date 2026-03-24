import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders } from "../_shared/cors.ts";
import {
  isEmailSendRateLimited,
  isWithinMagicLinkCooldown,
  MAGIC_LINK_COOLDOWN_MS,
} from "../_shared/magic_link_cooldown.ts";

const FOLLOWUP_URL = Deno.env.get("FOLLOWUP_URL")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

function jsonResponse(
  body: Record<string, unknown>,
  status: number,
  corsHeaders: HeadersInit,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request): Promise<Response> => {
  const origin = req.headers.get("origin");
  const corsHeaders = getCorsHeaders(origin);

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const body = await req.json();
    const { user_email } = body;

    if (!user_email) {
      return jsonResponse(
        { error: "Campo obrigatório ausente." },
        400,
        corsHeaders,
      );
    }

    const { data: contact, error: contactError } = await supabase
      .schema("public")
      .from("supplier_contacts")
      .select("id")
      .eq("email", user_email)
      .single();

    if (contactError || !contact) {
      return jsonResponse({ success: true }, 200, corsHeaders);
    }

    const { data: supplierUser, error: supplierUserError } = await supabase
      .schema("public")
      .from("supplier_users")
      .select("id, role_id, last_login, last_magic_link_requested_at")
      .eq("supplier_contact_id", contact.id)
      .single();

    if (supplierUserError || !supplierUser) {
      return jsonResponse({ success: true }, 200, corsHeaders);
    }

    const nowMs = Date.now();
    if (
      isWithinMagicLinkCooldown(
        supplierUser.last_magic_link_requested_at as string | null,
        MAGIC_LINK_COOLDOWN_MS,
        nowMs,
      )
    ) {
      return jsonResponse({ success: true }, 200, corsHeaders);
    }

    const { error: linkError } = await supabase.auth.signInWithOtp({
      email: user_email,
      options: {
        emailRedirectTo: FOLLOWUP_URL,
        shouldCreateUser: false,
      },
    });

    if (linkError) {
      if (isEmailSendRateLimited(linkError)) {
        console.warn(
          `Magic link rate limited for ${user_email}:`,
          linkError.message,
        );
      } else {
        console.error(`Failed to send magic link for ${user_email}:`, linkError);
      }
      return jsonResponse({ success: true }, 200, corsHeaders);
    }

    const { error: updateError } = await supabase
      .schema("public")
      .from("supplier_users")
      .update({ last_magic_link_requested_at: new Date().toISOString() })
      .eq("id", supplierUser.id);

    if (updateError) {
      console.error(
        "Failed to persist last_magic_link_requested_at:",
        updateError,
      );
    }

    return jsonResponse({ success: true }, 200, corsHeaders);
  } catch (err) {
    console.error("Unexpected error in supplier-logon:", err);
    return jsonResponse({ success: true }, 200, corsHeaders);
  }
});
