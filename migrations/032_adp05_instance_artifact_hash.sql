-- 032_adp05_instance_artifact_hash.sql
-- Stage 6.5: ADP-05 -- additive artifact hash references for instance start/replay.

-- Optional repository descriptor on the definition version row.
ALTER TABLE process_definitions
    ADD COLUMN IF NOT EXISTS definition_artifact_hash TEXT NULL;

-- Per-instance persisted definition artifact hash (nullable for legacy compatibility).
ALTER TABLE instance_projections
    ADD COLUMN IF NOT EXISTS definition_artifact_hash TEXT NULL;
