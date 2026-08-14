-- 1107_fix_audit_chain_text_resource_id.sql
--
-- ISS-0122 / GH #388 — 85 occurrences of C22021 'invalid byte 0xaa' at $1.
--
-- Root cause: bpm_audit_chain_canonical_payload / bpm_audit_compute_chain_hash
-- still declare p_resource_id TEXT (after GBL-081/GBL-082), but the
-- BEFORE INSERT trigger bpm_audit_apply_chain_hash does not validate UTF-8
-- on NEW.resource_id before calling the hash pipeline, and does not guard
-- the chain-hash pipeline against SQLSTATE 22021 / 22023 / etc.
--
-- Audit writes must NEVER block business writes. This migration:
--   (1) Drops the UUID- and TEXT-overloads of the two chain-hash SQL functions
--       so CREATE OR REPLACE FUNCTION can resolve the new signature cleanly.
--   (2) Re-creates bpm_audit_chain_canonical_payload with TEXT resource_id,
--       preserving the 035 column shape EXCEPT no `lower(p_resource_id::text)`
--       (resource_id is already TEXT and may carry non-UTF-8 bytes).
--   (3) Re-creates bpm_audit_compute_chain_hash with a UTF-8 EXCEPTION guard
--       that returns a zero-hash sentinel on encoding failure.
--   (4) Re-creates bpm_audit_apply_chain_hash() trigger function so the
--       predecessor-lookup + hash call + NEW assignment block is wrapped in
--       BEGIN ... EXCEPTION WHEN OTHERS THEN RAISE WARNING ... RETURN NEW; END;
--       and the input NEW.resource_id is pre-normalised to '<invalid-utf8:N>'
--       for the hash input only (NEW.resource_id column value is preserved
--       as-is so an auditor can still see the original bytes).
--   (5) Re-creates the BEFORE INSERT trigger trg_bpm_audit_apply_chain_hash
--       on audit_entries. The trigger drop+create is guarded by
--       to_regclass('audit_entries') so the migration is a no-op against
--       the public schema (where audit_entries has not existed since GBL-073)
--       and only fires per-tenant where audit_entries lives.
--
-- Non-destructive: no DROP TABLE / DROP COLUMN / TRUNCATE.
-- Idempotent on a long-lived bpm_test database (DROP ... IF EXISTS guarded).

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Drop both overloads of bpm_audit_chain_canonical_payload
--    (UUID from 035_adp09, TEXT from GBL-082). Unqualified names match
--    the rest of the migration suite which relies on
--    `SET search_path TO <schema>,public` set by src/db/migrations.zig
--    and on the migrate CLI's default search_path resolving to public.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS bpm_audit_chain_canonical_payload(
    UUID,UUID,UUID,TEXT,TEXT,UUID,TIMESTAMPTZ,JSONB,JSONB,UUID,JSONB,TEXT);
DROP FUNCTION IF EXISTS bpm_audit_chain_canonical_payload(
    UUID,UUID,UUID,TEXT,TEXT,TEXT,TIMESTAMPTZ,JSONB,JSONB,UUID,JSONB,TEXT);

-- ---------------------------------------------------------------------------
-- 2. Drop both overloads of bpm_audit_compute_chain_hash
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS bpm_audit_compute_chain_hash(
    UUID,UUID,UUID,TEXT,TEXT,UUID,TIMESTAMPTZ,JSONB,JSONB,UUID,JSONB,TEXT);
DROP FUNCTION IF EXISTS bpm_audit_compute_chain_hash(
    UUID,UUID,UUID,TEXT,TEXT,TEXT,TIMESTAMPTZ,JSONB,JSONB,UUID,JSONB,TEXT);

