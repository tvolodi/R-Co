-- Migration 094: EXP-201, EXP-202 — Dynamic Entity Subsystem foundation
-- Date: 2026-06-12
--
-- PURPOSE:
--   Creates the tables and seed data for the Dynamic Entity Subsystem:
--     - entity_definitions: versioned entity definition schemas
--     - entity_type_instances: maps entity types to synthetic instance IDs
--     - entity_record_latest: projection table for current entity record state
--     - Event type seeds: ENTITY_RECORD_CREATED/UPDATED/DELETED
--
-- IDEMPOTENCY:
--   All CREATE TABLE / CREATE INDEX use IF NOT EXISTS.
--   Event type inserts use ON CONFLICT DO NOTHING.
--   No existing tables are modified (additive-only).

-- ── Entity Definitions ───────────────────────────────────────────────────────
-- Stores one row per entity definition version. Denormalised from repository
-- artifacts for fast lookup.

DO $$
BEGIN
-- scope: public
-- ISS-0185: GLOBAL_REGISTRY only (3 table(s)); public canonical.

    CREATE TABLE IF NOT EXISTS public.entity_definitions (
        id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
        tenant_id               UUID        NOT NULL,
        name                    TEXT        NOT NULL,
        display_name            TEXT        NOT NULL,
        description             TEXT,
        definition_json         JSONB       NOT NULL,
        content_hash            BYTEA       NOT NULL,
        logical_shape_version   INTEGER     NOT NULL DEFAULT 1,
        artifact_version_id     UUID,
        status                  TEXT        NOT NULL DEFAULT 'DRAFT'
                                        CHECK (status IN ('DRAFT','ACTIVE','DEPRECATED','ARCHIVED')),
        created_by              UUID        NOT NULL,
        created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),

        CONSTRAINT uq_entity_defs_tenant_name_version
            UNIQUE (tenant_id, name, logical_shape_version)
    );
EXCEPTION WHEN duplicate_table THEN NULL;
END $$;

CREATE INDEX IF NOT EXISTS idx_entity_defs_tenant_name
    ON public.entity_definitions (tenant_id, name);

CREATE INDEX IF NOT EXISTS idx_entity_defs_status
    ON public.entity_definitions (tenant_id, status);

CREATE INDEX IF NOT EXISTS idx_entity_defs_content_hash
    ON public.entity_definitions (content_hash);

-- ── Entity Type Instances ────────────────────────────────────────────────────
-- Maps entity type names to synthetic instance IDs for event store integration.

DO $$
BEGIN
    CREATE TABLE IF NOT EXISTS public.entity_type_instances (
        entity_type     TEXT        PRIMARY KEY,
        tenant_id       UUID        NOT NULL,
        instance_id     UUID        NOT NULL UNIQUE,
        created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
EXCEPTION WHEN duplicate_table THEN NULL;
END $$;

-- ── Entity Record Latest (projection) ────────────────────────────────────────
-- One row per entity record, updated atomically with each event.

DO $$
BEGIN
    CREATE TABLE IF NOT EXISTS public.entity_record_latest (
        tenant_id           UUID        NOT NULL,
        entity_type         TEXT        NOT NULL,
        record_id           UUID        NOT NULL,
        current_state       JSONB       NOT NULL DEFAULT '{}',
        version_seq         BIGINT      NOT NULL DEFAULT 0,
        entity_def_version  INTEGER     NOT NULL,
        created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        deleted_at          TIMESTAMPTZ,

        CONSTRAINT pk_entity_record_latest
            PRIMARY KEY (entity_type, record_id)
    );
EXCEPTION WHEN duplicate_table THEN NULL;
END $$;

CREATE INDEX IF NOT EXISTS idx_erl_tenant_type
    ON public.entity_record_latest (tenant_id, entity_type);

CREATE INDEX IF NOT EXISTS idx_erl_tenant_type_updated
    ON public.entity_record_latest (tenant_id, entity_type, updated_at DESC);

-- ── Entity Event Type Seeds ──────────────────────────────────────────────────
-- Register ENTITY_RECORD_CREATED, ENTITY_RECORD_UPDATED, ENTITY_RECORD_DELETED
-- in event_type_registry so the event store can validate their payloads.

INSERT INTO public.event_type_registry (name, schema_version, json_schema, description)
VALUES
    ('ENTITY_RECORD_CREATED', 1,
     '{"type":"object","required":["entity_type","entity_def_version","record_id","field_values"],"properties":{"entity_type":{"type":"string","minLength":1,"maxLength":128},"entity_def_version":{"type":"integer","minimum":1},"record_id":{"type":"string","format":"uuid"},"field_values":{"type":"object"}}}'::jsonb,
     'Dynamic entity record created'),

    ('ENTITY_RECORD_UPDATED', 1,
     '{"type":"object","required":["entity_type","entity_def_version","record_id","field_values","changed_fields"],"properties":{"entity_type":{"type":"string","minLength":1,"maxLength":128},"entity_def_version":{"type":"integer","minimum":1},"record_id":{"type":"string","format":"uuid"},"field_values":{"type":"object"},"changed_fields":{"type":"array","items":{"type":"string"}}}}'::jsonb,
     'Dynamic entity record updated'),

    ('ENTITY_RECORD_DELETED', 1,
     '{"type":"object","required":["entity_type","entity_def_version","record_id","prior_field_values"],"properties":{"entity_type":{"type":"string","minLength":1,"maxLength":128},"entity_def_version":{"type":"integer","minimum":1},"record_id":{"type":"string","format":"uuid"},"prior_field_values":{"type":"object"}}}'::jsonb,
     'Dynamic entity record deleted')
ON CONFLICT (name, schema_version) DO NOTHING;
