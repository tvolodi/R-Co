-- 011_webhook_subscriptions.sql
-- Stage 4: Metrics & observability counters persisted for dashboards
-- Adapted from ai-dala-forge for BPM Platform

-- ── Metrics counters ──────────────────────────────────────────────────────────
-- Lightweight key-value store for in-process Prometheus mirrors
-- and for the health/metrics endpoint (OBS-06).

-- scope: public
-- ISS-0185: this migration creates a global-registry table.

CREATE TABLE IF NOT EXISTS public.metric_snapshots (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT        NOT NULL,
    labels      JSONB       NOT NULL DEFAULT '{}',
    value       DOUBLE PRECISION NOT NULL,
    captured_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ms_name_time
    ON public.metric_snapshots(name, captured_at DESC);

-- ── Rate limit buckets ────────────────────────────────────────────────────────
-- Per-token sliding window state for the ratelimit middleware (API-07).
-- Rows are upserted by the middleware; TTL cleanup by a background job.

CREATE TABLE IF NOT EXISTS public.rate_limit_buckets (
    token_id        TEXT        NOT NULL,
    window_start    TIMESTAMPTZ NOT NULL,
    request_count   INTEGER     NOT NULL DEFAULT 0,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    PRIMARY KEY (token_id, window_start)
);

CREATE INDEX IF NOT EXISTS idx_rlb_cleanup
    ON public.rate_limit_buckets(window_start);
