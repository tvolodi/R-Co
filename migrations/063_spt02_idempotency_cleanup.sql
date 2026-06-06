-- Migration 063: SPT-02 data migration phase 3 — belt-and-suspenders idempotency cleanup.
--
-- Drops all known tenant RLS policies by their exact names, regardless of whether
-- migration 062 has already removed them. This ensures any database that partially
-- applied migration 062 (or skipped it entirely) reaches a clean no-policy state.
--
-- PUBLIC-SCHEMA-ONLY: This migration is a no-op when runForSchema() executes
-- it inside a tenant schema. The guard below ensures the body only runs when
-- current_schema() = 'public'.
--
-- All statements are DROP POLICY IF EXISTS — no-ops if the policy is already absent.
-- Safe to run any number of times.
--
-- Policies covered (created in migration 028):
--   process_definitions_tenant_policy   ON process_definitions
--   instance_projections_tenant_policy  ON instance_projections
--   tasks_tenant_policy                 ON tasks
--   tokens_tenant_policy                ON tokens
--   audit_entries_tenant_policy         ON audit_entries
--   audit_log_tenant_policy             ON audit_log

DO $guard$
BEGIN
    IF current_schema() <> 'public' THEN
        -- Running inside a tenant schema via runForSchema() — skip entirely.
        RETURN;
    END IF;

DROP POLICY IF EXISTS process_definitions_tenant_policy   ON process_definitions;
DROP POLICY IF EXISTS instance_projections_tenant_policy  ON instance_projections;
DROP POLICY IF EXISTS tasks_tenant_policy                 ON tasks;
DROP POLICY IF EXISTS tokens_tenant_policy                ON tokens;
DROP POLICY IF EXISTS audit_entries_tenant_policy         ON audit_entries;
DROP POLICY IF EXISTS audit_log_tenant_policy             ON audit_log;

END;
$guard$;

