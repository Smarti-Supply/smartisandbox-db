-- ╭────────────────────────────────────────────────────────────────────╮
-- ┃                            Triggers                                ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- ╭────────────────────◉ CONTEXTO: Usuários ◉─────────────────────────╮
-- ┃                 Funções de gestão de usuários                      ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Criar a função trigger para inserir um novo usuário na tabela de usuários
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
  v_user_supplier_id BIGINT; -- Custom field for Transpetro
  v_supplier_letter TEXT; -- Custom field for Transpetro
  v_supplier_contact_id BIGINT;
  v_user_name TEXT;
  v_created_by UUID;
BEGIN
  -- Extrair metadados
  v_role_name := NEW.raw_user_meta_data ->> 'role_name';
  v_user_name := NEW.raw_user_meta_data ->> 'user_name';
  v_supplier_letter := NEW.raw_user_meta_data ->> 'supplier_letter'; -- Custom field for Transpetro
  v_user_supplier_id := (NEW.raw_user_meta_data ->> 'user_supplier_id')::BIGINT; -- Custom field for Transpetro
  v_company_id := (NEW.raw_user_meta_data ->> 'company_id')::BIGINT;
  v_supplier_id := (NEW.raw_user_meta_data ->> 'supplier_id')::BIGINT;
  v_created_by := (NEW.raw_user_meta_data ->> 'created_by')::UUID;
  v_is_active := (NEW.raw_user_meta_data ->> 'is_active')::BOOLEAN;

  -- Buscar role_id
  SELECT id INTO v_role_id FROM public.user_roles WHERE name = v_role_name LIMIT 1;

  -- Inserção de dados conforme role
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
      v_supplier_letter, -- Custom field for Transpetro
      v_user_supplier_id -- Custom field for Transpetro
    );

    INSERT INTO private.user_access_cache (
      user_id, role_id, role_name, company_id, supplier_id, is_active, last_synced_at
    ) VALUES (
      NEW.id, v_role_id, v_role_name, v_company_id, NULL, v_is_active, NOW()
    );

  ELSIF v_role_name = 'fornecedor' THEN
    SELECT sc.id INTO v_supplier_contact_id
    FROM public.supplier_contacts sc
    WHERE sc.supplier_id = v_supplier_id AND sc.email = NEW.email
    LIMIT 1;

    IF v_supplier_contact_id IS NULL THEN
      RAISE EXCEPTION 'No supplier_contact found for supplier_id % and email %', v_supplier_id, NEW.email;
    END IF;

    INSERT INTO public.supplier_users (
      id, supplier_contact_id, role_id
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

-- Criar o trigger em auth.users
CREATE TRIGGER trg_on_auth_user_created
AFTER INSERT ON auth.users
FOR EACH ROW
EXECUTE FUNCTION private.fn_handle_new_auth_user();


-- Criar a função trigger para deletar o usuário na tabela auth.users após exclusão da tabela company_users ou supplier_users
CREATE OR REPLACE FUNCTION private.fn_delete_auth_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
BEGIN
  DELETE FROM auth.users
  WHERE id = OLD.id;

  RETURN NULL;
END;
$$;

-- Criar o trigger em company_users e supplier_users
CREATE TRIGGER trg_delete_auth_user_on_company_user_delete
AFTER DELETE ON public.company_users
FOR EACH ROW
EXECUTE FUNCTION private.fn_delete_auth_user();

CREATE TRIGGER trg_delete_auth_user_on_supplier_user_delete
AFTER DELETE ON public.supplier_users
FOR EACH ROW
EXECUTE FUNCTION private.fn_delete_auth_user();


-- Criar a função trigger para atualizar a tabela UAC
CREATE OR REPLACE FUNCTION private.fn_sync_company_user_access()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private', 'auth'
AS $$
DECLARE
  v_role_name TEXT;
  v_metadata JSONB;
BEGIN
  -- Obter role_name baseado em role_id
  SELECT name INTO v_role_name
  FROM public.user_roles
  WHERE id = NEW.role_id;

  -- Atualizar ou inserir na tabela de cache
  UPDATE private.user_access_cache
  SET
    role_id        = NEW.role_id,
    role_name      = v_role_name,
    is_active      = NEW.is_active,
    last_synced_at = now()
  WHERE user_id = NEW.id;

  -- Carrega os metadados existentes
  SELECT raw_user_meta_data INTO v_metadata
  FROM auth.users
  WHERE id = NEW.id;

  -- Atualizar os metadados com os campos controlados
  v_metadata := jsonb_set(v_metadata, '{role_name}',       to_jsonb(v_role_name), true);
  v_metadata := jsonb_set(v_metadata, '{company_id}',      to_jsonb(NEW.company_id), true);
  v_metadata := jsonb_set(v_metadata, '{user_email}',      to_jsonb(NEW.email), true);
  v_metadata := jsonb_set(v_metadata, '{user_name}',       to_jsonb(NEW.name), true);
  v_metadata := jsonb_set(v_metadata, '{created_by}',      to_jsonb(NEW.created_by), true);
  v_metadata := jsonb_set(v_metadata, '{is_active}',       to_jsonb(NEW.is_active), true);
  v_metadata := jsonb_set(v_metadata, '{supplier_letter}', to_jsonb(NEW.supplier_letter), true); -- Custom field for Transpetro

  -- Aplica os novos metadados
  UPDATE auth.users
  SET raw_user_meta_data = v_metadata
  WHERE id = NEW.id;

  RETURN NEW;
END;
$$;

-- Criar o trigger em company_users
CREATE TRIGGER trg_sync_user_access_on_company_user_update
AFTER UPDATE ON public.company_users
FOR EACH ROW
EXECUTE FUNCTION private.fn_sync_company_user_access();


-- Criar função trigger para atualizar a tabela UAC para usuários fornecedores
CREATE OR REPLACE FUNCTION private.fn_sync_supplier_user_access()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private', 'auth'
AS $$
DECLARE
  v_role_name TEXT := 'fornecedor';
  v_metadata JSONB;
  v_role_id INT;
  v_auth_user_id UUID;
  v_supplier_id BIGINT;
  v_company_id BIGINT;
  v_supplier_email TEXT;
  v_supplier_name TEXT;
  v_created_by UUID;
BEGIN
  -- Obter role_id para "fornecedor"
  SELECT id INTO v_role_id
  FROM public.user_roles
  WHERE name = v_role_name;

  -- Obter o ID do usuário autenticado (auth.users.id) e o supplier_id do contato atualizado
  SELECT su.id, sc.supplier_id, s.company_id, sc.email, sc.name, sc.created_by
  INTO v_auth_user_id, v_supplier_id, v_company_id, v_supplier_email, v_supplier_name, v_created_by
  FROM public.supplier_users su
  JOIN public.supplier_contacts sc ON su.supplier_contact_id = sc.id
  JOIN public.suppliers s ON sc.supplier_id = s.id
  WHERE su.supplier_contact_id = NEW.id;

  -- Se não existir usuário autenticado ainda, sai silenciosamente
  IF v_auth_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  -- Atualizar no cache apenas se já existir
  UPDATE private.user_access_cache
  SET
    is_active      = NEW.is_active,
    last_synced_at = now()
  WHERE user_id = v_auth_user_id;

  -- Atualizar metadados no auth.users
  SELECT raw_user_meta_data INTO v_metadata
  FROM auth.users
  WHERE id = v_auth_user_id;

  IF v_metadata IS NULL THEN
    v_metadata := '{}';
  END IF;

  v_metadata := jsonb_set(v_metadata, '{role_name}',       to_jsonb(v_role_name), true);
  v_metadata := jsonb_set(v_metadata, '{supplier_id}',     to_jsonb(v_supplier_id), true);
  v_metadata := jsonb_set(v_metadata, '{company_id}',      to_jsonb(v_company_id), true);
  v_metadata := jsonb_set(v_metadata, '{supplier_email}',  to_jsonb(v_supplier_email), true);
  v_metadata := jsonb_set(v_metadata, '{supplier_name}',   to_jsonb(v_supplier_name), true);
  v_metadata := jsonb_set(v_metadata, '{created_by}',      to_jsonb(v_created_by), true);
  v_metadata := jsonb_set(v_metadata, '{is_active}',       to_jsonb(NEW.is_active), true);

  UPDATE auth.users
  SET raw_user_meta_data = v_metadata
  WHERE id = v_auth_user_id;

  RETURN NEW;
END;
$$;

-- Criar o trigger em supplier_contacts
CREATE TRIGGER trg_sync_user_access_on_supplier_contact_update
AFTER UPDATE ON public.supplier_contacts
FOR EACH ROW
EXECUTE FUNCTION private.fn_sync_supplier_user_access();


-- Criar a função trigger para atualizar o campo last_login
CREATE OR REPLACE FUNCTION private.fn_update_last_login()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
BEGIN
    -- Atualiza company_users se existir com o mesmo id
    UPDATE public.company_users
    SET last_login = NEW.last_sign_in_at
    WHERE id = NEW.id;

    -- Atualiza supplier_users se existir com o mesmo id
    UPDATE public.supplier_users
    SET last_login = NEW.last_sign_in_at
    WHERE id = NEW.id;
  RETURN NEW;
END;
$$;

-- Criar o trigger em auth.users
CREATE TRIGGER trg_update_last_login
AFTER UPDATE ON auth.users
FOR EACH ROW
WHEN (NEW.last_sign_in_at IS DISTINCT FROM OLD.last_sign_in_at)
EXECUTE FUNCTION private.fn_update_last_login();


-- ╭────────────────◉ CONTEXTO: Alterações de pedidos ◉────────────────╮
-- ┃                   Funções alterações de pedidos                    ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Criar a função trigger para registrar mudanças na tabela orders
CREATE OR REPLACE FUNCTION private.fn_log_order_changes()
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private'
AS $$
DECLARE
  supplier_contact_id BIGINT;
  request_source TEXT;
  client_user_id UUID;
  v_user_id UUID := (select auth.uid());
BEGIN
  -- Define 'client' como padrão caso request.source não tenha sido definido
  request_source := COALESCE(current_setting('request.source', true), 'client');

  -- Se for uma requisição do fornecedor, tenta buscar o ID
  BEGIN
    IF request_source = 'supplier' THEN
      supplier_contact_id := current_setting('request.supplier_contact_id', true)::BIGINT;
    END IF;
  EXCEPTION WHEN others THEN
    supplier_contact_id := NULL;
  END;

  BEGIN
    client_user_id := current_setting('request.user_id', true)::UUID;
  EXCEPTION WHEN others THEN
    client_user_id := v_user_id;
  END;

  -- Inserir log com campos de acordo com a operação
  INSERT INTO public.order_logs (
    order_id,
    changed_by_client,
    changed_by_supplier,
    old_status_id,
    new_status_id,
    old_due_date,
    new_due_date,
    old_supplier_id,
    new_supplier_id,
    old_order_number,
    new_order_number,
    old_order_description,
    new_order_description,
    source,
    created_at
  )
  VALUES (
    NEW.id,
    CASE WHEN request_source = 'client' THEN client_user_id ELSE NULL END,
    CASE WHEN request_source = 'supplier' THEN supplier_contact_id ELSE NULL END,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.status_id ELSE NULL END,
    NEW.status_id,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.due_date ELSE NULL END,
    NEW.due_date,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.supplier_id ELSE NULL END,
    NEW.supplier_id,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.order_number ELSE NULL END,
    NEW.order_number,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.order_description ELSE NULL END,
    NEW.order_description,
    request_source,
    now()
  );

  RETURN NEW;
END;
$$;

-- Criar o trigger na tabela orders
CREATE TRIGGER trg_log_order_changes
AFTER INSERT OR UPDATE ON public.orders
FOR EACH ROW
EXECUTE FUNCTION private.fn_log_order_changes();


-- Criar a função trigger para registrar mudanças na tabela order_items
CREATE OR REPLACE FUNCTION private.fn_log_order_item_changes()
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private'
AS $$
DECLARE
  supplier_contact_id BIGINT;
  request_source TEXT;
  client_user_id UUID;
  v_user_id UUID := (select auth.uid());
BEGIN
  -- Define 'client' como padrão caso request.source não tenha sido definido
  request_source := COALESCE(current_setting('request.source', true), 'client');

  -- Captura o usuário do fornecedor, se aplicável
  BEGIN
    IF request_source = 'supplier' THEN
      supplier_contact_id := current_setting('request.supplier_contact_id', true)::BIGINT;
    END IF;
  EXCEPTION WHEN others THEN
    supplier_contact_id := NULL;
  END;

  -- Captura o usuário do cliente
  BEGIN
    client_user_id := current_setting('request.user_id', true)::UUID;
  EXCEPTION WHEN others THEN
    client_user_id := v_user_id;
  END;

  -- Inserir log
  INSERT INTO public.order_item_logs (
    order_item_id,
    changed_by_client,
    changed_by_supplier,
    old_item_number,
    new_item_number,
    old_product,
    new_product,
    old_product_description,
    new_product_description,
    old_quantity,
    new_quantity,
    old_unity_of_measure,
    new_unity_of_measure,
    old_unit_price,
    new_unit_price,
    old_total_price,
    new_total_price,
    old_plant,
    new_plant,
    old_due_date,
    new_due_date,
    old_current_delivery_date,
    new_current_delivery_date,
    old_delivery_time,
    new_delivery_time,
    old_status_id,
    new_status_id,
    source,
    created_at
  )
  VALUES (
    NEW.id,
    CASE WHEN request_source = 'client' THEN client_user_id ELSE NULL END,
    CASE WHEN request_source = 'supplier' THEN supplier_contact_id ELSE NULL END,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.item_number ELSE NULL END,
    NEW.item_number,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.product ELSE NULL END,
    NEW.product,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.product_description ELSE NULL END,
    NEW.product_description,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.quantity ELSE NULL END,
    CASE WHEN NEW.quantity > 0 THEN NEW.quantity ELSE NULL END,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.unity_of_measure ELSE NULL END,
    NEW.unity_of_measure,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.unit_price ELSE NULL END,
    CASE WHEN NEW.unit_price >= 0 THEN NEW.unit_price ELSE NULL END,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.total_price ELSE NULL END,
    CASE WHEN NEW.total_price >= 0 THEN NEW.total_price ELSE NULL END,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.plant ELSE NULL END,
    NEW.plant,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.due_date ELSE NULL END,
    NEW.due_date,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.current_delivery_date ELSE NULL END,
    NEW.current_delivery_date,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.deliver_time ELSE NULL END,
    NEW.deliver_time,
    CASE WHEN TG_OP = 'UPDATE' THEN OLD.status_id ELSE NULL END,
    NEW.status_id,
    request_source,
    now()
  );

  RETURN NEW;
END;
$$;

-- Criar o trigger na tabela order_items
CREATE TRIGGER trg_log_order_item_changes
AFTER INSERT OR UPDATE ON public.order_items
FOR EACH ROW
EXECUTE FUNCTION private.fn_log_order_item_changes();


-- Criar a função trigger para atualizar o campo updated_at na tabela orders
CREATE OR REPLACE FUNCTION private.fn_update_column_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private'
AS $$
BEGIN
  -- Atualiza apenas se outros campos forem modificados
  IF NEW IS DISTINCT FROM OLD THEN
    NEW.updated_at := now();
  END IF;
  RETURN NEW;
END;
$$;

-- Criar o trigger na tabela orders
CREATE TRIGGER trg_order_updated_at
BEFORE UPDATE ON public.orders
FOR EACH ROW
WHEN (OLD.* IS DISTINCT FROM NEW.*)
EXECUTE FUNCTION private.fn_update_column_updated_at();

-- Criar o trigger em followup_queue
CREATE TRIGGER trigger_followup_queue_updated_at
BEFORE UPDATE ON private.followup_queue
FOR EACH ROW
WHEN (OLD.* IS DISTINCT FROM NEW.*)
EXECUTE FUNCTION private.fn_update_column_updated_at();

-- Cria trigger em followup_item_tracking
CREATE TRIGGER trigger_followup_item_tracking_updated_at
BEFORE UPDATE ON private.followup_item_tracking
FOR EACH ROW
WHEN (OLD.* IS DISTINCT FROM NEW.*)
EXECUTE FUNCTION private.fn_update_column_updated_at();

-- Criar a função trigger para propagar atualizações de order_items para orders
CREATE OR REPLACE FUNCTION private.fn_propagate_item_update_to_order()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  UPDATE public.orders
  SET updated_at = now()
  WHERE id = NEW.order_id;
  RETURN NEW;
END;
$$;

-- Criar o trigger na tabela order_items
CREATE TRIGGER trg_propagate_item_update_to_order
AFTER UPDATE ON public.order_items
FOR EACH ROW
EXECUTE FUNCTION private.fn_propagate_item_update_to_order();


-- Função para atualizar o status do pedido (Entrega Parcial ou Concluido) com base nos invoices de itens
CREATE OR REPLACE FUNCTION private.fn_update_order_status_on_invoice()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_order_id BIGINT;
  v_all_fulfilled BOOLEAN;
  v_any_delivered BOOLEAN;
BEGIN
  -- 1) Descobre o order_id a partir do item faturado
  SELECT oi.order_id INTO v_order_id
  FROM public.order_items oi
  WHERE oi.id = NEW.order_item_id;

  -- 2) Verifica se TODOS os itens foram entregues OU têm status final
  SELECT bool_and(
    COALESCE( -- item considerado entregue se soma >= quantidade OU status final
      delivered.total_quantity >= items.quantity, 
      FALSE
    ) OR COALESCE(status.is_final, FALSE)
  ) AS all_fulfilled,
  bool_or( -- pelo menos um item parcialmente entregue ou finalizado
    COALESCE(delivered.total_quantity > 0, FALSE) OR COALESCE(status.is_final, FALSE)
  ) AS any_delivered
  INTO v_all_fulfilled, v_any_delivered
  FROM public.order_items items
    LEFT JOIN (
      SELECT order_item_id, SUM(quantity) AS total_quantity
      FROM public.order_item_invoices
      GROUP BY order_item_id
    ) delivered ON delivered.order_item_id = items.id
    LEFT JOIN public.order_item_status status ON status.id = items.status_id
  WHERE items.order_id = v_order_id;

  -- 3) Atualiza status do pedido de acordo com as regras
  IF v_all_fulfilled THEN
    UPDATE public.orders
    SET status_id = 5, -- Concluído
        updated_at = now()
    WHERE id = v_order_id;
  ELSIF v_any_delivered THEN
    UPDATE public.orders
    SET status_id = 4, -- Entregas Parciais
        updated_at = now()
    WHERE id = v_order_id;
  END IF;

  RETURN NEW;
