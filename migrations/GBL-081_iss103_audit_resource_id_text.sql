-- GBL-081_iss103_audit_resource_id_text.sql
-- ISS-103: Change audit_entries.resource_id from UUID to TEXT
-- 
-- Motivation: Some resources are text-keyed (role_name, event_type, definition names)
-- and cannot be stored in a UUID NOT NULL column. This migration enables auditing
-- of such text-keyed resources by changing resource_id to TEXT NOT NULL.

-- Idempotent migration: check if resource_id is already TEXT
DO $$
DECLARE
    v_col_type TEXT;
    v_table_exists BOOLEAN;
    v_schema TEXT;
BEGIN
    SELECT current_schema() INTO v_schema;

    -- Check if audit_entries still exists in current schema
    SELECT EXISTS (
        SELECT 1 
        FROM information_schema.tables 
        WHERE table_schema = v_schema 
          AND table_name = 'audit_entries'
    ) INTO v_table_exists;

    IF NOT v_table_exists THEN
        RAISE NOTICE 'GBL-081: audit_entries does not exist in schema % — skipping migration.', v_schema;
        RETURN;
    END IF;

    -- Check current type
    SELECT data_type INTO v_col_type
    FROM information_schema.columns
    WHERE table_schema = v_schema
      AND table_name = 'audit_entries'
      AND column_name = 'resource_id';
    
    -- If already TEXT, skip
    IF v_col_type = 'text' THEN
        RAISE NOTICE 'audit_entries.resource_id is already TEXT in schema %; skipping migration', v_schema;
    ELSE
        -- Add temporary TEXT column
        EXECUTE format('ALTER TABLE %I.audit_entries ADD COLUMN resource_id_text TEXT', v_schema);
        -- Disable immutability guard during migration backfill
        EXECUTE format('ALTER TABLE %I.audit_entries DISABLE TRIGGER ALL', v_schema);
        -- Copy and convert UUID values to lowercase TEXT
        EXECUTE format('UPDATE %I.audit_entries SET resource_id_text = LOWER(resource_id::TEXT)', v_schema);
        -- Re-enable triggers
        EXECUTE format('ALTER TABLE %I.audit_entries ENABLE TRIGGER ALL', v_schema);
        -- Drop old UUID column
        EXECUTE format('ALTER TABLE %I.audit_entries DROP COLUMN resource_id', v_schema);
        -- Rename new column to resource_id
        EXECUTE format('ALTER TABLE %I.audit_entries RENAME COLUMN resource_id_text TO resource_id', v_schema);
        -- Restore NOT NULL constraint
        EXECUTE format('ALTER TABLE %I.audit_entries ALTER COLUMN resource_id SET NOT NULL', v_schema);
        
        RAISE NOTICE 'Successfully migrated %I.audit_entries.resource_id from UUID to TEXT', v_schema;

        -- Recreate indexes for the TEXT column
        EXECUTE format('DROP INDEX IF EXISTS %I.idx_audit_entries_resource_time', v_schema);
        EXECUTE format('CREATE INDEX idx_audit_entries_resource_time ON %I.audit_entries (resource_type, resource_id, timestamp DESC, audit_id DESC)', v_schema, v_schema);
        EXECUTE format('CREATE INDEX IF NOT EXISTS idx_audit_resource ON %I.audit_entries (resource_id)', v_schema, v_schema);
    END IF;

    -- Update functions (always, in case they were UUID-bound)
    
    -- 1. bpm_audit_resource_info
    EXECUTE format('DROP FUNCTION IF EXISTS %I.bpm_audit_resource_info(text,jsonb,jsonb)', v_schema);
    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.bpm_audit_resource_info(
            table_name TEXT,
            old_row JSONB,
            new_row JSONB,
            OUT resource_type TEXT,
            OUT resource_id TEXT
        )
        LANGUAGE plpgsql
        AS $inner$
        DECLARE
            src JSONB;
        BEGIN
            src := COALESCE(new_row, old_row);
            resource_type := table_name;
            
            IF table_name = ''definitions'' OR table_name = ''process_definitions'' THEN
                resource_id := src->>''id'';
            ELSIF table_name = ''instances'' OR table_name = ''instance_projections'' THEN
                resource_id := src->>''instance_id'';
            ELSIF table_name = ''tasks'' THEN
                resource_id := src->>''id'';
            ELSIF table_name = ''users'' THEN
                resource_id := src->>''id'';
            ELSIF table_name = ''groups'' THEN
                resource_id := src->>''id'';
            ELSIF table_name = ''group_members'' THEN
                resource_id := src->>''user_id'';
            ELSIF table_name = ''api_tokens'' THEN
                resource_id := src->>''id'';
            ELSIF table_name = ''dead_letter_queue'' OR table_name = ''dead_letter_items'' THEN
                resource_id := src->>''id'';
            ELSIF table_name = ''entities'' THEN
                resource_id := src->>''id'';
            ELSE
                resource_id := src->>''id'';
            END IF;
            
            -- Canonicalize to lowercase if it looks like a hex string/UUID
            IF resource_id ~ ''^[0-9a-fA-F-]+$'' THEN
                resource_id := LOWER(resource_id);
            END IF;
        END $inner$;
    ', v_schema, v_schema);

    -- 2. bpm_audit_on_mutation
    EXECUTE format('
        CREATE OR REPLACE FUNCTION %I.bpm_audit_on_mutation()
        RETURNS TRIGGER
        LANGUAGE plpgsql
        AS $inner$
        DECLARE
            old_row JSONB;
            new_row JSONB;
            action_name TEXT;
            actor_uuid UUID;
            r_type TEXT;
            r_id TEXT;
        BEGIN
            old_row := CASE WHEN TG_OP IN (''UPDATE'', ''DELETE'') THEN to_jsonb(OLD) ELSE NULL END;
            new_row := CASE WHEN TG_OP IN (''INSERT'', ''UPDATE'') THEN to_jsonb(NEW) ELSE NULL END;

            SELECT resource_type, resource_id
            INTO r_type, r_id
            FROM bpm_audit_resource_info(TG_TABLE_NAME, old_row, new_row);

            IF r_id IS NULL THEN
                IF TG_OP = ''DELETE'' THEN
                    RETURN OLD;
                END IF;
                RETURN NEW;
            END IF;

            action_name := COALESCE(
                NULLIF(current_setting(''bpm.audit_action'', true), ''''),
                bpm_audit_action_for_change(TG_TABLE_NAME, TG_OP, old_row, new_row)
            );

            actor_uuid := bpm_audit_try_uuid(current_setting(''bpm.actor_id'', true));

            IF actor_uuid IS NULL THEN
                IF TG_TABLE_NAME = ''process_definitions'' THEN
                    actor_uuid := bpm_audit_try_uuid(COALESCE(new_row->>''created_by'', old_row->>''created_by''));
                ELSIF TG_TABLE_NAME = ''tasks'' THEN
                    actor_uuid := bpm_audit_try_uuid(COALESCE(new_row->>''completed_by'', old_row->>''completed_by''));
                ELSIF TG_TABLE_NAME = ''users'' THEN
                    actor_uuid := bpm_audit_try_uuid(COALESCE(new_row->>''id'', old_row->>''id''));
                ELSIF TG_TABLE_NAME = ''api_tokens'' THEN
                    actor_uuid := bpm_audit_try_uuid(COALESCE(new_row->>''user_id'', old_row->>''user_id''));
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

            IF TG_OP = ''DELETE'' THEN
                RETURN OLD;
            END IF;
            RETURN NEW;
        END $inner$;
    ', v_schema, v_schema);

END $$;
