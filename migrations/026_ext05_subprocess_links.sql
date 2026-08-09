-- 026_ext05_subprocess_links.sql
-- Stage 6: EXT-05 — durable parent/child linkage for SUB_PROCESS runtime
--
-- scope: tenant_only
--
-- ISS-0644 / GH-643: PER_TENANT (canonical home = tenant_default), and this
-- file creates exactly one table with no other statements, so the
-- `tenant_only` scope (ISS-0644's new MigrationScope primitive) closes the
-- shadow-recreation path permanently instead of relying on
-- GBL-141_iss0641_drop_dual_schema_shadows.sql to keep cleaning up after
-- every fresh tenant-schema provision.

CREATE TABLE IF NOT EXISTS subprocess_links (
    parent_instance_id    UUID        NOT NULL REFERENCES instance_projections(instance_id) ON DELETE CASCADE,
    child_instance_id     UUID        PRIMARY KEY REFERENCES instance_projections(instance_id) ON DELETE CASCADE,
    parent_node_id        TEXT        NOT NULL,
    parent_branch_id      TEXT        NOT NULL,
    status                TEXT        NOT NULL DEFAULT 'WAITING',
                                     -- WAITING | COMPLETED | ERROR | CANCELLED
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at          TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_subprocess_links_parent_waiting
    ON subprocess_links(parent_instance_id)
    WHERE status = 'WAITING';

CREATE INDEX IF NOT EXISTS idx_subprocess_links_child_waiting
    ON subprocess_links(child_instance_id)
    WHERE status = 'WAITING';
