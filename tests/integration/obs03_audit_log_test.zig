const std = @import("std");
const testing = std.testing;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const DefinitionStore = bpm.definition.Store;
const CreateParams = bpm.definition.CreateParams;
const DefinitionGraph = bpm.definition.DefinitionGraph;
const GraphNode = bpm.definition.GraphNode;
const GraphEdge = bpm.definition.GraphEdge;

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
    return Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 5 });
}

fn parseUuid(s: []const u8) ![16]u8 {
    if (s.len != 36) return error.InvalidUuid;
    var compact: [32]u8 = undefined;
    var j: usize = 0;
    for (s) |c| {
        if (c == '-') continue;
        if (j >= compact.len) return error.InvalidUuid;
        compact[j] = c;
        j += 1;
    }
    if (j != 32) return error.InvalidUuid;
    var out: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, compact[0..]);
    return out;
}

fn uuidToString(allocator: std.mem.Allocator, uuid: [16]u8) ![]u8 {
    const raw = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(&uuid, .lower)});
    defer allocator.free(raw);

    return std.fmt.allocPrint(
        allocator,
        "{s}-{s}-{s}-{s}-{s}",
        .{ raw[0..8], raw[8..12], raw[12..16], raw[16..20], raw[20..32] },
    );
}

fn dbUuidString(conn: *bpm.pool.Conn, allocator: std.mem.Allocator) ![]u8 {
    const row = (try conn.queryRow(allocator, "SELECT gen_random_uuid()::text", &.{})) orelse return error.TestUnexpectedResult;
    defer {
        if (row[0]) |v| allocator.free(v);
        allocator.free(row);
    }

    const uuid = row[0] orelse return error.TestUnexpectedResult;
    return allocator.dupe(u8, uuid);
}

fn cleanupDefinition(pool: *Pool, name: []const u8, version: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM process_definitions WHERE name = $1 AND version = $2",
        &.{ name, version },
    ) catch {};
}

fn cleanupAuditResource(pool: *Pool, resource_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM audit_entries WHERE resource_id = $1::uuid",
        &.{resource_id},
    ) catch {};
}

fn cleanupAuditInsertFailureHook(conn: *bpm.pool.Conn) void {
    conn.exec("DROP TRIGGER IF EXISTS trg_bpm_test_fail_audit_insert ON audit_entries", &.{}) catch {};
    conn.exec("DROP FUNCTION IF EXISTS bpm_test_fail_audit_insert()", &.{}) catch {};
}

fn countRows(
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

    const count_str = row[0] orelse return error.TestUnexpectedResult;
    return std.fmt.parseInt(usize, count_str, 10);
}

fn extractJsonStringField(
    allocator: std.mem.Allocator,
    body: []const u8,
    field: []const u8,
) error{ OutOfMemory, TestUnexpectedResult }!?[]u8 {
    const pattern = try std.fmt.allocPrint(allocator, "\"{s}\":\"", .{field});
    defer allocator.free(pattern);

    const start = std.mem.indexOf(u8, body, pattern) orelse return null;
    const after_key = start + pattern.len;
    const rest = body[after_key..];
    const end_rel = std.mem.indexOfScalar(u8, rest, '"') orelse return error.TestUnexpectedResult;

    const value = try allocator.dupe(u8, rest[0..end_rel]);
    return value;
}

fn seedUserAndToken(
    conn: *bpm.pool.Conn,
    user_id: []const u8,
    email: []const u8,
    token_id: []const u8,
    token_name: []const u8,
    token_hash: []const u8,
) !void {
    // Make the seed idempotent across interrupted runs and prior failed cleanups.
    conn.exec(
        "DELETE FROM api_tokens WHERE id = $1::uuid OR token_hash = $2",
        &.{ token_id, token_hash },
    ) catch {};
    conn.exec(
        "DELETE FROM users WHERE id = $1::uuid OR email = $2",
        &.{ user_id, email },
    ) catch {};

    try conn.exec(
        \\INSERT INTO users (id, email, display_name, password_hash, is_active, username, status)
        \\VALUES ($1::uuid, $2, 'OBS03 User', 'hash', true, 'obs03_' || replace($1::text, '-', ''), 'ACTIVE')
        \\ON CONFLICT (id) DO UPDATE SET
        \\  email = EXCLUDED.email,
        \\  display_name = EXCLUDED.display_name,
        \\  password_hash = EXCLUDED.password_hash,
        \\  is_active = EXCLUDED.is_active,
        \\  username = EXCLUDED.username,
        \\  status = EXCLUDED.status
    ,
        &.{ user_id, email },
    );

    try conn.exec(
        \\INSERT INTO api_tokens (id, user_id, name, token_hash)
        \\VALUES ($1::uuid, $2::uuid, $3, $4)
        \\ON CONFLICT (id) DO UPDATE SET
        \\  user_id = EXCLUDED.user_id,
        \\  name = EXCLUDED.name,
        \\  token_hash = EXCLUDED.token_hash,
        \\  revoked_at = NULL
    ,
        &.{ token_id, user_id, token_name, token_hash },
    );
}

