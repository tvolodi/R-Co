-- 005_instances.sql
-- Stage 3: EE-01..EE-12 — Process instance lifecycle, tokens, tasks
-- Adapted from ai-dala-forge workflow_instances + workflow_tokens for BPM Platform

-- ── Execution tokens ──────────────────────────────────────────────────────────
-- EE-06: parallel split creates one token per branch.
-- EE-07: join waits until all active sibling tokens arrive.

CREATE TABLE IF NOT EXISTS tokens (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    instance_id     UUID        NOT NULL
                        REFERENCES instance_projections(instance_id) ON DELETE CASCADE,

    -- Position
    current_node    TEXT        NOT NULL,
    status          TEXT        NOT NULL DEFAULT 'active',
                                -- 'active' | 'waiting' | 'completed' | 'cancelled'

    -- EE-06/EE-07: parallel gateway tracking
    parent_token_id UUID        REFERENCES tokens(id),
    gateway_id      TEXT,       -- step that created this token (join matching)
    branch_name     TEXT,       -- named parallel branch

    -- Sub-process linkage (Stage 6)
    child_instance_id UUID,

    data            JSONB       NOT NULL DEFAULT '{}',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at    TIMESTAMPTZ,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_token_instance
    ON tokens(instance_id);

CREATE INDEX IF NOT EXISTS idx_token_active
    ON tokens(instance_id, status)
    WHERE status = 'active';

-- EE-07: partial index for waiting tokens at join gateways
CREATE INDEX IF NOT EXISTS idx_token_waiting
    ON tokens(instance_id, gateway_id)
    WHERE status = 'waiting';

-- ── Tasks ─────────────────────────────────────────────────────────────────────
-- EE-03: activated atomically when a HUMAN_TASK node is entered.
-- EE-04: completed by authorised actor supplying output variables.

CREATE TABLE IF NOT EXISTS tasks (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    instance_id     UUID        NOT NULL
                        REFERENCES instance_projections(instance_id) ON DELETE CASCADE,
    token_id        UUID        NOT NULL REFERENCES tokens(id) ON DELETE CASCADE,

    node_id         TEXT        NOT NULL,   -- node in the definition graph
    node_name       TEXT        NOT NULL,   -- display name

    status          TEXT        NOT NULL DEFAULT 'PENDING',
                                -- PENDING | COMPLETED | CANCELLED

    -- Assignment (from node definition)
    assignee_type   TEXT,       -- USER | GROUP | ROLE
    assignee_ref    TEXT,       -- user_id / group_name / role_name

    -- Form schema (optional, from HUMAN_TASK node definition)
    form_schema     JSONB,

    -- Output supplied on completion (EE-04)
    output_variables JSONB,

    completed_by    UUID,
    completed_at    TIMESTAMPTZ,
    cancelled_at    TIMESTAMPTZ,

    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_task_instance
    ON tasks(instance_id);

-- Inbox queries: pending tasks for a user/role
CREATE INDEX IF NOT EXISTS idx_task_pending
    ON tasks(assignee_ref, status)
    WHERE status = 'PENDING';

CREATE INDEX IF NOT EXISTS idx_task_status
    ON tasks(status);

-- ── Sub-process linkage ───────────────────────────────────────────────────────
-- Stage 6: parent instance waits while child runs; child completes → parent resumes.
ALTER TABLE instance_projections
    ADD COLUMN IF NOT EXISTS parent_instance_id UUID
        REFERENCES instance_projections(instance_id),
    ADD COLUMN IF NOT EXISTS parent_token_id UUID
        REFERENCES tokens(id),
    ADD COLUMN IF NOT EXISTS result_variables JSONB;

CREATE INDEX IF NOT EXISTS idx_proj_parent
    ON instance_projections(parent_instance_id)
    WHERE parent_instance_id IS NOT NULL;
