-- Migration 1136: ISS-0149 / GitHub #465 — apply the EXP-301/EXP-302 effects DDL
--                 to the schemas that actually own the tables it depends on.
--
-- PURPOSE:
--   `GBL-125_exp301_effects_outbox.sql` (effects_outbox table + indexes),
--   `GBL-126_exp301_effects_event_types.sql` (EFFECT_* event type registrations)
--   and `GBL-127_exp302_service_task_effect_ref.sql` (tasks.effect_delivery_id)
--   are all `GBL-`-prefixed, so `src/db/migrations.zig` runs them against the
--   `public` schema ONLY. But each is guarded by
--   `to_regclass('<prerequisite>') IS NULL THEN RETURN`, and every one of those
--   prerequisites lives exclusively in the per-tenant schemas after GBL-073:
--
--     GBL-125  guards on instance_projections  -> tenant schemas only
--     GBL-126  guards on event_type_registry   -> tenant schemas only
--     GBL-127  guards on tasks                 -> tenant schemas only
--
--   So in `public` the guard is always NULL, the body never executes, and the
--   migration is nonetheless recorded in public.schema_migrations as applied.
--   Net effect: `effects_outbox` HAS NEVER EXISTED in any schema, the EFFECT_*
--   event types were never registered, and `tasks.effect_delivery_id` was never
--   added — while the ledger reports all three as done.
--
--   This is the anti-pattern catalogued in docs/anti-patterns.md under GH #335 /
--   ISS-0076 ("guard reads a prerequisite that only exists under a per-tenant
--   schema"), recurring here across three files at once. It surfaced when
--   tests/integration/effects_subsystem_test.zig was executed for the first time
--   under GH #439 and 20 of its blocks failed with
--   `relation "effects_outbox" does not exist`.
--
-- WHY A NEW FILE RATHER THAN RENAMING GBL-125/126/127:
--   Renaming a migration changes its `version` string, which is the primary key
--   in public.schema_migrations. Every existing database has the GBL- names
--   recorded; renaming would make the runner see three brand-new unapplied files
--   AND leave three orphan ledger rows. Adding a corrective, idempotent,
--   plain-numeric migration is the append-only path this repo already requires.
--
-- SCHEMA SCOPE:
--   No `GBL-` prefix, so the runner applies this to EVERY schema (public and each
--   tenant). The same `to_regclass` guards are kept, which now do their intended
--   job: they no-op in `public` (where the prerequisites genuinely are absent)
--   and execute in each tenant schema (where they are present).
--
-- IDEMPOTENCY:
--   Every statement uses IF NOT EXISTS / ON CONFLICT DO NOTHING, so re-running
--   against a schema that already has the objects is a no-op.

-- ---------------------------------------------------------------------------
-- (1) effects_outbox — the EXP-301 transactional outbox (was GBL-125)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    -- Guard: instance_projections must exist in THIS schema. Unlike GBL-125,
    -- this file is not GBL-prefixed, so "this schema" is each tenant schema in
    -- turn, where instance_projections really does exist.
    IF to_regclass('instance_projections') IS NULL THEN
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

    -- Index on correlation_key to support the idempotent re-entry lookup.
    EXECUTE $q$
        CREATE INDEX IF NOT EXISTS idx_effects_outbox_correlation
            ON effects_outbox (correlation_key)
    $q$;
END $$;

-- ---------------------------------------------------------------------------
-- (2) EFFECT_* event type registrations (was GBL-126)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF to_regclass('event_type_registry') IS NULL THEN
        RETURN;
    END IF;

    INSERT INTO event_type_registry (name, schema_version, json_schema, description)
    VALUES
      (
        'EFFECT_EMITTED', 1,
        '{"type":"object","required":["node_id","correlation_key","kind"],"properties":{"node_id":{"type":"string"},"token_id":{"type":"string"},"correlation_key":{"type":"string"},"kind":{"type":"string"}}}'::jsonb,
        'EXP-301: Async effect emitted from service task; outbox row created'
      ),
      (
        'EFFECT_COMPLETED', 1,
        '{"type":"object","required":["correlation_key"],"properties":{"correlation_key":{"type":"string"},"response_body_json":{"type":"string"},"http_status":{"type":"integer"}}}'::jsonb,
        'EXP-301: Async effect delivery succeeded; token advanced past SERVICE_TASK'
      ),
      (
        'EFFECT_FAILED', 1,
        '{"type":"object","required":["correlation_key","error_detail"],"properties":{"correlation_key":{"type":"string"},"error_detail":{"type":"string"},"http_status":{"type":"integer"}}}'::jsonb,
        'EXP-301: Async effect delivery failed; instance set to ERROR'
      )
    ON CONFLICT (name, schema_version) DO NOTHING;
END $$;

-- ---------------------------------------------------------------------------
-- (3) tasks.effect_delivery_id — EXP-302 service task effect link (was GBL-127)
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF to_regclass('tasks') IS NULL THEN
        RETURN;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM   information_schema.columns
        WHERE  table_schema = current_schema()
          AND  table_name   = 'tasks'
          AND  column_name  = 'effect_delivery_id'
    ) THEN
        EXECUTE 'ALTER TABLE tasks ADD COLUMN effect_delivery_id UUID';
    END IF;
END $$;
