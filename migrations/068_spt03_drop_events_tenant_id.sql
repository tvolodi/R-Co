-- Migration 068: SPT-03 — Drop tenant_id from public.events and public.events_archive.
--
-- Migration 062 (SPT-02) intentionally kept tenant_id on the event-store tables
-- for "runtime compatibility".  SPT-03 removes the last row-based tenancy artefacts
-- from the public schema.  After this migration the events family joins all other
-- public tables in being fully tenant_id-free; the schema-per-tenant search_path
-- mechanism is the sole isolation boundary.
--
-- PUBLIC-SCHEMA-ONLY: The guard exits immediately when running inside a tenant
-- schema via runForSchema(), so per-tenant event tables (which never had tenant_id
-- after the LIKE ... DROP COLUMN pattern in migration 061) are unaffected.
--
-- Idempotent: DROP COLUMN IF EXISTS is a no-op when the column is absent.
--
-- Sequence:
--   1. Drop all remaining tenant_id-based indexes on events / events_archive.
--   2. Drop the tenant_id column (CASCADE drops any remaining dependents).

DO $guard$
BEGIN
    IF current_schema() <> 'public' THEN
        RETURN;
    END IF;

-- ── Step 1: Drop remaining tenant_id-based indexes ────────────────────────────
-- These were kept by migration 062 because the column was retained; now that
-- the column is being removed, drop them explicitly before the CASCADE.

DROP INDEX IF EXISTS idx_events_tenant_instance_seq;
DROP INDEX IF EXISTS idx_events_tenant_global_seq;
DROP INDEX IF EXISTS idx_events_archive_tenant_instance_seq;
DROP INDEX IF EXISTS idx_events_archive_tenant_global_seq;
DROP INDEX IF EXISTS idx_events_tenant_pipeline_run_seq;
DROP INDEX IF EXISTS idx_events_archive_tenant_pipeline_run_seq;

-- ── Step 2: Drop tenant_id columns with CASCADE ───────────────────────────────

ALTER TABLE IF EXISTS events          DROP COLUMN IF EXISTS tenant_id CASCADE;
ALTER TABLE IF EXISTS events_archive  DROP COLUMN IF EXISTS tenant_id CASCADE;

END;
$guard$;
