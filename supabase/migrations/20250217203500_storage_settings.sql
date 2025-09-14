-- ╭────────────────────────────────────────────────────────────────────╮
-- ┃                             Storage                                ┃
-- ╰────────────────────────────────────────────────────────────────────╯
-- Criar bucket importação de pedidos
INSERT INTO storage.buckets (
  id,
  name,
  public,
  allowed_mime_types
)
VALUES
  ('po-imports', 'po-imports', FALSE, ARRAY['text/csv', 'application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet']),
  ('supplier-imports', 'supplier-imports', FALSE, ARRAY['text/csv', 'application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet']),
  ('po-files-imports', 'po-files-imports', FALSE, ARRAY['application/pdf', 'application/zip', 'application/x-zip-compressed']),
  ('po-files', 'po-files', FALSE, ARRAY['application/pdf']),
  ('po-nfe-files', 'po-nfe-files', FALSE, ARRAY['application/pdf'])
ON CONFLICT (id) DO NOTHING;


-- ╭───────────────────────◉ CONTEXTO: RLS ◉───────────────────────────╮
-- ┃              Bucket po-imports ('admin', 'comprador')              ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Regras de acesso para o bucket po-imports
CREATE POLICY storage_select_po_imports
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'po-imports'
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

CREATE POLICY storage_insert_po_imports
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'po-imports'
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