fn cleanupUserAndToken(conn: *bpm.pool.Conn, user_id: []const u8, token_id: []const u8) void {
    conn.exec("DELETE FROM api_tokens WHERE id = $1::uuid", &.{token_id}) catch {};
    conn.exec("DELETE FROM users WHERE id = $1::uuid", &.{user_id}) catch {};
}

fn cleanupUserByEmail(conn: *bpm.pool.Conn, email: []const u8) void {
    conn.exec(
        "DELETE FROM api_tokens WHERE user_id IN (SELECT id FROM users WHERE email = $1)",
        &.{email},
    ) catch {};
    conn.exec("DELETE FROM users WHERE email = $1", &.{email}) catch {};
}

test "TC-OBS-03-INT-01: state-changing writes create audit rows with required fields" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "tc-obs03-write-audit";
    const version = "1.0.0";
    cleanupDefinition(&pool, name, version);
    defer cleanupDefinition(&pool, name, version);

    var store = DefinitionStore.init(alloc, &pool);
    defer store.deinit();

    const creator = try parseUuid("00000000-0000-0000-0000-000000000099");

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"operator\"}" },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "T", .condition = null },
        .{ .id = "e2", .source = "T", .target = "E", .condition = null },
    };

    const def = try store.create(alloc, CreateParams{
        .name = name,
        .version = version,
        .description = "obs03 integration",
        .graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges },
        .created_by = creator,
    });
    defer {
        alloc.free(def.name);
        alloc.free(def.version);
        if (def.description) |d| alloc.free(d);
        if (def.stage) |s| alloc.free(s);
        bpm.definition.freeDefinitionGraph(alloc, def.graph);
    }

    const updated_def = try store.update(alloc, def.id, .{
        .name = null,
        .version = null,
        .description = "obs03 integration updated",
        .graph = null,
        .stage = null,
    });
    defer {
        alloc.free(updated_def.name);
        alloc.free(updated_def.version);
        if (updated_def.description) |d| alloc.free(d);
        if (updated_def.stage) |s| alloc.free(s);
        bpm.definition.freeDefinitionGraph(alloc, updated_def.graph);
    }

    const def_id = try uuidToString(alloc, def.id);
    defer alloc.free(def_id);

    const conn = try pool.acquire();
    defer pool.release(conn);

    const rows = try conn.query(
        alloc,
        \\SELECT
        \\  audit_id::text,
        \\  actor_id::text,
        \\  action,
        \\  resource_type,
        \\  resource_id::text,
        \\  to_char("timestamp" AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        \\  before_state::text,
        \\  after_state::text
        \\FROM audit_entries
        \\WHERE resource_id = $1::uuid
        \\ORDER BY "timestamp" ASC, audit_id ASC
    ,
        &.{def_id},
    );
    defer {
        var r = rows;
        r.deinit();
    }

    try testing.expect(rows.rows.len >= 2);

    const first = rows.rows[0];
    const first_audit_id = first[0] orelse return error.TestUnexpectedResult;
    const first_actor_id = first[1] orelse return error.TestUnexpectedResult;
    const first_action = first[2] orelse return error.TestUnexpectedResult;
    const first_resource_type = first[3] orelse return error.TestUnexpectedResult;
    const first_resource_id = first[4] orelse return error.TestUnexpectedResult;
    const first_ts = first[5] orelse return error.TestUnexpectedResult;

    try testing.expect(first_audit_id.len > 0);
    try testing.expect(first_actor_id.len > 0);
    try testing.expectEqualStrings("definition.create", first_action);
    try testing.expectEqualStrings("definition", first_resource_type);
    try testing.expectEqualStrings(def_id, first_resource_id);
    try testing.expect(first_ts.len > 0);
    try testing.expect(first[6] == null);
    try testing.expect(first[7] != null);

    const user_id = "00000000-0000-0000-0000-0000000000a1";
    const token_id = "00000000-0000-0000-0000-0000000000b1";
    cleanupUserByEmail(conn, "obs03-delete-audit@example.test");
    cleanupUserAndToken(conn, user_id, token_id);
    defer cleanupUserAndToken(conn, user_id, token_id);
    try seedUserAndToken(
        conn,
        user_id,
        "obs03-delete-audit@example.test",
        token_id,
        "tc-obs03-delete-audit-token",
        "obs03_delete_hash_a1",
    );

    try conn.exec("DELETE FROM api_tokens WHERE id = $1::uuid", &.{token_id});

    const delete_count = try countRows(
        conn,
        alloc,
        \\SELECT COUNT(*)::text
        \\FROM audit_entries
        \\WHERE resource_type = 'token'
        \\  AND resource_id = $1::uuid
        \\  AND action = 'token.delete'
        \\  AND before_state IS NOT NULL
        \\  AND after_state IS NULL
    ,
        &.{token_id},
    );
    try testing.expect(delete_count >= 1);
}

