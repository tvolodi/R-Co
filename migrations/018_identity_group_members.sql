-- 018_identity_group_members.sql
-- IDN-02: group membership join model for task assignment and group management.
-- Additive only: create the membership join table and supporting indexes.

CREATE TABLE IF NOT EXISTS group_members (
    group_id    UUID        NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    user_id     UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    added_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (group_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_group_members_group_added
    ON group_members(group_id, added_at DESC, user_id DESC);

CREATE INDEX IF NOT EXISTS idx_group_members_user
    ON group_members(user_id);
