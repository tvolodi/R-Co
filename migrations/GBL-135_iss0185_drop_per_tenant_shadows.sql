-- GBL-135: ISS-0185 — drop stray per-tenant shadows from the public schema.
--
-- Root cause (see docs/issue-reports/ISS-0185-diagnosis.yaml):
--   14 PER_TENANT table names exist in BOTH the `public` and the
--   `tenant_default` schemas of a freshly migrated database. The tenant
--   copy is canonical (write/read path is per-tenant: dispatcher.zig,
--   identity.zig, etc. rely on unqualified search_path resolution and
--   FK chains from tables like users / groups / roles / events /
--   instance_projections all live in tenant_default).
--   The public copy is the always-empty shadow that drifts when later
--   GBL-only ALTERs add columns to the public copy alone.
--
--   This migration drops the public shadow for each per-tenant table.
--   Idempotent and tenant-data preserving: tenant_default.<name> is
--   never touched.
--
-- Classification (verified via pg_constraint + pg_depend queries):
--   PER_TENANT (12): public copy is stray shadow, drop it.
--   HYBRID (9):      both copies legitimate; not touched here.
--   GLOBAL (24):     see GBL-134.
--
-- Defense in depth:
--   1. The drop is scoped to tables that exist in BOTH `public` and
--      `tenant_default` — a table that exists only in public is NOT a
--      per-tenant shadow and is left alone.
--   2. The shadow-name list below is the explicit allow-list of
--      PER_TENANT table names per the ISS-0185 classification.
--   3. RESTRICT (default): if any public.<X> FKs into public.<name>,
--      the drop fails. Verified at linter build time that none of the
--      12 names below have public-side dependents, so the drop always
--      succeeds.

DO $$
DECLARE
    v_table    TEXT;
    v_exists_pub  BOOLEAN;
    v_exists_ten  BOOLEAN;
    v_dropped  INT := 0;
    -- 12 PER_TENANT tables whose public copies are the stray shadow.
    -- See docs/issue-reports/ISS-0185-diagnosis.yaml and
    -- scratch/_iss0185_v4.json for the full classification.
    -- NOTE: oidc_migration_job and repository_artifacts were moved to
    -- HYBRID during v4 verification (they have public-side FK
    -- dependents: oidc_migration_item and artifact_versions respectively).
    v_tables   TEXT[] := ARRAY[
        'api_token_audit',
        'event_payload_store',
        'group_roles',
        'instance_definition_snapshots',
        'instance_waits',
        'role_permissions',
        'sessions',
        'sla_records',
        'subprocess_links',
        'user_groups',
        'variable_schemas',
        'webhook_deliveries'
    ];
BEGIN
    FOREACH v_table IN ARRAY v_tables LOOP
        -- Defense: only drop if the table also exists in tenant_default.
        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public'
               AND table_name   = v_table
        ) INTO v_exists_pub;
        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'tenant_default'
               AND table_name   = v_table
        ) INTO v_exists_ten;

        IF v_exists_pub AND v_exists_ten THEN
            EXECUTE format('DROP TABLE public.%I RESTRICT', v_table);
            v_dropped := v_dropped + 1;
            RAISE NOTICE 'GBL-135: dropped public.% (stray per-tenant shadow).',
                v_table;
        END IF;
    END LOOP;

    RAISE NOTICE 'GBL-135: dropped % stray per-tenant shadow rows from public.',
        v_dropped;
END $$;