-- ---------------------------------------------------------------------------
-- 3. Re-create bpm_audit_chain_canonical_payload with TEXT resource_id.
--    Column shape mirrors 035_adp09_tamper_evident_audit_chain.sql, EXCEPT
--    no `lower(p_resource_id::text)` — p_resource_id is already TEXT and may
--    contain bytes that are not valid UTF-8; lower() is also undefined for
--    arbitrary TEXT if a 0xAA byte collides with a locale edge case.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bpm_audit_chain_canonical_payload(
    p_tenant_id UUID,
    p_audit_id UUID,
    p_actor_id UUID,
    p_action TEXT,
    p_resource_type TEXT,
    p_resource_id TEXT,
    p_timestamp TIMESTAMPTZ,
    p_before_state JSONB,
    p_after_state JSONB,
    p_pipeline_run_id UUID,
    p_payload_full JSONB,
    p_prev_chain_hash TEXT,
    p_trace_id TEXT DEFAULT NULL
) RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    SELECT concat_ws(E'\n',
        'tenant_id=' || lower(p_tenant_id::text),
        'audit_id=' || lower(p_audit_id::text),
        'actor_id=' || COALESCE(lower(p_actor_id::text), '~'),
        'action=' || COALESCE(p_action, '~'),
        'resource_type=' || COALESCE(p_resource_type, '~'),
        'resource_id=' || p_resource_id,
        'trace_id=' || COALESCE(p_trace_id, '~'),
        'created_at_us=' || ((EXTRACT(EPOCH FROM p_timestamp) * 1000000)::bigint)::text,
        'before_state=' || COALESCE(p_before_state::text, '~'),
        'after_state=' || COALESCE(p_after_state::text, '~'),
        'pipeline_run_id=' || COALESCE(lower(p_pipeline_run_id::text), '~'),
        'payload_full=' || COALESCE(p_payload_full::text, '~'),
        'prev_chain_hash=' || COALESCE(lower(p_prev_chain_hash), '~')
    );
$$;

-- ---------------------------------------------------------------------------
-- 4. Re-create bpm_audit_compute_chain_hash with TEXT resource_id.
--    The convert_to(..., 'UTF8') call is wrapped in BEGIN ... EXCEPTION WHEN
--    OTHERS so the function NEVER raises — it returns the canonical
--    OpenSSL EVP_Digest "all-zero" SHA-256 sentinel (64 hex zeros) on
--    encoding failure. Downstream bpm_audit_validate_chain treats this as
--    an invalid format and skips the row, but the audit row is still
--    inserted.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bpm_audit_compute_chain_hash(
    p_tenant_id UUID,
    p_audit_id UUID,
    p_actor_id UUID,
    p_action TEXT,
    p_resource_type TEXT,
    p_resource_id TEXT,
    p_timestamp TIMESTAMPTZ,
    p_before_state JSONB,
    p_after_state JSONB,
    p_pipeline_run_id UUID,
    p_payload_full JSONB,
    p_prev_chain_hash TEXT,
    p_trace_id TEXT DEFAULT NULL
) RETURNS TEXT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_canon TEXT;
    v_hash TEXT;
BEGIN
    v_canon := bpm_audit_chain_canonical_payload(
        p_tenant_id, p_audit_id, p_actor_id, p_action, p_resource_type,
        p_resource_id, p_timestamp, p_before_state, p_after_state,
        p_pipeline_run_id, p_payload_full, p_prev_chain_hash, p_trace_id
    );
    BEGIN
        v_hash := encode(public.digest(convert_to(v_canon, 'UTF8'), 'sha256'), 'hex');
    EXCEPTION WHEN OTHERS THEN
        -- Sentinel: 64 hex zeros — recognised as invalid by
        -- bpm_audit_validate_chain which will skip the row.
        v_hash := repeat('0', 64);
        RAISE WARNING 'bpm_audit_compute_chain_hash: payload could not be encoded as UTF-8, returning zero hash. SQLERRM=%', SQLERRM;
    END;
    RETURN v_hash;
END;
$$;

-- ---------------------------------------------------------------------------
-- 5. Trigger + trigger function: guarded by to_regclass('audit_entries').
--
--    audit_entries has not existed in the public schema since GBL-073
--    (drop legacy public business tables). The zig build migrate CLI does
--    NOT set search_path, so unqualified audit_entries resolves against
--    public and is missing → the guard makes this block a no-op there.
--
--    The canonical migrator Migrations.runForSchema() sets
--    search_path TO <schema>,public for every per-tenant application, so
--    unqualified audit_entries resolves to the current tenant schema
--    (where it DOES exist) → the trigger is recreated against the new
--    trigger function in that schema.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
    v_audit_entries_oid OID;
