-- 017_identity_user_registry.sql
-- IDN-01: User registry fields and status lifecycle support.
-- Additive only: extend existing users table used by identity/auth.

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS username TEXT;

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS status TEXT;

UPDATE users
SET username = COALESCE(username, 'user-' || replace(id::text, '-', ''))
WHERE username IS NULL;

UPDATE users
SET status = COALESCE(status, CASE WHEN is_active THEN 'ACTIVE' ELSE 'INACTIVE' END)
WHERE status IS NULL;

ALTER TABLE users
    ALTER COLUMN username SET NOT NULL;

ALTER TABLE users
    ALTER COLUMN status SET NOT NULL;

ALTER TABLE users
    ALTER COLUMN status SET DEFAULT 'ACTIVE';

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'users_status_check'
    ) THEN
        ALTER TABLE users
            ADD CONSTRAINT users_status_check CHECK (status IN ('ACTIVE', 'INACTIVE'));
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS idx_users_username_unique ON users(username);
CREATE INDEX IF NOT EXISTS idx_users_status ON users(status);
