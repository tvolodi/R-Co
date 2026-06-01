-- 057_iss0054_audit_chain_function_reconcile.sql
-- Reconcile XC-02 legacy audit-chain functions with ADP-09/ADP-10 semantics.

-- Remove legacy XC-02 overloads introduced after ADP-09/ADP-10.
DROP FUNCTION IF EXISTS bpm_audit_compute_chain_hash(UUID, UUID, UUID, TEXT, TEXT, UUID, TIMESTAMPTZ, JSONB, JSONB, UUID, TEXT, TEXT, TEXT);
DROP FUNCTION IF EXISTS bpm_audit_validate_chain(UUID);

-- Restore ADP-10-aware chain trigger behavior.
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
        NEW.audit_id,
        NEW.actor_id,
        NEW.action,
        NEW.resource_type,
        NEW.resource_id,
        NEW."timestamp",
        NEW.before_state,
        NEW.after_state,
        NEW.pipeline_run_id,
        NULL,
        NEW.prev_chain_hash,
        NULL
    );

    RETURN NEW;
END;
$$;

-- Keep the ADP-09/ADP-10 validation surface as a single canonical function signature.
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
            ae.chain_hash
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

        IF NOT chain_started AND r.chain_hash IS NULL AND r.prev_chain_hash IS NULL THEN
            CONTINUE;
        END IF;

        IF NOT chain_started THEN
            chain_started := TRUE;
        END IF;

        IF r.chain_hash IS NULL THEN
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

        expected_chain := bpm_audit_compute_chain_hash(
            r.tenant_id,
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
