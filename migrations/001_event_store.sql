-- 001_event_store.sql
-- Stage 1: Event Store — ES-01..ES-06, DB-01..DB-04
-- Adapted from ai-dala-forge (Rust/PostgreSQL) for BPM Platform (Zig)

-- ── Schema migrations tracker ─────────────────────────────────────────────────
-- Idempotent: run this first on every migration pass.
CREATE TABLE IF NOT EXISTS schema_migrations (
    version     TEXT        PRIMARY KEY,
    applied_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Event log ─────────────────────────────────────────────────────────────────
-- ES-01: append typed immutable events; ES-02: strict sequence order;
-- ES-03: global idempotency key; ES-04: global stream; ES-06: point-in-time.

CREATE TABLE IF NOT EXISTS events (
    -- ES-01 required fields
    event_id          UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    instance_id       UUID            NOT NULL,
    event_type        TEXT            NOT NULL,   -- must exist in event_type_registry
    payload           JSONB           NOT NULL DEFAULT '{}',
    actor_id          UUID            NOT NULL,
    created_at        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- ES-02: strict ordering per instance
    sequence_number   BIGINT          NOT NULL,

    -- ES-03: global idempotency key
    idempotency_key   TEXT            NOT NULL,

    -- ES-08: optional free-form tracing metadata (string → string)
    metadata          JSONB           NOT NULL DEFAULT '{}'
);

-- Global sequence for ES-04 (all instances ordered stream)
CREATE SEQUENCE IF NOT EXISTS events_global_seq START 1;
ALTER TABLE events ADD COLUMN IF NOT EXISTS
    global_seq  BIGINT NOT NULL DEFAULT nextval('events_global_seq');

-- ES-03: idempotency key is global — unique across all instances and event types
CREATE UNIQUE INDEX IF NOT EXISTS uq_event_idempotency
    ON events(idempotency_key);

-- ES-02: sequence number unique per instance
CREATE UNIQUE INDEX IF NOT EXISTS uq_event_sequence
    ON events(instance_id, sequence_number);

-- ES-04: global ordered stream
CREATE INDEX IF NOT EXISTS idx_events_global_seq
    ON events(global_seq);

-- ES-06: point-in-time query by instance + sequence or timestamp
CREATE INDEX IF NOT EXISTS idx_events_instance_seq
    ON events(instance_id, sequence_number);

CREATE INDEX IF NOT EXISTS idx_events_instance_time
    ON events(instance_id, created_at);

-- ES-01/ES-05: index by event_type for registry validation queries
CREATE INDEX IF NOT EXISTS idx_events_type
    ON events(event_type);

-- ── Per-instance sequence helper ──────────────────────────────────────────────
-- One row per instance tracks the next sequence number.
-- Avoids SELECT MAX(sequence_number) + 1 races under concurrent appends.
CREATE TABLE IF NOT EXISTS instance_sequence (
    instance_id   UUID    PRIMARY KEY,
    next_seq      BIGINT  NOT NULL DEFAULT 1
);

-- ── Instance projection / read model ─────────────────────────────────────────
-- Derived, queryable state rebuilt from the event log (EE-11 state reconstruction).
-- Re-buildable at any time without loss of ground truth.
CREATE TABLE IF NOT EXISTS instance_projections (
    instance_id     UUID        PRIMARY KEY,
    definition_id   UUID        NOT NULL,
    correlation_key TEXT,
    status          TEXT        NOT NULL DEFAULT 'ACTIVE',
                                -- ACTIVE | COMPLETED | CANCELLED | ERROR
    current_nodes   JSONB       NOT NULL DEFAULT '[]',   -- active token positions
    variables       JSONB       NOT NULL DEFAULT '{}',   -- merged variable map
    error_detail    JSONB,                               -- set on ERROR status
    last_event_seq  BIGINT      NOT NULL DEFAULT 0,
    started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at    TIMESTAMPTZ,
    cancelled_at    TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Correlation key is unique per definition (EE-01)
CREATE UNIQUE INDEX IF NOT EXISTS uq_instance_correlation
    ON instance_projections(definition_id, correlation_key)
    WHERE correlation_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_proj_status
    ON instance_projections(status)
    WHERE status = 'ACTIVE';

CREATE INDEX IF NOT EXISTS idx_proj_definition
    ON instance_projections(definition_id);
