-- ╭────────────────────────────────────────────────────────────────────╮
-- ┃                            Views                                   ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Criar view para listar os dados de uso dos planos
CREATE OR REPLACE VIEW public.view_client_usage
WITH (security_invoker = true)
AS
SELECT
    u.company_id,
    c.plan_id,
    DATE_TRUNC('month', NOW())::DATE AS period_start,
    (DATE_TRUNC('month', NOW()) + INTERVAL '1 month' - INTERVAL '1 day')::DATE AS period_end,
    COUNT(DISTINCT oi.id) AS total_order_lines,
    COALESCE(SUM(
    CASE 
        WHEN fl.supplier_contacts IS NOT NULL 
        THEN cardinality(fl.supplier_contacts)
        ELSE 0
    END
    ), 0) AS total_emails_sent
FROM public.company_users u
JOIN public.companies c ON c.id = u.company_id
LEFT JOIN public.orders o 
ON o.company_id = u.company_id
AND o.created_at >= DATE_TRUNC('month', NOW())
AND o.created_at < (DATE_TRUNC('month', NOW()) + INTERVAL '1 month')
LEFT JOIN public.order_items oi 
ON oi.order_id = o.id
AND oi.created_at >= DATE_TRUNC('month', NOW())
AND oi.created_at < (DATE_TRUNC('month', NOW()) + INTERVAL '1 month')
LEFT JOIN public.followup_logs fl 
ON fl.company_id = u.company_id
AND fl.sent_at >= DATE_TRUNC('month', NOW())
AND fl.sent_at < (DATE_TRUNC('month', NOW()) + INTERVAL '1 month')
WHERE EXISTS (
SELECT 1
FROM private.user_access_cache uac
WHERE uac.user_id = (select auth.uid())
    AND uac.role_name = 'admin'
    AND uac.is_active = true
    AND uac.company_id = u.company_id
)
GROUP BY u.company_id, c.plan_id;


-- Criar view para listar os pedidos dos clientes
CREATE OR REPLACE VIEW public.view_orders
WITH (security_invoker = true)
AS
SELECT
o.id,
o.order_number,
o.order_description,
s.external_id,
s.name AS supplier_name,
o.due_date,
dos.id AS status_id,
dos.name AS status_name,
o.created_at,
o.updated_at,
CASE
  WHEN dos.is_final = TRUE AND dos.code != 'concluido' THEN false
  WHEN NOT EXISTS (
    SELECT 1 FROM public.order_items oi
    JOIN public.order_item_status ois ON oi.status_id = ois.id
    WHERE oi.order_id = o.id AND ois.is_final = FALSE
  ) THEN false  -- Se todos os itens são finais, nunca é atrasado
  WHEN EXISTS (
    SELECT 1 FROM public.order_items oi
    JOIN public.order_item_status ois ON oi.status_id = ois.id
    WHERE oi.order_id = o.id AND ois.is_final = FALSE
  ) AND dos.code = 'concluido' THEN true  -- Concluído com itens não finais é atrasado
  ELSE CURRENT_DATE > o.due_date
END AS overdue_order,
-- Notificações do fornecedor (para compradores verem)
EXISTS (
    SELECT 1
    FROM public.order_notifications orn
    WHERE orn.order_id = o.id
      AND orn.is_read = false
      AND orn.type IN ('order_status_change', 'delivery_date_change', 'item_status_change', 'item_invoiced')
) AS has_notifications_from_supplier,

-- Notificações do comprador (para fornecedores verem)
EXISTS (
    SELECT 1
    FROM public.order_notifications orn
    WHERE orn.order_id = o.id
      AND orn.is_read = false
      AND orn.type IN ('client_observation', 'client_status_change', 'client_item_change')
) AS has_notifications_from_client,

