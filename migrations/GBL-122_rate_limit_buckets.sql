-- GBL-083_rate_limit_buckets.sql
-- ISS-401: Shared-store sliding-window rate limiter buckets.
-- Postgres-backed. One row per (tenant_id, principal) per window.
-- Idempotent: CREATE TABLE IF NOT EXISTS.
-- Fix collision with legacy business table in public schema (TNT-01).
DO $$
BEGIN
    -- If rate_limit_buckets exists but does NOT have tenant_id column, it is the legacy table.
    IF EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'public' 
          AND table_name = 'rate_limit_buckets'
          AND column_name = 'token_id'
    ) THEN
        DROP TABLE public.rate_limit_buckets CASCADE;
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.rate_limit_buckets (
    id              BIGSERIAL PRIMARY KEY,
    tenant_id       UUID    NOT NULL,
    principal       TEXT    NOT NULL,
    window_start    BIGINT  NOT NULL,
    count           BIGINT  NOT NULL DEFAULT 0,
    UNIQUE (tenant_id, principal, window_start)
);

CREATE INDEX IF NOT EXISTS idx_rate_limit_buckets_lookup
    ON public.rate_limit_buckets (tenant_id, principal, window_start DESC);

CREATE INDEX IF NOT EXISTS idx_rate_limit_buckets_window_start
    ON public.rate_limit_buckets (window_start);
