-- 026_ext05_subprocess_links.sql
-- Stage 6: EXT-05 — durable parent/child linkage for SUB_PROCESS runtime
--
-- ISS-0641 / GH-637: PER_TENANT (canonical home = tenant_default).
-- migrations.zig's migrationScope() has no per-table scope primitive (only
-- whole-file .public_only vs .all_schemas), so this file correctly keeps
-- running in every schema pass to create the tenant_default copy, but that
-- also creates an unwanted public shadow. See
-- docs/issue-reports/ISS-0185-diagnosis.yaml and
-- migrations/GBL-141_iss0641_drop_dual_schema_shadows.sql, which drops the
-- public shadow (idempotent, re-run after any cold-start replay).

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
