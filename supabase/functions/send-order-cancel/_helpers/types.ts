export type OrderInfo = {
  order_id: number;
  order_number: string;
  order_description?: string;
  due_date?: string;
  status_name: string;
};

export type CancelEntry = {
  user_id: string;
  supplier_id: number;
  supplier_name: string;
  supplier_contacts: string[];
  order_info: OrderInfo;
  company_id: number;
  company_name: string;
  user_observations: string;
  template_html: string;
};