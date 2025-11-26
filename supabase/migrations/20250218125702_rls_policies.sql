-- ╭────────────────────────────────────────────────────────────────────╮
-- ┃                              RLS                                   ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Habilitar RLS para as tabelas
ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.company_plans ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.super_admins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.companies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.company_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_contacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.supplier_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_item_status ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.default_order_status ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_and_item_observations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_item_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_item_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.order_notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.followup_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.followup_suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.followup_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.company_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.import_field_mappings ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.process_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.user_access_cache ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.followup_queue ENABLE ROW LEVEL SECURITY;
ALTER TABLE private.followup_item_tracking ENABLE ROW LEVEL SECURITY;

-- Criar politicas de RLS

-- Política de acesso para tabela de super admins
CREATE POLICY allow_authenticated_to_check_if_super_admin
ON private.super_admins
FOR SELECT
TO authenticated
USING (true);

GRANT SELECT ON private.super_admins TO authenticated;

-- Política de acesso para tabela de UAC
CREATE POLICY user_can_read_own_access_cache
ON private.user_access_cache
FOR SELECT 
TO authenticated
USING (auth.uid() = user_id AND is_active);

GRANT SELECT ON private.user_access_cache TO authenticated;

-- Política de acesso para tabela de logs de processos
CREATE POLICY user_can_see_own_logs
ON private.process_logs
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name IN ('admin', 'comprador')
      AND uac.is_active = true
  )
);

GRANT SELECT ON private.process_logs TO authenticated;

-- Política de acesso para tabela de followup queue
CREATE POLICY user_can_see_followup_queue
ON private.followup_queue
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name IN ('admin', 'comprador')
      AND uac.is_active = true
  )
);

GRANT SELECT ON private.followup_queue TO authenticated;

-- Política de acesso para tabela de followup item tracking
CREATE POLICY user_can_see_followup_item_tracking
ON private.followup_item_tracking
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name IN ('admin', 'comprador')
      AND uac.is_active = true
  )
);

GRANT SELECT ON private.followup_item_tracking TO authenticated;


-- Política de acesso para tabela de funções de clientes
CREATE POLICY users_can_read_user_roles
ON public.user_roles
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.is_active = true
  )
);

CREATE POLICY superadmins_can_manage_user_roles
ON public.user_roles
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

-- Política de acesso para tabela de planos de clientes
CREATE POLICY client_admins_can_read_active_plans
ON public.company_plans
FOR SELECT
TO authenticated
USING (
  is_active = TRUE
  AND EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = TRUE
  )
);

CREATE POLICY superadmins_can_read_all_plans
ON public.company_plans
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM private.super_admins sa
    WHERE sa.id = (select auth.uid())
  )
);


-- Política de acesso para tabela de empresas
CREATE POLICY company_users_can_read_own_company
ON public.companies
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.is_active = TRUE
      AND uac.role_name IN ('admin', 'comprador')
      AND uac.company_id = companies.id
  )
);

CREATE POLICY client_admin_can_insert_company
ON public.companies
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
  )
  AND NOT EXISTS (
    SELECT 1
    FROM public.companies c
    WHERE c.created_by = (select auth.uid())
  )
  AND NOT EXISTS (
    SELECT 1
    FROM public.company_users cu
    WHERE cu.id = (select auth.uid()) AND cu.company_id IS NOT NULL
  )
);

CREATE POLICY client_admin_can_update_own_company
ON public.companies
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND uac.company_id = companies.id
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND uac.company_id = companies.id
  )
);

CREATE POLICY client_admin_cant_delete_own_company
ON public.companies
FOR DELETE
TO authenticated
USING (FALSE); -- Bloqueia deleção por clientes

CREATE POLICY superadmins_can_manage_all_companies
ON public.companies
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

-- Política de acesso para tabela de usuários de empresas
CREATE POLICY client_admins_and_buyers_can_read_own_company_users
ON public.company_users
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name IN ('admin', 'comprador')
      AND uac.is_active = true
      AND uac.company_id = company_users.company_id
  )
);

CREATE POLICY client_admin_can_insert_users
ON public.company_users
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND uac.company_id = company_users.company_id
  )
);

