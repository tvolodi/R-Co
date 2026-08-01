-- GBL-105: One-time reconciliation of public.schema_migrations ledger for ISS-0112.
--
-- Root cause: the shared db_test database has drifted out of the INV-TI-1
-- invariant (docs/guides/test_infrastructure_guide.md §2). The ledger table
-- public.schema_migrations reports only 1 row (a stale, single-migration
-- entry from an earlier partial run) while migrations/ carries 97 SQL files.
-- Migrations.runForSchema() treats every filename present in the ledger as
-- already-applied and silently skips it; therefore every subsequent
-- `zig build migrate` run produces 96 no-ops and the schema never converges
-- with the canonical object set.
--
-- The applier guard (see src/db/migrations.zig, Change 2 of the design at
-- src/design/fix-iss0112.md) handles this case from now on: if a migration's
-- first object is already present in the target schema but the ledger row
-- is missing, the applier logs a notice and re-applies without re-recording.
-- This migration is the one-time bootstrap that makes the ledger match the
-- on-disk file set so the guard is correct on subsequent runs.
--
-- Idempotency: every CREATE/ALTER uses IF NOT EXISTS; every ledger insert
-- uses ON CONFLICT DO NOTHING; the corrective can be re-applied safely.
--
-- GBL-prefix: per the GBL-104 convention, GBL-prefixed files operate on
-- public (only ever). The applier skips them for non-public schemas.
--
-- Self-mark: this file is recorded by Migrations.runForSchema()'s normal
-- INSERT after this file's body executes successfully. The applier guard
-- (Change 2) reads the `-- reapply_on_drift: true` header below and
-- re-applies this corrective idempotently when the ledger is missing the
-- row but the schema already carries the reconciliation effects.
--
-- reapply_on_drift: true

DO $$
DECLARE
    v_filenames TEXT[] := ARRAY[
        '001_event_store.sql',
        '002_event_type_registry.sql',
        '003_event_archive.sql',
        '004_definitions.sql',
        '005_instances.sql',
        '006_tasks.sql',
        '007_timers.sql',
        '008_identity.sql',
        '009_audit_log.sql',
        '010_dlq.sql',
        '011_webhook_subscriptions.sql',
        '012_event_retention.sql',
        '013_event_archive_idempotency.sql',
        '014_definition_stage.sql',
        '015_timers_status_constraint.sql',
        '016_timer_recurrence_fields.sql',
        '017_identity_user_registry.sql',
        '018_identity_group_members.sql',
        '019_idn04_api_token_management.sql',
        '020_obs03_audit_entries.sql',
        '021_obs05_dead_letter_context.sql',
        '022_obs06_alerting_state.sql',
        '023_ext02_webhook_event_dispatch.sql',
        '024_webhook_subscription_audit.sql',
        '025_webhook_delivery_event_id_nullable.sql',
        '026_ext05_subprocess_links.sql',
        '027_adp01_event_store_tenant.sql',
        '028_adp02_tenant_scope_persistence.sql',
        '029_adp04_user_tenant_binding.sql',
        '030_adp04a_external_identity_linkage.sql',
        '031_adp04b_tenant_realm_binding.sql',
        '032_adp05_instance_artifact_hash.sql',
        '033_adp06_pipeline_run_correlation.sql',
        '034_adp07_agent_role_reserved_usernames.sql',
        '035_adp09_tamper_evident_audit_chain.sql',
        '036_adp10_agent_io_capture_audit.sql',
        '037_adp11_replay_safe_retention_policy.sql',
        '038_oidc_claim_mapping_config.sql',
        '039_jit_provisioning_config.sql',
        '040_oidc10_role_source.sql',
        '041_oidc15_realm_deletion_tracker.sql',
        '042_oidc16_26_agent_lifecycle_foundations.sql',
        '043_oidc34_migration_helper.sql',
        '044_fix_definition_conflict_constraint.sql',
        '045_repository_artifacts.sql',
        '046_repository_activations.sql',
        '047_repository_form_schemas.sql',
        '048_repository_event_types.sql',
        '049_repository_service_catalog.sql',
        '050_tenant_hostnames.sql',
        '050_xc01_trace_id_audit.sql',
        '051_xc02_audit_immutability.sql',
        '052_xc03_configuration_repository.sql',
        '053_xc04_kernel_determinism.sql',
        '054_xc05_deterministic_replay.sql',
        '055_xc06_backwards_compatibility.sql',
        '056_onboarding_registry.sql',
        '056_xc03_configuration_repository_fix.sql',
        '057_iss0054_audit_chain_function_reconcile.sql',
        '058_repo_artifacts_tenant_activation.sql',
        '059_fix_audit_chain_trigger_args.sql',
        '060_schema_per_tenant_bootstrap.sql',
        '069_retroactive_tenant_schema_provision.sql',
        '070_retroactive_tenant_schema_provision_backfill_fix.sql',
        '071_tnt04_public_schema_audit_flag.sql',
        '072_tnt01_rename_legacy_tables.sql',
        '081_iss101_timers_failed_status.sql',
        '082_iss102_tasks_claimed_by.sql',
        '083_instances_token_model.sql',
        '085_iss106_webhook_deliveries_outbox.sql',
        '086_iss107_tenant_storage_mode.sql',
        '087_default_tenant_storage_mode_cutover.sql',
        '088_iss105_instances_token_model_backfill.sql',
        '092_iss303_timer_fire_error_count.sql',
        '093_exp103_instance_waits.sql',
        '094_entity_subsystem.sql',
        'GBL-073_tnt01_drop_legacy_public_business_tables.sql',
        'GBL-074_tnt05_backfill_tracking.sql',
        'GBL-075_tnt05_backfill_run.sql',
        'GBL-076_tnt06_db_host_column.sql',
        'GBL-077_tnt07_rls_cleanup.sql',
        'GBL-078_svc01_service_catalog_scope.sql',
        'GBL-079_svc04_cross_schema_proc_def_refs.sql',
        'GBL-080_env01_tenant_type_field.sql',
        'GBL-081_iss103_audit_resource_id_text.sql',
        'GBL-082_fix_audit_chain_resource_id_text.sql',
        'GBL-083_rate_limit_buckets.sql',
        'GBL-084_rls_removal.sql',
        'GBL-085_state_snapshots.sql',
        'GBL-097_exp301_effects_outbox.sql',
        'GBL-098_exp301_effects_event_types.sql',
        'GBL-099_exp302_service_task_effect_ref.sql',
        'GBL-100_exp501_secrets.sql',
        'GBL-101_exp501_secrets_corrective.sql',
        'GBL-102_iss503_guard_tenant_type_scope.sql',
        'GBL-103_iss0100_guard_tc_slug_scope.sql',
        'GBL-104_iss0108_drop_stray_tenant_schema_migrations.sql'
    ];
    v_tenant RECORD;
    v_tenant_schema TEXT;
    v_inserted_public INTEGER := 0;
    v_inserted_tenant INTEGER := 0;
    v_filename TEXT;
