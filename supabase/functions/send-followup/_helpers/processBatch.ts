import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  collectOrderNumbersFromEntries,
  sendOpsAlert,
} from "../../_shared/sendOpsAlert.ts";
import { generateLink } from "../_helpers/generateLink.ts";
import { processLogs } from "../_helpers/processLogs.ts";
import type { Entry } from "../_helpers/types.ts";

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY")!;

/** Usa o mesmo cliente Supabase da função (evita outro createClient só para alertas/logs). */
export async function processBatch(
  entries: Entry[],
  supabase: SupabaseClient,
) {
    const batch: Array<{
      from: string;
      to: string[];
      subject: string;
      html: string;
    }> = [];
  
    for (const entry of entries) {
      for (const email of entry.supplier_contacts) {
        const item = await generateLink(entry, email);
        if (item) batch.push(item);
      }
    }
  
    if (batch.length === 0) {
      console.warn("Nenhum e-mail válido para envio no batch.");
      return;
    }

    console.log("📦 Batch pronto para envio:", JSON.stringify(batch, null, 2));
  
    // Delay de 1.2 segundos antes de chamar Resend API para evitar erro 429
    await new Promise(resolve => setTimeout(resolve, 1200));
  
    // Envia via Resend
    const batchRes = await fetch("https://api.resend.com/emails/batch", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${RESEND_API_KEY}`,
      },
      body: JSON.stringify(batch),
    });
  
    if (!batchRes.ok) {
      const msg = await batchRes.text();
      console.error("Erro ao enviar batch:", msg);
      return;
    }
  
    console.log(`📨 Batch enviado com ${batch.length} e-mails`);
  
    // Registra um log por Entry
    const result = await processLogs(entries);
    if (result instanceof Error) {
      console.error("Erro ao registrar logs:", result.message || result);
      const orderNums = collectOrderNumbersFromEntries(entries);
      const errMsg = result.message || String(result);
      const whenIsoUtc = new Date().toISOString();
      const settingIds = [
        ...new Set(
          entries.map((e) => e.setting_id).filter((id): id is number => id != null),
        ),
      ].join(", ");
      await sendOpsAlert({
        subjectSuffix: "followup_logs insert",
        dedupeKey: `followup_logs|${errMsg.slice(0, 120)}|${orderNums.join(",")}`,
        supabase,
        fields: {
          what:
            "O envio ao fornecedor pode ter ocorrido, mas o registro em followup_logs falhou.",
          where: "send-followup / processLogs (Supabase insert em followup_logs).",
          impact:
            "Auditoria e visão no app podem estar inconsistentes com o que foi enviado.",
          error: errMsg,
          context:
            `company_ids=${entries.map((e) => e.company_id).join(",")}; setting_id(s)=${settingIds || "—"}; entries=${entries.length}`,
          orderNumbers: orderNums,
          whenIsoUtc,
          suggestion:
            "Validar RLS, constraints, dados referenciados e migrations pendentes em followup_logs.",
        },
      });
    }
  }
  