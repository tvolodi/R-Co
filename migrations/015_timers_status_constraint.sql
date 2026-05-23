-- 015_timers_status_constraint.sql
-- SCH-01 hardening: constrain timers.status to the known scheduler lifecycle domain.

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'chk_timers_status_domain'
          AND conrelid = 'timers'::regclass
    ) THEN
        ALTER TABLE timers
            ADD CONSTRAINT chk_timers_status_domain
            CHECK (lower(status) IN ('pending', 'fired', 'cancelled'));
    END IF;
END
$$;
