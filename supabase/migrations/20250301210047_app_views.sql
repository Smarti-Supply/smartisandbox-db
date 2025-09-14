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
  EXISTS (
    SELECT 1
    FROM public.order_notifications orn
    WHERE orn.order_id = o.id
      AND orn.is_read = false
  ) AS has_notifications
FROM public.orders o
JOIN public.suppliers s ON s.id = o.supplier_id
JOIN public.default_order_status dos ON dos.id = o.status_id
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

-- Criar view para listar as notificações dos pedidos
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
  cu.name AS read_by_name,
  cu.email AS read_by_email
FROM public.order_notifications onf
LEFT JOIN public.company_users cu ON cu.id = onf.read_by;


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
  cu.email AS user_email
FROM private.process_logs pl
LEFT JOIN public.company_users cu ON cu.id = pl.user_id;


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
        WHEN fs.trigger_scope = 'item_status' THEN 'Status de Item'
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