END;
$$;

-- Trigger para executar a função após INSERT ou UPDATE
CREATE TRIGGER trg_update_order_status_on_invoice
AFTER INSERT ON public.order_item_invoices
FOR EACH ROW
EXECUTE FUNCTION private.fn_update_order_status_on_invoice();


-- ╭──────────────────────◉ CONTEXTO: Company ◉────────────────────────╮
-- ┃                   Funções para dados da company                    ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Criar a função trigger para registrar a empresa criada na tabela de usuários e criar o mapeamento padrão
CREATE OR REPLACE FUNCTION private.fn_handle_new_company()
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  default_orders_mapping JSONB := '{
  "po_header_mapping": [
    {"db_field": "public.orders.order_number", "required": true, "field_label": "Número do pedido", "file_column_name": "numero_do_pedido", "original_column_name": "Número do pedido"}, 
    {"db_field": "public.suppliers.external_id", "required": true, "field_label": "ID do fornecedor", "file_column_name": "id_do_fornecedor", "original_column_name": "ID do fornecedor"},
    {"db_field": "public.orders.order_description", "required": false, "field_label": "Descrição do pedido", "file_column_name": "descricao_do_pedido", "original_column_name": "Descrição do pedido"}, 
    {"db_field": "public.orders.due_date", "required": false, "field_label": "Data da remessa - Pedido", "file_column_name": "data_da_remessa__pedido", "original_column_name": "Data da remessa - Pedido"}, 
    {"db_field": "public.order_items.item_number", "required": true, "field_label": "Item do pedido", "file_column_name": "item_do_pedido", "original_column_name": "Item do pedido"},
    {"db_field": "public.order_items.product", "required": true, "field_label": "Material", "file_column_name": "material", "original_column_name": "Material"},
    {"db_field": "public.order_items.product_description", "required": false, "field_label": "Descrição do Material", "file_column_name": "descricao_do_material", "original_column_name": "Descrição do Material"}, 
    {"db_field": "public.order_items.quantity", "required": true, "field_label": "Quantidade solicitada", "file_column_name": "quantidade_solicitada", "original_column_name": "Quantidade solicitada"},
    {"db_field": "public.order_items.unity_of_measure", "required": false, "field_label": "Unidade de medida", "file_column_name": "unidade_de_medida", "original_column_name": "Unidade de medida"},
    {"db_field": "public.order_items.unit_price", "required": true, "field_label": "Preço unitário do produto", "file_column_name": "preco_unitario_do_produto", "original_column_name": "Preço unitário do produto"}, 
    {"db_field": "public.order_items.plant", "required": false, "field_label": "Centro", "file_column_name": "centro", "original_column_name": "Centro"},
    {"db_field": "public.order_items.due_date", "required": true, "field_label": "Data da Remessa - Item", "file_column_name": "data_da_remessa__item", "original_column_name": "Data da Remessa - Item"},
    {"db_field": "public.order_items.bidding_description", "required": false, "field_label": "Descrição Licitação", "file_column_name": "descricao_licitacao", "original_column_name": "Descrição Licitação"},
    {"db_field": "public.order_items.custom_deliver_time", "required": false, "field_label": "Prazo Fornecimento", "file_column_name": "prazo_fornecimento", "original_column_name": "Prazo Fornecimento"},
    {"db_field": "public.order_items.purchase_req", "required": false, "field_label": "Número Requisição", "file_column_name": "numero_requisicao", "original_column_name": "Número Requisição"},
    {"db_field": "public.order_items.purchase_req_item", "required": false, "field_label": "Item Requisição", "file_column_name": "item_requisicao", "original_column_name": "Item Requisição"}
  ]
  }'; -- Custom fields for Transpetro: bidding_description, custom_deliver_time, purchase_req, purchase_req_item

  default_suppliers_mapping JSONB := '{
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
  }';
