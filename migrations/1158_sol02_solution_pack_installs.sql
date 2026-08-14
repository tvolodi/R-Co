-- 1158_sol02_solution_pack_installs.sql
-- SOL-02: per-tenant solution pack installation metadata.
-- scope: tenant_only

CREATE TABLE IF NOT EXISTS solution_pack_installs (
    id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    pack_id        TEXT        NOT NULL,
    pack_version   TEXT        NOT NULL,
    schema_version TEXT        NOT NULL,
    installed_by   UUID        NOT NULL,
    installed_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_sol_pack_installs_pack_version
        UNIQUE (pack_id, pack_version)
);

CREATE INDEX IF NOT EXISTS idx_sol_pack_installs_pack_id
    ON solution_pack_installs (pack_id);