test "TC-OBS-03-INT-02: read-only GET/list operations do not create audit rows" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const name = "tc-obs03-read-only";
    const version = "1.0.0";
    cleanupDefinition(&pool, name, version);
    defer cleanupDefinition(&pool, name, version);

    var store = DefinitionStore.init(alloc, &pool);
    defer store.deinit();

    const creator = try parseUuid("00000000-0000-0000-0000-000000000199");
    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null },
        .{ .id = "E", .node_type = .END, .label = null },
    };
    const edges = [_]GraphEdge{.{ .id = "e1", .source = "S", .target = "E", .condition = null }};

    const def = try store.create(alloc, CreateParams{
        .name = name,
        .version = version,
        .description = "obs03 read-only",
        .graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges },
        .created_by = creator,
    });
    defer {
        alloc.free(def.name);
        alloc.free(def.version);
        if (def.description) |d| alloc.free(d);
        if (def.stage) |s| alloc.free(s);
        bpm.definition.freeDefinitionGraph(alloc, def.graph);
    }

    const def_id = try uuidToString(alloc, def.id);
    defer alloc.free(def_id);

    const conn = try pool.acquire();
    defer pool.release(conn);

    const before_count = try countRows(
        conn,
        alloc,
        "SELECT COUNT(*)::text FROM audit_entries WHERE resource_id = $1::uuid",
        &.{def_id},
    );

    const fetched = try store.getById(alloc, def.id);
    defer {
        alloc.free(fetched.name);
        alloc.free(fetched.version);
        if (fetched.description) |d| alloc.free(d);
        if (fetched.stage) |s| alloc.free(s);
        bpm.definition.freeDefinitionGraph(alloc, fetched.graph);
    }

    const list_result = bpm.audit_routes.handleList(&pool, alloc, .{
        .resource_type = "definition",
        .resource_id = def_id,
        .actor_id = "00000000-0000-0000-0000-000000000199",
        .page_size = 10,
    });
    defer alloc.free(list_result.body);
    try testing.expectEqual(@as(u16, 200), list_result.status_code);

    const after_count = try countRows(
        conn,
        alloc,
        "SELECT COUNT(*)::text FROM audit_entries WHERE resource_id = $1::uuid",
        &.{def_id},
    );

    try testing.expectEqual(before_count, after_count);
}

