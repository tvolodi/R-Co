const std = @import("std");
const portable_env = @import("env");
const helpers = @import("helpers.zig");
const testing = std.testing;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

// Root-level export required so pool connections apply tenant-schema search_path
// instead of falling back to search_path=public (see audit_iss103_test.zig).
pub const api_tenant_context = bpm.api_tenant_context;
const dlq_store = bpm.dlq_store;
const dlq_routes = bpm.dlq_routes;

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set - skipping integration test\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_default,public (schema isolation).
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 5 });
}

fn cleanupDlqBySourceRef(conn: *bpm.pool.Conn, source_ref: []const u8) void {
    conn.exec("DELETE FROM dead_letter_items WHERE source_ref = $1", &.{source_ref}) catch {};
}

fn cleanupInstance(conn: *bpm.pool.Conn, instance_id: []const u8) void {
    conn.exec("DELETE FROM dead_letter_items WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
}

fn insertInstanceProjection(conn: *bpm.pool.Conn, instance_id: []const u8, definition_id: []const u8, status: []const u8) !void {
    try conn.exec(
        \\INSERT INTO instance_projections (
        \\  instance_id, definition_id, correlation_key, status,
        \\  current_nodes, variables, error_detail, last_event_seq,
        \\  started_at, completed_at, cancelled_at, updated_at
        \\)
        \\VALUES (
        \\  $1::uuid, $2::uuid, NULL, $3,
        \\  '[]'::jsonb, '{}'::jsonb, NULL, 0,
        \\  NOW() - INTERVAL '1 day',
        \\  NULL,
        \\  CASE WHEN $3 = 'CANCELLED' THEN NOW() - INTERVAL '1 hour' ELSE NULL END,
        \\  NOW()
        \\)
        \\ON CONFLICT (instance_id) DO UPDATE SET
        \\  status = EXCLUDED.status,
        \\  updated_at = NOW()
    ,
        &.{ instance_id, definition_id, status },
    );
}

fn insertDlqRow(
    conn: *bpm.pool.Conn,
    id: []const u8,
    instance_id: ?[]const u8,
    item_type: []const u8,
    source_ref: []const u8,
    created_at_iso: []const u8,
) !void {
    try conn.exec(
        \\INSERT INTO dead_letter_items (
        \\  id, entry_type, instance_id, reason, error_detail,
        \\  retry_count, max_retries, status,
        \\  created_at, updated_at,
        \\  item_type, retry_limit,
        \\  original_payload, error_chain, processor_metadata,
        \\  first_failed_at, last_failed_at, source_ref
        \\)
        \\VALUES (
        \\  $1::uuid,
        \\  CASE $3
        \\    WHEN 'SERVICE_TASK' THEN 'service_task_failed'
        \\    WHEN 'WEBHOOK' THEN 'webhook_failed'
        \\    ELSE 'timer_failed'
        \\  END,
        \\  NULLIF($2, '')::uuid,
        \\  'retry limit exhausted',
        \\  '{"code":"FAILED"}'::jsonb,
        \\  3,
        \\  3,
        \\  'pending',
        \\  $5::timestamptz,
        \\  $5::timestamptz,
        \\  $3,
        \\  3,
        \\  '{"payload":"value"}'::jsonb,
        \\  '[{"code":"FAILED","message":"x"}]'::jsonb,
        \\  '{"source_module":"obs05.test"}'::jsonb,
        \\  $5::timestamptz,
        \\  $5::timestamptz,
        \\  $4
        \\)
        \\ON CONFLICT (id) DO UPDATE SET
        \\  status = 'pending',
        \\  updated_at = EXCLUDED.updated_at,
        \\  item_type = EXCLUDED.item_type,
        \\  source_ref = EXCLUDED.source_ref
    ,
        &.{ id, instance_id orelse "", item_type, source_ref, created_at_iso },
    );
}

fn rowCount(
    conn: *bpm.pool.Conn,
    allocator: std.mem.Allocator,
    sql: []const u8,
    params: []const []const u8,
) !usize {
    const row = (try conn.queryRow(allocator, sql, params)) orelse return error.TestUnexpectedResult;
    defer {
        if (row[0]) |v| allocator.free(v);
        allocator.free(row);
    }
    return std.fmt.parseInt(usize, row[0] orelse "0", 10);
}

fn rowText(
    conn: *bpm.pool.Conn,
    allocator: std.mem.Allocator,
    sql: []const u8,
    params: []const []const u8,
) ![]u8 {
    const row = (try conn.queryRow(allocator, sql, params)) orelse return error.TestUnexpectedResult;
    defer {
        if (row[0]) |v| allocator.free(v);
        allocator.free(row);
    }
    return allocator.dupe(u8, row[0] orelse return error.TestUnexpectedResult);
}

fn extractJsonStringField(allocator: std.mem.Allocator, body: []const u8, field: []const u8) !?[]u8 {
    const pattern = try std.fmt.allocPrint(allocator, "\"{s}\":\"", .{field});
    defer allocator.free(pattern);

    const start = std.mem.indexOf(u8, body, pattern) orelse return null;
    const after = start + pattern.len;
    const end_rel = std.mem.indexOfScalarPos(u8, body, after, '"') orelse return error.TestUnexpectedResult;
    const value = try allocator.dupe(u8, body[after..end_rel]);
    return value;
}

fn extractJsonUsizeField(allocator: std.mem.Allocator, body: []const u8, field: []const u8) !?usize {
    const pattern = try std.fmt.allocPrint(allocator, "\"{s}\":", .{field});
    defer allocator.free(pattern);

    const start = std.mem.indexOf(u8, body, pattern) orelse return null;
    var i = start + pattern.len;
    while (i < body.len and body[i] == ' ') : (i += 1) {}

    var j = i;
    while (j < body.len and std.ascii.isDigit(body[j])) : (j += 1) {}
    if (j == i) return error.TestUnexpectedResult;
    return std.fmt.parseInt(usize, body[i..j], 10) catch return error.TestUnexpectedResult;
}

fn freeRouteBody(allocator: std.mem.Allocator, body: []const u8) void {
    if (std.mem.eql(u8, body, "{\"type\":\"about:blank\",\"title\":\"INTERNAL_ERROR\",\"status\":500,\"detail\":\"internal error\"}")) {
        return;
    }
    allocator.free(body);
}

test "TC-OBS-05-INT-01: exhausted retries persist full context and GET /dlq supports filters+pagination" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    cleanupDlqBySourceRef(conn, "obs05-int01-service");
    cleanupDlqBySourceRef(conn, "obs05-int01-webhook");
    cleanupDlqBySourceRef(conn, "obs05-int01-timer");

    const service_instance = try h.newUuidString(alloc);
    defer alloc.free(service_instance);
    const timer_instance = try h.newUuidString(alloc);
    defer alloc.free(timer_instance);
    const operator_id = try h.newUuidString(alloc);
    defer alloc.free(operator_id);
    const worker_id = try h.newUuidString(alloc);
    defer alloc.free(worker_id);

    try dlq_store.moveToDlq(alloc, &pool, .{
        .instance_id = service_instance,
        .item_type = .SERVICE_TASK,
        .retry_count = 3,
        .retry_limit = 3,
        .original_payload_json = "{\"node_id\":\"charge_card\"}",
        .error_chain_json = "[{\"code\":\"HTTP_TIMEOUT\"}]",
        .processor_metadata_json = "{\"source_module\":\"engine.service_task\"}",
        .first_failed_at = "2026-05-25T10:00:00Z",
        .last_failed_at = "2026-05-25T10:00:30Z",
        .source_ref = "obs05-int01-service",
        .reason = "service task retry exhausted",
    });
    try dlq_store.moveToDlq(alloc, &pool, .{
        .instance_id = null,
        .item_type = .WEBHOOK,
        .retry_count = 3,
        .retry_limit = 3,
        .original_payload_json = "{\"event\":\"task.completed\"}",
        .error_chain_json = "[{\"code\":\"WEBHOOK_500\"}]",
        .processor_metadata_json = "{\"source_module\":\"webhook.dispatcher\"}",
        .first_failed_at = "2026-05-25T10:01:00Z",
        .last_failed_at = "2026-05-25T10:01:30Z",
        .source_ref = "obs05-int01-webhook",
        .reason = "webhook retry exhausted",
    });
    try dlq_store.moveToDlq(alloc, &pool, .{
        .instance_id = timer_instance,
        .item_type = .TIMER,
        .retry_count = 3,
        .retry_limit = 3,
        .original_payload_json = "{\"timer_id\":\"t-1\"}",
        .error_chain_json = "[{\"code\":\"TIMER_FIRE_FAILED\"}]",
        .processor_metadata_json = "{\"source_module\":\"scheduler\"}",
        .first_failed_at = "2026-05-25T10:02:00Z",
        .last_failed_at = "2026-05-25T10:02:30Z",
        .source_ref = "obs05-int01-timer",
        .reason = "timer retry exhausted",
    });

    const persisted_service_context = try rowCount(
        conn,
        alloc,
        \\SELECT COUNT(*)::text
        \\FROM dead_letter_items
        \\WHERE source_ref = $1
        \\  AND instance_id = $2::uuid
        \\  AND retry_count = 3
        \\  AND retry_limit = 3
        \\  AND original_payload @> '{"node_id":"charge_card"}'::jsonb
        \\  AND error_chain @> '[{"code":"HTTP_TIMEOUT"}]'::jsonb
        \\  AND processor_metadata @> '{"source_module":"engine.service_task"}'::jsonb
    ,
        &.{ "obs05-int01-service", service_instance },
    );
    try testing.expectEqual(@as(usize, 1), persisted_service_context);

    const operator = dlq_routes.Actor{
        .user_id = operator_id,
        .roles = &[_]bpm.api_authorization.Role{.PROCESS_OPERATOR},
        .is_operator_or_above = true,
        .is_platform_admin = false,
    };
    const worker = dlq_routes.Actor{
        .user_id = worker_id,
        .roles = &[_]bpm.api_authorization.Role{.TASK_WORKER},
        .is_operator_or_above = false,
        .is_platform_admin = false,
    };

    const forbidden = dlq_routes.handleList(&pool, alloc, worker, .{ .page_size = 10 });
    defer freeRouteBody(alloc, forbidden.body);
    try testing.expectEqual(@as(u16, 403), forbidden.status_code);

    const first_page = dlq_routes.handleList(&pool, alloc, operator, .{ .page_size = 2 });
    defer freeRouteBody(alloc, first_page.body);
    try testing.expectEqual(@as(u16, 200), first_page.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, first_page.body, 1, "\"count\":2"));
    const cursor = (try extractJsonStringField(alloc, first_page.body, "next_cursor")) orelse return error.TestUnexpectedResult;
    defer alloc.free(cursor);

    const second_page = dlq_routes.handleList(&pool, alloc, operator, .{ .page_size = 2, .cursor = cursor });
    defer freeRouteBody(alloc, second_page.body);
    try testing.expectEqual(@as(u16, 200), second_page.status_code);
    const second_page_count = (try extractJsonUsizeField(alloc, second_page.body, "count")) orelse return error.TestUnexpectedResult;
    try testing.expect(second_page_count >= 1);

    const filtered = dlq_routes.handleList(&pool, alloc, operator, .{ .item_type = .WEBHOOK, .page_size = 10 });
    defer freeRouteBody(alloc, filtered.body);
    try testing.expectEqual(@as(u16, 200), filtered.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, filtered.body, 1, "\"item_type\":\"WEBHOOK\""));

    const filtered_instance = dlq_routes.handleList(&pool, alloc, operator, .{
        .instance_id = service_instance,
        .page_size = 10,
    });
    defer freeRouteBody(alloc, filtered_instance.body);
    try testing.expectEqual(@as(u16, 200), filtered_instance.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, filtered_instance.body, 1, "\"count\":1"));
    const expected_instance = try std.fmt.allocPrint(alloc, "\"instance_id\":\"{s}\"", .{service_instance});
    defer alloc.free(expected_instance);
    try testing.expect(std.mem.containsAtLeast(u8, filtered_instance.body, 1, expected_instance));
}

