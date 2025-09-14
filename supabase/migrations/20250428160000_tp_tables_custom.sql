-- ╭────────────────────────────────────────────────────────────────────╮
-- ┃                       Custom - Transpetro                          ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Migration customizada para o cliente Transpetro (tp)
-- NÃO aplicar em outras instâncias genéricas ou de outros clientes

-- Adiciona os campos na tabela company_users
ALTER TABLE public.company_users
ADD COLUMN supplier_letter TEXT NULL,
ADD COLUMN supplier_id BIGINT NULL;

-- Adiciona comentários descritivos nas colunas
COMMENT ON COLUMN public.company_users.supplier_letter IS
  'Filtro de acesso baseado na letra inicial do fornecedor (ex: "A", "B", ou "#" para números)';

COMMENT ON COLUMN public.company_users.supplier_id IS
  'ID do fornecedor vinculado diretamente ao usuário (acesso exclusivo)';

-- Cria relacionamento de chave estrangeira entre company_users.supplier_id e suppliers.id
ALTER TABLE public.company_users
ADD CONSTRAINT fk_company_users_supplier
FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id)
ON DELETE SET NULL;


-- Adiciona campos customizados a tabela de order_items
ALTER TABLE public.order_items
ADD COLUMN bidding_description TEXT NULL,
ADD COLUMN custom_deliver_time INT NULL,
ADD COLUMN purchase_req BIGINT NULL,
ADD COLUMN purchase_req_item BIGINT NULL;


-- View encapsulada para filtrar os pedidos por iniciais do fornecedor
CREATE OR REPLACE VIEW public.view_orders_filtered_by_user
WITH (security_invoker = true) AS
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
JOIN public.company_users cu ON cu.id = (SELECT auth.uid())
JOIN private.user_access_cache uac ON uac.user_id = cu.id
WHERE
  uac.role_name = 'admin'

  -- Caso 2: usuário vinculado diretamente a um fornecedor específico
  OR (cu.supplier_id IS NOT NULL AND s.id = cu.supplier_id)

  -- Caso 1: filtro pela letra inicial ou número
  OR (
    cu.supplier_id IS NULL AND (
      (
        -- Verifica se a inicial (minúscula) está na lista
        LOWER(LEFT(s.name, 1)) = ANY (
          SELECT LOWER(UNNEST(string_to_array(cu.supplier_letter, ';')))
        )
      )
      OR (
        -- Caso especial para números, se '#' estiver na lista
        '#' = ANY(string_to_array(cu.supplier_letter, ';'))
        AND LEFT(s.name, 1) ~ '^[0-9]'
      )
    )
  )
  
  -- Garantir que fornecedores atribuídos diretamente a usuários
  -- não vazem para outros com mesma inicial
  AND (
    cu.supplier_id IS NOT NULL OR
    s.id NOT IN (
      SELECT DISTINCT cu2.supplier_id
      FROM public.company_users cu2
      WHERE cu2.supplier_id IS NOT NULL
    )
  )
LIMIT 1000;


-- View encapsulada para filtrar os fornecedores por inicial
CREATE OR REPLACE VIEW public.view_suppliers_filtered_by_user
WITH (security_invoker = true) AS
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
    cu_created.name AS creator_name,
    s.created_at
FROM public.suppliers s
LEFT JOIN public.company_users cu_created ON s.created_by = cu_created.id
JOIN public.company_users cu ON cu.id = (SELECT auth.uid())
JOIN private.user_access_cache uac ON uac.user_id = cu.id
WHERE
    uac.role_name = 'admin'

    -- Caso 2: acesso direto ao fornecedor
    OR (cu.supplier_id IS NOT NULL AND s.id = cu.supplier_id)

    -- Caso 1: acesso por inicial (letra ou número)
    OR (
      cu.supplier_id IS NULL AND (
        (
          -- Verifica se a inicial (minúscula) está na lista
          LOWER(LEFT(s.name, 1)) = ANY (
            SELECT LOWER(UNNEST(string_to_array(cu.supplier_letter, ';')))
          )
        )
        OR (
          -- Caso especial para números, se '#' estiver na lista
          '#' = ANY(string_to_array(cu.supplier_letter, ';'))
          AND LEFT(s.name, 1) ~ '^[0-9]'
        )
      )
    )

    -- Impede vazamento de fornecedores vinculados diretamente a outros usuários
    AND (
        cu.supplier_id IS NOT NULL OR
        s.id NOT IN (
            SELECT DISTINCT cu2.supplier_id
            FROM public.company_users cu2
            WHERE cu2.supplier_id IS NOT NULL
        )
    )
LIMIT 1000;

-- Criar view para listar os usuários do sistema
CREATE OR REPLACE VIEW public.view_company_users_with_supplier_letter
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
    cu.supplier_letter,
    cu.supplier_id,
    s.name AS supplier_name,
    cu.created_by,
    creator.name AS creator_name
FROM public.company_users cu
LEFT JOIN public.company_users creator ON creator.id = cu.created_by
LEFT JOIN public.user_roles ur ON ur.id = cu.role_id
LEFT JOIN public.suppliers s ON s.id = cu.supplier_id; 

-- Criar view customizada para order_items 
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
    oi.bidding_description, -- Campo customizado para Transpetro
    oi.custom_deliver_time, -- Campo customizado para Transpetro
    oi.purchase_req,        -- Campo customizado para Transpetro
    oi.purchase_req_item,   -- Campo customizado para Transpetro
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
