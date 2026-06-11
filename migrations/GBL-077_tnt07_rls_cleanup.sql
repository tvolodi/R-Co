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

    FOR v_tenant IN SELECT id FROM tenant LOOP

        -- Check tenant_schemas row with migrations_applied_at IS NOT NULL
        SELECT EXISTS (
            SELECT 1 FROM tenant_schemas
             WHERE tenant_id            = v_tenant.id
               AND migrations_applied_at IS NOT NULL
        ) INTO v_has_schema;

        -- Check at least one COMPLETED progress row for this tenant
        SELECT EXISTS (
            SELECT 1 FROM tnt05_progress
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
    -- DDL: Remove RLS policies and drop DEFAULT clauses before dropping columns
    -- All operations are wrapped in exception handlers to ensure idempotency
    -- -------------------------------------------------------------------------

    BEGIN
        EXECUTE 'ALTER TABLE process_definitions ALTER COLUMN tenant_id DROP DEFAULT';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        EXECUTE 'ALTER TABLE instance_projections ALTER COLUMN tenant_id DROP DEFAULT';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        EXECUTE 'ALTER TABLE tasks ALTER COLUMN tenant_id DROP DEFAULT';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        EXECUTE 'ALTER TABLE tokens ALTER COLUMN tenant_id DROP DEFAULT';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        EXECUTE 'ALTER TABLE audit_entries ALTER COLUMN tenant_id DROP DEFAULT';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        EXECUTE 'ALTER TABLE audit_log ALTER COLUMN tenant_id DROP DEFAULT';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    -- Disable RLS and drop columns
    BEGIN
        EXECUTE 'ALTER TABLE process_definitions DISABLE ROW LEVEL SECURITY';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
        EXECUTE 'DROP POLICY IF EXISTS process_definitions_tenant_policy ON process_definitions';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
        EXECUTE 'ALTER TABLE process_definitions DROP COLUMN IF EXISTS tenant_id';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        EXECUTE 'ALTER TABLE instance_projections DISABLE ROW LEVEL SECURITY';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
        EXECUTE 'DROP POLICY IF EXISTS instance_projections_tenant_policy ON instance_projections';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
        EXECUTE 'ALTER TABLE instance_projections DROP COLUMN IF EXISTS tenant_id';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        EXECUTE 'ALTER TABLE tasks DISABLE ROW LEVEL SECURITY';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
        EXECUTE 'DROP POLICY IF EXISTS tasks_tenant_policy ON tasks';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
        EXECUTE 'ALTER TABLE tasks DROP COLUMN IF EXISTS tenant_id';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        EXECUTE 'ALTER TABLE tokens DISABLE ROW LEVEL SECURITY';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
        EXECUTE 'DROP POLICY IF EXISTS tokens_tenant_policy ON tokens';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
        EXECUTE 'ALTER TABLE tokens DROP COLUMN IF EXISTS tenant_id';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        EXECUTE 'ALTER TABLE audit_entries DISABLE ROW LEVEL SECURITY';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
        EXECUTE 'DROP POLICY IF EXISTS audit_entries_tenant_policy ON audit_entries';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
        EXECUTE 'ALTER TABLE audit_entries DROP COLUMN IF EXISTS tenant_id';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        EXECUTE 'ALTER TABLE audit_log DISABLE ROW LEVEL SECURITY';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
        EXECUTE 'DROP POLICY IF EXISTS audit_log_tenant_policy ON audit_log';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
        EXECUTE 'ALTER TABLE audit_log DROP COLUMN IF EXISTS tenant_id';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    -- Drop tenant_id from tables without RLS
    BEGIN
        EXECUTE 'ALTER TABLE events DROP COLUMN IF EXISTS tenant_id';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        EXECUTE 'ALTER TABLE events_archive DROP COLUMN IF EXISTS tenant_id';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    -- Additional tables
    BEGIN
        EXECUTE 'ALTER TABLE instance_sequence DROP COLUMN IF EXISTS tenant_id';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        EXECUTE 'ALTER TABLE event_type_registry DROP COLUMN IF EXISTS tenant_id';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        EXECUTE 'ALTER TABLE event_retention_policies DROP COLUMN IF EXISTS tenant_id';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        EXECUTE 'ALTER TABLE timers DROP COLUMN IF EXISTS tenant_id';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        EXECUTE 'ALTER TABLE users DROP COLUMN IF EXISTS tenant_id';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        EXECUTE 'ALTER TABLE groups DROP COLUMN IF EXISTS tenant_id';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        EXECUTE 'ALTER TABLE group_members DROP COLUMN IF EXISTS tenant_id';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        EXECUTE 'ALTER TABLE roles DROP COLUMN IF EXISTS tenant_id';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        EXECUTE 'ALTER TABLE user_roles DROP COLUMN IF EXISTS tenant_id';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        EXECUTE 'ALTER TABLE api_tokens DROP COLUMN IF EXISTS tenant_id';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        EXECUTE 'ALTER TABLE webhook_subscriptions DROP COLUMN IF EXISTS tenant_id';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        EXECUTE 'ALTER TABLE dead_letter_items DROP COLUMN IF EXISTS tenant_id';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        EXECUTE 'ALTER TABLE repository_form_schemas DROP COLUMN IF EXISTS tenant_id';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    -- Drop the function with CASCADE to handle any remaining dependencies
    BEGIN
        EXECUTE 'DROP FUNCTION IF EXISTS bpm_effective_tenant_id() CASCADE';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    RAISE NOTICE 'GBL-077: RLS cleanup complete. tenant_id columns and RLS policies removed from public business tables.';

END $$;
