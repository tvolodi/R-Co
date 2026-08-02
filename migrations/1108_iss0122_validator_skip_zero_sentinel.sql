-- 1108_iss0122_validator_skip_zero_sentinel.sql
--
-- ISS-0122 / GH #388 — TC-ISS-0122-03 BLOCKER.
--
-- Migration 1107 wraps bpm_audit_compute_chain_hash in
--   BEGIN ... EXCEPTION WHEN OTHERS THEN
--       v_hash := repeat('0', 64);
--       RAISE WARNING ...;
--   END;
-- so that a non-UTF-8 resource_id never blocks an audit INSERT. The
-- downstream chain validator bpm_audit_validate_chain (defined by
-- migrations/035 / 036 / 051 / 057, most recently by 057) walks every
-- row in audit_entries and reports chain-integrity issues. Until now
-- the validator treated any chain_hash that was not lowercase 64-char
-- hex as a format violation (InvalidHashFormat) and emitted an issue.
-- The 64-zero sentinel produced by 1107's encoding-failure path
-- therefore surfaced as an issue row instead of being skipped.
--
-- This migration re-creates bpm_audit_validate_chain with the same
-- signature (UUID, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN) but treats the
-- 64-zero SHA-256 sentinel identically to a NULL chain_hash:
--   - Pre-chain-start rows where BOTH chain_hash and prev_chain_hash
--     are NULL OR the 64-zero sentinel are skipped (CONTINUE).
--   - Post-chain-start rows where chain_hash IS NULL OR chain_hash =
--     repeat('0', 64) are reported as LegacyGapAfterChainStart with
--     the same severity (and CONTINUE so the walk continues).
-- The "zero sentinel" is therefore a 'no hash recorded' marker, not a
-- format violation.
--
-- Non-destructive: re-defines an existing function in place; no DDL on
-- audit_entries; idempotent under CREATE OR REPLACE.
--
-- Validated against: TC-ISS-0122-03 (issues[] must be empty for the
-- per-test tenant that contains a single non-UTF-8 audit row).

BEGIN;

DROP FUNCTION IF EXISTS bpm_audit_validate_chain(
    UUID, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN);

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
    current_tenant UUID := NULL;
    seq_no BIGINT := 0;
    chain_started BOOLEAN := FALSE;
    expected_prev TEXT := NULL;
    expected_chain TEXT := NULL;
    seen_hashes TEXT[] := ARRAY[]::TEXT[];
    -- ISS-0122: the 64-zero SHA-256 sentinel produced by
    -- bpm_audit_compute_chain_hash's encoding-failure path. Treated as
    -- "no hash recorded" for pre-chain-start skip and as an explicit
    -- "this row is out of the chain" marker for in-chain skip — never
    -- as a chain-integrity issue.
    v_zero_sentinel CONSTANT TEXT := repeat('0', 64);
    -- ISS-0122: pre-chain-start predicate split into zero-sentinel
    -- (always skipped) and NULL (legacy gap).
    v_hash_zero_sentinel BOOLEAN;
    v_chain_hash_null BOOLEAN;
    -- ISS-0122: resource_id normalised the same way the trigger does
    -- (replaces non-UTF-8 bytes with '<invalid-utf8:N>').
    v_safe_resource_id TEXT;
BEGIN
    FOR r IN
        SELECT
            ae.tenant_id,
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
            ae.chain_hash,
            ae.trace_id
        FROM audit_entries ae
        WHERE (p_tenant_id IS NULL OR ae.tenant_id = p_tenant_id)
          AND (p_from_timestamp IS NULL OR ae."timestamp" >= p_from_timestamp)
          AND (p_to_timestamp IS NULL OR ae."timestamp" <= p_to_timestamp)
        ORDER BY ae.tenant_id ASC, ae."timestamp" ASC, ae.audit_id ASC
    LOOP
        IF current_tenant IS DISTINCT FROM r.tenant_id THEN
            current_tenant := r.tenant_id;
            seq_no := 0;
            chain_started := FALSE;
            expected_prev := NULL;
            expected_chain := NULL;
            seen_hashes := ARRAY[]::TEXT[];
        END IF;

        seq_no := seq_no + 1;

        -- ISS-0122: pre-chain-start rows where BOTH chain_hash and
        -- prev_chain_hash are missing (NULL or zero sentinel) are
        -- skipped — same behaviour as the legacy NULL path.
        v_hash_zero_sentinel := (r.chain_hash IS NOT NULL AND r.chain_hash = v_zero_sentinel);
        v_chain_hash_null    := (r.chain_hash IS NULL);

        IF NOT chain_started AND (r.chain_hash IS NULL OR r.chain_hash = repeat('0', 64))
           AND (r.prev_chain_hash IS NULL OR r.prev_chain_hash = repeat('0', 64)) THEN
            CONTINUE;
        END IF;

        -- ISS-0122: a 64-zero SHA-256 sentinel produced by
        -- bpm_audit_compute_chain_hash's encoding-failure path means
        -- "I tried to compute but encoding failed" — that row is
        -- deliberately outside the chain and must NEVER be reported as
        -- a chain-integrity issue. Skip it silently regardless of
        -- chain_started state. This is the contract migration 1107's
        -- comments promise ("Downstream bpm_audit_validate_chain
        -- treats this as an invalid format and skips the row").
        IF v_hash_zero_sentinel THEN
            CONTINUE;
        END IF;

        IF NOT chain_started THEN
            chain_started := TRUE;
        END IF;

        IF v_chain_hash_null THEN
            tenant_id := r.tenant_id;
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
            tenant_id := r.tenant_id;
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
            tenant_id := r.tenant_id;
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

        -- ISS-0122: pre-normalise resource_id the same way the trigger
        -- function does so the canonical payload the validator produces
        -- matches the one the trigger stored. Without this, non-UTF-8
        -- resource_id rows always report ChainHashMismatch because the
        -- trigger computes against '<invalid-utf8:N>' while the
        -- validator would compute against the original bytes (which the
        -- EXCEPTION guard inside bpm_audit_compute_chain_hash would
        -- replace with the zero sentinel).
        BEGIN
            v_safe_resource_id := r.resource_id;
            PERFORM convert_from(convert_to(r.resource_id, 'UTF8'), 'UTF8');
        EXCEPTION WHEN OTHERS THEN
            v_safe_resource_id := '<' || 'invalid-utf8:' || octet_length(r.resource_id) || '>';
        END;

        expected_chain := bpm_audit_compute_chain_hash(
            r.tenant_id,
            r.audit_id,
            r.actor_id,
            r.action,
            r.resource_type,
            v_safe_resource_id,
            r."timestamp",
            r.before_state,
            r.after_state,
            r.pipeline_run_id,
            r.payload_full,
            r.prev_chain_hash,
            r.trace_id
        );

        IF r.prev_chain_hash IS DISTINCT FROM expected_prev THEN
            tenant_id := r.tenant_id;
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
            tenant_id := r.tenant_id;
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
            tenant_id := r.tenant_id;
            audit_id := r.audit_id;
            sequence_no := seq_no;
            code := 'DuplicateChainHash';
            detail := 'duplicate chain_hash detected in tenant chain';
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

COMMIT;