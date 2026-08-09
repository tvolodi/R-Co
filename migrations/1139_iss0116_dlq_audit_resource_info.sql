-- 1139_iss0116_dlq_audit_resource_info.sql
-- ISS-0116 / GH-379: dead_letter_items not handled in per-tenant
-- bpm_audit_resource_info — audit trigger skips DLQ mutations.
--
-- Root cause: GBL-121_fix_audit_chain_resource_id_text.sql added
-- dead_letter_items handling to bpm_audit_resource_info, but
-- GBL-* migrations are blanket-skipped for tenant schemas by
-- Migrations.runForSchema() (see GBL-133 comment and migrations.zig).
-- Tenant schemas therefore retain the migration-020 version of the
-- function, which only recognises dead_letter_queue (the table's original
-- name). After migration 072 renamed dead_letter_queue → dead_letter_items,
-- the trigger fires correctly but bpm_audit_resource_info returns
-- resource_id = NULL for dead_letter_items, causing bpm_audit_on_mutation
-- to skip the INSERT into audit_entries without error.
--
-- Fix: recreate per-tenant bpm_audit_resource_info with dead_letter_items case.
-- Guard: skip if current schema is 'public' — GBL-121 already fixed public,
-- and the public version returns TEXT (different signature — can't CREATE OR REPLACE).

DO $$
DECLARE
    v_schema TEXT;
BEGIN
    SELECT current_schema() INTO v_schema;

    IF v_schema = 'public' THEN
        RAISE NOTICE '1139: public schema already fixed by GBL-121 — skipping';
        RETURN;
    END IF;

    -- DROP and recreate because CREATE OR REPLACE cannot change return type.
    -- The tenant schema version returns UUID; we preserve that signature.
    EXECUTE format('DROP FUNCTION IF EXISTS %I.bpm_audit_resource_info(text, jsonb, jsonb)', v_schema);

    EXECUTE format(
        $body$
        CREATE FUNCTION %I.bpm_audit_resource_info(
            table_name TEXT,
            old_row JSONB,
            new_row JSONB,
            OUT resource_type TEXT,
            OUT resource_id UUID
        )
        LANGUAGE plpgsql
        AS $fn$
        DECLARE
            src JSONB;
        BEGIN
            src := COALESCE(new_row, old_row);
            IF table_name = 'process_definitions' THEN
                resource_type := 'definition';
                resource_id := (src->>'id')::uuid;
                RETURN;
            END IF;
            IF table_name = 'instance_projections' THEN
                resource_type := 'instance';
                resource_id := (src->>'instance_id')::uuid;
                RETURN;
            END IF;
            IF table_name = 'tasks' THEN
                resource_type := 'task';
                resource_id := (src->>'id')::uuid;
                RETURN;
            END IF;
            IF table_name = 'users' THEN
                resource_type := 'user';
                resource_id := (src->>'id')::uuid;
                RETURN;
            END IF;
            IF table_name = 'groups' THEN
                resource_type := 'group';
                resource_id := (src->>'id')::uuid;
                RETURN;
            END IF;
            IF table_name = 'group_members' THEN
                resource_type := 'group_member';
                resource_id := (src->>'user_id')::uuid;
                RETURN;
            END IF;
            IF table_name = 'api_tokens' THEN
                resource_type := 'token';
                resource_id := (src->>'id')::uuid;
                RETURN;
            END IF;
            IF table_name = 'dead_letter_queue' OR table_name = 'dead_letter_items' THEN
                resource_type := 'dlq';
                resource_id := (src->>'id')::uuid;
                RETURN;
            END IF;
            IF table_name = 'webhook_subscriptions' THEN
                resource_type := 'webhook_subscription';
                resource_id := (src->>'id')::uuid;
                RETURN;
            END IF;
            resource_type := table_name;
            resource_id := NULL;
        END $fn$
        $body$,
        v_schema
    );

    RAISE NOTICE '1139: updated %.bpm_audit_resource_info — added dead_letter_items case', v_schema;
END $$;


