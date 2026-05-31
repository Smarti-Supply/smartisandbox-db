-- ============================================================================
-- Performance fix 3.0 — view_orders e RPC para usuários fornecedor multi-supplier
-- ============================================================================
-- Contexto:
--   Um usuário com role 'fornecedor' vinculado a N fornecedores tem N linhas
--   em private.user_access_cache. Ao consultar view_orders:
--
--   1. O RLS em `orders` avalia EXISTS(UAC) para CADA linha da tabela,
--      chamando fn_supplier_access_from_uac(uac.supplier_id, ..., orders.supplier_id)
--      N vezes por linha. Com 3.8k ordens e N=10 fornecedores, o planner pode
--      escalar para dezenas de milhares de avaliações.
--
--   2. A view dispara 6 subqueries por linha qualificada:
--      – 3 EXISTS separados em order_notifications (tipo: supplier | client | any)
--      – 2 EXISTS em order_items para overdue_order (mesma condição, 2 branches do CASE)
--      – 1 LATERAL para min_status
--
--   3. O LIMIT 1000 da view é aplicado DEPOIS de todos os subqueries por linha,
--      então todos os pedidos visíveis pagam o custo antes de paginar.
--
-- Correções nesta migration:
--
--   A. Índice parcial em order_notifications(order_id, type) WHERE is_read = false
--      — Complementa idx_order_notifications_order_read_created_at para os EXISTS
--        de notificação filtrados por tipo específico.
--
--   B. Reescrita de view_orders:
--      – Merge das 3 EXISTS de notificação → 1 LATERAL com bool_or condicional
--      – Merge das 2 EXISTS de overdue   → 1 LATERAL (avalia has_open_items 1x)
--      – Total de subqueries por linha: 3 → em vez de 6
--
--   C. Nova RPC fn_get_orders_for_current_supplier(p_limit, p_offset):
--      – SECURITY DEFINER: elimina RLS overhead nas tabelas internas
--      – Resolve supplier_ids acessíveis UMA VEZ via CTE
--      – Aplica LIMIT antes dos subqueries (paginação real na fonte)
--      – Usa CTEs para agregar notificações e overdue em BATCH para a página,
--        reduzindo subqueries de O(N_pedidos × 6) → O(4 queries fixas por página)
--
-- Reversível:
--   – DROP INDEX idx_order_notifications_unread_by_order_type
--   – Reaplicar view_orders de 20260430120100_multi_supplier_auth_functions_views.sql
--   – DROP FUNCTION public.fn_get_orders_for_current_supplier(int, int)
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- A. Índice parcial para EXISTS de notificação filtrado por tipo
-- ─────────────────────────────────────────────────────────────────────────────
-- O índice existente idx_order_notifications_order_read_created_at cobre
-- (order_id, is_read, created_at DESC) mas o planner ainda precisa filtrar
-- por `type IN (...)` após a varredura. Este índice parcial WHERE is_read = false
-- inclui `type` e permite index-only scans nos 3 EXISTS de notificação,
-- e também nos bool_or do novo LATERAL.
CREATE INDEX IF NOT EXISTS idx_order_notifications_unread_by_order_type
  ON public.order_notifications (order_id, type)
  WHERE is_read = false;

-- ─────────────────────────────────────────────────────────────────────────────
-- B. Reescrita de view_orders — reduz 6 subqueries/linha → 3
-- ─────────────────────────────────────────────────────────────────────────────
-- DROP necessário pois a lista de colunas foi alterada em 20260430120100
-- (adicionados supplier_id, cnpj, supplier_cnpj, supplier_cnpj_root).
-- CASCADE recria dependentes automaticamente.
DROP VIEW IF EXISTS public.view_orders CASCADE;

CREATE VIEW public.view_orders
WITH (security_invoker = true) AS
SELECT
  o.id,
  o.supplier_id,
  s.cnpj                  AS cnpj,
  s.cnpj                  AS supplier_cnpj,
  s.cnpj_root             AS supplier_cnpj_root,
  o.order_number,
  o.order_description,
  s.external_id,
  s.name                  AS supplier_name,
  o.due_date,
  dos.id                  AS status_id,
  dos.name                AS status_name,
  o.created_at,
  o.updated_at,
  -- ── overdue_order: avaliado com UM único LATERAL (era 2 EXISTS separados) ─
  CASE
    WHEN dos.is_final = TRUE AND dos.code != 'concluido' THEN false
    WHEN NOT COALESCE(item_open.has_open_items, false)   THEN false
    ELSE CURRENT_DATE > o.due_date
  END                                         AS overdue_order,
  -- ── notificações: agregadas num único LATERAL (eram 3 EXISTS separados) ──
  COALESCE(notif.from_supplier, false)        AS has_notifications_from_supplier,
  COALESCE(notif.from_client,   false)        AS has_notifications_from_client,
  COALESCE(notif.any_unread,    false)        AS has_notifications,
  -- ── min_status: LATERAL mantido (sem mudança estrutural) ─────────────────
  COALESCE(min_status.status_id,   NULL)      AS order_items_min_status_id,
  COALESCE(min_status.status_name, NULL)      AS order_items_min_status_name
