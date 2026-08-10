-- 1142_iss0645_restore_adp10_payload_full_trigger.sql
-- ISS-0645 / GH-649: corrective — restore ADP-10 agent-payload_full
-- auto-population in bpm_audit_apply_chain_hash(), lost when
-- 1107_fix_audit_chain_text_resource_id.sql rewrote the trigger function
-- from scratch for UTF-8 safety.
--
-- Root cause:
--   036_adp10_agent_io_capture_audit.sql and 059_fix_audit_chain_trigger_args.sql
--   both defined bpm_audit_apply_chain_hash() with this block, executed before
--   the chain-hash computation:
--
--     IF NEW.payload_full IS NULL AND bpm_audit_is_agent_actor(NEW.tenant_id, NEW.actor_id) THEN
--         NEW.payload_full := bpm_audit_build_agent_payload_full(...);
--     END IF;
--
--   1107_fix_audit_chain_text_resource_id.sql (ISS-0122 / GH-388) rewrote
--   bpm_audit_apply_chain_hash() from scratch to add UTF-8-safety guarding
--   around NEW.resource_id and wrap the hash computation in its own
--   BEGIN...EXCEPTION block. That rewrite carried forward the pipeline_run_id
--   backfill and the advisory-lock/predecessor-lookup/chain-hash logic, but
--   never re-added the payload_full auto-population block above -- it is
--   absent from both the public-pass copy and the per-tenant-loop copy in
--   1107. Every schema whose trg_bpm_audit_apply_chain_hash trigger has run
--   since 1107 first applied therefore silently stopped populating
--   payload_full for agent actors.
--
--   A second, independent defect compounds the first: 036_adp10_agent_io_
--   capture_audit.sql declared bpm_audit_build_agent_payload_full's 5th
--   parameter as `p_resource_id UUID`. GBL-081/1107 widened
--   audit_entries.resource_id from UUID to TEXT and updated
--   bpm_audit_compute_chain_hash / bpm_audit_chain_canonical_payload to
--   match (see 1141's DROP/CREATE cleanup of those two), but never touched
--   bpm_audit_build_agent_payload_full, which still declares UUID. Restoring
--   the call site above without also fixing this signature would raise
--   42883 'function ... does not exist' the moment NEW.resource_id (now
--   TEXT) is passed in from inside the trigger -- confirmed directly by
--   temporarily instrumenting the trigger body on bpm_gh649_fresh: the
--   error surfaced only from a real trigger firing (NEW.resource_id already
--   TEXT-typed with no available implicit UUID coercion), not from a
--   standalone call using a bare string literal (which Postgres resolves as
--   `unknown` and freely coerces to whichever overload exists).
--
-- Symptom:
--   tests/integration/adp10_agent_io_capture_audit_test.zig TC-ADP-10-02
--   inserts an audit_entries row for an actor whose users.username starts
--   with 'agent:' and asserts payload_full IS NOT NULL. Verified directly
--   against a freshly migrated, workspace-owned database
--   (bpm_gh649_fresh): bpm_audit_is_agent_actor(...) correctly returns true
--   for the fixture actor, but pg_proc.prosrc for the currently active
--   bpm_audit_apply_chain_hash() (the 1107 version) contains no call to
--   bpm_audit_is_agent_actor or bpm_audit_build_agent_payload_full at all,
--   so payload_full is never assigned and stays NULL on every INSERT
--   regardless of actor.
--
-- Fix:
--   1. Re-create bpm_audit_apply_chain_hash() as it currently stands in
--      every schema (1107's UTF-8-safe body, driven by search_path per the
--      standard unqualified/all_schemas convention), with the payload_full
--      auto-population block reinserted before the chain-hash computation
--      -- in the same relative position 036/059 originally used, so
--      agent-actor rows get their I/O-capture payload before the hash
--      pipeline runs (the hash covers payload_full, so order matters:
--      payload_full must be set first, exactly as 059 did).
--   2. Drop the UUID-typed overload of bpm_audit_build_agent_payload_full
--      (with the correct, complete 9-arg signature -- unlike 1107's
--      under-specified DROPs, this one is verified against the actual
--      pg_get_function_identity_arguments() output) and recreate it with
--      p_resource_id TEXT, body otherwise unchanged from 036.
--
-- Non-destructive: only trigger/function bodies change. No table, column,
-- or index changes. Idempotent (CREATE OR REPLACE / DROP IF EXISTS).

-- 1. Drop the stale UUID-typed overload of bpm_audit_build_agent_payload_full
--    and recreate with p_resource_id TEXT (matching audit_entries.resource_id
--    since GBL-081/1107). Body unchanged from 036_adp10_agent_io_capture_audit.sql.
DROP FUNCTION IF EXISTS bpm_audit_build_agent_payload_full(
    UUID, UUID, TEXT, TEXT, UUID, TIMESTAMPTZ, JSONB, JSONB, UUID);

CREATE OR REPLACE FUNCTION bpm_audit_build_agent_payload_full(
    p_tenant_id UUID,
    p_actor_id UUID,
    p_action TEXT,
    p_resource_type TEXT,
    p_resource_id TEXT,
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
    invocation_id := COALESCE(NULLIF(current_setting('bpm.audit_invocation_id', true), ''), lower(p_resource_id));
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
            'resource_id', lower(p_resource_id),
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

-- 2. Restore payload_full auto-population in bpm_audit_apply_chain_hash().
CREATE OR REPLACE FUNCTION bpm_audit_apply_chain_hash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev_hash TEXT;
    v_safe_resource_id TEXT;
    v_chain_hash TEXT;
    v_lock_key BIGINT;
    v_pipeline_run_setting TEXT;
BEGIN
    IF NEW.pipeline_run_id IS NULL THEN
        v_pipeline_run_setting := NULLIF(current_setting('bpm.pipeline_run_id', true), '');
        IF v_pipeline_run_setting IS NOT NULL THEN
            NEW.pipeline_run_id := bpm_audit_try_uuid(v_pipeline_run_setting);
        END IF;
    END IF;

    -- ISS-0645 / GH-649: restored from 036/059 -- populate payload_full for
    -- agent actors BEFORE the chain-hash computation below, since the hash
    -- pipeline covers payload_full and must see the final value.
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

    -- Acquire per-tenant advisory lock so concurrent writers do not fork
    -- the chain. Explicit ::bigint cast avoids SQLSTATE 42P08
    -- 'inconsistent types deduced for parameter $1' under PL/pgSQL when
    -- the parameter-type inference is ambiguous. Wrapped in BEGIN ...
    -- EXCEPTION so a transient lock-acquisition failure never aborts
    -- the audit INSERT.
    BEGIN
        v_lock_key := hashtext('bpm.audit.chain.' || NEW.tenant_id::text)::bigint;
        PERFORM pg_advisory_xact_lock(v_lock_key::bigint);
    EXCEPTION WHEN OTHERS THEN
        RAISE WARNING 'audit_chain_lock_skip: % (audit_id=%s, tenant_id=%s)', SQLERRM, NEW.audit_id, NEW.tenant_id;
    END;

    SELECT chain_hash
      INTO v_prev_hash
      FROM audit_entries
     WHERE tenant_id = NEW.tenant_id
       AND chain_hash IS NOT NULL
     ORDER BY "timestamp" DESC, audit_id DESC
     LIMIT 1;

    NEW.prev_chain_hash := v_prev_hash;

    -- Pre-normalise NEW.resource_id for the hash input only.
    -- If the bytes are not valid UTF-8, use '<invalid-utf8:N>' so the
    -- hash pipeline never sees an encoding-invalid TEXT.
    BEGIN
        PERFORM convert_from(convert_to(NEW.resource_id, 'UTF8'), 'UTF8');
        v_safe_resource_id := NEW.resource_id;
    EXCEPTION WHEN OTHERS THEN
        v_safe_resource_id := '<' || 'invalid-utf8:' || octet_length(NEW.resource_id) || '>';
    END;

    -- Compute the chain hash; never block the audit INSERT.
    BEGIN
        v_chain_hash := bpm_audit_compute_chain_hash(
            NEW.tenant_id, NEW.audit_id, NEW.actor_id, NEW.action,
            NEW.resource_type, v_safe_resource_id, NEW."timestamp",
            NEW.before_state, NEW.after_state, NEW.pipeline_run_id,
            NEW.payload_full, NEW.prev_chain_hash, NEW.trace_id
        );
        NEW.chain_hash := v_chain_hash;
    EXCEPTION WHEN OTHERS THEN
        NEW.chain_hash := NULL;
        NEW.prev_chain_hash := NULL;
        RAISE WARNING 'audit_chain_skip: % (audit_id=%s, tenant_id=%s)', SQLERRM, NEW.audit_id, NEW.tenant_id;
    END;

    RETURN NEW;
END;
$$;
