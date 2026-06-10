-- Migration: 040_oidc10_role_source.sql
-- OIDC-10: Add role_source column to user_roles for OIDC reconciliation.
--
-- Adds a column to distinguish OIDC-sourced role bindings (subject to
-- reconciliation on every OIDC auth) from locally-assigned bindings
-- (preserved across reconciliation).
--
-- Also ensures a UNIQUE (user_id, role_id) constraint exists so that
-- the OIDC-10 insertOidcRoleBinding can use ON CONFLICT DO NOTHING.

ALTER TABLE user_roles
ADD COLUMN IF NOT EXISTS role_source TEXT NOT NULL DEFAULT 'internal'
CHECK (role_source IN ('internal', 'oidc'));

COMMENT ON COLUMN user_roles.role_source IS
  'oidc = sourced from OIDC token claims and subject to reconciliation;'
  ' internal = assigned locally via IDN-03, preserved across reconciliation';

-- Ensure unique constraint exists for idempotent inserts.
-- Uses a DO block for PG < 14 compatibility (ALTER TABLE ... ADD CONSTRAINT
-- IF NOT EXISTS is PG 14+).
-- NOTE (TNT-02): connamespace check uses current_schema() so that this
-- migration remains idempotent when applied inside per-tenant schemas
-- (search_path = <tenant_schema>,public) as well as in public directly.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'user_roles_user_id_role_id_key'
          AND connamespace = (SELECT oid FROM pg_namespace WHERE nspname = current_schema())
    ) THEN
        ALTER TABLE user_roles ADD CONSTRAINT user_roles_user_id_role_id_key UNIQUE (user_id, role_id);
    END IF;
END $$;