FROM public.orders o
JOIN public.suppliers             s   ON s.id   = o.supplier_id
JOIN public.default_order_status  dos ON dos.id = o.status_id
-- Lateral 1: overdue — 1 passagem em order_items substitui 2 EXISTS
LEFT JOIN LATERAL (
  SELECT bool_or(ois.is_final = false) AS has_open_items
  FROM   public.order_items       oi
  JOIN   public.order_item_status ois ON ois.id = oi.status_id
  WHERE  oi.order_id = o.id
) item_open ON true
-- Lateral 2: notificações — 1 passagem com bool_or condicional substitui 3 EXISTS
LEFT JOIN LATERAL (
  SELECT
    bool_or(onf.type IN (
      'order_status_change', 'delivery_date_change',
      'item_status_change',  'item_invoiced'
    )) AS from_supplier,
    bool_or(onf.type IN (
      'client_observation', 'client_status_change', 'client_item_change'
    )) AS from_client,
    true AS any_unread
  FROM public.order_notifications onf
  WHERE onf.order_id = o.id
    AND onf.is_read  = false
) notif ON true
-- Lateral 3: min_status (sem alteração)
LEFT JOIN LATERAL (
  SELECT
    oi.status_id,
    ois.name AS status_name
  FROM   public.order_items       oi
  LEFT JOIN public.order_item_status ois ON ois.id = oi.status_id
  WHERE  oi.order_id    = o.id
    AND  oi.status_id   IS NOT NULL
  ORDER BY COALESCE(ois.position, 999999) ASC
  LIMIT 1
) min_status ON true
LIMIT 1000;

COMMENT ON VIEW public.view_orders IS
  'Pedidos visíveis via RLS. Notificações e overdue avaliados com 3 LATERALs (era 6 subqueries/linha). Para fornecedores multi-supplier, prefira fn_get_orders_for_current_supplier(limit, offset).';

