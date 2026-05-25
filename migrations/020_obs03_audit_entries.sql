-- 020_obs03_audit_entries.sql
-- OBS-03: Immutable audit log for successful state-changing API writes.
--
-- Design goals:
-- 1) Audit rows are appended in the same transaction as business writes.
-- 2) Any audit insert failure rolls back the whole mutation transaction.
-- 3) Audit rows are immutable (no UPDATE/DELETE allowed).

CREATE TABLE IF NOT EXISTS audit_entries (
    audit_id       UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id       UUID,
    action         TEXT        NOT NULL,
    resource_type  TEXT        NOT NULL,
    resource_id    UUID        NOT NULL,
    timestamp      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    before_state   JSONB,
    after_state    JSONB
);

CREATE INDEX IF NOT EXISTS idx_audit_entries_time
    ON audit_entries(timestamp DESC, audit_id DESC);

CREATE INDEX IF NOT EXISTS idx_audit_entries_actor_time
    ON audit_entries(actor_id, timestamp DESC, audit_id DESC);

CREATE INDEX IF NOT EXISTS idx_audit_entries_resource_time
    ON audit_entries(resource_type, resource_id, timestamp DESC, audit_id DESC);

CREATE OR REPLACE FUNCTION bpm_audit_try_uuid(input TEXT)
RETURNS UUID
LANGUAGE plpgsql
AS $$
BEGIN
    IF input IS NULL OR btrim(input) = '' THEN
        RETURN NULL;
    END IF;
    RETURN input::uuid;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION bpm_audit_immutable_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'audit_entries is immutable';
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_entries_no_update ON audit_entries;
CREATE TRIGGER trg_audit_entries_no_update
BEFORE UPDATE ON audit_entries
FOR EACH ROW EXECUTE FUNCTION bpm_audit_immutable_guard();

DROP TRIGGER IF EXISTS trg_audit_entries_no_delete ON audit_entries;
CREATE TRIGGER trg_audit_entries_no_delete
BEFORE DELETE ON audit_entries
FOR EACH ROW EXECUTE FUNCTION bpm_audit_immutable_guard();

