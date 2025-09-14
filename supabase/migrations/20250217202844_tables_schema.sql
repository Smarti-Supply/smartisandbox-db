-- ╭────────────────────────────────────────────────────────────────────╮
-- ┃                            Tabelas                                 ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Criar esquema privado para tabelas de logs
CREATE TABLE private.process_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    process_name TEXT NOT NULL,       -- ex: 'supplier_import', 'order_import'
    function_name TEXT NOT NULL,      -- ex: 'po_import_edge', 'fn_insert_orders'
    step TEXT NOT NULL,               -- ex: 'download_file', 'insert_orders', 'trigger_update'
    status TEXT NOT NULL,             -- ex: 'success' | 'error' | 'info'
    message TEXT,                     -- texto livre com erro, descrição, etc
    user_id UUID NULL,                -- usuário relacionado ao processo
    metadata JSONB,                   -- opcional: dados adicionais úteis pro debug
    created_at TIMESTAMP DEFAULT now()
);

-- Criar tabela de super administradores
CREATE TABLE private.super_admins (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    email TEXT UNIQUE NOT NULL,
    phone TEXT,
    created_at TIMESTAMP DEFAULT now() NOT NULL
);

-- Criar tabela de planos para empresas
CREATE TABLE public.company_plans (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL, -- Nome do plano (Ex: "Básico", "Pro", "Enterprise")
    price NUMERIC(12,2) NOT NULL, -- Preço mensal do plano
    max_users INT NULL, -- Limite de usuários (NULL = Ilimitado)
    max_order_lines INT NULL, -- Linhas de pedido permitidas (NULL = Ilimitado)
    max_emails INT NULL, -- Limite de e-mails enviados (NULL = Ilimitado)
    is_active BOOLEAN NOT NULL DEFAULT TRUE, -- Se o plano pode ser contratado
    created_at TIMESTAMP DEFAULT now() NOT NULL
);

-- Índices
CREATE INDEX idx_plans_active ON public.company_plans(is_active);

-- Criar tabela de roles para clientes
CREATE TABLE public.user_roles (
    id SERIAL PRIMARY KEY,  -- ID autoincrementável
    name TEXT UNIQUE NOT NULL CHECK (name IN ('admin', 'comprador', 'fornecedor')), -- Nome da role
    description TEXT NOT NULL,  -- Descrição da role
    created_at TIMESTAMP DEFAULT now() NOT NULL
);

-- Criar tabela de cache de acesso de usuários
CREATE TABLE private.user_access_cache (
    user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    role_id INT NOT NULL,
    role_name TEXT NOT NULL CHECK (role_name IN ('admin', 'comprador', 'fornecedor')),
    company_id BIGINT,
    supplier_id BIGINT,
    is_active BOOLEAN NOT NULL DEFAULT true,
    last_synced_at timestamp DEFAULT now(),
    FOREIGN KEY (role_id) REFERENCES public.user_roles(id) ON DELETE RESTRICT
);

CREATE INDEX idx_company_id_filter ON private.user_access_cache (user_id, role_name, is_active, company_id);
CREATE INDEX idx_supplier_id_filter ON private.user_access_cache (user_id, role_name, is_active, supplier_id);
CREATE INDEX idx_role_id ON private.user_access_cache (user_id, role_name, is_active);


-- Criar tabela de status padrão para pedidos
CREATE TABLE public.default_order_status (
    id BIGSERIAL PRIMARY KEY,
    code TEXT NOT NULL UNIQUE,       -- Código interno e estável (ex: 'criado', 'cancelado')
    name TEXT NOT NULL,              -- Nome descritivo para exibição
    description TEXT,                -- Opcional: explicação sobre o uso do status
    position INT NOT NULL DEFAULT 1, -- Ordem lógica no fluxo
    is_final BOOLEAN NOT NULL DEFAULT FALSE, -- Indica se o status encerra o pedido
    created_at TIMESTAMP DEFAULT now() NOT NULL
);

-- Índices
CREATE INDEX idx_default_order_item_status_code ON public.default_order_status(code);
CREATE INDEX idx_default_order_item_status_position ON public.default_order_status(position);
CREATE INDEX idx_default_order_item_status_is_final ON public.default_order_status(is_final);

