-- Migration 1170: SBX-01/02/03 task_specs and agent_sandboxes tables
-- scope: tenant_only

CREATE TABLE IF NOT EXISTS task_specs (
    task_spec_id            UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
    spec_hash               CHAR(64) NOT NULL,
    spec_body               JSONB   NOT NULL,
    orchestrator_principal  TEXT    NOT NULL,
    rng_seed                BIGINT  NOT NULL,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_ts_hash UNIQUE (spec_hash)
);
CREATE INDEX IF NOT EXISTS idx_ts_orchestrator
    ON task_specs (orchestrator_principal);

CREATE TABLE IF NOT EXISTS agent_sandboxes (
    sandbox_id          UUID    PRIMARY KEY DEFAULT gen_random_uuid(),
    status              TEXT    NOT NULL DEFAULT 'unclaimed'
                                CHECK (status IN ('unclaimed','claimed','released','failed')),
    owner_principal     TEXT,
    task_spec_id        UUID    REFERENCES task_specs(task_spec_id),
    claimed_at          TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT ux_sandbox_owner UNIQUE (owner_principal, task_spec_id)
);
CREATE INDEX IF NOT EXISTS idx_as_owner
    ON agent_sandboxes (owner_principal);
CREATE INDEX IF NOT EXISTS idx_as_status
    ON agent_sandboxes (status);