test "TC-OBS-05-INT-02: POST /dlq/:id/retry returns 409+discard for CANCELLED and 202 for ACTIVE" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const cancelled_instance = try h.newUuidString(alloc);

    defer alloc.free(cancelled_instance);
    const active_instance = try h.newUuidString(alloc);
    defer alloc.free(active_instance);
    const definition_id = try h.newUuidString(alloc);
    defer alloc.free(definition_id);

    cleanupInstance(conn, cancelled_instance);
    cleanupInstance(conn, active_instance);
    defer cleanupInstance(conn, cancelled_instance);
    defer cleanupInstance(conn, active_instance);

    try insertInstanceProjection(conn, cancelled_instance, definition_id, "CANCELLED");
    try insertInstanceProjection(conn, active_instance, definition_id, "ACTIVE");

    const cancelled_dlq_id = try h.newUuidString(alloc);

    defer alloc.free(cancelled_dlq_id);
    const active_dlq_id = try h.newUuidString(alloc);
    defer alloc.free(active_dlq_id);
    try insertDlqRow(conn, cancelled_dlq_id, cancelled_instance, "TIMER", "obs05-int02-cancelled", "2026-05-25T11:00:00Z");
    try insertDlqRow(conn, active_dlq_id, active_instance, "SERVICE_TASK", "obs05-int02-active", "2026-05-25T11:01:00Z");

    const actor_id = try h.newUuidString(alloc);
    defer alloc.free(actor_id);
    const worker_id = try h.newUuidString(alloc);
    defer alloc.free(worker_id);
    const actor = dlq_routes.Actor{
        .user_id = actor_id,
        .roles = &[_]bpm.api_authorization.Role{.PROCESS_OPERATOR},
        .is_operator_or_above = true,
        .is_platform_admin = false,
    };
    const worker = dlq_routes.Actor{
        .user_id = worker_id,
        .roles = &[_]bpm.api_authorization.Role{.TASK_WORKER},
        .is_operator_or_above = false,
        .is_platform_admin = false,
    };

    const forbidden_retry = dlq_routes.handleRetry(&pool, alloc, worker, active_dlq_id);
    defer freeRouteBody(alloc, forbidden_retry.body);
    try testing.expectEqual(@as(u16, 403), forbidden_retry.status_code);

    const cancelled_result = dlq_routes.handleRetry(&pool, alloc, actor, cancelled_dlq_id);
    defer freeRouteBody(alloc, cancelled_result.body);
    try testing.expectEqual(@as(u16, 409), cancelled_result.status_code);

    const cancelled_exists = try rowCount(
        conn,
        alloc,
        "SELECT COUNT(*)::text FROM dead_letter_items WHERE id = $1::uuid",
        &.{cancelled_dlq_id},
    );
    try testing.expectEqual(@as(usize, 0), cancelled_exists);

    const success_result = dlq_routes.handleRetry(&pool, alloc, actor, active_dlq_id);
    defer freeRouteBody(alloc, success_result.body);
    try testing.expectEqual(@as(u16, 202), success_result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, success_result.body, 1, "\"retry_count\":0"));

    const active_exists = try rowCount(
        conn,
        alloc,
        "SELECT COUNT(*)::text FROM dead_letter_items WHERE id = $1::uuid",
        &.{active_dlq_id},
    );
    try testing.expectEqual(@as(usize, 0), active_exists);

    const retry_audit_count = try rowCount(
        conn,
        alloc,
        "SELECT COUNT(*)::text FROM audit_entries WHERE resource_type = 'dlq' AND resource_id = $1 AND action = 'dlq.retry' AND actor_id = $2::uuid",
        &.{ active_dlq_id, actor.user_id },
    );
    try testing.expect(retry_audit_count >= 1);

    const instance_status = try rowText(
        conn,
        alloc,
        "SELECT status FROM instance_projections WHERE instance_id = $1::uuid",
        &.{active_instance},
    );
    defer alloc.free(instance_status);
    try testing.expectEqualStrings("ACTIVE", instance_status);
}

