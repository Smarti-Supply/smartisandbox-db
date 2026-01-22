import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import type { CancelEntry } from "../_helpers/types.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

export async function processLogs(entries: CancelEntry[]): Promise<true | Error> {
  let hasObservationInsertError = false;
  let observationInsertError: Error | null = null;

  try {
    for (const entry of entries) {
      if (entry.user_observations) {
        const observation = {
          order_id: entry.order_info.order_id,
          user_observations: entry.user_observations,
          created_by: entry.user_id,
        };

        const { error: insertError } = await supabase
          .schema("public")
          .from("order_and_item_observations")
          .insert([observation]);

        if (insertError) {
          hasObservationInsertError = true;
          observationInsertError = new Error(
            insertError.message || JSON.stringify(insertError)
          );

          console.error("⚠️ Erro ao inserir observação:", {
            order_id: entry.order_info.order_id,
            message: insertError.message,
          });
        }
      }
    }

    const logs = entries.map((e) => ({
      company_id: e.company_id,
      supplier_id: e.supplier_id,
      supplier_contacts: e.supplier_contacts,
      orders_payload: [
        {
          order_id: e.order_info.order_id,
          order_number: e.order_info.order_number,
        },
      ],
      sent_by: e.user_id,
      user_observations: e.user_observations,
      status: "enviado" as const,
      notification_type: "email" as const,
    }));

    console.log("📝 Logs de cancelamento a serem inseridos:", JSON.stringify(logs, null, 2));

    const { error: logError } = await supabase
      .schema("public")
      .from("followup_logs")
      .insert(logs);

    if (logError) {
      console.error("❌ Erro Supabase ao inserir logs de cancelamento:", {
        code: logError.code,
        message: logError.message,
        details: logError.details,
        hint: logError.hint,
      });

      if (hasObservationInsertError) {
        return new Error(
          `Erro ao registrar observações e logs:\n${observationInsertError?.message}\n${logError.message}`
        );
      }

      return new Error(logError.message || JSON.stringify(logError));
    }

    // Retorna o erro da observação, se logs foram salvos com sucesso
    if (hasObservationInsertError) {
      return observationInsertError!;
    }

    return true;
  } catch (err: unknown) {
    console.error("🔥 Exceção ao processar dados de cancelamento no Supabase:", err);
    return err instanceof Error ? err : new Error("Erro desconhecido");
  }
}
