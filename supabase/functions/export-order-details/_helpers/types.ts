export interface OrderDetailsPayload {
  export_id: string;
  id_pedido: number;
  order: Record<string, unknown>;
  order_items: Record<string, unknown>[];
  observations: Record<string, unknown>[];
  followup_tracking: Record<string, unknown>[];
  followup_logs: Record<string, unknown>[];
  order_item_invoices: Record<string, unknown>[];
  order_change_logs: Record<string, unknown>[];
  user_id: string;
  company_id: number;
  user_email: string;
}

export interface AWSResponse {
  success: boolean;
  message: string;
  export_id?: string;
}

export interface ExportResponse {
  success: boolean;
  message: string;
  export_id?: string;
  id_pedido?: number;
  order_items_count?: number;
  observations_count?: number;
  followup_tracking_count?: number;
  followup_logs_count?: number;
  order_item_invoices_count?: number;
}
