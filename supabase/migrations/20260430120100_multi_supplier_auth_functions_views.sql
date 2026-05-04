-- Multi-supplier auth: trigger fixes, RPC context by order supplier, helpers, views, list RPC.

-- ═══════════════════════════════════════════════════════════════════════════
-- Helpers: resolve supplier_contact for auth user scoped to order / line
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION private.fn_resolve_supplier_contact_for_order(
  p_auth_user_id uuid,
  p_order_id bigint
) RETURNS bigint
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
  SELECT sc.id
  FROM public.orders o
  JOIN public.supplier_contacts sc
    ON sc.supplier_id = o.supplier_id
   AND sc.is_active = true
  JOIN public.supplier_users su
    ON su.supplier_contact_id = sc.id
   AND su.auth_user_id = p_auth_user_id
  WHERE o.id = p_order_id
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION private.fn_resolve_supplier_contact_for_order_item(
  p_auth_user_id uuid,
  p_order_item_id bigint
) RETURNS bigint
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $$
  SELECT sc.id
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  JOIN public.supplier_contacts sc
    ON sc.supplier_id = o.supplier_id
   AND sc.is_active = true
  JOIN public.supplier_users su
    ON su.supplier_contact_id = sc.id
   AND su.auth_user_id = p_auth_user_id
  WHERE oi.id = p_order_item_id
  LIMIT 1;
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- Auth / supplier triggers
-- ═══════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION private.fn_delete_auth_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
BEGIN
  IF TG_TABLE_NAME = 'supplier_users' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.supplier_users su
      WHERE su.auth_user_id = OLD.auth_user_id
    ) THEN
      DELETE FROM auth.users WHERE id = OLD.auth_user_id;
    END IF;
  ELSE
    DELETE FROM auth.users WHERE id = OLD.id;
  END IF;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION private.fn_update_last_login()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
BEGIN
  UPDATE public.company_users
  SET last_login = NEW.last_sign_in_at
  WHERE id = NEW.id;

  UPDATE public.supplier_users
  SET last_login = NEW.last_sign_in_at
  WHERE auth_user_id = NEW.id;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION private.fn_handle_new_auth_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private'
AS $$
DECLARE
  v_role_name TEXT;
  v_role_id INT;
  v_company_id BIGINT;
  v_supplier_id BIGINT;
  v_is_active BOOLEAN;
  v_user_supplier_id BIGINT;
  v_supplier_letter TEXT;
  v_supplier_contact_id BIGINT;
  v_user_name TEXT;
  v_created_by UUID;
