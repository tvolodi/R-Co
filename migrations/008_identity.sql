-- 008_identity.sql
-- Stage 4/5: IDN-01..IDN-07 — Users, groups, roles, API tokens, sessions
-- Adapted from ai-dala-forge auth migrations for BPM Platform
-- Sources: 20260118_create_users.sql, 20260120_create_roles.sql,
--          20260119_create_sessions.sql, 20260216000000_create_groups.sql

-- ── Users ─────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS users (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    email               TEXT        NOT NULL UNIQUE,
    display_name        TEXT        NOT NULL,
    password_hash       TEXT        NOT NULL,
    is_active           BOOLEAN     NOT NULL DEFAULT true,

    -- Brute-force lockout
    failed_attempts     INTEGER     NOT NULL DEFAULT 0,
    locked_until        TIMESTAMPTZ,

    -- Metadata
    last_login_at       TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_users_email  ON users(email);
CREATE INDEX IF NOT EXISTS idx_users_active ON users(is_active) WHERE is_active = true;

-- ── Roles ─────────────────────────────────────────────────────────────────────
-- IDN-05: RBAC role definitions

CREATE TABLE IF NOT EXISTS roles (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT        NOT NULL UNIQUE,
    description TEXT,
    is_system   BOOLEAN     NOT NULL DEFAULT false,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- IDN-06: permissions per role (resource + action scoped)
CREATE TABLE IF NOT EXISTS role_permissions (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    role_id     UUID        NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    resource    TEXT        NOT NULL,   -- 'instances' | 'definitions' | 'tasks' | '*'
    action      TEXT        NOT NULL,   -- 'read' | 'write' | 'admin' | '*'
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (role_id, resource, action)
);

-- IDN-05: users ↔ roles (many-to-many)
CREATE TABLE IF NOT EXISTS user_roles (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role_id     UUID        NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    granted_by  UUID        REFERENCES users(id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (user_id, role_id)
);

CREATE INDEX IF NOT EXISTS idx_rp_role       ON role_permissions(role_id);
CREATE INDEX IF NOT EXISTS idx_ur_user       ON user_roles(user_id);
CREATE INDEX IF NOT EXISTS idx_ur_role       ON user_roles(role_id);

-- ── Groups ────────────────────────────────────────────────────────────────────
-- IDN-05: group-based assignment for HUMAN_TASK assignee_type = GROUP

CREATE TABLE IF NOT EXISTS groups (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT        NOT NULL UNIQUE,
    display_name    TEXT        NOT NULL,
    description     TEXT,
    is_system       BOOLEAN     NOT NULL DEFAULT false,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS user_groups (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    group_id    UUID        NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    added_by    UUID        REFERENCES users(id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (user_id, group_id)
);

CREATE TABLE IF NOT EXISTS group_roles (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id    UUID        NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    role_id     UUID        NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    assigned_by UUID        REFERENCES users(id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (group_id, role_id)
);

CREATE INDEX IF NOT EXISTS idx_ug_user  ON user_groups(user_id);
CREATE INDEX IF NOT EXISTS idx_ug_group ON user_groups(group_id);
CREATE INDEX IF NOT EXISTS idx_gr_group ON group_roles(group_id);

-- ── Sessions ──────────────────────────────────────────────────────────────────
-- IDN-04: JWT sessions with refresh tokens and revocation

CREATE TABLE IF NOT EXISTS sessions (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_id            UUID        NOT NULL UNIQUE,     -- jti claim
    refresh_token_hash  TEXT        NOT NULL,
    device_info         JSONB       NOT NULL DEFAULT '{}',
    ip_address          INET        NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_used_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at          TIMESTAMPTZ NOT NULL,
    revoked_at          TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_sess_user    ON sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_sess_token   ON sessions(token_id);
CREATE INDEX IF NOT EXISTS idx_sess_expires ON sessions(expires_at);

-- ── API Tokens ────────────────────────────────────────────────────────────────
-- IDN-04: long-lived API tokens for service accounts
-- Token value is hashed (SHA-256); raw value shown once at creation.

CREATE TABLE IF NOT EXISTS api_tokens (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID        NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name        TEXT        NOT NULL,
    token_hash  TEXT        NOT NULL UNIQUE,   -- SHA-256 hex of raw token
    last_used_at TIMESTAMPTZ,
    expires_at  TIMESTAMPTZ,
    revoked_at  TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_at_user  ON api_tokens(user_id);
CREATE INDEX IF NOT EXISTS idx_at_hash  ON api_tokens(token_hash);

-- ── Bootstrap seed roles ──────────────────────────────────────────────────────
INSERT INTO roles (name, description, is_system) VALUES
    ('PLATFORM_ADMIN',   'Full platform access; cannot be deleted', true),
    ('PROCESS_DESIGNER', 'Create/modify process definitions', true),
    ('PROCESS_OPERATOR', 'Manage instances and tasks', true),
    ('VIEWER',           'Read-only access to instances and definitions', true)
ON CONFLICT (name) DO NOTHING;
