/**
 * check-confirmation-failures
 *
 * Detects orders imported without a confirmation letter (setting_id = 1)
 * and sends an OPS alert via sendOpsAlert / Resend.
 *
 * Called by pg_cron → private.fn_trigger_confirmation_letter_alert()
 * every 30 minutes (at :10 and :40 past every hour UTC).
 *
 * Dedup strategy (DB-backed, survives across invocations):
 *   Checks private.process_logs for an entry with
 *   process_name = 'conf_letter_alert' and the same dedupe_key
 *   in the last DEDUP_WINDOW_HOURS hours. If found, skips the alert.
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  sendOpsAlert,
  type OpsAlertFields,
} from "../_shared/sendOpsAlert.ts";

// ── Constants ──────────────────────────────────────────────────────────────

const SETTING_ID          = 1;
const MIN_AGE_MINUTES     = 30;   // orders must be at least this old
const MAX_AGE_HOURS       = 48;   // ignore orders older than this
const DEDUP_WINDOW_HOURS  = 2;    // suppress repeat alerts for the same set
const PROCESS_NAME        = "conf_letter_alert";

// ── Types ──────────────────────────────────────────────────────────────────

type DetectedFailure = {
  order_id:       number;
  order_number:   string;
  supplier_id:    number;
  supplier_name:  string;
  imported_at:    string;
  failure_reason: "exhausted_retries" | "never_queued";
};

// ── Handler ────────────────────────────────────────────────────────────────

Deno.serve(async (req: Request): Promise<Response> => {
  // ── Auth: validate internal edge token ──────────────────────────────────
  const edgeToken    = req.headers.get("edge-token") ?? "";
  const expectedToken = Deno.env.get("INTERNAL_EDGE_TOKEN") ?? "";

  if (!expectedToken || edgeToken !== expectedToken) {
    console.warn("check-confirmation-failures: unauthorized request.");
    return new Response("Unauthorized", { status: 401 });
  }

  // ── Supabase client (service-role) ──────────────────────────────────────
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!supabaseUrl || !serviceKey) {
    console.error("check-confirmation-failures: missing SUPABASE_URL or SERVICE_ROLE_KEY.");
    return new Response(
      JSON.stringify({ error: "missing_env" }),
      { status: 500 },
    );
  }

  const supabase = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false },
  });

  // ── Step 1: detect failures ─────────────────────────────────────────────
  const { data: failures, error: rpcError } = await supabase.rpc(
    "fn_detect_confirmation_letter_failures",
    {
      p_min_age_minutes: MIN_AGE_MINUTES,
      p_max_age_hours:   MAX_AGE_HOURS,
      p_setting_id:      SETTING_ID,
    },
  ) as { data: DetectedFailure[] | null; error: unknown };

  if (rpcError) {
    const msg = (rpcError as { message?: string }).message ?? String(rpcError);
    console.error("check-confirmation-failures: RPC error —", msg);
    return new Response(JSON.stringify({ error: msg }), { status: 500 });
  }

  if (!failures || failures.length === 0) {
    console.log("check-confirmation-failures: no failures detected.");
    return new Response(
      JSON.stringify({ checked: true, failures: 0 }),
      { status: 200 },
    );
  }

  console.log(`check-confirmation-failures: ${failures.length} failure(s) detected.`);

  // ── Step 2: build dedupe key ────────────────────────────────────────────
  const orderNumbers = failures
    .map((f) => f.order_number)
    .sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));

  // Stable key: first 150 chars of sorted order numbers joined by commas
  const dedupeKey = `conf_letter_fail:${orderNumbers.join(",")}`
    .substring(0, 200);

  // ── Step 3: DB-backed dedup (survives across edge function cold starts) ──
  const dedupCutoff = new Date(
    Date.now() - DEDUP_WINDOW_HOURS * 60 * 60 * 1000,
  ).toISOString();

  const { data: recentAlert } = await supabase
    .schema("private")
    .from("process_logs")
    .select("id, created_at")
    .eq("process_name", PROCESS_NAME)
    .eq("status", "success")
    .gte("created_at", dedupCutoff)
    .contains("metadata", { dedupe_key: dedupeKey })
    .limit(1)
    .maybeSingle();

  if (recentAlert) {
    console.log(
      `check-confirmation-failures: deduped — alert already sent at ${recentAlert.created_at}.`,
    );
    return new Response(
      JSON.stringify({ checked: true, failures: failures.length, deduped: true }),
      { status: 200 },
    );
  }

  // ── Step 4: classify failures ───────────────────────────────────────────
  const exhausted  = failures.filter((f) => f.failure_reason === "exhausted_retries");
  const neverQueued = failures.filter((f) => f.failure_reason === "never_queued");

  const errorSummary = [
    exhausted.length  > 0 ? `${exhausted.length} com tentativas esgotadas`  : null,
    neverQueued.length > 0 ? `${neverQueued.length} nunca enfileirados`       : null,
  ]
    .filter(Boolean)
    .join("; ");

  // Format context table: one line per failure (includes internal order_id for SQL reprocessing)
  const contextLines = failures.map((f) => {
    const when = new Date(f.imported_at).toLocaleString("pt-BR", {
      timeZone: "America/Sao_Paulo",
      dateStyle: "short",
      timeStyle: "short",
    });
    const reason =
      f.failure_reason === "exhausted_retries"
        ? "retries esgotados"
        : "nunca enfileirado";
    return (
      `  [id=${f.order_id}] PC ${f.order_number.padEnd(10)} | ` +
      `${f.supplier_name.substring(0, 35).padEnd(35)} | ` +
      `importado ${when} | ${reason}`
    );
  });

  // Collect internal order_ids for the reprocessing SQL snippet
  const orderIds = failures.map((f) => f.order_id);
  const orderIdsSnippet = `ARRAY[${orderIds.join(",")}]::BIGINT[]`;

  const fields: OpsAlertFields = {
    what: `${failures.length} pedido(s) importado(s) sem carta de confirmação enviada (setting_id=${SETTING_ID}).`,
    where: "check-confirmation-failures / fn_detect_confirmation_letter_failures",
    impact:
      `Fornecedores NÃO receberam a carta de confirmação de pedido. ` +
      `Risco de pedidos não atendidos sem ciência do fornecedor.`,
    error: errorSummary || "desconhecido",
    context:
      `Pedidos afetados (id interno | PC | Fornecedor | Importado | Motivo):\n` +
      contextLines.join("\n"),
    orderNumbers,
    whenIsoUtc: new Date().toISOString(),
    suggestion:
      `1. Verifique: SELECT * FROM private.followup_queue WHERE setting_id=${SETTING_ID} AND status='falha';\n` +
      `2. Reprocessar retries esgotados:\n` +
      `   UPDATE private.followup_queue SET status='pendente', tentativa=0, next_try_at=NOW()\n` +
      `   WHERE setting_id=${SETTING_ID} AND status='falha' AND order_ids && ${orderIdsSnippet};\n` +
      `3. Se nenhuma entrada na fila: verifique o cron 'execute-scheduled-followups' e rode\n` +
      `   SELECT * FROM private.fn_get_targets_item_status(${SETTING_ID});`,
  };

  // ── Step 5: send alert ──────────────────────────────────────────────────
  const alertResult = await sendOpsAlert({
    subjectSuffix: `Pedidos sem carta de confirmação — ${failures.length} pedido(s)`,
    fields,
    dedupeKey,
    supabase,
  });

  // ── Step 6: persist dedup entry so next invocation can skip ─────────────
  if (alertResult.sent) {
    const { error: logError } = await supabase
      .schema("private")
      .from("process_logs")
      .insert({
        process_name:  PROCESS_NAME,
        function_name: "check-confirmation-failures",
        step:          "alert_sent",
        status:        "success",
        message:       `Confirmation letter alert sent for ${failures.length} order(s): ${orderNumbers.join(", ")}`,
        user_id:       null,
        order_id:      null,
        metadata: {
          dedupe_key:    dedupeKey,
          order_numbers: orderNumbers,
          failures:      failures.length,
          exhausted:     exhausted.length,
          never_queued:  neverQueued.length,
        },
      });

    if (logError) {
      console.error("check-confirmation-failures: failed to write dedup log —", logError.message);
    }
  }

  return new Response(
    JSON.stringify({
      checked:  true,
      failures: failures.length,
      alert:    alertResult,
    }),
    { status: 200 },
  );
});
