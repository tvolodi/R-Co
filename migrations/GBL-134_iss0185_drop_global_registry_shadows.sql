-- GBL-134: ISS-0185 — drop stray global-registry shadows from tenant schemas.
--
-- Root cause (see docs/issue-reports/ISS-0185-diagnosis.yaml):
--   45 table names exist in BOTH the `public` and the `tenant_default`
--   schemas of a freshly migrated database, because the source migrations
--   that create them are non-GBL and default to .all_schemas scope.
--   This migration drops the per-tenant shadow copies of GLOBAL_REGISTRY
--   tables (canonical home = public). HYBRID tables (where both public and
--   tenant have legitimate FK chains anchored to their respective copies)
--   are NOT touched here.
--
--   The companion migration GBL-135 drops stray public shadows of
--   PER_TENANT tables (canonical home = tenant schema).
--
--   Both are guarded by tools/lint_dual_schema_table_names.py so future
--   fresh provisions do not re-create the duplicates.
--
-- Classification (verified via pg_constraint + pg_depend queries):
--   GLOBAL (24):  shadow in tenant_default must be dropped.
--   HYBRID (7):   both copies legitimate; do NOT drop either.
--   PER_TENANT:   see GBL-135.
--
-- Safety properties:
--   1. The drop is scoped to tables that exist in BOTH `public` and the
--      target tenant schema (a table that exists only in the tenant schema
--      is NOT a shadow — leave it alone).
--   2. The shadow-name list below is the explicit allow-list of GLOBAL
--      table names per the ISS-0185 classification. New duplicates that
--      appear after this migration runs are caught by the new linter.
--   3. Each DROP is idempotent (table existence pre-checked) and wrapped
--      in a single transaction so partial failures roll back cleanly.
--   4. NOT data-destructive on the public side. The public copy is the
--      canonical one and is left untouched.

DO $$
DECLARE
    v_tenant      RECORD;
    v_schema_name TEXT;
    v_public_has  BOOLEAN;
    v_exists      BOOLEAN;
    v_dropped     INT := 0;
    -- 24 GLOBAL_REGISTRY tables whose tenant_default/<uuid> copies are the
    -- stray shadow. See docs/issue-reports/ISS-0185-diagnosis.yaml and
    -- scratch/_iss0185_v4.json for the full classification.
    v_tables      TEXT[] := ARRAY[
        'agent_bootstrap_audit',
        'agent_bootstrap_state',
        'agent_identity_binding',
        'agent_secret_rotation',
        'artifact_activation_groups',
        'entity_definitions',
        'entity_record_latest',
        'entity_type_instances',
        'federation_attribute_mapping',
        'idp_adapter_audit',
        'idp_federation_binding',
        'idp_operation_ledger',
        'idp_transaction_log',
        'jit_provisioning_config',
        'metric_snapshots',
        'obs_alert_hook_emission_state',
        'obs_alert_trigger_state',
        'onboarding_registry',
        'rate_limit_buckets',
        'realm_claim_mapping_config',
        'realm_deletion_tracker',
        'service_catalog',
        'subsystem_health_probe',
        'tenant_artifact_activations'
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
            -- Without this guard we could destroy legitimately per-tenant
            -- tables if a future migration ever reused one of these names.
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
                -- RESTRICT (default): if any tenant_default table FKs into
                -- this shadow, the drop fails. Verified at linter build time
                -- that none of the 24 names below have tenant-side
                -- dependents, so the drop always succeeds.
                EXECUTE format('DROP TABLE %I.%I RESTRICT', v_schema_name, v_table);
                v_dropped := v_dropped + 1;
                RAISE NOTICE 'GBL-134: dropped %.% (stray global shadow).',
                    v_schema_name, v_table;
            END IF;
        END LOOP;
    END LOOP;

    RAISE NOTICE 'GBL-134: dropped % stray global-registry shadow rows across tenant schemas.',
        v_dropped;
END $$;