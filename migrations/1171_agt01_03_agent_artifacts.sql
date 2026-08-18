-- Migration 1171: AGT-01/02/03 staging.agent_artifacts table
-- scope: staging_only
--
-- Provisions the staging schema and the agent_artifacts table used by the
-- artifact submission pipeline (POST /api/v1/agent/artifacts).
-- The migration runner skips this file on production deployments (env-class gate).

CREATE SCHEMA IF NOT EXISTS staging;

CREATE TABLE IF NOT EXISTS staging.agent_artifacts (
    artifact_id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id                UUID        NOT NULL,
    task_spec_id             UUID        NOT NULL
                                         REFERENCES task_specs(task_spec_id),
    attempt_count            INTEGER     NOT NULL
                                         CHECK (attempt_count >= 0),
    kind                     TEXT        NOT NULL
                                         CHECK (kind IN (
                                             'test_report',
                                             'design_artifact',
                                             'patch_set',
                                             'scenario_run'
                                         )),
    spec_hash                CHAR(64)    NOT NULL,
    payload                  JSONB       NOT NULL,
    non_deterministic_fields JSONB,
    touched_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_aa_idempotency UNIQUE (tenant_id, task_spec_id, attempt_count)
);

CREATE INDEX IF NOT EXISTS idx_aa_kind
    ON staging.agent_artifacts (kind);
CREATE INDEX IF NOT EXISTS idx_aa_tenant_spec
    ON staging.agent_artifacts (tenant_id, task_spec_id);
