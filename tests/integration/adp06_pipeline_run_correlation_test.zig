//! Integration tests for ADP-06 -- pipeline run correlation on audit and events.

const std = @import("std");
const testing = std.testing;

const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

// Root-level export required so pool connections apply tenant-schema search_path
// instead of falling back to search_path=public (see audit_iss103_test.zig).
pub const api_tenant_context = bpm.api_tenant_context;
const Registry = bpm.registry.Registry;
const RegisterParams = bpm.registry.RegisterParams;
const Store = bpm.store.Store;
const AppendParams = bpm.store.AppendParams;

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
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

fn parseUuid(s: []const u8) ![16]u8 {
    var compact: [32]u8 = undefined;
    var idx: usize = 0;
    for (s) |c| {
        if (c == '-') continue;
        if (idx >= compact.len) return error.InvalidUuid;
        compact[idx] = c;
        idx += 1;
    }
    if (idx != compact.len) return error.InvalidUuid;
    var out: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, compact[0..]);
    return out;
}

fn insertInstance(pool: *Pool, instance_id: []const u8, definition_id: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);

    try conn.exec(
        \\INSERT INTO instance_projections (
        \\  instance_id, definition_id, correlation_key, status,
        \\  current_nodes, variables, last_event_seq
        \\)
        \\VALUES (
        \\  $1::uuid, $2::uuid, NULL, 'ACTIVE',
        \\  '[]'::jsonb, '{}'::jsonb, 0
        \\)
    ,
        &.{ instance_id, definition_id },
    );
}

