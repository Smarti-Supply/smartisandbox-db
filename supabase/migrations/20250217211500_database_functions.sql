-- ╭────────────────────────────────────────────────────────────────────╮
-- ┃                            Funções                                 ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Função wrapper da função de log de eventos de processos para utilização em py (não declara schema)
CREATE OR REPLACE FUNCTION public.fn_log_process_event(
  p_process_name TEXT,
  p_function_name TEXT,
  p_step TEXT,
  p_status TEXT,
  p_message TEXT,
  p_user_id UUID,
  p_metadata JSONB,
  token TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public', 'vault'
AS $$
DECLARE
  expected_token TEXT;
BEGIN
  -- Obter o segredo do Vault
  SELECT decrypted_secret INTO expected_token
  FROM vault.decrypted_secrets
  WHERE name = 'AWS_TOKEN';

  IF token IS DISTINCT FROM expected_token THEN
    RAISE EXCEPTION 'Acesso não autorizado à função.';
  END IF;

  PERFORM private.fn_log_process_event(
    p_process_name,
    p_function_name,
    p_step,
    p_status,
    p_message,
    p_user_id,
    p_metadata
  );
END;
$$;

-- Função para processar os logs de processos
CREATE OR REPLACE FUNCTION private.fn_log_process_event(
  p_process_name TEXT,
  p_function_name TEXT,
  p_step TEXT,
  p_status TEXT,
  p_message TEXT,
  p_user_id UUID,
  p_metadata JSONB DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'private', 'public'
AS $$
BEGIN
  INSERT INTO private.process_logs (
    process_name,
    function_name,
    step,
    status,
    message,
    user_id,
    metadata,
    created_at
  )
  VALUES (
    p_process_name,
    p_function_name,
    p_step,
    p_status,
    p_message,
    p_user_id,
    p_metadata,
    now()
  );
END;
$$;


-- Função para restaurar o campo de mapeamento padrão
CREATE OR REPLACE FUNCTION public.fn_reset_field_mapping_by_type(p_type TEXT)
RETURNS VOID
SECURITY INVOKER
SET search_path TO 'public'
AS $$
BEGIN
  -- Atualiza o mapeamento
  UPDATE public.import_field_mappings
  SET 
    field_mapping = default_field_mapping,
    updated_at = now()
  WHERE
    type = p_type;
END;
$$ LANGUAGE plpgsql;


-- ╭────────────────────◉ CONTEXTO: Usuários ◉─────────────────────────╮
-- ┃                 Funções de gestão de usuários                      ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Função para criar novos usuários
CREATE OR REPLACE FUNCTION public.fn_create_new_user(
  user_email TEXT,
  user_name TEXT,
  role TEXT,
  user_password TEXT,
  supplier_letter TEXT, -- Custom field for Transpetro
  supplier_id BIGINT -- Custom field for Transpetro
)
RETURNS VOID
SECURITY DEFINER
SET search_path TO 'public', 'vault', 'private'
LANGUAGE plpgsql
AS $$
DECLARE
  endpoint TEXT := 'create-new-user';
  edge_token TEXT;
  service_role_key TEXT;
  supabase_url TEXT;
  v_user_id UUID;
  v_company_id BIGINT;
  v_is_active BOOLEAN;
  v_role_name TEXT;
  v_supplier_letter TEXT; -- Custom field for Transpetro
  payload JSONB;
  v_response JSONB;
  v_uid UUID := (select auth.uid());
BEGIN
  SELECT decrypted_secret INTO edge_token
  FROM vault.decrypted_secrets
  WHERE name = 'INTERNAL_EDGE_TOKEN';

  SELECT decrypted_secret INTO service_role_key
  FROM vault.decrypted_secrets
  WHERE name = 'SUPABASE_SERVICE_ROLE_KEY';

  SELECT decrypted_secret INTO supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'SUPABASE_URL';

  IF user_email IS NULL OR user_name IS NULL OR role IS NULL OR user_password IS NULL THEN
    RAISE EXCEPTION 'Todos os campos são obrigatórios.';
  END IF;

  IF role NOT IN ('admin', 'comprador') THEN
    RAISE EXCEPTION 'Role inválida: %', role;
  END IF;
  
  SELECT uac.user_id, uac.company_id, uac.is_active, uac.role_name
  INTO v_user_id, v_company_id, v_is_active, v_role_name
  FROM private.user_access_cache uac
  WHERE uac.user_id = v_uid
    AND uac.is_active = true
  LIMIT 1;

  IF NOT (v_is_active AND v_role_name = 'admin') THEN
    RAISE EXCEPTION 'Apenas administradores ativos podem criar novos usuários.';
  END IF;

  payload := jsonb_build_object(
      'company_id', v_company_id,
      'user_email', user_email,
      'user_name',  user_name,
      'role_name',  role,
      'user_password', user_password,
      'created_by', v_user_id,
      'supplier_letter', COALESCE(supplier_letter, ''), -- Custom field for Transpetro
      'user_supplier_id', supplier_id -- Custom field for Transpetro
  );

  SELECT net.http_post(
      url     := supabase_url || '/functions/v1/' || endpoint,
      headers := jsonb_build_object(
        'Content-Type',  'application/json',
        'Authorization', 'Bearer ' || service_role_key,
        'edge-token',    edge_token
      ),
      body := payload
    ) INTO v_response;

  -- Verificar se houve erro na chamada
  IF (v_response ->> 'status')::INT >= 400 THEN
    PERFORM private.fn_log_process_event(
      p_process_name  := 'create_new_user',
      p_function_name := 'fn_create_new_user',
      p_step          := 'edge_call',
      p_status        := 'error',
      p_message       := 'Falha ao chamar edge function.',
      p_user_id       := v_user_id,
      p_metadata      := jsonb_build_object(
                            'status', v_response ->> 'status',
                            'body',   v_response ->> 'body'
                          )
    );
    RAISE EXCEPTION 'Erro ao chamar edge function: %', v_response ->> 'body';
  END IF;

  -- Sucesso na criação do usuário
  PERFORM private.fn_log_process_event(
    p_process_name  := 'create_new_user',
    p_function_name := 'fn_create_new_user',
    p_step          := 'create_new_user',
    p_status        := 'success',
    p_message       := format('Usuário criado com sucesso para o e-mail %s.', user_email),
    p_user_id       := v_user_id,
    p_metadata      := jsonb_build_object(
                          'email', user_email,
                          'role',  role,
                          'nome',  user_name
                        )
  );
END;
$$;

-- Função para atualizar senha de usuário
CREATE OR REPLACE FUNCTION public.fn_update_user_password(
  user_id UUID,
  new_password TEXT
)
RETURNS VOID
SECURITY DEFINER
SET search_path TO 'public', 'vault', 'private', 'auth'
LANGUAGE plpgsql
AS $$
DECLARE
  endpoint TEXT := 'update-user-password';
  edge_token TEXT;
  service_role_key TEXT;
  supabase_url TEXT;
  v_user_id UUID;
  v_company_id BIGINT;
  v_is_active BOOLEAN;
  v_role_name TEXT;
  payload JSONB;
  v_response JSONB;
  v_uid UUID := (select auth.uid());
BEGIN
  SELECT decrypted_secret INTO edge_token
  FROM vault.decrypted_secrets
  WHERE name = 'INTERNAL_EDGE_TOKEN';

  SELECT decrypted_secret INTO service_role_key
  FROM vault.decrypted_secrets
  WHERE name = 'SUPABASE_SERVICE_ROLE_KEY';

  SELECT decrypted_secret INTO supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'SUPABASE_URL';

  IF user_id IS NULL OR new_password IS NULL THEN
    RAISE EXCEPTION 'ID do usuário e nova senha são obrigatórios.';
  END IF;
  
  SELECT uac.user_id, uac.company_id, uac.is_active, uac.role_name
  INTO v_user_id, v_company_id, v_is_active, v_role_name
  FROM private.user_access_cache uac
  WHERE uac.user_id = v_uid
    AND uac.is_active = true
  LIMIT 1;

  IF NOT (v_is_active AND v_role_name = 'admin') THEN
    RAISE EXCEPTION 'Apenas administradores ativos podem atualizar senhas de usuários.';
  END IF;

  payload := jsonb_build_object(
      'user_id', user_id,
      'new_password', new_password
  );

  SELECT net.http_post(
      url     := supabase_url || '/functions/v1/' || endpoint,
      headers := jsonb_build_object(
        'Content-Type',  'application/json',
        'Authorization', 'Bearer ' || service_role_key,
        'edge-token',    edge_token
      ),
      body := payload
    ) INTO v_response;

  -- Verificar se houve erro na chamada
  IF (v_response ->> 'status')::INT >= 400 THEN
    PERFORM private.fn_log_process_event(
      p_process_name  := 'update_user_password',
      p_function_name := 'fn_update_user_password',
      p_step          := 'edge_call',
      p_status        := 'error',
      p_message       := 'Falha ao chamar edge function.',
      p_user_id       := v_user_id,
      p_metadata      := jsonb_build_object(
                            'status', v_response ->> 'status',
                            'body',   v_response ->> 'body'
                          )
    );
    RAISE EXCEPTION 'Erro ao chamar edge function: %', v_response ->> 'body';
  END IF;

  -- Sucesso na atualização da senha
  PERFORM private.fn_log_process_event(
    p_process_name  := 'update_user_password',
    p_function_name := 'fn_update_user_password',
    p_step          := 'update_user_password',
    p_status        := 'success',
    p_message       := format('Senha atualizada com sucesso para o usuário %s.', user_id),
    p_user_id       := v_user_id,
    p_metadata      := jsonb_build_object(
                          'user_id', user_id
                        )
  );
END;
$$;

-- Função para excluir usuários inativos
CREATE OR REPLACE FUNCTION private.fn_delete_inactive_auth_users()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'private'
AS $$
DECLARE
  v_deleted_signed_in INT := 0;
  v_deleted_never_signed_in INT := 0;
  v_deleted_inactive INT := 0;
  deleted_payload JSONB := '[]'::jsonb;
BEGIN
  -- 1. Deleta usuários que logaram, mas estão inativos há 30 dias, e não são admin
  WITH deleted_signed_in AS (
    DELETE FROM auth.users
    WHERE id IN (
      SELECT u.id
      FROM auth.users u
      JOIN private.user_access_cache uac ON u.id = uac.user_id
      WHERE u.last_sign_in_at IS NOT NULL
        AND u.last_sign_in_at < now() - interval '30 days'
        AND uac.role_name <> 'admin'
    )
    RETURNING id, email
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', id,
    'email', email,
    'reason', 'signed_in_30d'
  )), '[]') INTO deleted_payload
  FROM deleted_signed_in;


  GET DIAGNOSTICS v_deleted_signed_in = ROW_COUNT;

  -- 2. Deleta usuários que nunca logaram e foram criados há mais de 30 dias, e não são admin
  WITH deleted_never_signed_in AS (
    DELETE FROM auth.users
    WHERE id IN (
      SELECT u.id
      FROM auth.users u
      JOIN private.user_access_cache uac ON u.id = uac.user_id
      WHERE u.last_sign_in_at IS NULL
        AND u.created_at < now() - interval '30 days'
        AND uac.role_name <> 'admin'
    )
    RETURNING id, email
  )
  SELECT deleted_payload || COALESCE(jsonb_agg(jsonb_build_object(
    'id', id,
    'email', email,
    'reason', 'never_signed_in_30d'
  )), '[]') INTO deleted_payload
  FROM deleted_never_signed_in;

  GET DIAGNOSTICS v_deleted_never_signed_in = ROW_COUNT;

  -- 3. Deleta usuários inativos no cache, que não são admin
  WITH deleted_inactive AS (
    DELETE FROM auth.users
    WHERE id IN (
      SELECT uac.user_id
      FROM private.user_access_cache uac
      WHERE uac.is_active = false
        AND uac.last_synced_at < now() - interval '30 days'
        AND uac.role_name <> 'admin'
    )
    RETURNING id, email
  )
  SELECT deleted_payload || COALESCE(jsonb_agg(jsonb_build_object(
    'id', id,
    'email', email,
    'reason', 'inactive_cache'
  )), '[]') INTO deleted_payload
  FROM deleted_inactive;

  GET DIAGNOSTICS v_deleted_inactive = ROW_COUNT;

  -- 4. Log final
  PERFORM private.fn_log_process_event(
    p_process_name  := 'delete_inactive_auth_users',
    p_function_name := 'fn_delete_inactive_auth_users',
    p_step          := 'delete_users',
    p_status        := 'success',
    p_message       := format('%s usuários inativos removidos (signed_in: %s, never_signed_in: %s, inativos: %s).',
                             v_deleted_signed_in + v_deleted_never_signed_in + v_deleted_inactive,
                             v_deleted_signed_in, v_deleted_never_signed_in, v_deleted_inactive),
    p_user_id       := NULL,
    p_metadata      := jsonb_build_object(
        'total_deletados', v_deleted_signed_in + v_deleted_never_signed_in + v_deleted_inactive,
        'deletados_signed_in', v_deleted_signed_in,
        'deletados_never_signed_in', v_deleted_never_signed_in,
        'deletados_inativos', v_deleted_inactive,
        'usuarios', deleted_payload
      )
  );

EXCEPTION WHEN OTHERS THEN
  PERFORM private.fn_log_process_event(
    p_process_name  := 'delete_inactive_auth_users',
    p_function_name := 'fn_delete_inactive_auth_users',
    p_step          := 'delete_users',
    p_status        := 'error',
    p_message       := SQLERRM,
    p_user_id       := NULL,
    p_metadata      := jsonb_build_object(
        'stack', pg_catalog.pg_backtrace()
      )
  );
  RAISE;
END; 
$$;


-- ╭─────────────────◉ CONTEXTO: Upload de Dados ◉─────────────────────╮
-- ┃             Funções upload de pedidos e fornecedores               ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Função para inserir/atualizar pedidos
CREATE OR REPLACE FUNCTION public.fn_insert_orders(payload JSONB, token TEXT, owner_id TEXT)
RETURNS VOID
SECURITY DEFINER
SET search_path TO 'public', 'vault'
LANGUAGE plpgsql
AS $$
DECLARE
  expected_token TEXT;
  record JSONB;
  supplier_id_resolved BIGINT;
  parsed_due_date DATE;
  v_total_records INT;
  v_processed_records INT := 0;
BEGIN
  -- Obter o segredo do Vault
  SELECT decrypted_secret INTO expected_token
  FROM vault.decrypted_secrets
  WHERE name = 'AWS_TOKEN';

  IF token IS DISTINCT FROM expected_token THEN
    RAISE EXCEPTION 'Acesso não autorizado à função fn_insert_orders.';
  END IF;

  PERFORM set_config('request.user_id', owner_id::TEXT, true);

  -- Obter total de registros
  v_total_records := jsonb_array_length(payload);

  -- Verifica se o campo company_id está presente
  FOR record IN SELECT * FROM jsonb_array_elements(payload)
  LOOP
    IF NOT (record ? 'company_id') THEN
      PERFORM private.fn_log_process_event(
        p_process_name  := 'orders_upload',
        p_function_name := 'fn_insert_orders',
        p_step          := 'validate_payload',
        p_status        := 'error',
        p_message       := format('company_id obrigatório para o Pedido (external_id: %s, order_number: %s).',
                                  COALESCE(record->>'external_id', 'N/A'), 
                                  COALESCE(record->>'order_number', 'N/A')),
        p_user_id       := owner_id::uuid,
        p_metadata      := record
      );
      RAISE EXCEPTION 'Algum registro no payload está sem company_id.';
    END IF;
  END LOOP;

  FOR record IN SELECT * FROM jsonb_array_elements(payload)
  LOOP
    -- Buscar o supplier_id usando o external_id e company_id
    SELECT id INTO supplier_id_resolved
    FROM public.suppliers
    WHERE company_id = (record->>'company_id')::BIGINT
    AND external_id = record->>'external_id'
    LIMIT 1;

    IF supplier_id_resolved IS NULL THEN
        PERFORM private.fn_log_process_event(
          p_process_name  := 'orders_upload',
          p_function_name := 'fn_insert_orders',
          p_step          := 'validate_supplier',
          p_status        := 'error',
          p_message       := format('Fornecedor com external_id %s não encontrado para company_id %s.',
                                    record->>'external_id', record->>'company_id'),
          p_user_id       := owner_id::uuid,
          p_metadata      := record
          );
      CONTINUE;
    END IF;

    -- Prepara due_date com segurança
    parsed_due_date := CASE
      WHEN record ? 'due_date'
        AND record->>'due_date' IS DISTINCT FROM 'null'
        AND record->>'due_date' <> ''
      THEN (record->>'due_date')::DATE
      ELSE NULL
    END;

    INSERT INTO public.orders (
      company_id,
      supplier_id,
      order_number,
      order_description,
      due_date
    )
    VALUES (
      (record->>'company_id')::BIGINT,
      supplier_id_resolved,
      record->>'order_number',
      record->>'order_description',
      parsed_due_date
    )
    ON CONFLICT (company_id, order_number) DO UPDATE
    SET
      order_description = CASE WHEN record ? 'order_description' THEN record->>'order_description' ELSE orders.order_description END,
      due_date = CASE
        WHEN record ? 'due_date'
          AND record->>'due_date' IS DISTINCT FROM 'null'
          AND record->>'due_date' <> ''
        THEN (record->>'due_date')::DATE
        ELSE orders.due_date
      END,
      updated_at = now();
    
    v_processed_records := v_processed_records + 1;
  END LOOP;

