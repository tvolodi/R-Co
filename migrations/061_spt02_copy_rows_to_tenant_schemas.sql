-- Migration 061: SPT-02 data migration phase 1
-- Copy all rows from public schema tables into per-tenant schemas.
--
-- PUBLIC-SCHEMA-ONLY: This migration is a no-op when runForSchema() executes
-- it inside a tenant schema.  The guard below ensures the body only runs when
-- current_schema() = 'public'.
--
-- Idempotent:
--   * ADD COLUMN IF NOT EXISTS guards the status column addition.
--   * bpm_provision_tenant_schema() uses ON CONFLICT DO NOTHING.
--   * CREATE TABLE IF NOT EXISTS guards each tenant schema table.
--   * DROP COLUMN IF EXISTS ... CASCADE is a no-op if already absent.
--   * Tenants with status = 'active' in tenant_schemas are skipped.
--   * INSERT ... ON CONFLICT DO NOTHING never duplicates rows.
--
-- Interrupted copy recovery:
--   A per-tenant transaction rolls back atomically if killed mid-copy.
--   The status remains 'pending', so a re-run will retry the copy safely.
--   ON CONFLICT DO NOTHING ensures rows copied in the aborted attempt are
--   not duplicated on retry.
--
-- Table creation strategy:
--   Each table is created in the tenant schema using
--   LIKE public.<table> INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING INDEXES
--   (omitting INCLUDING FOREIGN KEYS to prevent cross-schema FK dependencies).
--   The tenant_id column is then dropped with CASCADE, which also removes any
--   tenant_id-based composite indexes and constraints in the tenant schema copy.
--   The row copy uses a dynamically built column list (excluding tenant_id).

-- ── Step 1: Add status column to tenant_schemas ──────────────────────────────
-- Explicitly schema-qualified and idempotent (ADD COLUMN IF NOT EXISTS).
-- Safe to run in any schema context.

ALTER TABLE public.tenant_schemas
    ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'pending';

-- ── Step 2: Per-tenant copy loop ─────────────────────────────────────────────
-- PUBLIC-SCHEMA-ONLY: the body begins with a current_schema() guard so that
-- runForSchema() applying this migration inside a tenant schema is a no-op.
-- (A nested DO block inside another DO block is not valid in PL/pgSQL, so
--  the guard lives directly inside this single DO block.)

DO $$
DECLARE
    r_tenant        RECORD;
    t               TEXT;
    v_schema        TEXT;
    v_col_list      TEXT;
    has_col         BOOLEAN;
    col_exists      BOOLEAN;
    -- Tables processed in FK-dependency order:
    --   1. process_definitions  (no FK deps on other tenant tables)
    --   2. instance_projections (FK → process_definitions)
    --   3. tasks                (FK → instance_projections)
    --   4. events               (FK → instance_projections)
    --   5. events_archive       (standalone by seq; safe after events)
    --   6. tokens               (FK → instance_projections)
    --   7. audit_log            (standalone; safe after main tables)
    --   8. audit_entries        (standalone)
    --   9. users                (standalone identity table)
    --  10. groups               (standalone identity table)
    --  11. tenant_hostnames     (standalone; FK to public.tenant not migrated)
    tables_ordered  TEXT[] := ARRAY[
        'process_definitions',
        'instance_projections',
        'tasks',
        'events',
        'events_archive',
        'tokens',
        'audit_log',
        'audit_entries',
        'users',
        'groups',
        'tenant_hostnames'
    ];
