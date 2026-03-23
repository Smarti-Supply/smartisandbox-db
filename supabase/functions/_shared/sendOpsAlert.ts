/**
 * Alertas operacionais do pipeline de follow-up via Resend.
 * Destinatários: OPS_ALERT_FROM (lista separada por vírgula).
 * Remetente: igual ao dos e-mails de follow-up (RESEND_FOLLOWUP_FROM), salvo override OPS_ALERT_MAIL_FROM.
 */
import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { RESEND_FOLLOWUP_FROM } from "./resendFollowupFrom.ts";

const SUBJECT_PREFIX = "[SMARTI.IO Error Followup] - ";

export type OpsAlertFields = {
  what: string;
  where: string;
  impact: string;
  error: string;
  context: string;
  orderNumbers: string[];
  whenIsoUtc: string;
  suggestion: string;
};

const rateLimitBucket = new Map<string, number>();
const RATE_LIMIT_MS = 5 * 60 * 1000;

function pruneRateLimit(now: number) {
  for (const [k, t] of rateLimitBucket) {
    if (now - t > RATE_LIMIT_MS) rateLimitBucket.delete(k);
  }
}

/** Retorna false se um alerta equivalente foi enviado há pouco (dedup). */
export function shouldSendOpsAlert(dedupeKey: string): boolean {
  const now = Date.now();
  pruneRateLimit(now);
  const last = rateLimitBucket.get(dedupeKey);
  if (last !== undefined && now - last < RATE_LIMIT_MS) {
    return false;
  }
  rateLimitBucket.set(dedupeKey, now);
  return true;
}

export function parseOpsAlertRecipients(): string[] {
  const raw = Deno.env.get("OPS_ALERT_FROM")?.trim() ?? "";
  if (!raw) return [];
  return raw
    .split(/[,;]/)
    .map((s) => s.trim())
    .filter(Boolean);
}

function formatOrderLine(orderNumbers: string[]): string {
  if (orderNumbers.length === 0) {
    return "Pedidos afetados: — (não aplicável ou não disponível neste erro)";
  }
  const max = 50;
  const shown = orderNumbers.slice(0, max);
  const extra = orderNumbers.length > max
    ? ` (+${orderNumbers.length - max} outros)`
    : "";
  return `Pedidos afetados: ${shown.join(", ")}${extra}`;
}

export function buildOpsAlertPlainBody(f: OpsAlertFields): string {
  return [
    `O que: ${f.what}`,
    `Onde: ${f.where}`,
    `Impacto: ${f.impact}`,
    `Erro: ${f.error}`,
    `Contexto: ${f.context}`,
    formatOrderLine(f.orderNumbers),
    `Quando: ${f.whenIsoUtc}`,
    `Sugestão: ${f.suggestion}`,
  ].join("\n");
}

export type SendOpsAlertOptions = {
  subjectSuffix: string;
  fields: OpsAlertFields;
  /** Chave para dedup (ex.: hash de subject+error). */
  dedupeKey: string;
  supabase: SupabaseClient;
};

export async function sendOpsAlert(
  opts: SendOpsAlertOptions,
): Promise<{ sent: boolean; skipped: boolean; reason?: string }> {
  const recipients = parseOpsAlertRecipients();
  if (recipients.length === 0) {
    console.warn(
      "sendOpsAlert: OPS_ALERT_FROM vazio — alerta não enviado.",
    );
    await insertProcessLog(opts.supabase, opts.fields, opts.subjectSuffix, false);
    return { sent: false, skipped: true, reason: "no_recipients" };
  }

  const from =
    Deno.env.get("OPS_ALERT_MAIL_FROM")?.trim() || RESEND_FOLLOWUP_FROM;

  const resendKey = Deno.env.get("RESEND_API_KEY")?.trim();
  if (!resendKey) {
    console.warn("sendOpsAlert: RESEND_API_KEY ausente.");
    await insertProcessLog(opts.supabase, opts.fields, opts.subjectSuffix, false);
    return { sent: false, skipped: true, reason: "no_resend_key" };
  }

  if (!shouldSendOpsAlert(opts.dedupeKey)) {
    console.warn("sendOpsAlert: dedupe — mesmo alerta nos últimos 5 min.");
    await insertProcessLogDeduped(opts.supabase, opts.fields, opts.subjectSuffix);
    return { sent: false, skipped: true, reason: "deduped" };
  }

  const subject = `${SUBJECT_PREFIX}${opts.subjectSuffix}`;
  const text = buildOpsAlertPlainBody(opts.fields);

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${resendKey}`,
    },
    body: JSON.stringify({
      from,
      to: recipients,
      subject,
      text,
    }),
  });

  const ok = res.ok;
  if (!ok) {
    const errText = await res.text();
    console.error("sendOpsAlert: Resend falhou:", res.status, errText);
  }

  await insertProcessLog(
    opts.supabase,
    opts.fields,
    opts.subjectSuffix,
    ok,
    ok ? undefined : await res.text(),
  );

  return { sent: ok, skipped: false };
}

async function insertProcessLog(
  supabase: SupabaseClient,
  f: OpsAlertFields,
  subjectSuffix: string,
  emailSent: boolean,
  resendError?: string,
) {
  const metadata = {
    subject_suffix: subjectSuffix,
    order_numbers: f.orderNumbers,
    email_sent: emailSent,
    resend_error: resendError ?? null,
  };
  const { error } = await supabase.schema("private").from("process_logs").insert({
    process_name: "followup_ops_alert",
    function_name: "sendOpsAlert",
    step: "notify",
    status: emailSent ? "success" : "error",
    message: `${SUBJECT_PREFIX}${subjectSuffix}\n${buildOpsAlertPlainBody(f)}`,
    user_id: null,
    order_id: null,
    metadata,
  });
  if (error) {
    console.error("sendOpsAlert: falha ao gravar process_logs:", error);
  }
}

async function insertProcessLogDeduped(
  supabase: SupabaseClient,
  f: OpsAlertFields,
  subjectSuffix: string,
) {
  const metadata = {
    subject_suffix: subjectSuffix,
    order_numbers: f.orderNumbers,
    deduped: true,
  };
  const { error } = await supabase.schema("private").from("process_logs").insert({
    process_name: "followup_ops_alert",
    function_name: "sendOpsAlert",
    step: "notify_deduped",
    status: "info",
    message: `${SUBJECT_PREFIX}${subjectSuffix} (dedup 5min)\n${buildOpsAlertPlainBody(f)}`,
    user_id: null,
    order_id: null,
    metadata,
  });
  if (error) {
    console.error("sendOpsAlert: falha ao gravar process_logs (dedup):", error);
  }
}

/** Extrai order_number distintos dos entries do send-followup. */
export function collectOrderNumbersFromEntries(
  entries: { orders_payload?: { order_number?: number | string }[] }[],
): string[] {
  const set = new Set<string>();
  for (const e of entries) {
    for (const o of e.orders_payload ?? []) {
      if (o?.order_number != null) set.add(String(o.order_number));
    }
  }
  return [...set].sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
}
