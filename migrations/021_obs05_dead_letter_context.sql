-- 021_obs05_dead_letter_context.sql
-- Stage 6: OBS-05 dead-letter queue context, pagination order, and retry metadata.

ALTER TABLE dead_letter_queue
    ADD COLUMN IF NOT EXISTS item_type TEXT,
    ADD COLUMN IF NOT EXISTS retry_limit INTEGER,
    ADD COLUMN IF NOT EXISTS original_payload JSONB,
    ADD COLUMN IF NOT EXISTS error_chain JSONB,
    ADD COLUMN IF NOT EXISTS processor_metadata JSONB,
    ADD COLUMN IF NOT EXISTS first_failed_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS last_failed_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS source_ref TEXT;

UPDATE dead_letter_queue
SET item_type = CASE entry_type
    WHEN 'service_task_failed' THEN 'SERVICE_TASK'
    WHEN 'webhook_failed' THEN 'WEBHOOK'
    WHEN 'timer_failed' THEN 'TIMER'
    ELSE 'SERVICE_TASK'
END
WHERE item_type IS NULL;

UPDATE dead_letter_queue
SET retry_limit = COALESCE(max_retries, 3)
WHERE retry_limit IS NULL;

UPDATE dead_letter_queue
SET original_payload = '{}'::jsonb
WHERE original_payload IS NULL;

UPDATE dead_letter_queue
SET error_chain = CASE
    WHEN error_detail IS NULL THEN '[]'::jsonb
    WHEN jsonb_typeof(error_detail) = 'array' THEN error_detail
    ELSE jsonb_build_array(error_detail)
END
WHERE error_chain IS NULL;

UPDATE dead_letter_queue
SET processor_metadata = '{}'::jsonb
WHERE processor_metadata IS NULL;

UPDATE dead_letter_queue
SET first_failed_at = COALESCE(first_failed_at, created_at),
    last_failed_at = COALESCE(last_failed_at, created_at)
WHERE first_failed_at IS NULL OR last_failed_at IS NULL;

UPDATE dead_letter_queue
SET source_ref = COALESCE(source_ref, id::text)
WHERE source_ref IS NULL;

ALTER TABLE dead_letter_queue
    ALTER COLUMN item_type SET NOT NULL,
    ALTER COLUMN retry_limit SET NOT NULL,
    ALTER COLUMN retry_limit SET DEFAULT 3,
    ALTER COLUMN original_payload SET NOT NULL,
    ALTER COLUMN original_payload SET DEFAULT '{}'::jsonb,
    ALTER COLUMN error_chain SET NOT NULL,
    ALTER COLUMN error_chain SET DEFAULT '[]'::jsonb,
    ALTER COLUMN processor_metadata SET NOT NULL,
    ALTER COLUMN processor_metadata SET DEFAULT '{}'::jsonb,
    ALTER COLUMN first_failed_at SET NOT NULL,
    ALTER COLUMN first_failed_at SET DEFAULT NOW(),
    ALTER COLUMN last_failed_at SET NOT NULL,
    ALTER COLUMN last_failed_at SET DEFAULT NOW(),
    ALTER COLUMN source_ref SET NOT NULL;

CREATE INDEX IF NOT EXISTS idx_dlq_created_order
    ON dead_letter_queue(created_at DESC, id DESC)
    WHERE status IN ('pending', 'retrying');

CREATE INDEX IF NOT EXISTS idx_dlq_item_type
    ON dead_letter_queue(item_type, created_at DESC, id DESC)
    WHERE status IN ('pending', 'retrying');

CREATE INDEX IF NOT EXISTS idx_dlq_instance_type
    ON dead_letter_queue(instance_id, item_type, created_at DESC, id DESC)
    WHERE status IN ('pending', 'retrying');

CREATE UNIQUE INDEX IF NOT EXISTS uq_dlq_source_failure
    ON dead_letter_queue(item_type, source_ref, last_failed_at);
