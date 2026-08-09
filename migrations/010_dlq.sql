-- 010_dlq.sql  (already covered in 006_tasks.sql above — this file reserved)
-- Stage 5: Webhook subscriptions — WH-01..WH-04
-- Adapted from ai-dala-forge for BPM Platform

-- ── Webhook subscriptions ─────────────────────────────────────────────────────
-- WH-01: callers register endpoints to receive instance lifecycle events.
-- WH-02: delivery is attempted with retry + exponential backoff.

CREATE TABLE IF NOT EXISTS webhook_subscriptions (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id        UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,

    -- Target
    url             TEXT        NOT NULL,
    secret          TEXT        NOT NULL,   -- HMAC-SHA256 signing secret (hashed)
    description     TEXT,

    -- Event filter: NULL = subscribe to all event types
    event_types     TEXT[],

    -- Lifecycle
    is_active       BOOLEAN     NOT NULL DEFAULT true,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_wsub_owner  ON webhook_subscriptions(owner_id);
CREATE INDEX IF NOT EXISTS idx_wsub_active ON webhook_subscriptions(is_active)
    WHERE is_active = true;

-- ── Webhook deliveries ────────────────────────────────────────────────────────
-- WH-02: one row per delivery attempt per subscription.
-- ISS-0641 / GH-637: PER_TENANT (canonical home = tenant_default).
-- migrations.zig's migrationScope() has no per-table scope primitive (only
-- whole-file .public_only vs .all_schemas), so this file correctly keeps
-- running in every schema pass to create the tenant_default copy, but that
-- also creates an unwanted public shadow. See
-- docs/issue-reports/ISS-0185-diagnosis.yaml and
-- migrations/GBL-141_iss0641_drop_dual_schema_shadows.sql, which drops the
-- public shadow (idempotent, re-run after any cold-start replay).

CREATE TABLE IF NOT EXISTS webhook_deliveries (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    subscription_id     UUID        NOT NULL
                            REFERENCES webhook_subscriptions(id) ON DELETE CASCADE,
    event_id            UUID        NOT NULL REFERENCES events(event_id),

    -- Delivery state
    status              TEXT        NOT NULL DEFAULT 'pending',
                                    -- 'pending' | 'success' | 'failed' | 'exhausted'
    attempt_count       INTEGER     NOT NULL DEFAULT 0,
    max_attempts        INTEGER     NOT NULL DEFAULT 5,
    next_attempt_at     TIMESTAMPTZ,
    last_attempt_at     TIMESTAMPTZ,

    -- Last response
    http_status         INTEGER,
    response_body       TEXT,
    error_message       TEXT,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_wd_pending
    ON webhook_deliveries(next_attempt_at)
    WHERE status IN ('pending', 'failed');

CREATE INDEX IF NOT EXISTS idx_wd_subscription
    ON webhook_deliveries(subscription_id);
