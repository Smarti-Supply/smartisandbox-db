import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders } from "../_shared/cors.ts";
import { validatePayload } from "./_helpers/validatePayload.ts";
import { ExportResponse } from "./_helpers/types.ts";

Deno.serve(async (req) => {
  console.log('🚀 Edge function export-order-details iniciada');
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
    console.log('📊 Detalhes do payload:');
    console.log('  - id_pedido:', payload.id_pedido);
    console.log('  - observations count:', payload.observations?.length || 0);
    console.log('  - followup_tracking count:', payload.followup_tracking?.length || 0);
    if (payload.observations && payload.observations.length > 0) {
      console.log('  - Primeira observation:', JSON.stringify(payload.observations[0], null, 2));
    }
    if (payload.followup_tracking && payload.followup_tracking.length > 0) {
      console.log('  - Primeiro followup_tracking:', JSON.stringify(payload.followup_tracking[0], null, 2));
    }
    
    const validatedPayload = validatePayload(payload);
    console.log('✅ Payload validado com sucesso');
    console.log('📊 Detalhes após validação:');
    console.log('  - observations count:', validatedPayload.observations.length);
    console.log('  - followup_tracking count:', validatedPayload.followup_tracking.length);
    
    // Usar validatedPayload diretamente - o tipo já está correto do validatePayload
    const payloadData = validatedPayload;

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
    const p = payloadData as unknown as Record<string, unknown>;
    const awsPayload = {
      id_pedido: p.id_pedido,
      order: p.order,
      order_items: p.order_items,
      observations: p.observations,
      followup_tracking: p.followup_tracking,
      order_item_invoices: p.order_item_invoices,
      user_id: p.user_id,
      company_id: p.company_id,
      user_email: p.user_email
    };

    // Chamar AWS Lambda
    console.log('🌐 Chamando AWS Lambda:', `${awsApiUrl}/process-order-details-export`);
    console.log('📤 Payload para AWS:', JSON.stringify(awsPayload, null, 2));
    
    const awsResponse = await fetch(`${awsApiUrl}/process-order-details-export`, {
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
    const pForLog = payloadData as unknown as Record<string, unknown>;
    await supabase
      .from("private.process_logs")
      .insert({
        process_name: "data_export",
        function_name: "export-order-details",
        step: "aws_lambda_call",
        status: "success",
        message: `Exportação processada com sucesso para pedido ${pForLog.id_pedido}`,
        user_id: pForLog.user_id,
        metadata: {
          export_id: pForLog.export_id,
          id_pedido: pForLog.id_pedido,
          order_items_count: (pForLog.order_items as unknown[]).length,
          observations_count: (pForLog.observations as unknown[]).length,
          followup_tracking_count: (pForLog.followup_tracking as unknown[]).length,
          order_item_invoices_count: (pForLog.order_item_invoices as unknown[]).length,
          aws_response: awsResult
        }
      });

    console.log('✅ Exportação processada com sucesso!');

    // Resposta de sucesso
    const pForResponse = payloadData as unknown as Record<string, unknown>;
    const response = {
      success: true,
      message: "Exportação processada com sucesso",
      export_id: pForResponse.export_id,
      id_pedido: pForResponse.id_pedido,
      order_items_count: (pForResponse.order_items as unknown[]).length,
      observations_count: (pForResponse.observations as unknown[]).length,
      followup_tracking_count: (pForResponse.followup_tracking as unknown[]).length,
      order_item_invoices_count: (pForResponse.order_item_invoices as unknown[]).length
    } as ExportResponse;

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
          function_name: "export-order-details",
          step: "error",
          status: "error",
          message: message,
          user_id: null,
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

