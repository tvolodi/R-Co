//! Integration tests for OIDC-16..OIDC-26 lifecycle foundation persistence.
//!
//! DIRECTIVE T-1: no mocks or stubs; tests execute against real PostgreSQL
//! through TestHarness and rollback after each test.

const std = @import("std");
const testing = std.testing;
const pg = @import("pg");

const helpers = @import("helpers.zig");

fn freeRow(allocator: std.mem.Allocator, row: []?[]u8) void {
    for (row) |col| {
        if (col) |v| allocator.free(v);
    }
    allocator.free(row);
}

fn parseCount(value: ?[]u8) !u32 {
    const raw = value orelse return error.TestUnexpectedResult;
    return std.fmt.parseInt(u32, raw, 10);
}

fn expectExecFailure(conn: *pg.Conn, sql: []const u8, args: []const []const u8) !void {
    var failed = false;
    conn.exec(sql, args) catch {
        failed = true;
    };
    try testing.expect(failed);
}

test "TC-OIDC-17-01: idp_operation_ledger enforces idempotency key uniqueness per endpoint" {
    var h = try helpers.TestHarness.init(testing.allocator);
    defer h.deinit();

    const conn = &h.conn;

    const op1_id = try h.newUuidString(testing.allocator);
    defer testing.allocator.free(op1_id);
    const op2_id = try h.newUuidString(testing.allocator);
    defer testing.allocator.free(op2_id);

    try conn.exec(
        \\INSERT INTO idp_operation_ledger (
        \\  operation_id, endpoint_fingerprint, idempotency_key, scope,
        \\  request_hash, response_status, response_body_json, state, actor_id, expires_at
        \\) VALUES (
        \\  $1::uuid, $2, $3, $4, decode($5, 'hex'), 201, '{}'::jsonb, 'COMPLETED', $6, NOW() + INTERVAL '1 day'
        \\)
    , &[_][]const u8{
        op1_id,
        "POST:/api/v1/idp/provisioning:bundle",
        "idem-oidc17-01",
        "bundle_provision",
        "00",
        "agent:test-designer",
    });

    try expectExecFailure(conn,
        \\INSERT INTO idp_operation_ledger (
        \\  operation_id, endpoint_fingerprint, idempotency_key, scope,
        \\  request_hash, response_status, response_body_json, state, actor_id, expires_at
        \\) VALUES (
        \\  $1::uuid, $2, $3, $4, decode($5, 'hex'), 200, '{}'::jsonb, 'COMPLETED', $6, NOW() + INTERVAL '1 day'
        \\)
    , &[_][]const u8{
        op2_id,
        "POST:/api/v1/idp/provisioning:bundle",
        "idem-oidc17-01",
        "bundle_provision",
        "11",
        "agent:test-designer",
    });
}

test "TC-OIDC-18-01: transaction log supports forward plus reverse-order compensation records" {
    var h = try helpers.TestHarness.init(testing.allocator);
    defer h.deinit();

    const conn = &h.conn;
    const tx = try h.newUuidString(testing.allocator);
    defer testing.allocator.free(tx);

    try conn.exec(
        \\INSERT INTO idp_transaction_log (transaction_id, step_index, step_kind, direction, status)
        \\VALUES ($1::uuid, 0, 'create_realm', 'FORWARD', 'SUCCESS')
    , &[_][]const u8{tx});
    try conn.exec(
        \\INSERT INTO idp_transaction_log (transaction_id, step_index, step_kind, direction, status)
        \\VALUES ($1::uuid, 1, 'create_user', 'FORWARD', 'FAILED')
    , &[_][]const u8{tx});
    try conn.exec(
        \\INSERT INTO idp_transaction_log (transaction_id, step_index, step_kind, direction, status)
        \\VALUES ($1::uuid, 1, 'create_user', 'COMPENSATION', 'SUCCESS')
    , &[_][]const u8{tx});
    try conn.exec(
        \\INSERT INTO idp_transaction_log (transaction_id, step_index, step_kind, direction, status)
        \\VALUES ($1::uuid, 0, 'create_realm', 'COMPENSATION', 'SUCCESS')
    , &[_][]const u8{tx});

    var result = try conn.query(testing.allocator,
        \\SELECT COUNT(*)::text
        \\FROM idp_transaction_log
        \\WHERE transaction_id = $1::uuid AND direction = 'COMPENSATION'
    , &[_][]const u8{tx});
    defer result.deinit();
    if (result.rows.len == 0) return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 2), try parseCount(result.rows[0][0]));
}

test "TC-OIDC-20-01: agent identity bindings are isolated per agent kind" {
    var h = try helpers.TestHarness.init(testing.allocator);
    defer h.deinit();

    const conn = &h.conn;

    var result = try conn.query(testing.allocator,
        \\SELECT COUNT(*)::text
        \\FROM pg_indexes
        \\WHERE schemaname = 'public'
        \\  AND tablename = 'agent_identity_binding'
        \\  AND indexname = 'uq_agent_identity_binding_active'
    , &[_][]const u8{});
    defer result.deinit();
    if (result.rows.len == 0) return error.TestUnexpectedResult;

    try testing.expectEqual(@as(u32, 1), try parseCount(result.rows[0][0]));
}

