import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders } from "../_shared/cors.ts";
import { processBatch } from "./_helpers/processBatch.ts";
import type { CancelEntry } from "./_helpers/types.ts";

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

  const authHeader = req.headers.get("edge-token");
  if (authHeader !== INTERNAL_EDGE_TOKEN) {
    return new Response("Unauthorized", { status: 401, headers: corsHeaders });
  }

  const entries: CancelEntry[] = await req.json();
  if (!Array.isArray(entries) || entries.length === 0) {
    return new Response("Batch payload inválido", {
      status: 400,
      headers: corsHeaders,
    });
  }

  for (const e of entries) {
    if (
      !Array.isArray(e.supplier_contacts) || e.supplier_contacts.length === 0 ||
      !e.template_html || !e.order_info
    ) {
      return new Response("Campos obrigatórios ausentes em algum entry", {
        status: 400,
        headers: corsHeaders,
      });
    }
  }

  console.log("📥 Total de entradas de cancelamento:", entries.length);
  console.log("📥 Entradas recebidas para processamento:", JSON.stringify(entries, null, 2));
  
  // Executa envio/log em segundo plano
  EdgeRuntime.waitUntil(processBatch(entries));

  return new Response("Enviando cancelamentos em segundo plano", {
    status: 202,
    headers: corsHeaders,
  });
};

Deno.serve(handler);
