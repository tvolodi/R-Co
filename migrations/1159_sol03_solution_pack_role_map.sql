-- 1159_sol03_solution_pack_role_map.sql
-- SOL-03: per-tenant solution pack role-binding checklist.
-- scope: tenant_only

CREATE TABLE IF NOT EXISTS solution_pack_role_map (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    install_id  UUID        NOT NULL
                                REFERENCES solution_pack_installs(id) ON DELETE CASCADE,
    role_name   TEXT        NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT uq_sol_pack_role_map_install_role
        UNIQUE (install_id, role_name)
);

CREATE INDEX IF NOT EXISTS idx_sol_pack_role_map_role
    ON solution_pack_role_map (role_name);
