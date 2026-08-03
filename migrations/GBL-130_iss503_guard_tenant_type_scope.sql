-- GBL-102: ISS-0100 (GitHub #357) — Scope GBL-084's ISS-503 pre-flight guard
-- to tenant_type = 'production' only, and take over GBL-084's RLS-removal job.
--
-- NOTE ON NUMBERING: the fix design (src/design/iss0100-tenant-fixture-hygiene.md
-- §5.2 point 5) specified this file as GBL-086, based on a point-in-time
-- listing where GBL-085 was the highest allocated number. By implementation
-- time, GBL-097 through GBL-101 had already landed on main (and were already
-- applied in this environment's schema_migrations), so GBL-086 would be
-- REJECTED by the migration runner's out-of-order guard (src/db/migrations.zig
-- `OutOfOrderMigration`: a lower numeric order cannot apply after a higher
-- order is already recorded). This file was therefore created as GBL-102 —
-- the next free number after the actual on-disk highest (GBL-101) — instead
-- of GBL-086. This is a mechanical renumbering only; the guard-scoping logic
-- and full republished GBL-084 body are otherwise exactly as designed.
--
-- WHY A NEW FILE INSTEAD OF EDITING GBL-084 IN PLACE:
-- Migrations are tracked by filename in public.schema_migrations, and an
-- already-recorded filename is never re-read/re-executed (src/db/migrations.zig
-- `if (applied.contains(filename)) continue;`). In any environment where
-- GBL-084 already recorded itself as applied, editing GBL-084's guard SQL in
-- place would be inert. This migration instead republishes GBL-084's full body
-- (unchanged DDL) under a new filename, with only the pre-flight guard's WHERE
-- clause narrowed to exclude non-production (disposable/test-typed) fixture
-- tenants, so the tightened guard is guaranteed to actually run — once,
-- idempotently — in every environment, fresh or long-lived. See
-- src/design/iss0100-tenant-fixture-hygiene.md §5.2 for the full rationale.
--
-- ISS-503 pre-flight GATE: aborts with RAISE EXCEPTION if any tenant with
-- tenant_type = 'production' in public.tenant still has storage_mode =
-- 'LEGACY_RLS'. Disposable tenant_type = 'test' fixture tenants (leaked by
-- integration test runs that omit tenant_type, which then defaults to
-- 'production' per GBL-080) are no longer counted by this guard — that is
-- the ISS-0100 fix.
--
-- EXPECTED BEHAVIOR AFTER THIS MIGRATION LANDS: because migrations run in
-- filename order, GBL-084 (numerically earlier) always still executes BEFORE
-- GBL-102 on every TestHarness.init() / zig build migrate run. GBL-084's own
-- guard is unchanged (unscoped) and will keep RAISE EXCEPTION-ing and NOT
-- recording itself as applied on every subsequent run, for as long as any
-- tenant_type = 'test' fixture with storage_mode = 'LEGACY_RLS' exists — this
-- is pre-existing, harmless, non-fatal behavior (each migration file runs in
-- its own transactional attempt; a failed file simply does not record itself
-- and the runner proceeds to the next file), NOT a regression introduced by
-- this fix. Immediately after GBL-084's expected failure, GBL-102 (this file,
-- later filename) runs with its scoped guard, passes once no *production*
-- tenant remains in LEGACY_RLS mode, performs the RLS-removal DDL itself
-- (idempotent — safe to re-run even where GBL-084 already fully succeeded
-- previously), and records itself as applied. From that point on, RLS removal
-- is complete regardless of GBL-084's perpetual retry-and-fail NOTICE/EXCEPTION
-- output in logs.
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
    -- Pre-flight check: zero PRODUCTION tenants in LEGACY_RLS mode
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
        WHERE storage_mode = 'LEGACY_RLS'
          AND tenant_type = 'production';

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
