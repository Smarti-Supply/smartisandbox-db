import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { buildHtmlBlocks } from "../_helpers/buildHtmlBlocks.ts";
import { renderHtml } from "../_helpers/renderHtml.ts";
import type { Entry } from "../_helpers/types.ts";
import { renderPlainText } from "../_helpers/renderPlainText.ts";


const FOLLOWUP_URL = Deno.env.get("FOLLOWUP_URL")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

export async function generateLink(entry: Entry, contact: string) {
  // Extrair nome e email do formato "NAME <email>"
  const match = contact.match(/^(.+)\s<(.+)>$/);
  if (!match) {
    console.error("Formato de contato inválido:", contact);
    return null;
  }
  const name = match[1].trim();
  const email = match[2].trim();

  const { data, error } = await supabase.auth.admin.generateLink({
    type: "magiclink",
    email: email,
    options: {
      redirectTo: FOLLOWUP_URL,
      data: {
        company_id: entry.company_id,
        supplier_id: entry.supplier_id,
        supplier_email: email,
        supplier_name: name,
        role_name: "fornecedor",
        created_by: entry.user_id,
        is_active: true,
      },
    },
  });

  if (error || !data?.properties?.action_link) {
    console.error("Erro ao gerar link para", email, error);
    return null;
  }

  const magicLink = data.properties.action_link;
  const blocks = buildHtmlBlocks(magicLink, entry.orders_payload, entry.user_observations);
  const htmlContent = renderHtml(entry.template_html, blocks);
  const plainText = renderPlainText(entry.template_html, blocks);

  return {
    from: "SmartiSupply Followup <followup@smartisupply.com.br>",
    to: [email],
    subject: entry.company_name
      ? `${entry.company_name} - Follow-up de pedidos`
      : "Follow-up de pedidos",
    html: htmlContent,
    text: plainText,
  };
}
  