-- Criar tabela de empresas
CREATE TABLE public.companies (
    id BIGSERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    cnpj VARCHAR(20) NOT NULL UNIQUE,  -- CNPJ com chave única
    address_street TEXT,               -- Rua
    address_number TEXT,               -- Número
    address_neighborhood TEXT,         -- Bairro
    address_city TEXT,                 -- Cidade
    address_state VARCHAR(2),          -- Estado (sigla, ex: 'SP', 'RJ')
    address_zipcode VARCHAR(10),       -- CEP
    address_complement TEXT,           -- Complemento (opcional)
    plan_id INT NULL,                  -- Plano da empresa (NULL = sem plano atribuído)
    created_by UUID NOT NULL,          -- ID do usuário que criou a empresa
    created_at TIMESTAMP DEFAULT now() NOT NULL,
    FOREIGN KEY (plan_id) REFERENCES public.company_plans(id) ON DELETE RESTRICT
);

-- Índices
CREATE INDEX idx_companies_name ON public.companies(name);
CREATE INDEX idx_companies_cnpj ON public.companies(cnpj);
CREATE INDEX idx_companies_created_by ON public.companies(created_by);

-- Criar tabela de usuários clientes
CREATE TABLE public.company_users (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE, -- Relaciona com auth.users.id
    company_id BIGINT NULL, -- Permitir NULL para que o primeiro usuário possa criar a empresa
    name TEXT,       -- Nome do usuário
    email TEXT NOT NULL,  -- Email único
    phone TEXT NULL, -- Telefone opcional
    role_id INT NOT NULL, -- Somente roles pertinentes a clientes
    is_active BOOLEAN NOT NULL DEFAULT TRUE, -- Indica se o usuário pode acessar o sistema
    created_by UUID NULL, -- ID do usuário que criou esse usuário
    created_at TIMESTAMP DEFAULT now() NOT NULL,
    last_login TIMESTAMP NULL, -- Data do último login
    FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE SET NULL,
    FOREIGN KEY (role_id) REFERENCES public.user_roles(id) ON DELETE RESTRICT,
    FOREIGN KEY (created_by) REFERENCES public.company_users(id) ON DELETE SET NULL,
    UNIQUE (company_id, email)
);

-- Índices
CREATE INDEX idx_company_users_company ON public.company_users(company_id);
CREATE INDEX idx_company_users_email ON public.company_users(email);

-- Altera tabela public.companies para inserir a chave estrangeira para public.company_users
ALTER TABLE public.companies
    ADD CONSTRAINT companies_created_by_fkey
    FOREIGN KEY (created_by) REFERENCES public.company_users(id) ON DELETE RESTRICT;


-- Criar tabela de fornecedores
CREATE TABLE public.suppliers (
    id BIGSERIAL PRIMARY KEY,
    company_id BIGINT NOT NULL,                                    -- ID da empresa cliente
    external_id TEXT NOT NULL CHECK (trim(external_id) <> ''),  -- ID externo do fornecedor (opcional)
    name TEXT NOT NULL CHECK (trim(name) <> ''),                -- Razão social do fornecedor
    cnpj VARCHAR(14) NOT NULL CHECK (trim(cnpj) <> ''),         -- CNPJ único do fornecedor
    industry TEXT NULL,                                         -- Segmento de atuação
    products_services TEXT NULL,                                -- Produtos ou serviços oferecidos
    website TEXT NULL,                                          -- Site do fornecedor
    description TEXT NULL,                                      -- Descrição do fornecedor
    address_street TEXT,                                        -- Rua
    address_number TEXT,                                        -- Número
    address_neighborhood TEXT,                                  -- Bairro
    address_city TEXT,                                          -- Cidade
    address_state VARCHAR(2),                                   -- Estado (sigla, ex: 'SP', 'RJ')
    address_country TEXT,                                       -- País
    address_zipcode VARCHAR(8),                                 -- CEP
    address_complement TEXT,                                    -- Complemento (opcional)
    created_by UUID NULL,                                       -- ID do usuário cliente que criou o fornecedor
    created_at TIMESTAMP DEFAULT now() NOT NULL,
    FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE,
    FOREIGN KEY (created_by) REFERENCES public.company_users(id) ON DELETE SET NULL,
    UNIQUE (company_id, cnpj),
    UNIQUE (company_id, external_id)        
);

