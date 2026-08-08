-- GBL-137: ISS-0620 / GH-573 — forward-fix recreating the 4 PER_TENANT tables
-- that GBL-134 wrongly dropped from tenant_default.
--
-- Root cause (see docs/issues/ISS-0620.json and
-- src/design/iss0620-gbl134-per-tenant-forward-fix.md):
--   GBL-134's v_tables allow-list wrongly included 4 table names --
--   artifact_activation_groups, entity_definitions, entity_record_latest,
--   entity_type_instances -- that docs/issue-reports/ISS-0185-diagnosis.yaml's
--   own classification_table.per_tenant_public_is_stray list classifies as
--   PER_TENANT (canonical home = tenant_default; public is the stray
--   shadow) -- the OPPOSITE of what GBL-134 assumed (GLOBAL_REGISTRY,
--   canonical home = public). GBL-134 unconditionally DROP TABLE ...
--   RESTRICT'd these 4 tables' tenant_default copies in every tenant
--   schema, with no row-count check, no backup, no guard.
--
--   GBL-134 already ran against multiple databases (the shared bpm_test
--   database and workspace r-co-2's bpm_dev database, both confirmed via
--   schema_migrations) and is immutable -- this migration does not rewrite
--   it, matching the established convention already used by GBL-136 for
--   GBL-134's other defect (the 8-table GLOBAL_REGISTRY gap).
--
--   Any tenant_default row that existed for these 4 tables before GBL-134's
--   drop and was not already separately present in the public copy is
--   unrecoverable via the schema alone -- no WAL archiving is configured in
--   this environment (archive_mode=off, confirmed) and no backup was found.
--   This migration ONLY recreates the empty table structure going forward
--   so future tenant provisioning (and any tenant schema already missing
--   these tables) is not silently broken. It performs no data recovery.
--
-- Safety properties:
--   1. Purely additive: CREATE TABLE IF NOT EXISTS / CREATE INDEX IF NOT
--      EXISTS only. No DROP, no TRUNCATE, no DELETE, no data migration.
--   2. Idempotent: safe to run against a tenant schema that already has
--      these tables (e.g. bpm_test's tenant_default, which was reprovisioned
--      from scratch after GBL-134 ran and already has empty copies) and
--      against one that is missing them (e.g. bpm_dev's tenant_default,
--      where GBL-134's drop is still in effect).
--   3. No FK dependency ordering concerns: verified via grep across
--      src/**/*.zig and migrations/**/*.sql that none of the 4 tables has
--      any live FK dependent anywhere in the schema (unlike GBL-136's
--      artifact_versions, which required a per-table exception handler).
--   4. Schema shape copied verbatim from the tables' original creating
--      migrations (094_entity_subsystem.sql for entity_definitions /
--      entity_type_instances / entity_record_latest; 046_repository_
--      activations.sql for artifact_activation_groups) and cross-checked
--      against the still-live public.<table> copies in both known-affected
--      databases, which match exactly. Constraint/index names are
--      unqualified and unique only within their own schema (PostgreSQL
--      scopes both to the containing schema), so the same literal names
--      used by the original public-schema migrations are reused here
--      per-tenant-schema without collision.
--   5. GBL- prefix makes this migration run in the public pass only per
--      migrationScope() (src/db/migrations.zig) -- but its DO block below
--      iterates public.tenant itself and computes each tenant schema name,
--      the same technique GBL-134 and GBL-136 already use, so it reaches
--      every tenant schema despite running in the public pass.
--
-- Out of scope (see design doc §9):
--   Dropping the now-stray public copies of these 4 tables (destructive;
--   needs its own reviewed migration and its own issue). Any data-recovery
--   action for pre-drop rows (no recovery path was found in this
--   environment). Diagnosing bpm_test's unrelated tenant_default
--   reprovisioning event.

DO $$
DECLARE
    v_tenant      RECORD;
    v_schema_name TEXT;
    v_schema_exists BOOLEAN;
    v_processed   INT := 0;
    v_skipped     INT := 0;
BEGIN
    FOR v_tenant IN
        SELECT id FROM public.tenant ORDER BY created_at ASC
    LOOP
        IF v_tenant.id = '00000000-0000-0000-0000-000000000000' THEN
            v_schema_name := 'tenant_default';
        ELSE
            v_schema_name := 'tenant_' || replace(v_tenant.id::text, '-', '');
        END IF;

        -- Guard: only act on tenant schemas that actually exist. A
        -- public.tenant row does not guarantee a matching schema was
        -- provisioned (e.g. LEGACY_RLS-mode tenants, or a tenant row
        -- created between this check and a concurrent provisioning step
        -- elsewhere) -- skip cleanly rather than erroring, matching
        -- GBL-134/GBL-136's existence-checked, non-fatal treatment of
        -- absent schema state.
        SELECT EXISTS (
            SELECT 1 FROM pg_namespace WHERE nspname = v_schema_name
        ) INTO v_schema_exists;
        IF NOT v_schema_exists THEN
            v_skipped := v_skipped + 1;
            RAISE NOTICE 'GBL-137: skipped % — schema does not exist (no tenant schema provisioned for this tenant row).',
                v_schema_name;
            CONTINUE;
        END IF;

        -- ── entity_definitions (source: migrations/094_entity_subsystem.sql) ──
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %1$I.entity_definitions ('
            '    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),'
            '    tenant_id               UUID        NOT NULL,'
            '    name                    TEXT        NOT NULL,'
            '    display_name            TEXT        NOT NULL,'
            '    description             TEXT,'
            '    definition_json         JSONB       NOT NULL,'
            '    content_hash            BYTEA       NOT NULL,'
            '    logical_shape_version   INTEGER     NOT NULL DEFAULT 1,'
            '    artifact_version_id     UUID,'
            '    status                  TEXT        NOT NULL DEFAULT ''DRAFT'''
            '                                    CHECK (status IN (''DRAFT'',''ACTIVE'',''DEPRECATED'',''ARCHIVED'')),'
            '    created_by              UUID        NOT NULL,'
            '    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),'
            '    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),'
            '    CONSTRAINT uq_entity_defs_tenant_name_version'
            '        UNIQUE (tenant_id, name, logical_shape_version)'
            ')',
            v_schema_name
        );

        EXECUTE format('CREATE INDEX IF NOT EXISTS idx_entity_defs_tenant_name ON %I.entity_definitions (tenant_id, name)', v_schema_name);
        EXECUTE format('CREATE INDEX IF NOT EXISTS idx_entity_defs_status ON %I.entity_definitions (tenant_id, status)', v_schema_name);
        EXECUTE format('CREATE INDEX IF NOT EXISTS idx_entity_defs_content_hash ON %I.entity_definitions (content_hash)', v_schema_name);

        -- ── entity_type_instances (source: migrations/094_entity_subsystem.sql) ──
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I.entity_type_instances ('
            '    entity_type     TEXT        PRIMARY KEY,'
            '    tenant_id       UUID        NOT NULL,'
            '    instance_id     UUID        NOT NULL UNIQUE,'
            '    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()'
            ')',
            v_schema_name
        );

        -- ── entity_record_latest (source: migrations/094_entity_subsystem.sql) ──
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I.entity_record_latest ('
            '    tenant_id           UUID        NOT NULL,'
            '    entity_type         TEXT        NOT NULL,'
            '    record_id           UUID        NOT NULL,'
            '    current_state       JSONB       NOT NULL DEFAULT ''{}'','
            '    version_seq         BIGINT      NOT NULL DEFAULT 0,'
            '    entity_def_version  INTEGER     NOT NULL,'
            '    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),'
            '    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),'
            '    deleted_at          TIMESTAMPTZ,'
            '    CONSTRAINT pk_entity_record_latest'
            '        PRIMARY KEY (entity_type, record_id)'
            ')',
            v_schema_name
        );

        EXECUTE format('CREATE INDEX IF NOT EXISTS idx_erl_tenant_type ON %I.entity_record_latest (tenant_id, entity_type)', v_schema_name);
        EXECUTE format('CREATE INDEX IF NOT EXISTS idx_erl_tenant_type_updated ON %I.entity_record_latest (tenant_id, entity_type, updated_at DESC)', v_schema_name);

        -- ── artifact_activation_groups (source: migrations/046_repository_activations.sql) ──
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS %I.artifact_activation_groups ('
            '    group_id             UUID NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),'
            '    tenant_id            UUID NOT NULL,'
            '    activated_at         TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,'
            '    activator_user_id    UUID NOT NULL,'
            '    rationale            TEXT NOT NULL,'
            '    artifacts_json       JSONB NOT NULL'
            ')',
            v_schema_name
        );

        EXECUTE format('CREATE INDEX IF NOT EXISTS idx_activation_groups_tenant ON %I.artifact_activation_groups (tenant_id)', v_schema_name);
        EXECUTE format('CREATE INDEX IF NOT EXISTS idx_activation_groups_activated_at ON %I.artifact_activation_groups (activated_at DESC)', v_schema_name);

        v_processed := v_processed + 1;
        RAISE NOTICE 'GBL-137: ensured 4 PER_TENANT tables exist in %.', v_schema_name;
    END LOOP;

    RAISE NOTICE 'GBL-137: processed % and skipped % tenant schema(s).', v_processed, v_skipped;
END $$;
