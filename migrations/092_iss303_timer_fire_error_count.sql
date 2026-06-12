-- 089_iss303_timer_fire_error_count.sql
-- Requirements: ISS-303
--
-- Add fire_error_count and failed_at to timers table.
-- Idempotent: uses information_schema column existence check inside the
-- to_regclass() guard, same pattern as migration 081.

DO $$
DECLARE
    v_timers_oid OID;
BEGIN
    v_timers_oid := to_regclass('timers');
    IF v_timers_oid IS NULL THEN
        RETURN;  -- timers does not exist in this schema (e.g. public); no-op
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name   = 'timers'
          AND column_name  = 'fire_error_count'
    ) THEN
        EXECUTE 'ALTER TABLE timers ADD COLUMN fire_error_count INTEGER NOT NULL DEFAULT 0';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name   = 'timers'
          AND column_name  = 'failed_at'
    ) THEN
        EXECUTE 'ALTER TABLE timers ADD COLUMN failed_at TIMESTAMPTZ NULL';
    END IF;
END
$$;