-- Índices
CREATE INDEX idx_suppliers_name ON public.suppliers(name);
CREATE UNIQUE INDEX idx_suppliers_company_cnpj ON public.suppliers(company_id, cnpj);
CREATE UNIQUE INDEX idx_suppliers_company_external_id ON public.suppliers(company_id, external_id);


-- Criar tabela de usuários fornecedores
CREATE TABLE public.supplier_contacts (
    id BIGSERIAL PRIMARY KEY,
    supplier_id BIGINT NOT NULL,                       -- FK para public.suppliers(id)
    name TEXT NOT NULL CHECK (trim(name) <> ''),    -- Nome do usuário
    email TEXT NOT NULL CHECK (trim(email) <> ''),  -- Email único e obrigatório
    phone TEXT NULL,                                -- Telefone opcional
    created_by UUID NULL,                           -- FK para auth.users(id) que criou esse usuário
    created_at TIMESTAMP DEFAULT now() NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,        -- Indica se o usuário pode receber emails
    FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON DELETE CASCADE,
    FOREIGN KEY (created_by) REFERENCES public.company_users(id) ON DELETE SET NULL,
    UNIQUE (supplier_id, email)
);

-- Índices opcionais para melhorar a performance
CREATE INDEX idx_supplier_contacts_supplier ON public.supplier_contacts(supplier_id);
CREATE INDEX idx_supplier_contacts_email ON public.supplier_contacts(email);


-- Criar tabela de usuários fornecedores (para o app do fornecedor)
CREATE TABLE public.supplier_users (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    supplier_contact_id BIGINT NOT NULL,
    role_id INT NOT NULL,
    last_login TIMESTAMP NULL,
    FOREIGN KEY (supplier_contact_id) REFERENCES public.supplier_contacts(id) ON DELETE CASCADE,
    FOREIGN KEY (role_id) REFERENCES public.user_roles(id) ON DELETE RESTRICT
);

CREATE INDEX idx_supplier_users_supplier_contact ON public.supplier_users(supplier_contact_id);


-- Criar tabela de status dos pedidos
CREATE TABLE public.order_item_status (
    id BIGSERIAL PRIMARY KEY,
    company_id BIGINT NOT NULL,
    name TEXT NOT NULL,
    color TEXT NOT NULL DEFAULT '#FFFFFF',              -- Cor padrão branca
    position INT NOT NULL DEFAULT 1,                    -- Ordem dos status no fluxo
    is_final BOOLEAN NOT NULL DEFAULT FALSE,            -- Indica se esse status é finalizador
    expose_to_supplier BOOLEAN NOT NULL DEFAULT FALSE,  -- Se o status é visível para fornecedores
    default_status_id BIGINT,                           -- Referência ao status global (atribui esse status global quando o status do item for...)    
    created_at TIMESTAMP DEFAULT now() NOT NULL,
    FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE,
    FOREIGN KEY (default_status_id) REFERENCES public.default_order_status(id) ON DELETE SET NULL,
    UNIQUE (company_id, name),
    UNIQUE (company_id, position)
);

-- Índice adicional para company_id (caso necessário para performance)
CREATE INDEX idx_order_item_status_company ON public.order_item_status(company_id);


-- Criar tabela de pedidos
CREATE TABLE public.orders (
    id BIGSERIAL PRIMARY KEY,
    company_id BIGINT NOT NULL,
    supplier_id BIGINT NOT NULL,
    order_number TEXT NOT NULL CHECK (trim(order_number) <> ''),
    order_description TEXT NULL,
    status_id INT NOT NULL DEFAULT 1,
    due_date DATE NULL,
    created_at TIMESTAMP DEFAULT now() NOT NULL,
    updated_at TIMESTAMP DEFAULT now() NOT NULL,
    FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE RESTRICT,
    FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON DELETE RESTRICT,
    FOREIGN KEY (status_id) REFERENCES public.default_order_status(id) ON DELETE RESTRICT,
    UNIQUE (company_id, order_number)
);

-- Índices
CREATE INDEX idx_orders_company ON public.orders(company_id);
CREATE INDEX idx_orders_supplier ON public.orders(supplier_id);
CREATE INDEX idx_orders_status ON public.orders(status_id);
CREATE INDEX idx_orders_order_number ON public.orders(order_number);
CREATE INDEX idx_orders_company_supplier ON public.orders(company_id, supplier_id);


