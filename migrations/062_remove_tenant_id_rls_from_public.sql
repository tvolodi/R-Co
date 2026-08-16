-- scope: public
-- SPT-02 migration 062: remove tenant_id, RLS, bpm_effective_tenant_id(), and
-- tenant-scoped composite indexes from the public business tables.
--
-- Runs ONCE in the public pass. It is deliberately NOT run per-tenant: after
-- 061 the tenant schema tables already hold the tenant's rows and KEEP their
-- tenant_id column (schema isolation is the tenant boundary going forward);
-- only the public copies lose the row-based tenancy machinery.
--
-- Pre-flight gate: aborts (RAISE EXCEPTION) if any tenant_schemas row has
-- data_migrated_at IS NULL — i.e. migration 061 has not fully completed.
-- On a database where 061 already ran (or where no tenant_schemas rows exist,
-- e.g. a fresh bootstrap before 069 provisions anything) the gate passes and
-- the DDL proceeds.
--
-- All per-table DDL is %I-interpolated via EXECUTE format('... %I.%I ...',
-- 'public', <table>) — dynamic interpolation (migration 069 precedent) so the
-- file carries no static public.<business_table> reference (lint_migration_schema
-- M001) and no bare <table> (runner MigrationScopeMismatch).
--
-- Belt-and-suspenders: after DROP COLUMN tenant_id (which implicitly drops
-- every index/constraint referencing the column), a residual-index sweep drops
-- any remaining tenant_id-backed index/constraint that survived drift, and the
-- end-state is re-asserted (NOTICE, not exception) so a re-run on a fully
-- migrated database exits 0 unchanged (SPT-02 AC5).

-- ---------------------------------------------------------------------------
-- Pre-flight gate: 061 must have fully completed.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_unmigrated bigint;
BEGIN
    SELECT count(*) INTO v_unmigrated
      FROM public.tenant_schemas
     WHERE data_migrated_at IS NULL;

    IF v_unmigrated > 0 THEN
        RAISE EXCEPTION
            'SPT-02 062 pre-flight failed: % tenant_schemas row(s) still have data_migrated_at IS NULL. '
            'Migration 061 must fully complete (every tenant copied and marked) before tenant_id '
            'columns / RLS policies / bpm_effective_tenant_id() can be dropped from public.',
            v_unmigrated;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Main DDL: per Class-B public table, drop RLS / policies / tenant_id /
-- tenant-scoped composite indexes. Class-G registry tables are exempt.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    -- Class-G registry allow-list: tables that legitimately KEEP their
    -- tenant_id column in public forever (design §8.2 R4). All other public
    -- tables that carry a tenant_id column are treated as Class-B business
    -- tables and lose the column here.
    v_class_g text[] := ARRAY[
        'tenant_schemas',
        'tenant_hostnames',
        'tenant_realm_binding',
        'onboarding_registry',
        'platform_migrations_control_table',
        'rate_limit_buckets',
        'secrets',
        'repository_artifacts',
        'tenant_artifact_activations',
        'promotion_assertion_runs',
        'pack_update_resolutions',
        'solution_pack_installs',
        'tnt05_orphans',
        'tnt05_progress'
    ];
    v_tbl text;
    v_pol text;
    v_idx text;
    v_idx_tbl text;