test "TC-OBS-03-INT-03: audit insert failure rolls back business write" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const def_id = "00000000-0000-0000-0000-000000000301";
    const creator = "00000000-0000-0000-0000-000000000302";
    const name = "tc-obs03-rollback-failure";
    const version = "1.0.0";

    cleanupDefinition(&pool, name, version);
    defer cleanupDefinition(&pool, name, version);

    try conn.exec(
        \\CREATE OR REPLACE FUNCTION bpm_test_fail_audit_insert()
        \\RETURNS TRIGGER
        \\LANGUAGE plpgsql
        \\AS $$
        \\BEGIN
        \\  RAISE EXCEPTION 'forced audit insert failure for test';
        \\END;
        \\$$
    ,
        &.{},
    );
    try conn.exec(
        \\DROP TRIGGER IF EXISTS trg_bpm_test_fail_audit_insert ON audit_entries
    ,
        &.{},
    );
    try conn.exec(
        \\CREATE TRIGGER trg_bpm_test_fail_audit_insert
        \\BEFORE INSERT ON audit_entries
        \\FOR EACH ROW EXECUTE FUNCTION bpm_test_fail_audit_insert()
    ,
        &.{},
    );
    defer {
        conn.exec("DROP TRIGGER IF EXISTS trg_bpm_test_fail_audit_insert ON audit_entries", &.{}) catch {};
        conn.exec("DROP FUNCTION IF EXISTS bpm_test_fail_audit_insert()", &.{}) catch {};
    }

    const insert_err = conn.exec(
        \\INSERT INTO process_definitions
        \\  (id, name, version, description, status, graph, created_by)
        \\VALUES
        \\  ($1::uuid, $2, $3, 'rollback test', 'DRAFT', '{"nodes":[],"edges":[]}'::jsonb, $4::uuid)
    ,
        &.{ def_id, name, version, creator },
    );
    try testing.expectError(error.QueryFailed, insert_err);

    const definition_count = try countRows(
        conn,
        alloc,
        "SELECT COUNT(*)::text FROM process_definitions WHERE id = $1::uuid",
        &.{def_id},
    );
    try testing.expectEqual(@as(usize, 0), definition_count);

    const audit_count = try countRows(
        conn,
        alloc,
        "SELECT COUNT(*)::text FROM audit_entries WHERE resource_id = $1::uuid",
        &.{def_id},
    );
    try testing.expectEqual(@as(usize, 0), audit_count);
}

test "TC-OBS-03-INT-04: audit rows are immutable against update and delete" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const audit_id = try dbUuidString(conn, alloc);
    defer alloc.free(audit_id);
    const actor_id = try dbUuidString(conn, alloc);
    defer alloc.free(actor_id);
    const resource_id = try dbUuidString(conn, alloc);
    defer alloc.free(resource_id);

    cleanupAuditInsertFailureHook(conn);

    try conn.exec(
        \\INSERT INTO audit_entries
        \\  (audit_id, actor_id, action, resource_type, resource_id, timestamp, before_state, after_state)
        \\VALUES
        \\  ($1::uuid, $2::uuid, 'definition.create', 'definition', $3::uuid, '2026-05-25T09:00:00Z'::timestamptz, NULL, '{"status":"DRAFT"}'::jsonb)
    ,
        &.{ audit_id, actor_id, resource_id },
    );

    const update_err = conn.exec(
        "UPDATE audit_entries SET action = 'definition.update' WHERE audit_id = $1::uuid",
        &.{audit_id},
    );
    try testing.expectError(error.QueryFailed, update_err);

    const delete_err = conn.exec(
        "DELETE FROM audit_entries WHERE audit_id = $1::uuid",
        &.{audit_id},
    );
    try testing.expectError(error.QueryFailed, delete_err);

    const row = (try conn.queryRow(
        alloc,
        "SELECT action FROM audit_entries WHERE audit_id = $1::uuid",
        &.{audit_id},
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (row[0]) |v| alloc.free(v);
        alloc.free(row);
    }

    try testing.expectEqualStrings("definition.create", row[0] orelse "");
}

