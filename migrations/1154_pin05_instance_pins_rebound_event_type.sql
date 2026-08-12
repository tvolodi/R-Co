-- 1154_pin05_instance_pins_rebound_event_type.sql
-- PIN-05: register the INSTANCE_PINS_REBOUND event type in
-- event_type_registry, mirroring 002_event_type_registry.sql's seed pattern
-- for every other platform event type.
-- See src/design/pin-05-explicit-instance-pin-rebind.md.
--
-- src/engine/pin_rebind.zig's rebindPins() writes this event via a
-- hand-rolled `INSERT INTO events` (the SAME pattern instance.zig's
-- SUBPROCESS_STARTED / EXECUTION_ERROR writes already use), so this
-- registration is NOT required for the write itself to succeed (those
-- hand-rolled call sites never go through event_store.Store.append()'s
-- registry.validatePayload() gate — see instance.zig's own top-of-file
-- comment on this). It is added anyway so INSTANCE_PINS_REBOUND is
-- discoverable/self-describing for any future consumer that DOES validate
-- against the registry (ES-05), matching every other event type this
-- platform emits.
--
-- Payload shape mirrors src/engine/pin_rebind.zig's buildReboundPayload():
--   {"actor_id": "...", "reason": "...",
--    "changes": [{"kind": "...", "ref": "...",
--                 "prior_version": "...", "new_version": "..."}, ...]}

-- event_type_registry is a PER_TENANT table (see 1151_pin02_...'s identical
-- guard and its cited docs/anti-patterns.md dual-schema classification) —
-- GBL-112_tnt01_drop_legacy_public_business_tables.sql permanently dropped
-- public.event_type_registry. An unguarded INSERT here would fail
-- migration-time with C42P01 "relation event_type_registry does not exist"
-- in the public schema pass.
DO $$
BEGIN
    IF to_regclass('event_type_registry') IS NULL THEN
        RAISE NOTICE 'PIN-05: event_type_registry absent in this schema pass — skipping INSTANCE_PINS_REBOUND registration (per-tenant table, see comment above).';
        RETURN;
    END IF;

    INSERT INTO event_type_registry (name, schema_version, json_schema, description)
    VALUES (
        'INSTANCE_PINS_REBOUND',
        1,
        '{"type":"object","required":["actor_id","reason","changes"],"properties":{"actor_id":{"type":"string"},"reason":{"type":"string"},"changes":{"type":"array","items":{"type":"object","required":["kind","ref","prior_version","new_version"],"properties":{"kind":{"type":"string","enum":["catalog_entry","variable_schema","module"]},"ref":{"type":"string"},"prior_version":{"type":"string"},"new_version":{"type":"string"}}}}}}'::jsonb,
        'PIN-05: instance pin set explicitly rebound via POST /api/v1/instances/{id}/rebind-pins'
    )
    ON CONFLICT (name, schema_version) DO NOTHING;
END $$;
