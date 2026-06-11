-- Migration 082: ISS-102 — add tasks.claimed_by column and partial indexes
-- Idempotent: all statements use IF NOT EXISTS / to_regclass() guards.
--
-- NOTE ON PUBLIC SCHEMA: tasks lives in per-tenant schemas only.
-- The migration runner applies every non-GBL migration to both public and all
-- tenant schemas. When run against public (where tasks does not exist), the
-- DO $$ block is a no-op thanks to the to_regclass() guard. When run against
-- a tenant schema where tasks exists, it adds the column and indexes.
--
-- claimed_by records the individual worker who atomically claimed the task.
-- NULL = unclaimed; non-NULL = claimed by that worker.

DO $$
DECLARE
    v_tasks_oid OID;
BEGIN
    -- to_regclass() returns NULL if the table does not exist in the current
    -- search_path, making this migration a no-op for the public schema.
    v_tasks_oid := to_regclass('tasks');
    IF v_tasks_oid IS NULL THEN
        -- tasks table does not exist in this schema; nothing to do.
        RETURN;
    END IF;

    -- 2.1 Column addition (idempotent).
    ALTER TABLE tasks
        ADD COLUMN IF NOT EXISTS claimed_by UUID NULL;

    -- 2.2 Partial index: unclaimed work pool.
    -- Supports worker-queue scan: PENDING tasks for this group/role/user not yet claimed.
    -- NOTE: Using CREATE INDEX (without CONCURRENTLY) because the migration runner
    -- executes inside a BEGIN/COMMIT transaction block, and CONCURRENTLY requires
    -- running outside any transaction.
    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = current_schema()
          AND tablename  = 'tasks'
          AND indexname  = 'idx_tasks_unclaimed_pool'
    ) THEN
        CREATE INDEX idx_tasks_unclaimed_pool
            ON tasks (assignee_type, assignee_ref, created_at)
            WHERE status = 'PENDING' AND claimed_by IS NULL;
    END IF;

    -- 2.3 Partial index: "my tasks" (claimed by worker).
    -- Supports GET /tasks?claimed_by=<worker>: PENDING tasks already claimed by the caller.
    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = current_schema()
          AND tablename  = 'tasks'
          AND indexname  = 'idx_tasks_my_tasks'
    ) THEN
        CREATE INDEX idx_tasks_my_tasks
            ON tasks (claimed_by, created_at)
            WHERE status = 'PENDING' AND claimed_by IS NOT NULL;
    END IF;
END
$$;
