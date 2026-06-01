-- 059_fix_audit_chain_trigger_args.sql
-- Fix: bpm_audit_apply_chain_hash trigger function had wrong argument order
-- and types in its call to bpm_audit_compute_chain_hash.
-- The canonical function signature (from migration 035) is:
--   (tenant_id UUID, audit_id UUID, actor_id UUID, action TEXT, resource_type TEXT,
--    resource_id UUID, timestamp TIMESTAMPTZ, before_state JSONB, after_state JSONB,
--    pipeline_run_id UUID, payload_full JSONB, prev_chain_hash TEXT, trace_id TEXT)
-- Previous version swapped audit_id/actor_id and passed wrong types for args 11-13.

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

    -- Call canonical function with correct argument order and types:
    -- (tenant_id, audit_id, actor_id, action, resource_type, resource_id,
    --  timestamp, before_state, after_state, pipeline_run_id, payload_full,
    --  prev_chain_hash, trace_id)
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
        NEW.trace_id
    );

    RETURN NEW;
END;
$$;

-- Also remove the duplicate immutability triggers.
-- Migration 020 created trg_audit_entries_no_update/no_delete via bpm_audit_immutable_guard.
-- Migration 051 created trg_bpm_audit_prevent_update/prevent_delete via bpm_audit_enforce_immutability.
-- Both do the same thing — keep only one set to avoid double-trigger overhead.
DROP TRIGGER IF EXISTS trg_bpm_audit_prevent_update ON audit_entries;
DROP TRIGGER IF EXISTS trg_bpm_audit_prevent_delete ON audit_entries;
DROP FUNCTION IF EXISTS bpm_audit_enforce_immutability();
