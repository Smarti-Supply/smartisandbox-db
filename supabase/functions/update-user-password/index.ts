import { createClient } from "supabase";
import { getCorsHeaders } from "../_shared/cors.ts";

// Variáveis de ambiente
const INTERNAL_EDGE_TOKEN = Deno.env.get("INTERNAL_EDGE_TOKEN")!;
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

  const token = req.headers.get("edge-token");
  if (token !== INTERNAL_EDGE_TOKEN) {
    return new Response("Unauthorized", {
      status: 401,
      headers: corsHeaders,
    });
  }

  const body = await req.json();
  const { user_id, new_password } = body;

  if (!user_id || !new_password) {
    return new Response(
      JSON.stringify({ error: "ID do usuário e nova senha são obrigatórios." }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Buscar o email primeiro em company_users, se não encontrar, buscar em auth.users
  let userEmail: string | null = null;

  // Tentar buscar em company_users primeiro
  const { data: companyUser, error: companyUserError } = await supabase
    .schema("public")
    .from("company_users")
    .select("email")
    .eq("id", user_id)
    .single();

  if (!companyUserError && companyUser) {
    userEmail = companyUser.email;
  } else {
    // Se não encontrou em company_users, buscar em auth.users
    const { data: authUser, error: authUserError } = await supabase.auth.admin.getUserById(user_id);
    
    if (authUserError || !authUser?.user) {
      return new Response(JSON.stringify({ error: "Usuário não encontrado." }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    
    userEmail = authUser.user.email || null;
  }

  if (!userEmail) {
    return new Response(JSON.stringify({ error: "Email do usuário não encontrado." }), {
      status: 404,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  // Atualizar a senha do usuário usando o ID diretamente
  const { data: updateData, error: updateError } = await supabase.auth.admin.updateUserById(
    user_id,
    {
      password: new_password,
    }
  );

  if (updateError) {
    return new Response(JSON.stringify({ error: `Erro ao atualizar senha: ${updateError.message}` }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  return new Response(JSON.stringify({ 
    success: true,
    message: "Senha atualizada com sucesso",
    user_id: user_id,
    email: userEmail,
    user: updateData?.user 
  }), {
    status: 200,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
});

