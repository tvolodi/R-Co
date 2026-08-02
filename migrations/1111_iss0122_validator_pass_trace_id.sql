-- 1111_iss0122_validator_pass_trace_id.sql
--
-- ISS-0122 / GH #388 — TC-ISS-0122-03 BLOCKER (followup to 1110).
--
-- Migration 1110 re-created bpm_audit_validate_chain in every tenant_*
-- schema with the 1108 body. To keep the function compiling against the
-- audit_entries shape at the time, the inner call to
-- bpm_audit_compute_chain_hash hard-coded the trace_id argument to NULL:
--
--   expected_chain := %I.bpm_audit_compute_chain_hash(
--       r.tenant_id, r.audit_id, r.actor_id, r.action,
--       r.resource_type, v_safe_resource_id, r."timestamp",
--       r.before_state, r.after_state, r.pipeline_run_id,
--       r.payload_full, r.prev_chain_hash,
--       NULL                                          -- was: NULL
--   );
--
-- This is wrong. The trigger function bpm_audit_apply_chain_hash (defined
-- in 1107 and re-applied in 1109) computes the stored chain_hash against
-- the actual NEW.trace_id — the canonical payload embeds the trace-id
-- literal, so a NULL-passing validator diverges from the trigger's hash
-- and TC-03 reports (1 PrevHashMismatch, 2 ChainHashMismatch) on every
-- per-tenant validator body.
--
-- The public-schema validator (migration 1108) already passes r.trace_id
-- correctly; this migration only re-creates the per-tenant bodies.
--
-- The function signature, the RETURNS TABLE column list, the zero-sentinel
-- skip, the chain-start guard, the duplicate detection, the prev-hash
-- continuity check, and the p_stop_on_first_error short-circuit are
-- preserved byte-for-byte from 1110. The only behavioural change is the
-- trace_id argument to the inner compute call.
--
-- Non-destructive: CREATE OR REPLACE FUNCTION preserves the function OID,
-- so no callers, views, triggers, or tests need to be rebound. The
-- per-tenant loop wraps each CREATE OR REPLACE in BEGIN ... EXCEPTION
-- WHEN OTHERS so a single malformed tenant schema cannot abort the loop.
--
-- Validated against: TC-ISS-0122-03 (issues[] must be empty for the
-- per-test tenant that contains a single non-UTF-8 audit row).

BEGIN;

DO $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT nspname
          FROM pg_namespace
         WHERE nspname LIKE 'tenant_%'
           AND nspname NOT IN ('public', 'information_schema')
           AND nspname NOT LIKE 'pg_%'
           AND nspname NOT LIKE 'pgtoast%'
           AND nspname NOT LIKE 'pg_temp%'
         ORDER BY nspname
    LOOP
        RAISE NOTICE '1111: re-applying bpm_audit_validate_chain (trace_id) to tenant schema %', rec.nspname;
        BEGIN
            EXECUTE format($inner$
                CREATE OR REPLACE FUNCTION %I.bpm_audit_validate_chain(
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
                AS $func$
                DECLARE
                    r RECORD;
                    current_tenant UUID := NULL;
                    seq_no BIGINT := 0;
                    chain_started BOOLEAN := FALSE;
                    expected_prev TEXT := NULL;
                    expected_chain TEXT := NULL;
                    seen_hashes TEXT[] := ARRAY[]::TEXT[];
                    v_zero_sentinel CONSTANT TEXT := repeat('0', 64);
                    v_hash_zero_sentinel BOOLEAN;
                    v_chain_hash_null BOOLEAN;
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

                        v_hash_zero_sentinel := (r.chain_hash IS NOT NULL AND r.chain_hash = v_zero_sentinel);
                        v_chain_hash_null    := (r.chain_hash IS NULL);

                        IF NOT chain_started AND (r.chain_hash IS NULL OR r.chain_hash = repeat('0', 64))
                           AND (r.prev_chain_hash IS NULL OR r.prev_chain_hash = repeat('0', 64)) THEN
                            CONTINUE;
                        END IF;

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

                        BEGIN
                            v_safe_resource_id := r.resource_id;
                            PERFORM convert_from(convert_to(r.resource_id, 'UTF8'), 'UTF8');
                        EXCEPTION WHEN OTHERS THEN
                            v_safe_resource_id := '<' || 'invalid-utf8:' || octet_length(r.resource_id) || '>';
                        END;

                        -- ISS-0122 (1111): pass r.trace_id (matches the
                        -- trigger's NEW.trace_id). Was hard-coded NULL in 1110.
                        expected_chain := %I.bpm_audit_compute_chain_hash(
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
                $func$
            $inner$, rec.nspname, rec.nspname);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '1111: skip CREATE on tenant=%, sql=%', rec.nspname, SQLERRM;
        END;

        RAISE NOTICE '1111: re-applied bpm_audit_validate_chain (trace_id) to tenant schema %', rec.nspname;
    END LOOP;
END;
$$;

COMMIT;