test "TC-OBS-05-INT-03: POST /dlq/:id/discard appends audit and rolls back on audit failure" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var h = try helpers.TestHarness.init(alloc);
    defer h.deinit();

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const dlq_id_ok = try h.newUuidString(alloc);

    defer alloc.free(dlq_id_ok);
    const dlq_id_fail = try h.newUuidString(alloc);
    defer alloc.free(dlq_id_fail);
    try insertDlqRow(conn, dlq_id_ok, null, "WEBHOOK", "obs05-int03-ok", "2026-05-25T12:00:00Z");
    try insertDlqRow(conn, dlq_id_fail, null, "WEBHOOK", "obs05-int03-fail", "2026-05-25T12:01:00Z");
    defer cleanupDlqBySourceRef(conn, "obs05-int03-ok");
    defer cleanupDlqBySourceRef(conn, "obs05-int03-fail");

    const actor_id = try h.newUuidString(alloc);
    defer alloc.free(actor_id);
    const worker_id = try h.newUuidString(alloc);
    defer alloc.free(worker_id);
    const actor = dlq_routes.Actor{
        .user_id = actor_id,
        .roles = &[_]bpm.api_authorization.Role{.PROCESS_OPERATOR},
        .is_operator_or_above = true,
        .is_platform_admin = false,
    };
    const worker = dlq_routes.Actor{
        .user_id = worker_id,
        .roles = &[_]bpm.api_authorization.Role{.TASK_WORKER},
        .is_operator_or_above = false,
        .is_platform_admin = false,
    };

    const forbidden_discard = dlq_routes.handleDiscard(&pool, alloc, worker, dlq_id_ok, null);
    defer freeRouteBody(alloc, forbidden_discard.body);
    try testing.expectEqual(@as(u16, 403), forbidden_discard.status_code);

    const ok_result = dlq_routes.handleDiscard(&pool, alloc, actor, dlq_id_ok, null);
    defer freeRouteBody(alloc, ok_result.body);
    try testing.expectEqual(@as(u16, 200), ok_result.status_code);

    const audit_count = try rowCount(
        conn,
        alloc,
        "SELECT COUNT(*)::text FROM audit_entries WHERE resource_type = 'dlq' AND resource_id = $1 AND action = 'dlq.discard'",
        &.{dlq_id_ok},
    );
    try testing.expect(audit_count >= 1);

    // Wrap the deliberate audit-failure trigger install in a SAVEPOINT so
    // that the trg_bpm_test_fail_audit_insert / bpm_test_fail_audit_insert
    // pair cannot leak into the next test process. The previous implementation
    // used a happy-path defer that only fired if the test ran to completion;
    // on early return, the trigger persisted in db_test and fired P0001
    // 'audit_entries is immutable' on legitimate mutations in adp09 /
    // oidc22. The errdefer below rolls the savepoint back on any early
    // return, removing the trigger and function before the next test
    // process acquires a pool connection. The savepoint is NEVER released
    // on the happy path — it is rolled back unconditionally at the end of
    // the test block, so the trigger is guaranteed gone before the next
    // test process runs.
    conn.exec("SAVEPOINT s_audit_failure", &.{}) catch return error.PersistenceFailed;
    errdefer {
        conn.exec("ROLLBACK TO SAVEPOINT s_audit_failure", &.{}) catch {};
    }

    conn.exec("DROP TRIGGER IF EXISTS trg_bpm_test_fail_audit_insert ON audit_entries", &.{}) catch {};
    conn.exec("DROP FUNCTION IF EXISTS bpm_test_fail_audit_insert()", &.{}) catch {};
    try conn.exec(
        \\CREATE OR REPLACE FUNCTION bpm_test_fail_audit_insert()
        \\RETURNS trigger
        \\LANGUAGE plpgsql
        \\AS $$
        \\BEGIN
        \\  IF NEW.resource_type = 'dlq' AND NEW.action = 'dlq.discard' THEN
        \\    RAISE EXCEPTION 'forced OBS-05 audit failure';
        \\  END IF;
        \\  RETURN NEW;
        \\END;
        \\$$
    , &.{});
    try conn.exec(
        \\CREATE TRIGGER trg_bpm_test_fail_audit_insert
        \\BEFORE INSERT ON audit_entries
        \\FOR EACH ROW EXECUTE FUNCTION bpm_test_fail_audit_insert()
    , &.{});

    const fail_result = dlq_routes.handleDiscard(&pool, alloc, actor, dlq_id_fail, null);
    defer freeRouteBody(alloc, fail_result.body);
    try testing.expectEqual(@as(u16, 500), fail_result.status_code);

    const still_exists = try rowCount(
        conn,
        alloc,
        "SELECT COUNT(*)::text FROM dead_letter_items WHERE id = $1::uuid",
        &.{dlq_id_fail},
    );
    try testing.expectEqual(@as(usize, 1), still_exists);
}

