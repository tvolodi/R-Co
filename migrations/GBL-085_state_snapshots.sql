-- GBL-085: ISS-601 — State Snapshots for Large-Instance Reconstruction
--
-- Creates the instance_state_snapshots table for periodic per-instance state
-- snapshots. Reconstruction uses snapshots to replay only events since the latest
-- snapshot instead of the full event log.
--
-- Columns:
--   instance_id   UUID    — FK to instance_projections.instance_id
--   snapshot_seq  BIGINT  — Event sequence number at which this snapshot was taken
--   state_blob    JSONB   — Full serialization of InstanceState at snapshot_seq
--   created_at    TIMESTAMPTZ — Server timestamp of snapshot creation
--
-- Primary key: (instance_id, snapshot_seq) — at most one snapshot per instance per seq
-- Descending index: O(log n) lookup of the latest snapshot for an instance
--
-- Idempotent: uses CREATE TABLE IF NOT EXISTS / CREATE INDEX IF NOT EXISTS.
-- GBL-prefix: operates on public schema.
-- No schema-qualified names — uses unqualified table names.

CREATE TABLE IF NOT EXISTS instance_state_snapshots (
    instance_id   UUID        NOT NULL,
    snapshot_seq  BIGINT      NOT NULL,
    state_blob    JSONB       NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (instance_id, snapshot_seq)
);

CREATE INDEX IF NOT EXISTS idx_instance_state_snapshots_latest
    ON instance_state_snapshots (instance_id, snapshot_seq DESC);
