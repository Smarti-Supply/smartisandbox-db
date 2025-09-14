export type ordersPayload = {
  order_id:     number;
  order_number: number;
  items:        number[];
};

export type Entry = {
user_id:           string;
supplier_id:       number;
supplier_contacts: string[];
orders_payload:    ordersPayload[];
company_id:        number;
company_name:      string;
user_observations: string;
template_html:     string;
setting_id:        number | null;
};