-- Criar tabela para registrar alterações na tabela orders
CREATE TABLE public.order_logs (
    id BIGSERIAL PRIMARY KEY,
    order_id BIGINT NOT NULL,
    changed_by_client UUID NULL,
    changed_by_supplier BIGINT NULL,
    old_status_id INT NULL,
    new_status_id INT NOT NULL,
    old_due_date DATE NULL,
    new_due_date DATE NULL,
    old_supplier_id BIGINT NULL,
    new_supplier_id BIGINT NULL,
    old_order_number TEXT NULL,
    new_order_number TEXT NOT NULL,
    old_order_description TEXT,
    new_order_description TEXT,
    change_reason TEXT NULL,
    source TEXT CHECK (source IN ('client', 'supplier')) DEFAULT 'client',
    created_at TIMESTAMP DEFAULT now() NOT NULL,
    FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE,
    FOREIGN KEY (changed_by_client) REFERENCES public.company_users(id) ON DELETE SET NULL,
    FOREIGN KEY (changed_by_supplier) REFERENCES public.supplier_contacts(id) ON DELETE SET NULL
);

-- Índices
CREATE INDEX idx_order_logs_order ON public.order_logs(order_id);
CREATE INDEX idx_order_logs_changed_by_client ON public.order_logs(changed_by_client);
CREATE INDEX idx_order_logs_changed_by_supplier ON public.order_logs(changed_by_supplier);


-- Criar tabela de itens do pedido
CREATE TABLE public.order_items (
    id BIGSERIAL PRIMARY KEY,
    order_id BIGINT NOT NULL,
    item_number BIGINT NOT NULL,                                   -- Número sequencial do item
    product TEXT NOT NULL CHECK (trim(product) <> ''),          -- Código ou nome do produto
    product_description TEXT NULL,                              -- Descrição do produto
    quantity NUMERIC(12,2) NOT NULL CHECK (quantity > 0),       -- Quantidade mínima = 1
    unity_of_measure TEXT NULL,                                 -- Unidade de medida (ex: "kg", "un", "m")
    unit_price NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0),  -- Preço unitário mínimo = 0
    total_price NUMERIC(12,2) GENERATED ALWAYS AS (ROUND(quantity * unit_price, 2)) STORED,   -- Cálculo automático
    plant TEXT NULL,                                                                          -- Planta de origem do produto
    due_date DATE NOT NULL,                                                                   -- Data de entrega esperada
    current_delivery_date DATE NULL,                                                          -- Data de entrega atual, alterável
    deliver_time INT GENERATED ALWAYS AS (current_delivery_date - due_date) STORED,           -- Prazo de entrega calculado
    status_id INT NULL,                                                                       -- Status do item
    created_at TIMESTAMP DEFAULT now() NOT NULL,
    FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE,
    FOREIGN KEY (status_id) REFERENCES public.order_item_status(id) ON DELETE RESTRICT,
    UNIQUE (order_id, item_number)
);

-- Índices
CREATE INDEX idx_order_items_order ON public.order_items(order_id);
CREATE INDEX idx_order_items_status ON public.order_items(status_id);


-- Criar tabela de faturas de fornecedores
CREATE TABLE public.order_item_invoices (
    id BIGSERIAL PRIMARY KEY,
    order_item_id BIGINT NOT NULL,
    nfe_number TEXT NOT NULL,
    nfe_date DATE NOT NULL,
    quantity NUMERIC(12,2) NOT NULL CHECK (quantity > 0),              -- Quantidade faturada nesta nota
    invoiced_value NUMERIC(12,2) NOT NULL CHECK (invoiced_value >= 0), -- Valor total faturado nesta nota
    volumes TEXT NULL,                                                 -- Ex: "5 caixas", "2 pallets"
    created_at TIMESTAMP DEFAULT now() NOT NULL,
    created_by UUID NOT NULL,
    FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL,
    FOREIGN KEY (order_item_id) REFERENCES public.order_items(id) ON DELETE RESTRICT
);

-- Índices
CREATE INDEX idx_order_item_invoices_order_item_id ON public.order_item_invoices(order_item_id);
CREATE INDEX idx_order_item_invoices_nfe_number ON public.order_item_invoices(nfe_number);
CREATE INDEX idx_order_item_invoices_nfe_date ON public.order_item_invoices(nfe_date);


