-- 1139_iss0116_audit_dlq_rename_tenant_functions.sql
--
-- ISS-0116 / GitHub #379 — TC-OBS-05-INT-02/03 fail with the audit row for
-- dlq.retry / dlq.discard never being inserted (COUNT(*) = 0), even though
-- the store-layer transitions themselves (dead_letter_items UPDATE/DELETE)
-- are correct and atomic.
--
-- Root cause: bpm_audit_resource_info and bpm_audit_action_for_change were
-- fixed to recognise the dead_letter_queue -> dead_letter_items rename
-- (migration 072_tnt01_rename_legacy_tables.sql) only in the PUBLIC schema:
--   - GBL-121_fix_audit_chain_resource_id_text.sql added a 'dead_letter_items'
--     branch to bpm_audit_resource_info AND widened resource_id to TEXT, but
--     GBL-prefixed migrations only ever apply to `public`
--     (src/db/migrations.zig's `Migrations.run()` == runForSchema("public")).
--   - bpm_audit_action_for_change was NEVER given a 'dead_letter_items'
--     branch anywhere — only 020_obs03_audit_entries.sql and
--     024_webhook_subscription_audit.sql (both 'dead_letter_queue'-only)
--     ever defined it, and 024 (numeric, applies everywhere) is the last
--     writer.
--
-- audit_entries and dead_letter_items are PER_TENANT tables (canonical home
-- tenant_default, per the dual-schema classification in ISS-0185's cleanup:
-- GBL-112 drops the legacy `public` copies entirely). The trigger
-- trg_bpm_audit_dead_letter_queue survived the table rename (Postgres binds
-- triggers by OID, not name) and still fires on every dead_letter_items
-- mutation with TG_TABLE_NAME = 'dead_letter_items' — but in tenant_default,
-- bpm_audit_resource_info(table_name, ...) still only recognises the literal
-- 'dead_letter_queue' (GBL-121's fix never reached this schema) and falls
-- through to `resource_type := table_name; resource_id := NULL;`.
-- bpm_audit_on_mutation() then hits `IF r_id IS NULL THEN RETURN; END IF;`
-- and the audit INSERT is silently skipped — the dlq.retry/dlq.discard
-- transitions happen correctly in dead_letter_items, but leave no audit
-- trail, exactly matching the symptom TC-OBS-05-INT-02/03 assert against.
--
-- Confirmed live in bpm_test: tenant_default.bpm_audit_resource_info has
-- signature (text,jsonb,jsonb) OUT resource_id UUID (the 024 shape) while
-- public.bpm_audit_resource_info has OUT resource_id TEXT (the GBL-121
-- shape) — two schemas, two different, out-of-sync definitions.
--
-- This migration is a PLAIN NUMERIC file (not GBL-prefixed) specifically so
-- Migrations.runForSchema() applies it to every schema, including
-- tenant_default and any future tenant_* schema — matching the same
-- unqualified, current-schema-relative convention already used by
-- 020_obs03_audit_entries.sql, 024_webhook_subscription_audit.sql, and
-- GBL-121 itself (whose body contains no schema-qualification or per-schema
-- loop; only the runner's search_path scoping decides which schema it
-- lands in). Re-running this migration is safe: CREATE OR REPLACE FUNCTION
-- for bpm_audit_action_for_change (signature unchanged, TEXT return, no OUT
-- param type change) and a DROP FUNCTION IF EXISTS + CREATE for
-- bpm_audit_resource_info (matching GBL-121's own drop-then-create pattern,
-- required because the OUT parameter type is changing from UUID to TEXT
-- in tenant_default).
--
-- Non-destructive: no DROP TABLE / DROP COLUMN / TRUNCATE.

-- ---------------------------------------------------------------------------
-- 1. bpm_audit_action_for_change: add the 'dead_letter_items' branch
--    alongside the existing 'dead_letter_queue' branch (both retained so a
--    schema that has not yet had its table renamed still gets useful action
--    names). Otherwise identical to 024_webhook_subscription_audit.sql.
-- ---------------------------------------------------------------------------
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

    IF table_name = 'dead_letter_queue' OR table_name = 'dead_letter_items' THEN
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

-- ---------------------------------------------------------------------------
-- 2. bpm_audit_resource_info: bring every schema's copy up to the same
--    shape GBL-121 already gave `public` (TEXT resource_id, both
--    dead_letter_queue and dead_letter_items branches). Must DROP first
--    because the OUT parameter type is changing from UUID to TEXT in any
--    schema that still has the 024-installed UUID-returning version
--    (tenant_default and any tenant_* schema provisioned before GBL-121).
--    Re-running against a schema that already has the TEXT-returning
--    version (public) is a harmless no-op: DROP IF EXISTS on the UUID
--    overload does nothing there, and CREATE OR REPLACE reinstalls the
--    same body.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS bpm_audit_resource_info(TEXT, JSONB, JSONB);

CREATE OR REPLACE FUNCTION bpm_audit_resource_info(
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

    IF table_name = 'dead_letter_items' THEN
        resource_type := 'dlq';
        resource_id := LOWER(((src->>'id')::uuid)::TEXT);
        RETURN;
    END IF;

    IF table_name = 'webhook_subscriptions' THEN
        resource_type := 'webhook_subscription';
        resource_id := LOWER(((src->>'id')::uuid)::TEXT);
        RETURN;
    END IF;

    resource_type := table_name;
    resource_id := NULL;
END;
$$;
