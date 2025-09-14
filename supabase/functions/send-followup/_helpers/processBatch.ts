import { generateLink } from "../_helpers/generateLink.ts";
import { processLogs } from "../_helpers/processLogs.ts";
import type { Entry } from "../_helpers/types.ts";

const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY")!;

export async function processBatch(entries: Entry[]) {
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
    }
  }
  