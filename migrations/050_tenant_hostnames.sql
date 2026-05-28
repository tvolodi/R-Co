-- 050_tenant_hostnames.sql
-- OIDCF2: per-tenant hostname registry for subdomain-based config discovery.
-- Requirement: OIDC-F-05

CREATE TABLE IF NOT EXISTS tenant_hostnames (
    id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id  UUID        NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
    hostname   TEXT        NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT tenant_hostnames_hostname_uq UNIQUE (hostname)
);

CREATE INDEX IF NOT EXISTS tenant_hostnames_hostname_idx
    ON tenant_hostnames (hostname);
