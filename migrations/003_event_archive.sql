-- 003_event_archive.sql
-- Stage 1: ES-07 — Configurable event retention; archive table
-- Adapted from ai-dala-forge for BPM Platform

-- ── Archive table ─────────────────────────────────────────────────────────────
-- Identical schema to events. Archived rows are moved here, not deleted.
-- Active instance state reconstruction is never affected (EE-11).

CREATE TABLE IF NOT EXISTS events_archive (
    event_id          UUID            PRIMARY KEY,
    instance_id       UUID            NOT NULL,
    event_type        TEXT            NOT NULL,
    payload           JSONB           NOT NULL DEFAULT '{}',
    actor_id          UUID            NOT NULL,
    created_at        TIMESTAMPTZ     NOT NULL,
    sequence_number   BIGINT          NOT NULL,
    idempotency_key   TEXT            NOT NULL,
    metadata          JSONB           NOT NULL DEFAULT '{}',
    global_seq        BIGINT          NOT NULL,
    archived_at       TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_archive_instance
    ON events_archive(instance_id, sequence_number);

CREATE INDEX IF NOT EXISTS idx_archive_type
    ON events_archive(event_type);

CREATE INDEX IF NOT EXISTS idx_archive_time
    ON events_archive(created_at);

-- ── Retention policy table ────────────────────────────────────────────────────
-- Per event type: keep_forever | keep_days | keep_count

CREATE TABLE IF NOT EXISTS event_retention_policies (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type      TEXT        NOT NULL UNIQUE,
    policy          TEXT        NOT NULL DEFAULT 'keep_forever',
                                -- 'keep_forever' | 'keep_days' | 'keep_count'
    keep_days       INTEGER,    -- used when policy = 'keep_days'
    keep_count      INTEGER,    -- used when policy = 'keep_count'
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_retention_policy CHECK (
        policy IN ('keep_forever', 'keep_days', 'keep_count')
    ),
    CONSTRAINT chk_keep_days   CHECK (policy != 'keep_days'  OR keep_days  IS NOT NULL),
    CONSTRAINT chk_keep_count  CHECK (policy != 'keep_count' OR keep_count IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_erp_type ON event_retention_policies(event_type);
