import type { OrderInfo } from "../_helpers/types.ts";


export function buildHtmlBlocks(
 followupUrl: string,
 orderInfo: OrderInfo,
 userObservations?: string
): Record<string, string> {
 const blocks: Record<string, string> = {
   PedidosURL: followupUrl,
   OrderNumber: orderInfo.order_number,
   OrderDescription: orderInfo.order_description || '',
   DueDate: orderInfo.due_date || '',
   SupplierName: 'Prezado fornecedor', // Será substituído no template
 };


 if (userObservations) {
   blocks.UserObservationsBlock = `
     <p><strong>Observações do cliente:</strong></p>
     <p>${userObservations}</p>
   `;
 }


 // Bloco com informações do pedido
 blocks.OrderInfoBlock = `
   <p><strong>Pedido cancelado:</strong> ${orderInfo.order_number}</p>
   ${orderInfo.order_description ? `<p><strong>Descrição:</strong> ${orderInfo.order_description}</p>` : ''}
   ${orderInfo.due_date ? `<p><strong>Data prevista:</strong> ${orderInfo.due_date}</p>` : ''}
 `;


 return blocks;
}
