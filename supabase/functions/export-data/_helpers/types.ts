export interface ExportPayload {
  export_id: string;
  table_name: 'suppliers' | 'order_items';
  data: Record<string, unknown>[];
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
  table_name?: string;
  data_count?: number;
}