fn cleanupInstance(pool: *Pool, instance_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);

    conn.exec("DELETE FROM events_archive WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
    conn.exec("DELETE FROM events WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
    conn.exec("DELETE FROM instance_sequence WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
    conn.exec("DELETE FROM audit_entries WHERE resource_id = $1::uuid", &.{instance_id}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
}

test "TC-ADP-06-01: migration adds audit pipeline_run_id and query indexes" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    var cols = try harness.conn.query(
        alloc,
        \\SELECT is_nullable
        \\FROM information_schema.columns
        \\WHERE table_schema = 'public'
        \\  AND table_name = 'audit_entries'
        \\  AND column_name = 'pipeline_run_id'
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
        \\  AND indexname IN (
        \\      'idx_audit_entries_tenant_pipeline_time',
        \\      'idx_events_tenant_pipeline_run_seq',
        \\      'idx_events_archive_tenant_pipeline_run_seq'
        \\  )
        \\ORDER BY indexname ASC
    ,
        &.{},
    );
    defer idx.deinit();

    try testing.expectEqual(@as(usize, 3), idx.rows.len);
}

test "TC-ADP-06-02: trusted pipeline context propagates to event metadata and audit rows" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const instance_id = try harness.newUuidString(alloc);
    defer alloc.free(instance_id);
    const definition_id = try harness.newUuidString(alloc);
    defer alloc.free(definition_id);
    const actor_id = try harness.newUuidString(alloc);
    defer alloc.free(actor_id);
    const run_id = try harness.newUuidString(alloc);
    defer alloc.free(run_id);

    cleanupInstance(&pool, instance_id);
    defer cleanupInstance(&pool, instance_id);

    try insertInstance(&pool, instance_id, definition_id);

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "ADP06_EVENT",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    bpm.api_pipeline_context.set(run_id);
    defer bpm.api_pipeline_context.clear();

    // Ensure this assertion test is deterministic even if a stale duplicate key
    // exists from a prior interrupted run.
    {
        const prep_conn = try pool.acquire();
        defer pool.release(prep_conn);
        try prep_conn.exec("DELETE FROM events_archive WHERE idempotency_key = $1", &.{"adp06-idem-01"});
        try prep_conn.exec("DELETE FROM events WHERE idempotency_key = $1", &.{"adp06-idem-01"});
    }

    const append_result = try store.append(alloc, AppendParams{
        .instance_id = try parseUuid(instance_id),
        .event_type = "ADP06_EVENT",
        .payload = "{}",
        .actor_id = try parseUuid(actor_id),
        .idempotency_key = "adp06-idem-01",
        .metadata = "{}",
        .pipeline_run_id = bpm.api_pipeline_context.get(),
    });
    try testing.expect(!append_result.is_duplicate);

    const conn = try pool.acquire();
    defer pool.release(conn);

    const event_row = (try conn.queryRow(
        alloc,
        "SELECT metadata->>'pipeline_run_id' FROM events WHERE idempotency_key = $1",
        &.{"adp06-idem-01"},
    )) orelse return error.TestUnexpectedResult;
    defer {
        for (event_row) |c| if (c) |v| alloc.free(v);
        alloc.free(event_row);
    }
    try testing.expect(event_row[0] != null);
    try testing.expectEqualStrings(run_id, event_row[0].?);

    const audit_row = (try conn.queryRow(
        alloc,
        \\SELECT pipeline_run_id::text
        \\FROM audit_entries
        \\WHERE resource_id = $1::uuid
        \\ORDER BY timestamp DESC, audit_id DESC
        \\LIMIT 1
    ,
        &.{instance_id},
    )) orelse return error.TestUnexpectedResult;
    defer {
        for (audit_row) |c| if (c) |v| alloc.free(v);
        alloc.free(audit_row);
    }

    try testing.expect(audit_row[0] != null);
    try testing.expectEqualStrings(run_id, audit_row[0].?);

    const global = try store.readGlobal(alloc, .{
        .tenant_id = bpm.store.DEFAULT_TENANT_ID,
        .after_global_seq = null,
        .pipeline_run_id = run_id,
        .limit = 20,
    });
    defer {
        for (global) |rec| {
            alloc.free(rec.event_type);
            alloc.free(rec.payload);
            alloc.free(rec.metadata);
        }
        alloc.free(global);
    }
    try testing.expect(global.len >= 1);
}

test "TC-ADP-06-03: non-pipeline paths preserve null/absent compatibility and query filters" {
    const alloc = testing.allocator;
    var harness = try TestHarness.init(alloc);
    defer harness.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const instance_id = try harness.newUuidString(alloc);
    defer alloc.free(instance_id);
    const definition_id = try harness.newUuidString(alloc);
    defer alloc.free(definition_id);
    const actor_id = try harness.newUuidString(alloc);
    defer alloc.free(actor_id);
    const run_id = try harness.newUuidString(alloc);
    defer alloc.free(run_id);

    cleanupInstance(&pool, instance_id);
    defer cleanupInstance(&pool, instance_id);

    try insertInstance(&pool, instance_id, definition_id);

    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    _ = registry.registerType(alloc, RegisterParams{
        .name = "ADP06_EVENT_COMPAT",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    bpm.api_pipeline_context.clear();
    _ = try store.append(alloc, AppendParams{
        .instance_id = try parseUuid(instance_id),
        .event_type = "ADP06_EVENT_COMPAT",
        .payload = "{}",
        .actor_id = try parseUuid(actor_id),
        .idempotency_key = "adp06-idem-compat-01",
        .metadata = "{}",
    });

    const conn = try pool.acquire();
    defer pool.release(conn);

    const event_row = (try conn.queryRow(
        alloc,
        "SELECT metadata ? 'pipeline_run_id' FROM events WHERE idempotency_key = $1",
        &.{"adp06-idem-compat-01"},
    )) orelse return error.TestUnexpectedResult;
    defer {
        for (event_row) |c| if (c) |v| alloc.free(v);
        alloc.free(event_row);
    }

    const has_pipeline_key = std.mem.eql(u8, event_row[0] orelse "f", "t");
    try testing.expect(!has_pipeline_key);

    const audit_row = (try conn.queryRow(
        alloc,
        \\SELECT pipeline_run_id::text
        \\FROM audit_entries
        \\WHERE resource_id = $1::uuid
        \\ORDER BY timestamp DESC, audit_id DESC
        \\LIMIT 1
    ,
        &.{instance_id},
    )) orelse return error.TestUnexpectedResult;
    defer {
        for (audit_row) |c| if (c) |v| alloc.free(v);
        alloc.free(audit_row);
    }

    try testing.expect(audit_row[0] == null);

    const filtered_history = try store.readHistory(alloc, try parseUuid(instance_id), .{
        .tenant_id = bpm.store.DEFAULT_TENANT_ID,
        .event_type = null,
        .from = null,
        .to = null,
        .pipeline_run_id = run_id,
        .after_sequence = null,
        .limit = 20,
    });
    defer {
        for (filtered_history) |rec| {
            alloc.free(rec.event_type);
            alloc.free(rec.payload);
            alloc.free(rec.metadata);
        }
        alloc.free(filtered_history);
    }
    try testing.expectEqual(@as(usize, 0), filtered_history.len);

    const audit_result = bpm.audit_routes.handleList(&pool, alloc, .{
        .pipeline_run_id = run_id,
        .page_size = 20,
    });
    defer alloc.free(audit_result.body);

    try testing.expectEqual(@as(u16, 200), audit_result.status_code);
    try testing.expect(std.mem.indexOf(u8, audit_result.body, run_id) == null);
}
