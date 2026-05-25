-- 024_webhook_subscription_audit.sql
-- Extend OBS-03 audit coverage to webhook subscription mutations.

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

    IF table_name = 'webhook_subscriptions' THEN
        IF op = 'INSERT' THEN RETURN 'webhook_subscription.create'; END IF;
        IF op = 'DELETE' THEN RETURN 'webhook_subscription.delete'; END IF;
        RETURN 'webhook_subscription.update';
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

    IF table_name = 'webhook_subscriptions' THEN
        resource_type := 'webhook_subscription';
        resource_id := (src->>'id')::uuid;
        RETURN;
    END IF;

    resource_type := table_name;
    resource_id := NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_bpm_audit_webhook_subscriptions ON webhook_subscriptions;
CREATE TRIGGER trg_bpm_audit_webhook_subscriptions
AFTER INSERT OR UPDATE OR DELETE ON webhook_subscriptions
FOR EACH ROW EXECUTE FUNCTION bpm_audit_on_mutation();
