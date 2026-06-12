-- GBL-083_rate_limit_buckets.sql
-- ISS-401: Shared-store sliding-window rate limiter buckets.
-- Postgres-backed. One row per (tenant_id, principal) per window.
-- Idempotent: CREATE TABLE IF NOT EXISTS.

CREATE TABLE IF NOT EXISTS rate_limit_buckets (
    id              BIGSERIAL PRIMARY KEY,
    tenant_id       UUID    NOT NULL,
    principal       TEXT    NOT NULL,
    window_start    BIGINT  NOT NULL,
    count           BIGINT  NOT NULL DEFAULT 0,
    UNIQUE (tenant_id, principal, window_start)
);

CREATE INDEX IF NOT EXISTS idx_rate_limit_buckets_lookup
    ON rate_limit_buckets (tenant_id, principal, window_start DESC);

CREATE INDEX IF NOT EXISTS idx_rate_limit_buckets_window_start
    ON rate_limit_buckets (window_start);