BEGIN
    v_audit_entries_oid := to_regclass('audit_entries');
    IF v_audit_entries_oid IS NULL THEN
        RAISE NOTICE '1107: audit_entries not present in current schema — skipping trigger re-creation (no-op).';
        RETURN;
    END IF;

    EXECUTE 'DROP TRIGGER IF EXISTS trg_bpm_audit_apply_chain_hash ON audit_entries';

    EXECUTE $inner$
        CREATE OR REPLACE FUNCTION bpm_audit_apply_chain_hash()
        RETURNS trigger
        LANGUAGE plpgsql
        AS $func$
        DECLARE
            v_prev_hash TEXT;
            v_safe_resource_id TEXT;
            v_chain_hash TEXT;
            v_lock_key BIGINT;
        BEGIN
            -- Acquire per-tenant advisory lock so concurrent writers do not
            -- fork the chain. Explicit ::bigint cast avoids SQLSTATE 42P08
            -- 'inconsistent types deduced for parameter $1' under PL/pgSQL
            -- when the parameter-type inference is ambiguous. Wrapped in
            -- BEGIN ... EXCEPTION so a transient lock-acquisition failure
            -- never aborts the audit INSERT.
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
        $func$
    $inner$;

    EXECUTE 'CREATE TRIGGER trg_bpm_audit_apply_chain_hash
             BEFORE INSERT ON audit_entries
             FOR EACH ROW EXECUTE FUNCTION bpm_audit_apply_chain_hash()';

    RAISE NOTICE '1107: recreated trg_bpm_audit_apply_chain_hash on audit_entries in current schema';
END;
$$;

