-- Migration 064: SPT-02 follow-up — fix audit chain trigger after tenant_id removal.
--
-- Migration 062 dropped the tenant_id column from audit_entries (and all other
-- public tables), but did not update the bpm_audit_apply_chain_hash() trigger
-- function which still references NEW.tenant_id.  This causes every INSERT on
-- any audited table to fail with "column NEW.tenant_id does not exist".
--
-- This migration:
--   1. Replaces bpm_audit_apply_chain_hash() to remove all NEW.tenant_id
--      references.  The advisory lock and chain-hash predecessor lookup become
--      global (not per-tenant) since there is no longer a tenant_id column.
--   2. Replaces bpm_audit_is_agent_actor() to remove the u.tenant_id filter
--      (undefined_column after migration 062 is not caught by the existing
--      EXCEPTION WHEN undefined_table handler).
--   3. Replaces bpm_audit_build_agent_payload_full() to remove the u.tenant_id
--      filter for the same reason.
--   4. Adds a unique constraint uq_definition_name_version on
--      (name, version) in process_definitions to replace the dropped
--      uq_definition_tenant_version constraint so that ON CONFLICT DO NOTHING
--      still works for concurrent create requests (PD-01).
--
-- All replacements are idempotent (CREATE OR REPLACE / IF NOT EXISTS).

-- ── 1: Replace bpm_audit_apply_chain_hash() — remove NEW.tenant_id references ───

CREATE OR REPLACE FUNCTION bpm_audit_apply_chain_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    predecessor_hash TEXT;
    pipeline_run_setting TEXT;
BEGIN
    IF NEW.pipeline_run_id IS NULL THEN
        pipeline_run_setting := NULLIF(current_setting('bpm.pipeline_run_id', true), '');
        IF pipeline_run_setting IS NOT NULL THEN
            NEW.pipeline_run_id := bpm_audit_try_uuid(pipeline_run_setting);
        END IF;
    END IF;

    -- tenant_id was dropped from audit_entries by migration 062.
    -- Pass NULL for p_tenant_id throughout; the functions handle NULL gracefully.
    IF NEW.payload_full IS NULL AND bpm_audit_is_agent_actor(NULL, NEW.actor_id) THEN
        NEW.payload_full := bpm_audit_build_agent_payload_full(
            NULL,
            NEW.actor_id,
            NEW.action,
            NEW.resource_type,
            NEW.resource_id,
            NEW."timestamp",
            NEW.before_state,
            NEW.after_state,
            NEW.pipeline_run_id
        );
    END IF;

    -- Global advisory lock (no per-tenant key after tenant_id removal).
    PERFORM pg_advisory_xact_lock(hashtext('bpm.audit.chain.global'));

    SELECT chain_hash
      INTO predecessor_hash
      FROM audit_entries
     WHERE chain_hash IS NOT NULL
     ORDER BY "timestamp" DESC, audit_id DESC
     LIMIT 1;

    NEW.prev_chain_hash := predecessor_hash;

    NEW.chain_hash := bpm_audit_compute_chain_hash(
        NULL,
        NEW.audit_id,
        NEW.actor_id,
        NEW.action,
        NEW.resource_type,
        NEW.resource_id,
        NEW."timestamp",
        NEW.before_state,
        NEW.after_state,
        NEW.pipeline_run_id,
        NEW.payload_full,
        NEW.prev_chain_hash,
        NULL
    );

    RETURN NEW;
END;
$$;

-- ── 2: Replace bpm_audit_is_agent_actor() — remove u.tenant_id filter ───────────

CREATE OR REPLACE FUNCTION bpm_audit_is_agent_actor(
    p_tenant_id UUID,
    p_actor_id UUID
)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    actor_username_setting TEXT;
    actor_roles_setting TEXT;
    stored_username TEXT;
BEGIN
    IF p_actor_id IS NULL THEN
        RETURN FALSE;
    END IF;

    actor_username_setting := NULLIF(current_setting('bpm.actor_username', true), '');
    IF actor_username_setting IS NOT NULL AND lower(actor_username_setting) LIKE 'agent:%' THEN
        RETURN TRUE;
    END IF;

    actor_roles_setting := NULLIF(current_setting('bpm.actor_roles', true), '');
    IF actor_roles_setting IS NOT NULL AND position('AGENT_RUNNER' IN actor_roles_setting) > 0 THEN
        RETURN TRUE;
    END IF;

    BEGIN
        -- tenant_id was dropped from users by migration 062; query by id only.
        SELECT u.username
          INTO stored_username
          FROM users u
         WHERE u.id = p_actor_id
         LIMIT 1;
    EXCEPTION WHEN OTHERS THEN
        stored_username := NULL;
    END;

    IF stored_username IS NULL THEN
        RETURN FALSE;
    END IF;

    RETURN lower(stored_username) LIKE 'agent:%';
END;
$$;

-- ── 3: Replace bpm_audit_build_agent_payload_full() — remove u.tenant_id filter ─

