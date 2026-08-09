-- 004_definitions.sql
-- Stage 2: PD-01..PD-10 — Process definition model
-- Adapted from ai-dala-forge workflow_versions for BPM Platform

-- ── Process definitions ───────────────────────────────────────────────────────
-- PD-01: create; PD-03: version management; PD-04: lifecycle; PD-05: node types

CREATE TABLE IF NOT EXISTS process_definitions (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT        NOT NULL,
    version         TEXT        NOT NULL,
    description     TEXT,

    -- PD-04: lifecycle status
    status          TEXT        NOT NULL DEFAULT 'DRAFT',
                                -- DRAFT | ACTIVE | DEPRECATED | ARCHIVED

    -- PD-02/PD-05: definition graph (nodes + edges as validated JSON)
    graph           JSONB       NOT NULL DEFAULT '{"nodes":[],"edges":[]}',

    -- PD-08: snapshot is taken at instance start — stored in instance_definition_snapshots
    -- PD-09: export/import support uses this full row serialised

    created_by      UUID        NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    archived_at     TIMESTAMPTZ,

    -- PD-03: at most one ACTIVE version per name
    CONSTRAINT uq_definition_version UNIQUE (name, version)
);

-- PD-03: enforce single ACTIVE version per name
CREATE UNIQUE INDEX IF NOT EXISTS uq_active_definition
    ON process_definitions(name)
    WHERE status = 'ACTIVE';

CREATE INDEX IF NOT EXISTS idx_def_name   ON process_definitions(name);
CREATE INDEX IF NOT EXISTS idx_def_status ON process_definitions(status);

-- PD-10: full-text search on name + description
CREATE INDEX IF NOT EXISTS idx_def_fts
    ON process_definitions
    USING GIN (to_tsvector('english', coalesce(name, '') || ' ' || coalesce(description, '')));

-- ── Definition snapshots ──────────────────────────────────────────────────────
-- PD-08: immutable copy of the graph at instance start time.
-- Running instances are unaffected by later definition changes.
-- ISS-0641 / GH-637: PER_TENANT (canonical home = tenant_default), keyed
-- by instance_id (tenant-schema process instance data).
-- migrations.zig's migrationScope() has no per-table scope primitive (only
-- whole-file .public_only vs .all_schemas), so this file correctly keeps
-- running in every schema pass to create the tenant_default copy, but that
-- also creates an unwanted public shadow. See
-- docs/issue-reports/ISS-0185-diagnosis.yaml and
-- migrations/GBL-141_iss0641_drop_dual_schema_shadows.sql, which drops the
-- public shadow (idempotent, re-run after any cold-start replay).

CREATE TABLE IF NOT EXISTS instance_definition_snapshots (
    instance_id     UUID        PRIMARY KEY,
    definition_id   UUID        NOT NULL REFERENCES process_definitions(id),
    definition_name TEXT        NOT NULL,
    definition_ver  TEXT        NOT NULL,
    graph           JSONB       NOT NULL,
    snapshotted_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_snap_definition
    ON instance_definition_snapshots(definition_id);
