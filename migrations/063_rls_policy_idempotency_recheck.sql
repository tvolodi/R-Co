-- scope: public
-- SPT-02 migration 063: belt-and-suspenders RLS policy idempotency re-check.
--
-- Re-issues DROP POLICY IF EXISTS for every previously-known policy name on
-- every affected Class-B public table (SPT-02 AC4 — the belt-and-suspenders
-- idempotency check), re-asserts that bpm_effective_tenant_id() is gone, and
-- reports the end state via RAISE NOTICE (never EXCEPTION) so a re-run on a
-- fully migrated database exits 0 with the state unchanged (SPT-02 AC5) while
-- a genuinely dirty state is surfaced to the operator.
--
-- Runs ONCE in the public pass (never per-tenant). All per-table DDL is
-- %I-interpolated via EXECUTE format('... %I.%I ...', 'public', <table>) —
-- no static public.<business_table> reference, no bare <table>.

DO $$
DECLARE
    -- Class-G registry allow-list (must mirror migration 062 exactly).
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
    v_any_policy_dropped boolean := false;
    v_residual boolean := false;
BEGIN
    -- -----------------------------------------------------------------------
    -- 1. Belt-and-suspenders: re-issue DROP POLICY IF EXISTS for EVERY policy
    --    still present on any public Class-B table (covers the known
    --    <table>_tenant_policy names from the RLS migrations and any drift).
    -- -----------------------------------------------------------------------
    FOR v_tbl IN
        SELECT c.table_name::text
          FROM information_schema.columns c
         WHERE c.table_schema = 'public'
           AND c.column_name  = 'tenant_id'
           AND c.table_name <> ALL (v_class_g)
        UNION
        SELECT DISTINCT p.tablename
          FROM pg_policies p
         WHERE p.schemaname = 'public'
        ORDER BY 1
    LOOP
        FOR v_pol IN
            SELECT policyname FROM pg_policies
             WHERE schemaname = 'public' AND tablename = v_tbl
        LOOP
            EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I', v_pol, 'public', v_tbl);
            v_any_policy_dropped := true;
            RAISE NOTICE 'SPT-02 063: dropped policy % on %I.%I', v_pol, 'public', v_tbl;
        END LOOP;
    END LOOP;

    -- -----------------------------------------------------------------------
    -- 2. Re-assert the end state (idempotent; no-op on a healthy database).
    -- -----------------------------------------------------------------------
    DROP FUNCTION IF EXISTS public.bpm_effective_tenant_id() CASCADE;

    FOR v_tbl IN
        SELECT c.table_name::text
          FROM information_schema.columns c
         WHERE c.table_schema = 'public'
           AND c.column_name  = 'tenant_id'
           AND c.table_name <> ALL (v_class_g)
        ORDER BY 1
    LOOP
        RAISE NOTICE 'SPT-02 063 re-check: public table % still carries a tenant_id column (Class-B residual — operator should inspect).', v_tbl;
        v_residual := true;
    END LOOP;

    FOR v_pol IN
        SELECT p.schemaname || '.' || p.tablename || ' (' || p.policyname || ')'
          FROM pg_policies p
         WHERE p.schemaname = 'public'
    LOOP
        RAISE NOTICE 'SPT-02 063 re-check: policy % still present on a public table (operator should inspect).', v_pol;
        v_residual := true;
    END LOOP;

    IF v_any_policy_dropped THEN
        RAISE NOTICE 'SPT-02 063: dropped at least one residual RLS policy (belt-and-suspenders).';
    END IF;

    IF v_residual THEN
        RAISE WARNING 'SPT-02 063: residual tenant_id column(s) / RLS policy(ies) detected on public Class-B tables — see NOTICE above.';
    ELSE
        RAISE NOTICE 'SPT-02 063: clean — no residual tenant_id columns or RLS policies on public Class-B tables.';
    END IF;
END;
$$;