CREATE OR REPLACE FUNCTION bpm_audit_action_for_change(
    table_name TEXT,
    op TEXT,
    old_row JSONB,
    new_row JSONB
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    old_status TEXT;
    new_status TEXT;
    old_assignee TEXT;
    new_assignee TEXT;
BEGIN
    IF table_name = 'process_definitions' THEN
        IF op = 'INSERT' THEN RETURN 'definition.create'; END IF;
        IF op = 'DELETE' THEN RETURN 'definition.delete'; END IF;

        old_status := old_row->>'status';
        new_status := new_row->>'status';
        IF old_status = 'DRAFT' AND new_status = 'ACTIVE' THEN RETURN 'definition.activate'; END IF;
        IF old_status = 'ACTIVE' AND new_status = 'DEPRECATED' THEN RETURN 'definition.deprecate'; END IF;
        IF old_status = 'DEPRECATED' AND new_status = 'ARCHIVED' THEN RETURN 'definition.archive'; END IF;
        RETURN 'definition.update';
    END IF;

    IF table_name = 'instance_projections' THEN
        IF op = 'INSERT' THEN RETURN 'instance.create'; END IF;
        IF op = 'DELETE' THEN RETURN 'instance.delete'; END IF;

        old_status := old_row->>'status';
        new_status := new_row->>'status';
        IF old_status <> 'CANCELLED' AND new_status = 'CANCELLED' THEN RETURN 'instance.cancel'; END IF;
        RETURN 'instance.update';
    END IF;

    IF table_name = 'tasks' THEN
        IF op = 'INSERT' THEN RETURN 'task.create'; END IF;
        IF op = 'DELETE' THEN RETURN 'task.delete'; END IF;

        old_status := old_row->>'status';
        new_status := new_row->>'status';
        old_assignee := old_row->>'assignee_ref';
        new_assignee := new_row->>'assignee_ref';

        IF old_status <> 'COMPLETED' AND new_status = 'COMPLETED' THEN RETURN 'task.complete'; END IF;
        IF (old_assignee IS NULL OR old_assignee = '') AND (new_assignee IS NOT NULL AND new_assignee <> '') THEN RETURN 'task.assign'; END IF;
        IF (old_assignee IS NOT NULL AND old_assignee <> '') AND (new_assignee IS NOT NULL AND new_assignee <> '') AND old_assignee <> new_assignee THEN RETURN 'task.reassign'; END IF;
        RETURN 'task.update';
    END IF;

    IF table_name = 'users' THEN
        IF op = 'INSERT' THEN RETURN 'user.create'; END IF;
        IF op = 'DELETE' THEN RETURN 'user.delete'; END IF;
        RETURN 'user.update';
    END IF;

    IF table_name = 'groups' THEN
        IF op = 'INSERT' THEN RETURN 'group.create'; END IF;
        IF op = 'DELETE' THEN RETURN 'group.delete'; END IF;
        RETURN 'group.update';
    END IF;

    IF table_name = 'group_members' THEN
        IF op = 'INSERT' THEN RETURN 'group.member_add'; END IF;
        IF op = 'DELETE' THEN RETURN 'group.member_remove'; END IF;
        RETURN 'group.member_update';
    END IF;

    IF table_name = 'api_tokens' THEN
        IF op = 'INSERT' THEN RETURN 'token.issue'; END IF;
        IF op = 'DELETE' THEN RETURN 'token.delete'; END IF;

        IF (old_row->>'revoked_at') IS NULL AND (new_row->>'revoked_at') IS NOT NULL THEN
            RETURN 'token.revoke';
        END IF;
        RETURN 'token.update';
    END IF;

    IF table_name = 'dead_letter_queue' THEN
        IF op = 'DELETE' THEN RETURN 'dlq.delete'; END IF;
        IF op = 'INSERT' THEN RETURN 'dlq.create'; END IF;

        old_status := old_row->>'status';
        new_status := new_row->>'status';
        IF old_status <> 'discarded' AND new_status = 'discarded' THEN RETURN 'dlq.discard'; END IF;
        IF new_status = 'retrying' THEN RETURN 'dlq.retry'; END IF;
        RETURN 'dlq.update';
    END IF;

    RETURN lower(table_name) || '.' || lower(op);
END;
$$;

CREATE OR REPLACE FUNCTION bpm_audit_resource_info(
    table_name TEXT,
    old_row JSONB,
    new_row JSONB,
    OUT resource_type TEXT,
    OUT resource_id UUID
)
LANGUAGE plpgsql
AS $$
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

    IF table_name = 'dead_letter_queue' THEN
        resource_type := 'dlq';
        resource_id := (src->>'id')::uuid;
        RETURN;
    END IF;

    resource_type := table_name;
    resource_id := NULL;
END;
$$;

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
    r_id UUID;
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

DROP TRIGGER IF EXISTS trg_bpm_audit_process_definitions ON process_definitions;
CREATE TRIGGER trg_bpm_audit_process_definitions
AFTER INSERT OR UPDATE OR DELETE ON process_definitions
FOR EACH ROW EXECUTE FUNCTION bpm_audit_on_mutation();

DROP TRIGGER IF EXISTS trg_bpm_audit_instance_projections ON instance_projections;
CREATE TRIGGER trg_bpm_audit_instance_projections
AFTER INSERT OR UPDATE OR DELETE ON instance_projections
FOR EACH ROW EXECUTE FUNCTION bpm_audit_on_mutation();

DROP TRIGGER IF EXISTS trg_bpm_audit_tasks ON tasks;
CREATE TRIGGER trg_bpm_audit_tasks
AFTER INSERT OR UPDATE OR DELETE ON tasks
FOR EACH ROW EXECUTE FUNCTION bpm_audit_on_mutation();

DROP TRIGGER IF EXISTS trg_bpm_audit_users ON users;
CREATE TRIGGER trg_bpm_audit_users
AFTER INSERT OR UPDATE OR DELETE ON users
FOR EACH ROW EXECUTE FUNCTION bpm_audit_on_mutation();

DROP TRIGGER IF EXISTS trg_bpm_audit_groups ON groups;
CREATE TRIGGER trg_bpm_audit_groups
AFTER INSERT OR UPDATE OR DELETE ON groups
FOR EACH ROW EXECUTE FUNCTION bpm_audit_on_mutation();

DROP TRIGGER IF EXISTS trg_bpm_audit_group_members ON group_members;
CREATE TRIGGER trg_bpm_audit_group_members
AFTER INSERT OR UPDATE OR DELETE ON group_members
FOR EACH ROW EXECUTE FUNCTION bpm_audit_on_mutation();

DROP TRIGGER IF EXISTS trg_bpm_audit_api_tokens ON api_tokens;
CREATE TRIGGER trg_bpm_audit_api_tokens
AFTER INSERT OR UPDATE OR DELETE ON api_tokens
FOR EACH ROW EXECUTE FUNCTION bpm_audit_on_mutation();

DROP TRIGGER IF EXISTS trg_bpm_audit_dead_letter_queue ON dead_letter_queue;
CREATE TRIGGER trg_bpm_audit_dead_letter_queue
AFTER INSERT OR UPDATE OR DELETE ON dead_letter_queue
FOR EACH ROW EXECUTE FUNCTION bpm_audit_on_mutation();
