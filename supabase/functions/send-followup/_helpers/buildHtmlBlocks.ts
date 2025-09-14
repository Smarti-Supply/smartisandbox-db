import type { ordersPayload } from "../_helpers/types.ts";

/**
 * Constrói blocos HTML dinâmicos para substituição no template.
 * @param followupUrl - URL do botão de acesso
 * @param ordersPayload - Estrutura JSON dos pedidos e itens
 * @param userObservations - Texto livre de observações do cliente
 * @returns Objeto com blocos para renderização
 */

export function buildHtmlBlocks(
    followupUrl: string,
    ordersPayload?: ordersPayload[],
    userObservations?: string
  ): Record<string, string> {
    const blocks: Record<string, string> = {
      PedidosURL: followupUrl,
    };
  
    if (userObservations) {
      blocks.UserObservationsBlock = `
        <p><strong>Observações do cliente:</strong></p>
        <p>${userObservations}</p>
      `;
    }
  
    if (Array.isArray(ordersPayload)) {
      const listItems = ordersPayload.map(order => {
        const orderNumber = order.order_number;
        const items = Array.isArray(order.items) ? order.items.join(", ") : "";
        return `<li>Pedido ${orderNumber} — Itens: ${items}</li>`;
      }).join("");
  
      blocks.OrdersPayloadBlock = `
        <p><strong>Pedidos em destaque:</strong></p>
        <ul style="list-style-position: inside; padding: 0; text-align: center;">
          ${listItems}
        </ul>
      `;
    }
  
    return blocks;
  }
  