-- 1151_pin02_instance_started_pinned_versions.sql
-- PIN-02: widen the registered JSON Schema for INSTANCE_STARTED to include
-- pinned_versions[] — the array PIN-01's resolution pipeline produces.
-- See src/design/pin-02-pin-set-in-instance-started.md for the full design.
--
-- This is a genuine data-content UPDATE against a registry row's json_schema
-- JSONB column, not table/column DDL — templates/specs/migration.template.yaml's
-- schema targets table/column changes, so this migration is hand-written per
-- the design's own Classification rationale (Rule 1's letter does not match:
-- no column changes).
--
-- pinned_versions is NOT added to the schema's `required` array — PIN-02 AC4
-- explicitly allows a definition with zero service-catalog/module references
-- to still produce a valid pinned_versions[] (containing only the
-- variable_schema entry), and Store.append()'s registry.validatePayload()
-- (ES-05) would reject an absent-but-required field, a stricter failure mode
-- than PIN-02's own AC text asks for.
--
-- jsonb_set(..., true) with create_missing = true is idempotent — re-running
-- this UPDATE against a schema where it already succeeded overwrites
-- pinned_versions with the identical value.

-- event_type_registry is a PER_TENANT table (docs/anti-patterns.md's
-- dual-schema classification; canonical home tenant_default) —
-- GBL-112_tnt01_drop_legacy_public_business_tables.sql permanently dropped
-- public.event_type_registry (confirmed by migrations/1149_par03_retention_class.sql's
-- own identical guard against the same table). An unguarded UPDATE here
-- fails migration-time with C42P01 "relation event_type_registry does not
-- exist" in the public pass — guard the same way 1149 already does.
DO $$
BEGIN
    IF to_regclass('event_type_registry') IS NULL THEN
        RAISE NOTICE 'PIN-02: event_type_registry absent in this schema pass — skipping INSTANCE_STARTED schema widening (per-tenant table, see comment above).';
        RETURN;
    END IF;

    UPDATE event_type_registry
    SET json_schema = jsonb_set(
        json_schema,
        '{properties,pinned_versions}',
        '{"type":"array","items":{"type":"object","required":["kind","ref","resolved_id","version","source"],"properties":{"kind":{"type":"string","enum":["catalog_entry","variable_schema","module"]},"ref":{"type":"string"},"resolved_id":{"type":"string"},"version":{"type":"string"},"source":{"type":"string","enum":["resolved","override","inherited"]}}}}'::jsonb,
        true
    ),
    updated_at = NOW()
    WHERE name = 'INSTANCE_STARTED';
END $$;
