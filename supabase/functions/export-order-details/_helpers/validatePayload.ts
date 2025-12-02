import { OrderDetailsPayload } from './types.ts';

export function validatePayload(payload: unknown): OrderDetailsPayload {
  // Verificar se payload é um objeto
  if (!payload || typeof payload !== 'object') {
    throw new Error('Payload deve ser um objeto');
  }

  const p = payload as Record<string, unknown>;

  // Validar campos obrigatórios
  if (!p.export_id || typeof p.export_id !== 'string') {
    throw new Error('export_id é obrigatório e deve ser uma string');
  }

  if (!p.id_pedido || typeof p.id_pedido !== 'number') {
    throw new Error('id_pedido é obrigatório e deve ser um número');
  }

  if (!p.order || typeof p.order !== 'object') {
    throw new Error('order é obrigatório e deve ser um objeto');
  }

  if (!Array.isArray(p.order_items)) {
    throw new Error('order_items é obrigatório e deve ser um array');
  }

  if (!Array.isArray(p.observations)) {
    throw new Error('observations é obrigatório e deve ser um array');
  }

  if (!Array.isArray(p.followup_tracking)) {
    throw new Error('followup_tracking é obrigatório e deve ser um array');
  }

  if (!Array.isArray(p.order_item_invoices)) {
    throw new Error('order_item_invoices é obrigatório e deve ser um array');
  }

  if (!p.user_id || typeof p.user_id !== 'string') {
    throw new Error('user_id é obrigatório e deve ser uma string');
  }

  if (!p.company_id || typeof p.company_id !== 'number') {
    throw new Error('company_id é obrigatório e deve ser um número');
  }

  if (!p.user_email || typeof p.user_email !== 'string') {
    throw new Error('user_email é obrigatório e deve ser uma string');
  }

  // Validar formato do email
  const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
  if (!emailRegex.test(p.user_email)) {
    throw new Error('user_email deve ter um formato válido');
  }

  return {
    export_id: p.export_id,
    id_pedido: p.id_pedido,
    order: p.order as Record<string, unknown>,
    order_items: p.order_items as Record<string, unknown>[],
    observations: p.observations as Record<string, unknown>[],
    followup_tracking: p.followup_tracking as Record<string, unknown>[],
    order_item_invoices: p.order_item_invoices as Record<string, unknown>[],
    user_id: p.user_id,
    company_id: p.company_id,
    user_email: p.user_email
  };
}

