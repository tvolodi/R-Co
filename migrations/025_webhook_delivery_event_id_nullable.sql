-- 025_webhook_delivery_event_id_nullable.sql
-- EXT-02 delivery rows are keyed by subscription + event envelope fields.
-- event_id is legacy baggage from the earlier schema and must no longer block inserts.

ALTER TABLE webhook_deliveries
    ALTER COLUMN event_id DROP NOT NULL;