PERFORM private.fn_log_process_event(
  p_process_name  := 'orders_upload',
  p_function_name := 'fn_insert_orders',
  p_step          := 'process_batch',
  p_status        := 'success',
  p_message       := format('Lote de %s pedidos teve %s pedidos processados com sucesso.',
                           v_total_records, v_processed_records),
  p_user_id       := owner_id::uuid,
  p_metadata      := jsonb_build_object(
                        'total_registros', v_total_records,
                        'registros_processados', v_processed_records
                      )
);
END;
$$;


-- Função para inserir/atualizar itens de pedidos
CREATE OR REPLACE FUNCTION public.fn_insert_order_items(payload JSONB, token TEXT, owner_id TEXT)
RETURNS VOID
SECURITY DEFINER
SET search_path TO 'public', 'vault'
LANGUAGE plpgsql
AS $$
DECLARE
  expected_token TEXT;
  record JSONB;
  processed_orders BIGINT[] := '{}';
  order_id_lookup BIGINT;
  company_id_lookup BIGINT;
  default_status_id BIGINT;
  v_total_records INT;
  v_processed_records INT := 0;
BEGIN
  -- Validar token via Vault
  SELECT decrypted_secret INTO expected_token
  FROM vault.decrypted_secrets
  WHERE name = 'AWS_TOKEN';

  IF token IS DISTINCT FROM expected_token THEN
    RAISE EXCEPTION 'Acesso não autorizado.';
  END IF;

  PERFORM set_config('request.user_id', owner_id::TEXT, true);

  -- Obter total de registros
  v_total_records := jsonb_array_length(payload);

  -- Verifica se o campo company_id está presente
  FOR record IN SELECT * FROM jsonb_array_elements(payload)
  LOOP
    IF NOT (record ? 'company_id') THEN
      PERFORM private.fn_log_process_event(
        p_process_name  := 'orders_upload',
        p_function_name := 'fn_insert_order_items',
        p_step          := 'validate_payload',
        p_status        := 'error',
        p_message       := format('company_id obrigatório para o Item (item_number: %s, order_number: %s).',
                                  COALESCE(record->>'item_number', 'N/A'), 
                                  COALESCE(record->>'order_number', 'N/A')),
        p_user_id       := owner_id::uuid,
        p_metadata      := record
      );
      RAISE EXCEPTION 'Algum registro no payload está sem company_id.';
    END IF;
  END LOOP;

  FOR record IN SELECT * FROM jsonb_array_elements(payload)
  LOOP
    -- Extrair company_id para usar na busca
    company_id_lookup := (record->>'company_id')::BIGINT;
    
    -- Buscar order_id via order_number
    SELECT id INTO order_id_lookup
    FROM public.orders
    WHERE company_id = company_id_lookup
    AND order_number = record->>'order_number';

    IF order_id_lookup IS NULL THEN
      PERFORM private.fn_log_process_event(
        p_process_name  := 'orders_upload',
        p_function_name := 'fn_insert_order_items',
        p_step          := 'validate_order',
        p_status        := 'error',
        p_message       := format('Pedido com order_number %s não encontrado para company_id %s.',
                                  record->>'order_number', record->>'company_id'),
        p_user_id       := owner_id::uuid,
        p_metadata      := record
      );
      CONTINUE;
    END IF;

    -- Buscar o status padrão da empresa (position = 1) para order_items importados
    SELECT id INTO default_status_id
    FROM public.order_item_status
    WHERE company_id = company_id_lookup
    AND position = 1
    ORDER BY position ASC
    LIMIT 1;

    -- Log se não encontrou status padrão para a empresa
    IF default_status_id IS NULL THEN
      PERFORM private.fn_log_process_event(
        p_process_name  := 'orders_upload',
        p_function_name := 'fn_insert_order_items',
        p_step          := 'get_default_status',
        p_status        := 'error',
        p_message       := format('Status padrão não encontrado para empresa %s (company_id: %s). Item será criado sem status_id.',
                                  COALESCE((SELECT name FROM public.companies WHERE id = company_id_lookup), 'N/A'),
                                  company_id_lookup),
        p_user_id       := owner_id::uuid,
        p_metadata      := record
      );
    END IF;

    INSERT INTO public.order_items (
      order_id,
      item_number,
      product,
      product_description,
      quantity,
      unity_of_measure,
      unit_price,
      plant,
      due_date,
      current_delivery_date,
      status_id,
      bidding_description,  -- Campo customizado para Transpetro
      custom_deliver_time,  -- Campo customizado para Transpetro
      purchase_req,         -- Campo customizado para Transpetro
      purchase_req_item     -- Campo customizado para Transpetro
    )
    VALUES (
      order_id_lookup,
      (record->>'item_number')::BIGINT,
      record->>'product',
      record->>'product_description',
      (record->>'quantity')::NUMERIC,
      record->>'unity_of_measure',
      (record->>'unit_price')::NUMERIC,
      record->>'plant',
      (record->>'due_date')::DATE,
      (record->>'current_delivery_date')::DATE,
      -- Usar status padrão da empresa (position=1) quando não especificado ou NULL
      COALESCE((record->>'status_id')::BIGINT, default_status_id),
      record->>'bidding_description',         -- Campo customizado para Transpetro
      (record->>'custom_deliver_time')::INT,  -- Campo customizado para Transpetro
      (record->>'purchase_req')::BIGINT,      -- Campo customizado para Transpetro
      (record->>'purchase_req_item')::BIGINT  -- Campo customizado para Transpetro
    )
    ON CONFLICT (order_id, item_number) DO UPDATE
    SET
      product = CASE WHEN record ? 'product' THEN record->>'product' ELSE order_items.product END,
      product_description = CASE WHEN record ? 'product_description' THEN record->>'product_description' ELSE order_items.product_description END,
      quantity = CASE WHEN record ? 'quantity' THEN (record->>'quantity')::NUMERIC ELSE order_items.quantity END,
      unity_of_measure = CASE WHEN record ? 'unity_of_measure' THEN record->>'unity_of_measure' ELSE order_items.unity_of_measure END,
      unit_price = CASE WHEN record ? 'unit_price' THEN (record->>'unit_price')::NUMERIC ELSE order_items.unit_price END,
      plant = CASE WHEN record ? 'plant' THEN record->>'plant' ELSE order_items.plant END,
      due_date = CASE WHEN record ? 'due_date' THEN (record->>'due_date')::DATE ELSE order_items.due_date END,
      -- Para atualizações, usar status do payload se fornecido, senão usar status padrão se o atual for NULL
      status_id = CASE 
        WHEN record ? 'status_id' THEN COALESCE((record->>'status_id')::BIGINT, default_status_id)
        WHEN order_items.status_id IS NULL THEN default_status_id
        ELSE order_items.status_id 
      END,
      bidding_description = CASE WHEN record ? 'bidding_description' THEN record->>'bidding_description' ELSE order_items.bidding_description END,        -- Campo customizado para Transpetro
      custom_deliver_time = CASE WHEN record ? 'custom_deliver_time' THEN (record->>'custom_deliver_time')::INT ELSE order_items.custom_deliver_time END, -- Campo customizado para Transpetro
      purchase_req = CASE WHEN record ? 'purchase_req' THEN (record->>'purchase_req')::BIGINT ELSE order_items.purchase_req END,                          -- Campo customizado para Transpetro
      purchase_req_item = CASE WHEN record ? 'purchase_req_item' THEN (record->>'purchase_req_item')::BIGINT ELSE order_items.purchase_req_item END;      -- Campo customizado para Transpetro

    -- Armazena o order_id processado
    IF NOT (processed_orders @> ARRAY[order_id_lookup]) THEN
      processed_orders := array_append(processed_orders, order_id_lookup);
    END IF;
    
    v_processed_records := v_processed_records + 1;
  END LOOP;

  -- Atualiza due_date nos pedidos que ainda não possuem valor
  UPDATE public.orders o
  SET due_date = (
    SELECT MAX(oi.due_date)
    FROM public.order_items oi
    WHERE oi.order_id = o.id
  )
  WHERE o.id = ANY(processed_orders)
    AND o.due_date IS NULL;

PERFORM private.fn_log_process_event(
  p_process_name  := 'orders_upload',
  p_function_name := 'fn_insert_order_items',
  p_step          := 'process_batch',
  p_status        := 'success',
  p_message       := format('Lote de %s itens teve %s itens processados com sucesso.',
                           v_total_records, v_processed_records),
  p_user_id       := owner_id::uuid,
  p_metadata      := jsonb_build_object(
                        'total_registros', v_total_records,
                        'registros_processados', v_processed_records,
                        'pedidos_processados', processed_orders
                      )
);
END;
$$;


-- Função para inserir/atualizar fornecedores
CREATE OR REPLACE FUNCTION public.fn_insert_suppliers(payload JSONB, token TEXT, owner_id TEXT)
RETURNS VOID
SECURITY DEFINER
SET search_path TO 'public', 'vault'
LANGUAGE plpgsql
AS $$
DECLARE
  expected_token TEXT;
  record JSONB;
  v_total_records INT;
  v_processed_records INT := 0;
BEGIN
  -- Obter o segredo do Vault
  SELECT decrypted_secret INTO expected_token
  FROM vault.decrypted_secrets
  WHERE name = 'AWS_TOKEN';

  -- Validar token
  IF token IS DISTINCT FROM expected_token THEN
    RAISE EXCEPTION 'Acesso não autorizado à função fn_insert_suppliers.';
  END IF;

  PERFORM set_config('request.user_id', owner_id::TEXT, true);

  -- Obter total de registros
  v_total_records := jsonb_array_length(payload);

  -- Verifica se o campo company_id está presente
  FOR record IN SELECT * FROM jsonb_array_elements(payload)
  LOOP
    IF NOT (record ? 'company_id') THEN
      PERFORM private.fn_log_process_event(
        p_process_name  := 'suppliers_upload',
        p_function_name := 'fn_insert_suppliers',
        p_step          := 'validate_payload',
        p_status        := 'error',
        p_message       := format('company_id obrigatório para o Fornecedor (cnpj: %s, external_id: %s).',
                                  COALESCE(record->>'cnpj', 'N/A'), 
                                  COALESCE(record->>'external_id', 'N/A')),
        p_user_id       := owner_id::uuid,
        p_metadata      := record
      );
      RAISE EXCEPTION 'Algum registro no payload está sem company_id.';
    END IF;
  END LOOP;

  -- Iterar sobre os registros do payload
  FOR record IN SELECT * FROM jsonb_array_elements(payload)
  LOOP
    BEGIN
      INSERT INTO public.suppliers (
        company_id,
        external_id,
        name,
        cnpj,
        industry,
        products_services,
        website,
        description,
        address_street,
        address_number,
        address_neighborhood,
        address_city,
        address_state,
        address_country,
        address_zipcode,
        address_complement,
        created_by
      )
      VALUES (
        (record->>'company_id')::BIGINT,
        record->>'external_id',
        record->>'name',
        record->>'cnpj',
        record->>'industry',
        record->>'products_services',
        record->>'website',
        record->>'description',
        record->>'address_street',
        record->>'address_number',
        record->>'address_neighborhood',
        record->>'address_city',
        record->>'address_state',
        record->>'address_country',
        record->>'address_zipcode',
        record->>'address_complement',
        owner_id::uuid
      )
      ON CONFLICT (company_id, external_id) DO UPDATE
      SET
        name = EXCLUDED.name,
        cnpj = EXCLUDED.cnpj,
        industry = EXCLUDED.industry,
        products_services = EXCLUDED.products_services,
        website = EXCLUDED.website,
        description = EXCLUDED.description,
        address_street = EXCLUDED.address_street,
        address_number = EXCLUDED.address_number,
        address_neighborhood = EXCLUDED.address_neighborhood,
        address_city = EXCLUDED.address_city,
        address_state = EXCLUDED.address_state,
        address_country = EXCLUDED.address_country,
        address_zipcode = EXCLUDED.address_zipcode,
        address_complement = EXCLUDED.address_complement;
    
    EXCEPTION
      WHEN unique_violation THEN
        -- Se conflito for na constraint do CNPJ, atualiza manualmente
        IF SQLERRM LIKE '%suppliers_company_id_cnpj_key%' THEN
          BEGIN
            UPDATE public.suppliers
            SET
              name = (record->>'name'),
              external_id = (record->>'external_id'),
              industry = (record->>'industry'),
              products_services = (record->>'products_services'),
              website = (record->>'website'),
              description = (record->>'description'),
              address_street = (record->>'address_street'),
              address_number = (record->>'address_number'),
              address_neighborhood = (record->>'address_neighborhood'),
              address_city = (record->>'address_city'),
              address_state = (record->>'address_state'),
              address_country = (record->>'address_country'),
              address_zipcode = (record->>'address_zipcode'),
              address_complement = (record->>'address_complement')
            WHERE company_id = (record->>'company_id')::BIGINT
              AND cnpj = (record->>'cnpj');
          EXCEPTION
            WHEN OTHERS THEN
              PERFORM private.fn_log_process_event(
                p_process_name  := 'suppliers_upload',
                p_function_name := 'fn_insert_suppliers',
                p_step          := 'update_by_cnpj',
                p_status        := 'error',
                p_message       := format('Erro no UPDATE após conflito de CNPJ: %s', SQLERRM),
                p_user_id       := owner_id::uuid,
                p_metadata      := record
              );
              CONTINUE;
          END;
        ELSE
          -- Conflito inesperado de UNIQUE
          PERFORM private.fn_log_process_event(
            p_process_name  := 'suppliers_upload',
            p_function_name := 'fn_insert_suppliers',
            p_step          := 'unique_violation',
            p_status        := 'error',
            p_message       := format('Unique violation não esperada: %s', SQLERRM),
            p_user_id       := owner_id::uuid,
            p_metadata      := record
          );
          CONTINUE;
        END IF;
      WHEN OTHERS THEN
        -- Qualquer outro erro geral
        PERFORM private.fn_log_process_event(
          p_process_name  := 'suppliers_upload',
          p_function_name := 'fn_insert_suppliers',
          p_step          := 'unexpected_error',
          p_status        := 'error',
          p_message       := format('Erro inesperado: %s', SQLERRM),
          p_user_id       := owner_id::uuid,
          p_metadata      := record
        );
        CONTINUE;
    END;
    
    -- Incrementar contador de registros processados com sucesso
    v_processed_records := v_processed_records + 1;
  END LOOP;

PERFORM private.fn_log_process_event(
  p_process_name  := 'suppliers_upload',
  p_function_name := 'fn_insert_suppliers',
  p_step          := 'process_batch',
  p_status        := 'success',
  p_message       := format('Lote de %s fornecedores teve %s fornecedores processados com sucesso.',
                           v_total_records, v_processed_records),
  p_user_id       := owner_id::uuid,
  p_metadata      := jsonb_build_object(
                        'total_registros', v_total_records,
                        'registros_processados', v_processed_records
                      )
);
END;
$$;


