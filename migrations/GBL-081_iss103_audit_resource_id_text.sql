-- 083_iss103_audit_resource_id_text.sql
-- ISS-103: Change audit_entries.resource_id from UUID to TEXT
-- 
-- Motivation: Some resources are text-keyed (role_name, event_type, definition names)
-- and cannot be stored in a UUID NOT NULL column. This migration enables auditing
-- of such text-keyed resources by changing resource_id to TEXT NOT NULL.

-- Idempotent migration: check if resource_id is already TEXT
DO $$
DECLARE
    v_col_type TEXT;
BEGIN
    -- Check current type
    SELECT data_type INTO v_col_type
    FROM information_schema.columns
    WHERE table_schema = current_schema()
      AND table_name = 'audit_entries'
      AND column_name = 'resource_id';
    
    -- If already TEXT, skip
    IF v_col_type = 'text' THEN
        RAISE NOTICE 'audit_entries.resource_id is already TEXT; skipping migration';
        RETURN;
    END IF;
    
    -- Add temporary TEXT column
    ALTER TABLE audit_entries
        ADD COLUMN resource_id_text TEXT;
    
    -- Copy and convert UUID values to lowercase TEXT
    UPDATE audit_entries
    SET resource_id_text = LOWER(resource_id::TEXT);
    
    -- Drop old UUID column
    ALTER TABLE audit_entries
        DROP COLUMN resource_id;
    
    -- Rename new column to resource_id
    ALTER TABLE audit_entries
        RENAME COLUMN resource_id_text TO resource_id;
    
    -- Restore NOT NULL constraint
    ALTER TABLE audit_entries
        ALTER COLUMN resource_id SET NOT NULL;
    
    RAISE NOTICE 'Successfully migrated audit_entries.resource_id from UUID to TEXT';
END $$;

-- Recreate indexes for the TEXT column
DROP INDEX IF EXISTS idx_audit_entries_resource_time;
CREATE INDEX idx_audit_entries_resource_time
    ON audit_entries (resource_type, resource_id, timestamp DESC, audit_id DESC);

-- Note: idx_audit_entries_tenant_resource_time is not recreated because
-- the audit_entries table does not have a tenant_id column in this schema version

-- Create simple index on resource_id for point lookups
CREATE INDEX IF NOT EXISTS idx_audit_resource
    ON audit_entries (resource_id);

-- Update bpm_audit_resource_info to return TEXT resource_id
-- Must drop first because return type is changing
DROP FUNCTION IF EXISTS bpm_audit_resource_info(text, jsonb, jsonb);

CREATE FUNCTION bpm_audit_resource_info(
    table_name TEXT,
    old_row JSONB,
    new_row JSONB,
    OUT resource_type TEXT,
    OUT resource_id TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    src JSONB;
BEGIN
    src := COALESCE(new_row, old_row);

    IF table_name = 'process_definitions' THEN
        resource_type := 'definition';
        resource_id := LOWER(((src->>'id')::uuid)::TEXT);
        RETURN;
    END IF;

    IF table_name = 'instance_projections' THEN
        resource_type := 'instance';
        resource_id := LOWER(((src->>'instance_id')::uuid)::TEXT);
        RETURN;
    END IF;

    IF table_name = 'tasks' THEN
        resource_type := 'task';
        resource_id := LOWER(((src->>'id')::uuid)::TEXT);
        RETURN;
    END IF;

    IF table_name = 'users' THEN
        resource_type := 'user';
        resource_id := LOWER(((src->>'id')::uuid)::TEXT);
        RETURN;
    END IF;

    IF table_name = 'groups' THEN
        resource_type := 'group';
        resource_id := LOWER(((src->>'id')::uuid)::TEXT);
        RETURN;
    END IF;

    IF table_name = 'group_members' THEN
        resource_type := 'group_member';
        resource_id := LOWER(((src->>'user_id')::uuid)::TEXT);
        RETURN;
    END IF;

    IF table_name = 'api_tokens' THEN
        resource_type := 'token';
        resource_id := LOWER(((src->>'id')::uuid)::TEXT);
        RETURN;
    END IF;

    IF table_name = 'dead_letter_queue' THEN
        resource_type := 'dlq';
        resource_id := LOWER(((src->>'id')::uuid)::TEXT);
        RETURN;
    END IF;

    resource_type := table_name;
    resource_id := NULL;
END;
$$;

-- Update bpm_audit_on_mutation to use TEXT for resource_id
CREATE OR REPLACE FUNCTION bpm_audit_on_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    old_row JSONB;
    new_row JSONB;
    action_name TEXT;
    actor_uuid UUID;
    r_type TEXT;
    r_id TEXT;  -- Changed from UUID to TEXT
BEGIN
    old_row := CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) ELSE NULL END;
    new_row := CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) ELSE NULL END;

    SELECT resource_type, resource_id
    INTO r_type, r_id
    FROM bpm_audit_resource_info(TG_TABLE_NAME, old_row, new_row);

    IF r_id IS NULL THEN
        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        END IF;
        RETURN NEW;
    END IF;

    action_name := COALESCE(
        NULLIF(current_setting('bpm.audit_action', true), ''),
        bpm_audit_action_for_change(TG_TABLE_NAME, TG_OP, old_row, new_row)
    );

    actor_uuid := bpm_audit_try_uuid(current_setting('bpm.actor_id', true));

    IF actor_uuid IS NULL THEN
        IF TG_TABLE_NAME = 'process_definitions' THEN
            actor_uuid := bpm_audit_try_uuid(COALESCE(new_row->>'created_by', old_row->>'created_by'));
        ELSIF TG_TABLE_NAME = 'tasks' THEN
            actor_uuid := bpm_audit_try_uuid(COALESCE(new_row->>'completed_by', old_row->>'completed_by'));
        ELSIF TG_TABLE_NAME = 'users' THEN
            actor_uuid := bpm_audit_try_uuid(COALESCE(new_row->>'id', old_row->>'id'));
        ELSIF TG_TABLE_NAME = 'api_tokens' THEN
            actor_uuid := bpm_audit_try_uuid(COALESCE(new_row->>'user_id', old_row->>'user_id'));
        END IF;
    END IF;

    INSERT INTO audit_entries (
        actor_id,
        action,
        resource_type,
        resource_id,
        before_state,
        after_state
    ) VALUES (
        actor_uuid,
        action_name,
        r_type,
        r_id,
        old_row,
        new_row
    );

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;