BEGIN
    -- Discover Class-B tables at runtime: any public table with a tenant_id
    -- column that is not on the Class-G allow-list. This is the information
    -- schema reconciliation the design (§4 F9) makes authoritative: on a fresh
    -- database it includes the legacy business tables (dropped from public
    -- only later by GBL-112/GBL-123); on a database already past those files
    -- it covers the remaining tenant-scoped business tables only.
    CREATE TEMP TABLE _spt_class_b (tbl text PRIMARY KEY) ON COMMIT DROP;
    INSERT INTO pg_temp._spt_class_b
        SELECT c.table_name::text
          FROM information_schema.columns c
         WHERE c.table_schema = 'public'
           AND c.column_name  = 'tenant_id'
           AND c.table_name <> ALL (v_class_g)
           AND to_regclass('public.' || c.table_name::text) IS NOT NULL
        ON CONFLICT DO NOTHING;

    FOR v_tbl IN SELECT tbl FROM pg_temp._spt_class_b ORDER BY tbl LOOP
        -- 1. Disable RLS on the public copy (idempotent).
        EXECUTE format('ALTER TABLE IF EXISTS %I.%I DISABLE ROW LEVEL SECURITY', 'public', v_tbl);

        -- 2. Drop every policy on the public copy (belt-and-suspenders: this
        --    covers the known <table>_tenant_policy names and any drift).
        FOR v_pol IN
            SELECT policyname FROM pg_policies
             WHERE schemaname = 'public' AND tablename = v_tbl
        LOOP
            EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I', v_pol, 'public', v_tbl);
        END LOOP;

        -- 3. Drop the tenant_id column. This implicitly drops every index and
        --    constraint (incl. tenant-scoped composite indexes and unique
        --    constraints) that references the column.
        EXECUTE format('ALTER TABLE IF EXISTS %I.%I DROP COLUMN IF EXISTS tenant_id', 'public', v_tbl);
    END LOOP;

    -- -----------------------------------------------------------------------
    -- Belt-and-suspenders residual-index sweep: explicitly drop any remaining
    -- index/constraint backed by a tenant_id column on the Class-B tables. In
    -- the normal case DROP COLUMN already removed them, so this is a no-op; it
    -- exists to make the post-state verifiable even if an index name drifted.
    -- -----------------------------------------------------------------------
    FOR v_idx_tbl, v_idx IN
        SELECT t.relname::text, i.relname::text
          FROM pg_class t
          JOIN pg_index ix ON t.oid = ix.indrelid
          JOIN pg_class i  ON i.oid = ix.indexrelid
          JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(ix.indkey)
          JOIN pg_temp._spt_class_b cb ON cb.tbl = t.relname::text
         WHERE t.relnamespace = 'public'::regnamespace
           AND a.attname = 'tenant_id'
    LOOP
        BEGIN
            EXECUTE format('ALTER TABLE IF EXISTS %I.%I DROP CONSTRAINT IF EXISTS %I', 'public', v_idx_tbl, v_idx);
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'SPT-02 062: could not drop constraint % on %I.%I: %', v_idx, 'public', v_idx_tbl, SQLERRM;
        END;
        BEGIN
            EXECUTE format('DROP INDEX IF EXISTS %I.%I', 'public', v_idx);
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'SPT-02 062: could not drop index %I.%I: %', 'public', v_idx, SQLERRM;
        END;
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- Drop the RLS helper function from public (already absent where GBL-123 /
-- ISS-503 ran; idempotent here).
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.bpm_effective_tenant_id() CASCADE;

-- ---------------------------------------------------------------------------
-- End-state verification (NOTICE, never exception — a healthy re-run exits 0).
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_tbl text;
    v_pol text;
    v_residual boolean := false;
BEGIN
    FOR v_tbl IN
        SELECT c.table_name::text
          FROM information_schema.columns c
         WHERE c.table_schema = 'public'
           AND c.column_name  = 'tenant_id'
           AND to_regclass('public.' || c.table_name::text) IS NOT NULL
        ORDER BY c.table_name
    LOOP
        RAISE NOTICE 'SPT-02 062 re-check: public.%I still carries tenant_id (expected only on Class-G registry tables).', v_tbl;
        v_residual := true;
    END LOOP;

    FOR v_pol IN
        SELECT p.schemaname || '.' || p.tablename || ' (' || p.policyname || ')'
          FROM pg_policies p
         WHERE p.schemaname = 'public'
    LOOP
        RAISE NOTICE 'SPT-02 062 re-check: policy % still present on public table.', v_pol;
        v_residual := true;
    END LOOP;

    IF v_residual THEN
        RAISE NOTICE 'SPT-02 062: residual tenant_id column(s) / policy(ies) detected on public tables (see above). '
            'All remaining tenant_id columns should be Class-G registry columns (tenant_schemas, tenant_hostnames, '
            'tenant_realm_binding, onboarding_registry, rate_limit_buckets, secrets, repository_artifacts, '
            'tenant_artifact_activations, promotion_assertion_runs, pack_update_resolutions, solution_pack_installs, '
            'tnt05_orphans, tnt05_progress, platform_migrations_control_table).';
    ELSE
        RAISE NOTICE 'SPT-02 062: clean — no residual tenant_id columns or RLS policies on public tables.';
    END IF;
END;
$$;
