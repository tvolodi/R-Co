-- 1162_plc01_module_id_unique_per_tenant.sql
-- PLC-01 fix: module_id is unique PER PUBLISHING TENANT, not globally.
-- PLC-01 spec: "module_id (stable name, unique per publishing tenant)".
-- Multiple ACTIVE versions of the same module_id per tenant are allowed.
-- The original idx_pmc_module_id_unique (global) contradicted the spec and
-- blocked semver evolution under the same module_id within a tenant.
-- PRIMARY KEY (module_id, version) already provides row uniqueness.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'public'
          AND tablename = 'process_module_catalog'
          AND indexname = 'idx_pmc_module_id_unique'
    ) THEN
        DROP INDEX public.idx_pmc_module_id_unique;
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE schemaname = 'public'
          AND tablename = 'process_module_catalog'
          AND indexname = 'idx_pmc_module_id_tenant_unique'
    ) THEN
        DROP INDEX public.idx_pmc_module_id_tenant_unique;
    END IF;
END $$;

-- No replacement index: PRIMARY KEY (module_id, version) already provides
-- row uniqueness, and PLC-01 spec does not impose additional uniqueness
-- beyond row-level primary key.