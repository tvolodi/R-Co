-- scope: public
-- 031_adp04b_tenant_realm_binding.sql
-- ADP-04b: tenant realm binding for OIDC tenant isolation.
--
-- ISS-0101 / GH-359: this file creates the GLOBAL_REGISTRY `tenant` table
-- (canonical home = public). It has no schema-qualifier of its own — the
-- `-- scope: public` header above tells the migration runner
-- (src/db/migrations.zig migrationScope()) to run this file ONLY in the
-- public pass, never in a tenant-schema pass. Without this header the file
-- defaulted to .all_schemas scope and its unqualified CREATE TABLE ran
-- again in every tenant-schema pass, creating a shadow `tenant` table
-- inside tenant_default (and any other tenant schema) that drifted out of
-- sync with public.tenant as later GBL-only migrations added columns
-- (tenant_type, production_tenant_id). See docs/issues/ISS-0101.json and
-- migrations/GBL-140_iss0101_drop_shadow_tenant_tables.sql, which removes
-- the shadow this file already created before this header was added.

CREATE TABLE IF NOT EXISTS public.tenant (
    id            UUID PRIMARY KEY,
    slug          TEXT NOT NULL,
    display_name  TEXT NOT NULL,
    status        TEXT NOT NULL DEFAULT 'ACTIVE',
    idp_realm_id  TEXT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.tenant
    ADD COLUMN IF NOT EXISTS slug TEXT;

ALTER TABLE public.tenant
    ADD COLUMN IF NOT EXISTS display_name TEXT;

ALTER TABLE public.tenant
    ADD COLUMN IF NOT EXISTS idp_realm_id TEXT;

ALTER TABLE public.tenant
    ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

UPDATE public.tenant
SET slug = CASE
    WHEN id = '00000000-0000-0000-0000-000000000000' THEN 'default'
    ELSE 'tenant-' || replace(id::text, '-', '')
END
WHERE slug IS NULL;

UPDATE public.tenant
SET display_name = COALESCE(display_name, slug)
WHERE display_name IS NULL;

ALTER TABLE public.tenant
    ALTER COLUMN slug SET NOT NULL;

ALTER TABLE public.tenant
    ALTER COLUMN display_name SET NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'tenant_status_check'
    ) THEN
        ALTER TABLE public.tenant
            ADD CONSTRAINT tenant_status_check CHECK (status IN ('ACTIVE', 'INACTIVE'));
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'tenant_realm_non_empty_check'
    ) THEN
        ALTER TABLE public.tenant
            ADD CONSTRAINT tenant_realm_non_empty_check CHECK (
                idp_realm_id IS NULL OR btrim(idp_realm_id) <> ''
            );
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS idx_tenant_slug_unique
    ON public.tenant(slug);

CREATE UNIQUE INDEX IF NOT EXISTS idx_tenant_idp_realm_unique
    ON public.tenant(idp_realm_id)
    WHERE idp_realm_id IS NOT NULL;

INSERT INTO public.tenant (id, slug, display_name, status, idp_realm_id)
VALUES (
    '00000000-0000-0000-0000-000000000000',
    'default',
    'Default Tenant',
    'ACTIVE',
    'bpm-default'
)
ON CONFLICT (id) DO UPDATE
SET slug = COALESCE(tenant.slug, EXCLUDED.slug),
    display_name = COALESCE(tenant.display_name, EXCLUDED.display_name),
    status = COALESCE(tenant.status, EXCLUDED.status),
    idp_realm_id = COALESCE(tenant.idp_realm_id, EXCLUDED.idp_realm_id),
    updated_at = NOW();

UPDATE public.tenant
SET idp_realm_id = 'bpm-default',
    updated_at = NOW()
WHERE id = '00000000-0000-0000-0000-000000000000'
  AND idp_realm_id IS NULL;
