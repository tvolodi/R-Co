-- 016_timer_recurrence_fields.sql
-- SCH-07 recurring timer state persistence (additive only).

ALTER TABLE timers
    ADD COLUMN IF NOT EXISTS repeat_expression TEXT,
    ADD COLUMN IF NOT EXISTS repeat_total INTEGER,
    ADD COLUMN IF NOT EXISTS fired_count INTEGER,
    ADD COLUMN IF NOT EXISTS repeat_interval_us BIGINT;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'chk_timers_recurrence_shape'
          AND conrelid = 'timers'::regclass
    ) THEN
        ALTER TABLE timers
            ADD CONSTRAINT chk_timers_recurrence_shape
            CHECK (
                (
                    repeat_expression IS NULL
                    AND repeat_total IS NULL
                    AND fired_count IS NULL
                    AND repeat_interval_us IS NULL
                )
                OR
                (
                    repeat_expression IS NOT NULL
                    AND repeat_interval_us IS NOT NULL
                    AND fired_count IS NOT NULL
                    AND fired_count >= 0
                    AND (repeat_total IS NULL OR repeat_total >= 1)
                    AND (repeat_total IS NULL OR fired_count <= repeat_total)
                )
            );
    END IF;
END
$$;
