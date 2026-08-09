-- 095_iss0176_lua_script_execution_audit.sql
-- ISS-0176 / GH #504 — LUA-07 second acceptance criterion: a script
-- execution's manifest_hash must appear in a persisted, queryable execution
-- audit record.
--
-- See src/design/iss0176-lua07-audit-manifest-hash-minimal-wiring.md §3 for
-- the full rationale. Summary of the schema decision (§3.1): a new,
-- dedicated, application-inserted table — NOT a column on audit_entries
-- (trigger-fed only; a script execution is not a row-level mutation of any
-- trigger-covered table) and NOT audit_log.detail JSONB (would weaken the
-- mutation test and give no typed/indexed column for manifest_hash lookups).
--
-- Neither audit_entries nor audit_log is modified by this migration.
--
-- IDEMPOTENCY: CREATE TABLE/INDEX IF NOT EXISTS throughout (matches 009 and
-- 020's idempotency style).
--
-- No triggers, no immutability guard: this is a narrower, purpose-specific
-- record, not the general-purpose tamper-evident audit trail (§3.2 item 5).
--
-- scope: tenant_only
--
-- ISS-0644 / GH-643: PER_TENANT (canonical home = tenant_default). No
-- tenant_id column — tenant isolation is via schema, keyed by instance_id
-- (tenant-schema process instance data), same shape as
-- instance_definition_snapshots / instance_waits. This file creates exactly
-- one table with no other statements, so the `tenant_only` scope (ISS-0644's
-- new MigrationScope primitive) closes the shadow-recreation path
-- permanently instead of relying on
-- GBL-141_iss0641_drop_dual_schema_shadows.sql to keep cleaning up after
-- every fresh tenant-schema provision.

CREATE TABLE IF NOT EXISTS lua_script_execution_audit (
    audit_id        UUID        PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Executing instance/context identity (design §2.2 step 2). Not a FK to
    -- instance_projections: this path is reachable without a real process
    -- instance existing (e.g. a synthetic UUID in the integration test) —
    -- mirrors audit_entries.resource_id, which also carries no FK.
    instance_id     UUID        NOT NULL,

    -- Nullable, same convention as audit_entries.actor_id.
    actor_id        UUID,

    script_success  BOOLEAN     NOT NULL,

    -- 32-byte SHA-256 hash. NOT NULL because every row this table receives
    -- goes through executeScriptWithManifest, which always produces a
    -- verified hash — the plain executeScript path (manifest_hash = null) is
    -- out of scope for this table (design §6.1/§6.2).
    manifest_hash   BYTEA       NOT NULL CHECK (octet_length(manifest_hash) = 32),

    -- ScriptResult.error_message when script_success = false.
    error_message   TEXT,

    occurred_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Supports the mutation test's SELECT ... WHERE manifest_hash = $1 and the
-- realistic "find executions of this exact manifest" operational query.
CREATE INDEX IF NOT EXISTS idx_lua_script_audit_manifest_hash
    ON lua_script_execution_audit(manifest_hash);

-- Mirrors the time-ordered lookup indexes on both existing audit tables.
CREATE INDEX IF NOT EXISTS idx_lua_script_audit_instance_time
    ON lua_script_execution_audit(instance_id, occurred_at DESC);