CREATE OR REPLACE FUNCTION bpm_audit_build_agent_payload_full(
    p_tenant_id UUID,
    p_actor_id UUID,
    p_action TEXT,
    p_resource_type TEXT,
    p_resource_id UUID,
    p_timestamp TIMESTAMPTZ,
    p_before_state JSONB,
    p_after_state JSONB,
    p_pipeline_run_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    policy_id TEXT;
    allow_raw_messages BOOLEAN;
    capture_mode TEXT;
    trace_id TEXT;
    invocation_id TEXT;
    max_bytes INTEGER;
    observed_bytes INTEGER;
    was_truncated BOOLEAN := FALSE;
    actor_username TEXT;
    role_set JSONB;
    raw_payload JSONB;
    input_payload JSONB;
    output_payload JSONB;
    tool_calls_payload JSONB;
    llm_payload JSONB;
    redaction_rules JSONB;
    payload JSONB;
BEGIN
    policy_id := COALESCE(NULLIF(current_setting('bpm.audit_payload_policy_id', true), ''), 'adp10.default');
    allow_raw_messages := bpm_audit_safe_bool(current_setting('bpm.audit_payload_allow_raw_messages', true), FALSE);
    capture_mode := COALESCE(NULLIF(current_setting('bpm.audit_capture_mode', true), ''), CASE WHEN allow_raw_messages THEN 'full' ELSE 'metadata_only' END);
    IF capture_mode NOT IN ('full', 'redacted', 'metadata_only') THEN
        capture_mode := CASE WHEN allow_raw_messages THEN 'full' ELSE 'metadata_only' END;
    END IF;

    trace_id := NULLIF(current_setting('bpm.trace_id', true), '');
    invocation_id := COALESCE(NULLIF(current_setting('bpm.audit_invocation_id', true), ''), lower(p_resource_id::TEXT));
    max_bytes := bpm_audit_safe_int(current_setting('bpm.audit_payload_max_bytes', true), 1048576);

    actor_username := NULLIF(current_setting('bpm.actor_username', true), '');
    IF actor_username IS NULL THEN
        BEGIN
            -- tenant_id was dropped from users by migration 062; query by id only.
            SELECT u.username
              INTO actor_username
              FROM users u
             WHERE u.id = p_actor_id
             LIMIT 1;
        EXCEPTION WHEN OTHERS THEN
            actor_username := NULL;
        END;
    END IF;
    actor_username := COALESCE(actor_username, 'agent:unknown');

    role_set := bpm_audit_parse_jsonb(NULLIF(current_setting('bpm.actor_roles_json', true), ''));
    IF role_set IS NULL OR jsonb_typeof(role_set) <> 'array' THEN
        role_set := '["AGENT_RUNNER"]'::JSONB;
    END IF;

    raw_payload := bpm_audit_parse_jsonb(NULLIF(current_setting('bpm.audit_payload_full', true), ''));
    input_payload := COALESCE(raw_payload->'input', COALESCE(p_before_state, '{}'::JSONB));
    output_payload := COALESCE(raw_payload->'output', p_after_state);
    tool_calls_payload := COALESCE(raw_payload->'tool_calls', '[]'::JSONB);
    IF jsonb_typeof(tool_calls_payload) <> 'array' THEN
        tool_calls_payload := '[]'::JSONB;
    END IF;

    payload := jsonb_build_object(
        'schema_version', 'adp10.v1',
        'capture_mode', capture_mode,
        'policy_id', policy_id,
        'actor', jsonb_build_object(
            'id', p_actor_id,
            'username', actor_username,
            'roles', role_set
        ),
        'invocation_id', invocation_id,
        'trace_id', trace_id,
        'action', p_action,
        'resource_type', p_resource_type,
        'resource_id', p_resource_id,
        'timestamp', p_timestamp,
        'tool_calls', tool_calls_payload
    );

    IF capture_mode IN ('full', 'redacted') THEN
        observed_bytes := length(input_payload::TEXT) + length(COALESCE(output_payload::TEXT, ''));
        IF observed_bytes > max_bytes THEN
            was_truncated := TRUE;
            input_payload := NULL;
            output_payload := NULL;
        END IF;
        payload := payload || jsonb_build_object(
            'input', input_payload,
            'output', output_payload,
            'was_truncated', was_truncated
        );
    END IF;

    RETURN payload;
END;
$$;

-- ── 4: Add unique constraint on (name, version) for process_definitions ──────────
-- Replaces the dropped uq_definition_tenant_version (name, version, tenant_id).
-- Allows ON CONFLICT ON CONSTRAINT uq_definition_name_version DO NOTHING
-- for concurrent create requests (PD-01).

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'uq_definition_name_version'
          AND conrelid = 'process_definitions'::regclass
    ) THEN
        ALTER TABLE process_definitions
            ADD CONSTRAINT uq_definition_name_version UNIQUE (name, version);
    END IF;
END $$;
