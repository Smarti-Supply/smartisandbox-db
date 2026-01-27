import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders } from "../_shared/cors.ts";
import { validatePayload } from "./_helpers/validatePayload.ts";
import { ExportResponse } from "./_helpers/types.ts";
import { consolidateData } from "./_helpers/consolidateData.ts";
import { generatePdf } from "./_helpers/generatePdf.ts";
import { sendEmail } from "./_helpers/sendEmail.ts";

Deno.serve(async (req) => {
  console.log("🚀 Edge function export-order-details iniciada");
  console.log("📋 Method:", req.method);

  const origin = req.headers.get("origin");
  const corsHeaders = getCorsHeaders(origin);

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    if (req.method !== "POST") {
      return new Response(
        JSON.stringify({ error: "Método não permitido. Use POST." }),
        {
          status: 405,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        }
      );
    }

    const payload = await req.json();
    const validatedPayload = validatePayload(payload);
    const p = validatedPayload as unknown as Record<string, unknown>;

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    );

    const orderId = p.id_pedido as number;
    const order = p.order as Record<string, unknown>;
    const orderItems = (p.order_items as Record<string, unknown>[]) ?? [];
    const observations = (p.observations as Record<string, unknown>[]) ?? [];
    const followupTracking =
      (p.followup_tracking as Record<string, unknown>[]) ?? [];
    const followupLogs = (p.followup_logs as Record<string, unknown>[]) ?? [];
    const orderItemInvoices =
      (p.order_item_invoices as Record<string, unknown>[]) ?? [];
    const userEmail = p.user_email as string;
    const orderNumber = order?.numero_pedido as string | undefined;

    console.log("📦 Payload validado, consolidando dados...");

    const consolidated = consolidateData(
      orderId,
      order,
      orderItems,
      observations,
      followupTracking,
      orderItemInvoices
    );

    console.log(`✅ Dados consolidados — ${consolidated.length} itens únicos`);

    console.log("📄 Gerando PDF...");
    const pdfBytes = generatePdf(
      order,
      orderItems,
      observations,
      followupTracking,
      followupLogs,
      orderItemInvoices
    );
    console.log(`⏱ PDF gerado — ${pdfBytes.length} bytes`);

    const tableName = `order_details_${orderId}`;
    console.log(`📧 Enviando email para ${userEmail}...`);
    await sendEmail(userEmail, pdfBytes, tableName, orderNumber);
    console.log("✅ Email enviado com sucesso");

    await supabase.from("private.process_logs").insert({
      process_name: "data_export",
      function_name: "export-order-details",
      step: "export_complete",
      status: "success",
      message: `Exportação processada com sucesso para pedido ${orderId}`,
      user_id: p.user_id,
      order_id: orderId,
      metadata: {
        export_id: p.export_id,
        order_items_count: orderItems.length,
        observations_count: observations.length,
        followup_tracking_count: followupTracking.length,
        followup_logs_count: followupLogs.length,
        order_item_invoices_count: orderItemInvoices.length,
      },
    });

    const response: ExportResponse = {
      success: true,
      message: "Exportação processada com sucesso",
      export_id: p.export_id as string,
      id_pedido: orderId,
      order_items_count: orderItems.length,
      observations_count: observations.length,
      followup_tracking_count: followupTracking.length,
      followup_logs_count: followupLogs.length,
      order_item_invoices_count: orderItemInvoices.length,
    };

    return new Response(JSON.stringify(response), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : "Erro desconhecido";
    console.error("❌ Erro:", message);

    try {
      const supabase = createClient(
        Deno.env.get("SUPABASE_URL") ?? "",
        Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
      );
      await supabase.from("private.process_logs").insert({
        process_name: "data_export",
        function_name: "export-order-details",
        step: "error",
        status: "error",
        message,
        user_id: null,
        order_id: null,
        metadata: { error: message },
      });
    } catch (logErr) {
      console.error("Erro ao registrar log:", logErr);
    }

    return new Response(JSON.stringify({ error: message }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 400,
    });
  }
});