CREATE POLICY client_admin_can_update_own_company_users
ON public.company_users
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND uac.company_id = company_users.company_id
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND uac.company_id = company_users.company_id
  )
);


CREATE POLICY client_admin_can_delete_own_company_users
ON public.company_users
FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND uac.company_id = company_users.company_id
  )
);

CREATE POLICY superadmins_can_manage_all_company_users
ON public.company_users
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

-- Política de acesso para tabela de usuários de fornecedores
CREATE POLICY client_admins_can_read_own_supplier_users
ON public.supplier_users
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.supplier_contacts sc ON sc.id = supplier_users.supplier_contact_id
    JOIN public.suppliers s ON sc.supplier_id = s.id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND s.company_id = uac.company_id
  )
);

CREATE POLICY client_admins_can_insert_supplier_users
ON public.supplier_users
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.supplier_contacts sc ON sc.id = supplier_users.supplier_contact_id
    JOIN public.suppliers s ON s.id = sc.supplier_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND s.company_id = uac.company_id
  )
);

CREATE POLICY client_admin_can_update_own_supplier_users
ON public.supplier_users
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.supplier_contacts sc ON sc.id = supplier_users.supplier_contact_id
    JOIN public.suppliers s ON sc.supplier_id = s.id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND s.company_id = uac.company_id
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.supplier_contacts sc ON sc.id = supplier_users.supplier_contact_id
    JOIN public.suppliers s ON sc.supplier_id = s.id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND s.company_id = uac.company_id
  )
);

CREATE POLICY client_admin_can_delete_own_supplier_users
ON public.supplier_users
FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.supplier_contacts sc ON sc.id = supplier_users.supplier_contact_id
    JOIN public.suppliers s ON sc.supplier_id = s.id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND s.company_id = uac.company_id
  )
);

CREATE POLICY superadmins_can_manage_all_supplier_users
ON public.supplier_users
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

-- Política de acesso para tabela de fornecedores
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
          AND suppliers.id = uac.supplier_id
        )
      )
  )
);

CREATE POLICY admin_can_insert_supplier
ON public.suppliers
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND uac.company_id = suppliers.company_id
  )
);

CREATE POLICY admin_can_update_supplier
ON public.suppliers
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND uac.company_id = suppliers.company_id
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND uac.company_id = suppliers.company_id
  )
);

CREATE POLICY admin_can_delete_supplier
ON public.suppliers
FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND uac.company_id = suppliers.company_id
  )
);

CREATE POLICY superadmins_can_manage_all_suppliers
ON public.suppliers
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

-- Política de acesso para tabela de usuários de fornecedores
CREATE POLICY company_users_can_read_supplier_contacts
ON public.supplier_contacts
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.suppliers s ON s.id = supplier_contacts.supplier_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name IN ('admin', 'comprador')
      AND uac.is_active = true
      AND s.company_id = uac.company_id
  )
);

CREATE POLICY company_admin_can_insert_supplier_contacts
ON public.supplier_contacts
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.suppliers s ON s.id = supplier_contacts.supplier_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND s.company_id = uac.company_id
  )
);

CREATE POLICY company_admin_can_update_supplier_contacts
ON public.supplier_contacts
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.suppliers s ON s.id = supplier_contacts.supplier_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND s.company_id = uac.company_id
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.suppliers s ON s.id = supplier_contacts.supplier_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND s.company_id = uac.company_id
  )
);

CREATE POLICY company_admin_can_delete_supplier_contacts
ON public.supplier_contacts
FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.suppliers s ON s.id = supplier_contacts.supplier_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND s.company_id = uac.company_id
  )
);

CREATE POLICY superadmins_can_manage_all_supplier_contacts
ON public.supplier_contacts
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

-- Política de acesso para tabela de status de pedidos
CREATE POLICY company_or_supplier_can_read_order_item_status
ON public.order_item_status
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
        -- Acesso direto por admin ou comprador da empresa
        (uac.role_name IN ('admin', 'comprador') AND uac.company_id = order_item_status.company_id)

        -- Acesso por fornecedor se o status for visível e ele atender essa empresa
        OR (
          uac.role_name = 'fornecedor'
          AND uac.company_id = order_item_status.company_id
          AND order_item_status.expose_to_supplier = true
        )
      )
  )
);

