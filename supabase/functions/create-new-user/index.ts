import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
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
  const { company_id, user_email, user_name, role_name, user_password, created_by, supplier_letter, user_supplier_id } = body;

  if (!user_email || !user_name || !role_name || !user_password || !company_id || !created_by) {
    return new Response(
      JSON.stringify({ error: "Campos obrigatórios ausentes." }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  // Criar usuário primeiro sem senha (ou com senha temporária)
  const { data: createData, error: createError } = await supabase.auth.admin.createUser({
    email: user_email,
    email_confirm: true,
    user_metadata: {
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

  if (createError || !createData?.user) {
    return new Response(JSON.stringify({ error: createError?.message || "Erro ao criar usuário" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  // Atualizar a senha explicitamente após criar o usuário
  const { data: updateData, error: updateError } = await supabase.auth.admin.updateUserById(
    createData.user.id,
    {
      password: user_password,
    }
  );

  if (updateError) {
    // Se falhar ao atualizar senha, tenta deletar o usuário criado
    await supabase.auth.admin.deleteUser(createData.user.id);
    return new Response(JSON.stringify({ error: `Erro ao definir senha: ${updateError.message}` }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  return new Response(JSON.stringify({ user: updateData?.user || createData?.user }), {
    status: 200,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
});
