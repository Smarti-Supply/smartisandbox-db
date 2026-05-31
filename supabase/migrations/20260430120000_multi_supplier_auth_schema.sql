-- Multi-supplier auth: UAC multi-row per supplier, supplier_users N:N (auth_user_id + contact),
-- backfill same-email contacts, generated cnpj_root on suppliers.
-- Does not replace app functions/views (see 20260430120100_multi_supplier_auth_functions_views.sql).

-- ═══════════════════════════════════════════════════════════════════════════
-- 1) private.user_access_cache: surrogate PK, allow multiple rows per fornecedor
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE private.user_access_cache
  ADD COLUMN IF NOT EXISTS id BIGSERIAL;

-- Fill ids for existing rows (bigserial auto-fills on insert; backfill sequence)
SELECT setval(
  pg_get_serial_sequence('private.user_access_cache', 'id'),
  COALESCE((SELECT MAX(id) FROM private.user_access_cache), 1)
);

ALTER TABLE private.user_access_cache DROP CONSTRAINT IF EXISTS user_access_cache_pkey;

ALTER TABLE private.user_access_cache ADD PRIMARY KEY (id);

-- Original schema already had this FK name on user_id; dropping PK leaves it. Recreate explicitly.
ALTER TABLE private.user_access_cache
  DROP CONSTRAINT IF EXISTS user_access_cache_user_id_fkey;

ALTER TABLE private.user_access_cache
  ADD CONSTRAINT user_access_cache_user_id_fkey
  FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

CREATE UNIQUE INDEX IF NOT EXISTS uq_user_access_cache_one_internal_user
  ON private.user_access_cache (user_id)
  WHERE role_name IN ('admin', 'comprador');

CREATE UNIQUE INDEX IF NOT EXISTS uq_user_access_cache_supplier_scope
  ON private.user_access_cache (user_id, supplier_id)
  WHERE role_name = 'fornecedor' AND supplier_id IS NOT NULL;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2) public.supplier_users: surrogate PK + auth_user_id (N:N with contacts)
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE public.supplier_users RENAME TO supplier_users_legacy;

CREATE TABLE public.supplier_users (
  id BIGSERIAL PRIMARY KEY,
  auth_user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  supplier_contact_id BIGINT NOT NULL REFERENCES public.supplier_contacts(id) ON DELETE CASCADE,
  role_id INT NOT NULL REFERENCES public.user_roles(id) ON DELETE RESTRICT,
  last_login TIMESTAMP NULL,
  last_magic_link_requested_at TIMESTAMPTZ NULL,
  CONSTRAINT uq_supplier_users_auth_contact UNIQUE (auth_user_id, supplier_contact_id)
);

INSERT INTO public.supplier_users (
  auth_user_id,
  supplier_contact_id,
  role_id,
  last_login,
  last_magic_link_requested_at
)
SELECT
  sul.id,
  sul.supplier_contact_id,
  sul.role_id,
  sul.last_login,
  sul.last_magic_link_requested_at
FROM public.supplier_users_legacy sul;

-- Same email across suppliers: add missing links for existing auth users
INSERT INTO public.supplier_users (
  auth_user_id,
  supplier_contact_id,
  role_id,
  last_login,
  last_magic_link_requested_at
)
SELECT DISTINCT
  su.auth_user_id,
  sc_extra.id,
  su.role_id,
  su.last_login,
  su.last_magic_link_requested_at
FROM public.supplier_users su
JOIN auth.users au ON au.id = su.auth_user_id
JOIN public.supplier_contacts sc_extra
  ON lower(trim(sc_extra.email)) = lower(trim(au.email))
 AND sc_extra.is_active = true
WHERE NOT EXISTS (
  SELECT 1
  FROM public.supplier_users x
  WHERE x.auth_user_id = su.auth_user_id
    AND x.supplier_contact_id = sc_extra.id
);

DROP TABLE public.supplier_users_legacy CASCADE;

CREATE INDEX IF NOT EXISTS idx_supplier_users_auth_user_id
  ON public.supplier_users (auth_user_id);

CREATE INDEX IF NOT EXISTS idx_supplier_users_supplier_contact_id
  ON public.supplier_users (supplier_contact_id);

-- ═══════════════════════════════════════════════════════════════════════════
-- 3) UAC: insert one row per (auth user, supplier) for new supplier_user links
-- ═══════════════════════════════════════════════════════════════════════════

INSERT INTO private.user_access_cache (
  user_id,
  role_id,
  role_name,
  company_id,
  supplier_id,
  is_active,
  last_synced_at
)
SELECT
  su.auth_user_id,
  su.role_id,
  'fornecedor'::text,
  s.company_id,
  sc.supplier_id,
  sc.is_active,
  now()
FROM public.supplier_users su
JOIN public.supplier_contacts sc ON sc.id = su.supplier_contact_id
JOIN public.suppliers s ON s.id = sc.supplier_id
WHERE NOT EXISTS (
  SELECT 1
  FROM private.user_access_cache uac
  WHERE uac.user_id = su.auth_user_id
    AND uac.role_name = 'fornecedor'
    AND uac.supplier_id = sc.supplier_id
);