BEGIN
    -- ── Step 1: Backfill public.schema_migrations for all 96 prior files. ──
    -- Excludes 'GBL-105_iss0112_schema_ledger_reconcile.sql' itself (the applier
    -- records that via its normal flow after this block completes). Use the
    -- native ON CONFLICT DO NOTHING to keep this idempotent on re-runs.
    FOREACH v_filename IN ARRAY v_filenames LOOP
        INSERT INTO public.schema_migrations (schema_name, version)
        VALUES ('public', v_filename)
        ON CONFLICT (schema_name, version) DO NOTHING;
        IF FOUND THEN
            v_inserted_public := v_inserted_public + 1;
        END IF;
    END LOOP;

    RAISE NOTICE 'GBL-105: inserted % public.schema_migrations rows (96 expected on first run, 0 on re-run).', v_inserted_public;

    -- ── Step 2: Per-tenant-schema ledger backfill. ─────────────────────────
    -- The migration ledger is keyed by (schema_name, version). For every
    -- tenant that is provisioned via storage_mode='SCHEMA' AND whose schema
    -- still exists (i.e. has not been dropped by GBL-104), insert a row for
    -- every non-GBL migration file. GBL-prefixed migrations are
    -- blanket-skipped by Migrations.runForSchema() for non-public schemas
    -- (see src/db/migrations.zig::Migrations.runForSchema, line ~200), so
    -- we do NOT include them here — they should never appear in a per-tenant
    -- ledger row.
    FOR v_tenant IN
        SELECT id, storage_mode FROM public.tenant WHERE storage_mode = 'SCHEMA'
    LOOP
        IF v_tenant.id = '00000000-0000-0000-0000-000000000000'::uuid THEN
            v_tenant_schema := 'tenant_default';
        ELSE
            v_tenant_schema := 'tenant_' || replace(v_tenant.id::text, '-', '');
        END IF;

        -- Only insert if the schema still exists in pg_namespace.
        IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = v_tenant_schema) THEN
            FOREACH v_filename IN ARRAY v_filenames LOOP
                -- Skip GBL-prefixed filenames for non-public schemas.
                CONTINUE WHEN v_filename LIKE 'GBL-%';
                INSERT INTO public.schema_migrations (schema_name, version)
                VALUES (v_tenant_schema, v_filename)
                ON CONFLICT (schema_name, version) DO NOTHING;
                IF FOUND THEN
                    v_inserted_tenant := v_inserted_tenant + 1;
                END IF;
            END LOOP;
        END IF;
    END LOOP;

    RAISE NOTICE 'GBL-105: inserted % per-tenant-schema ledger rows.', v_inserted_tenant;

    -- ── Step 3: Object-additive fixes (each one IF NOT EXISTS / guarded DO-block). ──
    -- 3a) webhook_subscriptions.secret_ref column (Cluster A complaint).
    --     GBL-100 already adds it conditionally inside its own block, but
    --     legacy DBs that pre-date GBL-100's IF-to-regclass guard may lack
    --     the column. Re-apply idempotently.
    IF to_regclass('public.webhook_subscriptions') IS NOT NULL THEN
        ALTER TABLE public.webhook_subscriptions
            ADD COLUMN IF NOT EXISTS secret_ref TEXT;
    END IF;

    -- 3b) public.tenant_realm_binding table (Cluster D complaint).
    --     Migration 031 already creates it; this is a safety-net re-apply
    --     for legacy DBs whose earlier 031 apply was rolled back or
    --     partially-applied (which is the drift mode this whole migration
    --     exists to recover from).
    CREATE TABLE IF NOT EXISTS public.tenant_realm_binding (
        id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
        tenant_id       UUID NOT NULL REFERENCES public.tenant(id) ON DELETE CASCADE,
        realm           TEXT NOT NULL,
        binding_status  TEXT NOT NULL DEFAULT 'PENDING'
                        CHECK (binding_status IN ('PENDING','ACTIVE','REVOKED','FAILED')),
        created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        UNIQUE (tenant_id, realm)
    );
    CREATE INDEX IF NOT EXISTS idx_tenant_realm_binding_tenant
        ON public.tenant_realm_binding (tenant_id);
    CREATE INDEX IF NOT EXISTS idx_tenant_realm_binding_realm
        ON public.tenant_realm_binding (realm);

    -- 3c) entity_type_instances table — already created by migration 094 in
    --     the public schema. The per-tenant-scope variant must also exist in
    --     each SCHEMA-storage-mode tenant that EXP-201/202 tests run against.
    --     This block iterates the same tenant set as Step 2 and ensures each
    --     schema carries the table (Cluster D/E complaint).
    FOR v_tenant IN
        SELECT id, storage_mode FROM public.tenant WHERE storage_mode = 'SCHEMA'
    LOOP
        IF v_tenant.id = '00000000-0000-0000-0000-000000000000'::uuid THEN
            v_tenant_schema := 'tenant_default';
        ELSE
            v_tenant_schema := 'tenant_' || replace(v_tenant.id::text, '-', '');
        END IF;

        IF EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = v_tenant_schema) THEN
            EXECUTE format(
                'CREATE TABLE IF NOT EXISTS %I.entity_type_instances (
                    entity_type     TEXT        PRIMARY KEY,
                    tenant_id       UUID        NOT NULL,
                    instance_id     UUID        NOT NULL UNIQUE,
                    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
                )',
                v_tenant_schema
            );
        END IF;
    END LOOP;

    -- 3d) Constraint upgrades (Cluster A / Cluster D complaints). The
    --     constraint definitions below match the canonical
    --     application-constant values referenced by
    --     src/webhooks/dispatcher.zig (webhook_deliveries.status) and
    --     src/db/provisioning.zig (tenant.storage_mode). Each upgrade is
    --     idempotent via a guard that checks whether the constraint
    --     already exists with the canonical definition.
    --     Postgres does not support `ALTER CONSTRAINT IF NOT EXISTS`, so we
    --     guard by checking pg_constraint for the canonical definition
    --     before deciding whether to drop + recreate.
    IF to_regclass('public.webhook_deliveries') IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
             WHERE conname = 'webhook_deliveries_status_check'
               AND pg_get_constraintdef(oid) LIKE '%PENDING%DELIVERED%FAILED%RETRYING%'
        ) THEN
            ALTER TABLE public.webhook_deliveries
                DROP CONSTRAINT IF EXISTS webhook_deliveries_status_check;
            ALTER TABLE public.webhook_deliveries
                ADD CONSTRAINT webhook_deliveries_status_check
                CHECK (status IN ('PENDING','DELIVERED','FAILED','RETRYING'));
        END IF;
    END IF;

    IF to_regclass('public.tenant') IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
             WHERE conname = 'tenant_storage_mode_check'
               AND pg_get_constraintdef(oid) LIKE '%LEGACY_RLS%SCHEMA%'
        ) THEN
            ALTER TABLE public.tenant
                DROP CONSTRAINT IF EXISTS tenant_storage_mode_check;
            ALTER TABLE public.tenant
                ADD CONSTRAINT tenant_storage_mode_check
                CHECK (storage_mode IN ('LEGACY_RLS','SCHEMA'));
        END IF;
    END IF;

    -- ── Step 4: Summary notice. ───────────────────────────────────────────
    RAISE NOTICE 'GBL-105: reconciliation complete. public rows inserted: %, tenant rows inserted: %.', v_inserted_public, v_inserted_tenant;
END $$;