BEGIN
  v_role_name := NEW.raw_user_meta_data ->> 'role_name';
  v_user_name := NEW.raw_user_meta_data ->> 'user_name';
  v_supplier_letter := NEW.raw_user_meta_data ->> 'supplier_letter';
  v_user_supplier_id := (NEW.raw_user_meta_data ->> 'user_supplier_id')::BIGINT;
  v_company_id := (NEW.raw_user_meta_data ->> 'company_id')::BIGINT;
  v_supplier_id := (NEW.raw_user_meta_data ->> 'supplier_id')::BIGINT;
  v_created_by := (NEW.raw_user_meta_data ->> 'created_by')::UUID;
  v_is_active := (NEW.raw_user_meta_data ->> 'is_active')::BOOLEAN;

  SELECT id INTO v_role_id FROM public.user_roles WHERE name = v_role_name LIMIT 1;

  IF v_role_name IN ('admin', 'comprador') THEN
    INSERT INTO public.company_users (
      id, company_id, name, email, role_id, is_active, created_by, created_at, supplier_letter, supplier_id
    ) VALUES (
      NEW.id,
      v_company_id,
      COALESCE(v_user_name, ''),
      NEW.email,
      v_role_id,
      v_is_active,
      v_created_by,
      NOW(),
      v_supplier_letter,
      v_user_supplier_id
    );

    INSERT INTO private.user_access_cache (
      user_id, role_id, role_name, company_id, supplier_id, is_active, last_synced_at
    ) VALUES (
      NEW.id, v_role_id, v_role_name, v_company_id, NULL, v_is_active, NOW()
    );

  ELSIF v_role_name = 'fornecedor' THEN
    SELECT sc.id INTO v_supplier_contact_id
    FROM public.supplier_contacts sc
    WHERE sc.supplier_id = v_supplier_id
      AND sc.email = NEW.email
    LIMIT 1;

    IF v_supplier_contact_id IS NULL THEN
      RAISE EXCEPTION 'No supplier_contact found for supplier_id % and email %', v_supplier_id, NEW.email;
    END IF;

    INSERT INTO public.supplier_users (
      auth_user_id, supplier_contact_id, role_id
    ) VALUES (
      NEW.id,
      v_supplier_contact_id,
      v_role_id
    );

    INSERT INTO private.user_access_cache (
      user_id, role_id, role_name, company_id, supplier_id, is_active, last_synced_at
    ) VALUES (
      NEW.id, v_role_id, v_role_name, v_company_id, v_supplier_id, v_is_active, NOW()
    );
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION private.fn_sync_supplier_user_access()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private', 'auth'
AS $$
DECLARE
  v_role_name TEXT := 'fornecedor';
  v_metadata JSONB;
  v_supplier_id BIGINT;
  v_company_id BIGINT;
  v_supplier_email TEXT;
  v_supplier_name TEXT;
  v_created_by UUID;
  v_auth_uid UUID;
BEGIN
  SELECT sc.supplier_id, s.company_id, sc.email, sc.name, sc.created_by
  INTO v_supplier_id, v_company_id, v_supplier_email, v_supplier_name, v_created_by
  FROM public.supplier_contacts sc
  JOIN public.suppliers s ON s.id = sc.supplier_id
  WHERE sc.id = NEW.id;

  UPDATE private.user_access_cache uac
  SET
    is_active      = NEW.is_active,
    last_synced_at = now()
  FROM public.supplier_contacts sc
  WHERE sc.id = NEW.id
    AND uac.user_id IN (
      SELECT su.auth_user_id FROM public.supplier_users su WHERE su.supplier_contact_id = NEW.id
    )
    AND uac.role_name = 'fornecedor'
    AND uac.supplier_id = sc.supplier_id;

  FOR v_auth_uid IN
    SELECT DISTINCT su.auth_user_id
    FROM public.supplier_users su
    WHERE su.supplier_contact_id = NEW.id
  LOOP
    SELECT raw_user_meta_data INTO v_metadata
    FROM auth.users
    WHERE id = v_auth_uid;

    IF v_metadata IS NULL THEN
      v_metadata := '{}'::jsonb;
    END IF;

    v_metadata := jsonb_set(v_metadata, '{role_name}', to_jsonb(v_role_name), true);
    v_metadata := jsonb_set(v_metadata, '{supplier_id}', to_jsonb(v_supplier_id), true);
    v_metadata := jsonb_set(v_metadata, '{company_id}', to_jsonb(v_company_id), true);
    v_metadata := jsonb_set(v_metadata, '{supplier_email}', to_jsonb(v_supplier_email), true);
    v_metadata := jsonb_set(v_metadata, '{supplier_name}', to_jsonb(v_supplier_name), true);
    v_metadata := jsonb_set(v_metadata, '{created_by}', to_jsonb(v_created_by), true);
    v_metadata := jsonb_set(v_metadata, '{is_active}', to_jsonb(NEW.is_active), true);

    UPDATE auth.users
    SET raw_user_meta_data = v_metadata
    WHERE id = v_auth_uid;
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_delete_auth_user_on_supplier_user_delete ON public.supplier_users;
CREATE TRIGGER trg_delete_auth_user_on_supplier_user_delete
AFTER DELETE ON public.supplier_users
FOR EACH ROW
EXECUTE FUNCTION private.fn_delete_auth_user();

