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
        v_hash := encode(digest(convert_to(v_canon, 'UTF8'), 'sha256'), 'hex');
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
        BEGIN
            -- Acquire per-tenant advisory lock so concurrent writers do not fork the chain.
            PERFORM pg_advisory_xact_lock(hashtext('bpm.audit.chain.' || NEW.tenant_id::text));

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

COMMIT;