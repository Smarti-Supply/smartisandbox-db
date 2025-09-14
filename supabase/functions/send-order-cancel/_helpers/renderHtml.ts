 /**
 * Substitui variáveis no formato {{ .Variavel }} dentro de um template HTML.
 * @param template - HTML com placeholders no formato {{ .Nome }}
 * @param variables - Objeto com as chaves correspondentes às variáveis
 * @returns HTML com as variáveis substituídas
 */
 export function renderHtml(template: string, variables: Record<string, string>): string {
  // Substitui os que existem
  let html = Object.entries(variables).reduce((acc, [key, value]) => {
    const pattern = new RegExp(`{{\\s*\\.${key}\\s*}}`, 'g');
    return acc.replace(pattern, value);
  }, template);

  // Remove os que não foram substituídos (vazios)
  html = html.replace(/{{\s*\.\w+\s*}}/g, "");

  return html;
}