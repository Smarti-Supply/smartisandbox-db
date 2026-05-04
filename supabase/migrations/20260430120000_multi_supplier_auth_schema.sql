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
