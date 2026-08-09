-- 012_event_retention.sql
-- Large-payload side table + variable schema registry
-- Covers NFR-05 (8KB page size) and EE-09 (variable collision validation)

-- ── Large payload side table (NFR-05) ────────────────────────────────────────
-- Event payloads > 4 KB are stored here; events.payload holds a {"$ref": "<id>"} pointer.
-- ISS-0641 / GH-637: PER_TENANT (canonical home = tenant_default), FKs to
-- tenant-schema events(event_id). migrations.zig's migrationScope() has no
-- per-table scope primitive (only whole-file .public_only vs
-- .all_schemas), so this file correctly keeps running in every schema pass
-- to create the tenant_default copy, but that also creates an unwanted
-- public shadow. See docs/issue-reports/ISS-0185-diagnosis.yaml and
-- migrations/GBL-141_iss0641_drop_dual_schema_shadows.sql, which drops the
-- public shadow (idempotent, re-run after any cold-start replay).

CREATE TABLE IF NOT EXISTS event_payload_store (
    id          UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id    UUID    NOT NULL UNIQUE REFERENCES events(event_id) ON DELETE CASCADE,
    payload     JSONB   NOT NULL,
    byte_size   INTEGER NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Variable schema registry (EE-09) ─────────────────────────────────────────
-- Optional per-variable JSON Schema. If registered, merging a non-conformant
-- value → EXECUTION_ERROR (variable collision policy, EE-09 rule 3).
-- ISS-0641 / GH-637: PER_TENANT (canonical home = tenant_default), FKs to
-- tenant-schema process_definitions(id). See the event_payload_store
-- comment above — same file-scope limitation applies; GBL-141 drops the
-- public shadow.

CREATE TABLE IF NOT EXISTS variable_schemas (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    definition_id   UUID        NOT NULL REFERENCES process_definitions(id) ON DELETE CASCADE,
    variable_key    TEXT        NOT NULL,
    json_schema     JSONB       NOT NULL,
    description     TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (definition_id, variable_key)
);

CREATE INDEX IF NOT EXISTS idx_vs_definition
    ON variable_schemas(definition_id);
