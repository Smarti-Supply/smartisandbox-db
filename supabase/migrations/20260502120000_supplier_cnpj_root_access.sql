-- fn_supplier_access_from_uac: defined in 20260430120100_multi_supplier_auth_functions_views.sql (email expansion + performance-friendly EXISTS).

-- Resolve supplier_contact for orders (uses fn_supplier_access_from_uac).
CREATE OR REPLACE FUNCTION private.fn_resolve_supplier_contact_for_order(
  p_auth_user_id uuid,
  p_order_id bigint
) RETURNS bigint
LANGUAGE sql
STABLE
SET search_path TO 'public', 'private'
AS $$
  SELECT sc.id
  FROM public.orders o
  JOIN public.supplier_users su ON su.auth_user_id = p_auth_user_id
  JOIN public.supplier_contacts sc
    ON sc.id = su.supplier_contact_id
   AND sc.is_active = true
  JOIN public.suppliers s_sc ON s_sc.id = sc.supplier_id
  WHERE o.id = p_order_id
    AND private.fn_supplier_access_from_uac(sc.supplier_id, s_sc.company_id, o.supplier_id)
  ORDER BY CASE WHEN sc.supplier_id = o.supplier_id THEN 0 ELSE 1 END, sc.id
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION private.fn_resolve_supplier_contact_for_order_item(
  p_auth_user_id uuid,
  p_order_item_id bigint
) RETURNS bigint
LANGUAGE sql
STABLE
SET search_path TO 'public', 'private'
AS $$
  SELECT sc.id
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  JOIN public.supplier_users su ON su.auth_user_id = p_auth_user_id
  JOIN public.supplier_contacts sc
    ON sc.id = su.supplier_contact_id
   AND sc.is_active = true
  JOIN public.suppliers s_sc ON s_sc.id = sc.supplier_id
  WHERE oi.id = p_order_item_id
    AND private.fn_supplier_access_from_uac(sc.supplier_id, s_sc.company_id, o.supplier_id)
  ORDER BY CASE WHEN sc.supplier_id = o.supplier_id THEN 0 ELSE 1 END, sc.id
  LIMIT 1;
$$;

COMMENT ON FUNCTION private.fn_resolve_supplier_contact_for_order(uuid, bigint) IS
  'Resolves supplier_contact for an order using fn_supplier_access_from_uac (email-based expansion within company).';

COMMENT ON FUNCTION private.fn_resolve_supplier_contact_for_order_item(uuid, bigint) IS
  'Resolves supplier_contact for an order item using fn_supplier_access_from_uac (email-based expansion within company).';

-- ═══════════════════════════════════════════════════════════════════════════
-- RLS: substituir match estrito supplier_id = uac.supplier_id
-- ═══════════════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS company_or_supplier_can_read_own_suppliers ON public.suppliers;
CREATE POLICY company_or_supplier_can_read_own_suppliers
ON public.suppliers
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.is_active = true
      AND (
        (
          uac.role_name IN ('admin', 'comprador')
          AND suppliers.company_id = uac.company_id
        )
        OR (
          uac.role_name = 'fornecedor'
          AND private.fn_supplier_access_from_uac(uac.supplier_id, uac.company_id, suppliers.id)
        )
      )
  )
);

DROP POLICY IF EXISTS company_or_supplier_can_read_own_orders ON public.orders;
CREATE POLICY company_or_supplier_can_read_own_orders
ON public.orders
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.is_active = true
      AND (
        (uac.role_name IN ('admin', 'comprador') AND orders.company_id = uac.company_id)
        OR (
          uac.role_name = 'fornecedor'
          AND orders.company_id = uac.company_id
          AND private.fn_supplier_access_from_uac(uac.supplier_id, uac.company_id, orders.supplier_id)
        )
      )
  )
);

DROP POLICY IF EXISTS supplier_can_update_own_orders_status ON public.orders;
CREATE POLICY supplier_can_update_own_orders_status
ON public.orders
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'fornecedor'
      AND uac.is_active = true
      AND orders.company_id = uac.company_id
      AND private.fn_supplier_access_from_uac(uac.supplier_id, uac.company_id, orders.supplier_id)
  )
)
WITH CHECK (
  orders.status_id IS NOT NULL
);

DROP POLICY IF EXISTS company_or_supplier_can_read_own_order_items ON public.order_items;
CREATE POLICY company_or_supplier_can_read_own_order_items
ON public.order_items
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.orders o ON o.id = order_items.order_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.is_active = true
      AND (
        (uac.role_name IN ('admin', 'comprador') AND o.company_id = uac.company_id)
        OR (
          uac.role_name = 'fornecedor'
          AND o.company_id = uac.company_id
          AND private.fn_supplier_access_from_uac(uac.supplier_id, uac.company_id, o.supplier_id)
        )
      )
  )
);

DROP POLICY IF EXISTS suppliers_restricted_updates_order_items ON public.order_items;
CREATE POLICY suppliers_restricted_updates_order_items
ON public.order_items
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.orders o ON o.id = order_items.order_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.is_active = true
      AND uac.role_name = 'fornecedor'
      AND o.company_id = uac.company_id
      AND private.fn_supplier_access_from_uac(uac.supplier_id, uac.company_id, o.supplier_id)
  )
)
WITH CHECK (
  order_items.current_delivery_date IS NOT NULL
  OR order_items.status_id IS NOT NULL
);

DROP POLICY IF EXISTS company_or_supplier_can_read_own_observations ON public.order_and_item_observations;
CREATE POLICY company_or_supplier_can_read_own_observations
ON public.order_and_item_observations
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.orders o ON o.id = order_and_item_observations.order_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.is_active = true
      AND (
        (uac.role_name IN ('admin', 'comprador') AND o.company_id = uac.company_id)
        OR (
          uac.role_name = 'fornecedor'
          AND o.company_id = uac.company_id
          AND private.fn_supplier_access_from_uac(uac.supplier_id, uac.company_id, o.supplier_id)
        )
      )
  )
);

