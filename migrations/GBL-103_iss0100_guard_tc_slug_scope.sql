-- GBL-103: ISS-0100 rework 1 (GitHub #357) — further scope the ISS-503 guard
-- (already scoped to tenant_type='production' by GBL-102) to also exclude
-- test-fixture tenant slugs matching the 'tc-%' naming convention used
-- throughout tests/integration/.
--
-- WHY A NEW FILE INSTEAD OF EDITING GBL-102 IN PLACE:
-- Same rationale as GBL-102's own header (migrations/GBL-102_iss503_guard_tenant_type_scope.sql
-- "WHY A NEW FILE INSTEAD OF EDITING GBL-084 IN PLACE"): migrations are tracked
-- by filename in public.schema_migrations and an already-recorded filename is
-- never re-read (src/db/migrations.zig `if (applied.contains(filename)) continue;`).
-- In any environment where GBL-102 already recorded itself as applied, editing
-- GBL-102's guard SQL in place would be inert. This file republishes GBL-102's
-- full body unchanged, with the guard's WHERE clause narrowed to additionally
-- exclude slug LIKE 'tc-%' fixture tenants.
--
-- WHY 'tc-%' AND NOT A TENANT_TYPE-BASED FIX:
-- adp04b_tenant_realm_binding_test.zig and tm01_tenant_list_test.zig legitimately
-- exercise the real service.createTenant() production API path (asserting real
-- default-realm backfill / real HTTP-shaped list output) — converting them to
-- tenant_type='test' would falsify what they test. Their per-test `defer`
-- cleanup is already correct; the gap is that the guard re-evaluates on EVERY
-- TestHarness.init() call across the ~700-test binary's lifetime, so any other
-- test's init() can observe an adp04b/tm01 fixture row in its transient
-- in-flight window. See docs/issue-reports/ISS-0100-rework1-diagnosis.yaml for
-- full mechanism analysis. Every tenant slug created via service.createTenant()/
-- registry.createTenant() across the whole tests/integration/ tree is prefixed
-- 'tc-' (grep-verified at design time; see src/design/iss0100-rework1-guard-slug-scoping.md
-- §2.1) — a real production tenant would never be named 'tc-*'.
--
-- Idempotent: all DDL uses IF EXISTS / DROP COLUMN IF EXISTS, safe to re-run
-- even where GBL-102 already fully succeeded.
-- GBL-prefix: operates on public schema; exempt from lint_migration_schema.py
-- business-table check.

DO $$
DECLARE
    v_legacy_count INTEGER;
    v_tenant_table_exists BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'tenant'
    ) INTO v_tenant_table_exists;

    IF v_tenant_table_exists THEN
        SELECT count(*) INTO v_legacy_count
        FROM public.tenant
        WHERE storage_mode = 'LEGACY_RLS'
          AND tenant_type = 'production'
          AND slug NOT LIKE 'tc-%';

        IF v_legacy_count > 0 THEN
            RAISE EXCEPTION 'ISS-503 pre-flight failed: % tenant(s) still in LEGACY_RLS mode. All tenants must be cut over to SCHEMA before RLS removal.', v_legacy_count;
        END IF;
    ELSE
        RAISE NOTICE 'GBL-103: public.tenant table does not exist. Assuming legacy cleanup already occurred.';
    END IF;

    RAISE NOTICE 'GBL-103: Pre-flight check PASSED — Proceeding with RLS removal.';

    -- Group 1: RLS-protected tables — disable RLS, drop policy, drop tenant_id
    -- (identical to GBL-102/GBL-084 — unchanged, idempotent)
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

    -- Group 2: Non-RLS tables that had tenant_id column (identical, unchanged)
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

    -- Group 3: Drop RLS helper function (identical, unchanged)
    DROP FUNCTION IF EXISTS public.bpm_effective_tenant_id() CASCADE;

    RAISE NOTICE 'GBL-103: RLS removal complete. tenant_id columns and RLS policies removed from public business tables.';
END $$;