BEGIN
  -- Mapeamento padrão para pedidos
  INSERT INTO public.import_field_mappings (
    company_id, type, field_mapping, default_field_mapping
  )
  VALUES (
    NEW.id, 'orders', default_orders_mapping, default_orders_mapping
  );

  -- Mapeamento padrão para fornecedores
  INSERT INTO public.import_field_mappings (
    company_id, type, field_mapping, default_field_mapping
  )
  VALUES (
    NEW.id, 'suppliers', default_suppliers_mapping, default_suppliers_mapping
  );

  -- Atualiza o company_id do usuário que criou a empresa
  UPDATE public.company_users
  SET company_id = NEW.id
  WHERE id = NEW.created_by;

  RETURN NEW;
END;
$$;

-- Criar o trigger na tabela companies
CREATE TRIGGER trg_after_company_insert
AFTER INSERT ON public.companies
FOR EACH ROW
EXECUTE FUNCTION private.fn_handle_new_company();


-- ╭──────────────────────◉ CONTEXTO: Storage ◉────────────────────────╮
-- ┃                   Funções triggers para storage                    ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Função trigger para processar upload imediatamente via AWS Lambda
CREATE OR REPLACE FUNCTION private.fn_new_file_upload()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'storage', 'vault', 'private'
AS $$
DECLARE
  payload         JSONB;
  field_mapping   JSONB;
  aws_token       TEXT;
  aws_api_key     TEXT;
  aws_api_url     TEXT;
