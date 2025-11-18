import { createClient } from "supabase";
import type { Entry } from "../_helpers/types.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

export async function processLogs(entries: Entry[]): Promise<true | Error> {
  try {
    // As observações agora são inseridas pela função SQL fn_send_payload_followup
    // antes do envio do email, então não precisamos mais inserir aqui

    const logs = entries.map((e) => ({
      company_id: e.company_id,
      supplier_id: e.supplier_id,
      supplier_contacts: e.supplier_contacts,
      orders_payload: e.orders_payload,
      sent_by: e.user_id,
      user_observations: e.user_observations,
      setting_id: e.setting_id ?? null,
      status: "enviado" as const,
      notification_type: "email" as const,
    }));

    console.log("📝 Logs a serem inseridos:", JSON.stringify(logs, null, 2));

    const { error: logError } = await supabase
      .schema("public")
      .from("followup_logs")
      .insert(logs);

    if (logError) {
      console.error("❌ Erro Supabase ao inserir logs:", {
        code: logError.code,
        message: logError.message,
        details: logError.details,
        hint: logError.hint,
      });

      return new Error(logError.message || JSON.stringify(logError));
    }

    return true;
  } catch (err: unknown) {
    console.error("🔥 Exceção ao processar dados no Supabase:", err);
    return err instanceof Error ? err : new Error("Erro desconhecido");
  }
}