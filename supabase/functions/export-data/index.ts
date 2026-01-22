import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders } from "../_shared/cors.ts";
import { validatePayload } from "./_helpers/validatePayload.ts";
import { ExportResponse } from "./_helpers/types.ts";

Deno.serve(async (req) => {
  console.log('🚀 Edge function export-data iniciada');
  console.log('📋 Method:', req.method);
  
  const origin = req.headers.get("origin");
  const corsHeaders = getCorsHeaders(origin);
  
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // Validar método HTTP
    if (req.method !== "POST") {
      return new Response(
        JSON.stringify({ error: "Método não permitido. Use POST." }),
        { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Obter payload e validar
    const payload = await req.json();
    console.log('📦 Payload recebido:', JSON.stringify(payload, null, 2));
    
    const validatedPayload = validatePayload(payload);
    console.log('✅ Payload validado com sucesso');

    // Criar cliente Supabase
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    // Obter credenciais AWS das variáveis de ambiente
    console.log('🔍 Buscando credenciais AWS das variáveis de ambiente...');
    
    const awsToken = Deno.env.get("AWS_TOKEN");
    const awsApiKey = Deno.env.get("AWS_API_KEY");
    const awsApiUrl = Deno.env.get("AWS_API_URL");

    // Log das credenciais AWS obtidas
    console.log('🔑 Credenciais AWS obtidas:');
    console.log('  - AWS Token:', awsToken ? '✅ Presente' : '❌ Ausente');
    console.log('  - AWS API Key:', awsApiKey ? '✅ Presente' : '❌ Ausente');
    console.log('  - AWS API URL:', awsApiUrl);

    if (!awsToken || !awsApiKey || !awsApiUrl) {
      throw new Error("Credenciais AWS não encontradas nas variáveis de ambiente");
    }

    // Preparar payload para AWS Lambda
    const awsPayload = {
      table_name: validatedPayload.table_name,
      data: validatedPayload.data,
      user_id: validatedPayload.user_id,
      company_id: validatedPayload.company_id,
      user_email: validatedPayload.user_email
    };

    // Chamar AWS Lambda
    console.log('🌐 Chamando AWS Lambda:', `${awsApiUrl}/process-export`);
    console.log('📤 Payload para AWS:', JSON.stringify(awsPayload, null, 2));
    
    const awsResponse = await fetch(`${awsApiUrl}/process-export`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "internal-token": awsToken,
        "x-api-key": awsApiKey
      },
      body: JSON.stringify(awsPayload)
    });

    // Log da resposta da AWS
    console.log('📡 Resposta da AWS:', {
      status: awsResponse.status,
      ok: awsResponse.ok,
      statusText: awsResponse.statusText,
      headers: Object.fromEntries(awsResponse.headers.entries())
    });

    if (!awsResponse.ok) {
      const errorText = await awsResponse.text();
      console.log('❌ Erro na AWS Lambda:', errorText);
      throw new Error(`Erro na AWS Lambda: ${awsResponse.status} - ${errorText}`);
    }

    const awsResult = await awsResponse.json();
    console.log('📋 Resultado da AWS:', JSON.stringify(awsResult, null, 2));

    // Log de sucesso
    await supabase
      .from("private.process_logs")
      .insert({
        process_name: "data_export",
        function_name: "export-data",
        step: "aws_lambda_call",
        status: "success",
        message: `Exportação processada com sucesso para tabela ${validatedPayload.table_name}`,
        user_id: validatedPayload.user_id,
        order_id: null,
        metadata: {
          export_id: validatedPayload.export_id,
          table_name: validatedPayload.table_name,
          data_count: validatedPayload.data.length,
          aws_response: awsResult
        }
      });

    console.log('✅ Exportação processada com sucesso!');

    // Resposta de sucesso
    const response: ExportResponse = {
      success: true,
      message: "Exportação processada com sucesso",
      export_id: validatedPayload.export_id,
      table_name: validatedPayload.table_name,
      data_count: validatedPayload.data.length
    };

    return new Response(JSON.stringify(response), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200
    });

  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : "Erro desconhecido";
    
    // Log de erro
    try {
      const supabase = createClient(
        Deno.env.get("SUPABASE_URL") ?? "",
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
      );

      await supabase
        .from("private.process_logs")
        .insert({
          process_name: "data_export",
          function_name: "export-data",
          step: "error",
          status: "error",
          message: message,
          user_id: null,
          order_id: null,
          metadata: { error: message }
        });
    } catch (logError) {
      console.error("Erro ao registrar log:", logError);
    }

    return new Response(JSON.stringify({ error: message }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 400
    });
  }
});