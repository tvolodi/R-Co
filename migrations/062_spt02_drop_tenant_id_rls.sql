-- Migration 062: SPT-02 data migration phase 2
-- Remove all row-based tenancy infrastructure from the public schema.
-- All operations are guarded with IF EXISTS for full idempotency.
--
-- Operations performed in safe order:
--   1. DROP all known RLS policies (they reference bpm_effective_tenant_id).
--   2. DISABLE ROW LEVEL SECURITY on all affected tables.
--   3. DROP FUNCTION bpm_effective_tenant_id() CASCADE
--      (removes column DEFAULT expressions that call the function).
--   4. DROP all tenant_id-based named constraints.
--   5. DROP all tenant_id-based composite indexes.
--   6. DROP COLUMN tenant_id from all affected tables (CASCADE removes
--      any remaining dependents not caught by earlier steps).

-- ── Step 1: Drop all known RLS policies ──────────────────────────────────────

DROP POLICY IF EXISTS process_definitions_tenant_policy   ON process_definitions;
DROP POLICY IF EXISTS instance_projections_tenant_policy  ON instance_projections;
DROP POLICY IF EXISTS tasks_tenant_policy                 ON tasks;
DROP POLICY IF EXISTS tokens_tenant_policy                ON tokens;
DROP POLICY IF EXISTS audit_entries_tenant_policy         ON audit_entries;
DROP POLICY IF EXISTS audit_log_tenant_policy             ON audit_log;

-- ── Step 2: Disable RLS on all affected tables ────────────────────────────────

ALTER TABLE IF EXISTS process_definitions   DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS instance_projections  DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS tasks                 DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS tokens                DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS audit_entries         DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS audit_log             DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS events                DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS events_archive        DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS users                 DISABLE ROW LEVEL SECURITY;
ALTER TABLE IF EXISTS groups                DISABLE ROW LEVEL SECURITY;

-- ── Step 3: Drop bpm_effective_tenant_id() ───────────────────────────────────
-- CASCADE also removes column DEFAULT expressions referencing this function
-- and any RLS policies that were not explicitly listed above.

DROP FUNCTION IF EXISTS bpm_effective_tenant_id() CASCADE;

-- ── Step 4: Drop tenant_id-based named constraints ───────────────────────────

ALTER TABLE IF EXISTS process_definitions
    DROP CONSTRAINT IF EXISTS uq_definition_tenant_version;

-- ── Step 5: Drop tenant_id-based composite indexes ───────────────────────────
-- Covers all indexes created in migrations 027, 028, 029, 033, 035, and 051.

-- events (migration 027)
DROP INDEX IF EXISTS idx_events_tenant_instance_seq;
DROP INDEX IF EXISTS idx_events_tenant_global_seq;

-- events_archive (migration 027)
DROP INDEX IF EXISTS idx_events_archive_tenant_instance_seq;
DROP INDEX IF EXISTS idx_events_archive_tenant_global_seq;

-- events + events_archive pipeline_run correlation indexes (migration 033)
DROP INDEX IF EXISTS idx_events_tenant_pipeline_run_seq;
DROP INDEX IF EXISTS idx_events_archive_tenant_pipeline_run_seq;

-- process_definitions (migration 028)
DROP INDEX IF EXISTS uq_active_definition_tenant;
DROP INDEX IF EXISTS idx_def_tenant_name_status;
DROP INDEX IF EXISTS idx_def_tenant_created;

-- instance_projections (migration 028)
DROP INDEX IF EXISTS uq_instance_tenant_correlation;
DROP INDEX IF EXISTS idx_proj_tenant_status;
DROP INDEX IF EXISTS idx_proj_tenant_definition;
DROP INDEX IF EXISTS idx_proj_tenant_instance;

-- tasks (migration 028)
DROP INDEX IF EXISTS idx_task_tenant_instance;
DROP INDEX IF EXISTS idx_task_tenant_pending_assignee;
DROP INDEX IF EXISTS idx_task_tenant_status;

-- tokens (migration 028)
DROP INDEX IF EXISTS idx_token_tenant_instance;
DROP INDEX IF EXISTS idx_token_tenant_active;
DROP INDEX IF EXISTS idx_token_tenant_waiting;

-- audit_entries (migrations 028, 033, 035, 051)
DROP INDEX IF EXISTS idx_audit_entries_tenant_time;
DROP INDEX IF EXISTS idx_audit_entries_tenant_resource_time;
DROP INDEX IF EXISTS idx_audit_entries_tenant_pipeline_time;
DROP INDEX IF EXISTS idx_audit_entries_tenant_chain_lookup;
DROP INDEX IF EXISTS uq_audit_entries_tenant_chain_hash;
DROP INDEX IF EXISTS idx_audit_entries_tenant_chain;

-- audit_log (migration 028)
DROP INDEX IF EXISTS idx_audit_log_tenant_time;

-- users (migration 029)
DROP INDEX IF EXISTS idx_users_tenant_status_created;

-- groups (migration 029)
DROP INDEX IF EXISTS idx_groups_tenant_name;

-- ── Step 6: Drop tenant_id columns ───────────────────────────────────────────
-- Drop from every affected table. CASCADE removes any remaining dependents
-- (indexes, constraints, defaults) not already dropped above.

ALTER TABLE IF EXISTS events               DROP COLUMN IF EXISTS tenant_id CASCADE;
ALTER TABLE IF EXISTS events_archive       DROP COLUMN IF EXISTS tenant_id CASCADE;
ALTER TABLE IF EXISTS process_definitions  DROP COLUMN IF EXISTS tenant_id CASCADE;
ALTER TABLE IF EXISTS instance_projections DROP COLUMN IF EXISTS tenant_id CASCADE;
ALTER TABLE IF EXISTS tasks                DROP COLUMN IF EXISTS tenant_id CASCADE;
ALTER TABLE IF EXISTS tokens               DROP COLUMN IF EXISTS tenant_id CASCADE;
ALTER TABLE IF EXISTS audit_entries        DROP COLUMN IF EXISTS tenant_id CASCADE;
ALTER TABLE IF EXISTS audit_log            DROP COLUMN IF EXISTS tenant_id CASCADE;
ALTER TABLE IF EXISTS users                DROP COLUMN IF EXISTS tenant_id CASCADE;
ALTER TABLE IF EXISTS groups               DROP COLUMN IF EXISTS tenant_id CASCADE;
ALTER TABLE IF EXISTS tenant_hostnames     DROP COLUMN IF EXISTS tenant_id CASCADE;
