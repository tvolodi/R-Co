-- GBL-084: ISS-503 — Remove RLS policies and tenant_id columns from public
-- business tables after all tenants have been cut over to SCHEMA mode.
--
-- PRE-FLIGHT GATE: This migration aborts with RAISE EXCEPTION if any tenant
-- in public.tenant still has storage_mode = 'LEGACY_RLS'.
--
-- If the pre-flight fails: zero DDL changes are made.  The migration runner
-- receives MigrationError.MigrationFailed and does NOT record this migration
-- as applied in public.schema_migrations.
--
-- Idempotent: all DDL uses IF EXISTS / DROP COLUMN IF EXISTS.
-- GBL-prefix: operates on public schema; exempt from lint_migration_schema.py
-- business-table check.

DO $$
DECLARE
    v_legacy_count INTEGER;
BEGIN
    -- -------------------------------------------------------------------------
    -- Pre-flight check: zero tenants in LEGACY_RLS mode
    -- -------------------------------------------------------------------------

    SELECT count(*) INTO v_legacy_count
    FROM tenant
    WHERE storage_mode = 'LEGACY_RLS';

    IF v_legacy_count > 0 THEN
        RAISE EXCEPTION 'ISS-503 pre-flight failed: % tenant(s) still in LEGACY_RLS mode. All tenants must be cut over to SCHEMA before RLS removal.', v_legacy_count;
    END IF;

    RAISE NOTICE 'GBL-084: Pre-flight check PASSED — zero LEGACY_RLS tenants. Proceeding with RLS removal.';

    -- -------------------------------------------------------------------------
    -- Group 1: RLS-protected tables — disable RLS, drop policy, drop tenant_id
    -- -------------------------------------------------------------------------

    ALTER TABLE IF EXISTS process_definitions DISABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS process_definitions_tenant_policy ON process_definitions;
    ALTER TABLE IF EXISTS process_definitions DROP COLUMN IF EXISTS tenant_id;

    ALTER TABLE IF EXISTS instance_projections DISABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS instance_projections_tenant_policy ON instance_projections;
    ALTER TABLE IF EXISTS instance_projections DROP COLUMN IF EXISTS tenant_id;

    ALTER TABLE IF EXISTS tasks DISABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS tasks_tenant_policy ON tasks;
    ALTER TABLE IF EXISTS tasks DROP COLUMN IF EXISTS tenant_id;

    ALTER TABLE IF EXISTS tokens DISABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS tokens_tenant_policy ON tokens;
    ALTER TABLE IF EXISTS tokens DROP COLUMN IF EXISTS tenant_id;

    ALTER TABLE IF EXISTS audit_entries DISABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS audit_entries_tenant_policy ON audit_entries;
    ALTER TABLE IF EXISTS audit_entries DROP COLUMN IF EXISTS tenant_id;

    ALTER TABLE IF EXISTS audit_log DISABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS audit_log_tenant_policy ON audit_log;
    ALTER TABLE IF EXISTS audit_log DROP COLUMN IF EXISTS tenant_id;

    -- -------------------------------------------------------------------------
    -- Group 2: Non-RLS tables that had tenant_id column
    -- -------------------------------------------------------------------------

    ALTER TABLE IF EXISTS events DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS events_archive DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS instance_sequence DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS event_type_registry DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS event_retention_policies DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS timers DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS users DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS groups DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS group_members DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS roles DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS user_roles DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS api_tokens DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS webhook_subscriptions DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS webhook_deliveries DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS dead_letter_items DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS repository_form_schemas DROP COLUMN IF EXISTS tenant_id;

    -- -------------------------------------------------------------------------
    -- Group 3: Drop RLS helper function
    -- -------------------------------------------------------------------------

    DROP FUNCTION IF EXISTS bpm_effective_tenant_id();

    RAISE NOTICE 'GBL-084: RLS removal complete. tenant_id columns and RLS policies removed from public business tables.';

END $$;
