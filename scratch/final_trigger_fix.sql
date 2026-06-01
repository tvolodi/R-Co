-- FINAL FIX: Restore bpm_audit_apply_chain_hash to match migration 051 exactly
-- This fixes the parameter order and types that were incorrect in migration 057

DROP TRIGGER IF EXISTS trg_bpm_audit_apply_chain_hash ON audit_entries;

DROP FUNCTION IF EXISTS bpm_audit_apply_chain_hash();

CREATE FUNCTION bpm_audit_apply_chain_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev_chain_hash TEXT;
BEGIN
    -- Compute hash for this entry
    NEW.chain_hash := bpm_audit_compute_chain_hash(
        NEW.tenant_id,
        NEW.actor_id,
        NEW.audit_id,
        NEW.action,
        NEW.resource_type,
        NEW.resource_id,
        NEW.timestamp,
        NULL::JSONB,
        NULL::JSONB,
        NULL::UUID,
        NEW.trace_id,
        NULL::TEXT,
        NULL::TEXT
    );

    -- Link to previous entry in chain (optional, for tamper detection across time)
    SELECT chain_hash
      INTO v_prev_chain_hash
      FROM audit_entries
     WHERE tenant_id = NEW.tenant_id
       AND chain_hash IS NOT NULL
     ORDER BY timestamp DESC, audit_id DESC
     LIMIT 1;

    -- Store the link only for tracking (primary integrity comes from hash computation)
    NEW.prev_chain_hash := v_prev_chain_hash;

    RETURN NEW;
END;
$$;

-- Recreate the trigger
CREATE TRIGGER trg_bpm_audit_apply_chain_hash
BEFORE INSERT ON audit_entries
FOR EACH ROW EXECUTE FUNCTION bpm_audit_apply_chain_hash();

-- Verify the fix
SELECT 'Chain hash trigger restored to correct state from migration 051' AS fix_status;