DROP TRIGGER IF EXISTS trg_check_supplier_user_role ON public.supplier_users;
CREATE TRIGGER trg_check_supplier_user_role
BEFORE INSERT OR UPDATE ON public.supplier_users
FOR EACH ROW
EXECUTE FUNCTION private.fn_check_supplier_user_role();

-- ═══════════════════════════════════════════════════════════════════════════
-- Order write RPCs (supplier contact from order supplier_id)
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
        AND uac.supplier_id = (SELECT o2.supplier_id FROM public.orders o2 WHERE o2.id = p_order_id)
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
        AND uac.supplier_id = (
          SELECT o.supplier_id
          FROM public.order_items oi2
          JOIN public.orders o ON o.id = oi2.order_id
          WHERE oi2.id = p_order_item_id
            AND oi2.order_id = p_order_id
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

CREATE OR REPLACE FUNCTION public.fn_insert_order_item_invoice(
  p_order_item_id BIGINT,
  p_nfe_number TEXT,
  p_nfe_date DATE,
  p_quantity NUMERIC(12,2),
  p_invoiced_value NUMERIC(12,2),
  p_volumes TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private'
AS $$
DECLARE
  v_uid UUID := (SELECT auth.uid());
  v_role_name TEXT;
  v_supplier_contact_id BIGINT;
  v_order_item_exists BOOLEAN;
BEGIN
  IF p_nfe_number IS NULL OR trim(p_nfe_number) = '' THEN
    RAISE EXCEPTION 'Número da NFe não pode ser vazio.';
  ELSIF p_nfe_date IS NULL THEN
    RAISE EXCEPTION 'Data da NFe não pode ser nula.';
  ELSIF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Quantidade faturada deve ser maior que zero.';
  ELSIF p_invoiced_value IS NULL OR p_invoiced_value < 0 THEN
    RAISE EXCEPTION 'Valor faturado não pode ser negativo.';
  END IF;

  SELECT uac.role_name
  INTO v_role_name
  FROM private.user_access_cache uac
  WHERE uac.user_id = v_uid
    AND uac.is_active = true
    AND (
      uac.role_name IN ('admin', 'comprador')
      OR (
        uac.role_name = 'fornecedor'
        AND uac.supplier_id = (
          SELECT o.supplier_id
          FROM public.order_items oi0
          JOIN public.orders o ON o.id = oi0.order_id
          WHERE oi0.id = p_order_item_id
        )
      )
    )
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Usuário % não encontrado ou sem acesso.', v_uid;
  END IF;

  IF v_role_name = 'fornecedor' THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.order_items oi
      JOIN public.orders o ON o.id = oi.order_id
      WHERE oi.id = p_order_item_id
        AND EXISTS (
          SELECT 1
          FROM private.user_access_cache uac2
          WHERE uac2.user_id = v_uid
            AND uac2.is_active = true
            AND uac2.role_name = 'fornecedor'
            AND uac2.supplier_id = o.supplier_id
        )
    ) INTO v_order_item_exists;

    IF NOT v_order_item_exists THEN
      RAISE EXCEPTION 'Item de pedido % não encontrado ou não pertence ao fornecedor.', p_order_item_id;
    END IF;

    v_supplier_contact_id := private.fn_resolve_supplier_contact_for_order_item(v_uid, p_order_item_id);
    IF v_supplier_contact_id IS NULL THEN
      RAISE EXCEPTION 'Supplier contact not resolved for user % and order item %.', v_uid, p_order_item_id;
    END IF;

    PERFORM set_config('request.source', 'supplier', true);
    PERFORM set_config('request.supplier_contact_id', v_supplier_contact_id::TEXT, true);
    PERFORM set_config('request.user_id', v_uid::TEXT, true);

  ELSIF v_role_name IN ('admin', 'comprador') THEN
    SELECT EXISTS (
      SELECT 1
      FROM public.order_items oi
      JOIN public.orders o ON o.id = oi.order_id
      JOIN private.user_access_cache uac ON uac.company_id = o.company_id
      WHERE oi.id = p_order_item_id
        AND uac.user_id = v_uid
        AND uac.is_active = true
    ) INTO v_order_item_exists;

    IF NOT v_order_item_exists THEN
      RAISE EXCEPTION 'Item de pedido % não encontrado ou não pertence à empresa.', p_order_item_id;
    END IF;

    PERFORM set_config('request.source', 'client', true);
    PERFORM set_config('request.user_id', v_uid::TEXT, true);

  ELSE
    RAISE EXCEPTION 'Acesso negado: usuário % não tem permissão para inserir faturamentos.', v_uid;
  END IF;

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
    p_quantity,
    p_invoiced_value,
    p_volumes,
    v_uid
  );
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
      AND uac.supplier_id = (SELECT o2.supplier_id FROM public.orders o2 WHERE o2.id = p_order_id)
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

