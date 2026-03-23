import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders } from "../_shared/cors.ts";
import { sendOpsAlert } from "../_shared/sendOpsAlert.ts";
import { processBatch } from "./_helpers/processBatch.ts";
import type { Entry } from "./_helpers/types.ts";

// Declaração segura para evitar erro de lint
declare const EdgeRuntime: {
  waitUntil(promise: Promise<void>): void;
};

// Listener para encerramento da função
addEventListener("beforeunload", () => {
  console.log("🛑 Edge Function será encerrada.");
});

// Variáveis de ambiente
const INTERNAL_EDGE_TOKEN = Deno.env.get("INTERNAL_EDGE_TOKEN")!;

// Instâncias
const _supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } }
);

const handler = async (req: Request): Promise<Response> => {
  const origin = req.headers.get("origin");
  const corsHeaders = getCorsHeaders(origin);

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("edge-token");
    if (authHeader !== INTERNAL_EDGE_TOKEN) {
      return new Response("Unauthorized", { status: 401, headers: corsHeaders });
    }

    const entries: Entry[] = await req.json();
    if (!Array.isArray(entries) || entries.length === 0) {
      return new Response("Batch payload inválido", {
        status: 400,
        headers: corsHeaders,
      });
    }

    for (const e of entries) {
      if (
        !Array.isArray(e.supplier_contacts) || e.supplier_contacts.length === 0 ||
        !e.template_html || !e.orders_payload
      ) {
        return new Response("Campos obrigatórios ausentes em algum entry", {
          status: 400,
          headers: corsHeaders,
        });
      }
    }

    console.log("📥 Total de entradas:", entries.length);
    console.log(
      "📥 Entradas recebidas para processamento:",
      JSON.stringify(entries, null, 2),
    );

    // Executa envio/log em segundo plano
    EdgeRuntime.waitUntil(processBatch(entries, _supabase));

    return new Response("Enviando em segundo plano", {
      status: 202,
      headers: corsHeaders,
    });
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    const whenIsoUtc = new Date().toISOString();
    await sendOpsAlert({
      subjectSuffix: "send-followup handler não tratado",
      dedupeKey: `handler_unhandled|${msg.slice(0, 200)}`,
      supabase: _supabase,
      fields: {
        what: "Exceção não tratada no handler da Edge send-followup.",
        where: "supabase/functions/send-followup/index.ts",
        impact: "A requisição pode não ter sido processada corretamente.",
        error: msg,
        context: "—",
        orderNumbers: [],
        whenIsoUtc,
        suggestion: "Ver logs da Edge no painel Supabase e corrigir o handler.",
      },
    });
    return new Response("Erro interno", {
      status: 500,
      headers: corsHeaders,
    });
  }
};

Deno.serve(handler);