BEGIN
  -- Obter segredos
  SELECT decrypted_secret
  INTO aws_token
  FROM vault.decrypted_secrets
  WHERE name = 'AWS_TOKEN';

  SELECT decrypted_secret
  INTO aws_api_key
  FROM vault.decrypted_secrets
  WHERE name = 'AWS_API_KEY';

  SELECT decrypted_secret
  INTO aws_api_url
  FROM vault.decrypted_secrets
  WHERE name = 'AWS_API_URL';

  CASE NEW.bucket_id
    WHEN 'po-imports' THEN
      -- Mapeamento de campos para pedidos
      SELECT m.field_mapping
        INTO field_mapping
        FROM public.import_field_mappings m
        JOIN public.company_users u
        ON u.company_id = m.company_id
        WHERE u.id = NEW.owner_id::uuid
        AND m.type = 'orders';

      payload := jsonb_build_object(
        'bucket_id',    NEW.bucket_id,
        'name',         NEW.name,
        'owner_id',     NEW.owner_id,
        'field_mapping',field_mapping
      );

      BEGIN
        PERFORM net.http_post(
          url     := aws_api_url || '/process-po-upload',
          headers := jsonb_build_object(
                      'Content-Type',   'application/json',
                      'internal-token',  aws_token,
                      'x-api-key',       aws_api_key
                    ),
          body    := payload
        );
        PERFORM private.fn_log_process_event(
          p_process_name  := 'orders_upload',
          p_function_name := 'fn_new_file_upload',
          p_step          := 'po_imports',
          p_status        := 'success',
          p_message       := 'Payload enviado com sucesso',
          p_user_id       := NEW.owner_id::uuid,
          p_metadata      := payload
        );
      EXCEPTION WHEN OTHERS THEN
        PERFORM private.fn_log_process_event(
          p_process_name  := 'orders_upload',
          p_function_name := 'fn_new_file_upload',
          p_step          := 'po_imports',
          p_status        := 'error',
          p_message       := format('Erro ao chamar função de upload: %s', SQLERRM),
          p_user_id       := NEW.owner_id::uuid,
          p_metadata      := payload
        );
      END;

    WHEN 'supplier-imports' THEN
      -- Mapeamento de campos para fornecedores
      SELECT m.field_mapping
        INTO field_mapping
        FROM public.import_field_mappings m
        JOIN public.company_users u
        ON u.company_id = m.company_id
        WHERE u.id = NEW.owner_id::uuid
        AND m.type = 'suppliers';

      payload := jsonb_build_object(
        'bucket_id',    NEW.bucket_id,
        'name',         NEW.name,
        'owner_id',     NEW.owner_id,
        'field_mapping',field_mapping
      );

      BEGIN
        PERFORM net.http_post(
          url     := aws_api_url || '/process-supplier-upload',
          headers := jsonb_build_object(
                      'Content-Type', 'application/json',
                      'internal-token',  aws_token,
                      'x-api-key',       aws_api_key
                    ),
          body    := payload
        );
        PERFORM private.fn_log_process_event(
          p_process_name  := 'suppliers_upload',
          p_function_name := 'fn_new_file_upload',
          p_step          := 'supplier-imports',
          p_status        := 'success',
          p_message       := 'Payload enviado com sucesso',
          p_user_id       := NEW.owner_id::uuid,
          p_metadata      := payload
        );
      EXCEPTION WHEN OTHERS THEN
        PERFORM private.fn_log_process_event(
          p_process_name  := 'suppliers_upload',
          p_function_name := 'fn_new_file_upload',
          p_step          := 'supplier-imports',
          p_status        := 'error',
          p_message       := format('Erro ao chamar função de upload: %s', SQLERRM),
          p_user_id       := NEW.owner_id::uuid,
          p_metadata      := payload
        );
      END;

    WHEN 'po-files-imports' THEN
      -- Sem mapeamento extra
      payload := jsonb_build_object(
        'bucket_id', NEW.bucket_id,
        'name',      NEW.name,
        'owner_id',  NEW.owner_id
      );

      BEGIN
        PERFORM net.http_post(
          url     := aws_api_url || '/process-po-files',
          headers := jsonb_build_object(
                      'Content-Type', 'application/json',
                      'internal-token',  aws_token,
                      'x-api-key',       aws_api_key
                    ),
          body    := payload
        );
        PERFORM private.fn_log_process_event(
          p_process_name  := 'order_files_upload',
          p_function_name := 'fn_new_file_upload',
          p_step          := 'po_files_imports',
          p_status        := 'success',
          p_message       := 'Payload enviado com sucesso',
          p_user_id       := NEW.owner_id::uuid,
          p_metadata      := payload
        );
      EXCEPTION WHEN OTHERS THEN
        PERFORM private.fn_log_process_event(
          p_process_name  := 'order_files_upload',
          p_function_name := 'fn_new_file_upload',
          p_step          := 'po_files_imports',
          p_status        := 'error',
          p_message       := format('Erro ao chamar função de upload: %s', SQLERRM),
          p_user_id       := NEW.owner_id::uuid,
          p_metadata      := payload
        );
      END;

    -- Bucket custom para Transpetro // Remover
    WHEN 'po-migo-miro-imports' THEN
      payload := jsonb_build_object(
        'bucket_id',    NEW.bucket_id,
        'name',         NEW.name,
        'owner_id',     NEW.owner_id
      );

      BEGIN
        PERFORM net.http_post(
          url     := aws_api_url || '/process-po-migo-miro-upload',
          headers := jsonb_build_object(
                      'Content-Type',   'application/json',
                      'internal-token',  aws_token,
                      'x-api-key',       aws_api_key
                    ),
          body    := payload
        );
        PERFORM private.fn_log_process_event(
          p_process_name  := 'migo_miro_upload',
          p_function_name := 'fn_new_file_migo_miro_upload',
          p_step          := 'po-migo-miro-imports',
          p_status        := 'success',
          p_message       := 'Payload enviado com sucesso',
          p_user_id       := NEW.owner_id::uuid,
          p_metadata      := payload
        );
      EXCEPTION WHEN OTHERS THEN
        PERFORM private.fn_log_process_event(
          p_process_name  := 'migo_miro_upload',
          p_function_name := 'fn_new_file_migo_miro_upload',
          p_step          := 'po-migo-miro-imports',
          p_status        := 'error',
          p_message       := format('Erro ao chamar função de upload: %s', SQLERRM),
          p_user_id       := NEW.owner_id::uuid,
          p_metadata      := payload
        );
      END;

    ELSE
      RAISE LOG 'Bucket % não requer processamento pela trigger', NEW.bucket_id;
  END CASE;

  RETURN NEW;