-- ═══════════════════════════════════════════════════════════════════════════
-- fn_export_order_details: supplier display joins use auth_user_id + order supplier
-- ═══════════════════════════════════════════════════════════════════════════

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

-- ═══════════════════════════════════════════════════════════════════════════
-- List suppliers linked to current auth user (for selector UI)
-- ═══════════════════════════════════════════════════════════════════════════

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
SET search_path TO 'public'
AS $$
  SELECT s.id, s.name::text, s.cnpj::text, s.cnpj_root
  FROM public.suppliers s
  WHERE EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE uac.user_id = (select auth.uid())
      AND uac.is_active = true
      AND uac.role_name = 'fornecedor'
      AND uac.supplier_id = s.id
  );
$$;

GRANT EXECUTE ON FUNCTION public.fn_list_suppliers_for_current_user() TO authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
-- Views
-- ═══════════════════════════════════════════════════════════════════════════

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
  WHERE su.auth_user_id = onf.read_by
    AND sc.supplier_id = o.supplier_id
  LIMIT 1
) supplier_reader ON true;

CREATE OR REPLACE VIEW public.view_supplier_contacts
WITH (security_invoker = true) AS
SELECT
  sc.id AS supplier_contact_id,
  sc.supplier_id,
  sc.name,
  sc.email,
  sc.phone,
  cu.name AS creator_name,
  sc.created_at,
  sc.is_active,
  su.auth_user_id,
  su.id AS supplier_user_link_id,
  su.role_id,
  su.last_login
FROM public.supplier_contacts sc
LEFT JOIN public.company_users cu ON sc.created_by = cu.id
LEFT JOIN public.supplier_users su ON su.supplier_contact_id = sc.id;

-- Cannot CREATE OR REPLACE: first column "id" was uuid (user_id alias); now bigint (UAC row id).
-- WeWeb / legacy clients filter view by id = auth.uid(); restore id as user_id UUID.
-- access_cache_id is the surrogate PK for unique row (multi-supplier fornecedor).
DROP VIEW IF EXISTS public.view_user_access_cache CASCADE;

CREATE VIEW public.view_user_access_cache
WITH (security_invoker = true) AS
SELECT
  user_id AS id,
  id AS access_cache_id,
  role_id,
  role_name,
  company_id,
  supplier_id,
  is_active,
  last_synced_at
FROM private.user_access_cache;

-- Column list/order changed vs original view_orders; replace requires DROP first.
DROP VIEW IF EXISTS public.view_orders CASCADE;

CREATE VIEW public.view_orders
WITH (security_invoker = true) AS
SELECT
  o.id,
  o.supplier_id,
  s.cnpj AS cnpj,
  s.cnpj AS supplier_cnpj,
  s.cnpj_root AS supplier_cnpj_root,
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
    ) THEN false
    WHEN EXISTS (
      SELECT 1 FROM public.order_items oi
      JOIN public.order_item_status ois ON oi.status_id = ois.id
      WHERE oi.order_id = o.id AND ois.is_final = FALSE
    ) AND dos.code = 'concluido' THEN true
    ELSE CURRENT_DATE > o.due_date
  END AS overdue_order,
  EXISTS (
    SELECT 1
    FROM public.order_notifications orn
    WHERE orn.order_id = o.id
      AND orn.is_read = false
      AND orn.type IN ('order_status_change', 'delivery_date_change', 'item_status_change', 'item_invoiced')
  ) AS has_notifications_from_supplier,
  EXISTS (
    SELECT 1
    FROM public.order_notifications orn
    WHERE orn.order_id = o.id
      AND orn.is_read = false
      AND orn.type IN ('client_observation', 'client_status_change', 'client_item_change')
  ) AS has_notifications_from_client,
  EXISTS (
    SELECT 1
    FROM public.order_notifications orn
    WHERE orn.order_id = o.id
      AND orn.is_read = false
  ) AS has_notifications,
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

