-- 1140_iss0112_entity_tables_tenant_scope_corrective.sql
-- ISS-0112 / GH-375: corrective — entity_type_instances and
-- entity_record_latest missing from tenant schemas (including
-- reprovisioned/newly-created ones), causing EXP-201/EXP-202 entity record
-- create/update/delete to fail with "relation does not exist" whenever the
-- entities command path is exercised against a SCHEMA-mode tenant.
--
-- Root cause:
--   094_entity_subsystem.sql declares itself `-- scope: all_schemas` (it is
--   not GBL-prefixed), so migrations.zig's runForSchema() DOES walk it
--   during both the public pass and every per-tenant pass. But its
--   `entity_type_instances` and `entity_record_latest` (and
--   `entity_definitions`) CREATE TABLE statements are explicitly
--   `public.`-qualified rather than unqualified/search_path-resolved. Since
--   runForSchema's only per-schema mechanism is `SET search_path TO
--   <schema>,public` before executing each migration's unqualified DDL, an
--   explicitly `public.`-qualified statement ignores that search_path
--   entirely and always lands in `public` -- during the public pass this is
--   a normal create; during every tenant pass it is a harmless no-op
--   (`public.entity_type_instances` already exists), so the tenant schema
--   itself never receives the table. This reproduces the identical defect
--   class already fixed for `webhook_subscriptions.secret_ref` by migration
--   1134/1138 (ISS-0112/ISS-0635) and documented in
--   src/design/fix-iss0112.md — a `public.`-qualified statement inside an
--   all_schemas-scoped (or GBL- iterate-and-EXECUTE-format) migration can
--   never create tenant-schema copies of a table the application code
--   queries with an explicit tenant-schema-qualified reference
--   (`{tenant_schema}.entity_type_instances` in
--   src/entities/commands.zig:getOrCreateEntityTypeInstance /
--   ensureEntityInstanceProjection).
--
--   GBL-137_iss0620_recreate_per_tenant_shadows.sql already backfilled these
--   3 tables (plus artifact_activation_groups) into every tenant schema that
--   existed in public.tenant AT THE TIME GBL-137 WAS APPLIED (2026-08-08).
--   That backfill does not self-heal a tenant schema created or
--   reprovisioned afterward (e.g. this workspace's bpm_test tenant_default,
--   which was reprovisioned from scratch after GBL-137 last ran and
--   currently lacks entity_type_instances / entity_record_latest again),
--   because 094's own qualified DDL is still the only mechanism
--   provisionTenantSchema()->runForSchema() invokes for new/reprovisioned
--   schemas, and it is still broken. This migration fixes the ROOT CAUSE
--   (094's unfixable-in-place qualified statements, superseded here rather
--   than edited since 094 already ran) by re-declaring the 3 entity tables
--   with unqualified names inside an all_schemas-scoped migration, so
--   runForSchema's search_path mechanism places them correctly on every
--   future/reprovisioned tenant pass, AND backfills any tenant schema that
--   is missing them right now — a durable fix, not a one-time snapshot like
--   GBL-137.
--
-- Scope header intentionally absent (defaults to all_schemas per
-- migrations.zig migrationScope(); no GBL- prefix): must run against public
-- (where it is a no-op, all 3 tables already exist there) AND every tenant
-- schema (where it creates whatever is missing).
--
-- Safety properties:
--   1. Purely additive: CREATE TABLE IF NOT EXISTS / CREATE INDEX IF NOT
--      EXISTS only. No DROP, no TRUNCATE, no DELETE, no data migration.
--   2. Idempotent: safe to re-run against a schema that already has these
--      tables (public; any tenant schema GBL-137 already backfilled) and
--      against one that is missing them (any tenant schema
--      created/reprovisioned after GBL-137 ran).
--   3. Table shape copied verbatim from 094_entity_subsystem.sql /
--      GBL-137_iss0620_recreate_per_tenant_shadows.sql. Constraint/index
--      names are unqualified and unique only within their own schema
--      (PostgreSQL scopes both to the containing schema), so reusing the
--      same literal names across schemas is safe.
--   4. No FK dependency ordering concerns — same tables GBL-137 already
--      established have no live FK dependents anywhere in the schema.
--
-- Out of scope:
--   entity_definitions is deliberately NOT touched here even though it has
--   the identical qualification defect, because src/entities/definition.zig
--   queries it UNQUALIFIED (relying on search_path's `public` fallback
--   entry), so it resolves correctly today via the public copy regardless
--   of which schema is active. Only entity_type_instances and
--   entity_record_latest are queried by commands.zig with an EXPLICIT
--   tenant-schema qualifier ({s}.entity_type_instances /
--   {s}.entity_record_latest), which is what actually breaks. Reconciling
--   entity_definitions' storage location with its intended tenant/public
--   scope is a separate, non-blocking cleanup and is not needed to fix the
--   EXP-201/EXP-202 test failures this migration targets.

CREATE TABLE IF NOT EXISTS entity_type_instances (
    entity_type     TEXT        PRIMARY KEY,
    tenant_id       UUID        NOT NULL,
    instance_id     UUID        NOT NULL UNIQUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS entity_record_latest (
    tenant_id           UUID        NOT NULL,
    entity_type         TEXT        NOT NULL,
    record_id           UUID        NOT NULL,
    current_state       JSONB       NOT NULL DEFAULT '{}',
    version_seq         BIGINT      NOT NULL DEFAULT 0,
    entity_def_version  INTEGER     NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at          TIMESTAMPTZ,

    CONSTRAINT pk_entity_record_latest
        PRIMARY KEY (entity_type, record_id)
);

CREATE INDEX IF NOT EXISTS idx_erl_tenant_type
    ON entity_record_latest (tenant_id, entity_type);

CREATE INDEX IF NOT EXISTS idx_erl_tenant_type_updated
    ON entity_record_latest (tenant_id, entity_type, updated_at DESC);
