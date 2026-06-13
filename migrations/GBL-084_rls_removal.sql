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
    v_tenant_table_exists BOOLEAN;
BEGIN
    -- -------------------------------------------------------------------------
    -- Pre-flight check: zero tenants in LEGACY_RLS mode
    -- -------------------------------------------------------------------------

    SELECT EXISTS (
        SELECT 1 
        FROM information_schema.tables 
        WHERE table_schema = 'public' 
          AND table_name = 'tenant'
    ) INTO v_tenant_table_exists;

    IF v_tenant_table_exists THEN
        SELECT count(*) INTO v_legacy_count
        FROM public.tenant
        WHERE storage_mode = 'LEGACY_RLS';

        IF v_legacy_count > 0 THEN
            RAISE EXCEPTION 'ISS-503 pre-flight failed: % tenant(s) still in LEGACY_RLS mode. All tenants must be cut over to SCHEMA before RLS removal.', v_legacy_count;
        END IF;
    ELSE
        RAISE NOTICE 'GBL-084: public.tenant table does not exist. Assuming legacy cleanup already occurred.';
    END IF;

    RAISE NOTICE 'GBL-084: Pre-flight check PASSED — Proceeding with RLS removal.';

    -- -------------------------------------------------------------------------
    -- Group 1: RLS-protected tables — disable RLS, drop policy, drop tenant_id
    -- -------------------------------------------------------------------------

    ALTER TABLE IF EXISTS public.process_definitions DISABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS process_definitions_tenant_policy ON public.process_definitions;
    ALTER TABLE IF EXISTS public.process_definitions DROP COLUMN IF EXISTS tenant_id;

    ALTER TABLE IF EXISTS public.instance_projections DISABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS instance_projections_tenant_policy ON public.instance_projections;
    ALTER TABLE IF EXISTS public.instance_projections DROP COLUMN IF EXISTS tenant_id;

    ALTER TABLE IF EXISTS public.tasks DISABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS tasks_tenant_policy ON public.tasks;
    ALTER TABLE IF EXISTS public.tasks DROP COLUMN IF EXISTS tenant_id;

    ALTER TABLE IF EXISTS public.tokens DISABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS tokens_tenant_policy ON public.tokens;
    ALTER TABLE IF EXISTS public.tokens DROP COLUMN IF EXISTS tenant_id;

    ALTER TABLE IF EXISTS public.audit_entries DISABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS audit_entries_tenant_policy ON public.audit_entries;
    ALTER TABLE IF EXISTS public.audit_entries DROP COLUMN IF EXISTS tenant_id;

    ALTER TABLE IF EXISTS public.audit_log DISABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS audit_log_tenant_policy ON public.audit_log;
    ALTER TABLE IF EXISTS public.audit_log DROP COLUMN IF EXISTS tenant_id;

    -- -------------------------------------------------------------------------
    -- Group 2: Non-RLS tables that had tenant_id column
    -- -------------------------------------------------------------------------

    ALTER TABLE IF EXISTS events DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS events_archive DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS instance_sequence DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS event_type_registry DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS event_retention_policies DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS public.timers DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS public.users DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS public.groups DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS public.group_members DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS public.roles DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS public.user_roles DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS public.api_tokens DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS public.webhook_subscriptions DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS public.webhook_deliveries DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS public.dead_letter_items DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS public.repository_form_schemas DROP COLUMN IF EXISTS tenant_id;

    -- -------------------------------------------------------------------------
    -- Group 3: Drop RLS helper function
    -- -------------------------------------------------------------------------

    DROP FUNCTION IF EXISTS public.bpm_effective_tenant_id() CASCADE;

    RAISE NOTICE 'GBL-084: RLS removal complete. tenant_id columns and RLS policies removed from public business tables.';

END $$;