DROP POLICY IF EXISTS insert_by_suppliers ON public.order_and_item_observations;
CREATE POLICY insert_by_suppliers
ON public.order_and_item_observations
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.orders o ON o.id = order_and_item_observations.order_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.is_active
      AND uac.role_name = 'fornecedor'
      AND o.company_id = uac.company_id
      AND private.fn_supplier_access_from_uac(uac.supplier_id, uac.company_id, o.supplier_id)
  )
  AND order_and_item_observations.created_by = (select auth.uid())
  AND order_and_item_observations.supplier_observations IS NOT NULL
  AND order_and_item_observations.user_observations IS NULL
);

DROP POLICY IF EXISTS update_supplier_observations_by_supplier ON public.order_and_item_observations;
CREATE POLICY update_supplier_observations_by_supplier
ON public.order_and_item_observations
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.orders o ON o.id = order_and_item_observations.order_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.is_active = true
      AND uac.role_name = 'fornecedor'
      AND o.company_id = uac.company_id
      AND private.fn_supplier_access_from_uac(uac.supplier_id, uac.company_id, o.supplier_id)
  )
  AND order_and_item_observations.created_by = (select auth.uid())
)
WITH CHECK (
  supplier_observations IS NOT NULL
);

DROP POLICY IF EXISTS company_or_supplier_can_read_own_invoices ON public.order_item_invoices;
CREATE POLICY company_or_supplier_can_read_own_invoices
ON public.order_item_invoices
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.order_items oi ON oi.id = order_item_invoices.order_item_id
    JOIN public.orders o ON o.id = oi.order_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.is_active = true
      AND (
        (uac.role_name IN ('admin', 'comprador') AND o.company_id = uac.company_id)
        OR (
          uac.role_name = 'fornecedor'
          AND o.company_id = uac.company_id
          AND private.fn_supplier_access_from_uac(uac.supplier_id, uac.company_id, o.supplier_id)
        )
      )
  )
);

DROP POLICY IF EXISTS insert_by_suppliers ON public.order_item_invoices;
CREATE POLICY insert_by_suppliers
ON public.order_item_invoices
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.order_items oi ON oi.id = order_item_invoices.order_item_id
    JOIN public.orders o ON o.id = oi.order_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.is_active = true
      AND uac.role_name = 'fornecedor'
      AND o.company_id = uac.company_id
      AND private.fn_supplier_access_from_uac(uac.supplier_id, uac.company_id, o.supplier_id)
  )
  AND order_item_invoices.created_by = (select auth.uid())
);

DROP POLICY IF EXISTS delete_by_suppliers ON public.order_item_invoices;
CREATE POLICY delete_by_suppliers
ON public.order_item_invoices
FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.order_items oi ON oi.id = order_item_invoices.order_item_id
    JOIN public.orders o ON o.id = oi.order_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.is_active = true
      AND uac.role_name = 'fornecedor'
      AND o.company_id = uac.company_id
      AND private.fn_supplier_access_from_uac(uac.supplier_id, uac.company_id, o.supplier_id)
  )
  AND order_item_invoices.created_by = (select auth.uid())
);

DROP POLICY IF EXISTS suppliers_can_update_order_item_invoices ON public.order_item_invoices;
CREATE POLICY suppliers_can_update_order_item_invoices
ON public.order_item_invoices
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.order_items oi ON oi.id = order_item_invoices.order_item_id
    JOIN public.orders o ON o.id = oi.order_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.is_active = true
      AND uac.role_name = 'fornecedor'
      AND o.company_id = uac.company_id
      AND private.fn_supplier_access_from_uac(uac.supplier_id, uac.company_id, o.supplier_id)
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.order_items oi ON oi.id = order_item_invoices.order_item_id
    JOIN public.orders o ON o.id = oi.order_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.is_active = true
      AND uac.role_name = 'fornecedor'
      AND o.company_id = uac.company_id
      AND private.fn_supplier_access_from_uac(uac.supplier_id, uac.company_id, o.supplier_id)
  )
);

DROP POLICY IF EXISTS suppliers_can_read_client_notifications ON public.order_notifications;
CREATE POLICY suppliers_can_read_client_notifications
ON public.order_notifications
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.orders o ON o.id = order_notifications.order_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.is_active = true
      AND uac.role_name = 'fornecedor'
      AND o.company_id = uac.company_id
      AND private.fn_supplier_access_from_uac(uac.supplier_id, uac.company_id, o.supplier_id)
      AND order_notifications.type IN ('client_observation', 'client_status_change', 'client_item_change')
  )
);

DROP POLICY IF EXISTS suppliers_can_update_client_notifications ON public.order_notifications;
CREATE POLICY suppliers_can_update_client_notifications
ON public.order_notifications
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.orders o ON o.id = order_notifications.order_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.is_active = true
      AND uac.role_name = 'fornecedor'
      AND o.company_id = uac.company_id
      AND private.fn_supplier_access_from_uac(uac.supplier_id, uac.company_id, o.supplier_id)
      AND order_notifications.type IN ('client_observation', 'client_status_change', 'client_item_change')
  )
)
WITH CHECK (
  (
    read_by IS NULL OR read_by = (select auth.uid())
  ) AND
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.orders o ON o.id = order_notifications.order_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.is_active = true
      AND uac.role_name = 'fornecedor'
      AND o.company_id = uac.company_id
      AND private.fn_supplier_access_from_uac(uac.supplier_id, uac.company_id, o.supplier_id)
      AND order_notifications.type IN ('client_observation', 'client_status_change', 'client_item_change')
  )
);

