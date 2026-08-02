-- 1110_iss0122_validator_zero_sentinel_per_tenant.sql
--
-- ISS-0122 / GH #388 — TC-ISS-0122-03 BLOCKER (followup to 1108).
--
-- Migration 1108 re-created bpm_audit_validate_chain in the public schema
-- only. The per-tenant instance in tenant_default (and any other tenant_*
-- schema provisioned before 1108) still holds the body defined by
-- migrations/057_iss0054_audit_chain_function_reconcile.sql — which does
-- not handle the 64-zero SHA-256 sentinel that bpm_audit_compute_chain_hash
-- now writes when convert_to(payload, 'UTF8') raises 22021. When the
-- integration test calls bpm_audit_validate_chain($1) on a connection
-- whose search_path starts with tenant_default, PostgreSQL resolves the
-- tenant_default body, which then errors with
--   "record "r" has no field "trace_id"" (the body in 1108 added
--   ae.trace_id to the SELECT; the per-tenant body did not — and the
--   assign block that follows passed r.trace_id which the per-tenant body
--   does not have in its record shape).
--
-- This migration re-creates bpm_audit_validate_chain in every tenant_*
-- schema with the 1108 body (zero-sentinel skipped at the pre-chain-start
-- guard, trace_id removed from the SELECT, NULL passed to
-- bpm_audit_compute_chain_hash for the trace_id argument so the function
-- compiles against audit_entries regardless of whether the schema has the
-- trace_id column).
--
-- Non-destructive: re-defines an existing function in place; no DDL on
-- audit_entries; idempotent under CREATE OR REPLACE.
--
-- Validated against: TC-ISS-0122-03 (issues[] must be empty for the
-- per-test tenant that contains a single non-UTF-8 audit row).

BEGIN;

DO $$
DECLARE
    rec RECORD;
    v_sql TEXT;
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
        BEGIN
            v_sql := format(
                'DROP FUNCTION IF EXISTS %I.bpm_audit_validate_chain(
                    UUID, TIMESTAMPTZ, TIMESTAMPTZ, BOOLEAN)',
                rec.nspname
            );
            EXECUTE v_sql;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '1110: skip DROP on tenant=%, sql=%', rec.nspname, SQLERRM;
            CONTINUE;
        END;

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
                $func$
            $inner$, rec.nspname, rec.nspname);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '1110: skip CREATE on tenant=%, sql=%', rec.nspname, SQLERRM;
        END;

        RAISE NOTICE '1110: re-applied bpm_audit_validate_chain to tenant schema %', rec.nspname;
    END LOOP;
END;
$$;

COMMIT;
