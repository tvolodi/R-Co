-- Migration 067: SPT-04 — fix bpm_audit_validate_chain after tenant_id removal.
--
-- Migration 062 dropped audit_entries.tenant_id.  The bpm_audit_validate_chain
-- function defined in migration 057 still references ae.tenant_id in its SELECT
-- and in calls to bpm_audit_compute_chain_hash, causing every call to fail with
-- "column tenant_id does not exist" after migration 062.
--
-- Migration 064 updated bpm_audit_apply_chain_hash to pass NULL for tenant_id.
-- This migration applies the same treatment to bpm_audit_validate_chain:
--   • Remove the WHERE ae.tenant_id filter (column no longer exists).
--   • Replace ae.tenant_id column references with NULL::uuid throughout.
--   • Remove per-tenant chain-boundary reset logic; chain is now global.
--   • Order by timestamp, audit_id (no tenant_id sort key).
--   • Keep the p_tenant_id parameter for backward API compatibility but ignore it.
--
-- All operations are idempotent (CREATE OR REPLACE).

CREATE OR REPLACE FUNCTION bpm_audit_validate_chain(
    p_tenant_id UUID DEFAULT NULL,
    p_from_timestamp TIMESTAMPTZ DEFAULT NULL,
    p_to_timestamp TIMESTAMPTZ DEFAULT NULL,
    p_stop_on_first_error BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    tenant_id UUID,
    audit_id UUID,
    sequence_no BIGINT,
    code TEXT,
    detail TEXT,
    expected_prev_chain_hash TEXT,
    observed_prev_chain_hash TEXT,
    expected_chain_hash TEXT,
    observed_chain_hash TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    r RECORD;
    seq_no BIGINT := 0;
    chain_started BOOLEAN := FALSE;
    expected_prev TEXT := NULL;
    expected_chain TEXT := NULL;
    seen_hashes TEXT[] := ARRAY[]::TEXT[];
BEGIN
    -- tenant_id was dropped from audit_entries by migration 062.
    -- Chain is now global (all entries in one sequence).
    -- p_tenant_id is kept for API backward compatibility but is not used to filter.
    FOR r IN
        SELECT
            ae.audit_id,
            ae.actor_id,
            ae.action,
            ae.resource_type,
            ae.resource_id,
            ae."timestamp",
            ae.before_state,
            ae.after_state,
            ae.pipeline_run_id,
            ae.payload_full,
            ae.prev_chain_hash,
            ae.chain_hash
        FROM audit_entries ae
        WHERE (p_from_timestamp IS NULL OR ae."timestamp" >= p_from_timestamp)
          AND (p_to_timestamp   IS NULL OR ae."timestamp" <= p_to_timestamp)
        ORDER BY ae."timestamp" ASC, ae.audit_id ASC
    LOOP
        seq_no := seq_no + 1;

        IF NOT chain_started AND r.chain_hash IS NULL AND r.prev_chain_hash IS NULL THEN
            CONTINUE;
        END IF;

        IF NOT chain_started THEN
            chain_started := TRUE;
        END IF;

        IF r.chain_hash IS NULL THEN
            tenant_id := NULL;
            audit_id := r.audit_id;
            sequence_no := seq_no;
            code := 'LegacyGapAfterChainStart';
            detail := 'Encountered NULL chain_hash after chained segment started';
            expected_prev_chain_hash := expected_prev;
            observed_prev_chain_hash := r.prev_chain_hash;
            expected_chain_hash := NULL;
            observed_chain_hash := NULL;
            RETURN NEXT;
            IF p_stop_on_first_error THEN
                RETURN;
            END IF;
            CONTINUE;
        END IF;

        IF r.prev_chain_hash IS NOT NULL AND NOT bpm_audit_hash_format_valid(r.prev_chain_hash) THEN
            tenant_id := NULL;
            audit_id := r.audit_id;
            sequence_no := seq_no;
            code := 'InvalidHashFormat';
            detail := 'prev_chain_hash is not lowercase 64-char hex';
            expected_prev_chain_hash := expected_prev;
            observed_prev_chain_hash := r.prev_chain_hash;
            expected_chain_hash := NULL;
            observed_chain_hash := r.chain_hash;
            RETURN NEXT;
            IF p_stop_on_first_error THEN
                RETURN;
            END IF;
        END IF;

        IF NOT bpm_audit_hash_format_valid(r.chain_hash) THEN
            tenant_id := NULL;
            audit_id := r.audit_id;
            sequence_no := seq_no;
            code := 'InvalidHashFormat';
            detail := 'chain_hash is not lowercase 64-char hex';
            expected_prev_chain_hash := expected_prev;
            observed_prev_chain_hash := r.prev_chain_hash;
            expected_chain_hash := NULL;
            observed_chain_hash := r.chain_hash;
            RETURN NEXT;
            IF p_stop_on_first_error THEN
                RETURN;
            END IF;
            expected_prev := NULL;
            CONTINUE;
        END IF;

        -- tenant_id removed from audit_entries; pass NULL to the hash function.
        expected_chain := bpm_audit_compute_chain_hash(
            NULL,
            r.audit_id,
            r.actor_id,
            r.action,
            r.resource_type,
            r.resource_id,
            r."timestamp",
            r.before_state,
            r.after_state,
            r.pipeline_run_id,
            r.payload_full,
            r.prev_chain_hash,
            NULL
        );

        IF r.prev_chain_hash IS DISTINCT FROM expected_prev THEN
            tenant_id := NULL;
            audit_id := r.audit_id;
            sequence_no := seq_no;
            code := 'PrevHashMismatch';
            detail := 'prev_chain_hash does not match prior expected chain hash';
            expected_prev_chain_hash := expected_prev;
            observed_prev_chain_hash := r.prev_chain_hash;
            expected_chain_hash := expected_chain;
            observed_chain_hash := r.chain_hash;
            RETURN NEXT;
            IF p_stop_on_first_error THEN
                RETURN;
            END IF;
        END IF;

        IF r.chain_hash IS DISTINCT FROM expected_chain THEN
            tenant_id := NULL;
            audit_id := r.audit_id;
            sequence_no := seq_no;
            code := 'ChainHashMismatch';
            detail := 'chain_hash mismatch for canonicalized row content';
            expected_prev_chain_hash := expected_prev;
            observed_prev_chain_hash := r.prev_chain_hash;
            expected_chain_hash := expected_chain;
            observed_chain_hash := r.chain_hash;
            RETURN NEXT;
            IF p_stop_on_first_error THEN
                RETURN;
            END IF;
        END IF;

        IF r.chain_hash = ANY(seen_hashes) THEN
            tenant_id := NULL;
            audit_id := r.audit_id;
            sequence_no := seq_no;
            code := 'DuplicateChainHash';
            detail := 'duplicate chain_hash detected in global chain';
            expected_prev_chain_hash := expected_prev;
            observed_prev_chain_hash := r.prev_chain_hash;
            expected_chain_hash := expected_chain;
            observed_chain_hash := r.chain_hash;
            RETURN NEXT;
            IF p_stop_on_first_error THEN
                RETURN;
            END IF;
        END IF;

        seen_hashes := array_append(seen_hashes, r.chain_hash);

        IF r.prev_chain_hash IS DISTINCT FROM expected_prev OR r.chain_hash IS DISTINCT FROM expected_chain THEN
            expected_prev := expected_chain;
        ELSE
            expected_prev := r.chain_hash;
        END IF;
    END LOOP;

    RETURN;
END;
$$;