-- Flag: existe pelo menos uma notificação não lida? (compatibilidade)
EXISTS (
    SELECT 1
    FROM public.order_notifications orn
    WHERE orn.order_id = o.id
    AND orn.is_read = false
) AS has_notifications,
-- Adiciona o status_id com menor position dos order_items
COALESCE(min_status.status_id, NULL) AS order_items_min_status_id,
COALESCE(min_status.status_name, NULL) AS order_items_min_status_name
FROM public.orders o
JOIN public.suppliers s ON s.id = o.supplier_id
JOIN public.default_order_status dos ON dos.id = o.status_id
LEFT JOIN LATERAL (
  SELECT 
    oi.status_id,
    ois.name AS status_name
  FROM public.order_items oi
  LEFT JOIN public.order_item_status ois ON oi.status_id = ois.id
  WHERE oi.order_id = o.id
    AND oi.status_id IS NOT NULL
  ORDER BY COALESCE(ois.position, 999999) ASC
  LIMIT 1
) min_status ON true
LIMIT 1000;

/* 
- Esta view foi customizada para a Transpetro e por conter campos que estão na migration customizada, este bloco será comentado para não gerar erros ao rodar a migration.
- Para quaisquer outros clientes, favor remover este comentário e ajustar a view conforme necessário.

-- Criar view para listar os itens dos pedidos dos clientes
CREATE OR REPLACE VIEW public.view_order_items 
WITH (security_invoker = true) AS 
SELECT
    oi.id,
    oi.order_id,
    oi.item_number,
    oi.product,
    oi.product_description,
    oi.quantity,
    oi.unity_of_measure,
    oi.unit_price,
    oi.total_price,
    oi.plant,
    oi.due_date,
    oi.current_delivery_date,
    oi.deliver_time,
    ois.id AS status_id,
    ois.name AS status_name,
    -- Soma das quantidades faturadas para este item
    COALESCE(
        (SELECT SUM(oii.quantity) 
        FROM public.order_item_invoices oii 
        WHERE oii.order_item_id = oi.id),
        0
    ) AS invoiced_quantity,

    -- Notificação mais recente não lida (se houver)
    n.type AS notification_type,
    n.message AS notification_message,

    -- Flag: existe pelo menos uma notificação não lida?
    EXISTS (
    SELECT 1
    FROM public.order_notifications
    WHERE order_item_id = oi.id
        AND is_read = false
    ) AS has_unread_notification

FROM public.order_items oi
LEFT JOIN public.order_item_status ois ON oi.status_id = ois.id
LEFT JOIN LATERAL (
    SELECT type, message, is_read
    FROM public.order_notifications
    WHERE order_item_id = oi.id
    AND is_read = false
    ORDER BY created_at DESC
    LIMIT 1
) n ON true;
*/

-- View de notificações dos pedidos (inline: permite predicate pushdown e índices;
-- evita set-returning function que materializava toda a tabela por chamada).
-- RLS: joins em company_users / supplier_users / supplier_contacts respeitam o invoker.
CREATE OR REPLACE VIEW public.view_order_notifications
WITH (security_invoker = true) AS
SELECT
    onf.id,
    onf.order_id,
    onf.order_item_id,
    onf.type,
    onf.message,
    onf.is_read,
    onf.created_at,
    onf.read_by,
    COALESCE(cu.name, sc.name) AS read_by_name,
    COALESCE(cu.email, sc.email) AS read_by_email,
    CASE
        WHEN cu.id IS NOT NULL THEN 'client'::TEXT
        WHEN su.id IS NOT NULL THEN 'supplier'::TEXT
        ELSE NULL::TEXT
    END AS read_by_user_type,
    CASE
        WHEN onf.type IN (
            'client_observation',
            'client_status_change',
            'client_item_change'
        ) THEN true
        ELSE false
    END AS is_from_client,
    o.supplier_id
FROM public.order_notifications onf
LEFT JOIN public.orders o ON o.id = onf.order_id
LEFT JOIN public.company_users cu ON cu.id = onf.read_by
LEFT JOIN public.supplier_users su ON su.id = onf.read_by
LEFT JOIN public.supplier_contacts sc ON sc.id = su.supplier_contact_id;


