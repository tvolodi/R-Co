-- Migration 095: EXP-301 — register effect event types
-- Date: 2026-06-13
--
-- PURPOSE:
--   Registers EFFECT_EMITTED, EFFECT_COMPLETED, and EFFECT_FAILED in the
--   event_type_registry table so the event store can validate and accept them.
--   Uses INSERT ... ON CONFLICT DO NOTHING for idempotency.

-- Guard: only insert if event_type_registry exists (public schema migration).
DO $$
BEGIN
    IF to_regclass('event_type_registry') IS NOT NULL THEN
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
    END IF;
END $$;
