-- ╭────────────────────────────────────────────────────────────────────╮
-- ┃                       Custom - Transpetro                          ┃
-- ╰────────────────────────────────────────────────────────────────────╯
-- Migration customizada para o cliente Transpetro (tp)
-- NÃO aplicar em outras instâncias genéricas ou de outros clientes


-- ╭─────────────────◉ CONTEXTO: Tabelas  ◉────────────────────╮
-- ┃                 Tabelas customizadas                       ┃
-- ╰────────────────────────────────────────────────────────────╯

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
ADD COLUMN bidding_description TEXT NULL, -- Descrição da licitação
ADD COLUMN custom_deliver_time INT NULL,  -- Prazo de fornecimento
ADD COLUMN purchase_req BIGINT NULL,      -- Número da requisição
ADD COLUMN purchase_req_item BIGINT NULL; -- Item da requisição

-- Criar tabela de importação MIGO/MIRO 
CREATE TABLE public.order_item_migo_miro_imports (
    id BIGSERIAL PRIMARY KEY,
    order_item_id BIGINT NOT NULL,
    receipt_date DATE NULL,  
    invoice_date DATE NULL,  
    payment_date DATE NULL,
    FOREIGN KEY (order_item_id) REFERENCES public.order_items(id) ON DELETE RESTRICT 
);

-- RLS para tabela order_item_migo_miro_imports
ALTER TABLE public.order_item_migo_miro_imports ENABLE ROW LEVEL SECURITY;

-- Política para leitura: apenas admin ou comprador podem visualizar
CREATE POLICY read_own_migo_miro_imports
ON public.order_item_migo_miro_imports
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.order_items oi ON oi.id = order_item_migo_miro_imports.order_item_id
    JOIN public.orders o ON o.id = oi.order_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.is_active = true
      AND uac.role_name IN ('admin', 'comprador', 'fornecedor')
      AND o.company_id = uac.company_id
  )
);

-- Política para superadmins: acesso total
CREATE POLICY superadmins_can_manage_all_migo_miro_imports
ON public.order_item_migo_miro_imports
FOR ALL
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM private.super_admins sa
    WHERE sa.id = (select auth.uid())
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM private.super_admins sa
    WHERE sa.id = (select auth.uid())
  )
);

-- Política para processos automatizados: permite insert/update apenas via funções SECURITY DEFINER
CREATE POLICY allow_automated_processes_migo_miro_imports
ON public.order_item_migo_miro_imports
FOR INSERT
TO authenticated
WITH CHECK (
  -- Permite insert apenas se foi chamado via função SECURITY DEFINER
  -- ou se é um superadmin
  EXISTS (
    SELECT 1 FROM private.super_admins sa
    WHERE sa.id = (select auth.uid())
  )
  OR
  current_setting('request.user_id', true) IS NOT NULL
);

CREATE POLICY allow_automated_updates_migo_miro_imports
ON public.order_item_migo_miro_imports
FOR UPDATE
TO authenticated
USING (
  -- Permite update apenas se foi chamado via função SECURITY DEFINER
  -- ou se é um superadmin
  EXISTS (
    SELECT 1 FROM private.super_admins sa
    WHERE sa.id = (select auth.uid())
  )
  OR
  current_setting('request.user_id', true) IS NOT NULL
)
WITH CHECK (
  EXISTS (
    SELECT 1 FROM private.super_admins sa
    WHERE sa.id = (select auth.uid())
  )
  OR
  current_setting('request.user_id', true) IS NOT NULL
);

