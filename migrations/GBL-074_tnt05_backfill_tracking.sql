-- GBL-074: TNT-05 backfill tracking tables (idempotent)
--
-- Creates the per-tenant progress tracker and orphan log used by GBL-075.
-- Both tables live in public (GBL-prefix: exempt from lint_migration_schema.py
-- business-table check).
--
-- PERMITTED_PUBLIC_TABLES additions (src/bootstrap/audit.zig):
--   tnt05_progress, tnt05_orphans  (updated before this migration runs)

CREATE TABLE IF NOT EXISTS tnt05_progress (
    tenant_id    UUID        NOT NULL,
    table_name   TEXT        NOT NULL,
    rows_copied  BIGINT      NOT NULL DEFAULT 0,
    status       TEXT        NOT NULL DEFAULT 'PENDING',
    started_at   TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    PRIMARY KEY (tenant_id, table_name),
    CONSTRAINT tnt05_progress_status_check
        CHECK (status IN ('PENDING', 'IN_PROGRESS', 'COMPLETED', 'FAILED'))
);

COMMENT ON TABLE tnt05_progress IS
    'Per-tenant per-table backfill progress for TNT-05. Idempotency gate for GBL-075.';

CREATE TABLE IF NOT EXISTS tnt05_orphans (
    row_id      TEXT        NOT NULL,
    table_name  TEXT        NOT NULL,
    tenant_id   UUID        NOT NULL,
    reason      TEXT        NOT NULL,
    logged_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (table_name, row_id)
);

COMMENT ON TABLE tnt05_orphans IS
    'Rows from public business tables whose tenant_id was not found in public.tenant. '
    'Written by GBL-075; requires manual review before deletion.';
