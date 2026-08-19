-- Migration 1173: AGT-06 dual-sweep artifact retention
-- scope: staging_only
--
-- Adds lifecycle columns to staging.agent_artifacts and provisions the
-- artifact_version_pins table written atomically on verified-state transitions.

CREATE SCHEMA IF NOT EXISTS staging;

ALTER TABLE staging.agent_artifacts
    ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'needs_review'
        CHECK (status IN ('needs_review', 'verified')),
    ADD COLUMN IF NOT EXISTS verified_at TIMESTAMPTZ NULL;

CREATE INDEX IF NOT EXISTS idx_aa_status_created
    ON staging.agent_artifacts (status, created_at);

-- Retention pin table written atomically with the verified-state UPDATE (DB-03).
CREATE TABLE IF NOT EXISTS staging.artifact_version_pins (
    pin_id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    artifact_id                 UUID        NOT NULL
                                             REFERENCES staging.agent_artifacts(artifact_id)
                                             ON DELETE CASCADE,
    task_spec_version           TEXT        NOT NULL,
    process_definition_version  TEXT        NOT NULL,
    collected_at                TIMESTAMPTZ NULL,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_avp_artifact
    ON staging.artifact_version_pins (artifact_id);
CREATE INDEX IF NOT EXISTS idx_avp_collected
    ON staging.artifact_version_pins (collected_at)
    WHERE collected_at IS NOT NULL;