-- ╭─────────────────◉ CONTEXTO: Views  ◉────────────────────╮
-- ┃                 Views customizadas                       ┃
-- ╰──────────────────────────────────────────────────────────╯

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
  CASE
  WHEN dos.is_final = TRUE AND dos.code != 'concluido' THEN false
  WHEN NOT EXISTS (
    SELECT 1 FROM public.order_items oi
    JOIN public.order_item_status ois ON oi.status_id = ois.id
    WHERE oi.order_id = o.id AND ois.is_final = FALSE
  ) THEN false  -- Se todos os itens são finais, nunca é atrasado
  ELSE CURRENT_DATE > o.due_date
  END AS overdue_order,
  -- Campo para verificar se o limite máximo de followups foi atingido
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
  -- Notificações do fornecedor (para compradores verem)
  EXISTS (
    SELECT 1
    FROM public.view_order_notifications von
    WHERE von.order_id = o.id
      AND von.is_read = false
      AND von.is_from_client = false  -- Notificações DO FORNECEDOR
  ) AS has_notifications_from_supplier,

  -- Notificações do comprador (para fornecedores verem)
  EXISTS (
    SELECT 1
    FROM public.view_order_notifications von
    WHERE von.order_id = o.id
      AND von.is_read = false
      AND von.is_from_client = true   -- Notificações DO COMPRADOR
  ) AS has_notifications_from_client,
  -- Adiciona o status_id com menor position dos order_items
  COALESCE(min_status.status_id, NULL) AS order_items_min_status_id,
  COALESCE(min_status.status_name, NULL) AS order_items_min_status_name
FROM public.orders o
JOIN public.suppliers s ON s.id = o.supplier_id
JOIN public.default_order_status dos ON dos.id = o.status_id
JOIN public.company_users cu ON cu.id = (SELECT auth.uid())
JOIN private.user_access_cache uac ON uac.user_id = cu.id
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

    -- Notificação mais recente não lida do fornecedor (se houver)
    n_supplier.type AS notification_type_from_supplier,
    n_supplier.message AS notification_message_from_supplier,

    -- Notificação mais recente não lida do comprador (se houver)
    n_client.type AS notification_type_from_client,
    n_client.message AS notification_message_from_client,

    -- Flag: existe notificação não lida do fornecedor?
    EXISTS (
      SELECT 1
      FROM public.view_order_notifications von
      WHERE von.order_item_id = oi.id
        AND von.is_read = false
        AND von.is_from_client = false  -- Notificações DO FORNECEDOR
    ) AS has_notifications_from_supplier,

    -- Flag: existe notificação não lida do comprador?
    EXISTS (
      SELECT 1
      FROM public.view_order_notifications von
      WHERE von.order_item_id = oi.id
        AND von.is_read = false
        AND von.is_from_client = true   -- Notificações DO COMPRADOR
    ) AS has_notifications_from_client,

    -- Flag: existe pelo menos uma notificação não lida? (compatibilidade)
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
    FROM public.view_order_notifications von
    WHERE von.order_item_id = oi.id
      AND von.is_read = false
      AND von.is_from_client = false  -- Notificações DO FORNECEDOR
    ORDER BY created_at DESC
    LIMIT 1
) n_supplier ON true
LEFT JOIN LATERAL (
    SELECT type, message, is_read
    FROM public.view_order_notifications von
    WHERE von.order_item_id = oi.id
      AND von.is_read = false
      AND von.is_from_client = true   -- Notificações DO COMPRADOR
    ORDER BY created_at DESC
    LIMIT 1
) n_client ON true;


-- ╭─────────────────◉ CONTEXTO: Storage  ◉──────────────────╮
-- ┃                 Storage customizados                     ┃
-- ╰──────────────────────────────────────────────────────────╯

-- Criar bucket importação de MIGO/MIRO
INSERT INTO storage.buckets (
  id,
  name,
  public,
  allowed_mime_types
)
VALUES
  ('po-migo-miro-imports', 'po-migo-miro-imports', FALSE, ARRAY['text/csv', 'application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'])
ON CONFLICT (id) DO NOTHING;

-- Regras de acesso para o bucket po-migo-miro-imports
CREATE POLICY storage_select_po_migo_miro_imports
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'po-migo-miro-imports'
  AND EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name IN ('admin', 'comprador')
      AND uac.is_active = true
      AND (storage.foldername(storage.objects.name))[1] = uac.company_id::text
  )
);

CREATE POLICY storage_insert_po_migo_miro_imports
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'po-migo-miro-imports'
  AND EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name IN ('admin', 'comprador')
      AND uac.is_active = true
      AND (storage.foldername(storage.objects.name))[1] = uac.company_id::text
  )
);


