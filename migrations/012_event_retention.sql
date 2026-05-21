-- 012_event_retention.sql
-- Large-payload side table + variable schema registry
-- Covers NFR-05 (8KB page size) and EE-09 (variable collision validation)

-- ── Large payload side table (NFR-05) ────────────────────────────────────────
-- Event payloads > 4 KB are stored here; events.payload holds a {"$ref": "<id>"} pointer.

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
