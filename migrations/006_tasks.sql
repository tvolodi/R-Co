-- 006_tasks.sql
-- Stage 3 supplement: Dead-letter queue (EE-10, OBS-05)
-- Adapted from ai-dala-forge for BPM Platform

-- ── Dead Letter Queue ─────────────────────────────────────────────────────────
-- EE-10: instances/timers that exhausted retry budget land here.
-- OBS-05: operators retry or discard via the DLQ API.

CREATE TABLE IF NOT EXISTS dead_letter_queue (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    entry_type      TEXT        NOT NULL,
                                -- 'instance_error' | 'timer_failed' | 'service_task_failed' | 'webhook_failed'
    instance_id     UUID,
    reference_id    UUID,       -- timer_id / task_id / webhook_delivery_id

    reason          TEXT        NOT NULL,
    error_detail    JSONB,

    retry_count     INTEGER     NOT NULL DEFAULT 0,
    max_retries     INTEGER     NOT NULL DEFAULT 3,
    next_retry_at   TIMESTAMPTZ,
    last_retried_at TIMESTAMPTZ,

    status          TEXT        NOT NULL DEFAULT 'pending',
                                -- 'pending' | 'retrying' | 'resolved' | 'discarded'
    resolved_by     UUID,
    resolved_at     TIMESTAMPTZ,

    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_dlq_status
    ON dead_letter_queue(status)
    WHERE status IN ('pending', 'retrying');

CREATE INDEX IF NOT EXISTS idx_dlq_instance
    ON dead_letter_queue(instance_id)
    WHERE instance_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_dlq_retry_at
    ON dead_letter_queue(next_retry_at)
    WHERE status = 'retrying';