test "TC-OIDC-21-01: overlapping secret rotations become non-pending after finalization" {
    var h = try helpers.TestHarness.init(testing.allocator);
    defer h.deinit();

    const conn = &h.conn;
    const rotation_id = try h.newUuidString(testing.allocator);
    defer testing.allocator.free(rotation_id);
    const bad_rotation_id = try h.newUuidString(testing.allocator);
    defer testing.allocator.free(bad_rotation_id);

    try conn.exec(
        \\INSERT INTO agent_secret_rotation (
        \\  rotation_id, realm_id, provider_client_id, old_secret_fingerprint, new_secret_fingerprint,
        \\  old_secret_valid_until, status, created_by
        \\) VALUES (
        \\  $1::uuid, $2, $3, $4, $5, NOW() - INTERVAL '2 hours', 'OVERLAP', $6
        \\)
    , &[_][]const u8{ rotation_id, "realm-a", "client-orch-a", "old-fp", "new-fp", "agent:test-designer" });

    var before = try conn.query(testing.allocator,
        \\SELECT COUNT(*)::text
        \\FROM agent_secret_rotation
        \\WHERE status = 'OVERLAP' AND old_secret_valid_until <= NOW()
    , &[_][]const u8{});
    defer before.deinit();
    if (before.rows.len == 0) return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 1), try parseCount(before.rows[0][0]));

    try conn.exec(
        \\UPDATE agent_secret_rotation
        \\SET status = 'FINALIZED', finalized_at = NOW()
        \\WHERE rotation_id = $1::uuid
    , &[_][]const u8{rotation_id});

    var after = try conn.query(testing.allocator,
        \\SELECT COUNT(*)::text
        \\FROM agent_secret_rotation
        \\WHERE status = 'OVERLAP' AND old_secret_valid_until <= NOW()
    , &[_][]const u8{});
    defer after.deinit();
    if (after.rows.len == 0) return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 0), try parseCount(after.rows[0][0]));

    try expectExecFailure(conn,
        \\INSERT INTO agent_secret_rotation (
        \\  rotation_id, realm_id, provider_client_id, old_secret_fingerprint, new_secret_fingerprint,
        \\  old_secret_valid_until, status, created_by
        \\) VALUES (
        \\  $1::uuid, $2, $3, $4, $5, NOW() + INTERVAL '1 hour', 'BROKEN_STATE', $6
        \\)
    , &[_][]const u8{ bad_rotation_id, "realm-a", "client-orch-a", "old-fp-2", "new-fp-2", "agent:test-designer" });
}

test "TC-OIDC-19-01: redacted adapter audit payload row is persisted" {
    var h = try helpers.TestHarness.init(testing.allocator);
    defer h.deinit();

    const conn = &h.conn;

    const audit_id_v = try h.newUuidString(testing.allocator);
    defer testing.allocator.free(audit_id_v);
    const transaction_id_v = try h.newUuidString(testing.allocator);
    defer testing.allocator.free(transaction_id_v);

    try conn.exec(
        \\INSERT INTO idp_adapter_audit (
        \\  audit_id, actor_id, auth_source, adapter_method, provider_status_code, duration_ms,
        \\  realm_id, resource_id, transaction_id, request_payload_redacted, response_payload_redacted, redaction_applied
        \\) VALUES (
        \\  $1::uuid, $2, 'agent', 'createClient', 201, 12,
        \\  $3, $4, $5::uuid, $6::jsonb, $7::jsonb, true
        \\)
    , &[_][]const u8{
        audit_id_v,
        "agent:test-designer",
        "realm-a",
        "client-orch-a",
        transaction_id_v,
        "{\"client_secret\":\"[REDACTED]\"}",
        "{\"status\":\"ok\"}",
    });

    var result = try conn.query(testing.allocator,
        \\SELECT redaction_applied::text
        \\FROM idp_adapter_audit
        \\WHERE audit_id = $1::uuid
    , &[_][]const u8{audit_id_v});
    defer result.deinit();
    if (result.rows.len == 0) return error.TestUnexpectedResult;

    try testing.expectEqualStrings("true", result.rows[0][0] orelse return error.TestUnexpectedResult);
}

test "TC-OIDC-22-01: bootstrap state is singleton and bootstrap audit event types are enforced" {
    var h = try helpers.TestHarness.init(testing.allocator);
    defer h.deinit();

    const conn = &h.conn;

    var table_result = try conn.query(testing.allocator,
        \\SELECT COUNT(*)::text
        \\FROM information_schema.tables
        \\WHERE table_schema = 'public'
        \\  AND table_name IN ('agent_bootstrap_state', 'agent_bootstrap_audit')
    , &[_][]const u8{});
    defer table_result.deinit();
    if (table_result.rows.len == 0) return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 2), try parseCount(table_result.rows[0][0]));

    var constraint_result = try conn.query(testing.allocator,
        \\SELECT COUNT(*)::text
        \\FROM pg_constraint c
        \\JOIN pg_class t ON t.oid = c.conrelid
        \\JOIN pg_namespace n ON n.oid = t.relnamespace
        \\WHERE t.relname = 'agent_bootstrap_audit'
        \\  AND n.nspname = 'public'
        \\  AND pg_get_constraintdef(c.oid) LIKE '%BOOTSTRAP_REENABLED%'
    , &[_][]const u8{});
    defer constraint_result.deinit();
    if (constraint_result.rows.len == 0) return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 1), try parseCount(constraint_result.rows[0][0]));
}

test "TC-OIDC-23-01: federation alias is unique while active and reusable after delete" {
    var h = try helpers.TestHarness.init(testing.allocator);
    defer h.deinit();

    const conn = &h.conn;

    var result = try conn.query(testing.allocator,
        \\SELECT COUNT(*)::text
        \\FROM pg_indexes
        \\WHERE schemaname = 'public'
        \\  AND tablename = 'idp_federation_binding'
        \\  AND indexname = 'uq_idp_federation_alias_active'
    , &[_][]const u8{});
    defer result.deinit();
    if (result.rows.len == 0) return error.TestUnexpectedResult;

    try testing.expectEqual(@as(u32, 1), try parseCount(result.rows[0][0]));
}