CREATE POLICY storage_update_po_imports
ON storage.objects
FOR UPDATE
TO authenticated
USING (
  bucket_id = 'po-imports'
  AND EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name IN ('admin', 'comprador')
      AND uac.is_active = true
      AND (storage.foldername(storage.objects.name))[1] = uac.company_id::text
  )
)
WITH CHECK (
  bucket_id = 'po-imports'
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

CREATE POLICY storage_delete_po_imports
ON storage.objects
FOR DELETE
TO authenticated
USING (
  bucket_id = 'po-imports'
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


-- ╭───────────────────────◉ CONTEXTO: RLS ◉───────────────────────────╮
-- ┃          Bucket supplier-imports ('admin', 'comprador')            ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Regras de acesso para o bucket supplier-imports
CREATE POLICY storage_select_imports
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'supplier-imports'
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

CREATE POLICY storage_insert_supplier_imports
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'supplier-imports'
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

CREATE POLICY storage_update_supplier_imports
ON storage.objects
FOR UPDATE
TO authenticated
USING (
  bucket_id = 'supplier-imports'
  AND EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name IN ('admin', 'comprador')
      AND uac.is_active = true
      AND (storage.foldername(storage.objects.name))[1] = uac.company_id::text
  )
)
WITH CHECK (
  bucket_id = 'supplier-imports'
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

CREATE POLICY storage_delete_supplier_imports
ON storage.objects
FOR DELETE
TO authenticated
USING (
  bucket_id = 'supplier-imports'
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


-- ╭───────────────────────◉ CONTEXTO: RLS ◉───────────────────────────╮
-- ┃              Bucket po-files ('admin', 'comprador')                ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Regras de acesso para o bucket po-files
CREATE POLICY storage_select_po_files
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'po-files'
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

CREATE POLICY storage_insert_po_files
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'po-files'
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

CREATE POLICY storage_update_po_files
ON storage.objects
FOR UPDATE
TO authenticated
USING (
  bucket_id = 'po-files'
  AND EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name IN ('admin', 'comprador')
      AND uac.is_active = true
      AND (storage.foldername(storage.objects.name))[1] = uac.company_id::text
  )
)
WITH CHECK (
  bucket_id = 'po-files'
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

CREATE POLICY storage_delete_po_files
ON storage.objects
FOR DELETE
TO authenticated
USING (
  bucket_id = 'po-files'
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


-- ╭───────────────────────◉ CONTEXTO: RLS ◉───────────────────────────╮
-- ┃                  Bucket po-files ('fornecedor')                    ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Regras de acesso para o bucket po-files 'fornecedor'
CREATE POLICY storage_select_po_files_supplier
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'po-files'
  AND EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name IN ('fornecedor')
      AND uac.is_active = true
      AND (storage.foldername(storage.objects.name))[1] = uac.company_id::text
  )
);


-- ╭───────────────────────◉ CONTEXTO: RLS ◉───────────────────────────╮
-- ┃            Bucket po-files-imports ('admin', 'comprador')          ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Regras de acesso para o bucket po-files-imports
CREATE POLICY storage_select_po_files_imports
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'po-files-imports'
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

CREATE POLICY storage_insert_po_files_imports
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'po-files-imports'
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

CREATE POLICY storage_update_po_files_imports
ON storage.objects
FOR UPDATE
TO authenticated
USING (
  bucket_id = 'po-files-imports'
  AND EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name IN ('admin', 'comprador')
      AND uac.is_active = true
      AND (storage.foldername(storage.objects.name))[1] = uac.company_id::text
  )
)
WITH CHECK (
  bucket_id = 'po-files-imports'
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

CREATE POLICY storage_delete_po_files_imports
ON storage.objects
FOR DELETE
TO authenticated
USING (
  bucket_id = 'po-files-imports'
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


-- ╭───────────────────────◉ CONTEXTO: RLS ◉───────────────────────────╮
-- ┃              Bucket po-nfe-files ('admin', 'comprador')            ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Regras de acesso para o bucket po-nfe-files
CREATE POLICY storage_select_po_nfe_files
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'po-nfe-files'
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

CREATE POLICY storage_insert_po_nfe_files
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'po-nfe-files'
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

CREATE POLICY storage_update_po_nfe_files
ON storage.objects
FOR UPDATE
TO authenticated
USING (
  bucket_id = 'po-nfe-files'
  AND EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name IN ('admin', 'comprador')
      AND uac.is_active = true
      AND (storage.foldername(storage.objects.name))[1] = uac.company_id::text
  )
)
WITH CHECK (
  bucket_id = 'po-nfe-files'
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

CREATE POLICY storage_delete_po_nfe_files
ON storage.objects
FOR DELETE
TO authenticated
USING (
  bucket_id = 'po-nfe-files'
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


-- ╭───────────────────────◉ CONTEXTO: RLS ◉───────────────────────────╮
-- ┃                Bucket po-nfe-files ('fornecedor')                  ┃
-- ╰────────────────────────────────────────────────────────────────────╯

-- Regra de acesso para fornecedores no bucket de arquivos de NFE
CREATE POLICY storage_supplier_select_po_nfe_files
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'po-nfe-files'
  AND EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'fornecedor'
      AND uac.is_active = true
      AND (storage.foldername(storage.objects.name))[1] = uac.company_id::text
  )
);

CREATE POLICY storage_supplier_insert_po_nfe_files
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'po-nfe-files'
  AND EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'fornecedor'
      AND uac.is_active = true
      AND (storage.foldername(storage.objects.name))[1] = uac.company_id::text
  )
);

CREATE POLICY storage_supplier_update_po_nfe_files
ON storage.objects
FOR UPDATE
TO authenticated
USING (
  bucket_id = 'po-nfe-files'
  AND EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'fornecedor'
      AND uac.is_active = true
      AND (storage.foldername(storage.objects.name))[1] = uac.company_id::text
  )
)
WITH CHECK (
  bucket_id = 'po-nfe-files'
  AND EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'fornecedor'
      AND uac.is_active = true
      AND (storage.foldername(storage.objects.name))[1] = uac.company_id::text
  )
);

CREATE POLICY storage_supplier_delete_po_nfe_files
ON storage.objects
FOR DELETE
TO authenticated
USING (
  bucket_id = 'po-nfe-files'
  AND EXISTS (
    SELECT 1
    FROM private.user_access_cache uac
    WHERE
      uac.user_id = (select auth.uid())
      AND uac.role_name = 'fornecedor'
      AND uac.is_active = true
      AND (storage.foldername(storage.objects.name))[1] = uac.company_id::text
  )
);