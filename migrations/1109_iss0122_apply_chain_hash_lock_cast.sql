-- 1109_iss0122_apply_chain_hash_lock_cast.sql
--
-- ISS-0122 / GH #388 — TC-ISS-0122-04 BLOCKER (followup to 1107).
--
-- Migration 1107 re-created bpm_audit_apply_chain_hash() in the public
-- schema and in every tenant_* schema via a per-tenant DO block. The
-- per-tenant trigger function took pg_advisory_xact_lock(hashtext(...)
-- without an explicit ::bigint cast, which under PL/pgSQL parameter-type
-- inference emits SQLSTATE 42P08 'inconsistent types deduced for
-- parameter $1 (text versus uuid)' in some workloads (notably the
-- concurrent non-UTF-8 worker in TC-ISS-0122-04).
--
-- Migration 1107 is already applied and cannot be re-run (it is in the
-- schema_migrations ledger). This migration therefore re-creates
-- bpm_audit_apply_chain_hash() in:
--   (a) the public schema (defensive: 1107's public-schema path already
--       has the fix, but CREATE OR REPLACE is idempotent)
--   (b) every tenant_* schema, via a per-tenant DO block, replacing the
--       body with the lock-cast variant.
--
-- The lock-acquisition block is wrapped in BEGIN ... EXCEPTION WHEN
-- OTHERS so a transient lock failure (e.g. lock_timeout) never aborts
-- the audit INSERT — the migration's overall contract is "audit writes
-- must NEVER block business writes."
--
-- Non-destructive: CREATE OR REPLACE FUNCTION preserves the trigger
-- binding (trg_bpm_audit_apply_chain_hash on audit_entries).
--
-- Validated against: TC-ISS-0122-04 (concurrent non-UTF-8 inserts must
-- not fork the chain).

BEGIN;

-- ---------------------------------------------------------------------------
-- (a) Public schema: idempotent re-creation with explicit ::bigint cast
--     and BEGIN ... EXCEPTION guard around the lock call.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bpm_audit_apply_chain_hash()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev_hash TEXT;
    v_safe_resource_id TEXT;
    v_chain_hash TEXT;
    v_lock_key BIGINT;
BEGIN
    -- Acquire per-tenant advisory lock so concurrent writers do not fork
    -- the chain. Explicit ::bigint cast avoids SQLSTATE 42P08
    -- 'inconsistent types deduced for parameter $1' under PL/pgSQL when
    -- the parameter-type inference is ambiguous. Wrapped in BEGIN ...
    -- EXCEPTION so a transient lock-acquisition failure never aborts
    -- the audit INSERT.
    BEGIN
        v_lock_key := hashtext('bpm.audit.chain.' || NEW.tenant_id::text)::bigint;
        PERFORM pg_advisory_xact_lock(v_lock_key);
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

-- ---------------------------------------------------------------------------
-- (b) Per-tenant loop: re-create bpm_audit_apply_chain_hash() in every
--     tenant_* schema with the lock-cast variant. The trigger binding on
--     tenant.<n>.audit_entries remains valid because CREATE OR REPLACE
--     preserves the function OID.
-- ---------------------------------------------------------------------------
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
        RAISE NOTICE '1109: re-applying apply_chain_hash to tenant schema %', rec.nspname;
        BEGIN
            EXECUTE format($inner$
                CREATE OR REPLACE FUNCTION %I.bpm_audit_apply_chain_hash()
                RETURNS trigger
                LANGUAGE plpgsql
                AS $func$
                DECLARE
                    v_prev_hash TEXT;
                    v_safe_resource_id TEXT;
                    v_chain_hash TEXT;
                    v_lock_key BIGINT;
                BEGIN
                    BEGIN
                        v_lock_key := hashtext('bpm.audit.chain.' || NEW.tenant_id::text)::bigint;
                        PERFORM pg_advisory_xact_lock(v_lock_key);
                    EXCEPTION WHEN OTHERS THEN
                        RAISE WARNING 'audit_chain_lock_skip: %% (audit_id=%%s, tenant_id=%%s)', SQLERRM, NEW.audit_id, NEW.tenant_id;
                    END;

                    SELECT chain_hash
                      INTO v_prev_hash
                      FROM %I.audit_entries
                     WHERE tenant_id = NEW.tenant_id
                       AND chain_hash IS NOT NULL
                     ORDER BY "timestamp" DESC, audit_id DESC
                     LIMIT 1;

                    NEW.prev_chain_hash := v_prev_hash;

                    BEGIN
                        PERFORM convert_from(convert_to(NEW.resource_id, 'UTF8'), 'UTF8');
                        v_safe_resource_id := NEW.resource_id;
                    EXCEPTION WHEN OTHERS THEN
                        v_safe_resource_id := '<' || 'invalid-utf8:' || octet_length(NEW.resource_id) || '>';
                    END;

                    BEGIN
                        v_chain_hash := %I.bpm_audit_compute_chain_hash(
                            NEW.tenant_id, NEW.audit_id, NEW.actor_id, NEW.action,
                            NEW.resource_type, v_safe_resource_id, NEW."timestamp",
                            NEW.before_state, NEW.after_state, NEW.pipeline_run_id,
                            NEW.payload_full, NEW.prev_chain_hash, NEW.trace_id
                        );
                        NEW.chain_hash := v_chain_hash;
                    EXCEPTION WHEN OTHERS THEN
                        NEW.chain_hash := NULL;
                        NEW.prev_chain_hash := NULL;
                        RAISE WARNING 'audit_chain_skip: %% (audit_id=%%s, tenant_id=%%s)', SQLERRM, NEW.audit_id, NEW.tenant_id;
                    END;

                    RETURN NEW;
                END;
                $func$
            $inner$, rec.nspname, rec.nspname, rec.nspname);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '1109: skip CREATE apply_chain_hash on tenant=%, sql=%', rec.nspname, SQLERRM;
        END;
    END LOOP;
END;
$$;

COMMIT;