const HTML_TEMPLATE = `<!DOCTYPE html>
<html lang="pt-BR">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>Exportação de dados</title>
  <style>
    body { font-family: 'Helvetica Neue', Arial, sans-serif; background-color: #DDE6ED; margin: 0; padding: 0; color: #464C53; line-height: 1.6; }
    @media (max-width: 480px) { h2 { font-size: 20px !important; } .alt-link { font-size: 12px !important; } }
  </style>
</head>
<body style="margin: 0; padding: 0; background-color: #DDE6ED;">
  <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" style="background-color: #DDE6ED;">
    <tr><td align="center">
      <table role="presentation" border="0" cellpadding="0" cellspacing="0" width="100%" style="max-width: 800px; background-color: #ffffff; margin: 0 auto; border-radius: 8px; overflow: hidden; box-shadow: 0 4px 10px rgba(0, 0, 0, 0.08);">
        <tr><td align="center" bgcolor="#27374D" style="padding: 20px;"><div style="font-size: 28px; font-weight: bold; color: #ffffff;">Smarti<span style="color: #E7295E;">Supply</span></div></td></tr>
        <tr><td align="center" style="padding: 30px 20px; font-family: Arial, sans-serif; color: #464C53;">
          <h2 style="font-size: 24px; margin-bottom: 16px; color: #27374D;">Relatório do Pedido</h2>
          <p style="margin: 0 0 20px;">Segue em anexo o relatório em PDF com o histórico completo do pedido.</p>
          <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="margin: 20px auto; background-color: #F3F6F9; border-radius: 6px; border: 1px solid #9DB2BF;">
            <tr><td style="padding: 20px; color: #464C53; font-family: Arial, sans-serif;">Relatório PDF em anexo</td></tr>
          </table>
        </td></tr>
        <tr><td align="center" bgcolor="#F7F9FA" style="padding: 20px; font-size: 13px; color: #526D82; border-top: 1px solid #9DB2BF;">
          <p style="margin: 0;">© 2025 SmartiSupply. Todos os direitos reservados.</p>
          <p style="margin: 0;"><a href="https://smartirpa.io/supply-chain/" style="color: #526D82; text-decoration: underline;">SmartiSupply</a></p>
          <p style="margin: 0;">Você está recebendo este email como fornecedor parceiro da nossa plataforma.</p>
        </td></tr>
      </table>
    </td></tr>
  </table>
</body>
</html>`;

function uint8ArrayToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary);
}

export async function sendEmail(
  userEmail: string,
  pdfBytes: Uint8Array,
  tableName: string,
  orderNumber: string | undefined
): Promise<void> {
  const apiKey = Deno.env.get("RESEND_API_KEY");
  if (!apiKey) {
    throw new Error(
      "RESEND_API_KEY não encontrada nas variáveis de ambiente da Edge Function"
    );
  }

  const timestamp = new Date()
    .toISOString()
    .replace(/[-:T]/g, "")
    .slice(0, 14);
  const pdfFilename = `${tableName}_relatorio_${timestamp}.pdf`;
  const pdfBase64 = uint8ArrayToBase64(pdfBytes);

  const subject = orderNumber
    ? `Smarti - Relatório do Pedido #${orderNumber}`
    : "Smarti - Relatório do Pedido";

  const body = {
    from: "SmartiSupply Followup <followup@smartisupply.com.br>",
    to: [userEmail],
    subject,
    html: HTML_TEMPLATE,
    attachments: [{ filename: pdfFilename, content: pdfBase64 }],
  };

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Resend API ${res.status}: ${text}`);
  }
}
