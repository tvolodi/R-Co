-- Migration 096: EXP-302 — service task effect delivery reference column
-- Date: 2026-06-13
--
-- PURPOSE:
--   Adds an optional `effect_delivery_id` column to the tasks table linking a
--   service task attempt row to the effects_outbox row that replaced inline
--   execution.
--
--   NULL for tasks processed before migration or tasks with sync_inline=true.
--   Non-null after EXP-302 migration is active for a given service task.
--
-- IDEMPOTENCY:
--   Uses IF NOT EXISTS guard (via ADD COLUMN IF NOT EXISTS).

DO $$
DECLARE
    v_tasks_oid OID;
BEGIN
    -- Guard: tasks table must exist in this schema.
    v_tasks_oid := to_regclass('tasks');
    IF v_tasks_oid IS NULL THEN
        RETURN;
    END IF;

    -- Add column only if it does not already exist.
    IF NOT EXISTS (
        SELECT 1
        FROM   information_schema.columns
        WHERE  table_name   = 'tasks'
          AND  column_name  = 'effect_delivery_id'
    ) THEN
        -- Only add the FK reference if effects_outbox exists in this schema.
        IF to_regclass('effects_outbox') IS NOT NULL THEN
            EXECUTE $q$
                ALTER TABLE tasks
                    ADD COLUMN effect_delivery_id UUID
                        REFERENCES effects_outbox(effect_delivery_id)
            $q$;
        ELSE
            EXECUTE $q$
                ALTER TABLE tasks
                    ADD COLUMN effect_delivery_id UUID
            $q$;
        END IF;
    END IF;

END $$;