-- Multi-supplier UAC: várias linhas por user_id duplicavam pedidos; DISTINCT ON para WeWeb.
CREATE OR REPLACE VIEW public.view_orders_filtered_by_user
WITH (security_invoker = true) AS
SELECT *
FROM (
  SELECT DISTINCT ON (o.id)
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
      ) THEN false
      ELSE CURRENT_DATE > o.due_date
    END AS overdue_order,
    EXISTS (
      SELECT 1
      FROM public.order_items oi
      JOIN private.followup_item_tracking fit ON fit.order_item_id = oi.id
      JOIN public.followup_settings fs ON fs.id = fit.setting_id
      WHERE oi.order_id = o.id
        AND fs.is_active = true
        AND fs.max_followups IS NOT NULL
        AND fit.followup_count >= fs.max_followups
    ) AS max_followups_reached,
    EXISTS (
      SELECT 1
      FROM public.view_order_notifications von
      WHERE von.order_id = o.id
        AND von.is_read = false
        AND von.is_from_client = false
    ) AS has_notifications_from_supplier,
    EXISTS (
      SELECT 1
      FROM public.view_order_notifications von
      WHERE von.order_id = o.id
        AND von.is_read = false
        AND von.is_from_client = true
    ) AS has_notifications_from_client,
    COALESCE(min_status.status_id, NULL) AS order_items_min_status_id,
    COALESCE(min_status.status_name, NULL) AS order_items_min_status_name
  FROM public.orders o
  JOIN public.suppliers s ON s.id = o.supplier_id
  JOIN public.default_order_status dos ON dos.id = o.status_id
  JOIN public.company_users cu ON cu.id = (SELECT auth.uid())
  JOIN private.user_access_cache uac
    ON uac.user_id = cu.id
   AND uac.is_active = true
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
  WHERE
    uac.role_name = 'admin'
    OR (cu.supplier_id IS NOT NULL AND s.id = cu.supplier_id)
    OR (
      cu.supplier_id IS NULL AND (
        (
          LOWER(LEFT(s.name, 1)) = ANY (
            SELECT LOWER(UNNEST(string_to_array(cu.supplier_letter, ';')))
          )
        )
        OR (
          '#' = ANY(string_to_array(cu.supplier_letter, ';'))
          AND LEFT(s.name, 1) ~ '^[0-9]'
        )
      )
    )
    AND (
      cu.supplier_id IS NOT NULL OR
      s.id NOT IN (
        SELECT DISTINCT cu2.supplier_id
        FROM public.company_users cu2
        WHERE cu2.supplier_id IS NOT NULL
      )
    )
  ORDER BY
    o.id,
    CASE uac.role_name
      WHEN 'admin' THEN 1
      WHEN 'comprador' THEN 2
      WHEN 'fornecedor' THEN 3
      ELSE 4
    END,
    uac.id
) deduped_orders;

