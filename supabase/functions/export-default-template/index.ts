import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import * as XLSX from "https://esm.sh/xlsx@0.18.5";
import { getCorsHeaders } from "../_shared/cors.ts";

Deno.serve(async (req) => {
  const origin = req.headers.get("origin");
  const corsHeaders = getCorsHeaders(origin);
  
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");

    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      return new Response(
        JSON.stringify({ error: "Token de autenticação ausente ou inválido." }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const token = authHeader.replace("Bearer ", "");

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    const { data: userData, error: authError } = await supabase.auth.getUser(token)

    if (authError || !userData) {
      return new Response(
        JSON.stringify({ error: "Usuário não autenticado." }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Recuperar company_id do usuário autenticado
    const { data } = await supabase
      .from("company_users")
      .select("company_id")
      .eq("id", userData.user.id)
      .single();

    if (!data) throw new Error("Company not found");

    const company_id = data.company_id;

    // Extrair tipo do corpo da requisição
    const { type } = await req.json();
    if (!type) throw new Error("Missing type in request body");

    // Buscar mapeamento default da empresa
    const { data: mappingData } = await supabase
      .from("import_field_mappings")
      .select("default_field_mapping")
      .eq("company_id", company_id)
      .eq("type", type)
      .single();

    if (!mappingData) throw new Error("Mapping not found");

    const defaultMapping = mappingData.default_field_mapping;

    // Obter os field_label como cabeçalhos
    const mappingKey = Object.keys(defaultMapping)[0]; // Assume que há apenas uma chave no objeto
    const headers = defaultMapping[mappingKey].map(
      (field: { field_label: string }) => field.field_label
    );

    // Criar a planilha
    const ws = XLSX.utils.aoa_to_sheet([headers]);
    const wb = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(wb, ws, "Template");

    const xlsxBuffer = XLSX.write(wb, { type: "buffer", bookType: "xlsx" });

    const responseHeaders = new Headers({
      ...corsHeaders,
      "Content-Type": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      "Content-Disposition": `attachment; filename="template-${type}.xlsx"`
    });

    return new Response(xlsxBuffer, { headers: responseHeaders });
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : "Erro desconhecido";
    return new Response(JSON.stringify({ error: message }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 400
    });
  }
});
