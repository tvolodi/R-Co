-- scope: public
-- 050_tenant_hostnames.sql
-- OIDCF2: per-tenant hostname registry for subdomain-based config discovery.
-- Requirement: OIDC-F-05
--
-- ISS-0101 / GH-359: despite the "per-tenant" name in the comment above, this
-- table's `tenant_id` column FKs to the GLOBAL_REGISTRY `tenant` table
-- (canonical home = public — see migrations/031_adp04b_tenant_realm_binding.sql),
-- and rows are distinguished BY tenant_id, not by living in a per-tenant
-- schema. The table itself belongs in public only. Without the
-- `-- scope: public` header this file defaulted to .all_schemas and its
-- unqualified CREATE TABLE ran again in every tenant-schema pass, creating a
-- shadow `tenant_hostnames` inside tenant_default with a dangling FK to the
-- shadow `tenant` table. See docs/issues/ISS-0101.json and
-- migrations/GBL-140_iss0101_drop_shadow_tenant_tables.sql.

CREATE TABLE IF NOT EXISTS public.tenant_hostnames (
    id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id  UUID        NOT NULL REFERENCES public.tenant(id) ON DELETE CASCADE,
    hostname   TEXT        NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT tenant_hostnames_hostname_uq UNIQUE (hostname)
);

CREATE INDEX IF NOT EXISTS tenant_hostnames_hostname_idx
    ON public.tenant_hostnames (hostname);