-- Criar view para listar os registros de processo realizados por usuários
CREATE OR REPLACE VIEW public.view_user_process_logs
WITH (security_invoker = true) AS
SELECT
pl.id,
pl.process_name,
pl.function_name,
pl.step,
pl.status,
pl.message,
pl.user_id,
pl.order_id,
pl.metadata,
pl.created_at,
CASE pl.process_name
    WHEN 'orders_upload'              THEN 'Importação de Pedidos'
    WHEN 'suppliers_upload'           THEN 'Importação de Fornecedores'
    WHEN 'send_followup_emails'       THEN 'Envio de Follow-ups'
    WHEN 'send_followup_emails_cron'  THEN 'Envio de Follow-ups Automatizado'
    WHEN 'send_order_cancel_emails'   THEN 'Envio de Cancelamento de Pedidos'
    WHEN 'create_new_user'            THEN 'Criação de Novo Usuário'
    WHEN 'delete_inactive_auth_users' THEN 'Limpeza de Usuários Inativos'
    ELSE pl.process_name
END AS process_label,
CASE pl.status
    WHEN 'success' THEN 'Sucesso'
    WHEN 'error'   THEN 'Erro'
    WHEN 'warning' THEN 'Alerta'
    WHEN 'info'    THEN 'Informação'
    WHEN 'skip'    THEN 'Ignorado'
    ELSE pl.status
END AS status_label,
cu.name  AS user_name,
cu.email AS user_email,
o.order_number,
o.order_description
FROM private.process_logs pl
LEFT JOIN public.company_users cu ON cu.id = pl.user_id
LEFT JOIN public.orders o ON o.id = pl.order_id;


-- Criar view para listar os fornecedores
CREATE VIEW public.view_suppliers
WITH (security_invoker = true)
AS
SELECT
    s.id,
    s.company_id,
    s.external_id,
    s.name,
    s.cnpj,
    s.industry,
    s.products_services,
    s.website,
    s.description,
    s.address_street,
    s.address_number,
    s.address_neighborhood,
    s.address_city,
    s.address_state,
    s.address_country,
    s.address_zipcode,
    s.address_complement,
    cu.name AS creator_name,
    s.created_at
FROM public.suppliers s
LEFT JOIN public.company_users cu ON s.created_by = cu.id
LIMIT 1000;


-- Criar view para listar os usuários dos fornecedores
CREATE OR REPLACE VIEW public.view_supplier_contacts
WITH (security_invoker = true)
AS
SELECT
    sc.id AS supplier_contact_id,
    sc.supplier_id,
    sc.name,
    sc.email,
    sc.phone,
    cu.name AS creator_name,
    sc.created_at,
    sc.is_active,
    -- Dados do usuário (se existir)
    su.id AS auth_user_id,
    su.role_id,
    su.last_login
FROM public.supplier_contacts sc
LEFT JOIN public.company_users cu ON sc.created_by = cu.id
LEFT JOIN public.supplier_users su ON su.supplier_contact_id = sc.id;


-- Criar view para exibir as empresas do cliente
CREATE OR REPLACE VIEW public.view_companies
WITH (security_invoker = true)
AS
SELECT
    c.id,
    c.name,
    c.cnpj,
    c.address_street,
    c.address_number,
    c.address_neighborhood,
    c.address_city,
    c.address_state,
    c.address_zipcode,
    c.address_complement,
    c.plan_id,
    cu.name AS created_by,
    c.created_at
FROM public.companies c
LEFT JOIN public.company_users cu ON c.created_by = cu.id;


-- Criar view para listar os usuários do sistema
CREATE OR REPLACE VIEW public.view_company_users
WITH (security_invoker = true)
AS
SELECT
    cu.id,
    cu.company_id,
    cu.name,
    cu.email,
    cu.phone,
    cu.role_id,
    ur.name AS role_name,
    cu.is_active,
    cu.created_at,
    cu.last_login,
    cu.created_by,
    creator.name AS creator_name  -- Substitui o UUID por nome
FROM public.company_users cu
LEFT JOIN public.company_users creator ON creator.id = cu.created_by
LEFT JOIN public.user_roles ur ON ur.id = cu.role_id;


