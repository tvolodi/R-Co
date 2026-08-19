-- Migration 1172: SBX-04/05/06 sandbox ownership binding, sentinel enforcement, idle-reclaim
-- scope: tenant_only
--
-- 1. Add last_active_at TIMESTAMPTZ to agent_sandboxes.
-- 2. Replace column-level UNIQUE (owner_principal, task_spec_id) with a partial unique index
--    (task_spec_id) WHERE status = 'claimed', enforcing one claimed row per task_spec_id.
-- 3. Add sandbox_probe_counters for per-principal sliding-window sentinel rate limiting.
--
-- Idempotency: ADD COLUMN IF NOT EXISTS, DROP CONSTRAINT IF EXISTS,
-- CREATE UNIQUE INDEX IF NOT EXISTS, CREATE TABLE IF NOT EXISTS, CREATE INDEX IF NOT EXISTS.

ALTER TABLE agent_sandboxes
    ADD COLUMN IF NOT EXISTS last_active_at TIMESTAMPTZ;

UPDATE agent_sandboxes
    SET last_active_at = COALESCE(claimed_at, updated_at)
    WHERE last_active_at IS NULL;

ALTER TABLE agent_sandboxes
    DROP CONSTRAINT IF EXISTS ux_sandbox_owner;

CREATE UNIQUE INDEX IF NOT EXISTS ux_sandbox_owner
    ON agent_sandboxes (task_spec_id)
    WHERE status = 'claimed';

CREATE TABLE IF NOT EXISTS sandbox_probe_counters (
    principal    TEXT    NOT NULL,
    window_start BIGINT  NOT NULL,
    count        INTEGER NOT NULL DEFAULT 0,
    CONSTRAINT pk_spc PRIMARY KEY (principal, window_start)
);

CREATE INDEX IF NOT EXISTS idx_spc_window
    ON sandbox_probe_counters (window_start);