-- ╭─────────────────◉ CONTEXTO: Funções  ◉──────────────────╮
-- ┃                 Funções customizadas                     ┃
-- ╰──────────────────────────────────────────────────────────╯

-- Função para salvar return da lambda aws 'process_po_migo_miro_upload' na table 'order_item_migo_miro_imports' e atualizar 'order_items.status_id' que é fk para 'order_item_status.id', conforme as intruções:
-- receipt_date is empty = order_items.status_id 4 (Aguardando MIGO)
-- receipt_date isnot empty = order_items.status_id 5 (Aguardando MIRO)
-- invoice_date isnot empty = order_items.status_id 6 (Aguardando pagamento)
-- payment_date isnot empty = order_items.status_id 7 (Pagamento realizado)
-- importante: a função considera a seguinte ordem de importancia: payment_date, invoice_date, receipt_date. 
-- importante: se o 'order_items.status_id' (fk para order_item_status.id) possui 'order_item_status.is_final' = true o 'order_items.status_id' não é atualizado, apenas é salvo as informacoes na table 'order_item_migo_miro_imports'
CREATE OR REPLACE FUNCTION public.fn_process_migo_miro_imports(payload JSONB, token TEXT, owner_id TEXT)
RETURNS VOID
SECURITY DEFINER
SET search_path TO 'public', 'vault'
LANGUAGE plpgsql
AS $$
DECLARE
    expected_token TEXT;
    record JSONB;
    order_item_id_resolved BIGINT;
    current_status_id INT;
    is_final_status BOOLEAN;
    new_status_id INT;
    parsed_receipt_date DATE;
    parsed_invoice_date DATE;
    parsed_payment_date DATE;
    order_number_value TEXT;
    item_number_value BIGINT;
    v_total_records INT;
    v_processed_records INT := 0;