-- view_order_items (Transpetro): alinhado a view_order_notifications; evita PGRST205.
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
  oi.bidding_description,
  oi.custom_deliver_time,
  oi.purchase_req,
  oi.purchase_req_item,
  ois.id AS status_id,
  ois.name AS status_name,
  COALESCE(
    (
      SELECT SUM(oii.quantity)
      FROM public.order_item_invoices oii
      WHERE oii.order_item_id = oi.id
    ),
    0
  ) AS invoiced_quantity,
  n_supplier.type AS notification_type_from_supplier,
  n_supplier.message AS notification_message_from_supplier,
  n_client.type AS notification_type_from_client,
  n_client.message AS notification_message_from_client,
  EXISTS (
    SELECT 1
    FROM public.view_order_notifications von
    WHERE von.order_item_id = oi.id
      AND von.is_read = false
      AND von.is_from_client = false
  ) AS has_notifications_from_supplier,
  EXISTS (
    SELECT 1
    FROM public.view_order_notifications von
    WHERE von.order_item_id = oi.id
      AND von.is_read = false
      AND von.is_from_client = true
  ) AS has_notifications_from_client,
  EXISTS (
    SELECT 1
    FROM public.order_notifications
    WHERE order_item_id = oi.id
      AND is_read = false
  ) AS has_unread_notification
FROM public.order_items oi
LEFT JOIN public.order_item_status ois ON oi.status_id = ois.id
LEFT JOIN LATERAL (
  SELECT von.type, von.message, von.is_read
  FROM public.view_order_notifications von
  WHERE von.order_item_id = oi.id
    AND von.is_read = false
    AND von.is_from_client = false
  ORDER BY von.created_at DESC
  LIMIT 1
) n_supplier ON true
LEFT JOIN LATERAL (
  SELECT von.type, von.message, von.is_read
  FROM public.view_order_notifications von
  WHERE von.order_item_id = oi.id
    AND von.is_read = false
    AND von.is_from_client = true
  ORDER BY von.created_at DESC
  LIMIT 1
) n_client ON true;

GRANT SELECT ON public.view_order_items TO authenticated;
GRANT SELECT ON public.view_order_items TO service_role;

-- Supplier RLS helper (requires supplier_users.auth_user_id from 20260430120000). Policies reference this in 20260502120000.
CREATE OR REPLACE FUNCTION private.fn_supplier_access_from_uac(
  p_uac_supplier_id bigint,
  p_uac_company_id bigint,
  p_resource_supplier_id bigint
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT
    p_uac_supplier_id IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM public.suppliers s_res
      JOIN public.suppliers s_uac ON s_uac.id = p_uac_supplier_id
      WHERE s_res.id = p_resource_supplier_id
        AND s_res.company_id = p_uac_company_id
        AND s_uac.company_id = p_uac_company_id
        AND (
          s_res.id = s_uac.id
          OR (
            s_res.id <> s_uac.id
            AND EXISTS (
              SELECT 1
              FROM public.supplier_contacts sc_res
              WHERE sc_res.supplier_id = s_res.id
                AND sc_res.is_active = true
                AND EXISTS (
                  SELECT 1
                  FROM public.supplier_users su
                  JOIN public.supplier_contacts sc_u ON sc_u.id = su.supplier_contact_id
                  WHERE su.auth_user_id = (SELECT auth.uid())
                    AND sc_u.supplier_id = p_uac_supplier_id
                    AND sc_u.is_active = true
                    AND lower(trim(sc_u.email)) = lower(trim(sc_res.email))
                )
                AND EXISTS (
                  SELECT 1
                  FROM public.supplier_contacts sc2
                  JOIN public.suppliers s2 ON s2.id = sc2.supplier_id
                  WHERE sc2.is_active = true
                    AND s2.company_id = p_uac_company_id
                    AND lower(trim(sc2.email)) = lower(trim(sc_res.email))
                    AND sc2.supplier_id <> s_res.id
                )
            )
          )
        )
    );
$$;

COMMENT ON FUNCTION private.fn_supplier_access_from_uac(bigint, bigint, bigint) IS
  'Supplier: same supplier_id as UAC, or same company with matching normalized active contact email for auth user and at least one other supplier in the company sharing that email (SECURITY DEFINER).';

REVOKE ALL ON FUNCTION private.fn_supplier_access_from_uac(bigint, bigint, bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.fn_supplier_access_from_uac(bigint, bigint, bigint) TO authenticated;
