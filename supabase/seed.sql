-- Inserir as roles padrões
INSERT INTO public.user_roles (id, name, description) VALUES
    (1, 'admin', 'Usuário com permissões administrativas sobre a empresa'),
    (2, 'comprador', 'Usuário com permissões limitadas para gerenciar pedidos e fornecedores'),
    (3, 'fornecedor', 'Usuário com permissões limitadas para gerenciar pedidos e fornecedores');

-- Tabela public.user_plans
INSERT INTO public.company_plans (
    id, name, price, max_users, max_order_lines, max_emails, is_active, created_at
) VALUES 
    (1, 'Free', 0.00, 1, 10, 50, TRUE, now()),
    (2, 'Standard', 5000.00, 10, 1000, 5000, TRUE, now());

-- Tabela public.default_order_status (Criando status padrão para pedidos)
INSERT INTO public.default_order_status (id, code, name, description, position, is_final)
VALUES 
  (1, 'criado', 'Aguardando confirmação', 'Pedido registrado no sistema - Aguardando confirmação fornecedor', 1, FALSE),
  (2, 'confirmado', 'Confirmado - Aguardando Entrega', 'Pedido confirmado pelo fornecedor', 2, FALSE),
  (3, 'recusado', 'Recusado', 'Pedido recusado pelo fornecedor', 2, FALSE),
  (4, 'parcial', 'Entregas Parciais', 'Pedido com entregas parciais', 3, FALSE),
  (5, 'concluido', 'Concluído', 'Pedido concluído', 4, FALSE), --Logica para Transpetro
  (6, 'cancelado', 'Cancelado', 'Pedido cancelado', 5, TRUE);

INSERT INTO auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, last_sign_in_at, raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous) 
VALUES 
('0874b943-2dc1-4751-a848-d92f07d3a8ab', 'authenticated', 'authenticated', 'admin@admin.com', '$2a$10$OJ8pbFtgItqnHDgJlPGTUut7C79HFnoo3bN0HxqvJ/Oi/YAGKKo2K', now(), now(), '{"provider": "email", "providers": ["email"]}', '{"sub": "0874b943-2dc1-4751-a848-d92f07d3a8ab", "email": "admin@admin.com", "is_active": true, "role_name": "admin", "user_name": "AdminUser", "user_email": "admin@admin.com", "email_verified": true, "phone_verified": false}', now(), now(), false, false);

-- Tabela public.companies (Criando 3 empresas diferentes)
INSERT INTO public.companies (
    id, name, cnpj, address_street, address_number, address_neighborhood, address_city, address_state, address_zipcode, address_complement, plan_id, created_by, created_at
) VALUES 
    (1, 'Petrobras Transporte S.A', '02.709.449/0001-59', 'Avenida Presidente Vargas', '328', 'Centro', 'Rio de Janeiro', 'RJ', '20091-060', NULL, 2,'0874b943-2dc1-4751-a848-d92f07d3a8ab', now());


-- Tabela public.order_status (Criando status para cada empresa)
INSERT INTO public.order_item_status (
    id, company_id, name, color, position, is_final, expose_to_supplier, default_status_id, created_at
)
VALUES
    (1, 1, 'Aguardando confirmação do pedido', '#FFEB3B', 1, false, true, 1, now()),
    (2, 1, 'Aguardando entrega', '#FFC107', 2, false, true, 2, now()),
    (3, 1, 'Entrega informada', '#4CAF50', 3, false, true, NULL, now()),
    (4, 1, 'Aguardando MIGO', '#03A9F4', 4, false, true, NULL, now()),
    (5, 1, 'Aguardando MIRO', '#00BCD4', 5, false, true, NULL, now()),
    (6, 1, 'Aguardando pagamento', '#2196F3', 6, false, true, NULL, now()),
    (7, 1, 'Pagamento realizado', '#4CAF50', 7, true, true, NULL, now()),
    (8, 1, 'Declinio', '#F44336', 8, false, true, 3, now()),
    (9, 1, 'Em revisão', '#9C27B0', 9, false, true, NULL, now()),
    (10, 1, 'Esclarecimento técnico', '#3F51B5', 10, false, true, NULL, now()),
    (11, 1, 'Devolução/ Troca', '#795548', 11, false, true, NULL, now()),
    (12, 1, 'Pedido cancelado motivado pelo fornecedor', '#E91E63', 12, true, true, NULL, now()),
    (13, 1, 'Pedido cancelado motivado pela Transpetro', '#607D8B', 13, true, true, 6, now());


