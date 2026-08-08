-- GBL-136: ISS-0617 / GH-566 — follow-up to GBL-134, drop the 8
-- GLOBAL_REGISTRY tenant_default shadow copies GBL-134's v_tables array
-- omitted.
--
-- Root cause (see src/design/iss0617-gbl134-missing-tables-followup.md and
-- docs/issue-reports/ISS-0185-diagnosis.yaml):
--   GBL-134's header comment and the sibling ISS-0185 design both claim
--   full 37-table GLOBAL_REGISTRY coverage, but GBL-134's v_tables array
--   lists only 24 names. 13 names from the diagnosis file's
--   global_registry_tenant_default_is_stray list were never dropped. Of
--   those 13, 5 (api_token_audit, event_payload_store,
--   instance_definition_snapshots, instance_waits, variable_schemas) are
--   EXCLUDED from this migration: GBL-135 already dropped their `public`
--   copies in the opposite (PER_TENANT) direction, so tenant_default is now
--   the only surviving copy of those 5 tables — dropping them here would
--   destroy live data, not a shadow. That diagnosis-file contradiction is
--   tracked separately as ISS-0621/GH-574 and is not this migration's
--   concern. This migration is GBL-134's follow-up, not a replacement —
--   GBL-134 already ran against multiple databases and is immutable.
--
--   The remaining 8 names below are confirmed genuine tenant_default
--   shadows (public copy canonical, tenant copy stray) and are this
--   migration's scope:
--     artifact_versions, event_type_registry_producers, oidc_migration_item,
--     oidc_migration_job, registry_idp_operation_ledger,
--     repository_artifacts, tenant, tenant_hostnames
--
--   Direct consequence (ISS-0617's confirmed_root_cause): TestHarness's pool
--   connection uses search_path=tenant_default,public
--   (tests/integration/helpers.zig:256), so exp601_tier_quota_test.zig's
--   unqualified INSERT INTO repository_artifacts silently landed in the
--   stray tenant_default.repository_artifacts instead of the canonical
--   public.repository_artifacts that src/config/loader.zig's
--   loadConfigArtifact (search_path=public) actually queries, causing
--   TC-EXP-601-01..04 to observe the platform default quota profile instead
--   of the test's override.
--
-- Safety properties (identical to GBL-134):
--   1. The drop is scoped to tables that exist in BOTH `public` and the
--      target tenant schema (a table that exists only in the tenant schema
--      is NOT a shadow — leave it alone).
--   2. The shadow-name list below is the explicit allow-list for this
--      migration's scope.
--   3. Each DROP is idempotent (table existence pre-checked).
--   4. NOT data-destructive on the public side. The public copy is the
--      canonical one and is left untouched.
--   5. RESTRICT mode only — never CASCADE.
--
-- Deviation from GBL-134 (see design doc §3 for full rationale):
--   Unlike GBL-134's 24 names, `artifact_versions` has permanent,
--   legitimate tenant-side FK dependents (artifact_activations,
--   artifact_activation_history, repository_form_schemas — all PER_TENANT,
--   untouched by this migration) that make its RESTRICT drop fail on every
--   tenant schema, every time. This is correct, intended behavior — RESTRICT
--   is PostgreSQL correctly refusing to orphan or cascade-delete legitimate
--   per-tenant data. GBL-134's bare EXECUTE (no per-iteration exception
--   handler) would let this expected failure propagate out of the DO block
--   and roll back every other table's successful drop in the same
--   migration file. This migration therefore wraps each table's
--   DROP TABLE ... RESTRICT in its own BEGIN ... EXCEPTION WHEN
--   dependent_objects_still_exist ... END sub-block: the expected
--   artifact_versions failure is logged via RAISE NOTICE and the loop
--   continues, while any other exception type still propagates and aborts
--   the migration normally (no WHEN OTHERS catch-all).
--
--   tenant_hostnames is listed before tenant in v_tables so the common case
--   (tenant_hostnames_tenant_id_fkey being the only tenant_default-local
--   dependent on tenant) resolves within a single top-to-bottom pass.
--
-- Out of scope (see design doc §9):
--   ISS-0620 (4 wrongly-dropped PER_TENANT tables) and its data recovery,
--   ISS-0621 (diagnosis-file double-classification), and any
--   reclassification of artifact_versions itself.

DO $$
DECLARE
    v_tenant      RECORD;
    v_schema_name TEXT;
    v_public_has  BOOLEAN;
    v_exists      BOOLEAN;
    v_dropped     INT := 0;
    v_skipped     INT := 0;
    -- 8 GLOBAL_REGISTRY tables missing from GBL-134's v_tables array.
    -- tenant_hostnames precedes tenant for FK ordering (see header).
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
            -- Defense (1): only drop if the table also exists in public.
            -- This also makes the migration a safe no-op for
            -- registry_idp_operation_ledger, which does not currently exist
            -- in either schema on the live bpm_test database.
            SELECT EXISTS (
                SELECT 1 FROM information_schema.tables
                 WHERE table_schema = 'public'
                   AND table_name   = v_table
            ) INTO v_public_has;
            IF NOT v_public_has THEN
                CONTINUE;
            END IF;

            -- Defense (2): only drop the shadow copy in the tenant schema.
            SELECT EXISTS (
                SELECT 1 FROM information_schema.tables
                 WHERE table_schema = v_schema_name
                   AND table_name   = v_table
            ) INTO v_exists;

            IF v_exists THEN
                -- RESTRICT (default): if any tenant_default-local table FKs
                -- into this shadow, the drop fails. artifact_versions is
                -- expected to fail here on every tenant schema (see header)
                -- — that failure is caught below and logged, not treated as
                -- fatal. Never CASCADE.
                BEGIN
                    EXECUTE format('DROP TABLE %I.%I RESTRICT', v_schema_name, v_table);
                    v_dropped := v_dropped + 1;
                    RAISE NOTICE 'GBL-136: dropped %.% (stray global shadow).',
                        v_schema_name, v_table;
                EXCEPTION WHEN dependent_objects_still_exist THEN
                    v_skipped := v_skipped + 1;
                    RAISE NOTICE 'GBL-136: skipped %.% — live FK dependent still references it (expected for artifact_versions; see src/design/iss0617-gbl134-missing-tables-followup.md §3.1).',
                        v_schema_name, v_table;
                END;
            END IF;
        END LOOP;
    END LOOP;

    RAISE NOTICE 'GBL-136: dropped % and skipped % stray global-registry shadow(s) across tenant schemas.',
        v_dropped, v_skipped;
END $$;
