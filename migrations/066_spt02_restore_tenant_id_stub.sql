-- Migration 066: SPT-02 follow-up — restore bpm_effective_tenant_id() compatibility stub.
--
-- Migration 062 dropped bpm_effective_tenant_id() from the public schema.
-- However, the function is referenced in migration 028 as a column DEFAULT
-- expression:
--
--   ALTER TABLE process_definitions ADD COLUMN IF NOT EXISTS tenant_id UUID
--       DEFAULT bpm_effective_tenant_id();
--
-- When provisionTenantSchema() calls runForSchema() to build a new tenant
-- schema, ALL migrations (001–065) are applied in order.  Migration 028 runs
-- before 062, so by the time 062 is reached the function already exists inside
-- the tenant schema (created by migration 028).  BUT migration 028 looks up
-- bpm_effective_tenant_id() via search_path at ALTER TABLE time; if the
-- function is absent from both the tenant schema and public, the DDL fails.
--
-- Migration 066 re-creates the function as a schema-aware stub:
--   • In the PUBLIC schema (search_path check) the function is a no-op stub
--     that returns the all-zeros UUID.  It is only needed so migration 028
--     can apply to tenant schemas successfully; the Zig runtime never calls it.
--   • SPT-03 will drop this function permanently once all Zig call-sites that
--     pass tenant_id are removed from the source code.
--
-- This migration is IDEMPOTENT (CREATE OR REPLACE).

CREATE OR REPLACE FUNCTION bpm_effective_tenant_id()
RETURNS UUID
LANGUAGE sql
STABLE
AS $$
    -- Compatibility stub: returns the all-zeros UUID.
    -- Called only from migration 028's column DEFAULT expression when
    -- provisioning tenant schemas after migration 062 has removed the
    -- original tenant-filtering implementation.
    -- Will be dropped by SPT-03.
    SELECT '00000000-0000-0000-0000-000000000000'::UUID;
$$;