-- Criar view para utilizar como tabela de roles para o weweb
CREATE OR REPLACE VIEW public.view_user_access_cache
WITH (security_invoker = true)
AS
SELECT
user_id AS id,
role_id,
role_name,
company_id,
supplier_id,
is_active,
last_synced_at
FROM private.user_access_cache;


-- Criar view para Acompanhar performance e identificar problemas: Status geral da fila
CREATE OR REPLACE VIEW public.view_followup_queue_status
WITH (security_invoker = true)
AS
SELECT 
    status,
    COUNT(*) as total,
    MIN(created_at) as oldest,
    MAX(created_at) as newest
FROM private.followup_queue
GROUP BY status;


-- Criar view para Acompanhar performance e identificar problemas: Performance por empresa
CREATE OR REPLACE VIEW public.view_followup_performance
WITH (security_invoker = true)
AS
SELECT 
    c.name as company_name,
    fq.status,
    COUNT(*) as total,
    AVG(fq.tentativa) as avg_attempts,
    MAX(fq.updated_at) as last_activity
FROM private.followup_queue fq
JOIN public.companies c ON c.id = fq.company_id
WHERE fq.created_at > NOW() - INTERVAL '7 days'
GROUP BY c.name, fq.status
ORDER BY c.name, fq.status;


-- Criar view para Acompanhar performance e identificar problemas: Regras mais ativas
CREATE OR REPLACE VIEW public.view_followup_rules_activity
WITH (security_invoker = true)
AS
SELECT 
    fs.rule_name,
    fs.trigger_scope,
    c.name as company_name,
    COUNT(fq.id) as queue_items,
    fs.last_sent_at,
    fs.send_days_interval
FROM public.followup_settings fs
JOIN public.companies c ON c.id = fs.company_id
LEFT JOIN private.followup_queue fq ON fq.setting_id = fs.id
WHERE fs.is_active = true
GROUP BY fs.id, fs.rule_name, fs.trigger_scope, c.name, fs.last_sent_at, fs.send_days_interval
ORDER BY queue_items DESC;


-- Criar view para visualizar status personalizados com o nome do status global
CREATE OR REPLACE VIEW public.view_order_item_status
WITH (security_invoker = true)
AS
SELECT
    ois.id,
    ois.company_id,
    ois.name,
    ois.color,
    ois.position,
    ois.is_final,
    ois.expose_to_supplier,
    ois.default_status_id,
    dos.name AS default_status_name,  -- Nome do status global ao invés do ID
    ois.created_at
FROM public.order_item_status ois
LEFT JOIN public.default_order_status dos ON ois.default_status_id = dos.id;


-- Criar view para visualizar configurações de follow-up com descrição do trigger scope
CREATE OR REPLACE VIEW public.view_followup_settings
WITH (security_invoker = true)
AS
SELECT
    fs.id,
    fs.company_id,
    fs.rule_name,
    fs.last_sent_at,
    fs.trigger_scope,
    -- Campo extra que traduz o trigger_scope para um nome descritivo
    CASE 
        WHEN fs.trigger_scope = 'default_order_status' THEN 'Status de Pedido'
        WHEN fs.trigger_scope = 'order_due_date' THEN 'Data de Vencimento do Pedido'
        WHEN fs.trigger_scope = 'item_status' THEN 'Status'
        WHEN fs.trigger_scope = 'item_due_date' THEN 'Data de Vencimento do Item'
        WHEN fs.trigger_scope = 'item_delivery_date' THEN 'Data de Entrega do Item'
        WHEN fs.trigger_scope = 'manual_user_trigger' THEN 'Trigger Manual do Usuário'
        WHEN fs.trigger_scope = 'manual_user_order_cancel' THEN 'Cancelamento Manual do Pedido'
        ELSE fs.trigger_scope
    END AS trigger_scope_description,
    fs.trigger_reference_id,
    -- Novo campo: busca o nome do status baseado no trigger_scope
    CASE 
        WHEN fs.trigger_scope IN ('default_order_status') THEN
            (SELECT dos.name FROM public.default_order_status dos WHERE dos.id = fs.trigger_reference_id)
        WHEN fs.trigger_scope IN ('item_status') THEN
            (SELECT ois.name FROM public.order_item_status ois WHERE ois.id = fs.trigger_reference_id)
        ELSE NULL
    END AS trigger_reference_name,
    fs.send_days_interval,
    fs.repeat_interval_days,
    fs.max_followups,
    fs.cooldown_per_order,
    fs.email_template,
    fs.notification_type,
    fs.is_active,
    fs.created_at
