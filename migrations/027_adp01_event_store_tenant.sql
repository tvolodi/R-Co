-- 027_adp01_event_store_tenant.sql
-- Stage 6.5: ADP-01 — additive tenant_id support for event store tables.

ALTER TABLE events
    ADD COLUMN IF NOT EXISTS tenant_id UUID NOT NULL
    DEFAULT '00000000-0000-0000-0000-000000000000';

ALTER TABLE events_archive
    ADD COLUMN IF NOT EXISTS tenant_id UUID NOT NULL
    DEFAULT '00000000-0000-0000-0000-000000000000';

CREATE INDEX IF NOT EXISTS idx_events_tenant_instance_seq
    ON events(tenant_id, instance_id, sequence_number);

CREATE INDEX IF NOT EXISTS idx_events_tenant_global_seq
    ON events(tenant_id, global_seq);

CREATE INDEX IF NOT EXISTS idx_events_archive_tenant_instance_seq
    ON events_archive(tenant_id, instance_id, sequence_number);

CREATE INDEX IF NOT EXISTS idx_events_archive_tenant_global_seq
    ON events_archive(tenant_id, global_seq);
