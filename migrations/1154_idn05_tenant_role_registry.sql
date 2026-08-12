-- IDN-05: per-tenant named-role registry
-- Runs inside each tenant's own schema (SPT architecture).
-- No tenant_id column — schema search path provides tenant isolation.
-- scope: tenant_only

CREATE TABLE IF NOT EXISTS tenant_role (
    id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name       TEXT        NOT NULL,
    group_id   UUID        NOT NULL REFERENCES groups(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT tenant_role_name_unique UNIQUE (name)
);

CREATE INDEX IF NOT EXISTS idx_tenant_role_name  ON tenant_role(name);
CREATE INDEX IF NOT EXISTS idx_tenant_role_group ON tenant_role(group_id);
