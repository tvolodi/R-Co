-- 036_adp10_agent_io_capture_audit.sql
-- Stage 6.5: ADP-10 -- additive agent I/O capture in audit entries.

ALTER TABLE audit_entries
    ADD COLUMN IF NOT EXISTS payload_full JSONB NULL;

CREATE INDEX IF NOT EXISTS idx_audit_entries_payload_full_gin
    ON audit_entries
    USING GIN (payload_full)
    WHERE payload_full IS NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'chk_audit_entries_payload_full_object'
          AND conrelid = 'audit_entries'::regclass
    ) THEN
        ALTER TABLE audit_entries
            ADD CONSTRAINT chk_audit_entries_payload_full_object
            CHECK (payload_full IS NULL OR jsonb_typeof(payload_full) = 'object');
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION bpm_audit_safe_bool(input TEXT, fallback_value BOOLEAN)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF input IS NULL OR btrim(input) = '' THEN
        RETURN fallback_value;
    END IF;
    RETURN lower(btrim(input)) IN ('1', 'true', 't', 'yes', 'y', 'on');
EXCEPTION WHEN OTHERS THEN
    RETURN fallback_value;
END;
$$;

CREATE OR REPLACE FUNCTION bpm_audit_safe_int(input TEXT, fallback_value INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    parsed INTEGER;
BEGIN
    IF input IS NULL OR btrim(input) = '' THEN
        RETURN fallback_value;
    END IF;
    parsed := input::INTEGER;
    IF parsed < 1 THEN
        RETURN fallback_value;
    END IF;
    RETURN parsed;
EXCEPTION WHEN OTHERS THEN
    RETURN fallback_value;
END;
$$;

CREATE OR REPLACE FUNCTION bpm_audit_parse_jsonb(input TEXT)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF input IS NULL OR btrim(input) = '' THEN
        RETURN NULL;
    END IF;
    RETURN input::JSONB;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$;

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
        SELECT u.username
          INTO stored_username
          FROM users u
         WHERE u.id = p_actor_id
           AND u.tenant_id = p_tenant_id
         LIMIT 1;
    EXCEPTION WHEN undefined_table THEN
        stored_username := NULL;
    END;

    IF stored_username IS NULL THEN
        RETURN FALSE;
    END IF;

    RETURN lower(stored_username) LIKE 'agent:%';
END;
$$;

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
            SELECT u.username
              INTO actor_username
              FROM users u
             WHERE u.id = p_actor_id
               AND u.tenant_id = p_tenant_id
             LIMIT 1;
        EXCEPTION WHEN undefined_table THEN
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

    IF allow_raw_messages THEN
        llm_payload := COALESCE(
            raw_payload->'llm_messages',
            jsonb_build_object(
                'included', FALSE,
                'reason', 'allow',
                'messages', NULL
            )
        );
    ELSE
        llm_payload := jsonb_build_object(
            'included', FALSE,
            'reason', 'denied_by_policy',
            'messages', NULL
        );
        IF capture_mode = 'full' THEN
            capture_mode := 'metadata_only';
        END IF;
    END IF;

    IF jsonb_typeof(llm_payload) <> 'object' THEN
        llm_payload := jsonb_build_object(
            'included', FALSE,
            'reason', CASE WHEN allow_raw_messages THEN 'allow' ELSE 'denied_by_policy' END,
            'messages', NULL
        );
    END IF;

    redaction_rules := bpm_audit_parse_jsonb(NULLIF(current_setting('bpm.audit_payload_redaction_rules', true), ''));
    IF redaction_rules IS NULL OR jsonb_typeof(redaction_rules) <> 'array' THEN
        redaction_rules := '[]'::JSONB;
    END IF;

    payload := jsonb_build_object(
        'schema_version', 'adp10.v1',
        'capture_mode', capture_mode,
        'agent', jsonb_build_object(
            'actor_id', lower(p_actor_id::TEXT),
            'username', actor_username,
            'role_set', role_set
        ),
        'invocation', jsonb_build_object(
            'invocation_id', invocation_id,
            'pipeline_run_id', CASE WHEN p_pipeline_run_id IS NULL THEN NULL ELSE lower(p_pipeline_run_id::TEXT) END,
            'trace_id', trace_id,
            'action', COALESCE(p_action, '~'),
            'resource_type', COALESCE(p_resource_type, '~'),
            'resource_id', lower(p_resource_id::TEXT),
            'started_at_unix_us', (EXTRACT(EPOCH FROM p_timestamp) * 1000000)::BIGINT,
            'completed_at_unix_us', (EXTRACT(EPOCH FROM p_timestamp) * 1000000)::BIGINT,
            'outcome', 'success'
        ),
        'input', input_payload,
        'output', output_payload,
        'tool_calls', tool_calls_payload,
        'llm_messages', llm_payload,
        'redaction', jsonb_build_object(
            'policy_id', policy_id,
            'redaction_applied', NOT allow_raw_messages,
            'redaction_rules', redaction_rules
        ),
        'limits', jsonb_build_object(
            'max_bytes', max_bytes,
            'observed_bytes', 0,
            'truncated', FALSE
        )
    );

    observed_bytes := octet_length(payload::TEXT);
    IF observed_bytes > max_bytes THEN
        was_truncated := TRUE;
        payload := jsonb_set(payload, '{llm_messages,messages}', 'null'::JSONB, TRUE);
        payload := jsonb_set(payload, '{llm_messages,reason}', '"truncated"'::JSONB, TRUE);
        observed_bytes := octet_length(payload::TEXT);
    END IF;
    IF observed_bytes > max_bytes THEN
        payload := jsonb_set(payload, '{tool_calls}', '[]'::JSONB, TRUE);
        observed_bytes := octet_length(payload::TEXT);
    END IF;
    IF observed_bytes > max_bytes THEN
        payload := jsonb_set(payload, '{output}', 'null'::JSONB, TRUE);
        observed_bytes := octet_length(payload::TEXT);
    END IF;
    IF observed_bytes > max_bytes THEN
        payload := jsonb_set(payload, '{input}', '{}'::JSONB, TRUE);
        observed_bytes := octet_length(payload::TEXT);
    END IF;

    payload := jsonb_set(payload, '{limits,max_bytes}', to_jsonb(max_bytes), TRUE);
    payload := jsonb_set(payload, '{limits,observed_bytes}', to_jsonb(observed_bytes), TRUE);
    payload := jsonb_set(payload, '{limits,truncated}', to_jsonb(was_truncated), TRUE);

    RETURN payload;
END;
$$;

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
        NEW.payload_full,
        NEW.prev_chain_hash,
        NULL
    );

    RETURN NEW;
END;
$$;

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
