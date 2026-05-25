-- 023_ext02_webhook_event_dispatch.sql
-- EXT-02: webhook subscription APIs + reliable event fan-out dispatch state.

-- Align subscription storage with EXT-02 contract while keeping prior columns.
ALTER TABLE webhook_subscriptions
    ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'ACTIVE',
    ADD COLUMN IF NOT EXISTS consecutive_failures INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS max_attempts INTEGER NOT NULL DEFAULT 5,
    ADD COLUMN IF NOT EXISTS last_attempt_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS last_failure_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS paused_at TIMESTAMPTZ;

ALTER TABLE webhook_subscriptions
    DROP CONSTRAINT IF EXISTS webhook_subscriptions_status_check;

ALTER TABLE webhook_subscriptions
    ADD CONSTRAINT webhook_subscriptions_status_check
    CHECK (status IN ('ACTIVE', 'PAUSED'));

CREATE INDEX IF NOT EXISTS idx_wsub_status
    ON webhook_subscriptions(status);

-- Delivery rows carry deterministic outbound payload context and retry metadata.
ALTER TABLE webhook_deliveries
    ADD COLUMN IF NOT EXISTS event_type TEXT,
    ADD COLUMN IF NOT EXISTS instance_id UUID,
    ADD COLUMN IF NOT EXISTS payload_json JSONB,
    ADD COLUMN IF NOT EXISTS trace_id TEXT,
    ADD COLUMN IF NOT EXISTS delivered_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS last_http_status INTEGER,
    ADD COLUMN IF NOT EXISTS last_error TEXT;

UPDATE webhook_deliveries
SET next_attempt_at = COALESCE(next_attempt_at, NOW())
WHERE next_attempt_at IS NULL;

ALTER TABLE webhook_deliveries
    ALTER COLUMN next_attempt_at SET DEFAULT NOW();

CREATE INDEX IF NOT EXISTS idx_wd_status_next_attempt
    ON webhook_deliveries(status, next_attempt_at);

CREATE INDEX IF NOT EXISTS idx_wd_event_type
    ON webhook_deliveries(event_type);
