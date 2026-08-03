-- GBL-082_fix_audit_chain_resource_id_text.sql
-- Fix: After GBL-081 changed audit_entries.resource_id from UUID to TEXT,
-- the audit chain functions bpm_audit_chain_canonical_payload and
-- bpm_audit_compute_chain_hash still declared resource_id as UUID.
-- This caused a type mismatch when the audit trigger tried to call them
-- with a TEXT resource_id, blocking ALL audit INSERT operations.
--
-- Also fix: bpm_audit_resource_info referenced dead_letter_queue but
-- migration 072 renamed it to dead_letter_items. Add both variants.

-- 1. Update bpm_audit_chain_canonical_payload to accept TEXT resource_id
CREATE OR REPLACE FUNCTION bpm_audit_chain_canonical_payload(
    p_tenant_id UUID,
    p_audit_id UUID,
    p_actor_id UUID,
    p_action TEXT,
    p_resource_type TEXT,
    p_resource_id TEXT,
    p_timestamp TIMESTAMPTZ,
    p_before_state JSONB,
    p_after_state JSONB,
    p_pipeline_run_id UUID,
    p_payload_full JSONB,
    p_prev_chain_hash TEXT,
    p_trace_id TEXT DEFAULT NULL
)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    SELECT concat_ws(E'\n',
        'tenant_id=' || lower(p_tenant_id::text),
        'audit_id=' || lower(p_audit_id::text),
        'actor_id=' || COALESCE(lower(p_actor_id::text), '~'),
        'action=' || COALESCE(p_action, '~'),
        'resource_type=' || COALESCE(p_resource_type, '~'),
        'resource_id=' || p_resource_id,
        'trace_id=' || COALESCE(p_trace_id, '~'),
        'created_at_us=' || ((EXTRACT(EPOCH FROM p_timestamp) * 1000000)::bigint)::text,
        'before_state=' || COALESCE(p_before_state::text, '~'),
        'after_state=' || COALESCE(p_after_state::text, '~'),
        'pipeline_run_id=' || COALESCE(lower(p_pipeline_run_id::text), '~'),
        'payload_full=' || COALESCE(p_payload_full::text, '~'),
        'prev_chain_hash=' || COALESCE(lower(p_prev_chain_hash), '~')
    );
$$;

-- 2. Update bpm_audit_compute_chain_hash to accept TEXT resource_id
CREATE OR REPLACE FUNCTION bpm_audit_compute_chain_hash(
    p_tenant_id UUID,
    p_audit_id UUID,
    p_actor_id UUID,
    p_action TEXT,
    p_resource_type TEXT,
    p_resource_id TEXT,
    p_timestamp TIMESTAMPTZ,
    p_before_state JSONB,
    p_after_state JSONB,
    p_pipeline_run_id UUID,
    p_payload_full JSONB,
    p_prev_chain_hash TEXT,
    p_trace_id TEXT DEFAULT NULL
)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    SELECT encode(
        digest(
            convert_to(
                bpm_audit_chain_canonical_payload(
                    p_tenant_id,
                    p_audit_id,
                    p_actor_id,
                    p_action,
                    p_resource_type,
                    p_resource_id,
                    p_timestamp,
                    p_before_state,
                    p_after_state,
                    p_pipeline_run_id,
                    p_payload_full,
                    p_prev_chain_hash,
                    p_trace_id
                ),
                'utf8'
            ),
            'sha256'
        ),
        'hex'
    );
$$;

-- 3. Update bpm_audit_resource_info to handle dead_letter_items (renamed from dead_letter_queue)
--    Must DROP first because return type is changing (was already changed by GBL-081)
DROP FUNCTION IF EXISTS bpm_audit_resource_info(TEXT, JSONB, JSONB);

CREATE OR REPLACE FUNCTION bpm_audit_resource_info(
    table_name TEXT,
    old_row JSONB,
    new_row JSONB,
    OUT resource_type TEXT,
    OUT resource_id TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    src JSONB;
BEGIN
    src := COALESCE(new_row, old_row);

    IF table_name = 'process_definitions' THEN
        resource_type := 'definition';
        resource_id := LOWER(((src->>'id')::uuid)::TEXT);
        RETURN;
    END IF;

    IF table_name = 'instance_projections' THEN
        resource_type := 'instance';
        resource_id := LOWER(((src->>'instance_id')::uuid)::TEXT);
        RETURN;
    END IF;

    IF table_name = 'tasks' THEN
        resource_type := 'task';
        resource_id := LOWER(((src->>'id')::uuid)::TEXT);
        RETURN;
    END IF;

    IF table_name = 'users' THEN
        resource_type := 'user';
        resource_id := LOWER(((src->>'id')::uuid)::TEXT);
        RETURN;
    END IF;

    IF table_name = 'groups' THEN
        resource_type := 'group';
        resource_id := LOWER(((src->>'id')::uuid)::TEXT);
        RETURN;
    END IF;

    IF table_name = 'group_members' THEN
        resource_type := 'group_member';
        resource_id := LOWER(((src->>'user_id')::uuid)::TEXT);
        RETURN;
    END IF;

    IF table_name = 'api_tokens' THEN
        resource_type := 'token';
        resource_id := LOWER(((src->>'id')::uuid)::TEXT);
        RETURN;
    END IF;

    IF table_name = 'dead_letter_queue' THEN
        resource_type := 'dlq';
        resource_id := LOWER(((src->>'id')::uuid)::TEXT);
        RETURN;
    END IF;

    IF table_name = 'dead_letter_items' THEN
        resource_type := 'dlq';
        resource_id := LOWER(((src->>'id')::uuid)::TEXT);
        RETURN;
    END IF;

    resource_type := table_name;
    resource_id := NULL;
END;
$$;