END;
$$;

-- Criar o trigger em storage.objects
CREATE TRIGGER trg_new_file_upload
AFTER INSERT ON storage.objects
FOR EACH ROW
EXECUTE FUNCTION private.fn_new_file_upload();


-- Criar a função trigger para deletar arquivos de pedidos do bucket
CREATE OR REPLACE FUNCTION private.fn_delete_order_files_from_buckets()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public
AS $$
DECLARE
  v_folder_path TEXT;
  url TEXT;
  headers JSONB;
  payload JSONB;
  params JSONB := '{}'::jsonb;
  timeout_ms INT := 1000;
  request_id BIGINT;
  edge_token TEXT;
  service_role_key TEXT;
  supabase_url TEXT;
  endpoint TEXT := 'delete-bucket-files';
BEGIN
  -- Construir path
  v_folder_path := OLD.company_id::TEXT || '/' || OLD.id::TEXT || '/';

  -- Recuperar segredos
  SELECT decrypted_secret INTO edge_token
  FROM vault.decrypted_secrets
  WHERE name = 'INTERNAL_EDGE_TOKEN';

  SELECT decrypted_secret INTO service_role_key
  FROM vault.decrypted_secrets
  WHERE name = 'SUPABASE_SERVICE_ROLE_KEY';

  SELECT decrypted_secret INTO supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'SUPABASE_URL';

  -- Montar URL da edge function
  url := supabase_url || '/functions/v1/' || endpoint;

  -- Headers com autenticação
  headers := jsonb_build_object(
    'Content-Type',  'application/json',
    'Authorization', 'Bearer ' || service_role_key,
    'edge-token',    edge_token
  );

  -- Payload com os dois buckets e o caminho
  payload := jsonb_build_object(
    'buckets', jsonb_build_array('po-files', 'po-nfe-files'),
    'path', v_folder_path
  );

  -- Chamar função http_post
  SELECT net.http_post(url, payload, params, headers, timeout_ms)
  INTO request_id;

  RETURN NULL;
END;
$$;

-- Criar o trigger em orders
CREATE TRIGGER trg_delete_order_files_on_order_delete
AFTER DELETE ON public.orders
FOR EACH ROW
EXECUTE FUNCTION private.fn_delete_order_files_from_buckets();


-- ╭─────────────────────◉ CONTEXTO: Validações ◉──────────────────────╮
-- ┃                   Triggers de validação de dados                   ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Criar a função trigger para bloquear alterações no usuário
CREATE OR REPLACE FUNCTION private.fn_block_company_user_immutable_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'Alteração de ID do usuário não é permitida.';
  END IF;

  -- Permitir atribuição inicial de company_id (se antes era NULL)
  IF OLD.company_id IS NOT NULL AND NEW.company_id IS DISTINCT FROM OLD.company_id THEN
    RAISE EXCEPTION 'Alteração do company_id não é permitida.';
  END IF;

  IF NEW.email IS DISTINCT FROM OLD.email THEN
    RAISE EXCEPTION 'Alteração de e-mail do usuário não é permitida.';
  END IF;

  RETURN NEW;
END;
$$;

-- Criar o trigger em company_users
CREATE TRIGGER trg_block_id_email_update_on_company_user
BEFORE UPDATE ON public.company_users
FOR EACH ROW
EXECUTE FUNCTION private.fn_block_company_user_immutable_fields();


-- Criar a função trigger para bloquear alterações no contato de fornecedor
CREATE OR REPLACE FUNCTION private.fn_block_supplier_contact_immutable_fields()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.id IS DISTINCT FROM OLD.id THEN
    RAISE EXCEPTION 'Alteração de ID do contato de fornecedor não é permitida.';
  END IF;

  IF NEW.supplier_id IS DISTINCT FROM OLD.supplier_id THEN
    RAISE EXCEPTION 'Alteração do supplier_id não é permitida.';
  END IF;

  IF NEW.email IS DISTINCT FROM OLD.email THEN
    RAISE EXCEPTION 'Alteração de e-mail do contato de fornecedor não é permitida.';
  END IF;

  RETURN NEW;
END;
$$;

-- Criar o trigger em supplier_contacts
CREATE TRIGGER trg_block_id_email_update_on_supplier_contacts
BEFORE UPDATE ON public.supplier_contacts
FOR EACH ROW
EXECUTE FUNCTION private.fn_block_supplier_contact_immutable_fields();


-- Criar a função trigger para verificar o papel do usuário cliente
CREATE OR REPLACE FUNCTION private.fn_check_company_user_role()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE id = NEW.role_id AND name IN ('admin', 'comprador')
  ) THEN
    RAISE EXCEPTION 'Invalid role_id: only roles "admin" and "comprador" are allowed for company_users';
  END IF;
  RETURN NEW;
END;
$$;