-- Seed de configurações de follow-up para a Empresa 1 (com IDs explícitos)
INSERT INTO public.followup_settings (
    id, company_id, rule_name, trigger_scope, trigger_reference_id, send_days_interval,
    repeat_interval_days, max_followups, cooldown_per_order, email_template, notification_type, is_active, created_at, is_system_config
)
VALUES
    (1, 1, 'Pedido aguardando confirmação', 'item_status', 1, 0, 2, 3, TRUE, 'template_aguardando_confirmacao', 'email', TRUE, now(), FALSE),
    (2, 1, 'Item aguardando entrega', 'item_status', 2, 3, 3, 2, FALSE, 'template_aguardando_entrega', 'email', TRUE, now(), FALSE),
    (3, 1, 'Entrega em atraso', 'item_delivery_date', NULL, 0, 2, 5, FALSE, 'template_entrega_atrasada', 'email', TRUE, now(), FALSE),
    (4, 1, 'Aguardando MIGO', 'item_status', 4, 1, 2, 2, FALSE, 'template_migo_pendente', 'email', TRUE, now(), FALSE),
    (5, 1, 'Pedido com vencimento próximo', 'order_due_date', NULL, -3, NULL, 1, FALSE, 'template_vencimento_proximo', 'email', TRUE, now(), FALSE),
    (6, 1, 'Manual Followup', 'manual_user_trigger', null, null, null, null, FALSE, null, 'email', TRUE, now(), TRUE),
    (7, 1, 'Manual Cancelamento de Pedido', 'manual_user_order_cancel', null, null, null, null, FALSE, null, 'email', TRUE, now(), TRUE);


-- Tabela public.import_field_mappings (Criando mapeamentos de campos para importação de pedidos)
UPDATE public.import_field_mappings
SET
  field_mapping = '{
    "po_header_mapping": [
        { "db_field": "public.orders.order_number", "required": true, "field_label": "Número do pedido", "file_column_name": "numero_do_pedido", "original_column_name": "Número do pedido" },
        { "db_field": "public.suppliers.external_id", "required": true, "field_label": "ID do fornecedor", "file_column_name": "id_do_fornecedor", "original_column_name": "ID do fornecedor" },    
        { "db_field": "public.orders.order_description", "required": false, "field_label": "Descrição do pedido", "file_column_name": "descricao_do_pedido", "original_column_name": "Descrição do pedido" }, 
        { "db_field": "public.order_items.item_number", "required": true, "field_label": "Item do pedido", "file_column_name": "item_do_pedido", "original_column_name": "Item do pedido" },    
        { "db_field": "public.order_items.product", "required": true, "field_label": "Material", "file_column_name": "material", "original_column_name": "Material" },    
        { "db_field": "public.order_items.product_description", "required": false, "field_label": "Descrição do Material", "file_column_name": "descricao_do_material", "original_column_name": "Descrição do Material" },    
        { "db_field": "public.order_items.quantity", "required": true, "field_label": "Quantidade solicitada", "file_column_name": "quantidade_solicitada", "original_column_name": "Quantidade solicitada" },    
        { "db_field": "public.order_items.unity_of_measure", "required": false, "field_label": "Unidade de medida", "file_column_name": "unidade_de_medida", "original_column_name": "Unidade de medida" },    
        { "db_field": "public.order_items.unit_price", "required": true, "field_label": "Preço unitário do produto", "file_column_name": "preco_unitario_do_produto", "original_column_name": "Preço unitário do produto" },    
        { "db_field": "public.order_items.plant", "required": false, "field_label": "Centro", "file_column_name": "centro", "original_column_name": "Centro" },    
        { "db_field": "public.order_items.due_date", "required": true, "field_label": "Data da Remessa - Item", "file_column_name": "data_da_remessa__item", "original_column_name": "Data da Remessa - Item" },
        { "db_field": "public.order_items.bidding_description", "required": false, "field_label": "Descrição da licitação", "file_column_name": "descricao_da_licitacao", "original_column_name": "Descrição da licitação" },
        { "db_field": "public.order_items.custom_deliver_time", "required": false, "field_label": "Prazo de fornecimento", "file_column_name": "prazo_de_fornecimento", "original_column_name": "Prazo de fornecimento" },
        { "db_field": "public.order_items.purchase_req", "required": false, "field_label": "Número da requisição", "file_column_name": "numero_da_requisicao", "original_column_name": "Número da requisição" },
        { "db_field": "public.order_items.purchase_req_item", "required": false, "field_label": "Item da requisição", "file_column_name": "item_da_requisicao", "original_column_name": "Item da requisição" }    
    ]
  }'::jsonb,
  default_field_mapping = '{
    "po_header_mapping": [
        { "db_field": "public.orders.order_number", "required": true, "field_label": "Número do pedido", "file_column_name": "numero_do_pedido", "original_column_name": "Número do pedido" },
        { "db_field": "public.suppliers.external_id", "required": true, "field_label": "ID do fornecedor", "file_column_name": "id_do_fornecedor", "original_column_name": "ID do fornecedor" },    
        { "db_field": "public.orders.order_description", "required": false, "field_label": "Descrição do pedido", "file_column_name": "descricao_do_pedido", "original_column_name": "Descrição do pedido" }, 
        { "db_field": "public.order_items.item_number", "required": true, "field_label": "Item do pedido", "file_column_name": "item_do_pedido", "original_column_name": "Item do pedido" },    
        { "db_field": "public.order_items.product", "required": true, "field_label": "Material", "file_column_name": "material", "original_column_name": "Material" },    
        { "db_field": "public.order_items.product_description", "required": false, "field_label": "Descrição do Material", "file_column_name": "descricao_do_material", "original_column_name": "Descrição do Material" },    
        { "db_field": "public.order_items.quantity", "required": true, "field_label": "Quantidade solicitada", "file_column_name": "quantidade_solicitada", "original_column_name": "Quantidade solicitada" },    
        { "db_field": "public.order_items.unity_of_measure", "required": false, "field_label": "Unidade de medida", "file_column_name": "unidade_de_medida", "original_column_name": "Unidade de medida" },    
        { "db_field": "public.order_items.unit_price", "required": true, "field_label": "Preço unitário do produto", "file_column_name": "preco_unitario_do_produto", "original_column_name": "Preço unitário do produto" },    
        { "db_field": "public.order_items.plant", "required": false, "field_label": "Centro", "file_column_name": "centro", "original_column_name": "Centro" },    
        { "db_field": "public.order_items.due_date", "required": true, "field_label": "Data da Remessa - Item", "file_column_name": "data_da_remessa__item", "original_column_name": "Data da Remessa - Item" },
        { "db_field": "public.order_items.bidding_description", "required": false, "field_label": "Descrição da licitação", "file_column_name": "descricao_da_licitacao", "original_column_name": "Descrição da licitação" },
        { "db_field": "public.order_items.custom_deliver_time", "required": false, "field_label": "Prazo de fornecimento", "file_column_name": "prazo_de_fornecimento", "original_column_name": "Prazo de fornecimento" },
        { "db_field": "public.order_items.purchase_req", "required": false, "field_label": "Número da requisição", "file_column_name": "numero_da_requisicao", "original_column_name": "Número da requisição" },
        { "db_field": "public.order_items.purchase_req_item", "required": false, "field_label": "Item da requisição", "file_column_name": "item_da_requisicao", "original_column_name": "Item da requisição" }   
    ]
  }'::jsonb,
  updated_at = now()
