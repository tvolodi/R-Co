-- scope: public
-- SPT-02 migration 061: data copy into tenant schemas.
--
-- Copies every existing per-tenant business row out of the public schema into
-- the tenant's own schema (tenant_<uuid_no_hyphens> or tenant_default), per
-- src/design/spt-02-03-04-schema-per-tenant-migration.md §5.
--
-- This file runs ONCE in the public pass (it reads the public copies and
-- writes into tenant schemas); it is deliberately NOT run per-tenant.
--
-- Design contract:
--   * Per-tenant atomicity  — each tenant's copy is wrapped in a SAVEPOINT; a
--     failure inside one tenant rolls back only that tenant's work (the whole
--     migration still commits the other tenants, and the failed tenant's
--     tenant_schemas.data_migrated_at stays NULL so migration 062's pre-flight
--     gate aborts until the operator reconciles and re-runs).
--   * Idempotency            — a re-run skips tenants whose data_migrated_at is
--     already set; all DDL uses IF NOT EXISTS / IF EXISTS guards.
--   * Interruption recovery  — a crash mid-tenant leaves that tenant's
--     savepoint uncommitted and data_migrated_at NULL; the runner re-attempts
--     cleanly. No duplication is possible because a row is either fully copied
--     (marker set in the same transaction) or not at all.
--
-- Class-B reconciliation (design §4 F9): the copy list below is the canonical
-- start set, reconciled against the live schema at implementation time. Each
-- table is guarded at runtime (to_regclass + information_schema checks) so a
-- table that does not exist in this database's public schema (e.g. legacy
-- business tables already dropped by GBL-112/GBL-123) is skipped without
-- error, and a table whose target tenant-schema copy does not exist is skipped
-- when it has no rows to copy (or surfaced as an unmarked tenant when it does).
--
-- Class-G registry tables (tenant_schemas, tenant_hostnames, tenant_realm_binding,
-- onboarding_registry, platform_migrations_control_table, rate_limit_buckets,
-- secrets, repository_artifacts, tenant_artifact_activations,
-- promotion_assertion_runs, pack_update_resolutions, solution_pack_installs,
-- tnt05_orphans, tnt05_progress) keep their tenant_id column in public and are
-- NOT copied here. schema_migrations is not copied (each tenant schema already
-- carries its own ledger rows from the per-tenant runForSchema pass).

ALTER TABLE public.tenant_schemas
    ADD COLUMN IF NOT EXISTS data_migrated_at TIMESTAMPTZ;

DO $$
DECLARE
    -- Class-B business tables (canonical start set + implementation-time
    -- reconciliation additions). Guarded per-table at runtime below.
    v_class_b text[] := ARRAY[
        'process_definitions',
        'instance_projections',
        'events',
        'events_archive',
        'events_ephemeral',
        'tasks',
        'timers',
        'tokens',
        'audit_entries',
        'audit_log',
        'users',
        'groups',
        'group_members',
        'roles',
        'user_roles',
        'api_tokens',
        'webhook_subscriptions',
        'webhook_deliveries',
        'dead_letter_items',
        'repository_form_schemas',
        'instance_sequence',
        'event_type_registry',
        'event_retention_policies',
        'entity_record_latest',
        'entity_record_events',
        'promotion_reviews',
        'artifact_activations',
        'artifact_activation_history',
        'artifact_activation_groups',
        'entity_definitions',
        'entity_type_instances'
    ];
    v_tenant_id uuid;
    v_schema_name text;
    v_tbl text;
    v_done boolean;
    v_has_tid boolean;
    v_tgt_exists boolean;
    v_src_count bigint;
    v_tgt_count bigint;
    v_failed_tenants text := '';