-- Função para inserir/atualizar contatos de fornecedores
CREATE OR REPLACE FUNCTION public.fn_insert_supplier_contacts(payload JSONB, token TEXT, owner_id TEXT)
RETURNS VOID
SECURITY DEFINER
SET search_path TO 'public', 'vault'
LANGUAGE plpgsql
AS $$
DECLARE
  expected_token TEXT;
  record JSONB;
  supplier_id_resolved BIGINT;
  v_total_records INT;
  v_processed_records INT := 0;
BEGIN
  -- Obter o segredo do Vault
  SELECT decrypted_secret INTO expected_token
  FROM vault.decrypted_secrets
  WHERE name = 'AWS_TOKEN';

  -- Validar token
  IF token IS DISTINCT FROM expected_token THEN
    RAISE EXCEPTION 'Acesso não autorizado à função fn_insert_supplier_contacts.';
  END IF;

  PERFORM set_config('request.user_id', owner_id::TEXT, true);

  -- Obter total de registros
  v_total_records := jsonb_array_length(payload);

  -- Verifica se o campo company_id está presente
  FOR record IN SELECT * FROM jsonb_array_elements(payload)
  LOOP
    IF NOT (record ? 'company_id') THEN
      PERFORM private.fn_log_process_event(
        p_process_name  := 'suppliers_upload',
        p_function_name := 'fn_insert_supplier_contacts',
        p_step          := 'validate_payload',
        p_status        := 'error',
        p_message       := format('company_id obrigatório para o Contato (email: %s, external_id: %s).',
                                  COALESCE(record->>'email', 'N/A'), 
                                  COALESCE(record->>'external_id', 'N/A')),
        p_user_id       := owner_id::uuid,
        p_metadata      := record
      );
      RAISE EXCEPTION 'Algum registro no payload está sem company_id.';
    END IF;
  END LOOP;

  -- Iterar sobre os registros do payload
  FOR record IN SELECT * FROM jsonb_array_elements(payload)
  LOOP
    -- Resolver supplier_id usando company_id + external_id
    SELECT id INTO supplier_id_resolved
    FROM public.suppliers
    WHERE company_id = (record->>'company_id')::BIGINT
    AND external_id = record->>'external_id';

    IF supplier_id_resolved IS NULL THEN
        PERFORM private.fn_log_process_event(
          p_process_name  := 'suppliers_upload',
          p_function_name := 'fn_insert_supplier_contacts',
          p_step          := 'resolver_supplier_id',
          p_status        := 'error',
          p_message       := format('Fornecedor com external_id %s não encontrado para company_id %s.', record->>'external_id', record->>'company_id'),
          p_user_id      := owner_id::uuid,
          p_metadata     := record
        );
      CONTINUE;
    END IF;

    -- Inserir ou atualizar contato
    INSERT INTO public.supplier_contacts (
      supplier_id,
      name,
      email,
      phone,
      created_by
    )
    VALUES (
      supplier_id_resolved,
      record->>'name',
      record->>'email',
      record->>'phone',
      owner_id::uuid
    )
    ON CONFLICT (supplier_id, email) DO UPDATE
    SET
      name = EXCLUDED.name,
      phone = EXCLUDED.phone;
    
    v_processed_records := v_processed_records + 1;
  END LOOP;

PERFORM private.fn_log_process_event(
  p_process_name  := 'suppliers_upload',
  p_function_name := 'fn_insert_supplier_contacts',
  p_step          := 'process_batch',
  p_status        := 'success',
  p_message       := format('Lote de %s contatos teve %s contatos processados com sucesso.',
                           v_total_records, v_processed_records),
  p_user_id       := owner_id::uuid,
  p_metadata      := jsonb_build_object(
                        'total_registros', v_total_records,
                        'registros_processados', v_processed_records
                      )
);
END;
$$;


-- ╭───────────────────◉ CONTEXTO: Atualização ◉───────────────────────╮
-- ┃               Funções de atualização de pedidos                    ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Função para atualizar o status de pedidos
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
    v_supplier_id BIGINT;
    v_supplier_contact_id BIGINT;
BEGIN
    -- Captura company_id da sessão
    SELECT uac.company_id, uac.role_name, uac.supplier_id
    INTO v_company_id, v_role_name, v_supplier_id
    FROM private.user_access_cache uac
    WHERE uac.user_id = v_uid
      AND uac.is_active = true
    LIMIT 1;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Usuário % não encontrado ou sem acesso.', v_uid;
    END IF;

    IF v_role_name IN ('admin', 'comprador') AND p_status_id = 6 THEN
        PERFORM set_config('request.source', 'client', true);
        PERFORM set_config('request.user_id', v_uid::TEXT, true);

    ELSIF v_role_name = 'fornecedor' AND p_status_id IN (2, 3, 4) THEN

        SELECT sc.id
        INTO v_supplier_contact_id
        FROM public.supplier_contacts sc
        JOIN public.supplier_users su ON su.supplier_contact_id = sc.id
        WHERE su.id = v_uid
          AND sc.is_active = true
        LIMIT 1;

        PERFORM set_config('request.source', 'supplier', true);
        PERFORM set_config('request.supplier_contact_id', v_supplier_contact_id::TEXT, true);
        PERFORM set_config('request.user_id', v_uid::TEXT, true);

    ELSE
        RAISE EXCEPTION 'Acesso negado: usuário % não possui permissão para atualizar pedidos.', v_uid;
    END IF;

    -- Atualiza o status do pedido
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


-- Função para atualizar campos de itens de pedidos
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
    v_supplier_id BIGINT;
    v_supplier_contact_id BIGINT;
    v_status_name TEXT;
BEGIN
    IF p_status_id IS NULL AND p_current_delivery_date IS NULL THEN
        RAISE EXCEPTION 'Pelo menos um dos parâmetros p_status_id ou p_current_delivery_date deve ser fornecido.';
    END IF;

    -- Captura sessão do usuário
    SELECT uac.company_id, uac.role_name, uac.supplier_id
    INTO v_company_id, v_role_name, v_supplier_id
    FROM private.user_access_cache uac
    WHERE uac.user_id = v_uid
      AND uac.is_active = true
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Usuário % não encontrado ou sem acesso.', v_uid;
    END IF;

    -- Cliente ou Comprador
    IF v_role_name IN ('admin', 'comprador') THEN
        IF p_current_delivery_date IS NOT NULL THEN
            RAISE EXCEPTION 'Usuários com papel % não têm permissão para alterar a data de entrega do item.', v_role_name;
        END IF;

        PERFORM set_config('request.source', 'client', true);
        PERFORM set_config('request.user_id', v_uid::TEXT, true);

    -- Fornecedor
    ELSIF v_role_name = 'fornecedor' THEN
        -- Verifica se o status é permitido ao fornecedor
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

        SELECT sc.id
        INTO v_supplier_contact_id
        FROM public.supplier_contacts sc
        JOIN public.supplier_users su ON su.supplier_contact_id = sc.id
        WHERE su.id = v_uid
          AND sc.is_active = true
        LIMIT 1;

        PERFORM set_config('request.source', 'supplier', true);
        PERFORM set_config('request.supplier_contact_id', v_supplier_contact_id::TEXT, true);
        PERFORM set_config('request.user_id', v_uid::TEXT, true);
    ELSE
        RAISE EXCEPTION 'Acesso negado: usuário % não possui permissão para atualizar pedidos.', v_uid;
    END IF;

    -- Atualiza apenas os campos informados
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

-- Função para inserir fatura de item de pedido
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
    v_supplier_id BIGINT;
    v_supplier_contact_id BIGINT;
    v_order_item_exists BOOLEAN;
BEGIN
    -- Validar campos obrigatórios
    IF p_nfe_number IS NULL OR trim(p_nfe_number) = '' THEN
        RAISE EXCEPTION 'Número da NFe não pode ser vazio.';
    ELSIF p_nfe_date IS NULL THEN
        RAISE EXCEPTION 'Data da NFe não pode ser nula.';
    ELSIF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantidade faturada deve ser maior que zero.';
    ELSIF p_invoiced_value IS NULL OR p_invoiced_value < 0 THEN
        RAISE EXCEPTION 'Valor faturado não pode ser negativo.';
    END IF;

    -- Captura sessão do usuário
    SELECT uac.role_name, uac.supplier_id
    INTO v_role_name, v_supplier_id
    FROM private.user_access_cache uac
    WHERE uac.user_id = v_uid
      AND uac.is_active = true
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Usuário % não encontrado ou sem acesso.', v_uid;
    END IF;

    -- Verifica se item pertence a algum pedido e se o usuário tem acesso
    IF v_role_name = 'fornecedor' THEN
        -- Para fornecedores: verifica se o item pertence ao fornecedor
        SELECT EXISTS (
            SELECT 1
            FROM public.order_items oi
            JOIN public.orders o ON o.id = oi.order_id
            WHERE oi.id = p_order_item_id
              AND o.supplier_id = v_supplier_id
        ) INTO v_order_item_exists;

        IF NOT v_order_item_exists THEN
            RAISE EXCEPTION 'Item de pedido % não encontrado ou não pertence ao fornecedor.', p_order_item_id;
        END IF;

        SELECT sc.id
        INTO v_supplier_contact_id
        FROM public.supplier_contacts sc
        JOIN public.supplier_users su ON su.supplier_contact_id = sc.id
        WHERE su.id = v_uid
          AND sc.is_active = true
        LIMIT 1;

        PERFORM set_config('request.source', 'supplier', true);
        PERFORM set_config('request.supplier_contact_id', v_supplier_contact_id::TEXT, true);
        PERFORM set_config('request.user_id', v_uid::TEXT, true);

    ELSIF v_role_name IN ('admin', 'comprador') THEN
        -- Para compradores/admin: verifica se o item pertence à empresa
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

    -- Inserir fatura
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

-- Função para inserir observações do fornecedor
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
    v_supplier_id BIGINT;
    v_supplier_contact_id BIGINT;
    v_order_company_id BIGINT;
BEGIN
    -- Captura company_id da sessão
    SELECT uac.company_id, uac.role_name, uac.supplier_id
    INTO v_company_id, v_role_name, v_supplier_id
    FROM private.user_access_cache uac
    WHERE uac.user_id = v_uid
      AND uac.is_active = true
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Usuário % não encontrado ou sem acesso.', v_uid;
    END IF;

    -- Verifica se o usuário tem role 'fornecedor'
    IF v_role_name <> 'fornecedor' THEN
        RAISE EXCEPTION 'Acesso negado: apenas usuários com role "fornecedor" podem inserir observações.';
    END IF;

    -- Verifica se o pedido existe e pertence à empresa do usuário
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

    -- Captura o supplier_contact_id para o trigger
    SELECT sc.id
    INTO v_supplier_contact_id
    FROM public.supplier_contacts sc
    JOIN public.supplier_users su ON su.supplier_contact_id = sc.id
    WHERE su.id = v_uid
      AND sc.is_active = true
    LIMIT 1;

    -- Define variáveis de contexto para o trigger
    PERFORM set_config('request.source', 'supplier', true);
    PERFORM set_config('request.supplier_contact_id', v_supplier_contact_id::TEXT, true);
    PERFORM set_config('request.user_id', v_uid::TEXT, true);

    -- Insere a observação na tabela
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

