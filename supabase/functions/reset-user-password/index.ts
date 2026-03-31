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

    // Verifica se existe um usuário interno (company_user) com esse e-mail
    const { data: companyUser, error: userError } = await supabase
      .schema("public")
      .from("company_users")
      .select("id")
      .eq("email", user_email)
      .single();

    if (!userError && companyUser) {
      // Usuário interno encontrado: gera link de redefinição de senha
      const { data: _resetSuccess, error: resetError } =
        await supabase.auth.resetPasswordForEmail(
          user_email,
          {
            redirectTo: RESET_PASSWORD_URL,
          },
        );

      if (resetError) {
        console.error(
          `Erro ao enviar redefinição de senha para ${user_email}:`,
          resetError,
        );
      }
    } else {
      // Tenta fluxo para fornecedor (supplier) com o mesmo e-mail
      const { data: supplierContact, error: supplierContactError } =
        await supabase
          .schema("public")
          .from("supplier_contacts")
          .select("id")
          .eq("email", user_email)
          .single();

      if (!supplierContactError && supplierContact) {
        const { data: supplierUser, error: supplierUserError } = await supabase
          .schema("public")
          .from("supplier_users")
          .select("id")
          .eq("supplier_contact_id", supplierContact.id)
          .single();

        if (!supplierUserError && supplierUser) {
          const { data: _resetSuccess, error: resetError } =
            await supabase.auth.resetPasswordForEmail(
              user_email,
              {
                redirectTo: RESET_PASSWORD_URL,
              },
            );

          if (resetError) {
            console.error(
              `Erro ao enviar redefinição de senha para fornecedor ${user_email}:`,
              resetError,
            );
          }
        }
      }
    }

    // Nunca expõe se o e-mail é válido ou não; sempre retorna sucesso
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