-- Criar o trigger para verificar o papel do usuário cliente
CREATE TRIGGER trg_check_company_user_role
BEFORE INSERT OR UPDATE ON public.company_users
FOR EACH ROW
EXECUTE FUNCTION private.fn_check_company_user_role();


-- Criar a função trigger para verificar o papel do usuário fornecedor
CREATE OR REPLACE FUNCTION private.fn_check_supplier_user_role()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE id = NEW.role_id AND name = 'fornecedor'
  ) THEN
    RAISE EXCEPTION 'Invalid role_id: only role "fornecedor" is allowed for supplier_users';
  END IF;
  RETURN NEW;
END;
$$;

-- Criar o trigger em supplier_users
CREATE TRIGGER trg_check_supplier_user_role
BEFORE INSERT OR UPDATE ON public.supplier_users
FOR EACH ROW
EXECUTE FUNCTION private.fn_check_supplier_user_role();


-- Função de trigger para bloquear updates em campos protegidos em order_items
CREATE OR REPLACE FUNCTION private.fn_validate_supplier_update_order_item()
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_user_id UUID := (SELECT auth.uid());
  request_source TEXT;
  supplier_contact_id BIGINT;
  client_user_id UUID;
  is_supplier BOOLEAN := FALSE;
BEGIN
  -- Define 'client' como padrão caso request.source não tenha sido definido
  request_source := COALESCE(current_setting('request.source', true), 'client');

  -- Se for uma requisição do fornecedor, tenta buscar o ID
  BEGIN
    IF request_source = 'supplier' THEN
      supplier_contact_id := current_setting('request.supplier_contact_id', true)::BIGINT;
    END IF;
  EXCEPTION WHEN others THEN
    supplier_contact_id := NULL;
  END;

  -- Tenta buscar o user_id do request.user_id primeiro, senão usa auth.uid()
  BEGIN
    client_user_id := current_setting('request.user_id', true)::UUID;
  EXCEPTION WHEN others THEN
    client_user_id := v_user_id;
  END;

  -- Se não conseguiu obter user_id, tenta usar auth.uid() diretamente
  -- Se ainda assim for NULL, assume que não é fornecedor e permite (RLS vai validar)
  IF client_user_id IS NULL THEN
    client_user_id := v_user_id;
  END IF;

  -- Força consistência nos campos gerados
  NEW.total_price := OLD.total_price;
  NEW.deliver_time := OLD.deliver_time;

  -- Verifica se é fornecedor apenas se tiver user_id válido
  -- Se não tiver user_id, assume que não é fornecedor e permite (as políticas RLS validarão)
  IF client_user_id IS NOT NULL THEN
    SELECT EXISTS (
      SELECT 1 FROM private.user_access_cache uac
      WHERE uac.user_id = client_user_id 
        AND uac.role_name = 'fornecedor' 
        AND uac.is_active = true
    ) INTO is_supplier;
  END IF;

  -- Se for fornecedor, aplica restrições
  IF is_supplier THEN
    IF (
      NEW.product IS NOT DISTINCT FROM OLD.product AND
      NEW.quantity IS NOT DISTINCT FROM OLD.quantity AND
      NEW.unit_price IS NOT DISTINCT FROM OLD.unit_price AND
      NEW.product_description IS NOT DISTINCT FROM OLD.product_description AND
      NEW.unity_of_measure IS NOT DISTINCT FROM OLD.unity_of_measure AND
      NEW.plant IS NOT DISTINCT FROM OLD.plant AND
      NEW.due_date IS NOT DISTINCT FROM OLD.due_date AND
      NEW.item_number IS NOT DISTINCT FROM OLD.item_number AND
      NEW.order_id IS NOT DISTINCT FROM OLD.order_id AND
      NEW.created_at IS NOT DISTINCT FROM OLD.created_at
    ) THEN
      RETURN NEW;
    ELSE
      RAISE EXCEPTION 'Fornecedores só podem alterar os campos current_delivery_date e status_id.';
    END IF;
  END IF;

  -- Para não-fornecedores (admin/comprador) ou quando não consegue identificar o usuário,
  -- permite todas as alterações - as políticas RLS vão validar as permissões
  RETURN NEW;
END;
$$;


-- Criar o trigger em order_items
CREATE TRIGGER trg_restrict_supplier_update_order_items
BEFORE UPDATE ON public.order_items
FOR EACH ROW
EXECUTE FUNCTION private.fn_validate_supplier_update_order_item();

-- Função de trigger para bloquear updates em campos protegidos em order_item_invoices
CREATE OR REPLACE FUNCTION private.fn_validate_supplier_update_order_item_invoices()
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.order_item_id IS DISTINCT FROM OLD.order_item_id
    OR NEW.created_by IS DISTINCT FROM OLD.created_by
    OR NEW.created_at IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'Atualização de campos não permitida em faturas.';
  END IF;
  RETURN NEW;
END;
$$;

-- Criar o trigger em order_item_invoices
CREATE TRIGGER trg_restrict_supplier_update_order_item_invoices
BEFORE UPDATE ON public.order_item_invoices
FOR EACH ROW
EXECUTE FUNCTION private.fn_validate_supplier_update_order_item_invoices();


-- Cria a função trigger para atualizar status do item quando status da order é alterado 
CREATE OR REPLACE FUNCTION private.fn_sync_order_items_status()
RETURNS TRIGGER
SECURITY DEFINER
SET search_path TO 'public', 'private'
LANGUAGE plpgsql
AS $$
BEGIN
    -- Verificar se o status_id foi realmente alterado
    IF OLD.status_id IS DISTINCT FROM NEW.status_id THEN
        
        -- Atualizar o status_id de todos os order_items relacionados
        -- EXCETO aqueles que já possuem status FINAL
        UPDATE public.order_items 
        SET status_id = (
            SELECT ois.id 
            FROM public.order_item_status ois 
            WHERE ois.default_status_id = NEW.status_id
            AND ois.company_id = NEW.company_id
            LIMIT 1
        )
        WHERE order_id = NEW.id
        AND EXISTS (
            SELECT 1 
            FROM public.order_item_status ois 
            WHERE ois.default_status_id = NEW.status_id
            AND ois.company_id = NEW.company_id
        )
        AND NOT EXISTS (
          SELECT 1
          FROM public.order_item_status current_ois
          WHERE current_ois.id = order_items.status_id
          AND current_ois.is_final = TRUE
        );
        
    END IF;
    
    RETURN NEW;
END;
$$;

-- Criar o trigger que acionar a função para atualizar o status do item
CREATE OR REPLACE TRIGGER trigger_sync_order_items_status
    AFTER UPDATE ON public.orders
    FOR EACH ROW
    EXECUTE FUNCTION private.fn_sync_order_items_status();


-- ╭───────────────────◉ CONTEXTO: Notificações ◉──────────────────────╮
-- ┃                     Triggers de notificações                       ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Criar a função trigger para notificar mudanças no status do pedido
CREATE OR REPLACE FUNCTION private.fn_notify_order_status_change()
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_new_status_name TEXT;
  v_request_source TEXT;