WHERE company_id = 1 AND type = 'orders';

-- Tabela public.import_field_mappings (Criando mapeamentos de campos para importação de fornecedores)
UPDATE public.import_field_mappings
SET
  field_mapping = '{
    "supplier_header_mapping": [
      { "db_field": "public.suppliers.external_id", "required": true, "field_label": "ID do Fornecedor", "file_column_name": "id_do_fornecedor", "original_column_name": "ID do Fornecedor" },
      { "db_field": "public.suppliers.name", "required": true, "field_label": "Razão Social", "file_column_name": "razao_social", "original_column_name": "Razão Social" },
      { "db_field": "public.suppliers.cnpj", "required": true, "field_label": "CNPJ", "file_column_name": "cnpj", "original_column_name": "CNPJ" },
      { "db_field": "public.suppliers.industry", "required": false, "field_label": "Segmento", "file_column_name": "segmento", "original_column_name": "Segmento" },
      { "db_field": "public.suppliers.products_services", "required": false, "field_label": "Produtos/Serviços", "file_column_name": "produtosservicos", "original_column_name": "Produtos/Serviços" },
      { "db_field": "public.suppliers.website", "required": false, "field_label": "Site", "file_column_name": "site", "original_column_name": "Site" },
      { "db_field": "public.suppliers.description", "required": false, "field_label": "Descrição", "file_column_name": "descricao", "original_column_name": "Descrição" },
      { "db_field": "public.suppliers.address_street", "required": false, "field_label": "Rua", "file_column_name": "rua", "original_column_name": "Rua" },
      { "db_field": "public.suppliers.address_number", "required": false, "field_label": "Número", "file_column_name": "numero", "original_column_name": "Número" },
      { "db_field": "public.suppliers.address_neighborhood", "required": false, "field_label": "Bairro", "file_column_name": "bairro", "original_column_name": "Bairro" },
      { "db_field": "public.suppliers.address_city", "required": false, "field_label": "Cidade", "file_column_name": "cidade", "original_column_name": "Cidade" },
      { "db_field": "public.suppliers.address_state", "required": false, "field_label": "Estado", "file_column_name": "estado", "original_column_name": "Estado" },
      { "db_field": "public.suppliers.address_country", "required": false, "field_label": "País", "file_column_name": "pais", "original_column_name": "País" },
      { "db_field": "public.suppliers.address_zipcode", "required": false, "field_label": "CEP", "file_column_name": "cep", "original_column_name": "CEP" },
      { "db_field": "public.suppliers.address_complement", "required": false, "field_label": "Complemento", "file_column_name": "complemento", "original_column_name": "Complemento" },
      { "db_field": "public.supplier_contacts.name", "required": true, "field_label": "Nome do Contato", "file_column_name": "nome_do_contato", "original_column_name": "Nome do Contato" },
      { "db_field": "public.supplier_contacts.email", "required": true, "field_label": "Email do Contato", "file_column_name": "email_do_contato", "original_column_name": "Email do Contato" },
      { "db_field": "public.supplier_contacts.phone", "required": false, "field_label": "Telefone do Contato", "file_column_name": "telefone_do_contato", "original_column_name": "Telefone do Contato" }
    ]
  }'::jsonb,
  default_field_mapping = '{
    "supplier_header_mapping": [
      { "db_field": "public.suppliers.external_id", "required": true, "field_label": "ID do Fornecedor", "file_column_name": "id_do_fornecedor", "original_column_name": "ID do Fornecedor" },
      { "db_field": "public.suppliers.name", "required": true, "field_label": "Razão Social", "file_column_name": "razao_social", "original_column_name": "Razão Social" },
      { "db_field": "public.suppliers.cnpj", "required": true, "field_label": "CNPJ", "file_column_name": "cnpj", "original_column_name": "CNPJ" },
      { "db_field": "public.suppliers.industry", "required": false, "field_label": "Segmento", "file_column_name": "segmento", "original_column_name": "Segmento" },
      { "db_field": "public.suppliers.products_services", "required": false, "field_label": "Produtos/Serviços", "file_column_name": "produtosservicos", "original_column_name": "Produtos/Serviços" },
      { "db_field": "public.suppliers.website", "required": false, "field_label": "Site", "file_column_name": "site", "original_column_name": "Site" },
      { "db_field": "public.suppliers.description", "required": false, "field_label": "Descrição", "file_column_name": "descricao", "original_column_name": "Descrição" },
      { "db_field": "public.suppliers.address_street", "required": false, "field_label": "Rua", "file_column_name": "rua", "original_column_name": "Rua" },
      { "db_field": "public.suppliers.address_number", "required": false, "field_label": "Número", "file_column_name": "numero", "original_column_name": "Número" },
      { "db_field": "public.suppliers.address_neighborhood", "required": false, "field_label": "Bairro", "file_column_name": "bairro", "original_column_name": "Bairro" },
      { "db_field": "public.suppliers.address_city", "required": false, "field_label": "Cidade", "file_column_name": "cidade", "original_column_name": "Cidade" },
      { "db_field": "public.suppliers.address_state", "required": false, "field_label": "Estado", "file_column_name": "estado", "original_column_name": "Estado" },
      { "db_field": "public.suppliers.address_country", "required": false, "field_label": "País", "file_column_name": "pais", "original_column_name": "País" },
      { "db_field": "public.suppliers.address_zipcode", "required": false, "field_label": "CEP", "file_column_name": "cep", "original_column_name": "CEP" },
      { "db_field": "public.suppliers.address_complement", "required": false, "field_label": "Complemento", "file_column_name": "complemento", "original_column_name": "Complemento" },
      { "db_field": "public.supplier_contacts.name", "required": true, "field_label": "Nome do Contato", "file_column_name": "nome_do_contato", "original_column_name": "Nome do Contato" },
      { "db_field": "public.supplier_contacts.email", "required": true, "field_label": "Email do Contato", "file_column_name": "email_do_contato", "original_column_name": "Email do Contato" },
      { "db_field": "public.supplier_contacts.phone", "required": false, "field_label": "Telefone do Contato", "file_column_name": "telefone_do_contato", "original_column_name": "Telefone do Contato" }
    ]
  }'::jsonb,
  updated_at = now()
WHERE company_id = 1 AND type = 'suppliers';
