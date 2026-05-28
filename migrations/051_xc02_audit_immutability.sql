-- 051_xc02_audit_immutability.sql
-- XC-02: Audit immutability with cryptographic chaining.
-- Adds chain_hash and prev_chain_hash columns for tamper detection.
-- Adds tenant_id for multi-tenant isolation.

-- Ensure pgcrypto extension is available for digest/hash functions
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Add tenant_id column (nullable for backward compatibility)
ALTER TABLE audit_entries
    ADD COLUMN IF NOT EXISTS tenant_id UUID NULL;

-- Add chain hash columns for cryptographic chaining
ALTER TABLE audit_entries
    ADD COLUMN IF NOT EXISTS chain_hash TEXT NULL;

ALTER TABLE audit_entries
    ADD COLUMN IF NOT EXISTS prev_chain_hash TEXT NULL;

-- Create index for efficient chain queries (using timestamp instead of created_at)
CREATE INDEX IF NOT EXISTS idx_audit_entries_tenant_chain
    ON audit_entries (tenant_id, "timestamp" DESC, audit_id DESC)
    WHERE tenant_id IS NOT NULL;

-- Function to compute chain hash deterministically using SHA-256
DROP FUNCTION IF EXISTS bpm_audit_compute_chain_hash(UUID,UUID,UUID,TEXT,TEXT,UUID,TIMESTAMPTZ,JSONB,JSONB,UUID,TEXT,TEXT,TEXT);
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

-- Drop the trigger first (it depends on the function)
DROP TRIGGER IF EXISTS trg_bpm_audit_apply_chain_hash ON audit_entries;

-- Function to apply chain hash on INSERT
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

    -- Find previous entry for this tenant
    IF NEW.tenant_id IS NOT NULL THEN
        SELECT chain_hash INTO v_prev_chain_hash
        FROM audit_entries
        WHERE tenant_id = NEW.tenant_id
        AND (timestamp < NEW.timestamp OR (timestamp = NEW.timestamp AND audit_id < NEW.audit_id))
        ORDER BY timestamp DESC, audit_id DESC
        LIMIT 1;

        NEW.prev_chain_hash := v_prev_chain_hash;
    END IF;

    RETURN NEW;
END;
$$;

-- Recreate the trigger for chain hashing
CREATE TRIGGER trg_bpm_audit_apply_chain_hash
BEFORE INSERT ON audit_entries
FOR EACH ROW EXECUTE FUNCTION bpm_audit_apply_chain_hash();

-- Function to validate an audit chain for tampering
DROP FUNCTION IF EXISTS bpm_audit_validate_chain(UUID);
CREATE FUNCTION bpm_audit_validate_chain(p_tenant_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev_hash_expected TEXT;
    v_issues JSONB := '[]'::JSONB;
    v_first_entry BOOLEAN := TRUE;
    v_entry RECORD;
BEGIN
    -- Iterate through all entries for this tenant in order
    FOR v_entry IN
        SELECT audit_id, chain_hash, prev_chain_hash, timestamp
        FROM audit_entries
        WHERE tenant_id = p_tenant_id
        ORDER BY timestamp ASC, audit_id ASC
    LOOP
        -- First entry should have NULL prev_chain_hash
        IF v_first_entry THEN
            IF v_entry.prev_chain_hash IS NOT NULL THEN
                v_issues := v_issues || jsonb_build_array(
                    jsonb_build_object(
                        'audit_id', v_entry.audit_id::TEXT,
                        'issue', 'First entry has non-NULL prev_chain_hash'
                    )
                );
            END IF;
            v_first_entry := FALSE;
        ELSE
            -- Verify that prev_chain_hash matches the previous entry's chain_hash
            IF v_entry.prev_chain_hash <> v_prev_hash_expected THEN
                v_issues := v_issues || jsonb_build_array(
                    jsonb_build_object(
                        'audit_id', v_entry.audit_id::TEXT,
                        'issue', 'prev_chain_hash mismatch',
                        'expected', v_prev_hash_expected,
                        'actual', COALESCE(v_entry.prev_chain_hash, 'NULL')
                    )
                );
            END IF;
        END IF;

        -- Remember this entry's hash for the next iteration
        v_prev_hash_expected := v_entry.chain_hash;
    END LOOP;

    RETURN jsonb_build_object('tenant_id', p_tenant_id::TEXT, 'issues', v_issues);
END;
$$;