-- Criar tabela de notificações de pedidos
CREATE TABLE public.order_notifications (
    id BIGSERIAL PRIMARY KEY,
    order_id BIGINT NOT NULL,
    order_item_id BIGINT NULL,
    type TEXT NOT NULL CHECK (type IN ('order_status_change', 'delivery_date_change', 'item_status_change', 'item_invoiced', 'client_observation', 'client_status_change', 'client_item_change')),
    message TEXT NOT NULL,
    is_read BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT now() NOT NULL,
    read_by UUID NULL,
    FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE,
    FOREIGN KEY (order_item_id) REFERENCES public.order_items(id) ON DELETE SET NULL,
    FOREIGN KEY (read_by) REFERENCES auth.users(id) ON DELETE SET NULL
);

CREATE INDEX idx_order_notifications_order ON public.order_notifications(order_id);
CREATE INDEX idx_order_notifications_order_item ON public.order_notifications(order_item_id);

-- Criar tabela para registrar alterações nos itens do pedido
CREATE TABLE public.order_item_logs (
    id BIGSERIAL PRIMARY KEY,
    order_item_id BIGINT NOT NULL,
    changed_by_client UUID NULL,
    changed_by_supplier BIGINT NULL,
    old_item_number BIGINT,
    new_item_number BIGINT,
    old_product TEXT,
    new_product TEXT,
    old_product_description TEXT,
    new_product_description TEXT,
    old_quantity NUMERIC(12,2),
    new_quantity NUMERIC(12,2),
    old_unity_of_measure TEXT,
    new_unity_of_measure TEXT,
    old_unit_price NUMERIC(12,2),
    new_unit_price NUMERIC(12,2),
    old_total_price NUMERIC(12,2),
    new_total_price NUMERIC(12,2),
    old_plant TEXT,
    new_plant TEXT,
    old_due_date DATE,
    new_due_date DATE,
    old_current_delivery_date DATE,
    new_current_delivery_date DATE,
    old_delivery_time INT,
    new_delivery_time INT,
    old_volumes TEXT,
    new_volumes TEXT,
    old_nfe_number TEXT,
    new_nfe_number TEXT,
    old_nfe_date DATE,
    new_nfe_date DATE,
    old_status_id INT,
    new_status_id INT,
    old_observations TEXT,
    new_observations TEXT,
    source TEXT CHECK (source IN ('client', 'supplier')) DEFAULT 'client',
    created_at TIMESTAMP DEFAULT now() NOT NULL,
    FOREIGN KEY (order_item_id) REFERENCES public.order_items(id) ON DELETE CASCADE,
    FOREIGN KEY (changed_by_client) REFERENCES public.company_users(id) ON DELETE SET NULL,
    FOREIGN KEY (changed_by_supplier) REFERENCES public.supplier_contacts(id) ON DELETE SET NULL
);


-- Índices
CREATE INDEX idx_order_item_logs_item ON public.order_item_logs(order_item_id);
CREATE INDEX idx_order_item_logs_changed_by_client ON public.order_item_logs(changed_by_client);
CREATE INDEX idx_order_item_logs_changed_by_supplier ON public.order_item_logs(changed_by_supplier);


-- Criar tabela de configurações de follow-up
CREATE TABLE public.followup_settings (
    id BIGSERIAL PRIMARY KEY,
    company_id BIGINT NOT NULL,
    rule_name TEXT NOT NULL,
    last_sent_at TIMESTAMP NULL, --Armazena a última vez em que essa regra foi usada para envio de e-mails (qualquer fornecedor/pedido).


    -- Gatilho da notificação (se aplicável)
    trigger_scope TEXT NOT NULL CHECK (
        trigger_scope IN (
            'default_order_status',
            'order_due_date',
            'item_status',
            'item_due_date',
            'item_delivery_date',
            'manual_user_trigger',
            'manual_user_order_cancel'
        )
    ),
    trigger_reference_id BIGINT NULL, -- id referente ao gatilho (ex: id do status padrão, id do pedido, etc.)

    -- Delay ou intervalo entre envios
    send_days_interval INT NULL,
    repeat_interval_days INT NULL,
    max_followups INT NULL,

    -- Configurações de notificação
    email_template TEXT NULL,
    notification_type TEXT CHECK (notification_type = 'email') NOT NULL DEFAULT 'email',
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    is_system_config BOOLEAN NOT NULL DEFAULT FALSE,

    created_at TIMESTAMP DEFAULT now() NOT NULL,
    FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE
);

