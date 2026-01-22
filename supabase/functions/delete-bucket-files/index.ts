import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders } from "../_shared/cors.ts";

// Variáveis de ambiente
const INTERNAL_EDGE_TOKEN = Deno.env.get("INTERNAL_EDGE_TOKEN")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Supabase client com service role
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

  let body;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "Invalid JSON body" }), {
      status: 400,
      headers: corsHeaders,
    });
  }

  const { buckets, path } = body;

  if (!Array.isArray(buckets) || typeof path !== "string") {
    return new Response(JSON.stringify({
      error: "Invalid payload: expected { buckets: string[], path: string }",
    }), {
      status: 400,
      headers: corsHeaders,
    });
  }

  console.log(`📂 Deletando pasta de pedidos '${path}' dos buckets:`, buckets);

  const results: Record<string, { success: boolean; error?: string }> = {};

  for (const bucket of buckets) {
    const { data, error } = await supabase.storage.from(bucket).list(path);

    if (error) {
      results[bucket] = { success: false, error: `List failed: ${error.message}` };
      continue;
    }

    if (data.length === 0) {
      console.log(`📭 Arquivos não encontrados em '${bucket}/${path}' — pulando esta remoção...`);
      results[bucket] = { success: true }; // Nothing to delete
      continue;
    }

    const filesToRemove = data.map((file) => `${path}${file.name}`);
    console.log(`🗑️ Removendo ${filesToRemove.length} arquivo(s) do bucket '${bucket}'`);
    const { error: removeError } = await supabase.storage
      .from(bucket)
      .remove(filesToRemove);

    if (removeError) {
      console.error(`❌ Falha ao remover arquivos do bucket '${bucket}':`, removeError.message);
      results[bucket] = {
        success: false,
        error: `Remove failed: ${removeError.message}`,
      };
    } else {
      console.log(`✅ Arquivos removidos com sucesso do bucket '${bucket}'`);
      results[bucket] = { success: true };
    }
  }

  const failed = Object.values(results).some((r) => !r.success);
  const status = failed ? 207 : 200;

  console.log("📊 Arquivos deletados:", JSON.stringify(results, null, 2));

  return new Response(JSON.stringify({ path, results }), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
});