BEGIN
    -- Public-schema guard: exit early when running inside a tenant schema.
    IF current_schema() <> 'public' THEN
        RETURN;
    END IF;

    -- Guard: if tenant_id was already removed from public.process_definitions
    -- (i.e. migration 062 ran before this migration in a per-tenant schema
    -- context), there is nothing to copy — exit early.
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE  table_schema = 'public'
          AND  table_name   = 'process_definitions'
          AND  column_name  = 'tenant_id'
    ) INTO col_exists;
    IF NOT col_exists THEN
        RAISE NOTICE 'migration 061: tenant_id already removed from public schema — skipping data copy';
        RETURN;
    END IF;

    -- Collect all distinct tenant_ids across every affected public table.
    -- UNION (not UNION ALL) deduplicates across tables.
    FOR r_tenant IN
        SELECT DISTINCT tenant_id FROM (
            SELECT tenant_id FROM public.process_definitions
            UNION SELECT tenant_id FROM public.instance_projections
            UNION SELECT tenant_id FROM public.tasks
            UNION SELECT tenant_id FROM public.events
            UNION SELECT tenant_id FROM public.events_archive
            UNION SELECT tenant_id FROM public.tokens
            UNION SELECT tenant_id FROM public.audit_log
            UNION SELECT tenant_id FROM public.audit_entries
            UNION SELECT tenant_id FROM public.users
            UNION SELECT tenant_id FROM public.groups
            UNION SELECT tenant_id FROM public.tenant_hostnames
        ) sub
        WHERE tenant_id IS NOT NULL
    LOOP
        -- Provision schema (idempotent — ON CONFLICT DO NOTHING in function).
        PERFORM public.bpm_provision_tenant_schema(r_tenant.tenant_id);

        -- Skip tenants that are already fully migrated.
        CONTINUE WHEN EXISTS (
            SELECT 1 FROM public.tenant_schemas
            WHERE  tenant_id = r_tenant.tenant_id
              AND  status    = 'active'
        );

        -- Derive schema name (must match bpm_provision_tenant_schema logic).
        IF r_tenant.tenant_id = '00000000-0000-0000-0000-000000000000'::uuid THEN
            v_schema := 'tenant_default';
        ELSE
            v_schema := 'tenant_' || replace(r_tenant.tenant_id::text, '-', '');
        END IF;

        -- ── Per-table copy ────────────────────────────────────────────────────
        FOREACH t IN ARRAY tables_ordered LOOP

            -- Guard: skip if the public table has no tenant_id column.
            -- (Handles tables like 'timers' or 'sessions' that were never given one.)
            SELECT EXISTS (
                SELECT 1 FROM information_schema.columns
                WHERE  table_schema = 'public'
                  AND  table_name   = t
                  AND  column_name  = 'tenant_id'
            ) INTO has_col;
            CONTINUE WHEN NOT has_col;

            -- Create table in tenant schema (structure only, no FK constraints).
            --   * INCLUDING DEFAULTS  → copies column default expressions
            --   * INCLUDING CONSTRAINTS → copies PK, UNIQUE, CHECK, NOT NULL
            --   * INCLUDING INDEXES   → copies all indexes (required for PK)
            --   * Omits INCLUDING FOREIGN KEYS to avoid cross-schema FK deps
            EXECUTE format(
                'CREATE TABLE IF NOT EXISTS %I.%I '
                '(LIKE public.%I '
                ' INCLUDING DEFAULTS '
                ' INCLUDING CONSTRAINTS '
                ' INCLUDING INDEXES)',
                v_schema, t, t
            );

            -- Drop tenant_id from the tenant-schema table.
            -- CASCADE removes any composite indexes or constraints that include it.
            EXECUTE format(
                'ALTER TABLE %I.%I DROP COLUMN IF EXISTS tenant_id CASCADE',
                v_schema, t
            );

            -- Build INSERT column list: all public columns except tenant_id,
            -- ordered by ordinal_position to match SELECT list.
            SELECT string_agg(
                       quote_ident(column_name),
                       ', '
                       ORDER BY ordinal_position
                   )
            INTO   v_col_list
            FROM   information_schema.columns
            WHERE  table_schema = 'public'
              AND  table_name   = t
              AND  column_name != 'tenant_id';

            -- Copy rows for this tenant.
            -- ON CONFLICT DO NOTHING: safe on retry; PK collisions are skipped.
            EXECUTE format(
                'INSERT INTO %I.%I (%s) '
                'SELECT %s '
                'FROM   public.%I '
                'WHERE  tenant_id = %L '
                'ON CONFLICT DO NOTHING',
                v_schema, t,
                v_col_list,
                v_col_list,
                t,
                r_tenant.tenant_id
            );

        END LOOP;
        -- ── End per-table copy ────────────────────────────────────────────────

        -- Mark this tenant as fully migrated.
        UPDATE public.tenant_schemas
        SET    status = 'active'
        WHERE  tenant_id = r_tenant.tenant_id;

    END LOOP;
END;
$$;
