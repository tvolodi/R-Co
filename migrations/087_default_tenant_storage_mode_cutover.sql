-- 087_default_tenant_storage_mode_cutover.sql
-- Requirements: ISS-502 (fresh-DB bootstrap blocker unblock)
--
-- Context: migration 031_adp04b_tenant_realm_binding.sql seeds the default
-- tenant (id=00000000-0000-0000-0000-000000000000) via a raw INSERT, bypassing
-- the Zig-side provisionTenantSchema() path. Migration 086_iss107_tenant_storage_mode.sql
-- adds tenant.storage_mode with DEFAULT 'LEGACY_RLS' and documents that newly
-- provisioned tenants should default to SCHEMA via provisionTenantSchema() —
-- but the seed tenant never goes through that path, so on a from-scratch
-- database it is permanently stuck at LEGACY_RLS. Migration
-- 069_retroactive_tenant_schema_provision.sql DOES retroactively provision the
-- tenant_default PostgreSQL schema (and its public.tenant_schemas row) for any
-- tenant missing one — so by the time this migration runs, the default
-- tenant's schema has already been provisioned — it just never gets
-- storage_mode flipped to SCHEMA. GBL-084_rls_removal.sql then correctly (per
-- its own intentionally strict ISS-503 pre-flight gate) refuses to proceed
-- while any tenant is still LEGACY_RLS, aborting the whole migration chain on
-- a fresh install.
--
-- This migration cuts the default tenant over from LEGACY_RLS to SCHEMA, but
-- ONLY when public.tenant_schemas already has a row for it (i.e. only when
-- migration 069's retroactive provisioning has actually run and the
-- tenant_default schema exists). It does NOT create the schema itself — that
-- remains 069's and provisionTenantSchema()'s responsibility. If no
-- tenant_schemas row exists yet (should not happen given migration order, but
-- guarded defensively), storage_mode is left unchanged and a RAISE NOTICE
-- explains why, rather than failing the migration.
--
-- Does NOT modify GBL-084_rls_removal.sql's pre-flight check — that check is
-- correct and intentionally strict per ISS-503. This migration is purely
-- additive.
--
-- Does NOT use or repurpose the onboarding_registry.migration_window_active
-- flag — that flag serves a different purpose (TNT-04 live zero-downtime
-- migration windows) and must not be weakened by reuse here.
--
-- Idempotent: safe to re-run at any time with no ill effect.

DO $$
DECLARE
    v_default_tenant_id CONSTANT UUID := '00000000-0000-0000-0000-000000000000';
    v_schema_provisioned BOOLEAN;
    v_current_storage_mode TEXT;
BEGIN
    -- Only act if public.tenant exists (fresh bootstrap always has it by this
    -- point, but guard consistent with GBL-084's own defensive style).
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = 'tenant'
    ) THEN
        RAISE NOTICE '087: public.tenant table does not exist. Skipping default-tenant storage_mode cutover.';
        RETURN;
    END IF;

    SELECT storage_mode INTO v_current_storage_mode
    FROM public.tenant
    WHERE id = v_default_tenant_id;

    IF v_current_storage_mode IS NULL THEN
        RAISE NOTICE '087: default tenant % not found in public.tenant. Skipping storage_mode cutover.', v_default_tenant_id;
        RETURN;
    END IF;

    IF v_current_storage_mode = 'SCHEMA' THEN
        RAISE NOTICE '087: default tenant % already at storage_mode = SCHEMA. Nothing to do.', v_default_tenant_id;
        RETURN;
    END IF;

    -- Only flip to SCHEMA if migration 069's retroactive provisioning already
    -- registered a tenant_schemas row (i.e. tenant_default schema exists).
    SELECT EXISTS (
        SELECT 1
        FROM public.tenant_schemas
        WHERE tenant_id = v_default_tenant_id
    ) INTO v_schema_provisioned;

    IF v_schema_provisioned THEN
        UPDATE public.tenant
        SET storage_mode = 'SCHEMA',
            updated_at = NOW()
        WHERE id = v_default_tenant_id
          AND storage_mode = 'LEGACY_RLS';

        RAISE NOTICE '087: default tenant % cut over from LEGACY_RLS to SCHEMA storage_mode (tenant_schemas row confirmed).', v_default_tenant_id;
    ELSE
        RAISE NOTICE '087: default tenant % has no public.tenant_schemas row yet — leaving storage_mode = %. Expected migration 069 to have provisioned it by this point; verify migration order.', v_default_tenant_id, v_current_storage_mode;
    END IF;
END $$;