-- Função para inserir observações do comprador
CREATE OR REPLACE FUNCTION public.fn_insert_client_observations(
    p_order_id BIGINT,
    p_user_observations TEXT,
    p_created_by UUID,
    p_order_item_id BIGINT DEFAULT NULL
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
    v_order_company_id BIGINT;
    v_order_number TEXT;
    v_item_number BIGINT;
BEGIN
    -- Captura company_id da sessão
    SELECT uac.company_id, uac.role_name
    INTO v_company_id, v_role_name
    FROM private.user_access_cache uac
    WHERE uac.user_id = v_uid
      AND uac.is_active = true
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Usuário % não encontrado ou sem acesso.', v_uid;
    END IF;

    -- Verifica se o usuário tem role 'admin' ou 'comprador'
    IF v_role_name NOT IN ('admin', 'comprador') THEN
        RAISE EXCEPTION 'Acesso negado: apenas usuários com role "admin" ou "comprador" podem inserir observações.';
    END IF;

    -- Verifica se o pedido existe e pertence à empresa do usuário
    SELECT company_id, order_number
    INTO v_order_company_id, v_order_number
    FROM public.orders
    WHERE id = p_order_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Pedido % não encontrado.', p_order_id;
    END IF;

    IF v_order_company_id <> v_company_id THEN
        RAISE EXCEPTION 'Acesso negado: pedido % não pertence à empresa do usuário.', p_order_id;
    END IF;

    -- Se order_item_id foi fornecido, verifica se existe
    IF p_order_item_id IS NOT NULL THEN
        SELECT item_number INTO v_item_number
        FROM public.order_items
        WHERE id = p_order_item_id AND order_id = p_order_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Item % não encontrado no pedido %.', p_order_item_id, p_order_id;
        END IF;
    END IF;

    -- Define variáveis de contexto para o trigger
    PERFORM set_config('request.source', 'client', true);
    PERFORM set_config('request.user_id', v_uid::TEXT, true);

    -- Insere a observação na tabela
    INSERT INTO public.order_and_item_observations (
        order_id,
        order_item_id,
        user_observations,
        created_by
    ) VALUES (
        p_order_id,
        p_order_item_id,
        p_user_observations,
        p_created_by
    );

END;
$$;

-- Função para atualizar status de pedido pelo comprador
CREATE OR REPLACE FUNCTION public.fn_update_order_status_by_client(
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
BEGIN
    -- Captura company_id da sessão
    SELECT uac.company_id, uac.role_name
    INTO v_company_id, v_role_name
    FROM private.user_access_cache uac
    WHERE uac.user_id = v_uid
      AND uac.is_active = true
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Usuário % não encontrado ou sem acesso.', v_uid;
    END IF;

    -- Verifica se o usuário tem role 'admin' ou 'comprador'
    IF v_role_name NOT IN ('admin', 'comprador') THEN
        RAISE EXCEPTION 'Acesso negado: apenas usuários com role "admin" ou "comprador" podem atualizar status de pedidos.';
    END IF;

    -- Define variáveis de contexto para o trigger
    PERFORM set_config('request.source', 'client', true);
    PERFORM set_config('request.user_id', v_uid::TEXT, true);

    -- Atualiza o status do pedido
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

-- Função para atualizar campos de itens pelo comprador
CREATE OR REPLACE FUNCTION public.fn_update_order_items_by_client(
    p_order_id BIGINT,
    p_order_item_id BIGINT,
    p_status_id BIGINT DEFAULT NULL,
    p_due_date DATE DEFAULT NULL,
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
BEGIN
    IF p_status_id IS NULL AND p_due_date IS NULL AND p_current_delivery_date IS NULL THEN
        RAISE EXCEPTION 'Pelo menos um dos parâmetros deve ser fornecido.';
    END IF;

    -- Captura sessão do usuário
    SELECT uac.company_id, uac.role_name
    INTO v_company_id, v_role_name
    FROM private.user_access_cache uac
    WHERE uac.user_id = v_uid
      AND uac.is_active = true
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Usuário % não encontrado ou sem acesso.', v_uid;
    END IF;

    -- Verifica se o usuário tem role 'admin' ou 'comprador'
    IF v_role_name NOT IN ('admin', 'comprador') THEN
        RAISE EXCEPTION 'Acesso negado: apenas usuários com role "admin" ou "comprador" podem atualizar itens de pedidos.';
    END IF;

    -- Define variáveis de contexto para o trigger
    PERFORM set_config('request.source', 'client', true);
    PERFORM set_config('request.user_id', v_uid::TEXT, true);

    -- Atualiza apenas os campos informados
    IF p_status_id IS NOT NULL AND p_due_date IS NOT NULL AND p_current_delivery_date IS NOT NULL THEN
        UPDATE public.order_items
        SET status_id = p_status_id,
            due_date = p_due_date,
            current_delivery_date = p_current_delivery_date
        WHERE id = p_order_item_id
          AND order_id = p_order_id;

    ELSIF p_status_id IS NOT NULL AND p_due_date IS NOT NULL THEN
        UPDATE public.order_items
        SET status_id = p_status_id,
            due_date = p_due_date
        WHERE id = p_order_item_id
          AND order_id = p_order_id;

    ELSIF p_status_id IS NOT NULL AND p_current_delivery_date IS NOT NULL THEN
        UPDATE public.order_items
        SET status_id = p_status_id,
            current_delivery_date = p_current_delivery_date
        WHERE id = p_order_item_id
          AND order_id = p_order_id;

    ELSIF p_due_date IS NOT NULL AND p_current_delivery_date IS NOT NULL THEN
        UPDATE public.order_items
        SET due_date = p_due_date,
            current_delivery_date = p_current_delivery_date
        WHERE id = p_order_item_id
          AND order_id = p_order_id;

    ELSIF p_status_id IS NOT NULL THEN
        UPDATE public.order_items
        SET status_id = p_status_id
        WHERE id = p_order_item_id
          AND order_id = p_order_id;

    ELSIF p_due_date IS NOT NULL THEN
        UPDATE public.order_items
        SET due_date = p_due_date
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

-- ╭─────────────────◉ CONTEXTO: Envio de Emails ◉─────────────────────╮
-- ┃                   Funções de envio de emails                       ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Função para criar payload para enviar e-mails de follow-up via cron
CREATE OR REPLACE FUNCTION private.fn_send_payload_followup_cron(
    p_company_id BIGINT,
    supplier_ids BIGINT[] DEFAULT NULL,
    order_ids BIGINT[] DEFAULT NULL,
    user_observations TEXT DEFAULT NULL,
    template_html TEXT DEFAULT NULL,
    setting_id BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private'
AS $$
DECLARE
    payload JSONB := '[]'::JSONB;
    suppliers_to_process BIGINT[];
    supplier RECORD;
    supplier_contacts TEXT[];
    orders RECORD;
    orders_payload JSONB;
    supplier_payload JSONB;
    html_template_final TEXT;
BEGIN
    -- Validar se company_id foi fornecido
    IF p_company_id IS NULL THEN
        RAISE EXCEPTION 'company_id é obrigatório para execução via cron';
    END IF;

    -- Carrega o template, se não informado
    IF template_html IS NULL THEN
        SELECT email_template INTO html_template_final
        FROM public.followup_settings
        WHERE company_id = p_company_id
        AND trigger_scope = 'manual_user_trigger'
        AND is_active = TRUE
        ORDER BY id DESC
        LIMIT 1;
        
        IF html_template_final IS NULL THEN
            RAISE EXCEPTION 'Nenhum template configurado para follow-up manual (manual_user_trigger)';
        END IF;
    ELSE
        html_template_final := template_html;
    END IF;

    -- Define os suppliers a processar
    IF order_ids IS NOT NULL AND array_length(order_ids, 1) IS NOT NULL THEN
        SELECT array_agg(DISTINCT o.supplier_id) INTO suppliers_to_process
        FROM public.orders o
        JOIN public.default_order_status dos ON o.status_id = dos.id
        WHERE o.company_id = p_company_id
        AND o.id = ANY(order_ids)
        AND (
          -- Se todos os itens são finais, nunca envia followup
          NOT EXISTS (
            SELECT 1 FROM public.order_items oi
            JOIN public.order_item_status ois ON oi.status_id = ois.id
            WHERE oi.order_id = o.id AND ois.is_final = FALSE
          )
          OR
          -- Se tem itens não finais, verifica o status do pedido
          (
            EXISTS (
              SELECT 1 FROM public.order_items oi
              JOIN public.order_item_status ois ON oi.status_id = ois.id
              WHERE oi.order_id = o.id AND ois.is_final = FALSE
            )
            AND (
              (dos.is_final = FALSE AND dos.code != 'concluido')
              OR (dos.code = 'concluido')
            )
          )
        );
    ELSIF supplier_ids IS NOT NULL AND array_length(supplier_ids, 1) IS NOT NULL THEN
        -- Aplicar filtro mesmo quando supplier_ids é fornecido
        SELECT array_agg(DISTINCT o.supplier_id) INTO suppliers_to_process
        FROM public.orders o
        JOIN public.default_order_status dos ON o.status_id = dos.id
        WHERE o.company_id = p_company_id
          AND o.supplier_id = ANY(supplier_ids)
          AND (
            -- Se todos os itens são finais, nunca envia followup
            NOT EXISTS (
              SELECT 1 FROM public.order_items oi
              JOIN public.order_item_status ois ON oi.status_id = ois.id
              WHERE oi.order_id = o.id AND ois.is_final = FALSE
            )
            OR
            -- Se tem itens não finais, verifica o status do pedido
            (
              EXISTS (
                SELECT 1 FROM public.order_items oi
                JOIN public.order_item_status ois ON oi.status_id = ois.id
                WHERE oi.order_id = o.id AND ois.is_final = FALSE
              )
              AND (
                (dos.is_final = FALSE AND dos.code != 'concluido')
                OR (dos.code = 'concluido')
              )
            )
          );
    ELSE
        SELECT array_agg(DISTINCT supplier_id) INTO suppliers_to_process
        FROM public.orders o
        JOIN public.default_order_status dos ON o.status_id = dos.id
        WHERE o.company_id = p_company_id
        AND (
          -- Se todos os itens são finais, nunca envia followup
          NOT EXISTS (
            SELECT 1 FROM public.order_items oi
            JOIN public.order_item_status ois ON oi.status_id = ois.id
            WHERE oi.order_id = o.id AND ois.is_final = FALSE
          )
          OR
          -- Se tem itens não finais, verifica o status do pedido
          (
            EXISTS (
              SELECT 1 FROM public.order_items oi
              JOIN public.order_item_status ois ON oi.status_id = ois.id
              WHERE oi.order_id = o.id AND ois.is_final = FALSE
            )
            AND (
              (dos.is_final = FALSE AND dos.code != 'concluido')
              OR (dos.code = 'concluido')
            )
          )
        );
    END IF;

    -- Loop de fornecedores
    FOR supplier IN
        SELECT id, name
        FROM public.suppliers
        WHERE id = ANY(suppliers_to_process)
        AND company_id = p_company_id
    LOOP
      BEGIN
        -- Buscar contatos do fornecedor
        SELECT array_agg(name || ' <' || email || '>') INTO supplier_contacts
        FROM public.supplier_contacts
        WHERE supplier_id = supplier.id
        AND is_active = TRUE;

        -- Pula se não houver contatos
        IF supplier_contacts IS NULL OR array_length(supplier_contacts, 1) = 0 THEN
            CONTINUE;
        END IF;

        -- Montar pedidos do fornecedor - MESMA ESTRUTURA DA FUNÇÃO ORIGINAL
        orders_payload := '[]'::JSONB;
        
        FOR orders IN
            SELECT id, order_number, items
            FROM (
                SELECT
                    o.id,
                    o.supplier_id,
                    o.order_number,
                    COALESCE(array_agg(oi.item_number), ARRAY[]::BIGINT[]) AS items
                FROM public.orders o
                JOIN public.default_order_status dos ON o.status_id = dos.id
                LEFT JOIN public.order_items oi ON oi.order_id = o.id
                WHERE o.company_id = p_company_id
                AND (
                  -- Se todos os itens são finais, nunca envia followup
                  NOT EXISTS (
                    SELECT 1 FROM public.order_items oi2
                    JOIN public.order_item_status ois2 ON oi2.status_id = ois2.id
                    WHERE oi2.order_id = o.id AND ois2.is_final = FALSE
                  )
                  OR
                  -- Se tem itens não finais, verifica o status do pedido
                  (
                    EXISTS (
                      SELECT 1 FROM public.order_items oi2
                      JOIN public.order_item_status ois2 ON oi2.status_id = ois2.id
                      WHERE oi2.order_id = o.id AND ois2.is_final = FALSE
                    )
                    AND (
                      (dos.is_final = FALSE AND dos.code != 'concluido')
                      OR (dos.code = 'concluido')
                    )
                  )
                )
                AND (
                    (order_ids IS NOT NULL AND o.id = ANY(order_ids)) OR
                    (order_ids IS NULL)
                )
                GROUP BY o.supplier_id, o.order_number, o.id
            ) orders_with_items
            WHERE supplier_id = supplier.id
        LOOP
            -- CORREÇÃO: usar order_number como na função original, não order_id
            orders_payload := orders_payload || jsonb_build_object(
                'order_id', orders.id,
                'order_number', orders.order_number,
                'items', orders.items
            );
        END LOOP;

        -- Montar bloco de payload do fornecedor
        supplier_payload := jsonb_build_object(
            'supplier_id', supplier.id,
            'supplier_contacts', to_jsonb(supplier_contacts),
            'orders_payload', orders_payload,
            'user_observations', COALESCE(user_observations, ''),
            'template_html', html_template_final,
            'setting_id', setting_id
        );

        payload := payload || jsonb_build_array(supplier_payload);

      EXCEPTION
        WHEN OTHERS THEN
          PERFORM private.fn_log_process_event(
            p_process_name  := 'send_followup_emails_cron',
            p_function_name := 'fn_send_payload_followup_cron',
            p_step          := 'supplier_payload',
            p_status        := 'error',
            p_message       := format('Erro ao montar payload para fornecedor %s (%s): %s', supplier.name, supplier.id, SQLERRM),
            p_user_id       := NULL,
            p_metadata      := jsonb_build_object(
                                  'supplier_id', supplier.id,
                                  'company_id', p_company_id
                                )
          );
          CONTINUE;
      END;
    END LOOP;
    
    IF jsonb_array_length(payload) = 0 THEN
      PERFORM private.fn_log_process_event(
        p_process_name  := 'send_followup_emails_cron',
        p_function_name := 'fn_send_payload_followup_cron',
        p_step          := 'empty_payload',
        p_status        := 'warning',
        p_message       := 'Nenhum payload válido foi gerado. Nenhum follow-up será enviado.',
        p_user_id       := NULL,
        p_metadata      := jsonb_build_object(
                              'company_id', p_company_id
                            )
      );
      RETURN;
    END IF;

    PERFORM private.fn_log_process_event(
      p_process_name  := 'send_followup_emails_cron',
      p_function_name := 'fn_send_payload_followup_cron',
      p_step          := 'build_payload',
      p_status        := 'success',
      p_message       := format('Payload construído com sucesso para %s fornecedores com %s pedidos.',
                               jsonb_array_length(payload),
                               (SELECT SUM(jsonb_array_length(entry->'orders_payload')) 
                                FROM jsonb_array_elements(payload) AS entry)),
      p_user_id       := NULL,
      p_metadata      := jsonb_build_object(
                            'total_fornecedores', jsonb_array_length(payload),
                            'total_pedidos', (SELECT SUM(jsonb_array_length(entry->'orders_payload')) 
                                             FROM jsonb_array_elements(payload) AS entry),
                            'executado_para_company_id', p_company_id
                        )
    );

  BEGIN
    -- Usar a função específica para cron
    PERFORM private.fn_send_followup_emails_cron(payload, p_company_id);
  EXCEPTION
    WHEN OTHERS THEN
      PERFORM private.fn_log_process_event(
        p_process_name  := 'send_followup_emails_cron',
        p_function_name := 'fn_send_payload_followup_cron',
        p_step          := 'send_payload',
        p_status        := 'error',
        p_message       := format('Erro ao executar fn_send_followup_emails_cron: %s', SQLERRM),
        p_user_id       := NULL,
        p_metadata      := jsonb_build_object(
                              'payload_parcial', payload,
                              'company_id', p_company_id
                            )
      );
  END;
END;
$$;

-- Função específica para uso pelo cron (sem depender de autenticação)
CREATE OR REPLACE FUNCTION private.fn_send_followup_emails_cron(
    supplier_payload JSONB,
    in_company_id BIGINT
)
RETURNS VOID
SECURITY DEFINER
SET search_path TO 'public', 'vault', 'private'
LANGUAGE plpgsql
AS $$
DECLARE
    edge_token TEXT;
    service_role_key TEXT;
    supabase_url TEXT;
    endpoint TEXT := 'send-followup';
    -- variáveis do loop externo
    entry JSONB;
    supplier_id BIGINT;
    supplier_contacts TEXT[];
    template_html TEXT;
    orders_payload JSONB;
    user_observations TEXT;
    setting_id BIGINT;
    -- variáveis do loop interno
    enriched_payload JSONB;
    supplier_contacts_slice TEXT[];
    v_response JSONB;
    -- (sem autenticação)
    company_name TEXT;
BEGIN
    -- Validar parâmetros obrigatórios
    IF in_company_id IS NULL THEN
        RAISE EXCEPTION 'company_id é obrigatório para execução via cron';
    END IF;

    -- Buscar secrets - MESMA ORDEM DA FUNÇÃO ORIGINAL
    SELECT decrypted_secret INTO edge_token
    FROM vault.decrypted_secrets
    WHERE name = 'INTERNAL_EDGE_TOKEN';

    SELECT decrypted_secret INTO service_role_key
    FROM vault.decrypted_secrets
    WHERE name = 'SUPABASE_SERVICE_ROLE_KEY';

    SELECT decrypted_secret INTO supabase_url
    FROM vault.decrypted_secrets
    WHERE name = 'SUPABASE_URL';

    -- Nome da empresa
    SELECT name INTO company_name
    FROM public.companies
    WHERE id = in_company_id;

    -- Loop externo: para cada entry no JSON de fornecedores
    FOR entry IN
        SELECT * FROM jsonb_array_elements(supplier_payload)
    LOOP
        supplier_id := (entry ->> 'supplier_id')::BIGINT;
        template_html := entry ->> 'template_html';
        orders_payload := entry -> 'orders_payload';
        user_observations := entry ->> 'user_observations';
        setting_id := (entry ->> 'setting_id')::BIGINT;

        -- Converte JSON array para TEXT[]
        supplier_contacts := ARRAY(
            SELECT jsonb_array_elements_text(entry -> 'supplier_contacts')
        );

        -- quebra o array de contatos em batches de até 100
        FOR i IN 1..CEIL(array_length(supplier_contacts, 1) / 100.0)::BIGINT LOOP
            -- fatia os contatos
            supplier_contacts_slice := supplier_contacts[
                (i - 1) * 100 + 1 : LEAST(i * 100, array_length(supplier_contacts, 1))
            ];

            enriched_payload := jsonb_build_object(
                'user_id', NULL::UUID,  -- Diferença: NULL em vez de v_user_id
                'supplier_id', supplier_id,
                'supplier_contacts', to_jsonb(supplier_contacts_slice),
                'orders_payload', orders_payload,
                'company_id', in_company_id,  -- Diferença: usar in_company_id em vez de v_company_id
                'company_name', company_name,
                'user_observations', user_observations,
                'template_html', template_html,
                'setting_id', setting_id
            );

            SELECT net.http_post(
                url := supabase_url || '/functions/v1/' || endpoint,
                headers := jsonb_build_object(
                    'Content-Type', 'application/json',
                    'Authorization', 'Bearer ' || service_role_key,
                    'edge-token', edge_token
                ),
                body := jsonb_build_array(enriched_payload)
            ) INTO v_response;

            IF (v_response ->> 'status')::INT >= 400 THEN
              PERFORM private.fn_log_process_event(
                p_process_name  := 'send_followup_emails_cron',
                p_function_name := 'fn_send_followup_emails_cron',
                p_step          := 'edge_call',
                p_status        := 'error',
                p_message       := format('Erro ao enviar follow-up: %s', v_response ->> 'body'),
                p_user_id       := NULL::UUID,
                p_metadata      := jsonb_build_object(
                                      'contatos', supplier_contacts_slice,
                                      'status', v_response ->> 'status'
                                    )
              );
              CONTINUE;
            END IF;

            PERFORM private.fn_log_process_event(
                p_process_name  := 'send_followup_emails_cron',
                p_function_name := 'fn_send_followup_emails_cron',
                p_step          := 'edge_call',
                p_status        := 'success',
                p_message       := format('Chamada para Edge Function bem-sucedida para %s pedidos em batch de %s contatos.',
                                         jsonb_array_length(orders_payload), 
                                         array_length(supplier_contacts_slice, 1)),
                p_user_id       := NULL::UUID,  -- Diferença: NULL em vez de v_user_id
                p_metadata      := entry
            );
        END LOOP;
    END LOOP;
END;
$$;


-- Função para criar payload para enviar e-mails de follow-up
CREATE OR REPLACE FUNCTION public.fn_send_payload_followup(
  supplier_ids BIGINT[] DEFAULT NULL,
  order_ids    BIGINT[] DEFAULT NULL,
  user_observations TEXT DEFAULT NULL,
  template_html     TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private'
AS $$
DECLARE
  payload JSONB := '[]'::JSONB;
  suppliers_to_process BIGINT[];
  supplier RECORD;
  supplier_contacts TEXT[];
  orders RECORD;
  orders_payload JSONB;
  supplier_payload JSONB;
  html_template_final TEXT;
  v_company_id BIGINT;
  v_uid UUID := (select auth.uid());
  entry JSONB;
  order_entry JSONB;
  order_id_val BIGINT;
  observations_inserted INT := 0;
  observations_failed INT := 0;
BEGIN
  -- Captura company_id da sessão
  SELECT uac.company_id INTO v_company_id
  FROM private.user_access_cache uac
  WHERE uac.user_id = v_uid
    AND uac.is_active = true
    AND uac.role_name IN ('admin', 'comprador')
  LIMIT 1;

  IF v_company_id IS NULL THEN
    RAISE EXCEPTION 'Acesso negado: company_id não encontrado para o usuário % no cache de acesso.', v_uid;
  END IF;

  -- Carrega o template, se não informado
  IF template_html IS NULL THEN
    SELECT email_template INTO html_template_final
    FROM public.followup_settings
    WHERE company_id = v_company_id
      AND trigger_scope = 'manual_user_trigger'
      AND is_active = TRUE
    ORDER BY id DESC
    LIMIT 1;

    IF html_template_final IS NULL THEN
      RAISE EXCEPTION 'Nenhum template configurado para follow-up manual (manual_user_trigger)';
    END IF;
  ELSE
    html_template_final := template_html;
  END IF;

  -- Define os suppliers a processar
  IF order_ids IS NOT NULL AND array_length(order_ids, 1) IS NOT NULL THEN
    SELECT array_agg(DISTINCT o.supplier_id) INTO suppliers_to_process
    FROM public.orders o
    JOIN public.default_order_status dos ON o.status_id = dos.id
    WHERE o.company_id = v_company_id
      AND o.id = ANY(order_ids)
      AND (
        -- Se tem itens não finais, verifica o status do pedido
        EXISTS (
          SELECT 1 FROM public.order_items oi
          JOIN public.order_item_status ois ON oi.status_id = ois.id
          WHERE oi.order_id = o.id AND ois.is_final = FALSE
        )
        AND (
          (dos.is_final = FALSE AND dos.code != 'concluido')
          OR (dos.code = 'concluido')
        )
      );

  ELSIF supplier_ids IS NOT NULL AND array_length(supplier_ids, 1) IS NOT NULL THEN
    -- Aplicar filtro mesmo quando supplier_ids é fornecido
    SELECT array_agg(DISTINCT o.supplier_id) INTO suppliers_to_process
    FROM public.orders o
    JOIN public.default_order_status dos ON o.status_id = dos.id
    WHERE o.company_id = v_company_id
      AND o.supplier_id = ANY(supplier_ids)
      AND (
        -- Se tem itens não finais, verifica o status do pedido
        EXISTS (
          SELECT 1 FROM public.order_items oi
          JOIN public.order_item_status ois ON oi.status_id = ois.id
          WHERE oi.order_id = o.id AND ois.is_final = FALSE
        )
        AND (
          (dos.is_final = FALSE AND dos.code != 'concluido')
          OR (dos.code = 'concluido')
        )
      );

  ELSE
    SELECT array_agg(DISTINCT supplier_id) INTO suppliers_to_process
    FROM public.orders o
    JOIN public.default_order_status dos ON o.status_id = dos.id
    WHERE o.company_id = v_company_id
      AND (
        -- Se tem itens não finais, verifica o status do pedido
        EXISTS (
          SELECT 1 FROM public.order_items oi
          JOIN public.order_item_status ois ON oi.status_id = ois.id
          WHERE oi.order_id = o.id AND ois.is_final = FALSE
        )
        AND (
          (dos.is_final = FALSE AND dos.code != 'concluido')
          OR (dos.code = 'concluido')
        )
      );
  END IF;

  -- Loop de fornecedores
  FOR supplier IN
    SELECT id, name
    FROM public.suppliers
    WHERE id = ANY(suppliers_to_process)
      AND company_id = v_company_id
  LOOP
    BEGIN
      -- Buscar contatos do fornecedor
      SELECT array_agg(name || ' <' || email || '>') INTO supplier_contacts
      FROM public.supplier_contacts
      WHERE supplier_id = supplier.id
        AND is_active = TRUE;

      -- Pula se não houver contatos
      IF supplier_contacts IS NULL OR array_length(supplier_contacts, 1) = 0 THEN
        CONTINUE;
      END IF;

      -- Montar pedidos do fornecedor
      orders_payload := '[]'::JSONB;

      FOR orders IN
        SELECT id, order_number, items
          FROM (
            SELECT 
              o.id,
              o.supplier_id,
              o.order_number,
              COALESCE(array_agg(oi.item_number), ARRAY[]::BIGINT[]) AS items
            FROM public.orders o
            JOIN public.default_order_status dos ON o.status_id = dos.id
            LEFT JOIN public.order_items oi ON oi.order_id = o.id
            WHERE o.company_id = v_company_id
              AND (
                -- Se tem itens não finais, verifica o status do pedido
                EXISTS (
                  SELECT 1 FROM public.order_items oi2
                  JOIN public.order_item_status ois2 ON oi2.status_id = ois2.id
                  WHERE oi2.order_id = o.id AND ois2.is_final = FALSE
                )
                AND (
                  (dos.is_final = FALSE AND dos.code != 'concluido')
                  OR (dos.code = 'concluido')
                )
              )
              AND (
                (order_ids IS NOT NULL AND o.id = ANY(order_ids)) OR
                (order_ids IS NULL)
              )
            GROUP BY o.supplier_id, o.order_number, o.id
          ) orders_with_items
          WHERE supplier_id = supplier.id
      LOOP
        orders_payload := orders_payload || jsonb_build_object(
          'order_id', orders.id,
          'order_number', orders.order_number,
          'items', orders.items
        );
      END LOOP;

      -- Montar bloco de payload do fornecedor
      supplier_payload := jsonb_build_object(
        'supplier_id',       supplier.id,
        'supplier_contacts', to_jsonb(supplier_contacts),
        'orders_payload',    orders_payload,
        'user_observations', COALESCE(user_observations, ''),
        'template_html',     html_template_final
      );

      payload := payload || jsonb_build_array(supplier_payload);

    EXCEPTION
      WHEN OTHERS THEN
        PERFORM private.fn_log_process_event(
          p_process_name  := 'send_followup_emails',
          p_function_name := 'fn_send_payload_followup',
          p_step          := 'supplier_payload',
          p_status        := 'error',
          p_message       := format('Erro ao montar payload para fornecedor %s (%s): %s', supplier.name, supplier.id, SQLERRM),
          p_user_id       := v_uid,
          p_metadata      := jsonb_build_object(
                                'supplier_id', supplier.id,
                                'company_id', v_company_id
                              )
        );
        CONTINUE;
    END;
  END LOOP;
  
  IF jsonb_array_length(payload) = 0 THEN
    PERFORM private.fn_log_process_event(
      p_process_name  := 'send_followup_emails',
      p_function_name := 'fn_send_payload_followup',
      p_step          := 'empty_payload',
      p_status        := 'warning',
      p_message       := 'Nenhum payload válido foi gerado. Nenhum follow-up será enviado.',
      p_user_id       := v_uid,
      p_metadata      := jsonb_build_object(
                            'company_id', v_company_id
                          )
    );
    RETURN;
  END IF;

  PERFORM private.fn_log_process_event(
    p_process_name  := 'send_followup_emails',
    p_function_name := 'fn_send_payload_followup',
    p_step          := 'build_payload',
    p_status        := 'success',
    p_message       := format('Payload construído com sucesso para %s fornecedores com %s pedidos.',
                             jsonb_array_length(payload),
                             (SELECT SUM(jsonb_array_length(e->'orders_payload')) 
                              FROM jsonb_array_elements(payload) AS e)),
    p_user_id       := v_uid,
    p_metadata      := jsonb_build_object(
                          'total_fornecedores', jsonb_array_length(payload),
                          'total_pedidos', (SELECT SUM(jsonb_array_length(e->'orders_payload')) 
                                           FROM jsonb_array_elements(payload) AS e),
                          'executado_para_company_id', v_company_id
                      )
  );
  
  -- Inserir observações se user_observations estiver presente
  IF user_observations IS NOT NULL AND TRIM(user_observations) != '' THEN
    BEGIN
      observations_inserted := 0;
      observations_failed := 0;
      
      -- Iterar sobre todos os fornecedores no payload
      FOR entry IN
        SELECT value FROM jsonb_array_elements(payload)
      LOOP
        -- Iterar sobre todos os pedidos de cada fornecedor
        FOR order_entry IN
          SELECT value FROM jsonb_array_elements(entry->'orders_payload')
        LOOP
          order_id_val := (order_entry->>'order_id')::BIGINT;
          
          BEGIN
            -- Chamar fn_insert_client_observations para cada pedido
            PERFORM public.fn_insert_client_observations(
              p_order_id := order_id_val,
              p_user_observations := user_observations,
              p_created_by := v_uid,
              p_order_item_id := NULL
            );
            observations_inserted := observations_inserted + 1;
          EXCEPTION
            WHEN OTHERS THEN
              observations_failed := observations_failed + 1;
              PERFORM private.fn_log_process_event(
                p_process_name  := 'send_followup_emails',
                p_function_name := 'fn_send_payload_followup',
                p_step          := 'insert_observations',
                p_status        := 'error',
                p_message       := format('Erro ao inserir observação para pedido %s: %s', order_id_val, SQLERRM),
                p_user_id       := v_uid,
                p_metadata      := jsonb_build_object(
                                      'order_id', order_id_val,
                                      'company_id', v_company_id
                                    )
              );
          END;
        END LOOP;
      END LOOP;
      
      -- Log do resultado da inserção de observações
      IF observations_inserted > 0 THEN
        PERFORM private.fn_log_process_event(
          p_process_name  := 'send_followup_emails',
          p_function_name := 'fn_send_payload_followup',
          p_step          := 'insert_observations',
          p_status        := 'success',
          p_message       := format('Observações inseridas com sucesso: %s pedidos. Falhas: %s.', observations_inserted, observations_failed),
          p_user_id       := v_uid,
          p_metadata      := jsonb_build_object(
                                'observations_inserted', observations_inserted,
                                'observations_failed', observations_failed,
                                'company_id', v_company_id
                              )
        );
      END IF;
    END;
  END IF;
  
  BEGIN
  -- Disparo do e-mail
    PERFORM private.fn_send_followup_emails(payload);
  EXCEPTION
    WHEN OTHERS THEN
      PERFORM private.fn_log_process_event(
        p_process_name  := 'send_followup_emails',
        p_function_name := 'fn_send_payload_followup',
        p_step          := 'send_payload',
        p_status        := 'error',
        p_message       := format('Erro ao executar fn_send_followup_emails: %s', SQLERRM),
        p_user_id       := v_uid,
        p_metadata      := jsonb_build_object(
                              'payload_parcial', payload,
                              'company_id', v_company_id
                            )
      );
  END;
END;
$$;


-- Função para enviar e-mails de follow-up
CREATE OR REPLACE FUNCTION private.fn_send_followup_emails(
  supplier_payload JSONB,
  in_company_id BIGINT DEFAULT NULL
)
RETURNS VOID
SECURITY DEFINER
SET search_path TO 'public', 'vault', 'private'
LANGUAGE plpgsql
AS $$
DECLARE
  edge_token        TEXT;
  service_role_key  TEXT;
  supabase_url      TEXT;
  endpoint          TEXT := 'send-followup';
  -- variáveis do loop externo
  entry             JSONB;
  supplier_id       BIGINT;
  supplier_contacts TEXT[];
  template_html     TEXT;
  orders_payload    JSONB;
  user_observations TEXT;
  -- variáveis do loop interno
  supplier_contact  TEXT;
  enriched_payload  JSONB;
  supplier_contacts_slice TEXT[];
  v_response JSONB;
  -- sessão
  v_uid             UUID := (select auth.uid());
  v_user_id         UUID;
  v_company_id      BIGINT;
  v_is_active       BOOLEAN;
  company_name      TEXT;
BEGIN
  SELECT decrypted_secret INTO edge_token
    FROM vault.decrypted_secrets
    WHERE name = 'INTERNAL_EDGE_TOKEN';

  SELECT decrypted_secret INTO service_role_key
    FROM vault.decrypted_secrets
    WHERE name = 'SUPABASE_SERVICE_ROLE_KEY';

  SELECT decrypted_secret INTO supabase_url
    FROM vault.decrypted_secrets
    WHERE name = 'SUPABASE_URL';

  -- Sessão do usuário (se in_company_id não for passado)
  IF in_company_id IS NULL THEN
    SELECT uac.user_id, uac.company_id, uac.is_active
    INTO v_user_id, v_company_id, v_is_active
    FROM private.user_access_cache uac
    WHERE uac.user_id = v_uid
      AND uac.is_active = true
      AND uac.role_name IN ('admin', 'comprador')
    LIMIT 1;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Acesso negado: usuário % não tem registro ativo de acesso.', v_uid;
    END IF;
  ELSE
    v_company_id := in_company_id;
  END IF;

  -- Nome da empresa
  SELECT name INTO company_name
    FROM public.companies
    WHERE id = v_company_id;

  -- Loop externo: para cada entry no JSON de fornecedores
  FOR entry IN
    SELECT * FROM jsonb_array_elements(supplier_payload)
  LOOP
    supplier_id       := (entry ->> 'supplier_id')::BIGINT;
    template_html     := entry ->> 'template_html';
    orders_payload    := entry -> 'orders_payload';
    user_observations := entry ->> 'user_observations';

    -- Converte JSON array para TEXT[]
    supplier_contacts := ARRAY(
      SELECT jsonb_array_elements_text(entry -> 'supplier_contacts')
    );

    -- quebra o array de contatos em batches de até 100
    FOR i IN 1..CEIL(array_length(supplier_contacts, 1) / 100.0)::BIGINT LOOP
      -- fatia os contatos
      supplier_contacts_slice := supplier_contacts[
        (i - 1) * 100 + 1 : LEAST(i * 100, array_length(supplier_contacts, 1))
      ];

      enriched_payload := jsonb_build_object(
        'user_id',           v_user_id,
        'supplier_id',       supplier_id,
        'supplier_contacts', to_jsonb(supplier_contacts_slice),
        'orders_payload',    orders_payload,
        'company_id',        v_company_id,
        'company_name',      company_name,
        'user_observations', user_observations,
        'template_html',     template_html
      );

      SELECT net.http_post(
        url     := supabase_url || '/functions/v1/' || endpoint,
        headers := jsonb_build_object(
          'Content-Type',  'application/json',
          'Authorization', 'Bearer ' || service_role_key,
          'edge-token',    edge_token
        ),
        body    := jsonb_build_array(enriched_payload)
      ) INTO v_response;

      IF (v_response ->> 'status')::INT >= 400 THEN
        PERFORM private.fn_log_process_event(
          p_process_name  := 'send_followup_emails',
          p_function_name := 'fn_send_followup_emails',
          p_step          := 'edge_call',
          p_status        := 'error',
          p_message       := format('Erro ao enviar follow-up (status %s): %s', v_response ->> 'status', v_response ->> 'body'),
          p_user_id       := v_user_id,
          p_metadata      := jsonb_build_object(
                                'contatos', supplier_contacts_slice,
                                'payload', enriched_payload
                              )
        );
        CONTINUE;
      END IF;

      PERFORM private.fn_log_process_event(
        p_process_name  := 'send_followup_emails',
        p_function_name := 'fn_send_followup_emails',
        p_step          := 'edge_call',
        p_status        := 'success',
        p_message       := format('Chamada para Edge Function bem-sucedida para %s pedidos em batch de %s contatos.',
                                 jsonb_array_length(orders_payload), 
                                 array_length(supplier_contacts_slice, 1)),
        p_user_id       := v_user_id,
        p_metadata      := entry
      );
    END LOOP;
  END LOOP;
END;
$$;


-- Função para criar payload de e-mails de cancelamento de pedidos
CREATE OR REPLACE FUNCTION public.fn_send_payload_order_cancel(
    order_ids BIGINT[],
    user_observations TEXT DEFAULT NULL,
    template_html TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private'
AS $$
DECLARE
    order_info RECORD;
    supplier_contacts TEXT[];
    supplier_payloads JSONB[]; -- Array para múltiplos payloads
    html_template_final TEXT;
    v_company_id BIGINT;
    v_uid UUID := (select auth.uid());
    current_order_id BIGINT; -- Para iterar pelos IDs
BEGIN
    -- Captura company_id da sessão
    SELECT uac.company_id INTO v_company_id
    FROM private.user_access_cache uac
    WHERE uac.user_id = v_uid
      AND uac.is_active = true
      AND uac.role_name IN ('admin', 'comprador')
    LIMIT 1;

    IF v_company_id IS NULL THEN
        RAISE EXCEPTION 'Acesso negado: company_id não encontrado para o usuário % no cache de acesso.', v_uid;
    ELSE
        PERFORM set_config('request.source', 'client', true);
        PERFORM set_config('request.user_id', v_uid::TEXT, true);
    END IF;

    -- Carrega o template, se não informado
    IF template_html IS NULL THEN
        SELECT email_template INTO html_template_final
        FROM public.followup_settings
        WHERE company_id = v_company_id
          AND trigger_scope = 'manual_user_order_cancel'
          AND is_active = TRUE
        ORDER BY id DESC
        LIMIT 1;

        IF html_template_final IS NULL THEN
            RAISE EXCEPTION 'Nenhum template configurado para cancelamento de pedidos (manual_user_order_cancel)';
        END IF;
    ELSE
        html_template_final := template_html;
    END IF;

    -- Inicializa array de payloads
    supplier_payloads := ARRAY[]::JSONB[];

    -- Loop pelos order_ids
    FOREACH current_order_id IN ARRAY order_ids
    LOOP
      BEGIN
        -- Busca informações do pedido e fornecedor
        SELECT 
            o.id,
            o.order_number,
            o.order_description,
            o.due_date,
            dos.name as status_name,
            s.id as supplier_id,
            s.name as supplier_name
        INTO order_info
        FROM public.orders o
        JOIN public.default_order_status dos ON o.status_id = dos.id
        JOIN public.suppliers s ON o.supplier_id = s.id
        WHERE o.id = current_order_id
          AND o.company_id = v_company_id
          AND s.company_id = v_company_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Pedido % não encontrado ou não pertence à empresa do usuário', current_order_id;
        END IF;

        -- Atualiza o status do pedido para 6 (cancelado)
        UPDATE public.orders 
        SET status_id = 6
        WHERE id = current_order_id
          AND company_id = v_company_id;

        -- Buscar contatos do fornecedor
        SELECT array_agg(name || ' <' || email || '>') INTO supplier_contacts
        FROM public.supplier_contacts
        WHERE supplier_id = order_info.supplier_id
          AND is_active = TRUE;

        -- Verifica se há contatos - SE NÃO HOUVER, APENAS CONTINUA PARA O PRÓXIMO PEDIDO
        IF supplier_contacts IS NOT NULL AND array_length(supplier_contacts, 1) > 0 THEN
            -- Adiciona payload ao array somente se houver contatos
            supplier_payloads := supplier_payloads || jsonb_build_object(
                'supplier_id', order_info.supplier_id,
                'supplier_name', order_info.supplier_name,
                'supplier_contacts', to_jsonb(supplier_contacts),
                'order_info', jsonb_build_object(
                    'order_id', order_info.id,
                    'order_number', order_info.order_number,
                    'order_description', COALESCE(order_info.order_description, ''),
                    'due_date', order_info.due_date,
                    'status_name', order_info.status_name
                ),
                'user_observations', COALESCE(user_observations, ''),
                'template_html', html_template_final
            );
        END IF;
        -- Se não houver contatos, simplesmente ignora e continua para o próximo pedido
      EXCEPTION
        WHEN OTHERS THEN
          PERFORM private.fn_log_process_event(
            p_process_name  := 'send_order_cancel_emails',
            p_function_name := 'fn_send_payload_order_cancel',
            p_step          := 'order_process',
            p_status        := 'error',
            p_message       := format('Erro ao processar pedido %s: %s', current_order_id, SQLERRM),
            p_user_id       := v_uid,
            p_metadata      := jsonb_build_object(
                                  'order_id', current_order_id,
                                  'company_id', v_company_id
                                )
          );
          CONTINUE;
      END;
    END LOOP;

    IF array_length(supplier_payloads, 1) = 0 THEN
      PERFORM private.fn_log_process_event(
        p_process_name  := 'send_order_cancel_emails',
        p_function_name := 'fn_send_payload_order_cancel',
        p_step          := 'empty_payload',
        p_status        := 'warning',
        p_message       := 'Nenhum payload de cancelamento foi gerado. Nenhum e-mail será enviado.',
        p_user_id       := v_uid,
        p_metadata      := jsonb_build_object(
                              'company_id', v_company_id,
                              'total_pedidos_recebidos', array_length(order_ids, 1)
                            )
      );
      RETURN;
    END IF;

    BEGIN
    -- Disparo dos e-mails (passa o array de payloads) - só se houver payloads
    IF array_length(supplier_payloads, 1) > 0 THEN
        PERFORM private.fn_send_order_cancel_emails(supplier_payloads);
    END IF;
    EXCEPTION
      WHEN OTHERS THEN
        PERFORM private.fn_log_process_event(
          p_process_name  := 'send_order_cancel_emails',
          p_function_name := 'fn_send_payload_order_cancel',
          p_step          := 'send_payload',
          p_status        := 'error',
          p_message       := format('Erro ao executar fn_send_order_cancel_emails: %s', SQLERRM),
          p_user_id       := v_uid,
          p_metadata      := jsonb_build_object(
                                'payload_parcial', supplier_payloads,
                                'company_id', v_company_id
                              )
        );
    END;
END;
$$;

-- Função para enviar e-mails de cancelamento de pedidos (BULK)
CREATE OR REPLACE FUNCTION private.fn_send_order_cancel_emails(
    supplier_payloads JSONB[], 
    in_company_id BIGINT DEFAULT NULL
)
RETURNS VOID
SECURITY DEFINER
SET search_path TO 'public', 'vault', 'private'
LANGUAGE plpgsql
AS $$
DECLARE
    edge_token TEXT;
    service_role_key TEXT;
    supabase_url TEXT;
    endpoint TEXT := 'send-order-cancel'; 
    -- variáveis do fornecedor
    supplier_payload JSONB; -- Para iterar pelos payloads
    supplier_id BIGINT;
    supplier_name TEXT;
    supplier_contacts TEXT[];
    template_html TEXT;
    order_info JSONB;
    user_observations TEXT;
    -- variáveis do envio em lotes
    enriched_payload JSONB;
    supplier_contacts_slice TEXT[];
    v_response JSONB;
    -- sessão
    v_uid UUID := (select auth.uid());
    v_user_id UUID;
    v_company_id BIGINT;
    v_is_active BOOLEAN;
    company_name TEXT;
BEGIN
    SELECT decrypted_secret INTO edge_token
    FROM vault.decrypted_secrets
    WHERE name = 'INTERNAL_EDGE_TOKEN';

    SELECT decrypted_secret INTO service_role_key
    FROM vault.decrypted_secrets
    WHERE name = 'SUPABASE_SERVICE_ROLE_KEY';

    SELECT decrypted_secret INTO supabase_url
    FROM vault.decrypted_secrets
    WHERE name = 'SUPABASE_URL';

    -- Sessão do usuário (se in_company_id não for passado)
    IF in_company_id IS NULL THEN
        SELECT uac.user_id, uac.company_id, uac.is_active
        INTO v_user_id, v_company_id, v_is_active
        FROM private.user_access_cache uac
        WHERE uac.user_id = v_uid
          AND uac.is_active = true
          AND uac.role_name IN ('admin', 'comprador')
        LIMIT 1;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Acesso negado: usuário % não tem registro ativo de acesso.', v_uid;
        END IF;
    ELSE
        v_company_id := in_company_id;
    END IF;

    -- Nome da empresa
    SELECT name INTO company_name
    FROM public.companies
    WHERE id = v_company_id;

    -- Loop pelos payloads (múltiplos pedidos)
    FOREACH supplier_payload IN ARRAY supplier_payloads
    LOOP
        -- Extrai dados do payload atual
        supplier_id := (supplier_payload ->> 'supplier_id')::BIGINT;
        supplier_name := supplier_payload ->> 'supplier_name';
        template_html := supplier_payload ->> 'template_html';
        order_info := supplier_payload -> 'order_info';
        user_observations := supplier_payload ->> 'user_observations';

        -- Converte JSON array para TEXT[]
        supplier_contacts := ARRAY(
            SELECT jsonb_array_elements_text(supplier_payload -> 'supplier_contacts')
        );

        -- Envia emails em lotes de até 100 contatos por vez
        FOR i IN 1..CEIL(array_length(supplier_contacts, 1) / 100.0)::BIGINT LOOP
            -- fatia os contatos
            supplier_contacts_slice := supplier_contacts[
                (i - 1) * 100 + 1 : LEAST(i * 100, array_length(supplier_contacts, 1))
            ];

            enriched_payload := jsonb_build_object(
                'user_id', v_user_id,
                'supplier_id', supplier_id,
                'supplier_name', supplier_name,
                'supplier_contacts', to_jsonb(supplier_contacts_slice),
                'order_info', order_info,
                'company_id', v_company_id,
                'company_name', company_name,
                'user_observations', user_observations,
                'template_html', template_html
            );

            SELECT net.http_post(
                url := supabase_url || '/functions/v1/' || endpoint,
                headers := jsonb_build_object(
                    'Content-Type', 'application/json',
                    'Authorization', 'Bearer ' || service_role_key,
                    'edge-token', edge_token
                ),
                body := jsonb_build_array(enriched_payload)
            ) INTO v_response;

            IF (v_response ->> 'status')::INT >= 400 THEN
              PERFORM private.fn_log_process_event(
                p_process_name  := 'send_order_cancel_emails',
                p_function_name := 'fn_send_order_cancel_emails',
                p_step          := 'edge_call',
                p_status        := 'error',
                p_message       := format('Falha no envio do email de cancelamento para %s (pedido: %s): %s', supplier_name, order_info ->> 'order_number', v_response ->> 'body'),
                p_user_id       := v_user_id,
                p_metadata      := jsonb_build_object(
                                      'contatos', supplier_contacts_slice,
                                      'status', v_response ->> 'status'
                                    )
              );
              CONTINUE;
            END IF;

            PERFORM private.fn_log_process_event(
                p_process_name  := 'send_order_cancel_emails',
                p_function_name := 'fn_send_order_cancel_emails',
                p_step          := 'edge_call',
                p_status        := 'success',
                p_message       := 'Email de cancelamento enviado para ' || supplier_name || ' - batch de ' || array_length(supplier_contacts_slice, 1) || ' contatos (pedido: ' || (order_info ->> 'order_number') || ')',
                p_user_id       := v_user_id,
                p_metadata      := supplier_payload
            );
        END LOOP;
    END LOOP;
END;
$$;


-- ╭─────────────────────◉ CONTEXTO: Automações ◉──────────────────────╮
-- ┃             Funções modulares de automação de followup             ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Função modular por TRIGGER_SCOPE: default_order_status (Status de Pedido)
CREATE OR REPLACE FUNCTION private.fn_get_targets_default_order_status(p_setting_id BIGINT)
RETURNS TABLE (
  supplier_id BIGINT,
  order_ids BIGINT[]
)
SECURITY DEFINER
SET search_path TO 'public', 'private'
LANGUAGE plpgsql
AS $$
DECLARE
  v_company_id BIGINT;
  v_status_id BIGINT;
  v_max_followups INT;
BEGIN
  -- Buscar configurações da regra
  SELECT fs.company_id, fs.trigger_reference_id, fs.max_followups
  INTO v_company_id, v_status_id, v_max_followups
  FROM public.followup_settings fs
  WHERE fs.id = p_setting_id AND fs.is_active = true;


  IF v_company_id IS NULL THEN
      RETURN;
  END IF;


  -- Default para max_followups se não definido
  v_max_followups := COALESCE(v_max_followups, 999);


  RETURN QUERY
  SELECT
      o.supplier_id,
      array_agg(o.id) as order_ids
  FROM public.orders o
  JOIN public.suppliers s ON s.id = o.supplier_id
  JOIN public.default_order_status dos ON dos.id = o.status_id
  WHERE o.company_id = v_company_id
    AND (v_status_id IS NULL OR o.status_id = v_status_id)
    AND (
      -- Se tem itens não finais, verifica o status do pedido
      EXISTS (
        SELECT 1 FROM public.order_items oi
        JOIN public.order_item_status ois ON oi.status_id = ois.id
        WHERE oi.order_id = o.id AND ois.is_final = FALSE
      )
      AND (
        (dos.is_final = FALSE AND dos.code != 'concluido')
        OR (dos.code = 'concluido')
      )
    )
    AND EXISTS (
        SELECT 1 FROM public.supplier_contacts sc
        WHERE sc.supplier_id = o.supplier_id
          AND sc.is_active = true
    )

    AND EXISTS (
        SELECT 1 FROM public.order_items oi
        LEFT JOIN private.followup_item_tracking fit ON (fit.order_item_id = oi.id AND fit.setting_id = p_setting_id)
        WHERE oi.order_id = o.id
          AND COALESCE(fit.followup_count, 0) < v_max_followups
    )
  GROUP BY o.supplier_id;
END;
$$;

-- Função modular por TRIGGER_SCOPE: order_due_date (Data de Vencimento do Pedido)
CREATE OR REPLACE FUNCTION private.fn_get_targets_order_due_date(p_setting_id BIGINT)
RETURNS TABLE (
  supplier_id BIGINT,
  order_ids BIGINT[]
)
SECURITY DEFINER
SET search_path TO 'public', 'private'
LANGUAGE plpgsql
AS $$
DECLARE
  v_company_id BIGINT;
  v_days_before INT;
  v_max_followups INT;
BEGIN
  SELECT fs.company_id, fs.send_days_interval, fs.max_followups
  INTO v_company_id, v_days_before, v_max_followups
  FROM public.followup_settings fs
  WHERE fs.id = p_setting_id AND fs.is_active = true;


  IF v_company_id IS NULL THEN
      RETURN;
  END IF;


  v_days_before := COALESCE(v_days_before, 3);
  v_max_followups := COALESCE(v_max_followups, 999);


  RETURN QUERY
  SELECT
      o.supplier_id,
      array_agg(o.id) as order_ids
  FROM public.orders o
  JOIN public.suppliers s ON s.id = o.supplier_id
  JOIN public.default_order_status dos ON dos.id = o.status_id
  WHERE o.company_id = v_company_id
    AND o.due_date IS NOT NULL
    AND o.due_date <= (CURRENT_DATE + (v_days_before || ' days')::INTERVAL)
    AND o.due_date >= CURRENT_DATE
    AND (
      -- Se tem itens não finais, verifica o status do pedido
      EXISTS (
        SELECT 1 FROM public.order_items oi
        JOIN public.order_item_status ois ON oi.status_id = ois.id
        WHERE oi.order_id = o.id AND ois.is_final = FALSE
      )
      AND (
        (dos.is_final = FALSE AND dos.code != 'concluido')
        OR (dos.code = 'concluido')
      )
    )
    AND EXISTS (
        SELECT 1 FROM public.supplier_contacts sc
        WHERE sc.supplier_id = o.supplier_id
          AND sc.is_active = true
    )

    AND EXISTS (
        SELECT 1 FROM public.order_items oi
        LEFT JOIN private.followup_item_tracking fit ON (fit.order_item_id = oi.id AND fit.setting_id = p_setting_id)
        WHERE oi.order_id = o.id
          AND COALESCE(fit.followup_count, 0) < v_max_followups
    )
  GROUP BY o.supplier_id;
END;
$$;

-- Função modular por TRIGGER_SCOPE: item_status (Status de item)
CREATE OR REPLACE FUNCTION private.fn_get_targets_item_status(p_setting_id BIGINT)
RETURNS TABLE (
  supplier_id BIGINT,
  order_ids BIGINT[]
)
SECURITY DEFINER
SET search_path TO 'public', 'private'
LANGUAGE plpgsql
AS $$
DECLARE
  v_company_id BIGINT;
  v_status_id BIGINT;
  v_max_followups INT;
BEGIN
  SELECT fs.company_id, fs.trigger_reference_id, fs.max_followups
  INTO v_company_id, v_status_id, v_max_followups
  FROM public.followup_settings fs
  WHERE fs.id = p_setting_id AND fs.is_active = true;


  IF v_company_id IS NULL THEN
      RETURN;
  END IF;


  v_max_followups := COALESCE(v_max_followups, 999);


  RETURN QUERY
  SELECT
      o.supplier_id,
      array_agg(DISTINCT o.id) as order_ids
  FROM public.orders o
  JOIN public.order_items oi ON oi.order_id = o.id
  JOIN public.suppliers s ON s.id = o.supplier_id
  JOIN public.default_order_status dos ON dos.id = o.status_id
  LEFT JOIN private.followup_item_tracking fit ON (fit.order_item_id = oi.id AND fit.setting_id = p_setting_id)
  WHERE o.company_id = v_company_id
    AND (v_status_id IS NULL OR oi.status_id = v_status_id)
    AND (
      -- Se tem itens não finais, verifica o status do pedido
      EXISTS (
        SELECT 1 FROM public.order_items oi2
        JOIN public.order_item_status ois2 ON oi2.status_id = ois2.id
        WHERE oi2.order_id = o.id AND ois2.is_final = FALSE
      )
      AND (
        (dos.is_final = FALSE AND dos.code != 'concluido')
        OR (dos.code = 'concluido')
      )
    )
    AND EXISTS (
        SELECT 1 FROM public.supplier_contacts sc
        WHERE sc.supplier_id = o.supplier_id
          AND sc.is_active = true
    )

    AND COALESCE(fit.followup_count, 0) < v_max_followups
  GROUP BY o.supplier_id;
END;
$$;


-- Função modular por TRIGGER_SCOPE: item_due_date (Data de Vencimento do Item)
CREATE OR REPLACE FUNCTION private.fn_get_targets_item_due_date(p_setting_id BIGINT)
RETURNS TABLE (
  supplier_id BIGINT,
  order_ids BIGINT[]
)
SECURITY DEFINER
SET search_path TO 'public', 'private'
LANGUAGE plpgsql
AS $$
DECLARE
  v_company_id BIGINT;
  v_days_before INT;
  v_max_followups INT;
BEGIN
  SELECT fs.company_id, fs.send_days_interval, fs.max_followups
  INTO v_company_id, v_days_before, v_max_followups
  FROM followup_settings fs
  WHERE fs.id = p_setting_id AND fs.is_active = true;


  IF v_company_id IS NULL THEN
      RETURN;
  END IF;


  v_days_before := COALESCE(v_days_before, 3);
  v_max_followups := COALESCE(v_max_followups, 999);


  RETURN QUERY
  SELECT
      o.supplier_id,
      array_agg(DISTINCT o.id) as order_ids
  FROM public.orders o
  JOIN public.order_items oi ON oi.order_id = o.id
  JOIN public.suppliers s ON s.id = o.supplier_id
  JOIN public.default_order_status dos ON dos.id = o.status_id
  LEFT JOIN private.followup_item_tracking fit ON (fit.order_item_id = oi.id AND fit.setting_id = p_setting_id)
  WHERE o.company_id = v_company_id
    AND oi.due_date IS NOT NULL
    AND oi.due_date <= (CURRENT_DATE + (v_days_before || ' days')::INTERVAL)
    AND oi.due_date >= CURRENT_DATE
    AND (
      -- Se tem itens não finais, verifica o status do pedido
      EXISTS (
        SELECT 1 FROM public.order_items oi2
        JOIN public.order_item_status ois2 ON oi2.status_id = ois2.id
        WHERE oi2.order_id = o.id AND ois2.is_final = FALSE
      )
      AND (
        (dos.is_final = FALSE AND dos.code != 'concluido')
        OR (dos.code = 'concluido')
      )
    )
    AND EXISTS (
        SELECT 1 FROM public.supplier_contacts sc
        WHERE sc.supplier_id = o.supplier_id
          AND sc.is_active = true
    )

    AND COALESCE(fit.followup_count, 0) < v_max_followups
  GROUP BY o.supplier_id;
END;
$$;

-- Função modular por TRIGGER_SCOPE: item_delivery_date (Data de Entrega do Item)
CREATE OR REPLACE FUNCTION private.fn_get_targets_item_delivery_date(p_setting_id BIGINT)
RETURNS TABLE (
  supplier_id BIGINT,
  order_ids BIGINT[]
)
SECURITY DEFINER
SET search_path TO 'public', 'private'
LANGUAGE plpgsql
AS $$
DECLARE
  v_company_id BIGINT;
  v_days_before INT;
  v_max_followups INT;
BEGIN
  SELECT fs.company_id, fs.send_days_interval, fs.max_followups
  INTO v_company_id, v_days_before, v_max_followups
  FROM public.followup_settings fs
  WHERE fs.id = p_setting_id AND fs.is_active = true;


  IF v_company_id IS NULL THEN
      RETURN;
  END IF;


  v_days_before := COALESCE(v_days_before, 3);
  v_max_followups := COALESCE(v_max_followups, 999);


  RETURN QUERY
  SELECT
      o.supplier_id,
      array_agg(DISTINCT o.id) as order_ids
  FROM public.orders o
  JOIN public.order_items oi ON oi.order_id = o.id
  JOIN public.suppliers s ON s.id = o.supplier_id
  JOIN public.default_order_status dos ON dos.id = o.status_id
  LEFT JOIN private.followup_item_tracking fit ON (fit.order_item_id = oi.id AND fit.setting_id = p_setting_id)
  WHERE o.company_id = v_company_id
    AND oi.current_delivery_date IS NOT NULL
    AND oi.current_delivery_date <= (CURRENT_DATE + (v_days_before || ' days')::INTERVAL)
    AND oi.current_delivery_date >= CURRENT_DATE
    AND (
      -- Se tem itens não finais, verifica o status do pedido
      EXISTS (
        SELECT 1 FROM public.order_items oi2
        JOIN public.order_item_status ois2 ON oi2.status_id = ois2.id
        WHERE oi2.order_id = o.id AND ois2.is_final = FALSE
      )
      AND (
        (dos.is_final = FALSE AND dos.code != 'concluido')
        OR (dos.code = 'concluido')
      )
    )
    AND EXISTS (
        SELECT 1 FROM public.supplier_contacts sc
        WHERE sc.supplier_id = o.supplier_id
          AND sc.is_active = true
    )

    AND COALESCE(fit.followup_count, 0) < v_max_followups
  GROUP BY o.supplier_id;
END;
$$;

-- Função executada pelo cron, para identificar regras elegíveis e popula a fila respeitando frequências.
CREATE OR REPLACE FUNCTION private.fn_execute_scheduled_followups()
RETURNS TABLE (
  processed_rules INT,
  queued_items INT,
  skipped_rules INT
)
SECURITY DEFINER
SET search_path TO 'public', 'private'
LANGUAGE plpgsql
AS $$
DECLARE
  setting RECORD;
  target RECORD;
  v_processed_rules INT := 0;
  v_queued_items INT := 0;
  v_skipped_rules INT := 0;
BEGIN
  FOR setting IN
      SELECT fs.*, c.name as company_name
      FROM public.followup_settings fs
      JOIN public.companies c ON c.id = fs.company_id
      WHERE fs.is_active = true
      ORDER BY fs.company_id, fs.id
  LOOP
      
      -- Verificar se passou o intervalo mínimo desde o último envio
      IF setting.last_sent_at IS NOT NULL 
         AND setting.send_days_interval IS NOT NULL 
         AND setting.last_sent_at > (NOW() - (setting.send_days_interval || ' days')::INTERVAL) THEN
          -- Pular esta regra pois ainda não passou o intervalo mínimo
          v_skipped_rules := v_skipped_rules + 1;
          CONTINUE;
      END IF;
      
      -- Processar cada trigger_scope com suas funções específicas
        IF setting.trigger_scope = 'default_order_status' THEN
            FOR target IN SELECT * FROM private.fn_get_targets_default_order_status(setting.id) LOOP
                PERFORM private.fn_queue_followup(setting.id, target.supplier_id, target.order_ids);
                v_queued_items := v_queued_items + 1;
            END LOOP;

        ELSIF setting.trigger_scope = 'order_due_date' THEN
            FOR target IN SELECT * FROM private.fn_get_targets_order_due_date(setting.id) LOOP
                PERFORM private.fn_queue_followup(setting.id, target.supplier_id, target.order_ids);
                v_queued_items := v_queued_items + 1;
            END LOOP;

        ELSIF setting.trigger_scope = 'item_status' THEN
            FOR target IN SELECT * FROM private.fn_get_targets_item_status(setting.id) LOOP
                PERFORM private.fn_queue_followup(setting.id, target.supplier_id, target.order_ids);
                v_queued_items := v_queued_items + 1;
            END LOOP;

        ELSIF setting.trigger_scope = 'item_due_date' THEN
            FOR target IN SELECT * FROM private.fn_get_targets_item_due_date(setting.id) LOOP
                PERFORM private.fn_queue_followup(setting.id, target.supplier_id, target.order_ids);
                v_queued_items := v_queued_items + 1;
            END LOOP;

        ELSIF setting.trigger_scope = 'item_delivery_date' THEN
            FOR target IN SELECT * FROM private.fn_get_targets_item_delivery_date(setting.id) LOOP
                PERFORM private.fn_queue_followup(setting.id, target.supplier_id, target.order_ids);
                v_queued_items := v_queued_items + 1;
            END LOOP;
        END IF;

      -- Atualizar timestamp da última execução
      UPDATE public.followup_settings
      SET last_sent_at = NOW()
      WHERE id = setting.id;
    
      v_processed_rules := v_processed_rules + 1;
  END LOOP;


  RETURN QUERY SELECT v_processed_rules, v_queued_items, v_skipped_rules;
END;
$$;

-- Função para evitar duplicação de itens na fila para o mesmo fornecedor/regra.
-- Respeita repeat_interval_days para controlar frequência de envio
CREATE OR REPLACE FUNCTION private.fn_queue_followup(
    p_setting_id BIGINT,
    p_supplier_id BIGINT,
    p_order_ids BIGINT[]
)
RETURNS VOID
SECURITY DEFINER
SET search_path TO 'public', 'private'
LANGUAGE plpgsql
AS $$
DECLARE
    v_company_id BIGINT;
    v_repeat_interval_days INT;
    v_last_success_at TIMESTAMP;
    v_should_queue BOOLEAN := FALSE;
BEGIN
    -- Buscar company_id e repeat_interval_days do setting
    SELECT fs.company_id, fs.repeat_interval_days
    INTO v_company_id, v_repeat_interval_days
    FROM public.followup_settings fs
    WHERE fs.id = p_setting_id;

    -- Buscar último envio bem-sucedido para este supplier+setting
    SELECT MAX(updated_at) INTO v_last_success_at
    FROM private.followup_queue
    WHERE setting_id = p_setting_id
      AND supplier_id = p_supplier_id
      AND status = 'sucesso';

    -- Decidir se deve enfileirar baseado no repeat_interval_days
    IF v_repeat_interval_days IS NULL OR v_repeat_interval_days = 0 THEN
        -- Se repeat_interval_days é NULL ou 0, só envia 1x por dia
        IF v_last_success_at IS NULL OR v_last_success_at < CURRENT_DATE THEN
            v_should_queue := TRUE;
        END IF;
    ELSE
        -- Se repeat_interval_days > 0, respeita o intervalo configurado
        IF v_last_success_at IS NULL OR 
           v_last_success_at < (NOW() - (v_repeat_interval_days || ' days')::INTERVAL) THEN
            v_should_queue := TRUE;
        END IF;
    END IF;

    -- Se deve enfileirar E não existe item pendente/enviando, inserir
    IF v_should_queue THEN
        INSERT INTO private.followup_queue (setting_id, supplier_id, company_id, order_ids, next_try_at)
        SELECT p_setting_id, p_supplier_id, v_company_id, p_order_ids, NOW()
        WHERE NOT EXISTS (
            SELECT 1 FROM private.followup_queue
            WHERE setting_id = p_setting_id
              AND supplier_id = p_supplier_id
              AND status IN ('pendente', 'enviando')
        );
    END IF;
END;
$$;

-- Função atualizar contadores após envio de followup
CREATE OR REPLACE FUNCTION private.fn_update_followup_counters(
  p_setting_id BIGINT,
  p_order_ids BIGINT[]
)
RETURNS VOID
SECURITY DEFINER
SET search_path TO 'public', 'private'
LANGUAGE plpgsql
AS $$
DECLARE
  v_company_id BIGINT;
  v_supplier_id BIGINT;
  pedido_id BIGINT;
  item_record RECORD;
BEGIN
  -- Buscar company_id do setting
  SELECT fs.company_id
  INTO v_company_id
  FROM public.followup_settings fs
  WHERE fs.id = p_setting_id;

  IF v_company_id IS NULL THEN
      RETURN;
  END IF;

  -- Para cada pedido processado
  FOREACH pedido_id IN ARRAY p_order_ids
  LOOP
      -- Buscar supplier_id do pedido
      SELECT supplier_id INTO v_supplier_id
      FROM public.orders
      WHERE id = pedido_id;
      
      -- Atualizar contador para cada item do pedido
      FOR item_record IN
          SELECT oi.id as item_id, oi.order_id
          FROM public.order_items oi
          WHERE oi.order_id = pedido_id
      LOOP
          INSERT INTO private.followup_item_tracking (
              order_id,
              order_item_id,
              setting_id,
              supplier_id,
              company_id,
              followup_count,
              last_followup_at
          )
          VALUES (
              item_record.order_id,
              item_record.item_id,
              p_setting_id,
              v_supplier_id,
              v_company_id,
              1,
              NOW()
          )
          ON CONFLICT (order_item_id, setting_id)
          DO UPDATE SET
              followup_count = followup_item_tracking.followup_count + 1,
              last_followup_at = NOW(),
              updated_at = NOW();
      END LOOP;
  END LOOP;
END;
$$;

-- Função para buscar notificações com informações completas de usuários
CREATE OR REPLACE FUNCTION public.fn_get_order_notifications()
RETURNS TABLE (
    id BIGINT,
    order_id BIGINT,
    order_item_id BIGINT,
    type TEXT,
    message TEXT,
    is_read BOOLEAN,
    created_at TIMESTAMP,
    read_by UUID,
    read_by_name TEXT,
    read_by_email TEXT,
    read_by_user_type TEXT,
    is_from_client BOOLEAN,
    supplier_id BIGINT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
    RETURN QUERY
    SELECT
        onf.id,
        onf.order_id,
        onf.order_item_id,
        onf.type,
        onf.message,
        onf.is_read,
        onf.created_at,
        onf.read_by,
        -- Buscar nome e email do usuário que marcou como lida
        COALESCE(cu.name, sc.name) AS read_by_name,
        COALESCE(cu.email, sc.email) AS read_by_email,
        -- Identificar o tipo de usuário que marcou como lida
        CASE 
            WHEN cu.id IS NOT NULL THEN 'client'::TEXT
            WHEN su.id IS NOT NULL THEN 'supplier'::TEXT
            ELSE NULL::TEXT
        END AS read_by_user_type,
        -- Identificar se a notificação é do cliente
        CASE 
            WHEN onf.type IN ('client_observation', 'client_status_change', 'client_item_change') THEN true
            ELSE false
        END AS is_from_client,
        -- Obter supplier_id através do pedido
        o.supplier_id
    FROM public.order_notifications onf
    -- LEFT JOIN para obter supplier_id do pedido
    LEFT JOIN public.orders o ON o.id = onf.order_id
    -- LEFT JOIN para buscar usuários compradores/admins
    LEFT JOIN public.company_users cu ON cu.id = onf.read_by
    -- LEFT JOIN para buscar usuários fornecedores via supplier_users -> supplier_contacts
    LEFT JOIN public.supplier_users su ON su.id = onf.read_by
    LEFT JOIN public.supplier_contacts sc ON sc.id = su.supplier_contact_id;
END;
$$;

-- Função para exportar dados de tabelas específicas
CREATE OR REPLACE FUNCTION public.fn_export_table(
  p_table_name TEXT,
  p_user_id UUID,
  -- Filtros para suppliers
  p_supplier_ids BIGINT[] DEFAULT NULL, -- suppliers.id - funciona para order_items também
  p_cities TEXT[] DEFAULT NULL, -- suppliers.address_city
  p_states TEXT[] DEFAULT NULL, -- suppliers.address_state
  p_supplier_created_dates DATE[] DEFAULT NULL, -- suppliers.created_at
  -- Filtros para order_items
  p_order_ids BIGINT[] DEFAULT NULL, -- order_items.order_id 
  p_item_created_dates DATE[] DEFAULT NULL, -- order_items.created_at (datas exatas)
  p_item_created_date_start DATE DEFAULT NULL, -- order_items.created_at (período início)
  p_item_created_date_end DATE DEFAULT NULL, -- order_items.created_at (período fim)
  p_due_dates DATE[] DEFAULT NULL, -- order_items.due_date
  p_delivery_dates DATE[] DEFAULT NULL, -- order_items.current_delivery_date
  p_status_ids INT[] DEFAULT NULL -- order_items.status_id
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
  table_data JSONB;
  payload JSONB;
  export_id UUID;
  v_response JSONB;
BEGIN
  -- Validar se a tabela é permitida
  IF p_table_name NOT IN ('suppliers', 'order_items') THEN
    RAISE EXCEPTION 'Tabela não permitida para exportação: %', p_table_name;
  END IF;

  -- Validar se arrays não estão vazios quando fornecidos
  IF p_supplier_ids IS NOT NULL AND array_length(p_supplier_ids, 1) = 0 THEN
    RAISE EXCEPTION 'Array de supplier_ids não pode estar vazio';
  END IF;
  
  IF p_cities IS NOT NULL AND array_length(p_cities, 1) = 0 THEN
    RAISE EXCEPTION 'Array de cities não pode estar vazio';
  END IF;
  
  IF p_states IS NOT NULL AND array_length(p_states, 1) = 0 THEN
    RAISE EXCEPTION 'Array de states não pode estar vazio';
  END IF;
  
  IF p_supplier_created_dates IS NOT NULL AND array_length(p_supplier_created_dates, 1) = 0 THEN
    RAISE EXCEPTION 'Array de supplier_created_dates não pode estar vazio';
  END IF;
  
  IF p_order_ids IS NOT NULL AND array_length(p_order_ids, 1) = 0 THEN
    RAISE EXCEPTION 'Array de order_ids não pode estar vazio';
  END IF;
  
  IF p_item_created_dates IS NOT NULL AND array_length(p_item_created_dates, 1) = 0 THEN
    RAISE EXCEPTION 'Array de item_created_dates não pode estar vazio';
  END IF;
  
  IF p_due_dates IS NOT NULL AND array_length(p_due_dates, 1) = 0 THEN
    RAISE EXCEPTION 'Array de due_dates não pode estar vazio';
  END IF;
  
  IF p_delivery_dates IS NOT NULL AND array_length(p_delivery_dates, 1) = 0 THEN
    RAISE EXCEPTION 'Array de delivery_dates não pode estar vazio';
  END IF;
  
  IF p_status_ids IS NOT NULL AND array_length(p_status_ids, 1) = 0 THEN
    RAISE EXCEPTION 'Array de status_ids não pode estar vazio';
  END IF;
  
  -- Validar parâmetros de período
  IF p_item_created_date_start IS NOT NULL AND p_item_created_date_end IS NOT NULL THEN
    IF p_item_created_date_start > p_item_created_date_end THEN
      RAISE EXCEPTION 'Data de início não pode ser maior que data de fim';
    END IF;
  END IF;

  -- Buscar email e company_id do usuário
  SELECT cu.email, cu.company_id
  INTO user_email, v_company_id
  FROM public.company_users cu
  WHERE cu.id = p_user_id;

  IF user_email IS NULL THEN
    RAISE EXCEPTION 'Usuário não encontrado ou sem empresa associada.';
  END IF;

  -- Buscar dados da tabela baseado no company_id
  CASE p_table_name
    WHEN 'suppliers' THEN
      SELECT jsonb_agg(
        jsonb_build_object(
          'id_fornecedor', s.external_id,
          'nome', s.name,
          'cnpj', s.cnpj,
          'website', s.website,
          'descricao', s.description,
          'rua', s.address_street,
          'endereco_numero', s.address_number,
          'bairro', s.address_neighborhood,
          'cidade', s.address_city,
          'uf', s.address_state,
          'pais', s.address_country,
          'cep', s.address_zipcode,
          'complemento', s.address_complement,
          'criado_em', s.created_at
        )
      )
      INTO table_data
      FROM public.suppliers s
      WHERE s.company_id = v_company_id
        AND (p_supplier_ids IS NULL OR s.id = ANY(p_supplier_ids))
        AND (p_cities IS NULL OR s.address_city = ANY(p_cities))
        AND (p_states IS NULL OR s.address_state = ANY(p_states))
        AND (p_supplier_created_dates IS NULL OR DATE(s.created_at) = ANY(p_supplier_created_dates));

    WHEN 'order_items' THEN
      SELECT jsonb_agg(
        jsonb_build_object(
          -- Dados do order_item
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
          
          -- Dados da order relacionada
          'numero_pedido', o.order_number,
          'pedido_descricao', o.order_description,
          'pedido_data_da_remessa', o.due_date,
          'fornecedor', s.name,
          'pedido_criado_em', o.created_at,
          'pedido_atualizado_em', o.updated_at
        )
      )
      INTO table_data
      FROM public.order_items oi
      JOIN public.orders o ON o.id = oi.order_id
      JOIN public.order_item_status ois ON ois.id = oi.status_id
      JOIN public.suppliers s ON s.id = o.supplier_id
      WHERE o.company_id = v_company_id
        AND (p_supplier_ids IS NULL OR s.id = ANY(p_supplier_ids))
        AND (p_order_ids IS NULL OR oi.order_id = ANY(p_order_ids))
        AND (p_item_created_dates IS NULL OR DATE(oi.created_at) = ANY(p_item_created_dates))
        AND (p_item_created_date_start IS NULL OR DATE(oi.created_at) >= p_item_created_date_start)
        AND (p_item_created_date_end IS NULL OR DATE(oi.created_at) <= p_item_created_date_end)
        AND (p_due_dates IS NULL OR oi.due_date = ANY(p_due_dates))
        AND (p_delivery_dates IS NULL OR oi.current_delivery_date = ANY(p_delivery_dates))
        AND (p_status_ids IS NULL OR oi.status_id = ANY(p_status_ids));
  END CASE;

  -- Se não há dados, retornar erro
  IF table_data IS NULL OR jsonb_array_length(table_data) = 0 THEN
    RAISE EXCEPTION 'Nenhum dado encontrado para exportação na tabela %.', p_table_name;
  END IF;

  -- Gerar ID único para a operação
  export_id := gen_random_uuid();

  -- Obter credenciais Supabase do Vault
  SELECT decrypted_secret INTO service_role_key
  FROM vault.decrypted_secrets
  WHERE name = 'SUPABASE_SERVICE_ROLE_KEY';

  SELECT decrypted_secret INTO supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'SUPABASE_URL';

  SELECT decrypted_secret INTO edge_token
  FROM vault.decrypted_secrets
  WHERE name = 'EDGE_TOKEN';

  -- Montar payload para edge function
  payload := jsonb_build_object(
    'export_id', export_id,
    'table_name', p_table_name,
    'data', table_data,
    'user_id', p_user_id,
    'company_id', v_company_id,
    'user_email', user_email
  );

  -- Chamar edge function
  BEGIN
    SELECT net.http_post(
      url := supabase_url || '/functions/v1/export-data',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || service_role_key,
        'edge-token', edge_token
      ),
      body := payload
    ) INTO v_response;

    -- Verificar status da resposta
    IF (v_response ->> 'status')::INT >= 400 THEN
      -- Log de erro
      PERFORM private.fn_log_process_event(
        p_process_name := 'data_export',
        p_function_name := 'fn_export_table',
        p_step := 'edge_function_call',
        p_status := 'error',
        p_message := format('Erro na edge function: %s', v_response ->> 'content'),
        p_user_id := p_user_id,
        p_metadata := jsonb_build_object(
          'export_id', export_id,
          'table_name', p_table_name,
          'response', v_response
        )
      );

      RAISE EXCEPTION 'Erro na edge function: %', v_response ->> 'content';
    ELSE
      -- Log de sucesso
      PERFORM private.fn_log_process_event(
        p_process_name := 'data_export',
        p_function_name := 'fn_export_table',
        p_step := 'edge_function_call',
        p_status := 'success',
        p_message := format('Exportação iniciada com sucesso para tabela %s', p_table_name),
        p_user_id := p_user_id,
        p_metadata := jsonb_build_object(
          'export_id', export_id,
          'table_name', p_table_name,
          'data_count', jsonb_array_length(table_data),
          'response', v_response
        )
      );
    END IF;

  EXCEPTION WHEN OTHERS THEN
    -- Log de erro
    PERFORM private.fn_log_process_event(
      p_process_name := 'data_export',
      p_function_name := 'fn_export_table',
      p_step := 'edge_function_call',
      p_status := 'error',
      p_message := format('Erro ao chamar edge function: %s', SQLERRM),
      p_user_id := p_user_id,
      p_metadata := jsonb_build_object(
        'export_id', export_id,
        'table_name', p_table_name,
        'error', SQLERRM
      )
    );

    RAISE EXCEPTION 'Erro ao iniciar exportação: %', SQLERRM;
  END;

  -- Retornar resultado
  RETURN jsonb_build_object(
    'success', true,
    'export_id', export_id,
    'table_name', p_table_name,
    'data_count', jsonb_array_length(table_data),
    'message', 'Exportação iniciada com sucesso'
  );

END;
$$;

-- Função para exportar detalhes de um pedido (observações e follow-up tracking)
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
  order_item_invoices_data JSONB;
  combined_data JSONB;
  payload JSONB;
  export_id UUID;
  v_response JSONB;
BEGIN
  -- Buscar email e company_id do usuário
  SELECT cu.email, cu.company_id
  INTO user_email, v_company_id
  FROM public.company_users cu
  WHERE cu.id = p_user_id;

  IF user_email IS NULL THEN
    RAISE EXCEPTION 'Usuário não encontrado ou sem empresa associada.';
  END IF;

  -- Validar se o pedido existe e pertence à company do usuário
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

  -- Buscar dados do pedido (order)
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

  -- Buscar dados dos itens do pedido (order_items)
  SELECT jsonb_agg(
    jsonb_build_object(
      -- Dados do order_item
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
      
      -- Dados da order relacionada
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

  -- Se não houver itens, retornar array vazio
  IF order_items_data IS NULL THEN
    order_items_data := '[]'::jsonb;
  END IF;

  -- Buscar order_and_item_observations
  -- Substituir order_item_id por numero_item (fazer JOIN com order_items)
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', oao.id,
      'id_pedido', oao.order_id,
      'numero_item', oi.item_number,
      'observacao_do_usuario', oao.user_observations,
      'observacao_do_fornecedor', oao.supplier_observations,
      'data_da_entrega', oao.current_delivery_date,
      'criado_em', oao.created_at
    )
  ), '[]'::jsonb)
  INTO observations_data
  FROM public.order_and_item_observations oao
  LEFT JOIN public.order_items oi ON oi.id = oao.order_item_id
  WHERE oao.order_id = p_order_id;

  -- Buscar followup_item_tracking com rule_name
  -- Usar company_id diretamente da tabela followup_item_tracking
  -- Substituir order_item_id por numero_item
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', fit.id,
      'id_pedido', fit.order_id,
      'numero_item', oi.item_number,
      'regras_de_followup', fs.rule_name,
      'criado_em', fit.created_at
    )
  ), '[]'::jsonb)
  INTO followup_tracking_data
  FROM private.followup_item_tracking fit
  JOIN public.order_items oi ON oi.id = fit.order_item_id
  LEFT JOIN public.followup_settings fs ON fs.id = fit.setting_id
  WHERE fit.order_id = p_order_id
    AND fit.company_id = v_company_id;

  -- Buscar order_item_invoices relacionadas aos order_items do pedido
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', oii.id,
      'numero_item', oi.item_number,
      'numero_nfe', oii.nfe_number,
      'data_nfe', oii.nfe_date,
      'quantidade_faturada', oii.quantity,
      'valor_faturado', oii.invoiced_value,
      'volumes', oii.volumes,
      'criado_em', oii.created_at
    )
  ), '[]'::jsonb)
  INTO order_item_invoices_data
  FROM public.order_item_invoices oii
  JOIN public.order_items oi ON oi.id = oii.order_item_id
  WHERE oi.order_id = p_order_id;

  -- Combinar os dados
  combined_data := jsonb_build_object(
    'id_pedido', p_order_id,
    'observations', observations_data,
    'followup_tracking', followup_tracking_data
  );

  -- Gerar ID único para a operação
  export_id := gen_random_uuid();

  -- Obter credenciais Supabase do Vault
  SELECT decrypted_secret INTO service_role_key
  FROM vault.decrypted_secrets
  WHERE name = 'SUPABASE_SERVICE_ROLE_KEY';

  SELECT decrypted_secret INTO supabase_url
  FROM vault.decrypted_secrets
  WHERE name = 'SUPABASE_URL';

  SELECT decrypted_secret INTO edge_token
  FROM vault.decrypted_secrets
  WHERE name = 'EDGE_TOKEN';

  -- Montar payload para edge function
  payload := jsonb_build_object(
    'export_id', export_id,
    'id_pedido', p_order_id,
    'order', order_data,
    'order_items', order_items_data,
    'observations', observations_data,
    'followup_tracking', followup_tracking_data,
    'order_item_invoices', COALESCE(order_item_invoices_data, '[]'::jsonb),
    'user_id', p_user_id,
    'company_id', v_company_id,
    'user_email', user_email
  );

  -- Chamar edge function
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

    -- Verificar status da resposta
    IF (v_response ->> 'status')::INT >= 400 THEN
      -- Log de erro
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
      -- Log de sucesso
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
          'response', v_response
        )
      );
    END IF;

  EXCEPTION WHEN OTHERS THEN
    -- Log de erro
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

  -- Retornar resultado
  RETURN jsonb_build_object(
    'success', true,
    'export_id', export_id,
    'id_pedido', p_order_id,
    'order_items_count', jsonb_array_length(order_items_data),
    'observations_count', jsonb_array_length(observations_data),
    'followup_tracking_count', jsonb_array_length(followup_tracking_data),
    'order_item_invoices_count', jsonb_array_length(COALESCE(order_item_invoices_data, '[]'::jsonb)),
    'message', 'Exportação iniciada com sucesso'
  );

END;
$$;
