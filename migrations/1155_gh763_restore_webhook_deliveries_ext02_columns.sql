-- 1155_gh763_restore_webhook_deliveries_ext02_columns.sql
-- GH-763: restore webhook_deliveries columns dropped by PAR-01 (migration 1147)
--
-- Root cause: 1147_par01_events_partitioning.sql drops and recreates webhook_deliveries
-- with a composite FK to the partitioned events table, but the column reconciliation
-- only covered migrations 025 and 085. The seven columns added by
-- 023_ext02_webhook_event_dispatch.sql were silently omitted:
--   event_type, instance_id, payload_json, trace_id, delivered_at,
--   last_http_status, last_error
--
-- This migration adds them back idempotently (ALTER TABLE IF EXISTS + ADD COLUMN IF NOT EXISTS)
-- so that:
--   - public schema: webhook_deliveries does not exist (dropped by GBL-112) — skipped
--   - tenant schemas: columns restored; existing rows are unaffected (all nullable)
--   - TC-ISS-106-05 (full_contract_row_round_trips) passes again
--   - The webhook dispatcher's extended outbox columns are available
--
-- Applies to: every schema with a webhook_deliveries table (tenant schemas only).
-- Idempotent: ALTER TABLE IF EXISTS + ADD COLUMN IF NOT EXISTS are both no-ops when
-- the table or column already exists.

DO $$
BEGIN
    -- Guard: skip if the table doesn't exist in the current schema (e.g. public, where
    -- GBL-112_tnt01_drop_legacy_public_business_tables.sql already DROP'd it).
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = current_schema()
          AND table_name = 'webhook_deliveries'
    ) THEN
        RAISE NOTICE '1155: webhook_deliveries absent in schema % — skipping (expected for public).', current_schema();
        RETURN;
    END IF;

    -- Restore the seven columns from migration 023 that were dropped by migration 1147.
    EXECUTE 'ALTER TABLE webhook_deliveries ADD COLUMN IF NOT EXISTS event_type       TEXT';
    EXECUTE 'ALTER TABLE webhook_deliveries ADD COLUMN IF NOT EXISTS instance_id      UUID';
    EXECUTE 'ALTER TABLE webhook_deliveries ADD COLUMN IF NOT EXISTS payload_json     JSONB';
    EXECUTE 'ALTER TABLE webhook_deliveries ADD COLUMN IF NOT EXISTS trace_id         TEXT';
    EXECUTE 'ALTER TABLE webhook_deliveries ADD COLUMN IF NOT EXISTS delivered_at     TIMESTAMPTZ';
    EXECUTE 'ALTER TABLE webhook_deliveries ADD COLUMN IF NOT EXISTS last_http_status INTEGER';
    EXECUTE 'ALTER TABLE webhook_deliveries ADD COLUMN IF NOT EXISTS last_error       TEXT';
END $$;
