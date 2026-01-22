import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders } from "../_shared/cors.ts";

// Variáveis de ambiente
const RESET_PASSWORD_URL = Deno.env.get("RESET_PASSWORD_URL")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

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

  try {
    const body = await req.json();
    const { user_email } = body;

    if (!user_email) {
      return new Response(
        JSON.stringify({ error: "Campo obrigatório ausente." }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Verifica se o fornecedor existe
    const { data: companyUser, error: userError } = await supabase
      .schema("public")
      .from("company_users")
      .select("id")
      .eq("email", user_email)
      .single();

    if (userError || !companyUser) {
      // Não envia erro detalhado para evitar enumeração de e-mails
      return new Response(JSON.stringify({ success: true }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Gera magic link
    const { data: _resetSuccess, error: resetError } = await supabase.auth.resetPasswordForEmail(
      user_email,
      {
        redirectTo: RESET_PASSWORD_URL,
      }
    );

    if (resetError) {
      console.error(`Erro ao enviar redefinição de senha para ${user_email}:`, resetError);
      return new Response(JSON.stringify({ success: true }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    return new Response(JSON.stringify({ success: true }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (err) {
    console.error("Erro inesperado:", err);
      return new Response(JSON.stringify({ success: true }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
});
