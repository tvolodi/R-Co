-- 1166_ord03_ordering_event_types_seed.sql
-- ORD-03 / ORD-04 (stage 16, WF02-batch-7-20260816): register the correlated
-- effect re-entry event types in event_type_registry so src/ordering/consumer.zig
-- (applyCompletion -> EXECUTION_EFFECT_APPLIED, AC2/AC4) and the ORD-04 lag /
-- contention escalations (EXECUTION_CORRELATION_LAG / EXECUTION_CORRELATION_CONTENTION)
-- pass the ES-05 registry check. ORD-03 is Type E only (no migration YAML), so this
-- is a dedicated follow-up seed following the 1152 pattern.
--
-- Uses retention_class = 'retain_forever': EXECUTION_* events are in the protected
-- family (chk_retention_class_protected_family forbids 'delete'); 'archive_queryable'
-- (the column default) would allow eventual archival, so we explicitly set
-- 'retain_forever' per PAR-03 AC1.
--
-- Idempotent: ON CONFLICT (name, schema_version) DO NOTHING.
-- Guarded: event_type_registry is a PER_TENANT table (absent in public pass).

DO $$
BEGIN
    IF to_regclass('event_type_registry') IS NULL THEN
        RAISE NOTICE '1166: event_type_registry absent in this schema pass — skipping ordering event-type seed (per-tenant table).';
        RETURN;
    END IF;

    INSERT INTO event_type_registry (name, schema_version, json_schema, description, retention_class)
    VALUES
        (
            'EXECUTION_EFFECT_APPLIED', 1,
            '{"type":"object","required":["correlation_id","sequence_no"],"additionalProperties":false,"properties":{"correlation_id":{"type":"string"},"sequence_no":{"type":"integer"}}}'::jsonb,
            'ORD-03 AC2/AC4: a correlated effect completion was applied in order; apply order is auditable from the event log alone (ORD-04 AC5)',
            'retain_forever'
        ),
        (
            'EXECUTION_CORRELATION_LAG', 1,
            '{"type":"object","required":["correlation_id","lag"],"additionalProperties":false,"properties":{"correlation_id":{"type":"string"},"lag":{"type":"integer"},"oldest_pending_age_s":{"type":"integer"}}}'::jsonb,
            'ORD-04 AC2: per-correlation lag exceeded the threshold; names the correlation_id, the lag, and the age of the oldest PENDING row',
            'retain_forever'
        ),
        (
            'EXECUTION_CORRELATION_CONTENTION', 1,
            '{"type":"object","required":["guard_false_rate_pct"],"additionalProperties":false,"properties":{"guard_false_rate_pct":{"type":"integer"},"consumer_count":{"type":"integer"}}}'::jsonb,
            'ORD-04 AC3: execute-guard false rate exceeded 50% in one minute; consumer_count reduced by 2 (floor 2)',
            'retain_forever'
        )
    ON CONFLICT (name, schema_version) DO NOTHING;
END $$;
