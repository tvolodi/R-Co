-- scope: public
-- GBL-139: ISS-0183 / GH-516 — reconcile bpm_test's tenant_default schema
-- for the 8 GLOBAL_REGISTRY table names GBL-136 drops, which GBL-138's own
-- reconciliation list omitted.
--
-- Root cause:
--   GBL-138 (ISS-0623/GH-580) re-applied GBL-134's and GBL-135's DROP logic
--   after tenant_default was accidentally dropped and reprovisioned from
--   scratch mid-run on 2026-08-08, resurrecting every shadow table GBL-134/
--   GBL-135/GBL-136/GBL-137 had previously cleaned up. GBL-138's
--   v_tenant_shadow_tables array explicitly copies "GBL-134's 11
--   GLOBAL_REGISTRY names ... present as duplicates in this reprovisioning
--   event" but never included GBL-136's own 8-name follow-up list (GBL-136
--   was itself a follow-up patching a gap in GBL-134's original array, so
--   GBL-138 reconciling only GBL-134's names silently left GBL-136's names
--   out of the reconciliation).
--
--   Confirmed via direct read-only query against this workspace's bpm_test
--   (docker exec r-co-2-db_test-1 psql, port 5453): 7 of GBL-136's 8 names
--   (registry_idp_operation_ledger never existed here, per GBL-136's own
--   comment) currently exist as duplicates in BOTH public and tenant_default:
--     artifact_versions, event_type_registry_producers, oidc_migration_item,
--     oidc_migration_job, repository_artifacts, tenant, tenant_hostnames
--
--   Direct consequence for ISS-0183/GH-516 (tests/integration/
--   repository_test.zig): TC-REPO-02-01's unqualified
--   information_schema.table_constraints probe for
--   repository_artifacts_pkey resolves both the public and tenant_default
--   copies (information_schema views are not search_path-filtered), so the
--   test observes 2 rows where the schema's intent is 1 canonical PRIMARY
--   KEY constraint. This is the exact ISS-0185 dual-schema-shadow symptom
--   GBL-134..138 exist to eliminate, reintroduced by the reprovisioning
--   event GBL-138 already documented but did not fully reconcile.
--
-- This migration is GBL-136's reconciliation follow-up, not a replacement --
-- it re-applies GBL-136's exact DROP logic (same table list, same
-- RESTRICT-only safety posture, same per-table exception handling) now that
-- tenant_default has been reprovisioned again and these shadows are back.
-- GBL-134/135/136/137/138 are immutable per this lineage's established
-- convention and are left unmodified.
--
-- Safety properties (identical to GBL-136/GBL-138):
--   1. The drop is scoped to tables that exist in BOTH public and the
--      target tenant schema (a table that exists only in the tenant schema
--      is NOT a shadow -- leave it alone).
--   2. The shadow-name list below is GBL-136's own 8-name allow-list --
--      no new classification decisions are made here.
--   3. Each DROP is idempotent (table existence pre-checked); safe to
--      re-run against a database where the duplicates are already gone.
--   4. NOT data-destructive on the public side. The public copy is the
--      canonical one and is left untouched.
--   5. RESTRICT mode only -- never CASCADE. artifact_versions is expected
--      to fail here on every tenant schema (permanent, legitimate
--      tenant-side FK dependents: artifact_activations,
--      artifact_activation_history, repository_form_schemas) -- that
--      failure is caught and logged, not fatal, matching GBL-136 exactly.

DO $$
DECLARE
    v_tenant      RECORD;
    v_schema_name TEXT;
    v_public_has  BOOLEAN;
    v_exists      BOOLEAN;
    v_dropped     INT := 0;
    v_skipped     INT := 0;
    -- GBL-136's exact 8-name allow-list, re-applied after reprovisioning.
    v_tables      TEXT[] := ARRAY[
        'event_type_registry_producers',
        'oidc_migration_item',
        'oidc_migration_job',
        'registry_idp_operation_ledger',
        'repository_artifacts',
        'tenant_hostnames',
        'tenant',
        'artifact_versions'
    ];
    v_table       TEXT;
BEGIN
    FOR v_tenant IN
        SELECT id FROM public.tenant ORDER BY created_at ASC
    LOOP
        IF v_tenant.id = '00000000-0000-0000-0000-000000000000' THEN
            v_schema_name := 'tenant_default';
        ELSE
            v_schema_name := 'tenant_' || replace(v_tenant.id::text, '-', '');
        END IF;

        FOREACH v_table IN ARRAY v_tables LOOP
            SELECT EXISTS (
                SELECT 1 FROM information_schema.tables
                 WHERE table_schema = 'public'
                   AND table_name   = v_table
            ) INTO v_public_has;
            IF NOT v_public_has THEN
                CONTINUE;
            END IF;

            SELECT EXISTS (
                SELECT 1 FROM information_schema.tables
                 WHERE table_schema = v_schema_name
                   AND table_name   = v_table
            ) INTO v_exists;

            IF v_exists THEN
                BEGIN
                    EXECUTE format('DROP TABLE %I.%I RESTRICT', v_schema_name, v_table);
                    v_dropped := v_dropped + 1;
                    RAISE NOTICE 'GBL-139: dropped %.% (re-resurrected global shadow, GBL-136 follow-up).',
                        v_schema_name, v_table;
                EXCEPTION WHEN dependent_objects_still_exist THEN
                    v_skipped := v_skipped + 1;
                    RAISE NOTICE 'GBL-139: skipped %.% — live FK dependent still references it (expected for artifact_versions).',
                        v_schema_name, v_table;
                END;
            END IF;
        END LOOP;
    END LOOP;

    RAISE NOTICE 'GBL-139: dropped % and skipped % re-resurrected global-registry shadow(s) across tenant schemas.',
        v_dropped, v_skipped;
END $$;
