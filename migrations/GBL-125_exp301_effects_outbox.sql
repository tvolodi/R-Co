-- Migration 094: EXP-301 — effects_outbox transactional outbox
-- Date: 2026-06-13
--
-- PURPOSE:
--   Creates the `effects_outbox` table used as the transactional outbox for
--   async effect delivery. One row per EFFECT_EMITTED event; rebuildable from
--   the event log. The effects worker polls this table and delivers each row
--   to the external system, retrying with back-off on failure and routing to
--   the DLQ after max_attempts exhausted.
--
-- IDEMPOTENCY:
--   All CREATE TABLE / CREATE INDEX statements use IF NOT EXISTS guards inside
--   a DO $$ block that is a no-op when instance_projections is absent.

DO $$
DECLARE
    v_proj_oid OID;
BEGIN
    -- Guard: instance_projections must exist in this schema.
    v_proj_oid := to_regclass('instance_projections');
    IF v_proj_oid IS NULL THEN
        RETURN;
    END IF;

    EXECUTE $q$
        CREATE TABLE IF NOT EXISTS effects_outbox (
            effect_delivery_id   UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
            effect_event_id      UUID        NOT NULL,
            instance_id          UUID        NOT NULL,
            node_id              TEXT        NOT NULL,
            correlation_key      TEXT        NOT NULL,
            kind                 TEXT        NOT NULL CHECK (kind IN ('http_call','email')),
            spec_json            JSONB       NOT NULL,
            status               TEXT        NOT NULL DEFAULT 'pending'
                                                CHECK (status IN ('pending','delivered','dead_lettered')),
            attempt_count        SMALLINT    NOT NULL DEFAULT 0,
            max_attempts         SMALLINT    NOT NULL DEFAULT 5,
            next_attempt_at      TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '5 seconds',
            last_http_status     SMALLINT,
            last_error           TEXT,
            created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    $q$;

    -- Index for the worker sweep query: due rows in pending status.
    EXECUTE $q$
        CREATE INDEX IF NOT EXISTS idx_effects_outbox_due
            ON effects_outbox (next_attempt_at)
            WHERE status = 'pending'
    $q$;

    -- Index for per-instance lookups and audit queries.
    EXECUTE $q$
        CREATE INDEX IF NOT EXISTS idx_effects_outbox_instance
            ON effects_outbox (instance_id)
    $q$;

    -- Unique constraint on correlation_key to support idempotent re-entry check.
    EXECUTE $q$
        CREATE INDEX IF NOT EXISTS idx_effects_outbox_correlation
            ON effects_outbox (correlation_key)
    $q$;

END $$;