CREATE POLICY company_admin_can_insert_order_item_status
ON public.order_item_status
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND uac.company_id = order_item_status.company_id
  )
);

CREATE POLICY company_admin_can_update_own_order_item_status
ON public.order_item_status
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND uac.company_id = order_item_status.company_id
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND uac.company_id = order_item_status.company_id
  )
);

CREATE POLICY company_admin_can_delete_own_order_item_status
ON public.order_item_status
FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND uac.company_id = order_item_status.company_id
  )
);

CREATE POLICY superadmins_can_manage_all_order_item_status
ON public.order_item_status
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

-- Política de acesso para tabela de status padrão de pedidos
CREATE POLICY allow_read_default_order_status
ON public.default_order_status
FOR SELECT
TO authenticated
USING (TRUE);

-- Política de acesso para tabela de pedidos
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
        OR (uac.role_name = 'fornecedor' AND orders.supplier_id = uac.supplier_id)
      )
  )
);

CREATE POLICY company_admin_can_insert_orders
ON public.orders
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND uac.company_id = orders.company_id
  )
);

CREATE POLICY company_admin_can_update_own_orders
ON public.orders
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name IN ('admin', 'comprador')
      AND uac.is_active = true
      AND uac.company_id = orders.company_id
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name IN ('admin', 'comprador')
      AND uac.is_active = true
      AND uac.company_id = orders.company_id
  )
);

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
      AND orders.supplier_id = uac.supplier_id
  )
)
WITH CHECK (
  orders.status_id IS NOT NULL
);

CREATE POLICY company_admin_can_delete_own_orders
ON public.orders
FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND uac.company_id = orders.company_id
  )
);

CREATE POLICY superadmins_can_manage_all_orders
ON public.orders
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

-- Política de acesso para tabela de itens de pedidos
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
        OR (uac.role_name = 'fornecedor' AND o.supplier_id = uac.supplier_id)
      )
  )
);

CREATE POLICY company_admin_can_insert_order_items
ON public.order_items
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.orders o ON o.id = order_items.order_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND o.company_id = uac.company_id
  )
);

CREATE POLICY company_users_can_update_own_order_items
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
      AND uac.role_name IN ('admin', 'comprador')
      AND o.company_id = uac.company_id
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.orders o ON o.id = order_items.order_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.is_active = true
      AND uac.role_name IN ('admin', 'comprador')
      AND o.company_id = uac.company_id
  )
);

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
      AND o.supplier_id = uac.supplier_id
  )
)
WITH CHECK (
  -- Só pode alterar current_delivery_date ou status_id
  order_items.current_delivery_date IS NOT NULL
  OR order_items.status_id IS NOT NULL
);

CREATE POLICY company_admin_can_delete_own_order_items
ON public.order_items
FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.orders o ON o.id = order_items.order_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND o.company_id = uac.company_id
  )
);

CREATE POLICY superadmins_can_manage_all_order_items
ON public.order_items
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

-- Política de acesso para tabela de observações de itens de pedidos
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
        OR (uac.role_name = 'fornecedor' AND o.supplier_id = uac.supplier_id)
      )
  )
);

CREATE POLICY insert_by_company_users
ON public.order_and_item_observations
FOR INSERT
TO authenticated
WITH CHECK (
  -- Vínculo com empresa e permissão
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.orders o ON o.id = order_and_item_observations.order_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.is_active
      AND uac.role_name IN ('admin', 'comprador')
      AND o.company_id = uac.company_id
  )
  -- Validar autoria
  AND order_and_item_observations.created_by = (select auth.uid())
  -- Só pode preencher observações de usuário
  AND order_and_item_observations.user_observations IS NOT NULL
  AND order_and_item_observations.supplier_observations IS NULL
);

