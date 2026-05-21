-- 009_audit_log.sql
-- Stage 4: OBS-01..OBS-04 — Append-only audit log
-- Adapted from ai-dala-forge audit_entries for BPM Platform
-- Source: migrations/20260122_create_audit_entries.sql (forge)

-- ── Audit log ─────────────────────────────────────────────────────────────────
-- Append-only. Rows are never updated or deleted.
-- OBS-01: every mutating API call writes one entry.

CREATE TABLE IF NOT EXISTS audit_log (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Actor
    actor_id        UUID        REFERENCES users(id) ON DELETE SET NULL,
    actor_email     TEXT,       -- snapshot: preserved even if user is deleted

    -- Action
    action          TEXT        NOT NULL,
                                -- CREATE | READ | UPDATE | DELETE | EXECUTE |
                                -- LOGIN | LOGOUT | TOKEN_ISSUED | TOKEN_REVOKED |
                                -- INSTANCE_START | INSTANCE_CANCEL | TASK_COMPLETE |
                                -- DEFINITION_ACTIVATE | DEFINITION_ARCHIVE | DLQ_RETRY | DLQ_DISCARD

    -- Target entity
    entity_type     TEXT,       -- 'definition' | 'instance' | 'task' | 'user' | ...
    entity_id       UUID,
    entity_name     TEXT,       -- human-readable label at time of action

    -- Request context
    ip_address      INET,
    user_agent      TEXT,
    trace_id        TEXT,       -- X-Trace-ID from request header

    -- Change payload (optional; before/after for UPDATE)
    detail          JSONB,

    occurred_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Queries: "show all actions for this instance" / "show all by this user"
CREATE INDEX IF NOT EXISTS idx_al_entity
    ON audit_log(entity_type, entity_id);

CREATE INDEX IF NOT EXISTS idx_al_actor
    ON audit_log(actor_id);

CREATE INDEX IF NOT EXISTS idx_al_time
    ON audit_log(occurred_at DESC);

CREATE INDEX IF NOT EXISTS idx_al_action
    ON audit_log(action);
