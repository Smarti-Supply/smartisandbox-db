import { createClient } from "supabase";
import { getCorsHeaders } from "../_shared/cors.ts";

// Variáveis de ambiente
const INTERNAL_EDGE_TOKEN = Deno.env.get("INTERNAL_EDGE_TOKEN")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESET_PASSWORD_URL = Deno.env.get("RESET_PASSWORD_URL")!;

// Instância do Supabase com SERVICE_ROLE
const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

Deno.serve(async (req: Request): Promise<Response> => {
  const origin = req.headers.get("origin");
  const corsHeaders = getCorsHeaders(origin);
  
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const token = req.headers.get("edge-token");
  if (token !== INTERNAL_EDGE_TOKEN) {
    return new Response("Unauthorized", {
      status: 401,
      headers: corsHeaders,
    });
  }

  const body = await req.json();
  const { company_id, user_email, user_name, role_name, created_by, supplier_letter, user_supplier_id } = body;

  if (!user_email || !user_name || !role_name || !company_id || !created_by) {
    return new Response(
      JSON.stringify({ error: "Campos obrigatórios ausentes." }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  const { data, error } = await supabase.auth.admin.inviteUserByEmail(user_email, {
      redirectTo: RESET_PASSWORD_URL,
      data: {
      company_id,
      user_email,
      user_name,
      role_name,
      created_by,
      supplier_letter, // Custom field for Transpetro
      user_supplier_id, // Custom field for Transpetro
      is_active: true
    },
  });

  if (error) {
    return new Response(JSON.stringify({ error: error.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  return new Response(JSON.stringify({ user: data?.user }), {
    status: 200,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
});
