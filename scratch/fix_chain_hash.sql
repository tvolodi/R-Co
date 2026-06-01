-- Drop the trigger first since it depends on the function
DROP TRIGGER IF EXISTS trg_bpm_audit_apply_chain_hash ON audit_entries;

-- Drop and recreate the function with correct parameter order
DROP FUNCTION IF EXISTS bpm_audit_compute_chain_hash(UUID, UUID, UUID, TEXT, TEXT, UUID, TIMESTAMPTZ, JSONB, JSONB, UUID, TEXT, TEXT, TEXT);

CREATE FUNCTION bpm_audit_compute_chain_hash(
    p_tenant_id UUID,
    p_actor_id UUID,
    p_audit_id UUID,
    p_action TEXT,
    p_resource_type TEXT,
    p_resource_id UUID,
    p_timestamp TIMESTAMPTZ,
    p_context JSONB,
    p_result JSONB,
    p_ref_id UUID,
    p_trace_id TEXT,
    p_prev_hash TEXT,
    p_request_id TEXT
)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    SELECT encode(
        digest(
            CONCAT(
                COALESCE(p_tenant_id::TEXT, ''),  '|',
                COALESCE(p_actor_id::TEXT, ''),  '|',
                COALESCE(p_audit_id::TEXT, ''),  '|',
                COALESCE(p_action, ''),  '|',
                COALESCE(p_resource_type, ''),  '|',
                COALESCE(p_resource_id::TEXT, ''),  '|',
                COALESCE(p_timestamp::TEXT, ''),  '|',
                COALESCE(p_context::TEXT, ''),  '|',
                COALESCE(p_result::TEXT, ''),  '|',
                COALESCE(p_ref_id::TEXT, ''),  '|',
                COALESCE(p_trace_id, ''),  '|',
                COALESCE(p_prev_hash, ''),  '|',
                COALESCE(p_request_id, '')
            ),
            'sha256'
        ),
        'hex'
    );
$$;

-- Drop and recreate the trigger with correct parameter order
DROP FUNCTION IF EXISTS bpm_audit_apply_chain_hash();
CREATE FUNCTION bpm_audit_apply_chain_hash()
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

    IF NEW.payload_full IS NULL AND bpm_audit_is_agent_actor(NEW.tenant_id, NEW.actor_id) THEN
        NEW.payload_full := bpm_audit_build_agent_payload_full(
            NEW.tenant_id,
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

    -- Serialize inserts per tenant to prevent chain forks under concurrency.
    PERFORM pg_advisory_xact_lock(hashtext('bpm.audit.chain.' || NEW.tenant_id::text));

    SELECT chain_hash
      INTO predecessor_hash
      FROM audit_entries
     WHERE tenant_id = NEW.tenant_id
       AND chain_hash IS NOT NULL
     ORDER BY "timestamp" DESC, audit_id DESC
     LIMIT 1;

    NEW.prev_chain_hash := predecessor_hash;

    NEW.chain_hash := bpm_audit_compute_chain_hash(
        NEW.tenant_id,
        NEW.actor_id,
        NEW.audit_id,
        NEW.action,
        NEW.resource_type,
        NEW.resource_id,
        NEW."timestamp",
        NEW.before_state,
        NEW.after_state,
        NULL,
        NEW.trace_id,
        NEW.prev_chain_hash,
        NULL
    );

    RETURN NEW;
END;
$$;

-- Recreate the trigger
CREATE TRIGGER trg_bpm_audit_apply_chain_hash
BEFORE INSERT ON audit_entries
FOR EACH ROW EXECUTE FUNCTION bpm_audit_apply_chain_hash();

SELECT 'Chain hash function and trigger recreated successfully' AS status;