BEGIN
    -- Obter o segredo do Vault
    SELECT decrypted_secret INTO expected_token
    FROM vault.decrypted_secrets
    WHERE name = 'AWS_TOKEN';

    IF token IS DISTINCT FROM expected_token THEN
        RAISE EXCEPTION 'Acesso não autorizado à função fn_process_migo_miro_imports.';
    END IF;

    PERFORM set_config('request.user_id', owner_id::TEXT, true);

    -- Obter total de registros
    v_total_records := jsonb_array_length(payload);

    -- Verifica se os campos numero_pc e itmpc estão presentes em todos os registros
    FOR record IN SELECT * FROM jsonb_array_elements(payload)
    LOOP
        IF NOT (record ? 'numero_pc' AND record ? 'itmpc') THEN
            PERFORM private.fn_log_process_event(
                p_process_name  := 'migo_miro_upload',
                p_function_name := 'fn_process_migo_miro_imports',
                p_step          := 'validate_payload',
                p_status        := 'error',
                p_message       := format('Registro(s) no payload sem numero_pc ou itmpc para item (numero_pc: %s, itmpc: %s).',
                                          COALESCE(record->>'numero_pc', 'N/A'), 
                                          COALESCE(record->>'itmpc', 'N/A')),
                p_user_id       := owner_id::uuid,
                p_metadata      := record
            );
            RAISE EXCEPTION 'Algum registro no payload está sem numero_pc ou itmpc.';
        END IF;
    END LOOP;

    -- Processar cada registro do payload
    FOR record IN SELECT * FROM jsonb_array_elements(payload)
    LOOP
        -- Extrair valores do payload
        order_number_value := record->>'numero_pc';
        item_number_value := (record->>'itmpc')::BIGINT;

        -- Buscar o order_item_id usando order_number e item_number
        SELECT oi.id, oi.status_id, COALESCE(ois.is_final, false)
        INTO order_item_id_resolved, current_status_id, is_final_status
        FROM public.order_items oi
        INNER JOIN public.orders o ON oi.order_id = o.id
        LEFT JOIN public.order_item_status ois ON oi.status_id = ois.id
        WHERE o.order_number = order_number_value
          AND oi.item_number = item_number_value;

        -- Se order_item não existe, logar erro e continuar
        IF NOT FOUND THEN
            PERFORM private.fn_log_process_event(
                p_process_name  := 'migo_miro_upload',
                p_function_name := 'fn_process_migo_miro_imports',
                p_step          := 'validate_order_item',
                p_status        := 'error',
                p_message       := format('Order item não encontrado para (item: %s, número_pedido: %s)', 
                                        order_number_value, item_number_value),
                p_user_id       := owner_id::uuid,
                p_metadata      := record
            );
            CONTINUE;
        END IF;

        -- Fazer parsing das datas com segurança
        parsed_receipt_date := CASE
            WHEN record ? 'dt_recebimento'
                AND record->>'dt_recebimento' IS DISTINCT FROM 'null'
                AND record->>'dt_recebimento' <> ''
            THEN (LEFT(record->>'dt_recebimento', 10))::DATE + INTERVAL '1 day'
            ELSE NULL
        END;

        parsed_invoice_date := CASE
            WHEN record ? 'data_fatura'
                AND record->>'data_fatura' IS DISTINCT FROM 'null'
                AND record->>'data_fatura' <> ''
            THEN (LEFT(record->>'data_fatura', 10))::DATE + INTERVAL '1 day'
            ELSE NULL
        END;

        parsed_payment_date := CASE
            WHEN record ? 'data_pagto'
                AND record->>'data_pagto' IS DISTINCT FROM 'null'
                AND record->>'data_pagto' <> ''
            THEN (LEFT(record->>'data_pagto', 10))::DATE + INTERVAL '1 day'
            ELSE NULL
        END;

        -- Verificar se todas as quantidades foram entregues
        DECLARE
            all_fulfilled BOOLEAN;
            total_delivered NUMERIC;
            required_quantity NUMERIC;
            old_status_name TEXT;
            new_status_name TEXT;
        BEGIN
            SELECT 
                COALESCE(delivered.total_quantity >= items.quantity, FALSE) AS all_fulfilled,
                COALESCE(delivered.total_quantity, 0) AS total_delivered,
                items.quantity AS required_quantity
            INTO all_fulfilled, total_delivered, required_quantity
            FROM public.order_items items
            LEFT JOIN (
                SELECT order_item_id, SUM(quantity) AS total_quantity
                FROM public.order_item_invoices
                GROUP BY order_item_id
            ) delivered ON delivered.order_item_id = items.id
            WHERE items.id = order_item_id_resolved;

            -- Só salvar na tabela se todas as quantidades foram entregues
            IF all_fulfilled THEN
                -- Verificar se já existe registro para este order_item_id
                IF EXISTS (SELECT 1 FROM public.order_item_migo_miro_imports WHERE order_item_id = order_item_id_resolved) THEN
                    -- Atualizar registro existente
                    UPDATE public.order_item_migo_miro_imports
                    SET
                        receipt_date = CASE 
                            WHEN record ? 'dt_recebimento' THEN parsed_receipt_date 
                            ELSE receipt_date 
                        END,
                        invoice_date = CASE 
                            WHEN record ? 'data_fatura' THEN parsed_invoice_date 
                            ELSE invoice_date 
                        END,
                        payment_date = CASE 
                            WHEN record ? 'data_pagto' THEN parsed_payment_date 
                            ELSE payment_date 
                        END
                    WHERE order_item_id = order_item_id_resolved;
                ELSE
                    -- Inserir novo registro
                    INSERT INTO public.order_item_migo_miro_imports (
                        order_item_id,
                        receipt_date,
                        invoice_date,
                        payment_date
                    )
                    VALUES (
                        order_item_id_resolved,
                        parsed_receipt_date,
                        parsed_invoice_date,
                        parsed_payment_date
                    );
                END IF;

                -- Determinar novo status baseado na ordem de importância
                -- Ordem: payment_date > invoice_date > receipt_date
                IF parsed_payment_date IS NOT NULL THEN
                    new_status_id := 7; -- Pagamento realizado
                ELSIF parsed_invoice_date IS NOT NULL THEN
                    new_status_id := 6; -- Aguardando pagamento
                ELSIF parsed_receipt_date IS NOT NULL THEN
                    new_status_id := 5; -- Aguardando MIRO
                ELSE
                    new_status_id := 4; -- Aguardando MIGO
                END IF;

                -- Buscar nomes dos status
                SELECT name INTO old_status_name
                FROM public.order_item_status
                WHERE id = current_status_id;

                SELECT name INTO new_status_name
                FROM public.order_item_status
                WHERE id = new_status_id;

                -- Atualizar status do order_item apenas se não for status final
                IF NOT is_final_status THEN
                    UPDATE public.order_items
                    SET status_id = new_status_id
                    WHERE id = order_item_id_resolved;

                    PERFORM private.fn_log_process_event(
                        p_process_name  := 'migo_miro_upload',
                        p_function_name := 'fn_process_migo_miro_imports',
                        p_step          := 'update_status',
                        p_status        := 'success',
                        p_message       := format('Status do order_item %s atualizado de "%s" para "%s" (item: %s, número_pedido: %s).', 
                                                order_item_id_resolved, COALESCE(old_status_name, current_status_id::TEXT), COALESCE(new_status_name, new_status_id::TEXT), 
                                                order_number_value, item_number_value),
                        p_user_id       := owner_id::uuid,
                        p_metadata      := jsonb_build_object(
                            'order_item_id', order_item_id_resolved,
                            'numero_pc', order_number_value,
                            'itmpc', item_number_value,
                            'old_status_id', current_status_id,
                            'new_status_id', new_status_id,
                            'receipt_date', parsed_receipt_date,
                            'invoice_date', parsed_invoice_date,
                            'payment_date', parsed_payment_date
                        )
                    );
                ELSE
                    PERFORM private.fn_log_process_event(
                        p_process_name  := 'migo_miro_upload',
                        p_function_name := 'fn_process_migo_miro_imports',
                        p_step          := 'skip_final_status',
                        p_status        := 'info',
                        p_message       := format('Status do order_item %s não foi atualizado pois já está em status final (item: %s, número_pedido: %s).', 
                                                order_item_id_resolved, order_number_value, item_number_value),
                        p_user_id       := owner_id::uuid,
                        p_metadata      := jsonb_build_object(
                            'order_item_id', order_item_id_resolved,
                            'numero_pc', order_number_value,
                            'itmpc', item_number_value,
                            'current_status_id', current_status_id,
                            'is_final_status', is_final_status
                        )
                    );
                END IF;
            ELSE
                -- Log para itens que não foram salvos por não terem todas as unidades entregues
                PERFORM private.fn_log_process_event(
                    p_process_name  := 'migo_miro_upload',
                    p_function_name := 'fn_process_migo_miro_imports',
                    p_step          := 'skip_incomplete_delivery',
                    p_status        := 'error',
                    p_message       := format('Não foi salvo pois não tem todas as unidades entregues (item: %s, número_pedido: %s).', 
                                            order_item_id_resolved, order_number_value, item_number_value),
                    p_user_id       := owner_id::uuid,
                    p_metadata      := jsonb_build_object(
                        'order_item_id', order_item_id_resolved,
                        'numero_pc', order_number_value,
                        'itmpc', item_number_value,
                        'total_delivered', total_delivered,
                        'required_quantity', required_quantity,
                        'receipt_date', parsed_receipt_date,
                        'invoice_date', parsed_invoice_date,
                        'payment_date', parsed_payment_date
                    )
                );
            END IF;
        END;

        -- Incrementar contador de registros processados
        v_processed_records := v_processed_records + 1;
    END LOOP;

    -- Log de sucesso final
    PERFORM private.fn_log_process_event(
        p_process_name  := 'migo_miro_upload',
        p_function_name := 'fn_process_migo_miro_imports',
        p_step          := 'process_batch',
        p_status        := 'success',
        p_message       := format('Lote de %s itens teve %s itens processados com sucesso.',
                                 v_total_records, v_processed_records),
        p_user_id       := owner_id::uuid,
        p_metadata      := jsonb_build_object(
            'total_registros', v_total_records,
            'registros_processados', v_processed_records
        )
    );

END;
$$;