FROM public.followup_settings fs
WHERE fs.is_system_config = false;


-- Criar view para visualizar observações da order e item com item_number
CREATE OR REPLACE VIEW public.view_order_and_item_observations
WITH (security_invoker = true)
AS
SELECT 
    oio.id,
    oio.order_id,
    oio.order_item_id,
    o.order_number,
    oi.item_number,
    oi.product,
    oio.user_observations,
    oio.supplier_observations,
    oio.current_delivery_date,
    oio.created_at,
    oio.created_by
FROM public.order_and_item_observations oio
LEFT JOIN public.order_items oi ON oio.order_item_id = oi.id
LEFT JOIN public.orders o ON oio.order_id = o.id;


-- Criar view que combina informações de itens de pedido e pedidos com suas respectivas faturas/notas fiscais
CREATE VIEW public.view_order_and_item_invoices
WITH (security_invoker = true) AS
SELECT 
    oi.order_id,
    oi.id AS order_item_id,
    oi.item_number,
    oi.product,
    oii.id AS invoice_id,
    oii.nfe_number,
    oii.invoiced_value,
    oii.nfe_date,
    oii.created_at,
    oi.quantity AS quantity_ordered,    -- Quantidade solicitada do pedido
    oii.quantity AS quantity_delivered  -- Quantidade entregue/faturada
FROM 
    public.order_items oi
INNER JOIN 
    public.order_item_invoices oii ON oi.id = oii.order_item_id
ORDER BY 
    oi.order_id, 
    oi.item_number, 
    oii.nfe_date;


