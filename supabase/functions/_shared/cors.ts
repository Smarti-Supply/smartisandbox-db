const allowedOrigins = [
  "https://editor.weweb.io",
  "https://transpetro.smartisupply.com.br"
];

export function getCorsHeaders(origin: string | null): Record<string, string> {
  const isAllowed = origin && allowedOrigins.includes(origin);

  const headers: Record<string, string> = {
    "Vary": "Origin",
    "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
    "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, edge-token, content-type"
  };

  // 👉 Se a origem for conhecida, adiciona o CORS dinâmico
  if (isAllowed) {
    headers["Access-Control-Allow-Origin"] = origin;
    headers["Access-Control-Allow-Credentials"] = "true";
  }

  return headers;
}