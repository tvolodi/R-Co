-- 1141_iss0645_audit_chain_function_overload_cleanup.sql
-- ISS-0645 / GH-649: corrective — drop the stale UUID-typed overloads of
-- bpm_audit_compute_chain_hash and bpm_audit_chain_canonical_payload left
-- behind in every tenant schema after 1107_fix_audit_chain_text_resource_id.sql.
--
-- Root cause:
--   1107_fix_audit_chain_text_resource_id.sql intended to drop the UUID-typed
--   overload of each function (originally created by 035_adp09_tamper_evident_
--   audit_chain.sql with a 13th parameter `p_trace_id TEXT DEFAULT NULL`) before
--   recreating a TEXT-typed replacement. Its DROP FUNCTION statements listed
--   only 12 argument types, omitting the trailing p_trace_id TEXT parameter:
--
--     DROP FUNCTION IF EXISTS bpm_audit_compute_chain_hash(
--         UUID,UUID,UUID,TEXT,TEXT,UUID,TIMESTAMPTZ,JSONB,JSONB,UUID,JSONB,TEXT);
--
--   PostgreSQL resolves DROP FUNCTION overloads by exact parameter-type list;
--   a 12-arg signature does not match the actual 13-arg function, so under
--   IF EXISTS the DROP silently no-ops (NOTICE: function ... does not exist,
--   skipping) instead of raising an error. The UUID-typed overload was never
--   removed, so every schema the migration runner has touched since (once per
--   tenant schema, via runForSchema()'s per-schema search_path pass) now
--   carries BOTH the original UUID-typed overload and the newer TEXT-typed
--   replacement side by side.
--
-- Symptom:
--   tests/integration/adp09_tamper_evident_audit_chain_test.zig TC-ADP-09-01
--   queries pg_proc (schema-qualified to tenant_default as of this same
--   ISS-0645 pass) expecting exactly 3 rows for
--   {bpm_audit_compute_chain_hash, bpm_audit_apply_chain_hash,
--   bpm_audit_validate_chain} and instead finds 4 -- the two overloads of
--   bpm_audit_compute_chain_hash both match the `proname IN (...)` filter.
--   Verified directly on a freshly migrated, workspace-owned database
--   (bpm_gh649_fresh): tenant_default carries both
--   bpm_audit_compute_chain_hash(...,p_resource_id uuid,...) and
--   bpm_audit_compute_chain_hash(...,p_resource_id text,...), and the same
--   duplication exists for bpm_audit_chain_canonical_payload.
--
-- Fix:
--   Drop both stale UUID-typed overloads with the correct, complete 13-arg
--   signature (including p_trace_id TEXT) so the DROP actually matches. This
--   migration is unqualified (search_path-resolved, no GBL- prefix) so
--   runForSchema() applies it once per already-provisioned schema
--   (public, tenant_default, and every tenant_<uuid> schema), cleaning up
--   the duplication everywhere it was introduced. Idempotent: IF EXISTS
--   guards make repeat application on already-cleaned schemas a no-op.
--
-- Non-destructive: the TEXT-typed overloads (the ones actually in use by the
-- BEFORE INSERT trigger and by bpm_audit_validate_chain) are untouched.

DROP FUNCTION IF EXISTS bpm_audit_compute_chain_hash(
    UUID,UUID,UUID,TEXT,TEXT,UUID,TIMESTAMPTZ,JSONB,JSONB,UUID,JSONB,TEXT,TEXT);

DROP FUNCTION IF EXISTS bpm_audit_chain_canonical_payload(
    UUID,UUID,UUID,TEXT,TEXT,UUID,TIMESTAMPTZ,JSONB,JSONB,UUID,JSONB,TEXT,TEXT);
