-- scope: public
-- GBL-140: ISS-0101 / GH-359 — drop tenant_default shadow tenant tables.
--
-- Root cause (see docs/issues/ISS-0101.json and
-- src/design/iss0101-gh359-shadow-tenant-table-fix.md): migrations/031_adp04b_
-- tenant_realm_binding.sql and migrations/050_tenant_hostnames.sql both lacked
-- a `-- scope: public` header, so migrationScope() defaulted them to
-- .all_schemas and their unqualified CREATE TABLE statements ran in every
-- tenant-schema pass (not just public), creating shadow `tenant` and
-- `tenant_hostnames` tables inside tenant_default. GBL-139 (and GBL-134/135/
-- 136 before it) already dropped these shadows once, but an accidental
-- `DROP SCHEMA tenant_default CASCADE` + full replay during
-- WF03-GH566-20260808 (2026-08-08 08:19Z, see GBL-138's own header)
-- re-applied 031 and 050_tenant_hostnames.sql against tenant_default,
-- resurrecting both shadows a second time. This migration removes them
-- again; this time the companion scope-header patch to 031 and
-- 050_tenant_hostnames.sql (same commit) closes the creation path so no
-- future reprovision (accidental or intentional) can recreate them, ending
-- the GBL-134→...→GBL-140 whack-a-mole for this specific table pair.
--
-- FK ordering: tenant_default.tenant_hostnames.tenant_id references
-- tenant_default.tenant.id. DROP tenant_hostnames (FK child) FIRST, then
-- tenant (FK parent) SECOND — reversing the order fails with
-- "cannot drop table tenant because other objects depend on it".
--
-- Scoped to tenant_default only (not looped over all tenant schemas like
-- GBL-134..139): every other tenant schema already had these shadows
-- removed by GBL-134/135/136, and the resurrection event only touched
-- tenant_default. Narrower scope reduces blast radius.
--
-- Idempotent: both DROPs are existence-guarded (information_schema.tables)
-- and use RESTRICT (never CASCADE), so an unexpected live FK dependent
-- raises a caught, logged NOTICE rather than silently destroying data, and
-- re-running this file against a database where the shadows are already
-- gone is a clean no-op.
DO $$
DECLARE
    v_hostnames_exists BOOLEAN;
    v_tenant_exists    BOOLEAN;
    v_dropped          INT := 0;
BEGIN
    -- Step 1: DROP tenant_default.tenant_hostnames (FK child — must go first).
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
         WHERE table_schema = 'tenant_default' AND table_name = 'tenant_hostnames'
    ) INTO v_hostnames_exists;
    IF v_hostnames_exists THEN
        BEGIN
            DROP TABLE tenant_default.tenant_hostnames RESTRICT;
            v_dropped := v_dropped + 1;
            RAISE NOTICE 'GBL-140: dropped tenant_default.tenant_hostnames (shadow).';
        EXCEPTION WHEN dependent_objects_still_exist THEN
            RAISE NOTICE 'GBL-140: SKIP tenant_default.tenant_hostnames — unexpected FK dependent.';
        END;
    END IF;

    -- Step 2: DROP tenant_default.tenant (FK parent — safe after step 1).
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
         WHERE table_schema = 'tenant_default' AND table_name = 'tenant'
    ) INTO v_tenant_exists;
    IF v_tenant_exists THEN
        BEGIN
            DROP TABLE tenant_default.tenant RESTRICT;
            v_dropped := v_dropped + 1;
            RAISE NOTICE 'GBL-140: dropped tenant_default.tenant (shadow).';
        EXCEPTION WHEN dependent_objects_still_exist THEN
            RAISE NOTICE 'GBL-140: SKIP tenant_default.tenant — unexpected FK dependent.';
        END;
    END IF;

    RAISE NOTICE 'GBL-140: % shadow(s) dropped from tenant_default.', v_dropped;
END $$;
