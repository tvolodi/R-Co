-- Migration 093: EXP-103 — instance_waits persistence layer
-- Date: 2026-06-12
--
-- PURPOSE:
--   Adds the `instance_waits` table, which records every in-flight wait a
--   process instance is currently blocked on. One row exists for each live
--   wait (timer, human task, or catch-event subscription) from the moment
--   the wait is armed until the moment it is resolved.
--
--   The invariant is atomic co-write: the row is inserted in the same
--   database transaction that arms the wait, so a crash between arm and
--   commit leaves neither the wait nor its descriptor.
--
-- IDEMPOTENCY:
--   The DO $$ block is a no-op if instance_projections does not exist
--   (e.g. when applied to the public schema). All CREATE TABLE / CREATE INDEX
--   operations use IF NOT EXISTS guards inside the block.

DO $$
DECLARE
    v_proj_oid OID;
BEGIN
    -- Guard: instance_projections must exist in this schema.
    -- to_regclass() returns NULL without raising an error, making this migration
    -- a no-op when applied to schemas where the table does not exist (e.g. public).
    v_proj_oid := to_regclass('instance_projections');
    IF v_proj_oid IS NULL THEN
        RETURN;
    END IF;

    -- Create the instance_waits table (idempotent via DO NOT EXISTS).
    -- Per-tenant: references instance_projections which lives in the tenant schema.
    EXECUTE $q$
        CREATE TABLE IF NOT EXISTS instance_waits (
            id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
            instance_id      UUID        NOT NULL REFERENCES instance_projections(instance_id) ON DELETE CASCADE,
            kind             TEXT        NOT NULL CHECK (kind IN ('timer', 'catch_event', 'human_task')),
            ref_id           UUID        NOT NULL,
            node_id          TEXT        NOT NULL,
            fire_at          TIMESTAMPTZ NULL,
            catch_event_key  TEXT        NULL,
            created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            resolved_at      TIMESTAMPTZ NULL,
            UNIQUE (instance_id, ref_id)
        )
    $q$;

    -- Index on (instance_id, resolved_at) for efficient restore/reconciliation
    -- queries (EXP-402) that filter unresolved waits per instance.
    EXECUTE $q$
        CREATE INDEX IF NOT EXISTS idx_instance_waits_instance_resolved
            ON instance_waits (instance_id, resolved_at)
    $q$;

END $$;
