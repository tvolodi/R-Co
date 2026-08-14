-- 1160_sol_definition_install_fk.sql
-- SOL-02/03: link process_definitions back to the solution pack install that
-- created them.  NULL for definitions created via normal PD-01 flow.
-- scope: tenant_only

ALTER TABLE process_definitions
    ADD COLUMN IF NOT EXISTS solution_pack_install_id UUID
        REFERENCES solution_pack_installs(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_proc_def_pack_install
    ON process_definitions (solution_pack_install_id)
    WHERE solution_pack_install_id IS NOT NULL;