CREATE POLICY insert_by_suppliers
ON public.order_and_item_observations
FOR INSERT
TO authenticated
WITH CHECK (
  -- Vínculo com pedido e supplier_id
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.orders o ON o.id = order_and_item_observations.order_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.is_active
      AND uac.role_name = 'fornecedor'
      AND o.supplier_id = uac.supplier_id
  )
  -- Validar autoria
  AND order_and_item_observations.created_by = (select auth.uid())
  -- Só pode preencher observações de fornecedor
  AND order_and_item_observations.supplier_observations IS NOT NULL
  AND order_and_item_observations.user_observations IS NULL
);

CREATE POLICY update_user_observations_by_company_users
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
      AND uac.role_name IN ('admin', 'comprador')
      AND o.company_id = uac.company_id
  )
  AND order_and_item_observations.created_by = (select auth.uid())
)
WITH CHECK (
  -- Permite modificar apenas a parte que eles podem
  user_observations IS NOT NULL
);

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
      AND o.supplier_id = uac.supplier_id
  )
  AND order_and_item_observations.created_by = (select auth.uid())
)
WITH CHECK (
  supplier_observations IS NOT NULL
);

CREATE POLICY company_admin_can_delete_observations
ON public.order_and_item_observations
FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.orders o ON o.id = order_and_item_observations.order_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND o.company_id = uac.company_id
  )
  OR created_by = (select auth.uid())
);

CREATE POLICY superadmins_can_manage_all_observations
ON public.order_and_item_observations
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

-- Política de acesso para tabela de faturas de itens de pedidos
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
        OR (uac.role_name = 'fornecedor' AND o.supplier_id = uac.supplier_id)
      )
  )
);

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
      AND o.supplier_id = uac.supplier_id
  )
  AND order_item_invoices.created_by = (select auth.uid())
);

CREATE POLICY insert_by_company_users
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
      AND uac.role_name IN ('admin', 'comprador')
      AND o.company_id = uac.company_id
  )
  AND order_item_invoices.created_by = (select auth.uid())
);

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
      AND o.supplier_id = uac.supplier_id
  )
  AND order_item_invoices.created_by = (select auth.uid())
);

CREATE POLICY superadmins_can_manage_all_order_item_invoices
ON public.order_item_invoices
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

-- Política de acesso para tabela de logs de pedidos
CREATE POLICY company_users_can_read_own_order_logs
ON public.order_logs
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.orders o ON o.id = order_logs.order_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.is_active = true
      AND uac.role_name IN ('admin', 'comprador')
      AND o.company_id = uac.company_id
  )
);

CREATE POLICY superadmins_can_manage_all_order_logs
ON public.order_logs
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

-- Política de acesso para tabela de logs de pedidos
CREATE POLICY company_users_can_read_order_notifications
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
      AND uac.role_name IN ('admin', 'comprador')
      AND o.company_id = uac.company_id
  )
);

CREATE POLICY company_users_can_update_order_notifications
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
      AND uac.role_name IN ('admin', 'comprador')
      AND o.company_id = uac.company_id
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
      AND uac.role_name IN ('admin', 'comprador')
      AND o.company_id = uac.company_id
  )
);

CREATE POLICY company_users_can_delete_order_notifications
ON public.order_notifications
FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.orders o ON o.id = order_notifications.order_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.is_active = true
      AND o.company_id = uac.company_id
      AND (
        uac.role_name = 'admin'
        OR (
          uac.role_name = 'comprador'
          AND order_notifications.read_by = (select auth.uid())
        )
      )
  )
);

CREATE POLICY superadmins_can_manage_all_order_notifications
ON public.order_notifications
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

-- Política de acesso para fornecedores lerem notificações do comprador
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
      AND o.supplier_id = uac.supplier_id
      -- Só pode ver notificações do comprador (client_*)
      AND order_notifications.type IN ('client_observation', 'client_status_change', 'client_item_change')
  )
);

-- Política de acesso para fornecedores atualizarem notificações (marcar como lida)
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
      AND o.supplier_id = uac.supplier_id
      -- Só pode atualizar notificações do comprador (client_*)
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
      AND o.supplier_id = uac.supplier_id
      -- Só pode atualizar notificações do comprador (client_*)
      AND order_notifications.type IN ('client_observation', 'client_status_change', 'client_item_change')
  )
);