-- ─────────────────────────────────────────────────────────────────────────────
-- C. fn_get_orders_for_current_supplier — RPC otimizada para fornecedores
-- ─────────────────────────────────────────────────────────────────────────────
-- Por que SECURITY DEFINER?
--   O RLS em `orders` para fornecedores faz EXISTS(UAC) para cada linha, chamando
--   fn_supplier_access_from_uac N vezes (N = nº de suppliers do usuário). Com
--   SECURITY DEFINER a função controla o acesso explicitamente via CTE (uma
--   leitura do UAC, resultado reutilizado), sem pagar o custo de RLS por linha.
--
-- Por que CTEs para notificações / overdue?
--   Após o LIMIT da paginação, a página tem no máximo p_limit linhas. As CTEs
--   notif_agg e item_check fazem UMA query por CTE para TODOS os pedidos da
--   página via IN (SELECT id FROM base), em vez de N subqueries por linha.
--   Custo: O(p_limit) → 4 queries fixas por chamada.
--
-- Uso no frontend (Supabase JS):
--   const { data } = await supabase.rpc('get_orders_for_current_supplier', {
--     p_limit: 200, p_offset: 0
--   });
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.fn_get_orders_for_current_supplier(
  p_limit  INT DEFAULT 200,
  p_offset INT DEFAULT 0
)
RETURNS TABLE (
  id                              BIGINT,
  supplier_id                     BIGINT,
  cnpj                            TEXT,
  supplier_cnpj                   TEXT,
  supplier_cnpj_root              TEXT,
  order_number                    TEXT,
  order_description               TEXT,
  external_id                     TEXT,
  supplier_name                   TEXT,
  due_date                        DATE,
  status_id                       BIGINT,
  status_name                     TEXT,
  created_at                      TIMESTAMP,
  updated_at                      TIMESTAMP,
  overdue_order                   BOOLEAN,
  has_notifications_from_supplier BOOLEAN,
  has_notifications_from_client   BOOLEAN,
  has_notifications               BOOLEAN,
  order_items_min_status_id       BIGINT,
  order_items_min_status_name     TEXT
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'private'
AS $$
  -- ── 1. Resolve os supplier_ids acessíveis UMA vez ────────────────────────
  -- Usa idx_supplier_id_filter: (user_id, role_name, is_active, supplier_id)
  WITH accessible AS MATERIALIZED (
    SELECT uac.supplier_id,
           uac.company_id
    FROM   private.user_access_cache uac
    WHERE  uac.user_id   = (SELECT auth.uid())
      AND  uac.is_active = true
      AND  uac.role_name = 'fornecedor'
  ),
  -- ── 2. Página de pedidos via JOIN em supplier_id ──────────────────────────
  -- Usa idx_orders_company_supplier: (company_id, supplier_id)
  -- LIMIT aplicado AQUI — antes dos subqueries de notificação/overdue.
  base AS MATERIALIZED (
    SELECT
      o.id,
      o.supplier_id,
      s.cnpj::text        AS cnpj,
      s.cnpj::text        AS supplier_cnpj,
      s.cnpj_root         AS supplier_cnpj_root,
      o.order_number,
      o.order_description,
      s.external_id,
      s.name              AS supplier_name,
      o.due_date,
      dos.id              AS status_id,
      dos.name            AS status_name,
      dos.is_final        AS dos_is_final,
      dos.code            AS dos_code,
      o.created_at,
      o.updated_at
    FROM   public.orders                 o
    JOIN   accessible                    acc ON acc.supplier_id = o.supplier_id
    JOIN   public.suppliers              s   ON s.id  = o.supplier_id
                                             AND s.company_id = acc.company_id
    JOIN   public.default_order_status   dos ON dos.id = o.status_id
    ORDER BY o.updated_at DESC
    LIMIT  p_limit
    OFFSET p_offset
  ),
  -- ── 3. Notificações em batch para toda a página (1 query, não N por linha) ─
  -- Usa idx_order_notifications_unread_by_order_type: (order_id, type) WHERE is_read = false
  notif_agg AS (
    SELECT
      onf.order_id,
      bool_or(onf.type IN (
        'order_status_change', 'delivery_date_change',
        'item_status_change',  'item_invoiced'
      ))                                          AS from_supplier,
      bool_or(onf.type IN (
        'client_observation', 'client_status_change', 'client_item_change'
      ))                                          AS from_client,
      true                                        AS any_unread
    FROM   public.order_notifications onf
    WHERE  onf.order_id IN (SELECT id FROM base)
      AND  onf.is_read  = false
    GROUP BY onf.order_id
  ),
  -- ── 4. Overdue check em batch — 1 query para toda a página ───────────────
  -- Usa idx_order_items_order_status: (order_id, status_id)
  item_check AS (
    SELECT
      oi.order_id,
      bool_or(ois.is_final = false) AS has_open_items
    FROM   public.order_items       oi
    JOIN   public.order_item_status ois ON ois.id = oi.status_id
    WHERE  oi.order_id IN (SELECT id FROM base)
    GROUP BY oi.order_id
  ),
  -- ── 5. Min status em batch — 1 query para toda a página ──────────────────
  min_status AS (
    SELECT DISTINCT ON (oi.order_id)
      oi.order_id,
      oi.status_id,
      ois.name AS status_name
    FROM   public.order_items       oi
    LEFT JOIN public.order_item_status ois ON ois.id = oi.status_id
    WHERE  oi.order_id   IN (SELECT id FROM base)
      AND  oi.status_id  IS NOT NULL
    ORDER BY oi.order_id, COALESCE(ois.position, 999999) ASC
  )
  -- ── 6. Resultado final: JOINs em memória sobre a página já limitada ───────
  SELECT
    b.id,
    b.supplier_id,
    b.cnpj,
    b.supplier_cnpj,
    b.supplier_cnpj_root,
    b.order_number,
    b.order_description,
    b.external_id,
    b.supplier_name,
    b.due_date,
    b.status_id,
    b.status_name,
    b.created_at,
    b.updated_at,
    CASE
      WHEN b.dos_is_final AND b.dos_code != 'concluido' THEN false
      WHEN NOT COALESCE(ic.has_open_items, false)        THEN false
      ELSE CURRENT_DATE > b.due_date
    END                                             AS overdue_order,
    COALESCE(n.from_supplier, false)                AS has_notifications_from_supplier,
    COALESCE(n.from_client,   false)                AS has_notifications_from_client,
    COALESCE(n.any_unread,    false)                AS has_notifications,
    ms.status_id                                    AS order_items_min_status_id,
    ms.status_name                                  AS order_items_min_status_name
  FROM      base        b
  LEFT JOIN notif_agg   n  ON n.order_id  = b.id
  LEFT JOIN item_check  ic ON ic.order_id = b.id
  LEFT JOIN min_status  ms ON ms.order_id = b.id;
$$;

COMMENT ON FUNCTION public.fn_get_orders_for_current_supplier(int, int) IS
  'RPC paginada para fornecedores multi-supplier. SECURITY DEFINER elimina RLS por linha; CTEs MATERIALIZED resolvem supplier_ids uma vez e buscam notificações/overdue em batch para a página inteira. Substitui query direta em view_orders para fornecedores com muitos suppliers.';

GRANT EXECUTE ON FUNCTION public.fn_get_orders_for_current_supplier(int, int) TO authenticated;