BEGIN
    -- -----------------------------------------------------------------------
    -- 1. Collect the set of tenants that need data migrated.
    --    (a) every distinct tenant_id present in any Class-B public table that
    --        still carries a tenant_id column, plus
    --    (b) every tenant_schemas row (its tenant may have no data rows yet,
    --        but the marker must still be set so 062's pre-flight can pass).
    -- -----------------------------------------------------------------------
    CREATE TEMP TABLE _spt_tenants (tenant_id uuid PRIMARY KEY) ON COMMIT DROP;
    INSERT INTO pg_temp._spt_tenants
        SELECT ts.tenant_id FROM public.tenant_schemas ts
        ON CONFLICT DO NOTHING;

    FOREACH v_tbl IN ARRAY v_class_b LOOP
        -- Only tables that exist in public AND still have a tenant_id column
        -- participate in the data-migration discovery.
        IF to_regclass('public.' || v_tbl) IS NOT NULL AND
           EXISTS (
               SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'public'
                 AND table_name   = v_tbl
                 AND column_name  = 'tenant_id'
           ) THEN
            EXECUTE format(
                'INSERT INTO pg_temp._spt_tenants SELECT DISTINCT tenant_id FROM public.%I ON CONFLICT DO NOTHING',
                v_tbl
            );
        END IF;
    END LOOP;

    -- -----------------------------------------------------------------------
    -- 2. Copy per tenant, atomically per tenant.
    --
    -- Each iteration is a nested PL/pgSQL BEGIN...EXCEPTION block. PL/pgSQL
    -- gives a nested block implicit savepoint semantics: a failure inside one
    -- tenant rolls back ONLY that tenant's work, the loop continues to the
    -- next tenant, and the outer migration transaction still commits every
    -- other tenant's copy. The failed tenant's tenant_schemas.data_migrated_at
    -- stays NULL so migration 062's pre-flight gate aborts until the operator
    -- reconciles and re-runs. (Manual SAVEPOINT/RELEASE via EXECUTE is NOT
    -- possible — PostgreSQL rejects dynamic execution of transaction commands
    -- with "EXECUTE of transaction commands is not implemented".)
    -- -----------------------------------------------------------------------
    FOR v_tenant_id IN SELECT tenant_id FROM pg_temp._spt_tenants ORDER BY tenant_id LOOP
        BEGIN
            -- Idempotent skip: a tenant whose marker is already set was fully
            -- copied by a previous run (or a concurrent one).
            SELECT EXISTS (
                SELECT 1 FROM public.tenant_schemas
                WHERE tenant_id = v_tenant_id AND data_migrated_at IS NOT NULL
            ) INTO v_done;
            IF v_done THEN
                CONTINUE;
            END IF;

            -- Ensure the tenant schema exists (idempotent — migration 060).
            PERFORM public.bpm_provision_tenant_schema(v_tenant_id);

            -- Derive the tenant schema name (same convention as
            -- schemaNameForTenant / bpm_provision_tenant_schema).
            IF v_tenant_id = '00000000-0000-0000-0000-000000000000'::uuid THEN
                v_schema_name := 'tenant_default';
            ELSE
                v_schema_name := 'tenant_' || replace(v_tenant_id::text, '-', '');
            END IF;

            -- Copy each Class-B table that exists on both sides.
            FOREACH v_tbl IN ARRAY v_class_b LOOP
                IF to_regclass('public.' || v_tbl) IS NULL THEN
                    CONTINUE; -- table absent from public on this database
                END IF;

                SELECT EXISTS (
                    SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'public'
                      AND table_name   = v_tbl
                      AND column_name  = 'tenant_id'
                ) INTO v_has_tid;
                IF NOT v_has_tid THEN
                    CONTINUE; -- no tenant_id column left to filter on
                END IF;

                SELECT to_regclass(format('%I.%I', v_schema_name, v_tbl)) IS NOT NULL
                INTO v_tgt_exists;

                IF NOT v_tgt_exists THEN
                    -- Target table missing. If the public copy has rows for
                    -- this tenant we cannot complete the copy — surface it so
                    -- the tenant stays unmarked (062 pre-flight will gate).
                    EXECUTE format(
                        'SELECT count(*) FROM public.%I WHERE tenant_id = $1',
                        v_tbl
                    ) INTO v_src_count USING v_tenant_id;
                    IF v_src_count > 0 THEN
                        RAISE EXCEPTION
                            'SPT-02 061: cannot copy table % for tenant % — target table %I.%I does not exist',
                            v_tbl, v_tenant_id::text, v_schema_name, v_tbl;
                    ELSE
                        RAISE NOTICE 'SPT-02 061: skipping % (no target table %I.%I and no rows to copy)',
                            v_tbl, v_schema_name, v_tbl;
                    END IF;
                    CONTINUE;
                END IF;

                -- Copy this tenant's rows (column sets match by construction —
                -- both sides derive from the same migration files; tenant_id
                -- still exists on both sides at 061 time, 062 drops it later).
                EXECUTE format(
                    'INSERT INTO %I.%I SELECT * FROM public.%I WHERE tenant_id = $1',
                    v_schema_name, v_tbl, v_tbl
                ) USING v_tenant_id;

                -- Row-count parity: copied count must equal source count.
                EXECUTE format(
                    'SELECT count(*) FROM %I.%I',
                    v_schema_name, v_tbl
                ) INTO v_tgt_count;
                EXECUTE format(
                    'SELECT count(*) FROM public.%I WHERE tenant_id = $1',
                    v_tbl
                ) INTO v_src_count USING v_tenant_id;

                IF v_tgt_count <> v_src_count THEN
                    RAISE EXCEPTION
                        'SPT-02 061: row-count mismatch for %I.%I (copied % vs source % for tenant %)',
                        v_schema_name, v_tbl, v_tgt_count, v_src_count, v_tenant_id::text;
                END IF;
            END LOOP;

            -- Mark the tenant fully migrated in the same transaction/block as
            -- the copy (SPT-02 AC6 detection point).
            UPDATE public.tenant_schemas
               SET data_migrated_at = NOW()
             WHERE tenant_id = v_tenant_id;
        EXCEPTION
            WHEN OTHERS THEN
                -- The nested block's implicit savepoint rolls back only this
                -- tenant's work; the tenant stays unmarked (062 pre-flight gates).
                v_failed_tenants := v_failed_tenants || v_tenant_id::text || ', ';
                RAISE WARNING 'SPT-02 061: data copy for tenant % failed (left unmarked; 062 pre-flight will gate): %',
                    v_tenant_id::text, SQLERRM;
        END;
    END LOOP;

    IF v_failed_tenants <> '' THEN
        RAISE WARNING 'SPT-02 061: % tenant(s) left unmigrated: % (resolve and re-run — migration 062 will abort until data_migrated_at is set for every tenant_schemas row).',
            (SELECT count(*) FROM string_to_array(trim(trailing ', ' from v_failed_tenants), ',')),
            trim(trailing ', ' from v_failed_tenants);
    END IF;
END;
$$;