-- Política de acesso para tabela de logs de itens de pedidos
CREATE POLICY company_users_can_read_own_order_item_logs
ON public.order_item_logs
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.orders o ON o.company_id = uac.company_id
    JOIN public.order_items oi ON oi.order_id = o.id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name IN ('admin', 'comprador')
      AND uac.is_active = true
      AND oi.id = order_item_logs.order_item_id
  )
);

CREATE POLICY superadmins_can_manage_all_order_item_logs
ON public.order_item_logs
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

-- Política de acesso para tabela de configurações de follow-up
CREATE POLICY company_users_can_read_own_followup_settings
ON public.followup_settings
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name IN ('admin', 'comprador')
      AND uac.is_active = true
      AND uac.company_id = followup_settings.company_id
  )
);

CREATE POLICY admins_can_insert_followup_settings
ON public.followup_settings
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND uac.company_id = followup_settings.company_id
  )
);

CREATE POLICY admins_can_update_own_followup_settings
ON public.followup_settings
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND uac.company_id = followup_settings.company_id
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND uac.company_id = followup_settings.company_id
  )
);

CREATE POLICY admins_can_delete_own_followup_settings
ON public.followup_settings
FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND uac.company_id = followup_settings.company_id
  )
);

CREATE POLICY superadmins_can_manage_all_followup_settings
ON public.followup_settings
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

-- Política de acesso para tabela de associação de regras de follow-up
CREATE POLICY company_users_can_read_own_followup_suppliers
ON public.followup_suppliers
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.followup_settings fs ON fs.id = followup_suppliers.followup_setting_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name IN ('admin', 'comprador')
      AND uac.is_active = true
      AND fs.company_id = uac.company_id
  )
);

CREATE POLICY admins_can_insert_followup_suppliers
ON public.followup_suppliers
FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.followup_settings fs ON fs.id = followup_suppliers.followup_setting_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND fs.company_id = uac.company_id
  )
);

CREATE POLICY admins_can_update_own_followup_suppliers
ON public.followup_suppliers
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.followup_settings fs ON fs.id = followup_suppliers.followup_setting_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND fs.company_id = uac.company_id
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.followup_settings fs ON fs.id = followup_suppliers.followup_setting_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND fs.company_id = uac.company_id
  )
);

CREATE POLICY admins_can_delete_own_followup_suppliers
ON public.followup_suppliers
FOR DELETE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    JOIN public.followup_settings fs ON fs.id = followup_suppliers.followup_setting_id
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND fs.company_id = uac.company_id
  )
);

CREATE POLICY superadmins_can_manage_all_followup_suppliers
ON public.followup_suppliers
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

-- Política de acesso para tabela de logs de follow-up
CREATE POLICY company_users_can_read_own_followup_logs
ON public.followup_logs
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name IN ('admin', 'comprador')
      AND uac.is_active = true
      AND uac.company_id = followup_logs.company_id
  )
);

CREATE POLICY superadmins_can_manage_all_followup_logs
ON public.followup_logs
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

-- Política de acesso para tabela de faturas de clientes
CREATE POLICY admins_can_read_own_invoices
ON public.company_invoices
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND uac.company_id = company_invoices.company_id
  )
);

CREATE POLICY superadmins_can_manage_all_company_invoices
ON public.company_invoices
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

-- Política de acesso para tabela de mapeamentos de campos de importação
CREATE POLICY admin_can_read_own_field_mapping
ON public.import_field_mappings
FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND uac.company_id = import_field_mappings.company_id
  )
);

CREATE POLICY admin_can_update_own_field_mapping
ON public.import_field_mappings
FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND uac.company_id = import_field_mappings.company_id
  )
)
WITH CHECK (
  EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'admin'
      AND uac.is_active = true
      AND uac.company_id = import_field_mappings.company_id
  )
);

CREATE POLICY admin_cant_delete_field_mapping
ON public.import_field_mappings
FOR DELETE
TO authenticated
USING (FALSE);

CREATE POLICY superadmin_can_manage_all_field_mappings
ON public.import_field_mappings
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