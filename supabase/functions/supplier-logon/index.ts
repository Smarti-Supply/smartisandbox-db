import { createClient } from "supabase";
import { getCorsHeaders } from "../_shared/cors.ts";

// Variáveis de ambiente
const FOLLOWUP_URL = Deno.env.get("FOLLOWUP_URL")!;
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
    // Primeiro, busca o contato pelo e-mail
    const { data: contact, error: contactError } = await supabase
      .schema("public")
      .from("supplier_contacts")
      .select("id")
      .eq("email", user_email)
      .single();

    if (contactError || !contact) {
        // Não envia erro detalhado para evitar enumeração de e-mails
        return new Response(JSON.stringify({ success: true }), {
          status: 200,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

    // Depois, busca o usuário associado ao contato
    const { data: supplierUser, error: supplierUserError } = await supabase
      .schema("public")
      .from("supplier_users")
      .select("id, role_id, last_login")
      .eq("supplier_contact_id", contact.id)
      .single();

    if (supplierUserError || !supplierUser) {
      // Não envia erro detalhado para evitar enumeração de e-mails
      return new Response(JSON.stringify({ success: true }), {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Gera magic link
    const { data: _linkSuccess, error: linkError } = await supabase.auth.signInWithOtp({
      email: user_email,
      options: {
        emailRedirectTo: FOLLOWUP_URL,
        shouldCreateUser: false,
      },
    });

    if (linkError) {
      console.error(`Erro ao gerar magic link para ${user_email}:`, linkError);
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
