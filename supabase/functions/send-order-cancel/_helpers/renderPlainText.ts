export function renderPlainText(
    templateHtml: string,
    blocks: Record<string, string>
  ): string {
    let text = templateHtml;
  
    // Substitui os blocos pelos valores convertidos para texto plano
    for (const [key, value] of Object.entries(blocks)) {
      const placeholder = `{{ .${key} }}`;
      const plainValue = stripHtml(value);
      text = text.replace(new RegExp(placeholder, "g"), plainValue);
    }
  
    // Remove qualquer tag HTML restante (bem simples)
    text = text.replace(/<\/?[^>]+(>|$)/g, "");
  
    // Normaliza espaços e quebras de linha
    return text
      .replace(/\s+\n/g, "\n")        // remove espaços antes de quebras de linha
      .replace(/\n{3,}/g, "\n\n")     // evita mais de 2 quebras seguidas
      .trim();
  }
  
  function stripHtml(html: string): string {
    return html
      .replace(/<\/?[^>]+(>|$)/g, "") // remove tags
      .replace(/&nbsp;/g, " ")        // trata espaços não separáveis
      .replace(/&amp;/g, "&")         // trata &
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .trim();
  }
  