-- ---------------------------------------------------------------------------
-- 6. Per-tenant loop: apply the same chain-function + trigger DDL to every
--    schema matching 'tenant_*' (real audit data lives per-tenant; the
--    zig build migrate CLI's search_path resolves to 'public' so step 5
--    above is a no-op there and audit_entries is never reached).
--
--    For each tenant schema we:
--      (a) Drop both UUID and TEXT overloads of the two chain-hash
--          SQL functions in the per-tenant namespace.
--      (b) Re-create the canonical_payload + compute_chain_hash +
--          apply_chain_hash trigger function (TEXT resource_id) in
--          the per-tenant namespace.
--      (c) Recreate the BEFORE INSERT trigger against the per-tenant
--          audit_entries table.
--      (d) Widen audit_entries.resource_id from UUID to TEXT (no-op
--          if already TEXT). GBL-081's guard was originally written
--          for the public schema; it has not been seen to run against
--          per-tenant schemas on this database, so we are explicit here.
--
--    Each EXECUTE is wrapped in BEGIN ... EXCEPTION WHEN OTHERS THEN
--    RAISE WARNING so a single broken tenant cannot abort the whole loop
--    or the outer transaction.
-- ---------------------------------------------------------------------------
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
           -- ISS-0646 / GH-651: this loop runs every time THIS FILE executes
           -- for ANY schema (i.e. every time a brand-new tenant is
           -- provisioned, since runForSchema() applies pending migrations in
           -- order for that one new schema) -- but it reaches back and
           -- unconditionally recreates bpm_audit_apply_chain_hash() with
           -- THIS FILE's shape on EVERY existing tenant schema, including
           -- ones where a later migration (1142) already installed a newer,
           -- correct body. The migration ledger tracks (schema_name,
           -- version) for THIS file's own nominal pass only -- it has no
           -- awareness that this loop's side effect touches other schemas,
           -- so it can never prevent this. Confirmed live: reproduced
           -- deterministically, single-threaded, by provisioning any one
           -- new tenant schema while tenant_default already had 1142
           -- applied -- tenant_default's function body silently reverted
           -- to this file's pre-1142 shape with zero ledger interaction.
           -- Skip any schema that already has 1142 applied -- 1142
           -- unconditionally re-creates bpm_audit_apply_chain_hash() with a
           -- newer, correct body (the payload_full auto-population block);
           -- letting this file's loop run there would revert it. A text
           -- comparison against '1142...' is deliberately NOT used here
           -- (unlike the numeric migrationOrder() the Zig runner uses,
           -- GBL-prefixed filenames do not sort correctly as plain text) --
           -- checking for this one specific, known-later file by exact name
           -- is simpler and sufficient for what this guard needs to prevent.
           AND NOT EXISTS (
               SELECT 1 FROM public.schema_migrations sm
                WHERE sm.schema_name = nspname
                  AND sm.version = '1142_iss0645_restore_adp10_payload_full_trigger.sql'
           )
         ORDER BY nspname
    LOOP
        RAISE NOTICE '1107: applying chain-hash DDL to tenant schema %', rec.nspname;

        -- (d) Widen resource_id from UUID to TEXT. Idempotent: a TEXT
        --     column triggers a 'column cannot be cast automatically' or
        --     'no conversion' SQLSTATE which is swallowed by the guard.
        BEGIN
            v_sql := format(
                'ALTER TABLE %I.audit_entries ALTER COLUMN resource_id TYPE TEXT USING LOWER(resource_id::text)',
                rec.nspname
            );
            EXECUTE v_sql;
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '1107: skip ALTER COLUMN on tenant=%, sql=%', rec.nspname, SQLERRM;
        END;

        -- (a) Drop both UUID and TEXT overloads in the per-tenant namespace.
        BEGIN
            EXECUTE format(
                'DROP FUNCTION IF EXISTS %I.bpm_audit_chain_canonical_payload(
                    UUID,UUID,UUID,TEXT,TEXT,UUID,TIMESTAMPTZ,JSONB,JSONB,UUID,JSONB,TEXT)',
                rec.nspname
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '1107: skip DROP canonical_payload(uuid-overload) on tenant=%, sql=%', rec.nspname, SQLERRM;
        END;

        BEGIN
            EXECUTE format(
                'DROP FUNCTION IF EXISTS %I.bpm_audit_chain_canonical_payload(
                    UUID,UUID,UUID,TEXT,TEXT,TEXT,TIMESTAMPTZ,JSONB,JSONB,UUID,JSONB,TEXT)',
                rec.nspname
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '1107: skip DROP canonical_payload(text-overload) on tenant=%, sql=%', rec.nspname, SQLERRM;
        END;

        BEGIN
            EXECUTE format(
                'DROP FUNCTION IF EXISTS %I.bpm_audit_compute_chain_hash(
                    UUID,UUID,UUID,TEXT,TEXT,UUID,TIMESTAMPTZ,JSONB,JSONB,UUID,JSONB,TEXT)',
                rec.nspname
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '1107: skip DROP compute_chain_hash(uuid-overload) on tenant=%, sql=%', rec.nspname, SQLERRM;
        END;

        BEGIN
            EXECUTE format(
                'DROP FUNCTION IF EXISTS %I.bpm_audit_compute_chain_hash(
                    UUID,UUID,UUID,TEXT,TEXT,TEXT,TIMESTAMPTZ,JSONB,JSONB,UUID,JSONB,TEXT)',
                rec.nspname
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '1107: skip DROP compute_chain_hash(text-overload) on tenant=%, sql=%', rec.nspname, SQLERRM;
        END;

        BEGIN
            EXECUTE format('DROP FUNCTION IF EXISTS %I.bpm_audit_apply_chain_hash()', rec.nspname);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '1107: skip DROP apply_chain_hash on tenant=%, sql=%', rec.nspname, SQLERRM;
        END;

        -- (b.1) Re-create bpm_audit_chain_canonical_payload in the tenant namespace.
        BEGIN
            EXECUTE format($inner$
                CREATE OR REPLACE FUNCTION %I.bpm_audit_chain_canonical_payload(
                    p_tenant_id UUID,
                    p_audit_id UUID,
                    p_actor_id UUID,
                    p_action TEXT,
                    p_resource_type TEXT,
                    p_resource_id TEXT,
                    p_timestamp TIMESTAMPTZ,
                    p_before_state JSONB,
                    p_after_state JSONB,
                    p_pipeline_run_id UUID,
                    p_payload_full JSONB,
                    p_prev_chain_hash TEXT,
                    p_trace_id TEXT DEFAULT NULL
                ) RETURNS TEXT
                LANGUAGE sql
                STABLE
                AS $func$
                    SELECT concat_ws(E'\n',
                        'tenant_id=' || lower(p_tenant_id::text),
                        'audit_id=' || lower(p_audit_id::text),
                        'actor_id=' || COALESCE(lower(p_actor_id::text), '~'),
                        'action=' || COALESCE(p_action, '~'),
                        'resource_type=' || COALESCE(p_resource_type, '~'),
                        'resource_id=' || p_resource_id,
                        'trace_id=' || COALESCE(p_trace_id, '~'),
                        'created_at_us=' || ((EXTRACT(EPOCH FROM p_timestamp) * 1000000)::bigint)::text,
                        'before_state=' || COALESCE(p_before_state::text, '~'),
                        'after_state=' || COALESCE(p_after_state::text, '~'),
                        'pipeline_run_id=' || COALESCE(lower(p_pipeline_run_id::text), '~'),
                        'payload_full=' || COALESCE(p_payload_full::text, '~'),
                        'prev_chain_hash=' || COALESCE(lower(p_prev_chain_hash), '~')
                    );
                $func$
            $inner$, rec.nspname);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '1107: skip CREATE canonical_payload on tenant=%, sql=%', rec.nspname, SQLERRM;
        END;

        -- (b.2) Re-create bpm_audit_compute_chain_hash in the tenant namespace.
        BEGIN
            EXECUTE format($inner$
                CREATE OR REPLACE FUNCTION %I.bpm_audit_compute_chain_hash(
                    p_tenant_id UUID,
                    p_audit_id UUID,
                    p_actor_id UUID,
                    p_action TEXT,
                    p_resource_type TEXT,
                    p_resource_id TEXT,
                    p_timestamp TIMESTAMPTZ,
                    p_before_state JSONB,
                    p_after_state JSONB,
                    p_pipeline_run_id UUID,
                    p_payload_full JSONB,
                    p_prev_chain_hash TEXT,
                    p_trace_id TEXT DEFAULT NULL
                ) RETURNS TEXT
                LANGUAGE plpgsql
                STABLE
                AS $func$
                DECLARE
                    v_canon TEXT;
                    v_hash TEXT;
                BEGIN
                    v_canon := %I.bpm_audit_chain_canonical_payload(
                        p_tenant_id, p_audit_id, p_actor_id, p_action, p_resource_type,
                        p_resource_id, p_timestamp, p_before_state, p_after_state,
                        p_pipeline_run_id, p_payload_full, p_prev_chain_hash, p_trace_id
                    );
                    BEGIN
                        v_hash := encode(public.digest(convert_to(v_canon, 'UTF8'), 'sha256'), 'hex');
                    EXCEPTION WHEN OTHERS THEN
                        v_hash := repeat('0', 64);
                        RAISE WARNING 'bpm_audit_compute_chain_hash: payload could not be encoded as UTF-8, returning zero hash. SQLERRM=%', SQLERRM;
                    END;
                    RETURN v_hash;
                END;
                $func$
            $inner$, rec.nspname, rec.nspname);
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '1107: skip CREATE compute_chain_hash on tenant=%, sql=%', rec.nspname, SQLERRM;
        END;

        -- (b.3) Re-create the trigger function bpm_audit_apply_chain_hash in the tenant namespace.
        --       It calls %I.bpm_audit_compute_chain_hash(...) with the same schema qualification.
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
                    -- Acquire per-tenant advisory lock so concurrent writers
                    -- do not fork the chain. Explicit ::bigint cast avoids
                    -- SQLSTATE 42P08 'inconsistent types deduced for
                    -- parameter $1' under PL/pgSQL when the parameter-type
                    -- inference is ambiguous. Wrapped in BEGIN ...
                    -- EXCEPTION so a transient lock-acquisition failure
                    -- never aborts the audit INSERT.
                    BEGIN
                        v_lock_key := hashtext('bpm.audit.chain.' || NEW.tenant_id::text)::bigint;
                        PERFORM pg_advisory_xact_lock(v_lock_key::bigint);
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
            RAISE WARNING '1107: skip CREATE apply_chain_hash on tenant=%, sql=%', rec.nspname, SQLERRM;
        END;

        -- (c) Drop and recreate the BEFORE INSERT trigger.
        BEGIN
            EXECUTE format(
                'DROP TRIGGER IF EXISTS trg_bpm_audit_apply_chain_hash ON %I.audit_entries',
                rec.nspname
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '1107: skip DROP TRIGGER on tenant=%, sql=%', rec.nspname, SQLERRM;
        END;

        BEGIN
            EXECUTE format(
                'CREATE TRIGGER trg_bpm_audit_apply_chain_hash
                 BEFORE INSERT ON %I.audit_entries
                 FOR EACH ROW EXECUTE FUNCTION %I.bpm_audit_apply_chain_hash()',
                rec.nspname, rec.nspname
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING '1107: skip CREATE TRIGGER on tenant=%, sql=%', rec.nspname, SQLERRM;
        END;

        RAISE NOTICE '1107: applied chain-hash DDL to tenant schema %', rec.nspname;
    END LOOP;
END;
$$;

COMMIT;