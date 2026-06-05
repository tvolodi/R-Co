-- Migration 065: SPT-02 follow-up — replace dropped tenant-scoped unique constraints.
--
-- Migration 062 dropped:
--   uq_instance_tenant_correlation (definition_id, tenant_id, correlation_key)
--   uq_active_definition_tenant    (name) WHERE status='ACTIVE' (partial, tenant-scoped)
--   uq_definition_name_version     was added in migration 064
--
-- This migration adds the tenant-agnostic replacements so that ON CONFLICT
-- clauses in the Zig source code have valid constraint targets.
--
-- All operations are idempotent (DO ... IF NOT EXISTS).

-- ── 1: Global correlation_key uniqueness for instance_projections ─────────────
-- Replaces: uq_instance_tenant_correlation (tenant_id, definition_id, correlation_key)
-- New constraint: uniqueness on (definition_id, correlation_key) globally.
--
-- Note: if the current data has duplicate (definition_id, correlation_key) pairs
-- (possible if multiple tenants had overlapping keys), this ADD CONSTRAINT will
-- fail.  In that case, deduplicate the rows first.

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'uq_instance_definition_correlation'
          AND conrelid = 'instance_projections'::regclass
    ) THEN
        ALTER TABLE instance_projections
            ADD CONSTRAINT uq_instance_definition_correlation
            UNIQUE (definition_id, correlation_key);
    END IF;
END $$;

-- ── 2: Global ACTIVE uniqueness for process_definitions ──────────────────────
-- Replaces: uq_active_definition_tenant (partial unique: name WHERE status='ACTIVE')
-- New constraint: at most one ACTIVE definition per name, globally.
-- Only add if the index does not exist yet.

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE indexname = 'uq_active_definition_global'
          AND tablename = 'process_definitions'
    ) THEN
        CREATE UNIQUE INDEX uq_active_definition_global
            ON process_definitions (name)
            WHERE status = 'ACTIVE';
    END IF;
END $$;
