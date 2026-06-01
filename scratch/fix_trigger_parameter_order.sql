-- Fix the chain hash trigger to use correct parameter order
-- This fixes the parameter order that was incorrect in the initial migration 057

-- Drop the trigger first since it depends on the function
DROP TRIGGER IF EXISTS trg_bpm_audit_apply_chain_hash ON audit_entries;

-- Drop and recreate the function (copy from corrected migration 057)
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

    -- CORRECTED: parameter order now matches bpm_audit_compute_chain_hash signature
    NEW.chain_hash := bpm_audit_compute_chain_hash(
        NEW.tenant_id,
        NEW.actor_id,
        NEW.audit_id,
        NEW.action,
        NEW.resource_type,
        NEW.resource_id,
        NEW."timestamp",
        NULL::JSONB,
        NULL::JSONB,
        NULL::UUID,
        NEW.trace_id,
        NEW.prev_chain_hash,
        NULL::TEXT
    );

    RETURN NEW;
END;
$$;

-- Recreate the trigger
CREATE TRIGGER trg_bpm_audit_apply_chain_hash
BEFORE INSERT ON audit_entries
FOR EACH ROW EXECUTE FUNCTION bpm_audit_apply_chain_hash();

SELECT 'Chain hash trigger fixed with correct parameter order' AS status;
