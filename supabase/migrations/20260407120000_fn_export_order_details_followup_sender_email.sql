-- Inclui sent_by_name e sent_by_email nos followup_logs do payload de exportação
-- (PDF da edge function export-order-details exibe e-mail em vez de UUID).

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
  -- Incluir usuario_nome e usuario_email via JOIN com company_users OU supplier_users
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
  LEFT JOIN public.supplier_users su ON su.id = oao.created_by
  LEFT JOIN public.supplier_contacts sc ON sc.id = su.supplier_contact_id
  WHERE oao.order_id = p_order_id;

  -- Buscar followup_item_tracking com rule_name
  -- Usar company_id diretamente da tabela followup_item_tracking
  -- Substituir order_item_id por numero_item
  -- Obter usuario_nome e usuario_email via order_item_logs (log de mudança de status mais recente)
  -- Pode ser company_users OU supplier_contacts
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
    -- Buscar o log de mudança de status mais recente para este item
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

  -- Buscar followup_logs relacionados ao pedido
  -- Filtrar onde orders_payload contém um objeto com order_id igual ao p_order_id
  -- Incluir rule_name da tabela followup_settings
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

  -- Buscar order_item_invoices relacionadas aos order_items do pedido
  -- Incluir usuario_nome e usuario_email via JOIN com company_users OU supplier_users
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
  LEFT JOIN public.supplier_users su ON su.id = oii.created_by
  LEFT JOIN public.supplier_contacts sc ON sc.id = su.supplier_contact_id
  WHERE oi.order_id = p_order_id;

  -- Buscar logs de alteração (view) para unificar data no relatório
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
    'followup_logs', COALESCE(followup_logs_data, '[]'::jsonb),
    'order_item_invoices', COALESCE(order_item_invoices_data, '[]'::jsonb),
    'order_change_logs', COALESCE(order_change_logs_data, '[]'::jsonb),
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
          'followup_logs_count', jsonb_array_length(COALESCE(followup_logs_data, '[]'::jsonb)),
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
    'followup_logs_count', jsonb_array_length(COALESCE(followup_logs_data, '[]'::jsonb)),
    'order_item_invoices_count', jsonb_array_length(COALESCE(order_item_invoices_data, '[]'::jsonb)),
    'message', 'Exportação iniciada com sucesso'
  );

END;
$$;
