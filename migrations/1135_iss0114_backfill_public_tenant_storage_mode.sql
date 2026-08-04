-- Migration 1135: ISS-0114 - Backfill public.tenant from public.tenant_schemas
-- Issue: https://github.com/R-Co/bpm-platform/issues/377 (ISS-0114)
-- Date: 2026-08-04
-- Author: BACKEND-DEV (WF03-gh377-20260804)
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
-- ON CONFLICT (id) DO NOTHING and a conditional WHERE clause.

INSERT INTO public.tenant (id, storage_mode, created_at)
SELECT ts.tenant_id, 'SCHEMA', NOW()
FROM public.tenant_schemas ts
WHERE NOT EXISTS (SELECT 1 FROM public.tenant WHERE id = ts.tenant_id)
ON CONFLICT (id) DO UPDATE
  SET storage_mode='SCHEMA'
  WHERE public.tenant.storage_mode='LEGACY_RLS' OR public.tenant.storage_mode IS NULL;