-- Criar view inteligente para visualizar logs de alterações dos pedidos
CREATE OR REPLACE VIEW public.view_order_change_logs
WITH (security_invoker = true)
AS
WITH combined_logs AS (
    -- Logs de pedidos
    SELECT 
        'order' AS log_type,
        ol.id,
        ol.order_id,
        NULL AS order_item_id,
        ol.changed_by_client,
        ol.changed_by_supplier,
        ol.source,
        ol.created_at,
        -- Informações do pedido
        o.order_number,
        o.order_description,
        s.name AS supplier_name,
        dos_old.name AS old_status_name,
        dos_new.name AS new_status_name,
        ol.old_due_date,
        ol.new_due_date,
        ol.old_order_number,
        ol.new_order_number,
        ol.old_order_description,
        ol.new_order_description,
        ol.change_reason,
        -- Campos para identificar mudanças
        CASE 
            WHEN ol.old_status_id IS DISTINCT FROM ol.new_status_id THEN 'status'
            WHEN ol.old_due_date IS DISTINCT FROM ol.new_due_date THEN 'due_date'
            WHEN ol.old_order_number IS DISTINCT FROM ol.new_order_number THEN 'order_number'
            WHEN ol.old_order_description IS DISTINCT FROM ol.new_order_description THEN 'order_description'
            ELSE 'other'
        END AS change_type,
        -- Label
        CASE 
            WHEN ol.old_status_id IS DISTINCT FROM ol.new_status_id THEN 'Status'
            WHEN ol.old_due_date IS DISTINCT FROM ol.new_due_date THEN 'Data de Vencimento'
            WHEN ol.old_order_number IS DISTINCT FROM ol.new_order_number THEN 'Número do Pedido'
            WHEN ol.old_order_description IS DISTINCT FROM ol.new_order_description THEN 'Descrição do Pedido'
            ELSE 'Outro'
        END AS change_type_label,
        -- Descrição da mudança
        CASE 
            WHEN ol.old_status_id IS DISTINCT FROM ol.new_status_id THEN 
                'Status alterado de "' || COALESCE(dos_old.name, 'N/A') || '" para "' || COALESCE(dos_new.name, 'N/A') || '"'
            WHEN ol.old_due_date IS DISTINCT FROM ol.new_due_date THEN 
                'Data de vencimento alterada de "' || COALESCE(ol.old_due_date::TEXT, 'N/A') || '" para "' || COALESCE(ol.new_due_date::TEXT, 'N/A') || '"'
            WHEN ol.old_order_number IS DISTINCT FROM ol.new_order_number THEN 
                'Número do pedido alterado de "' || COALESCE(ol.old_order_number, 'N/A') || '" para "' || COALESCE(ol.new_order_number, 'N/A') || '"'
            WHEN ol.old_order_description IS DISTINCT FROM ol.new_order_description THEN 
                'Descrição do pedido alterada'
            ELSE 'Alteração realizada'
        END AS change_description
    FROM public.order_logs ol
    JOIN public.orders o ON o.id = ol.order_id
    JOIN public.suppliers s ON s.id = o.supplier_id
    LEFT JOIN public.default_order_status dos_old ON dos_old.id = ol.old_status_id
    LEFT JOIN public.default_order_status dos_new ON dos_new.id = ol.new_status_id
    
    UNION ALL
    
    -- Logs de itens de pedido
    SELECT 
        'item' AS log_type,
        oil.id,
        o.id AS order_id, -- ID do pedido (orders.id) ao qual o item pertence
        oil.order_item_id,
        oil.changed_by_client,
        oil.changed_by_supplier,
        oil.source,
        oil.created_at,
        -- Informações do pedido (via item)
        o.order_number,
        o.order_description,
        s.name AS supplier_name,
        -- Status
        ois_old.name AS old_status_name,
        ois_new.name AS new_status_name,
        -- Outros campos
        oil.old_due_date,
        oil.new_due_date,
        NULL AS old_order_number,
        NULL AS new_order_number,
        NULL AS old_order_description,
        NULL AS new_order_description,
        NULL AS change_reason,
        -- Campos para identificar mudanças
        CASE 
            WHEN oil.old_status_id IS DISTINCT FROM oil.new_status_id THEN 'status'
            WHEN oil.old_due_date IS DISTINCT FROM oil.new_due_date THEN 'due_date'
            WHEN oil.old_product IS DISTINCT FROM oil.new_product THEN 'product'
            WHEN oil.old_quantity IS DISTINCT FROM oil.new_quantity THEN 'quantity'
            WHEN oil.old_unit_price IS DISTINCT FROM oil.new_unit_price THEN 'unit_price'
            WHEN oil.old_current_delivery_date IS DISTINCT FROM oil.new_current_delivery_date THEN 'delivery_date'
            ELSE 'other'
        END AS change_type,
        -- Label
        CASE 
            WHEN oil.old_status_id IS DISTINCT FROM oil.new_status_id THEN 'Status'
            WHEN oil.old_due_date IS DISTINCT FROM oil.new_due_date THEN 'Data de Vencimento'
            WHEN oil.old_product IS DISTINCT FROM oil.new_product THEN 'Produto'
            WHEN oil.old_quantity IS DISTINCT FROM oil.new_quantity THEN 'Quantidade'
            WHEN oil.old_unit_price IS DISTINCT FROM oil.new_unit_price THEN 'Preço Unitário'
            WHEN oil.old_current_delivery_date IS DISTINCT FROM oil.new_current_delivery_date THEN 'Data de Entrega'
            ELSE 'Outro'
        END AS change_type_label,
        -- Descrição da mudança
        CASE 
            WHEN oil.old_status_id IS DISTINCT FROM oil.new_status_id THEN 
                'Status do item alterado de "' || COALESCE(ois_old.name, 'N/A') || '" para "' || COALESCE(ois_new.name, 'N/A') || '"'
            WHEN oil.old_due_date IS DISTINCT FROM oil.new_due_date THEN 
                'Data de vencimento do item alterada de "' || COALESCE(oil.old_due_date::TEXT, 'N/A') || '" para "' || COALESCE(oil.new_due_date::TEXT, 'N/A') || '"'
            WHEN oil.old_product IS DISTINCT FROM oil.new_product THEN 
                'Produto alterado de "' || COALESCE(oil.old_product, 'N/A') || '" para "' || COALESCE(oil.new_product, 'N/A') || '"'
            WHEN oil.old_quantity IS DISTINCT FROM oil.new_quantity THEN 
                'Quantidade alterada de "' || COALESCE(oil.old_quantity::TEXT, 'N/A') || '" para "' || COALESCE(oil.new_quantity::TEXT, 'N/A') || '"'
            WHEN oil.old_unit_price IS DISTINCT FROM oil.new_unit_price THEN 
                'Preço unitário alterado de "' || COALESCE(oil.old_unit_price::TEXT, 'N/A') || '" para "' || COALESCE(oil.new_unit_price::TEXT, 'N/A') || '"'
            WHEN oil.old_current_delivery_date IS DISTINCT FROM oil.new_current_delivery_date THEN 
                'Data de entrega alterada de "' || COALESCE(oil.old_current_delivery_date::TEXT, 'N/A') || '" para "' || COALESCE(oil.new_current_delivery_date::TEXT, 'N/A') || '"'
            ELSE 'Alteração realizada no item'
        END AS change_description
    FROM public.order_item_logs oil
    JOIN public.order_items oi ON oi.id = oil.order_item_id
    JOIN public.orders o ON o.id = oi.order_id
    JOIN public.suppliers s ON s.id = o.supplier_id
    LEFT JOIN public.order_item_status ois_old ON ois_old.id = oil.old_status_id
    LEFT JOIN public.order_item_status ois_new ON ois_new.id = oil.new_status_id
)
SELECT 
    cl.*,
    -- Informações do usuário que fez a alteração
    CASE 
        WHEN cl.changed_by_client IS NOT NULL THEN cu.name
        WHEN cl.changed_by_supplier IS NOT NULL THEN sc.name
        ELSE 'Sistema'
    END AS changed_by_name,
    CASE 
        WHEN cl.changed_by_client IS NOT NULL THEN cu.email
        WHEN cl.changed_by_supplier IS NOT NULL THEN sc.email
        ELSE NULL
    END AS changed_by_email,
    -- Tipo de usuário
    CASE 
        WHEN cl.changed_by_client IS NOT NULL THEN 'Cliente'
        WHEN cl.changed_by_supplier IS NOT NULL THEN 'Fornecedor'
        ELSE 'Sistema'
    END AS user_type,
    -- Informações do item (se aplicável)
    oi.item_number,
    oi.product AS item_product,
    oi.product_description AS item_product_description,
    -- Formatação de data
    TO_CHAR(cl.created_at, 'DD/MM/YYYY HH24:MI:SS') AS formatted_created_at,
    -- Tempo relativo
    CASE 
        WHEN cl.created_at > NOW() - INTERVAL '1 hour' THEN 'Agora mesmo'
        WHEN cl.created_at > NOW() - INTERVAL '24 hours' THEN 
            EXTRACT(HOUR FROM NOW() - cl.created_at)::TEXT || ' horas atrás'
        WHEN cl.created_at > NOW() - INTERVAL '7 days' THEN 
            EXTRACT(DAY FROM NOW() - cl.created_at)::TEXT || ' dias atrás'
        ELSE TO_CHAR(cl.created_at, 'DD/MM/YYYY')
    END AS relative_time
FROM combined_logs cl
LEFT JOIN public.company_users cu ON cu.id = cl.changed_by_client
LEFT JOIN public.supplier_contacts sc ON sc.id = cl.changed_by_supplier
LEFT JOIN public.order_items oi ON oi.id = cl.order_item_id
ORDER BY cl.created_at DESC;