BEGIN
  BEGIN
    v_request_source := current_setting('request.source', true);
  EXCEPTION WHEN OTHERS THEN
    v_request_source := NULL;
  END;

  -- Só executa se for fornecedor
  IF v_request_source IS DISTINCT FROM 'supplier' THEN
    RETURN NEW;
  END IF;

  IF NEW.status_id IS DISTINCT FROM OLD.status_id AND NEW.status_id IS NOT NULL THEN
    -- Buscar o nome do novo status
    SELECT name INTO v_new_status_name
    FROM public.default_order_status
    WHERE id = NEW.status_id;

    -- Só registra notificação se o status não for "Concluído"
    IF v_new_status_name IS DISTINCT FROM 'Concluído' THEN
      INSERT INTO public.order_notifications(order_id, type, message)
      VALUES (
        NEW.id,
        'order_status_change',
        format('O status do pedido %s foi alterado para "%s".', NEW.order_number, v_new_status_name)
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- Criar o trigger em orders
CREATE TRIGGER trg_notify_order_status_change
AFTER UPDATE ON public.orders
FOR EACH ROW
EXECUTE FUNCTION private.fn_notify_order_status_change();


-- Criar a função trigger para notificar mudanças na data de entrega
CREATE OR REPLACE FUNCTION private.fn_notify_delivery_date_change() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_order_number BIGINT;
  v_request_source TEXT;
BEGIN
  BEGIN
    v_request_source := current_setting('request.source', true);
  EXCEPTION WHEN OTHERS THEN
    v_request_source := NULL;
  END;

  -- Só executa se for fornecedor
  IF v_request_source IS DISTINCT FROM 'supplier' THEN
    RETURN NEW;
  END IF;

  IF NEW.current_delivery_date IS DISTINCT FROM OLD.current_delivery_date 
    AND NEW.current_delivery_date IS NOT NULL THEN

    -- Buscar o número do pedido
    SELECT order_number INTO v_order_number
    FROM public.orders
    WHERE id = NEW.order_id;

    INSERT INTO public.order_notifications(order_id, order_item_id, type, message)
    VALUES (
      NEW.order_id,
      NEW.id,
      'delivery_date_change',
      format('A data de entrega do item %s, pedido %s, foi alterada para %s', NEW.item_number, v_order_number, TO_CHAR(NEW.current_delivery_date, 'DD/MM/YYYY'))
    );
  END IF;
  RETURN NEW;
END;
$$;

-- Criar o trigger em order_items
CREATE TRIGGER trg_notify_delivery_date_change
AFTER UPDATE ON public.order_items
FOR EACH ROW
EXECUTE FUNCTION private.fn_notify_delivery_date_change();


-- Criar a função trigger para notificar mudanças no status do item
CREATE OR REPLACE FUNCTION private.fn_notify_item_status_change() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_new_status_name TEXT;
  v_order_number BIGINT;
  v_request_source TEXT;
BEGIN
  BEGIN
    v_request_source := current_setting('request.source', true);
  EXCEPTION WHEN OTHERS THEN
    v_request_source := NULL;
  END;

  -- Só executa se for fornecedor
  IF v_request_source IS DISTINCT FROM 'supplier' THEN
    RETURN NEW;
  END IF;

  IF NEW.status_id IS DISTINCT FROM OLD.status_id AND NEW.status_id IS NOT NULL THEN

    -- Buscar o nome do novo status
    SELECT name INTO v_new_status_name
    FROM public.order_item_status
    WHERE id = NEW.status_id;

    -- Buscar o número do pedido
    SELECT order_number INTO v_order_number
    FROM public.orders
    WHERE id = NEW.order_id;

    INSERT INTO public.order_notifications(order_id, order_item_id, type, message)
    VALUES (
      NEW.order_id,
      NEW.id,
      'item_status_change',
      format('O status do item %s, pedido %s, foi alterado para "%s".', NEW.item_number, v_order_number, v_new_status_name)
    );
  END IF;
  RETURN NEW;
END;
$$;

-- Criar o trigger em order_items
CREATE TRIGGER trg_notify_item_status_change
AFTER UPDATE ON public.order_items
FOR EACH ROW
EXECUTE FUNCTION private.fn_notify_item_status_change();


-- Criar a função trigger para notificar quando um item é faturado
CREATE OR REPLACE FUNCTION private.fn_notify_item_invoiced()
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_order_id BIGINT;
  v_item_number BIGINT;
  v_order_number BIGINT;
  v_request_source TEXT;
BEGIN
  BEGIN
    v_request_source := current_setting('request.source', true);
  EXCEPTION WHEN OTHERS THEN
    v_request_source := NULL;
  END;

  -- Só executa se for fornecedor
  IF v_request_source IS DISTINCT FROM 'supplier' THEN
    RETURN NEW;
  END IF;
  
  SELECT oi.order_id, oi.item_number, o.order_number
  INTO v_order_id, v_item_number, v_order_number
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  WHERE oi.id = NEW.order_item_id;

  INSERT INTO public.order_notifications(order_id, order_item_id, type, message)
  VALUES (
    v_order_id,
    NEW.order_item_id,
    'item_invoiced',
    format('Item %s, pedido %s, foi faturado na nota fiscal %s.', v_item_number, v_order_number, NEW.nfe_number)
  );

  RETURN NEW;
END;
$$;

-- Criar o trigger em order_item_invoices
CREATE TRIGGER trg_notify_item_invoiced
AFTER INSERT ON public.order_item_invoices
FOR EACH ROW
EXECUTE FUNCTION private.fn_notify_item_invoiced();

-- Criar a função trigger para notificar inserção de observações do fornecedor
CREATE OR REPLACE FUNCTION private.fn_notify_supplier_observations_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
    v_request_source TEXT;
    v_supplier_contact_id TEXT;
    v_user_id TEXT;
    v_order_number TEXT;
    v_supplier_name TEXT;
BEGIN
    BEGIN
        v_request_source := current_setting('request.source', true);
        v_supplier_contact_id := current_setting('request.supplier_contact_id', true);
        v_user_id := current_setting('request.user_id', true);
    EXCEPTION WHEN OTHERS THEN
        v_request_source := NULL;
        v_supplier_contact_id := NULL;
        v_user_id := NULL;
    END;

    -- Só executa se for fornecedor inserindo observações
    IF v_request_source IS DISTINCT FROM 'supplier' OR NEW.supplier_observations IS NULL THEN
        RETURN NEW;
    END IF;

    -- Buscar informações do pedido e fornecedor para a notificação
    SELECT o.order_number, s.name
    INTO v_order_number, v_supplier_name
    FROM public.orders o
    LEFT JOIN public.suppliers s ON s.id = (
        SELECT sc.supplier_id
        FROM public.supplier_contacts sc
        WHERE sc.id = v_supplier_contact_id::BIGINT
    )
    WHERE o.id = NEW.order_id;

    -- Inserir notificação
    INSERT INTO public.order_notifications(order_id, type, message)
    VALUES (
        NEW.order_id,
        'order_status_change',
        format('Nova observação do fornecedor %s foi adicionada ao pedido %s.', 
              COALESCE(v_supplier_name, 'Desconhecido'), 
              COALESCE(v_order_number, NEW.order_id::TEXT))
    );

    RETURN NEW;
END;
$$;

-- Criar o trigger na tabela order_and_item_observations
CREATE TRIGGER trg_notify_supplier_observations_insert
AFTER INSERT ON public.order_and_item_observations
FOR EACH ROW
EXECUTE FUNCTION private.fn_notify_supplier_observations_insert();

-- Criar a função trigger para notificar observações do comprador
CREATE OR REPLACE FUNCTION private.fn_notify_client_observations_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
    v_request_source TEXT;
    v_user_id TEXT;
    v_order_number TEXT;
    v_item_number BIGINT;
    v_company_name TEXT;
BEGIN
    BEGIN
        v_request_source := current_setting('request.source', true);
        v_user_id := current_setting('request.user_id', true);
    EXCEPTION WHEN OTHERS THEN
        v_request_source := NULL;
        v_user_id := NULL;
    END;

    -- Só executa se for comprador inserindo observações
    IF v_request_source IS DISTINCT FROM 'client' OR NEW.user_observations IS NULL THEN
        RETURN NEW;
    END IF;

    -- Buscar informações do pedido e empresa para a notificação
    SELECT o.order_number, c.name
    INTO v_order_number, v_company_name
    FROM public.orders o
    JOIN public.companies c ON c.id = o.company_id
    WHERE o.id = NEW.order_id;

    -- Se for observação de item específico, buscar número do item
    IF NEW.order_item_id IS NOT NULL THEN
        SELECT item_number INTO v_item_number
        FROM public.order_items
        WHERE id = NEW.order_item_id;
    END IF;

    -- Inserir notificação
    INSERT INTO public.order_notifications(order_id, order_item_id, type, message)
    VALUES (
        NEW.order_id,
        NEW.order_item_id,
        'client_observation',
        CASE 
            WHEN v_item_number IS NOT NULL THEN
                format('Nova observação do comprador %s foi adicionada ao item %s, pedido %s.', 
                      COALESCE(v_company_name, 'Desconhecido'), 
                      v_item_number,
                      COALESCE(v_order_number, NEW.order_id::TEXT))
            ELSE
                format('Nova observação do comprador %s foi adicionada ao pedido %s.', 
                      COALESCE(v_company_name, 'Desconhecido'), 
                      COALESCE(v_order_number, NEW.order_id::TEXT))
        END
    );

    RETURN NEW;
END;
$$;

-- Criar o trigger para observações do comprador
CREATE TRIGGER trg_notify_client_observations_insert
AFTER INSERT ON public.order_and_item_observations
FOR EACH ROW
EXECUTE FUNCTION private.fn_notify_client_observations_insert();

-- Criar a função trigger para notificar mudanças de status do pedido pelo comprador
CREATE OR REPLACE FUNCTION private.fn_notify_client_order_status_change()
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_new_status_name TEXT;
  v_request_source TEXT;
  v_company_name TEXT;
BEGIN
  BEGIN
    v_request_source := current_setting('request.source', true);
  EXCEPTION WHEN OTHERS THEN
    v_request_source := NULL;
  END;

  -- Só executa se for comprador
  IF v_request_source IS DISTINCT FROM 'client' THEN
    RETURN NEW;
  END IF;

  IF NEW.status_id IS DISTINCT FROM OLD.status_id AND NEW.status_id IS NOT NULL THEN
    -- Buscar o nome do novo status
    SELECT name INTO v_new_status_name
    FROM public.default_order_status
    WHERE id = NEW.status_id;

    -- Buscar nome da empresa
    SELECT c.name INTO v_company_name
    FROM public.companies c
    JOIN public.orders o ON o.company_id = c.id
    WHERE o.id = NEW.id;

    -- Só registra notificação se o status não for "Concluído"
    IF v_new_status_name IS DISTINCT FROM 'Concluído' THEN
      INSERT INTO public.order_notifications(order_id, type, message)
      VALUES (
        NEW.id,
        'client_status_change',
        format('O status do pedido %s foi alterado para "%s" pelo comprador %s.', 
               NEW.order_number, 
               v_new_status_name,
               COALESCE(v_company_name, 'Desconhecido'))
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

-- Criar o trigger em orders para mudanças do comprador
CREATE TRIGGER trg_notify_client_order_status_change
AFTER UPDATE ON public.orders
FOR EACH ROW
EXECUTE FUNCTION private.fn_notify_client_order_status_change();

-- Criar a função trigger para notificar mudanças em itens pelo comprador
CREATE OR REPLACE FUNCTION private.fn_notify_client_item_change() 
RETURNS TRIGGER 
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_order_number BIGINT;
  v_request_source TEXT;
  v_company_name TEXT;
  v_status_name TEXT;
  v_changes TEXT[] := '{}';
BEGIN
  BEGIN
    v_request_source := current_setting('request.source', true);
  EXCEPTION WHEN OTHERS THEN
    v_request_source := NULL;
  END;

  -- Só executa se for comprador
  IF v_request_source IS DISTINCT FROM 'client' THEN
    RETURN NEW;
  END IF;

  -- Buscar o número do pedido
  SELECT order_number INTO v_order_number
  FROM public.orders
  WHERE id = NEW.order_id;

  -- Buscar nome da empresa
  SELECT c.name INTO v_company_name
  FROM public.companies c
  JOIN public.orders o ON o.company_id = c.id
  WHERE o.id = NEW.order_id;

  -- Verificar mudanças e construir mensagem
  IF NEW.status_id IS DISTINCT FROM OLD.status_id AND NEW.status_id IS NOT NULL THEN
    SELECT name INTO v_status_name
    FROM public.order_item_status
    WHERE id = NEW.status_id;
    
    v_changes := array_append(v_changes, format('status alterado para "%s"', v_status_name));
  END IF;

  IF NEW.due_date IS DISTINCT FROM OLD.due_date THEN
    v_changes := array_append(v_changes, format('data de vencimento alterada para %s', TO_CHAR(NEW.due_date, 'DD/MM/YYYY')));
  END IF;

  IF NEW.current_delivery_date IS DISTINCT FROM OLD.current_delivery_date THEN
    v_changes := array_append(v_changes, format('data de entrega alterada para %s', TO_CHAR(NEW.current_delivery_date, 'DD/MM/YYYY')));
  END IF;

  -- Inserir notificação se houve mudanças
  IF array_length(v_changes, 1) > 0 THEN
    INSERT INTO public.order_notifications(order_id, order_item_id, type, message)
    VALUES (
      NEW.order_id,
      NEW.id,
      'client_item_change',
      format('O item %s, pedido %s, teve %s pelo comprador %s.', 
             NEW.item_number, 
             v_order_number, 
             array_to_string(v_changes, ', '),
             COALESCE(v_company_name, 'Desconhecido'))
    );
  END IF;

  RETURN NEW;
END;
$$;

-- Criar o trigger em order_items para mudanças do comprador
CREATE TRIGGER trg_notify_client_item_change
AFTER UPDATE ON public.order_items
FOR EACH ROW
EXECUTE FUNCTION private.fn_notify_client_item_change();