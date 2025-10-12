import { ExportPayload } from './types.ts';

export function validatePayload(payload: unknown): ExportPayload {
  // Verificar se payload é um objeto
  if (!payload || typeof payload !== 'object') {
    throw new Error('Payload deve ser um objeto');
  }

  const p = payload as Record<string, unknown>;

  // Validar campos obrigatórios
  if (!p.export_id || typeof p.export_id !== 'string') {
    throw new Error('export_id é obrigatório e deve ser uma string');
  }

  if (!p.table_name || typeof p.table_name !== 'string') {
    throw new Error('table_name é obrigatório e deve ser uma string');
  }

  if (!['suppliers', 'order_items'].includes(p.table_name)) {
    throw new Error('table_name deve ser suppliers ou order_items');
  }

  if (!Array.isArray(p.data)) {
    throw new Error('data é obrigatório e deve ser um array');
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
    table_name: p.table_name as 'suppliers' | 'order_items',
    data: p.data as Record<string, unknown>[],
    user_id: p.user_id,
    company_id: p.company_id,
    user_email: p.user_email
  };
}