-- ═══════════════════════════════════════════════════════════════════════════
-- RPCs SECURITY DEFINER: supplier checks aligned with fn_supplier_access_from_uac (email expansion)
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.fn_update_order_status(
  p_order_id BIGINT,
  p_status_id INT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private'
AS $$
DECLARE
  v_uid UUID := (select auth.uid());
  v_company_id BIGINT;
  v_role_name TEXT;
  v_supplier_contact_id BIGINT;
BEGIN
  SELECT uac.company_id, uac.role_name
  INTO v_company_id, v_role_name
  FROM private.user_access_cache uac
  WHERE uac.user_id = v_uid
    AND uac.is_active = true
    AND (
      uac.role_name IN ('admin', 'comprador')
      OR (
        uac.role_name = 'fornecedor'
        AND EXISTS (
          SELECT 1
          FROM public.orders o2
          WHERE o2.id = p_order_id
            AND o2.company_id = uac.company_id
            AND private.fn_supplier_access_from_uac(uac.supplier_id, uac.company_id, o2.supplier_id)
        )
      )
    )
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Usuário % não encontrado ou sem acesso.', v_uid;
  END IF;

  IF v_role_name IN ('admin', 'comprador') AND p_status_id = 6 THEN
    PERFORM set_config('request.source', 'client', true);
    PERFORM set_config('request.user_id', v_uid::TEXT, true);

  ELSIF v_role_name = 'fornecedor' AND p_status_id IN (2, 3, 4) THEN
    v_supplier_contact_id := private.fn_resolve_supplier_contact_for_order(v_uid, p_order_id);
    IF v_supplier_contact_id IS NULL THEN
      RAISE EXCEPTION 'Supplier contact not resolved for user % and order %.', v_uid, p_order_id;
    END IF;

    PERFORM set_config('request.source', 'supplier', true);
    PERFORM set_config('request.supplier_contact_id', v_supplier_contact_id::TEXT, true);
    PERFORM set_config('request.user_id', v_uid::TEXT, true);

  ELSE
    RAISE EXCEPTION 'Acesso negado: usuário % não possui permissão para atualizar pedidos.', v_uid;
  END IF;

  UPDATE public.orders
  SET status_id = p_status_id
  WHERE id = p_order_id
    AND company_id = v_company_id
    AND status_id IS DISTINCT FROM p_status_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pedido % não encontrado ou acesso negado.', p_order_id;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.fn_update_order_items_fields(
  p_order_id BIGINT,
  p_order_item_id BIGINT,
  p_status_id BIGINT DEFAULT NULL,
  p_current_delivery_date DATE DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private'
AS $$
DECLARE
  v_uid UUID := (SELECT auth.uid());
  v_company_id BIGINT;
  v_role_name TEXT;
  v_supplier_contact_id BIGINT;
  v_status_name TEXT;
BEGIN
  IF p_status_id IS NULL AND p_current_delivery_date IS NULL THEN
    RAISE EXCEPTION 'Pelo menos um dos parâmetros p_status_id ou p_current_delivery_date deve ser fornecido.';
  END IF;

  SELECT uac.company_id, uac.role_name
  INTO v_company_id, v_role_name
  FROM private.user_access_cache uac
  WHERE uac.user_id = v_uid
    AND uac.is_active = true
    AND (
      uac.role_name IN ('admin', 'comprador')
      OR (
        uac.role_name = 'fornecedor'
        AND EXISTS (
          SELECT 1
          FROM public.order_items oi2
          JOIN public.orders o ON o.id = oi2.order_id
          WHERE oi2.id = p_order_item_id
            AND oi2.order_id = p_order_id
            AND o.company_id = uac.company_id
            AND private.fn_supplier_access_from_uac(uac.supplier_id, uac.company_id, o.supplier_id)
        )
      )
    )
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Usuário % não encontrado ou sem acesso.', v_uid;
  END IF;

  IF v_role_name IN ('admin', 'comprador') THEN
    IF p_current_delivery_date IS NOT NULL THEN
      RAISE EXCEPTION 'Usuários com papel % não têm permissão para alterar a data de entrega do item.', v_role_name;
    END IF;

    PERFORM set_config('request.source', 'client', true);
    PERFORM set_config('request.user_id', v_uid::TEXT, true);

  ELSIF v_role_name = 'fornecedor' THEN
    IF p_status_id IS NOT NULL THEN
      SELECT name
      INTO v_status_name
      FROM public.order_item_status
      WHERE id = p_status_id
        AND expose_to_supplier = true
        AND company_id = v_company_id
      LIMIT 1;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'O status informado (ID: %) não é permitido para fornecedores ou não existe.', p_status_id;
      END IF;
    END IF;

    v_supplier_contact_id := private.fn_resolve_supplier_contact_for_order_item(v_uid, p_order_item_id);
    IF v_supplier_contact_id IS NULL THEN
      RAISE EXCEPTION 'Supplier contact not resolved for user % and order item %.', v_uid, p_order_item_id;
    END IF;

    PERFORM set_config('request.source', 'supplier', true);
    PERFORM set_config('request.supplier_contact_id', v_supplier_contact_id::TEXT, true);
    PERFORM set_config('request.user_id', v_uid::TEXT, true);
  ELSE
    RAISE EXCEPTION 'Acesso negado: usuário % não possui permissão para atualizar pedidos.', v_uid;
  END IF;

  IF p_status_id IS NOT NULL AND p_current_delivery_date IS NOT NULL THEN
    UPDATE public.order_items
    SET status_id = p_status_id,
        current_delivery_date = p_current_delivery_date
    WHERE id = p_order_item_id
      AND order_id = p_order_id;

  ELSIF p_status_id IS NOT NULL THEN
    UPDATE public.order_items
    SET status_id = p_status_id
    WHERE id = p_order_item_id
      AND order_id = p_order_id;

  ELSIF p_current_delivery_date IS NOT NULL THEN
    UPDATE public.order_items
    SET current_delivery_date = p_current_delivery_date
    WHERE id = p_order_item_id
      AND order_id = p_order_id;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Item % do Pedido % não encontrado ou acesso negado.', p_order_item_id, p_order_id;
  END IF;
END;
$$;

-- =============================================================================
-- fn_insert_order_item_invoice — dual-mode (order_item vs order)
-- =============================================================================
-- MODE A — order_item objects: each element has "order_id" key.
--   Fields read: id (order_item id), quantity, invoiced_value / total_price.
--   p_quantity overrides per-item quantity when provided.
--
-- MODE B — order objects: each element has NO "order_id" key.
--   The function fetches ALL order_items for that order and invoices each one.
--   Fields read: id (order id). p_quantity used per item;
--   invoiced_value = unit_price * effective_quantity.
--
-- p_items may be a JSON object (normalised to single-element array) or array.
-- Guards: duplicate NFe per item; auto-cap quantity to remaining (no error).
-- =============================================================================

-- Drop all previous overloads to avoid PGRST203 ambiguity.
DROP FUNCTION IF EXISTS public.fn_insert_order_item_invoice(bigint, text, date, numeric, numeric, text);
DROP FUNCTION IF EXISTS public.fn_insert_order_item_invoice(bigint, text, date, numeric, numeric, text, bigint);
DROP FUNCTION IF EXISTS public.fn_insert_order_item_invoice(jsonb, text, date, bigint);

CREATE OR REPLACE FUNCTION public.fn_insert_order_item_invoice(
  p_items         JSONB,
  nfe_number      TEXT,
  nfe_date        DATE,
  p_quantity      NUMERIC(12,2) DEFAULT NULL,
  p_new_status_id BIGINT        DEFAULT 2
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private'
AS $$
DECLARE
  STATUS_PENDING_CONFIRMATION_ID CONSTANT BIGINT := 1;

  v_uid                 UUID   := (SELECT auth.uid());
  v_role_name           TEXT;

  -- Local copies of shared params — avoids ambiguity with same-named columns.
  v_nfe_number     TEXT;
  v_nfe_date       DATE;

  -- Outer loop (over p_items elements)
  v_item           JSONB;

  -- Values resolved per order_item being processed
  v_order_item_id  BIGINT;
  v_quantity       NUMERIC(12,2);
  v_invoiced_value NUMERIC(12,2);
  v_volumes        TEXT;

  -- Used when mode B (order object): inner loop over order's items
  v_order_id       BIGINT;
  r_oi             RECORD;
BEGIN

  -- ── Validate shared parameters ───────────────────────────────────────────
  IF p_items IS NULL THEN
    RAISE EXCEPTION 'p_items cannot be null.';
  END IF;

  -- Normalise: wrap a bare object into a single-element array.
  IF jsonb_typeof(p_items) = 'object' THEN
    p_items := jsonb_build_array(p_items);
  END IF;

  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items must be a non-empty JSON object or array.';
  END IF;

  IF nfe_number IS NULL OR trim(nfe_number) = '' THEN
    RAISE EXCEPTION 'NFe number cannot be empty.';
  END IF;

  IF nfe_date IS NULL THEN
    RAISE EXCEPTION 'NFe date cannot be null.';
  END IF;

  -- Copy to unambiguous local variables.
  v_nfe_number := nfe_number;
  v_nfe_date   := nfe_date;

  -- ── Resolve caller role (once for the whole batch) ───────────────────────
  SELECT uac.role_name
  INTO v_role_name
  FROM private.user_access_cache uac
  WHERE uac.user_id  = v_uid
    AND uac.is_active = true
    AND uac.role_name IN ('admin', 'comprador', 'fornecedor')
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'User % not found or has no access.', v_uid;
  END IF;

  IF v_role_name = 'fornecedor' THEN
    PERFORM set_config('request.source',  'supplier',  true);
    PERFORM set_config('request.user_id', v_uid::TEXT, true);
  ELSIF v_role_name IN ('admin', 'comprador') THEN
    PERFORM set_config('request.source',  'client',    true);
    PERFORM set_config('request.user_id', v_uid::TEXT, true);
  ELSE
    RAISE EXCEPTION 'Access denied: user % does not have permission to insert invoices.', v_uid;
  END IF;

  -- ── Outer loop: iterate over each element of p_items ────────────────────
  FOR v_item IN SELECT value FROM jsonb_array_elements(p_items)
  LOOP
    v_volumes := v_item->>'volumes';  -- optional, same for all sub-items

    -- ────────────────────────────────────────────────────────────────────────
    -- MODE A: ORDER ITEM object — has "order_id" key
    -- ────────────────────────────────────────────────────────────────────────
    IF v_item ? 'order_id' THEN

      v_order_item_id  := (v_item->>'id')::BIGINT;
      v_quantity       := COALESCE(p_quantity, (v_item->>'quantity')::NUMERIC(12,2));
      v_invoiced_value := COALESCE(
        (v_item->>'invoiced_value')::NUMERIC(12,2),
        (v_item->>'total_price')::NUMERIC(12,2)
      );

      PERFORM private.fn_invoice_order_item(
        v_uid, v_role_name,
        v_order_item_id, v_quantity, v_invoiced_value, v_volumes,
        v_nfe_number, v_nfe_date,
        p_new_status_id, STATUS_PENDING_CONFIRMATION_ID
      );

    -- ────────────────────────────────────────────────────────────────────────
    -- MODE B: ORDER object — no "order_id" key; invoice all its order_items
    -- ────────────────────────────────────────────────────────────────────────
    ELSE

      v_order_id := (v_item->>'id')::BIGINT;

      IF v_order_id IS NULL THEN
        RAISE EXCEPTION 'id (order id) is required in every order object.';
      END IF;

      FOR r_oi IN
        SELECT oi.id, oi.quantity, oi.unit_price
        FROM public.order_items oi
        WHERE oi.order_id = v_order_id
      LOOP
        -- Effective quantity: caller override → item's own quantity
        v_quantity       := COALESCE(p_quantity, r_oi.quantity);
        -- Invoiced value proportional to effective quantity
        v_invoiced_value := ROUND(r_oi.unit_price * v_quantity, 2);

        PERFORM private.fn_invoice_order_item(
          v_uid, v_role_name,
          r_oi.id, v_quantity, v_invoiced_value, v_volumes,
          v_nfe_number, v_nfe_date,
          p_new_status_id, STATUS_PENDING_CONFIRMATION_ID
        );
      END LOOP;

    END IF;
  END LOOP;

END;
$$;


-- =============================================================================
-- Private helper: all per-item logic (access, guards, insert, status update)
-- =============================================================================
CREATE OR REPLACE FUNCTION private.fn_invoice_order_item(
  p_uid                         UUID,
  p_role_name                   TEXT,
  p_order_item_id               BIGINT,
  p_quantity                    NUMERIC(12,2),
  p_invoiced_value              NUMERIC(12,2),
  p_volumes                     TEXT,
  p_nfe_number                  TEXT,
  p_nfe_date                    DATE,
  p_new_status_id               BIGINT,
  p_status_pending_confirmation BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private'
AS $$
DECLARE
  v_supplier_contact_id      BIGINT;
  v_order_item_exists        BOOLEAN;
  v_item_quantity            NUMERIC(12,2);
  v_already_invoiced         NUMERIC(12,2);
  v_remaining                NUMERIC(12,2);
  v_effective_quantity       NUMERIC(12,2);
  v_effective_invoiced_value NUMERIC(12,2);
BEGIN

  -- ── Per-item field validation ──────────────────────────────────────────
  IF p_order_item_id IS NULL THEN
    RAISE EXCEPTION 'order_item_id is required.';
  ELSIF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Invoiced quantity must be greater than zero (item id: %).', p_order_item_id;
  ELSIF p_invoiced_value IS NULL OR p_invoiced_value < 0 THEN
    RAISE EXCEPTION 'Invoiced value cannot be negative (item id: %).', p_order_item_id;
  END IF;

  -- ── Access check ──────────────────────────────────────────────────────
  IF p_role_name = 'fornecedor' THEN

    SELECT EXISTS (
      SELECT 1
      FROM public.order_items oi
      JOIN public.orders o ON o.id = oi.order_id
      WHERE oi.id = p_order_item_id
        AND EXISTS (
          SELECT 1
          FROM private.user_access_cache uac2
          WHERE uac2.user_id  = p_uid
            AND uac2.is_active = true
            AND uac2.role_name = 'fornecedor'
            AND o.company_id   = uac2.company_id
            AND private.fn_supplier_access_from_uac(uac2.supplier_id, uac2.company_id, o.supplier_id)
        )
    ) INTO v_order_item_exists;

    IF NOT v_order_item_exists THEN
      RAISE EXCEPTION 'Order item % not found or does not belong to the supplier.', p_order_item_id;
    END IF;

    v_supplier_contact_id := private.fn_resolve_supplier_contact_for_order_item(p_uid, p_order_item_id);
    IF v_supplier_contact_id IS NULL THEN
      RAISE EXCEPTION 'Supplier contact not resolved for user % and order item %.', p_uid, p_order_item_id;
    END IF;

    PERFORM set_config('request.supplier_contact_id', v_supplier_contact_id::TEXT, true);

  ELSIF p_role_name IN ('admin', 'comprador') THEN

    SELECT EXISTS (
      SELECT 1
      FROM public.order_items oi
      JOIN public.orders o ON o.id = oi.order_id
      JOIN private.user_access_cache uac ON uac.company_id = o.company_id
      WHERE oi.id       = p_order_item_id
        AND uac.user_id  = p_uid
        AND uac.is_active = true
    ) INTO v_order_item_exists;

    IF NOT v_order_item_exists THEN
      RAISE EXCEPTION 'Order item % not found or does not belong to the company.', p_order_item_id;
    END IF;

  END IF;

  -- ── Duplicate NFe guard ────────────────────────────────────────────────
  IF EXISTS (
    SELECT 1
    FROM public.order_item_invoices oii
    WHERE oii.order_item_id = p_order_item_id
      AND oii.nfe_number    = p_nfe_number
  ) THEN
    RAISE EXCEPTION
      'Item % has already been invoiced with NFe %. Duplicate insertion is not allowed.',
      p_order_item_id, p_nfe_number;
  END IF;

  -- ── Quantity resolution ────────────────────────────────────────────────
  -- If caller requested more than what remains, auto-cap to remaining.
  -- If already fully invoiced, skip silently.
  SELECT oi.quantity, COALESCE(SUM(oii.quantity), 0)
  INTO v_item_quantity, v_already_invoiced
  FROM public.order_items oi
  LEFT JOIN public.order_item_invoices oii ON oii.order_item_id = oi.id
  WHERE oi.id = p_order_item_id
  GROUP BY oi.quantity;

  v_remaining := v_item_quantity - v_already_invoiced;

  IF v_remaining <= 0 THEN
    -- Item already fully invoiced — nothing to do for this item.
    RETURN;
  END IF;

  IF p_quantity > v_remaining THEN
    -- Auto-adjust to remaining quantity; recalculate invoiced_value proportionally.
    v_effective_quantity       := v_remaining;
    v_effective_invoiced_value := ROUND((p_invoiced_value / p_quantity) * v_remaining, 2);
  ELSE
    v_effective_quantity       := p_quantity;
    v_effective_invoiced_value := p_invoiced_value;
  END IF;

  -- ── Insert invoice ─────────────────────────────────────────────────────
  INSERT INTO public.order_item_invoices (
    order_item_id,
    nfe_number,
    nfe_date,
    quantity,
    invoiced_value,
    volumes,
    created_by
  )
  VALUES (
    p_order_item_id,
    p_nfe_number,
    p_nfe_date,
    v_effective_quantity,
    v_effective_invoiced_value,
    p_volumes,
    p_uid
  );

  -- ── Advance item status when still at "awaiting confirmation" ──────────
  UPDATE public.order_items
  SET status_id = p_new_status_id
  WHERE id        = p_order_item_id
    AND status_id = p_status_pending_confirmation;

END;
$$;

CREATE OR REPLACE FUNCTION public.fn_insert_supplier_observations(
  p_order_id BIGINT,
  p_supplier_observations TEXT,
  p_created_by UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private'
AS $$
DECLARE
  v_uid UUID := (select auth.uid());
  v_company_id BIGINT;
  v_role_name TEXT;
  v_supplier_contact_id BIGINT;
  v_order_company_id BIGINT;
BEGIN
  SELECT uac.company_id, uac.role_name
  INTO v_company_id, v_role_name
  FROM private.user_access_cache uac
  WHERE uac.user_id = v_uid
    AND uac.is_active = true
    AND (
      uac.role_name = 'fornecedor'
      AND EXISTS (
        SELECT 1
        FROM public.orders o2
        WHERE o2.id = p_order_id
          AND o2.company_id = uac.company_id
          AND private.fn_supplier_access_from_uac(uac.supplier_id, uac.company_id, o2.supplier_id)
      )
    )
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Usuário % não encontrado ou sem acesso.', v_uid;
  END IF;

  IF v_role_name <> 'fornecedor' THEN
    RAISE EXCEPTION 'Acesso negado: apenas usuários com role "fornecedor" podem inserir observações.';
  END IF;

  SELECT company_id
  INTO v_order_company_id
  FROM public.orders
  WHERE id = p_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pedido % não encontrado.', p_order_id;
  END IF;

  IF v_order_company_id <> v_company_id THEN
    RAISE EXCEPTION 'Acesso negado: pedido % não pertence à empresa do usuário.', p_order_id;
  END IF;

  v_supplier_contact_id := private.fn_resolve_supplier_contact_for_order(v_uid, p_order_id);
  IF v_supplier_contact_id IS NULL THEN
    RAISE EXCEPTION 'Supplier contact not resolved for user % and order %.', v_uid, p_order_id;
  END IF;

  PERFORM set_config('request.source', 'supplier', true);
  PERFORM set_config('request.supplier_contact_id', v_supplier_contact_id::TEXT, true);
  PERFORM set_config('request.user_id', v_uid::TEXT, true);

  INSERT INTO public.order_and_item_observations (
    order_id,
    supplier_observations,
    created_by
  ) VALUES (
    p_order_id,
    p_supplier_observations,
    p_created_by
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.fn_list_suppliers_for_current_user()
RETURNS TABLE (
  supplier_id bigint,
  supplier_name text,
  cnpj text,
  cnpj_root text
)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path TO 'public', 'private'
AS $$
  SELECT DISTINCT s.id, s.name::text, s.cnpj::text, s.cnpj_root
  FROM public.suppliers s
  WHERE EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE uac.user_id = (select auth.uid())
      AND uac.is_active = true
      AND uac.role_name = 'fornecedor'
      AND private.fn_supplier_access_from_uac(uac.supplier_id, uac.company_id, s.id)
  );
$$;

-- Export (utilizador empresa): todas as faturas/observações do pedido no JSON; join sc só para nome quando created_by é fornecedor daquele supplier.
CREATE OR REPLACE FUNCTION public.fn_export_order_details(
  p_order_id BIGINT,
  p_user_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private', 'vault'
AS $$
DECLARE
  supabase_url TEXT;
  service_role_key TEXT;
  edge_token TEXT;
  user_email TEXT;
  v_company_id BIGINT;
  v_order_company_id BIGINT;
  order_data JSONB;
  order_items_data JSONB;
  observations_data JSONB;
  followup_tracking_data JSONB;
  followup_logs_data JSONB;
  order_item_invoices_data JSONB;
  order_change_logs_data JSONB;
  combined_data JSONB;
  payload JSONB;
  export_id UUID;
  v_response JSONB;
BEGIN
  SELECT cu.email, cu.company_id
  INTO user_email, v_company_id
  FROM public.company_users cu
  WHERE cu.id = p_user_id;

  IF user_email IS NULL THEN
    RAISE EXCEPTION 'Usuário não encontrado ou sem empresa associada.';
  END IF;

  SELECT o.company_id
  INTO v_order_company_id
  FROM public.orders o
  WHERE o.id = p_order_id;

  IF v_order_company_id IS NULL THEN
    RAISE EXCEPTION 'Pedido não encontrado.';
  END IF;

  IF v_order_company_id != v_company_id THEN
    RAISE EXCEPTION 'Pedido não pertence à empresa do usuário.';
  END IF;

  SELECT jsonb_build_object(
    'numero_pedido', o.order_number,
    'pedido_descricao', o.order_description,
    'pedido_data_da_remessa', o.due_date,
    'fornecedor', s.name,
    'pedido_criado_em', o.created_at,
    'pedido_atualizado_em', o.updated_at
  )
  INTO order_data
  FROM public.orders o
  JOIN public.suppliers s ON s.id = o.supplier_id
  WHERE o.id = p_order_id;

  SELECT jsonb_agg(
    jsonb_build_object(
      'id_item', oi.id,
      'numero_item', oi.item_number,
      'produto', oi.product,
      'descricao_produto', oi.product_description,
      'quantidade', oi.quantity,
      'unidade_medida', oi.unity_of_measure,
      'preco_unitario', oi.unit_price,
      'preco_total', oi.total_price,
      'centro', oi.plant,
      'item_data_da_remessa', oi.due_date,
      'data_da_entrega', oi.current_delivery_date,
      'status', ois.name,
      'item_criado_em', oi.created_at,
      'numero_pedido', o.order_number,
      'pedido_descricao', o.order_description,
      'pedido_data_da_remessa', o.due_date,
      'fornecedor', s.name,
      'pedido_criado_em', o.created_at,
      'pedido_atualizado_em', o.updated_at
    )
  )
  INTO order_items_data
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  JOIN public.order_item_status ois ON ois.id = oi.status_id
  JOIN public.suppliers s ON s.id = o.supplier_id
  WHERE oi.order_id = p_order_id;

  IF order_items_data IS NULL THEN
    order_items_data := '[]'::jsonb;
  END IF;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', oao.id,
      'id_pedido', oao.order_id,
      'numero_item', oi.item_number,
      'observacao_do_usuario', oao.user_observations,
      'observacao_do_fornecedor', oao.supplier_observations,
      'data_da_entrega', oao.current_delivery_date,
      'criado_em', oao.created_at,
      'usuario_nome', COALESCE(cu.name, sc.name),
      'usuario_email', COALESCE(cu.email, sc.email)
    )
  ), '[]'::jsonb)
  INTO observations_data
  FROM public.order_and_item_observations oao
  LEFT JOIN public.order_items oi ON oi.id = oao.order_item_id
  LEFT JOIN public.company_users cu ON cu.id = oao.created_by
  LEFT JOIN public.orders o_ob ON o_ob.id = oao.order_id
  LEFT JOIN public.supplier_users su
    ON su.auth_user_id = oao.created_by
  LEFT JOIN public.supplier_contacts sc
    ON sc.id = su.supplier_contact_id
   AND sc.supplier_id = o_ob.supplier_id
  WHERE oao.order_id = p_order_id;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', fit.id,
      'id_pedido', fit.order_id,
      'numero_item', oi.item_number,
      'regras_de_followup', COALESCE(fs.rule_name, 'Regra não encontrada'),
      'criado_em', fit.created_at,
      'usuario_nome', COALESCE(cu.name, sc.name),
      'usuario_email', COALESCE(cu.email, sc.email)
    )
  ), '[]'::jsonb)
  INTO followup_tracking_data
  FROM private.followup_item_tracking fit
  JOIN public.order_items oi ON oi.id = fit.order_item_id
  LEFT JOIN public.followup_settings fs ON fs.id = fit.setting_id
  LEFT JOIN LATERAL (
    SELECT oil.changed_by_client, oil.changed_by_supplier
    FROM public.order_item_logs oil
    WHERE oil.order_item_id = fit.order_item_id
      AND oil.new_status_id IS NOT NULL
      AND oil.old_status_id IS DISTINCT FROM oil.new_status_id
    ORDER BY oil.created_at DESC
    LIMIT 1
  ) oil_recent ON true
  LEFT JOIN public.company_users cu ON cu.id = oil_recent.changed_by_client
  LEFT JOIN public.supplier_contacts sc ON sc.id = oil_recent.changed_by_supplier
  WHERE fit.order_id = p_order_id
    AND fit.company_id = v_company_id;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', fl.id,
      'supplier_id', fl.supplier_id,
      'supplier_contacts', fl.supplier_contacts,
      'sent_at', fl.sent_at,
      'sent_by', CASE WHEN fl.sent_by IS NULL THEN '' ELSE fl.sent_by::TEXT END,
      'sent_by_name', sent_cu.name,
      'sent_by_email', sent_cu.email,
      'user_observations', fl.user_observations,
      'supplier_observations', fl.supplier_observations,
      'setting_id', fl.setting_id,
      'rule_name', COALESCE(fs.rule_name, NULL),
      'status', fl.status,
      'notification_type', fl.notification_type,
      'created_at', fl.created_at,
      'is_automatic', CASE WHEN fl.sent_by IS NULL THEN true ELSE false END
    )
    ORDER BY fl.sent_at DESC
  ), '[]'::jsonb)
  INTO followup_logs_data
  FROM public.followup_logs fl
  LEFT JOIN public.followup_settings fs ON fs.id = fl.setting_id
  LEFT JOIN public.company_users sent_cu ON sent_cu.id = fl.sent_by
  WHERE fl.company_id = v_company_id
    AND EXISTS (
      SELECT 1
      FROM jsonb_array_elements(fl.orders_payload) AS order_entry
      WHERE (order_entry->>'order_id')::BIGINT = p_order_id
    );

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', oii.id,
      'numero_item', oi.item_number,
      'numero_nfe', oii.nfe_number,
      'data_nfe', oii.nfe_date,
      'quantidade_faturada', oii.quantity,
      'valor_faturado', oii.invoiced_value,
      'volumes', oii.volumes,
      'criado_em', oii.created_at,
      'usuario_nome', COALESCE(cu.name, sc.name),
      'usuario_email', COALESCE(cu.email, sc.email)
    )
  ), '[]'::jsonb)
  INTO order_item_invoices_data
  FROM public.order_item_invoices oii
  JOIN public.order_items oi ON oi.id = oii.order_item_id
  LEFT JOIN public.company_users cu ON cu.id = oii.created_by
  LEFT JOIN public.orders o_inv ON o_inv.id = oi.order_id
  LEFT JOIN public.supplier_users su
    ON su.auth_user_id = oii.created_by
  LEFT JOIN public.supplier_contacts sc
    ON sc.id = su.supplier_contact_id
   AND sc.supplier_id = o_inv.supplier_id
  WHERE oi.order_id = p_order_id;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'created_at', created_at,
      'formatted_created_at', formatted_created_at,
      'change_type_label', change_type_label,
      'change_description', change_description,
      'item_number', item_number,
      'changed_by_name', changed_by_name,
      'changed_by_email', changed_by_email,
      'log_type', log_type
    )
    ORDER BY created_at ASC
  ), '[]'::jsonb)
  INTO order_change_logs_data
  FROM public.view_order_change_logs
  WHERE order_id = p_order_id;

  combined_data := jsonb_build_object(
    'id_pedido', p_order_id,
    'observations', observations_data,
    'followup_tracking', followup_tracking_data
  );

  export_id := gen_random_uuid();

  SELECT decrypted_secret INTO service_role_key
  FROM vault.decrypted_secrets
  WHERE name = 'SUPABASE_SERVICE_ROLE_KEY';

  SELECT decrypted_secret INTO supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'SUPABASE_URL';

  SELECT decrypted_secret INTO edge_token
  FROM vault.decrypted_secrets
  WHERE name = 'EDGE_TOKEN';

  payload := jsonb_build_object(
    'export_id', export_id,
    'id_pedido', p_order_id,
    'order', order_data,
    'order_items', order_items_data,
    'observations', observations_data,
    'followup_tracking', followup_tracking_data,
    'followup_logs', COALESCE(followup_logs_data, '[]'::jsonb),
    'order_item_invoices', COALESCE(order_item_invoices_data, '[]'::jsonb),
    'order_change_logs', COALESCE(order_change_logs_data, '[]'::jsonb),
    'user_id', p_user_id,
    'company_id', v_company_id,
    'user_email', user_email
  );

  BEGIN
    SELECT net.http_post(
      url := supabase_url || '/functions/v1/export-order-details',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || service_role_key,
        'edge-token', edge_token
      ),
      body := payload
    ) INTO v_response;

    IF (v_response ->> 'status')::INT >= 400 THEN
      PERFORM private.fn_log_process_event(
        p_process_name := 'data_export',
        p_function_name := 'fn_export_order_details',
        p_step := 'edge_function_call',
        p_status := 'error',
        p_message := format('Erro na edge function: %s', v_response ->> 'content'),
        p_user_id := p_user_id,
        p_metadata := jsonb_build_object(
          'export_id', export_id,
          'id_pedido', p_order_id,
          'response', v_response
        )
      );

      RAISE EXCEPTION 'Erro na edge function: %', v_response ->> 'content';
    ELSE
      PERFORM private.fn_log_process_event(
        p_process_name := 'data_export',
        p_function_name := 'fn_export_order_details',
        p_step := 'edge_function_call',
        p_status := 'success',
        p_message := format('Exportação iniciada com sucesso para pedido %s', p_order_id),
        p_user_id := p_user_id,
        p_metadata := jsonb_build_object(
          'export_id', export_id,
          'id_pedido', p_order_id,
          'order_items_count', jsonb_array_length(order_items_data),
          'observations_count', jsonb_array_length(observations_data),
          'followup_tracking_count', jsonb_array_length(followup_tracking_data),
          'followup_logs_count', jsonb_array_length(COALESCE(followup_logs_data, '[]'::jsonb)),
          'response', v_response
        )
      );
    END IF;

  EXCEPTION WHEN OTHERS THEN
    PERFORM private.fn_log_process_event(
      p_process_name := 'data_export',
      p_function_name := 'fn_export_order_details',
      p_step := 'edge_function_call',
      p_status := 'error',
      p_message := format('Erro ao chamar edge function: %s', SQLERRM),
      p_user_id := p_user_id,
      p_metadata := jsonb_build_object(
        'export_id', export_id,
        'id_pedido', p_order_id,
        'error', SQLERRM
      )
    );

    RAISE EXCEPTION 'Erro ao iniciar exportação: %', SQLERRM;
  END;

  RETURN jsonb_build_object(
    'success', true,
    'export_id', export_id,
    'id_pedido', p_order_id,
    'order_items_count', jsonb_array_length(order_items_data),
    'observations_count', jsonb_array_length(observations_data),
    'followup_tracking_count', jsonb_array_length(followup_tracking_data),
    'followup_logs_count', jsonb_array_length(COALESCE(followup_logs_data, '[]'::jsonb)),
    'order_item_invoices_count', jsonb_array_length(COALESCE(order_item_invoices_data, '[]'::jsonb)),
    'message', 'Exportação iniciada com sucesso'
  );
END;
$$;

-- View: read_by do fornecedor no mesmo grupo CNPJ raiz.
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
  COALESCE(cu.name, supplier_reader.contact_name) AS read_by_name,
  COALESCE(cu.email, supplier_reader.contact_email) AS read_by_email,
  CASE
    WHEN cu.id IS NOT NULL THEN 'client'::TEXT
    WHEN supplier_reader.contact_name IS NOT NULL THEN 'supplier'::TEXT
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
LEFT JOIN LATERAL (
  SELECT sc.name AS contact_name, sc.email AS contact_email
  FROM public.supplier_users su
  JOIN public.supplier_contacts sc ON sc.id = su.supplier_contact_id
  JOIN public.suppliers s_sc ON s_sc.id = sc.supplier_id
  WHERE su.auth_user_id = onf.read_by
    AND sc.is_active = true
    AND o.id IS NOT NULL
    AND private.fn_supplier_access_from_uac(sc.supplier_id, s_sc.company_id, o.supplier_id)
  ORDER BY CASE WHEN sc.supplier_id = o.supplier_id THEN 0 ELSE 1 END, sc.id
  LIMIT 1
) supplier_reader ON true;
