import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { collectOrderNumbersFromEntries } from "../../_shared/sendOpsAlert.ts";
import { generateLink } from "../_helpers/generateLink.ts";
import { processLogs } from "../_helpers/processLogs.ts";
import type { Entry } from "../_helpers/types.ts";

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY")!;

/** Usa o mesmo cliente Supabase da função (evita outro createClient só para logs). */
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
      // Falha de envio de e-mail: apenas logamos aqui.
      // O handler da Edge send-followup é o responsável
      // por notificar OPS em caso de falhas de envio.
      return;
    }
  
    console.log(`📨 Batch enviado com ${batch.length} e-mails`);
  
    // Registra um log por Entry. Falhas aqui NÃO disparam alerta OPS,
    // apenas são logadas em console, pois o envio ao fornecedor já ocorreu.
    const result = await processLogs(entries);
    if (result instanceof Error) {
      console.error("Erro ao registrar logs:", result.message || result);
      // Nenhum notify-ops aqui: problema é apenas de auditoria/followup_logs.
      const _orderNums = collectOrderNumbersFromEntries(entries);
      void _orderNums; // usado apenas para facilitar debugging local se necessário
    }
  }
  