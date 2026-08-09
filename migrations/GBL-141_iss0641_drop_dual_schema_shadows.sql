-- GBL-141: ISS-0641 / GH-637 — drop the 14 dual-schema shadow tables
-- reported by tools/lint_dual_schema_table_names.py after a full cold-start
-- replay (ISS-0185-class defect).
--
-- Root cause (see docs/issues/ISS-0641.json and
-- src/design/fix-ISS-0641.md): 10 non-GBL source migrations
-- (004_definitions.sql, 007_timers.sql, 008_identity.sql, 010_dlq.sql,
-- 012_event_retention.sql, 019_idn04_api_token_management.sql,
-- 026_ext05_subprocess_links.sql, 058_repo_artifacts_tenant_activation.sql,
-- 093_exp103_instance_waits.sql, 095_iss0176_lua_script_execution_audit.sql)
-- create these 14 tables without a `-- scope: public` header and (except
-- for tenant_artifact_activations, now fixed) without a scope primitive
-- that could exclude the wrong schema pass, so the migration runner
-- (src/db/migrations.zig migrationScope(), default .all_schemas) replays
-- the unqualified CREATE TABLE in every schema pass, leaving a stray
-- shadow copy behind the canonical one.
--
-- 12 of these 13 PER_TENANT names were already dropped once by
-- migrations/GBL-135_iss0185_drop_per_tenant_shadows.sql; they grew back
-- because GBL-135 only cleaned the shadow that existed at the time and
-- never closed the creation path (no primitive exists to do so — see
-- src/design/fix-ISS-0641.md §4a). tenant_artifact_activations was already
-- targeted once by GBL-134/GBL-138's GLOBAL_REGISTRY drop arrays for the
-- same reason, but this time 058's own source migration is also patched
-- with `-- scope: public` (companion commit), which is expected to close
-- its creation path permanently — unlike the 13 PER_TENANT tables below,
-- which remain expected to require re-application of this migration after
-- any future full cold-start replay until migrations.zig gains a
-- tenant-only scope primitive (tracked as a follow-up in this issue).
--
-- Classification (verified via information_schema.table_constraints /
-- constraint_column_usage FK-chain query — zero FK dependents found on the
-- public copy of any of these 14 tables on the live db_test — and
-- row-count inspection):
--   PER_TENANT (13): tenant_default copy canonical, public copy is the
--     always-empty stray shadow (confirmed 0 rows on all 13 on db_test).
--     Drop public.<name>. Same direction/pattern as GBL-135.
--   GLOBAL_REGISTRY (1): public copy canonical (confirmed 8 live rows on
--     db_test for tenant_artifact_activations), tenant schema copy(ies)
--     are the always-empty stray shadow (confirmed 0 rows). Drop
--     <tenant_schema>.tenant_artifact_activations for every tenant schema.
--     Same direction/pattern as GBL-134/136/138/139/140.
--
-- Safety properties (identical to GBL-135/136/140):
--   1. Each drop is scoped to tables that exist in BOTH schemas being
--      compared — a table that exists only in its canonical schema is not
--      a shadow and is left alone.
--   2. The table-name lists below are the explicit, evidence-backed
--      allow-lists for this migration's scope (see src/design/fix-ISS-0641.md
--      §3 for the per-table classification evidence).
--   3. Each drop is idempotent (existence-guarded) and safe to re-run
--      against an already-clean database (no-op).
--   4. RESTRICT only, never CASCADE. Per-table EXCEPTION WHEN
--      dependent_objects_still_exist guard (GBL-136/140 style): an
--      unexpected live FK dependent produces a logged NOTICE and the
--      migration continues, rather than aborting or silently cascading.
--   5. Not data-destructive on the canonical side: the canonical copy
--      (tenant_default for the 13 PER_TENANT names, public for
--      tenant_artifact_activations) is never touched by this migration.

