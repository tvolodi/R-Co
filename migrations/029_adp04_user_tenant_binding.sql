-- 029_adp04_user_tenant_binding.sql
-- ADP-04: Bind identity users to a single tenant and enforce same-tenant
-- group membership semantics.

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS tenant_id UUID NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000';

ALTER TABLE groups
    ADD COLUMN IF NOT EXISTS tenant_id UUID NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000';

CREATE INDEX IF NOT EXISTS idx_users_tenant_status_created
    ON users(tenant_id, status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_groups_tenant_name
    ON groups(tenant_id, name);

CREATE INDEX IF NOT EXISTS idx_group_members_tenant_group_added
    ON group_members(group_id, added_at DESC, user_id DESC);

CREATE INDEX IF NOT EXISTS idx_group_members_tenant_user
    ON group_members(user_id);
