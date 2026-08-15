-- 1161_plc01_process_module_catalog.sql
-- PLC-01: Process module catalog — tables and grant table.
-- scope: global (multi-tenant)

-- semver_sort: orders semver strings correctly (1.2.0 < 1.10.0 < 2.0.0).
-- Installed as a reusable helper so both the catalog and solution-pack
-- resolution queries can call it without duplicating the expression.
CREATE OR REPLACE FUNCTION public.semver_sort(v TEXT) RETURNS INT[] AS $$
DECLARE
    parts TEXT[];
BEGIN
    parts := string_to_array(regexp_replace(v, '[^0-9.]', '', 'g'), '.');
    RETURN ARRAY[
        COALESCE(NULLIF(parts[1], '')::INT, 0),
        COALESCE(NULLIF(parts[2], '')::INT, 0),
        COALESCE(NULLIF(parts[3], '')::INT, 0)
    ];
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- process_module_catalog: versioned registry of reusable sub-process definitions.
CREATE TABLE IF NOT EXISTS process_module_catalog (
    module_id           VARCHAR(255)  NOT NULL,
    version             VARCHAR(32)   NOT NULL,
    owning_tenant_id    UUID          NOT NULL,
    owning_definition_id UUID         NOT NULL,
    interface_schema    JSONB         NOT NULL DEFAULT '{}',
    exportable          BOOLEAN       NOT NULL DEFAULT TRUE,
    status              VARCHAR(32)   NOT NULL DEFAULT 'DRAFT'
                                 CHECK (status IN ('DRAFT', 'ACTIVE', 'DEPRECATED')),
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (module_id, version)
);

-- Unique module_id across all tenants (globally unique name).
CREATE UNIQUE INDEX IF NOT EXISTS idx_pmc_module_id_unique
    ON process_module_catalog (module_id);

-- Index for resolution: find highest ACTIVE version for a module + tenant.
CREATE INDEX IF NOT EXISTS idx_pmc_resolve
    ON process_module_catalog (module_id, owning_tenant_id, status, version);

-- process_module_catalog_share: cross-tenant visibility grants.
CREATE TABLE IF NOT EXISTS process_module_catalog_share (
    grant_id            UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    granting_tenant_id  UUID          NOT NULL,
    module_id           VARCHAR(255)  NOT NULL,
    receiving_tenant_id  UUID          NOT NULL,
    granted_at          TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    granted_by         UUID          NOT NULL,

    UNIQUE (granting_tenant_id, module_id, receiving_tenant_id)
);

CREATE INDEX IF NOT EXISTS idx_pmcs_receiving
    ON process_module_catalog_share (receiving_tenant_id, module_id);
