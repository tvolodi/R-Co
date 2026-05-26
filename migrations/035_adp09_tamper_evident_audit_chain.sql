-- 035_adp09_tamper_evident_audit_chain.sql
-- Stage 6.5: ADP-09 -- additive tamper-evident audit chaining.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

ALTER TABLE audit_entries
    ADD COLUMN IF NOT EXISTS chain_hash TEXT NULL,
    ADD COLUMN IF NOT EXISTS prev_chain_hash TEXT NULL;

CREATE INDEX IF NOT EXISTS idx_audit_entries_tenant_chain_lookup
    ON audit_entries (tenant_id, "timestamp" DESC, audit_id DESC)
    WHERE chain_hash IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_audit_entries_tenant_chain_hash
    ON audit_entries (tenant_id, chain_hash)
    WHERE chain_hash IS NOT NULL;

CREATE OR REPLACE FUNCTION bpm_audit_hash_format_valid(hash_value TEXT)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT hash_value ~ '^[0-9a-f]{64}$';
$$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'chk_audit_entries_chain_hash_format'
          AND conrelid = 'audit_entries'::regclass
    ) THEN
        ALTER TABLE audit_entries
            ADD CONSTRAINT chk_audit_entries_chain_hash_format
            CHECK (chain_hash IS NULL OR bpm_audit_hash_format_valid(chain_hash));
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'chk_audit_entries_prev_chain_hash_format'
          AND conrelid = 'audit_entries'::regclass
    ) THEN
        ALTER TABLE audit_entries
            ADD CONSTRAINT chk_audit_entries_prev_chain_hash_format
            CHECK (prev_chain_hash IS NULL OR bpm_audit_hash_format_valid(prev_chain_hash));
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION bpm_audit_chain_canonical_payload(
    p_tenant_id UUID,
    p_audit_id UUID,
    p_actor_id UUID,
    p_action TEXT,
    p_resource_type TEXT,
    p_resource_id UUID,
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
        'resource_id=' || lower(p_resource_id::text),
        'trace_id=' || COALESCE(p_trace_id, '~'),
        'created_at_us=' || ((EXTRACT(EPOCH FROM p_timestamp) * 1000000)::bigint)::text,
        'before_state=' || COALESCE(p_before_state::text, '~'),
        'after_state=' || COALESCE(p_after_state::text, '~'),
        'pipeline_run_id=' || COALESCE(lower(p_pipeline_run_id::text), '~'),
        'payload_full=' || COALESCE(p_payload_full::text, '~'),
        'prev_chain_hash=' || COALESCE(lower(p_prev_chain_hash), '~')
    );
$$;

CREATE OR REPLACE FUNCTION bpm_audit_compute_chain_hash(
    p_tenant_id UUID,
    p_audit_id UUID,
    p_actor_id UUID,
    p_action TEXT,
    p_resource_type TEXT,
    p_resource_id UUID,
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
                'UTF8'
            ),
            'sha256'
        ),
        'hex'
    );
$$;

CREATE OR REPLACE FUNCTION bpm_audit_apply_chain_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    predecessor_hash TEXT;
BEGIN
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

DROP TRIGGER IF EXISTS trg_bpm_audit_apply_chain_hash ON audit_entries;
CREATE TRIGGER trg_bpm_audit_apply_chain_hash
BEFORE INSERT ON audit_entries
FOR EACH ROW EXECUTE FUNCTION bpm_audit_apply_chain_hash();

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
            NULL,
            r.prev_chain_hash,
            NULL
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
