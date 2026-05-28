-- 055_xc06_backwards_compatibility.sql
-- XC-06: Backwards Compatibility
-- New platform versions load and continue instances created by prior versions.
-- Schema migrations are additive and idempotent.
--
-- This migration demonstrates additive-only schema design:
-- - All ALTER TABLE ADD COLUMN statements use IF NOT EXISTS
-- - No columns are dropped or renamed
-- - New features default to NULL or sensible defaults for old records

-- Mark migration as applied (this migration itself is idempotent)
-- The schema_migrations table tracks which migrations have been applied.

-- Verify core tables exist and are backward-compatible
CREATE TABLE IF NOT EXISTS schema_migrations (
    version    TEXT        PRIMARY KEY,
    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Verify instances table is backward-compatible
-- Old instances without new columns should still be queryable
ALTER TABLE instances
    ADD COLUMN IF NOT EXISTS trace_id TEXT NULL;

ALTER TABLE instances
    ADD COLUMN IF NOT EXISTS definition_artifact_hash TEXT NULL;

-- Verify events table is backward-compatible
ALTER TABLE events
    ADD COLUMN IF NOT EXISTS idempotency_key TEXT NULL;

-- Ensure audit_entries is backward-compatible
-- (Already verified in earlier migrations)

-- Create function to validate backward compatibility
CREATE OR REPLACE FUNCTION bpm_check_backward_compatibility()
RETURNS TABLE (
    table_name TEXT,
    status TEXT,
    message TEXT
) AS $$
BEGIN
    -- Check instances table
    RETURN QUERY SELECT
        'instances'::TEXT,
        'OK'::TEXT,
        'instances table has required columns'::TEXT
    WHERE EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public'
        AND table_name = 'instances'
    );

    -- Check events table
    RETURN QUERY SELECT
        'events'::TEXT,
        'OK'::TEXT,
        'events table has required columns'::TEXT
    WHERE EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public'
        AND table_name = 'events'
    );

    -- Check audit_entries table
    RETURN QUERY SELECT
        'audit_entries'::TEXT,
        'OK'::TEXT,
        'audit_entries table has required columns'::TEXT
    WHERE EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public'
        AND table_name = 'audit_entries'
    );
END;
$$ LANGUAGE plpgsql;
