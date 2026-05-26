-- 026_ext05_subprocess_links.sql
-- Stage 6: EXT-05 — durable parent/child linkage for SUB_PROCESS runtime

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