test "TC-OBS-03-INT-05: GET /audit supports filters with deterministic pagination and ordering" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const actor_a = try dbUuidString(conn, alloc);
    defer alloc.free(actor_a);
    const actor_b = try dbUuidString(conn, alloc);
    defer alloc.free(actor_b);
    const rid_a1 = try dbUuidString(conn, alloc);
    defer alloc.free(rid_a1);
    const rid_a2 = try dbUuidString(conn, alloc);
    defer alloc.free(rid_a2);
    const rid_b = try dbUuidString(conn, alloc);
    defer alloc.free(rid_b);
    const audit_a1 = try dbUuidString(conn, alloc);
    defer alloc.free(audit_a1);
    const audit_a2 = try dbUuidString(conn, alloc);
    defer alloc.free(audit_a2);
    const audit_b = try dbUuidString(conn, alloc);
    defer alloc.free(audit_b);

    cleanupAuditInsertFailureHook(conn);

    try conn.exec(
        \\INSERT INTO audit_entries (audit_id, actor_id, action, resource_type, resource_id, timestamp, before_state, after_state)
        \\VALUES
        \\  ($1::uuid, $2::uuid, 'definition.update', 'definition', $3::uuid, NOW() - INTERVAL '2 second', '{"status":"DRAFT"}'::jsonb, '{"status":"DRAFT"}'::jsonb),
        \\  ($4::uuid, $2::uuid, 'definition.activate', 'definition', $5::uuid, NOW() - INTERVAL '1 second', '{"status":"DRAFT"}'::jsonb, '{"status":"ACTIVE"}'::jsonb),
        \\  ($6::uuid, $7::uuid, 'task.complete', 'task', $8::uuid, NOW() - INTERVAL '1 minute', '{"status":"OPEN"}'::jsonb, '{"status":"COMPLETED"}'::jsonb)
    ,
        &.{ audit_a1, actor_a, rid_a1, audit_a2, rid_a2, audit_b, actor_b, rid_b },
    );

    const first_page = bpm.audit_routes.handleList(&pool, alloc, .{
        .actor_id = actor_a,
        .resource_type = "definition",
        .from = "2000-01-01T00:00:00Z",
        .to = "2100-01-01T00:00:00Z",
        .page_size = 1,
    });
    defer alloc.free(first_page.body);

    try testing.expectEqual(@as(u16, 200), first_page.status_code);
    try testing.expect(std.mem.indexOf(u8, first_page.body, audit_a2) != null);
    try testing.expect(std.mem.indexOf(u8, first_page.body, audit_b) == null);

    const next_cursor = try extractJsonStringField(alloc, first_page.body, "next_cursor");
    defer if (next_cursor) |c| alloc.free(c);
    try testing.expect(next_cursor != null);

    const second_page = bpm.audit_routes.handleList(&pool, alloc, .{
        .actor_id = actor_a,
        .resource_type = "definition",
        .from = "2000-01-01T00:00:00Z",
        .to = "2100-01-01T00:00:00Z",
        .cursor = next_cursor.?,
        .page_size = 1,
    });
    defer alloc.free(second_page.body);

    try testing.expectEqual(@as(u16, 200), second_page.status_code);
    try testing.expect(std.mem.indexOf(u8, second_page.body, audit_a1) != null);

    const scoped_page = bpm.audit_routes.handleList(&pool, alloc, .{
        .resource_id = rid_a1,
        .page_size = 5,
    });
    defer alloc.free(scoped_page.body);
    try testing.expectEqual(@as(u16, 200), scoped_page.status_code);
    try testing.expect(std.mem.indexOf(u8, scoped_page.body, audit_a1) != null);
    try testing.expect(std.mem.indexOf(u8, scoped_page.body, audit_a2) == null);

    const invalid_window = bpm.audit_routes.handleList(&pool, alloc, .{
        .from = "2026-05-25T11:00:00Z",
        .to = "2026-05-25T10:00:00Z",
    });
    defer alloc.free(invalid_window.body);
    try testing.expectEqual(@as(u16, 422), invalid_window.status_code);
}

test "TC-OBS-03-INT-06: canceled-token post-auth action remains audited" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const user_id = "00000000-0000-0000-0000-000000000601";
    const token_id = "00000000-0000-0000-0000-000000000602";

    cleanupUserByEmail(conn, "obs03-revoke-audit@example.test");
    cleanupUserAndToken(conn, user_id, token_id);
    defer cleanupUserAndToken(conn, user_id, token_id);

    try seedUserAndToken(
        conn,
        user_id,
        "obs03-revoke-audit@example.test",
        token_id,
        "tc-obs03-revoke-token",
        "obs03_revoke_hash_601",
    );

    try conn.begin();
    errdefer conn.rollback() catch {};

    try conn.exec("SELECT set_config('bpm.actor_id', $1, true)", &.{user_id});
    try conn.exec("UPDATE api_tokens SET revoked_at = NOW() WHERE id = $1::uuid", &.{token_id});
    try conn.commit();

    const audit_count = try countRows(
        conn,
        alloc,
        \\SELECT COUNT(*)::text
        \\FROM audit_entries
        \\WHERE resource_type = 'token'
        \\  AND resource_id = $1::uuid
        \\  AND action = 'token.revoke'
        \\  AND actor_id = $2::uuid
    ,
        &.{ token_id, user_id },
    );
    try testing.expect(audit_count >= 1);
}