-- Índices
CREATE INDEX idx_followup_settings_company ON public.followup_settings(company_id);

-- Criar tabela de regras de follow-up por fornecedor
CREATE TABLE public.followup_suppliers (
    id BIGSERIAL PRIMARY KEY,
    followup_setting_id BIGINT NOT NULL,
    supplier_id BIGINT NOT NULL,
    created_at TIMESTAMP DEFAULT now() NOT NULL,
    FOREIGN KEY (followup_setting_id) REFERENCES public.followup_settings(id) ON DELETE CASCADE,
    FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON DELETE CASCADE,
    UNIQUE (followup_setting_id, supplier_id)
);

-- Índices
CREATE INDEX idx_followup_suppliers_followup_setting ON public.followup_suppliers(followup_setting_id);
CREATE INDEX idx_followup_suppliers_supplier ON public.followup_suppliers(supplier_id);

-- Criar tabela de logs de follow-up
CREATE TABLE public.followup_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id BIGINT NOT NULL,
    supplier_id BIGINT NOT NULL,
    supplier_contacts TEXT[] NULL,              -- Contatos do fornecedor (opcional)
    orders_payload JSONB NULL,                  -- Novo campo JSON com estrutura de pedidos + itens
    sent_at TIMESTAMP DEFAULT now() NOT NULL,   -- Data de envio do follow-up
    sent_by UUID NULL,                          -- ID do usuário que enviou o follow-up
    user_observations TEXT NULL,                -- Observações do cliente
    supplier_observations TEXT NULL,            -- Observações do fornecedor
    setting_id BIGINT NULL,                     -- ID da regra que originou o follow-up
    status TEXT CHECK (status IN ('enviado', 'respondido', 'falha')) NOT NULL DEFAULT 'enviado', -- Status do follow-up
    notification_type TEXT CHECK (notification_type = 'email') NOT NULL DEFAULT 'email', -- Apenas email é permitido
    created_at TIMESTAMP DEFAULT now() NOT NULL,
    FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE,
    FOREIGN KEY (sent_by) REFERENCES public.company_users(id) ON DELETE SET NULL,
    FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON DELETE SET NULL,
    FOREIGN KEY (setting_id) REFERENCES public.followup_settings(id) ON DELETE SET NULL
);

-- Índices
CREATE INDEX idx_followup_logs_supplier_id ON public.followup_logs(supplier_id);
CREATE INDEX idx_followup_logs_company_id ON public.followup_logs(company_id);
CREATE INDEX idx_followup_logs_status ON public.followup_logs(status);
CREATE INDEX idx_followup_logs_setting_id ON public.followup_logs(setting_id);
CREATE INDEX idx_followup_logs_orders_payload_gin ON public.followup_logs USING GIN (orders_payload);
CREATE INDEX idx_followup_logs_orders_payload_path ON public.followup_logs USING GIN (orders_payload jsonb_path_ops);


-- Criar tabela de faturas de clientes
CREATE TABLE public.company_invoices (
    id BIGSERIAL PRIMARY KEY,
    company_id BIGINT NOT NULL,                        -- Empresa que pagou a fatura
    plan_id INT NOT NULL,                           -- Plano referente ao pagamento
    amount NUMERIC(12,2) NOT NULL,                  -- Valor cobrado
    status TEXT CHECK (status IN ('pendente', 'pago', 'cancelado')) NOT NULL DEFAULT 'pendente',
    due_date DATE NOT NULL,                         -- Data de vencimento da fatura
    paid_at TIMESTAMP NULL,                         -- Data do pagamento (se foi pago)
    created_at TIMESTAMP DEFAULT now() NOT NULL,
    FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE SET NULL,
    FOREIGN KEY (plan_id) REFERENCES public.company_plans(id) ON DELETE SET NULL
);

-- Criar índices para melhorar performance nas buscas
CREATE INDEX idx_invoices_company ON public.company_invoices(company_id);
CREATE INDEX idx_invoices_status ON public.company_invoices(status);
CREATE INDEX idx_invoices_plan_id ON public.company_invoices(plan_id);


