-- GBL-077: TNT-07 — Remove RLS policies and tenant_id columns from public
-- business tables, and drop bpm_effective_tenant_id().
--
-- PRE-FLIGHT GATE: This migration aborts with RAISE EXCEPTION if any tenant
-- in public.tenant is not fully migrated (tenant_schemas row with
-- migrations_applied_at IS NOT NULL AND at least one tnt05_progress row
-- with status = 'COMPLETED').
--
-- If the pre-flight fails: zero DDL changes are made.
-- The migration runner receives MigrationError.MigrationFailed and does NOT
-- record this migration as applied in public.schema_migrations.
--
-- GBL-prefix: operates on public schema; exempt from lint_migration_schema.py
-- business-table check.

DO $$
DECLARE
    v_tenant         RECORD;
    v_unready        TEXT[] := ARRAY[]::TEXT[];
    v_has_schema     BOOLEAN;
    v_has_progress   BOOLEAN;
BEGIN
    -- -------------------------------------------------------------------------
    -- Pre-flight check: all tenants must be fully migrated
    -- -------------------------------------------------------------------------

    -- Check if tnt05_progress table exists at all (GBL-074 must have run)
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
         WHERE table_schema = 'public'
           AND table_name   = 'tnt05_progress'
           AND table_type   = 'BASE TABLE'
    ) THEN
        RAISE EXCEPTION 'TNT-07 pre-flight failed: tnt05_progress table does not exist. Run GBL-074 and GBL-075 first.';
    END IF;

    FOR v_tenant IN SELECT id FROM public.tenant LOOP

        -- Check tenant_schemas row with migrations_applied_at IS NOT NULL
        SELECT EXISTS (
            SELECT 1 FROM public.tenant_schemas
             WHERE tenant_id            = v_tenant.id
               AND migrations_applied_at IS NOT NULL
        ) INTO v_has_schema;

        -- Check at least one COMPLETED progress row for this tenant
        SELECT EXISTS (
            SELECT 1 FROM public.tnt05_progress
             WHERE tenant_id = v_tenant.id
               AND status    = 'COMPLETED'
        ) INTO v_has_progress;

        IF NOT v_has_schema OR NOT v_has_progress THEN
            v_unready := array_append(v_unready, v_tenant.id::text);
        END IF;

    END LOOP;

    IF array_length(v_unready, 1) > 0 THEN
        RAISE EXCEPTION 'TNT-07 pre-flight failed. Unready tenants: %',
            array_to_string(v_unready, ', ');
    END IF;

    RAISE NOTICE 'GBL-077: Pre-flight check PASSED — all tenants ready. Proceeding with RLS cleanup.';

    -- -------------------------------------------------------------------------
    -- DDL: Remove RLS policies from tables that had them (migration 028 subset)
    -- Tables: process_definitions, instance_projections, tasks, tokens,
    --         audit_entries, audit_log
    -- -------------------------------------------------------------------------

    -- process_definitions
    ALTER TABLE IF EXISTS public.process_definitions DISABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS process_definitions_tenant_policy ON public.process_definitions;
    ALTER TABLE IF EXISTS public.process_definitions DROP COLUMN IF EXISTS tenant_id;

    -- instance_projections
    ALTER TABLE IF EXISTS public.instance_projections DISABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS instance_projections_tenant_policy ON public.instance_projections;
    ALTER TABLE IF EXISTS public.instance_projections DROP COLUMN IF EXISTS tenant_id;

    -- tasks
    ALTER TABLE IF EXISTS public.tasks DISABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS tasks_tenant_policy ON public.tasks;
    ALTER TABLE IF EXISTS public.tasks DROP COLUMN IF EXISTS tenant_id;

    -- tokens
    ALTER TABLE IF EXISTS public.tokens DISABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS tokens_tenant_policy ON public.tokens;
    ALTER TABLE IF EXISTS public.tokens DROP COLUMN IF EXISTS tenant_id;

    -- audit_entries
    ALTER TABLE IF EXISTS public.audit_entries DISABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS audit_entries_tenant_policy ON public.audit_entries;
    ALTER TABLE IF EXISTS public.audit_entries DROP COLUMN IF EXISTS tenant_id;

    -- audit_log
    ALTER TABLE IF EXISTS public.audit_log DISABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS audit_log_tenant_policy ON public.audit_log;
    ALTER TABLE IF EXISTS public.audit_log DROP COLUMN IF EXISTS tenant_id;

    -- -------------------------------------------------------------------------
    -- DDL: Remove tenant_id column from tables that had it without RLS
    -- (migration 027 additions): events, events_archive
    -- -------------------------------------------------------------------------

    -- events
    ALTER TABLE IF EXISTS events DROP COLUMN IF EXISTS tenant_id;

    -- events_archive
    ALTER TABLE IF EXISTS events_archive DROP COLUMN IF EXISTS tenant_id;

    -- -------------------------------------------------------------------------
    -- Additional tables that may have had tenant_id added in later migrations
    -- -------------------------------------------------------------------------

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
    ALTER TABLE IF EXISTS dead_letter_items DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS repository_form_schemas DROP COLUMN IF EXISTS tenant_id;

    -- -------------------------------------------------------------------------
    -- Drop bpm_effective_tenant_id() function
    -- (We use CASCADE to ensure default values and policies in tenant schemas
    --  that still reference this global function are also dropped. In Stage 12,
    --  these columns are no longer used for RLS anyway.)
    -- -------------------------------------------------------------------------
    DROP FUNCTION IF EXISTS public.bpm_effective_tenant_id() CASCADE;

    RAISE NOTICE 'GBL-077: RLS cleanup complete. tenant_id columns and RLS policies removed from public business tables (and global helper function dropped).';

END $$;
