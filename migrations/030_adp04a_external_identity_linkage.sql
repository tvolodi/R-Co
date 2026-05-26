-- 030_adp04a_external_identity_linkage.sql
-- ADP-04a: Add external identity linkage fields for OIDC subject mapping.

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS external_id TEXT;

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS external_realm TEXT;

ALTER TABLE users
    ADD COLUMN IF NOT EXISTS auth_source TEXT NOT NULL DEFAULT 'internal';

UPDATE users
SET auth_source = 'internal'
WHERE auth_source IS NULL;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'users_auth_source_check'
    ) THEN
        ALTER TABLE users
            ADD CONSTRAINT users_auth_source_check CHECK (auth_source IN ('internal', 'oidc'));
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'users_external_identity_shape_check'
    ) THEN
        ALTER TABLE users
            ADD CONSTRAINT users_external_identity_shape_check CHECK (
                (auth_source = 'internal' AND external_id IS NULL AND external_realm IS NULL)
                OR
                (
                    auth_source = 'oidc'
                    AND external_id IS NOT NULL
                    AND external_realm IS NOT NULL
                    AND btrim(external_id) <> ''
                    AND btrim(external_realm) <> ''
                )
            );
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS idx_users_external_identity_unique
    ON users(external_realm, external_id)
    WHERE external_id IS NOT NULL;