CREATE TABLE public.import_field_mappings (
    id BIGSERIAL PRIMARY KEY,
    company_id BIGINT NOT NULL,
    type TEXT NOT NULL CHECK (TYPE IN ('orders', 'suppliers', 'migo_miro')),
    field_mapping JSONB NULL,
    default_field_mapping JSONB NOT NULL,
    created_at TIMESTAMP DEFAULT now(),
    updated_at TIMESTAMP DEFAULT now(),
    FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE
);

CREATE INDEX idx_imports_company_id ON public.import_field_mappings (company_id);

-- Criar tabela para armazenar observações a nivel de pedidos e itens
CREATE TABLE public.order_and_item_observations (
    id BIGSERIAL PRIMARY KEY,
    order_id BIGINT NOT NULL,
    order_item_id BIGINT NULL,
    user_observations TEXT NULL,
    supplier_observations TEXT NULL,
    current_delivery_date DATE NULL,
    created_at TIMESTAMP DEFAULT now(),
    created_by UUID NOT NULL,
    FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE,
    FOREIGN KEY (order_item_id) REFERENCES public.order_items(id) ON DELETE SET NULL,
    FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL
);

CREATE INDEX idx_order_and_item_observations_order_id ON public.order_and_item_observations(order_id);
CREATE INDEX idx_order_and_item_observations_order_item_id ON public.order_and_item_observations(order_item_id);
CREATE INDEX idx_order_and_item_observations_created_at ON public.order_and_item_observations(created_at);
CREATE INDEX idx_order_and_item_observations_created_by ON public.order_and_item_observations(created_by);

-- Criar tabela da fila com controles avançados
CREATE TABLE private.followup_queue (
    id BIGSERIAL PRIMARY KEY,
    setting_id BIGINT NOT NULL,
    supplier_id BIGINT NOT NULL,
    company_id BIGINT NOT NULL,
    order_ids BIGINT[] NULL,
    status TEXT CHECK (status IN ('pendente', 'enviando', 'sucesso', 'falha', 'cancelado')) NOT NULL DEFAULT 'pendente',
    tentativa INT NOT NULL DEFAULT 0,
    max_tentativas INT NOT NULL DEFAULT 3,
    last_try_at TIMESTAMP NULL,
    next_try_at TIMESTAMP NULL,
    error_message TEXT NULL,
    created_at TIMESTAMP DEFAULT now() NOT NULL,
    updated_at TIMESTAMP DEFAULT now() NOT NULL,
    FOREIGN KEY (setting_id) REFERENCES public.followup_settings(id) ON DELETE CASCADE,
    FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON DELETE CASCADE,
    FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE
);

CREATE INDEX idx_followup_queue_processing ON private.followup_queue(status, next_try_at) 
WHERE status IN ('pendente', 'falha');
CREATE INDEX idx_followup_queue_company ON private.followup_queue(company_id, status);
CREATE INDEX idx_followup_queue_setting ON private.followup_queue(setting_id, status);


-- Criar tabela para rastrear follow-ups por item (max_followups POR ITEM)
CREATE TABLE private.followup_item_tracking (
    id BIGSERIAL PRIMARY KEY,
    order_id BIGINT NOT NULL,
    order_item_id BIGINT NOT NULL,
    setting_id BIGINT NOT NULL,
    supplier_id BIGINT NOT NULL,
    company_id BIGINT NOT NULL,
    followup_count INT NOT NULL DEFAULT 0,
    last_followup_at TIMESTAMP NULL,
    created_at TIMESTAMP DEFAULT now() NOT NULL,
    updated_at TIMESTAMP DEFAULT now() NOT NULL,
    FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE,
    FOREIGN KEY (order_item_id) REFERENCES public.order_items(id) ON DELETE CASCADE,
    FOREIGN KEY (setting_id) REFERENCES public.followup_settings(id) ON DELETE CASCADE,
    FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON DELETE CASCADE,
    FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE,
    UNIQUE(order_item_id, setting_id)
);

CREATE INDEX idx_followup_item_tracking_item_setting ON private.followup_item_tracking(order_item_id, setting_id);
CREATE INDEX idx_followup_item_tracking_company ON private.followup_item_tracking(company_id);
CREATE INDEX idx_followup_item_tracking_order ON private.followup_item_tracking(order_id);
CREATE INDEX idx_followup_item_tracking_order_setting ON private.followup_item_tracking(order_id, setting_id);