-- scope: public
-- ISS-0604 / GH-470: writes ONLY public.tenant from public.tenant_schemas (every
-- table reference is public.-qualified). It has no per-tenant effect, and running
-- it in a tenant pass is fatal on a fresh database: it needs public.tenant.tenant_type
-- from GBL-119, which per-tenant passes skip, so it failed C42703, left the default
-- tenant unready, and tripped GBL-116's TNT-07 pre-flight — deadlocking bootstrap.
-- Migration 1135: ISS-0114 - Backfill public.tenant from public.tenant_schemas
-- Issue: https://github.com/R-Co/bpm-platform/issues/377 (ISS-0114)
-- Date: 2026-08-04
-- Author: BACKEND-DEV (WF03-gh377-20260804)
--
-- REWORK 1 (2026-08-04): The original INSERT only populated (id, storage_mode)
-- which caused C23502 NOT NULL violations on slug, display_name, status,
-- tenant_type, created_at, updated_at. This patch sets ALL NOT NULL columns
-- required by public.tenant. Pattern mirrors migration 031 (ADP-04b) which
-- uses slug = 'tenant-' || replace(id::text, '-', '') as the deterministic
-- slug derived from the tenant_id.
--
-- Problem: Some tenants have a row in public.tenant_schemas (because
-- bpm_provision_tenant_schema() registered them) but NO row in public.tenant.
-- The pool's applyRequestStorageRouting() resolver defaults to LEGACY_RLS when
-- public.tenant returns 0 rows, which routes these freshly-provisioned tenants
-- to SET search_path TO public instead of SET search_path TO tenant_<uuid>,public.
-- The thread-local _storage_mode cache then sticks at LEGACY_RLS, poisoning
-- every subsequent connection acquired from the same thread.
--
-- Solution: Backfill public.tenant with SCHEMA storage_mode for every
-- tenant that already has a public.tenant_schemas row. Idempotent via
-- ON CONFLICT (id) DO UPDATE on the existing row, full INSERT for new rows.
-- All NOT NULL columns are populated with stable defaults derived from the
-- tenant_id (slug, display_name) or with CURRENT settings (status, tenant_type,
-- storage_mode, created_at, updated_at).

INSERT INTO public.tenant (
    id,
    slug,
    display_name,
    status,
    tenant_type,
    storage_mode,
    created_at,
    updated_at
)
SELECT
    ts.tenant_id,
    'tenant-' || replace(ts.tenant_id::text, '-', ''),
    'Auto-provisioned tenant ' || substr(ts.tenant_id::text, 1, 8),
    'ACTIVE',
    'production',
    'SCHEMA',
    NOW(),
    NOW()
FROM public.tenant_schemas ts
WHERE NOT EXISTS (SELECT 1 FROM public.tenant WHERE id = ts.tenant_id)
ON CONFLICT (id) DO UPDATE
  SET storage_mode = 'SCHEMA',
      updated_at = NOW()
  WHERE public.tenant.storage_mode = 'LEGACY_RLS'
     OR public.tenant.storage_mode IS NULL;