-- ═══════════════════════════════════════════════════════════════════════════
-- 4) suppliers.cnpj_root (UI / filter only; 8 digits after stripping non-digits)
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE public.suppliers
  ADD COLUMN IF NOT EXISTS cnpj_root text
  GENERATED ALWAYS AS (
    CASE
      WHEN length(regexp_replace(cnpj::text, '\D', '', 'g')) >= 8
      THEN left(regexp_replace(cnpj::text, '\D', '', 'g'), 8)
      ELSE NULL::text
    END
  ) STORED;

CREATE INDEX IF NOT EXISTS idx_suppliers_cnpj_root ON public.suppliers (cnpj_root);

-- ═══════════════════════════════════════════════════════════════════════════
-- supplier_users RLS (table recreated above; policies from 20250218125702 do not carry over)
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE public.supplier_users ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS supplier_self_can_select_own_supplier_users ON public.supplier_users;
CREATE POLICY supplier_self_can_select_own_supplier_users
ON public.supplier_users
FOR SELECT
TO authenticated
USING (auth_user_id = (select auth.uid()));

DROP POLICY IF EXISTS supplier_self_can_update_own_supplier_users ON public.supplier_users;
CREATE POLICY supplier_self_can_update_own_supplier_users
ON public.supplier_users
FOR UPDATE
TO authenticated
USING (auth_user_id = (select auth.uid()))
WITH CHECK (auth_user_id = (select auth.uid()));

DROP POLICY IF EXISTS client_admins_can_read_own_supplier_users ON public.supplier_users;
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

DROP POLICY IF EXISTS client_buyers_can_read_own_supplier_users ON public.supplier_users;
CREATE POLICY client_buyers_can_read_own_supplier_users
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
      AND uac.role_name = 'comprador'
      AND uac.is_active = true
      AND s.company_id = uac.company_id
  )
);

DROP POLICY IF EXISTS client_admins_can_insert_supplier_users ON public.supplier_users;
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

DROP POLICY IF EXISTS client_admin_can_update_own_supplier_users ON public.supplier_users;
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

DROP POLICY IF EXISTS client_admin_can_delete_own_supplier_users ON public.supplier_users;
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

DROP POLICY IF EXISTS superadmins_can_manage_all_supplier_users ON public.supplier_users;
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


-- ═══════════════════════════════════════════════════════════════════════════
-- Scope materialization for view_orders_filtered_by_user (added 2026-05-29)
-- ═══════════════════════════════════════════════════════════════════════════
-- Materializa o conjunto (comprador company_user, supplier) derivado das
-- regras supplier_letter + supplier_id em company_users. Substitui o parsing
-- per-row de string_to_array() na view_orders_filtered_by_user, que era
-- responsável por ~15% do tempo total de queries PostgREST.
--
-- Semântica (preservada do WHERE original da view): para um comprador `cu`,
-- um supplier `s` está no scope se:
--   1. cu.supplier_id IS NOT NULL AND s.id = cu.supplier_id (claim direto)
--   2. cu.supplier_id IS NULL AND letter de cu.supplier_letter casa com
--      LEFT(s.name, 1), AND s não está claimed por outro company_user na
--      mesma company
--   3. cu.supplier_id IS NULL AND '#' em cu.supplier_letter AND
--      LEFT(s.name, 1) ~ '^[0-9]', AND s não está claimed
--
-- Admins não são populados aqui (a view trata a role 'admin' por branch
-- separado). Fornecedores não usam esta tabela.
--
-- A tabela é mantida por triggers definidas em
-- 20260430120100_multi_supplier_auth_functions_views.sql.

CREATE TABLE IF NOT EXISTS private.company_user_supplier_scope (
  company_user_id UUID NOT NULL
    REFERENCES public.company_users(id) ON DELETE CASCADE,
  supplier_id BIGINT NOT NULL
    REFERENCES public.suppliers(id) ON DELETE CASCADE,
  PRIMARY KEY (company_user_id, supplier_id)
);

CREATE INDEX IF NOT EXISTS idx_cuss_company_user
  ON private.company_user_supplier_scope (company_user_id);

CREATE INDEX IF NOT EXISTS idx_cuss_supplier
  ON private.company_user_supplier_scope (supplier_id);

COMMENT ON TABLE private.company_user_supplier_scope IS
  'Materialized scope of (comprador company_user, supplier) pairs derived from company_users.supplier_letter + supplier_id rules. Refreshed by triggers on company_users and suppliers.';

-- Permissions: schema private não é exposto via PostgREST, mas damos GRANT
-- SELECT para authenticated porque a view view_orders_filtered_by_user usa
-- security_invoker = true e precisa ler como o caller.
REVOKE ALL ON TABLE private.company_user_supplier_scope FROM PUBLIC;
GRANT SELECT ON TABLE private.company_user_supplier_scope TO authenticated;

-- RLS: a proteção real vem do schema private + GRANT acima. A policy
-- USING (true) silencia o advisor do Supabase e formaliza que authenticated
-- pode ler qualquer linha (a view filtra por cu.id = auth.uid() antes do
-- EXISTS no scope, então não há vazamento).
ALTER TABLE private.company_user_supplier_scope ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS allow_authenticated_read_scope
  ON private.company_user_supplier_scope;
CREATE POLICY allow_authenticated_read_scope
  ON private.company_user_supplier_scope
  FOR SELECT TO authenticated
  USING (true);
