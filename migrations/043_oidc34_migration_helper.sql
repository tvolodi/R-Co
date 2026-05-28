-- 043_oidc34_migration_helper.sql
-- OIDC-34: migration helper job tracking tables.

CREATE TABLE IF NOT EXISTS oidc_migration_job (
    migration_job_id UUID PRIMARY KEY,
    realm_id TEXT NOT NULL,
    initiated_by TEXT NOT NULL,
    dry_run BOOLEAN NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('RUNNING','PARTIAL','COMPLETED','ROLLED_BACK','FAILED')),
    attempted_count INTEGER NOT NULL DEFAULT 0,
    provisioned_count INTEGER NOT NULL DEFAULT 0,
    linked_count INTEGER NOT NULL DEFAULT 0,
    failed_count INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS oidc_migration_item (
    migration_item_id UUID PRIMARY KEY,
    migration_job_id UUID NOT NULL REFERENCES oidc_migration_job(migration_job_id),
    local_user_id UUID NOT NULL,
    provider_user_id TEXT,
    action_status TEXT NOT NULL CHECK (action_status IN ('PLANNED','PROVISIONED','LINKED','FAILED','ROLLED_BACK')),
    failure_reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_oidc_migration_item_job
    ON oidc_migration_item (migration_job_id, action_status);