DO $$
DECLARE
    v_table        TEXT;
    v_exists_pub   BOOLEAN;
    v_exists_ten   BOOLEAN;
    v_dropped      INT := 0;
    v_skipped      INT := 0;
    -- 13 PER_TENANT tables whose public copies are the stray shadow.
    -- 12 already appeared in GBL-135's v_tables array (see file header);
    -- lua_script_execution_audit is the 1 new name (migration 095,
    -- post-dates the original ISS-0185 classification).
    v_per_tenant_tables TEXT[] := ARRAY[
        'api_token_audit',
        'event_payload_store',
        'group_roles',
        'instance_definition_snapshots',
        'instance_waits',
        'lua_script_execution_audit',
        'role_permissions',
        'sessions',
        'sla_records',
        'subprocess_links',
        'user_groups',
        'variable_schemas',
        'webhook_deliveries'
    ];
BEGIN
    -- Step 1: drop the 13 PER_TENANT stray shadows from public.
    FOREACH v_table IN ARRAY v_per_tenant_tables LOOP
        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = v_table
        ) INTO v_exists_pub;
        SELECT EXISTS (
            SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'tenant_default' AND table_name = v_table
        ) INTO v_exists_ten;

        -- Defense: only drop if the table ALSO exists in tenant_default
        -- (its canonical home) — a public-only occurrence is not a shadow.
        IF v_exists_pub AND v_exists_ten THEN
            BEGIN
                EXECUTE format('DROP TABLE public.%I RESTRICT', v_table);
                v_dropped := v_dropped + 1;
                RAISE NOTICE 'GBL-141: dropped public.% (stray per-tenant shadow).',
                    v_table;
            EXCEPTION WHEN dependent_objects_still_exist THEN
                v_skipped := v_skipped + 1;
                RAISE NOTICE 'GBL-141: skipped public.% — unexpected FK dependent.',
                    v_table;
            END;
        END IF;
    END LOOP;

    RAISE NOTICE 'GBL-141: dropped % and skipped % stray per-tenant shadow(s) from public.',
        v_dropped, v_skipped;
END $$;

-- Step 2: drop the 1 GLOBAL_REGISTRY stray shadow
-- (tenant_artifact_activations) from every tenant schema. Loops
-- public.tenant like GBL-136/138/139 for full multi-tenant coverage,
-- even though only tenant_default is currently provisioned on this
-- environment.
DO $$
DECLARE
    v_tenant      RECORD;
    v_schema_name TEXT;
    v_public_has  BOOLEAN;
    v_exists      BOOLEAN;
    v_dropped     INT := 0;
    v_skipped     INT := 0;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
         WHERE table_schema = 'public' AND table_name = 'tenant_artifact_activations'
    ) INTO v_public_has;

    IF NOT v_public_has THEN
        RAISE NOTICE 'GBL-141: public.tenant_artifact_activations does not exist — skipping step 2.';
    ELSE
        FOR v_tenant IN
            SELECT id FROM public.tenant ORDER BY created_at ASC
        LOOP
            IF v_tenant.id = '00000000-0000-0000-0000-000000000000' THEN
                v_schema_name := 'tenant_default';
            ELSE
                v_schema_name := 'tenant_' || replace(v_tenant.id::text, '-', '');
            END IF;

            SELECT EXISTS (
                SELECT 1 FROM information_schema.tables
                 WHERE table_schema = v_schema_name
                   AND table_name   = 'tenant_artifact_activations'
            ) INTO v_exists;

            IF v_exists THEN
                BEGIN
                    EXECUTE format('DROP TABLE %I.tenant_artifact_activations RESTRICT', v_schema_name);
                    v_dropped := v_dropped + 1;
                    RAISE NOTICE 'GBL-141: dropped %.tenant_artifact_activations (stray global shadow).',
                        v_schema_name;
                EXCEPTION WHEN dependent_objects_still_exist THEN
                    v_skipped := v_skipped + 1;
                    RAISE NOTICE 'GBL-141: skipped %.tenant_artifact_activations — unexpected FK dependent.',
                        v_schema_name;
                END;
            END IF;
        END LOOP;

        RAISE NOTICE 'GBL-141: dropped % and skipped % stray tenant_artifact_activations shadow(s) across tenant schemas.',
            v_dropped, v_skipped;
    END IF;
END $$;
