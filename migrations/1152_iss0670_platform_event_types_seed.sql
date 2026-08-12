-- 1152_iss0670_platform_event_types_seed.sql
-- ISS-0670 (PAR-02 AC5): Register EXECUTION_PARTITION_CREATED and related
-- platform event types in event_type_registry. Must run before any code path
-- calls Store.appendPlatform() with these event types (ES-05 registry check).
--
-- Uses retention_class = 'retain_forever': EXECUTION_* events are in the
-- protected family (chk_retention_class_protected_family forbids 'delete');
-- 'archive_queryable' (the column default) would allow eventual archival,
-- so we explicitly set 'retain_forever' per PAR-03 AC1.
--
-- Idempotent: ON CONFLICT (name, schema_version) DO NOTHING.
-- Guarded: event_type_registry is a PER_TENANT table (absent in public pass).

DO $$
BEGIN
    IF to_regclass('event_type_registry') IS NULL THEN
        RAISE NOTICE '1152: event_type_registry absent in this schema pass — skipping (per-tenant table).';
        RETURN;
    END IF;

    INSERT INTO event_type_registry (name, schema_version, json_schema, description, retention_class)
    VALUES
        (
            'EXECUTION_PARTITION_CREATED', 1,
            '{"type":"object","required":["partition_name","parent_table","range_start","range_end"],"additionalProperties":false,"properties":{"partition_name":{"type":"string"},"parent_table":{"type":"string"},"range_start":{"type":"string"},"range_end":{"type":"string"}}}'::jsonb,
            'PAR-02 AC5: monthly partition created and attached by plat_partition_maintenance',
            'retain_forever'
        ),
        (
            'EXECUTION_PARTITION_DETACHED', 1,
            '{"type":"object","required":["partition_name","parent_table","range_start","range_end"],"additionalProperties":false,"properties":{"partition_name":{"type":"string"},"parent_table":{"type":"string"},"range_start":{"type":"string"},"range_end":{"type":"string"}}}'::jsonb,
            'PAR-03: monthly partition detached by PartitionRetention',
            'retain_forever'
        ),
        (
            'EXECUTION_PARTITION_DROPPED', 1,
            '{"type":"object","required":["partition_name","parent_table","range_start","range_end"],"additionalProperties":false,"properties":{"partition_name":{"type":"string"},"parent_table":{"type":"string"},"range_start":{"type":"string"},"range_end":{"type":"string"}}}'::jsonb,
            'PAR-03: monthly partition dropped by PartitionRetention after retention expiry',
            'retain_forever'
        )
    ON CONFLICT (name, schema_version) DO NOTHING;
END $$;
