//! Integration tests for ADP-10 -- agent I/O capture in audit payload_full.

const std = @import("std");
const testing = std.testing;

const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

test "TC-ADP-10-01: migration adds nullable payload_full column and payload index" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    var cols = try harness.conn.query(
        alloc,
        \\SELECT is_nullable
        \\FROM information_schema.columns
        \\WHERE table_schema = 'public'
        \\  AND table_name = 'audit_entries'
        \\  AND column_name = 'payload_full'
    ,
        &.{},
    );
    defer cols.deinit();

    try testing.expectEqual(@as(usize, 1), cols.rows.len);
    try testing.expectEqualStrings("YES", cols.rows[0][0] orelse "");

    var idx = try harness.conn.query(
        alloc,
        \\SELECT indexname
        \\FROM pg_indexes
        \\WHERE schemaname = 'public'
        \\  AND indexname = 'idx_audit_entries_payload_full_gin'
    ,
        &.{},
    );
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 1), idx.rows.len);
}

test "TC-ADP-10-02: agent rows persist payload_full while non-agent rows stay NULL" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    // SPT-02 (migration 062): users and audit_entries no longer have row-level scope columns.
    const agent_user_id = "a1000000-0000-0000-0000-000000000001";

    try harness.conn.exec(
        \\INSERT INTO users (id, email, display_name, password_hash, is_active, username, status)
        \\VALUES ($1::uuid, 'adp10.agent@example.test', 'ADP10 Agent', 'hash', true, 'agent:adp10', 'ACTIVE')
        \\ON CONFLICT (id) DO UPDATE SET
        \\  email = EXCLUDED.email,
        \\  display_name = EXCLUDED.display_name,
        \\  password_hash = EXCLUDED.password_hash,
        \\  is_active = EXCLUDED.is_active,
        \\  username = EXCLUDED.username,
        \\  status = EXCLUDED.status
    ,
        &.{agent_user_id},
    );

    try harness.conn.exec(
        "SELECT set_config('bpm.actor_username', 'agent:adp10', true)",
        &.{},
    );
    try harness.conn.exec(
        "SELECT set_config('bpm.pipeline_run_id', 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', true)",
        &.{},
    );
    try harness.conn.exec(
        "SELECT set_config('bpm.audit_payload_allow_raw_messages', 'true', true)",
        &.{},
    );
    try harness.conn.exec(
        \\SELECT set_config('bpm.audit_payload_full', '{"schema_version":"adp10.v1","capture_mode":"full","input":{"request":{"x":1}},"output":{"result":"ok"},"tool_calls":[{"ordinal":0,"tool_name":"fn:demo","input":{"arg":1},"output":{"ok":true},"error":null}],"llm_messages":{"included":true,"reason":"allow","messages":[{"role":"user","content":"ping"}]},"redaction":{"policy_id":"adp10.test","redaction_applied":false,"redaction_rules":[]},"limits":{"max_bytes":1048576,"observed_bytes":0,"truncated":false}}', true)
    ,
        &.{},
    );

    try harness.conn.exec(
        \\INSERT INTO audit_entries (
        \\  audit_id, actor_id, action, resource_type, resource_id, timestamp, before_state, after_state
        \\)
        \\VALUES (
        \\  'a1000000-0000-0000-0000-000000000101'::uuid,
        \\  $1::uuid,
        \\  'definition.update',
        \\  'definition',
        \\  'a1000000-0000-0000-0000-000000000301'::uuid,
        \\  '2026-05-26T12:00:01Z'::timestamptz,
        \\  '{"status":"DRAFT"}'::jsonb,
        \\  '{"status":"ACTIVE"}'::jsonb
        \\)
    ,
        &.{agent_user_id},
    );

    try harness.conn.exec(
        "SELECT set_config('bpm.actor_username', 'human:operator', true)",
        &.{},
    );

    try harness.conn.exec(
        \\INSERT INTO audit_entries (
        \\  audit_id, actor_id, action, resource_type, resource_id, timestamp, before_state, after_state
        \\)
        \\VALUES (
        \\  'a1000000-0000-0000-0000-000000000102'::uuid,
        \\  'a1000000-0000-0000-0000-000000000002'::uuid,
        \\  'definition.update',
        \\  'definition',
        \\  'a1000000-0000-0000-0000-000000000302'::uuid,
        \\  '2026-05-26T12:00:02Z'::timestamptz,
        \\  '{"status":"ACTIVE"}'::jsonb,
        \\  '{"status":"ARCHIVED"}'::jsonb
        \\)
    ,
        &.{},
    );

    var rows = try harness.conn.query(
        alloc,
        \\SELECT
        \\  audit_id::text,
        \\  action,
        \\  resource_type,
        \\  before_state::text,
        \\  after_state::text,
        \\  payload_full IS NULL,
        \\  payload_full->>'schema_version',
        \\  payload_full->>'capture_mode',
        \\  payload_full->'tool_calls' IS NOT NULL,
        \\  bpm_audit_compute_chain_hash(
        \\      NULL::uuid,
        \\      audit_id,
        \\      actor_id,
        \\      action,
        \\      resource_type,
        \\      resource_id,
        \\      "timestamp",
        \\      before_state,
        \\      after_state,
        \\      pipeline_run_id,
        \\      payload_full,
        \\      prev_chain_hash,
        \\      NULL
        \\  ) = chain_hash AS chain_match
        \\FROM audit_entries
        \\WHERE audit_id IN (
        \\  'a1000000-0000-0000-0000-000000000101'::uuid,
        \\  'a1000000-0000-0000-0000-000000000102'::uuid
        \\)
        \\ORDER BY audit_id ASC
    ,
        &.{},
    );
    defer rows.deinit();

    try testing.expectEqual(@as(usize, 2), rows.rows.len);

    const agent_row = rows.rows[0];
    const non_agent_row = rows.rows[1];

    try testing.expectEqualStrings("a1000000-0000-0000-0000-000000000101", agent_row[0] orelse "");
    try testing.expectEqualStrings("definition.update", agent_row[1] orelse "");
    try testing.expectEqualStrings("definition", agent_row[2] orelse "");
    try testing.expectEqualStrings("{\"status\": \"DRAFT\"}", agent_row[3] orelse "");
    try testing.expectEqualStrings("{\"status\": \"ACTIVE\"}", agent_row[4] orelse "");
    try testing.expectEqualStrings("f", agent_row[5] orelse "t");
    try testing.expectEqualStrings("adp10.v1", agent_row[6] orelse "");
    try testing.expect(std.mem.eql(u8, agent_row[7] orelse "", "full") or std.mem.eql(u8, agent_row[7] orelse "", "metadata_only") or std.mem.eql(u8, agent_row[7] orelse "", "redacted"));
    try testing.expectEqualStrings("t", agent_row[8] orelse "f");
    try testing.expectEqualStrings("t", agent_row[9] orelse "f");

    try testing.expectEqualStrings("a1000000-0000-0000-0000-000000000102", non_agent_row[0] orelse "");
    try testing.expectEqualStrings("definition.update", non_agent_row[1] orelse "");
    try testing.expectEqualStrings("definition", non_agent_row[2] orelse "");
    try testing.expectEqualStrings("{\"status\": \"ACTIVE\"}", non_agent_row[3] orelse "");
    try testing.expectEqualStrings("{\"status\": \"ARCHIVED\"}", non_agent_row[4] orelse "");
    try testing.expectEqualStrings("t", non_agent_row[5] orelse "f");
    try testing.expectEqualStrings("t", non_agent_row[9] orelse "f");
}
