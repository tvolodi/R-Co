-- 007_timers.sql
-- Stage 5: SCH-01..SCH-04 — Scheduler, timers, SLA tracking
-- Adapted directly from ai-dala-forge workflow_timers + workflow_sla_records for BPM Platform
-- Source: migrations/20260308150000_workflow_timers.sql (forge)

-- ── Timers ────────────────────────────────────────────────────────────────────
-- SCH-01: created when a HUMAN_TASK node with escalation_timer_duration is entered.
-- SCH-02: background scheduler polls idx_timer_pending every N seconds.
-- SCH-03: cancelled atomically with EE-08 instance cancellation.
-- SCH-04: auto-transition action drives the engine forward without human input.

CREATE TABLE IF NOT EXISTS timers (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    instance_id     UUID        NOT NULL
                        REFERENCES instance_projections(instance_id) ON DELETE CASCADE,
    token_id        UUID        REFERENCES tokens(id) ON DELETE CASCADE,

    -- Classification
    timer_type      TEXT        NOT NULL,
                                -- 'deadline' | 'reminder' | 'escalation' | 'scheduled_transition'
    step_name       TEXT        NOT NULL,

    -- Scheduling
    fires_at        TIMESTAMPTZ NOT NULL,
    repeat_interval TEXT,       -- ISO 8601 duration for recurring (e.g. "PT24H")
    max_repeats     INTEGER,    -- null = unlimited until cancelled
    repeat_count    INTEGER     NOT NULL DEFAULT 0,

    -- Action dispatched on fire (SCH-04)
    action_type     TEXT        NOT NULL,
                                -- 'notify' | 'escalate' | 'auto_transition' | 'cancel'
    action_config   JSONB       NOT NULL DEFAULT '{}',

    -- Lifecycle
    status          TEXT        NOT NULL DEFAULT 'pending',
                                -- 'pending' | 'fired' | 'cancelled'
    fired_at        TIMESTAMPTZ,
    cancelled_at    TIMESTAMPTZ,
    cancel_reason   TEXT,

    -- Stale protection: timer ignored if instance already advanced past its step
    stale_after_hours INTEGER   NOT NULL DEFAULT 72,

    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Hot index: scheduler polls this every tick — must be fast
CREATE INDEX IF NOT EXISTS idx_timer_pending
    ON timers(fires_at)
    WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_timer_instance
    ON timers(instance_id);

CREATE INDEX IF NOT EXISTS idx_timer_token
    ON timers(token_id)
    WHERE token_id IS NOT NULL;

-- ── SLA Records ───────────────────────────────────────────────────────────────
-- SCH-01: created on HUMAN_TASK entry; SCH-02: completed on task completion.
-- Clock: started_at → deadline_at. Outcome: met / breached.

CREATE TABLE IF NOT EXISTS sla_records (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    instance_id         UUID        NOT NULL
                            REFERENCES instance_projections(instance_id) ON DELETE CASCADE,

    -- What is being measured
    step_name           TEXT        NOT NULL,
    sla_name            TEXT        NOT NULL,   -- label from the node definition

    -- SLA definition
    target_duration     TEXT        NOT NULL,   -- ISO 8601 duration, e.g. "PT48H"
    started_at          TIMESTAMPTZ NOT NULL,
    deadline_at         TIMESTAMPTZ NOT NULL,   -- started_at + target_duration

    -- Outcome
    completed_at        TIMESTAMPTZ,
    status              TEXT        NOT NULL DEFAULT 'active',
                                    -- 'active' | 'met' | 'breached'
    actual_duration_ms  BIGINT,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_sla_instance ON sla_records(instance_id);
CREATE INDEX IF NOT EXISTS idx_sla_active   ON sla_records(status) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_sla_deadline ON sla_records(deadline_at) WHERE status = 'active';
