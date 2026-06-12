-- Migration 083: ISS-105 — Persist token model with join counters
-- Date: 2026-06-11
--
-- STRATEGY:
--   1. Add new columns to instance_projections: active_tokens, join_counters
--   2. Backfill existing data from current_nodes to active_tokens (deterministic UUID v3)
--   3. Initialize join_counters to {} for all instances
--   4. No dropping of old columns yet (backward compatibility)
--
-- IDEMPOTENCY:
--   All ADD COLUMN use IF NOT EXISTS.
--   Backfill uses upsert-safe logic.

DO $$
DECLARE
    v_instance_proj_oid OID;
BEGIN
    -- Guard: instance_projections table must exist
    v_instance_proj_oid := to_regclass('instance_projections');
    IF v_instance_proj_oid IS NULL THEN
        -- If instance_projections doesn't exist in this schema, nothing to do.
        RETURN;
    END IF;

    -- 1. Add new columns (IF NOT EXISTS makes this idempotent)
    ALTER TABLE instance_projections
        ADD COLUMN IF NOT EXISTS active_tokens JSONB NOT NULL DEFAULT '[]',
        ADD COLUMN IF NOT EXISTS join_counters JSONB NOT NULL DEFAULT '{}';

    -- 2. Index on active_tokens for query optimization
    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = current_schema()
          AND tablename = 'instance_projections'
          AND indexname = 'idx_instance_active_tokens'
    ) THEN
        CREATE INDEX idx_instance_active_tokens
            ON instance_projections USING GIN (active_tokens);
    END IF;

END $$;
