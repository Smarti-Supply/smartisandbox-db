import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { getCorsHeaders } from "../_shared/cors.ts";
import {
  sendOpsAlert,
  type OpsAlertFields,
} from "../_shared/sendOpsAlert.ts";

const INTERNAL_EDGE_TOKEN = Deno.env.get("INTERNAL_EDGE_TOKEN")!;

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } },
);

export type NotifyOpsPayload = {
  subject_suffix: string;
  what: string;
  where: string;
  impact: string;
  error: string;
  context: string;
  order_numbers?: string[];
  suggestion?: string;
};

function normalizePayload(body: unknown): NotifyOpsPayload | null {
  if (!body || typeof body !== "object") return null;
  const o = body as Record<string, unknown>;
  const str = (k: string) =>
    typeof o[k] === "string" ? (o[k] as string) : "";
  const order_numbers = Array.isArray(o.order_numbers)
    ? (o.order_numbers as unknown[]).filter((x): x is string =>
      typeof x === "string"
    )
    : typeof o.order_numbers === "string"
    ? o.order_numbers.split(",").map((s) => s.trim()).filter(Boolean)
    : [];

  const subject_suffix = str("subject_suffix");
  if (!subject_suffix) return null;

  return {
    subject_suffix,
    what: str("what") || "—",
    where: str("where") || "—",
    impact: str("impact") || "—",
    error: str("error") || "—",
    context: str("context") || "—",
    order_numbers,
    suggestion: str("suggestion") || "—",
  };
}

Deno.serve(async (req: Request): Promise<Response> => {
  const origin = req.headers.get("origin");
  const corsHeaders = getCorsHeaders(origin);

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response("Method not allowed", {
      status: 405,
      headers: corsHeaders,
    });
  }

  const authHeader = req.headers.get("edge-token");
  if (authHeader !== INTERNAL_EDGE_TOKEN) {
    return new Response("Unauthorized", { status: 401, headers: corsHeaders });
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return new Response("JSON inválido", { status: 400, headers: corsHeaders });
  }

  const p = normalizePayload(body);
  if (!p) {
    return new Response("Payload inválido (subject_suffix obrigatório)", {
      status: 400,
      headers: corsHeaders,
    });
  }

  const whenIsoUtc = new Date().toISOString();
  const fields: OpsAlertFields = {
    what: p.what,
    where: p.where,
    impact: p.impact,
    error: p.error,
    context: p.context,
    orderNumbers: p.order_numbers ?? [],
    whenIsoUtc,
    suggestion: p.suggestion ?? "—",
  };

  const dedupeKey = `${p.subject_suffix}|${p.error.slice(0, 200)}|${
    (p.order_numbers ?? []).join(",")
  }`;

  const result = await sendOpsAlert({
    subjectSuffix: p.subject_suffix,
    fields,
    dedupeKey,
    supabase,
  });

  return new Response(
    JSON.stringify({
      ok: true,
      sent: result.sent,
      skipped: result.skipped,
      reason: result.reason,
    }),
    {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    },
  );
});
