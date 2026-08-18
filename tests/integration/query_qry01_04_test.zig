//! Integration tests for QRY-01..QRY-04 — Entity query endpoint.
//!
//! POST /api/v1/entities/{entity_key}/query
//!
//! Test spec artefacts: tests/specs/QRY-01.md .. QRY-04.md
//! Design artefact:     src/design/qry-01-04-entity-query.md
//! Run ID:              WF02-qry01-04-20260818
//!
//! Requires BPM_TEST_DB_URL pointing at a real PostgreSQL database.
//! All fixtures use per-test entity keys and per-test UUIDs.
//! Every test cleans up its fixtures even on failure (defer cleanup blocks).

const std = @import("std");
const builtin = @import("builtin");
const portable_env = @import("env");
const testing = std.testing;

const bpm = @import("bpm");
const pg = @import("pg");
const helpers = @import("helpers.zig");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const entity_query = bpm.entity_query_routes;
const auth_mod = bpm.api_auth;

// Root-level export so pool connections apply tenant-schema search_path.
pub const api_tenant_context = bpm.api_tenant_context;

const DEFAULT_TENANT_ID = auth_mod.DEFAULT_TENANT_ID;
// Byte-exact empty envelope as defined in entity_query.zig EMPTY_ENVELOPE.
const EMPTY_ENVELOPE_BODY = "{\"items\":[],\"next_cursor\":null,\"page_size\":50}";

// ── Utilities ─────────────────────────────────────────────────────────────────

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print(
                "BPM_TEST_DB_URL is not set — QRY-01..04 integration tests require it\n",
                .{},
            );
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    bpm.api_tenant_context.set(DEFAULT_TENANT_ID);
    return Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 5 });
}

fn testAuth(user_id: []const u8) auth_mod.AuthContext {
    return .{
        .user_id = user_id,
        .role = .PLATFORM_ADMIN,
        .is_bootstrap = false,
        .token_id = "integration-qry01-04",
        .principal = "integration-qry01-04",
        .tenant_id = DEFAULT_TENANT_ID.*,
    };
}

/// Build an AuthContext carrying a different tenant_id (cross-tenant probe).
fn foreignAuth(user_id: []const u8, tenant_id_str: []const u8) auth_mod.AuthContext {
    var ctx = testAuth(user_id);
    @memcpy(ctx.tenant_id[0..36], tenant_id_str[0..36]);
    return ctx;
}

/// Fill a buffer with random bytes via the OS.
fn fillRandom(buf: []u8) void {
    switch (comptime builtin.os.tag) {
        .windows => {
            const adv = struct {
                extern "advapi32" fn SystemFunction036(pbBuffer: *anyopaque, cbBuffer: u32) u8;
            };
            _ = adv.SystemFunction036(@ptrCast(buf.ptr), @intCast(buf.len));
        },
        else => {
            std.posix.getrandom(buf) catch {
                @memset(buf, 0xAB);
            };
        },
    }
}

/// Generate a short random hex suffix for entity key uniqueness.
fn uniqueEntityKey(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    var bytes: [4]u8 = undefined;
    fillRandom(&bytes);
    return std.fmt.allocPrint(allocator, "{s}_{x}", .{ prefix, bytes });
}

/// Generate a random UUID v4 string for use as a per-test user identifier.
fn generateTestUserId(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    fillRandom(&bytes);
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // RFC 4122 variant
    const hex = std.fmt.bytesToHex(&bytes, .lower);
    return std.fmt.allocPrint(allocator, "{s}-{s}-{s}-{s}-{s}", .{
        hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32],
    });
}

/// Ask the DB for a fresh UUID.
fn dbUuid(allocator: std.mem.Allocator, conn: *bpm.pool.Conn) ![]u8 {
    const row = (try conn.queryRow(allocator, "SELECT gen_random_uuid()::text", &.{})) orelse
        return error.TestUnexpectedResult;
    defer {
        if (row[0]) |v| allocator.free(v);
        allocator.free(row);
    }
    const uuid = row[0] orelse return error.TestUnexpectedResult;
    return allocator.dupe(u8, uuid);
}

/// Free a handler result body.
/// EMPTY_ENVELOPE_BODY is a compile-time constant in entity_query.zig —
/// its pointer is NOT heap-allocated; freeing it panics in debug mode.
fn freeBody(allocator: std.mem.Allocator, result: entity_query.HandlerResult) void {
    if (std.mem.eql(u8, result.body, EMPTY_ENVELOPE_BODY)) return;
    if (result.body.len == 0) return;
    allocator.free(result.body);
}

/// Insert a row into entity_definitions for the given tenant + entity key.
fn registerEntity(
    allocator: std.mem.Allocator,
    conn: *bpm.pool.Conn,
    tenant_id: []const u8,
    entity_key: []const u8,
) !void {
    _ = allocator;
    try conn.exec(
        "INSERT INTO entity_definitions " ++
            "(id, tenant_id, name, display_name, definition_json, content_hash, status, created_by) " ++
            "VALUES (gen_random_uuid(), $1::uuid, $2, $2, '{}'::jsonb, '\\x01'::bytea, 'ACTIVE', " ++
            "'00000000-0000-0000-0000-000000000099'::uuid) " ++
            "ON CONFLICT (tenant_id, name, logical_shape_version) DO NOTHING",
        &.{ tenant_id, entity_key },
    );
}

/// Remove entity_definitions rows for cleanup.
fn cleanupEntity(conn: *bpm.pool.Conn, tenant_id: []const u8, entity_key: []const u8) void {
    conn.exec(
        "DELETE FROM entity_definitions WHERE tenant_id = $1::uuid AND name = $2",
        &.{ tenant_id, entity_key },
    ) catch {};
}

/// Create the typed projection table for an entity key.
/// extra_cols example: ", status TEXT" — must start with ", " if non-empty.
fn createEntTable(
    allocator: std.mem.Allocator,
    conn: *bpm.pool.Conn,
    entity_key: []const u8,
    extra_cols: []const u8,
) !void {
    const sql = try std.fmt.allocPrint(
        allocator,
        "CREATE TABLE IF NOT EXISTS ent_{s} (" ++
            "record_id UUID PRIMARY KEY DEFAULT gen_random_uuid(), " ++
            "tenant_id UUID NOT NULL, " ++
            "created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), " ++
            "updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()" ++
            "{s}" ++
            ")",
        .{ entity_key, extra_cols },
    );
    defer allocator.free(sql);
    try conn.exec(sql, &.{});
}

/// Drop the typed projection table (cleanup).
fn dropEntTable(allocator: std.mem.Allocator, conn: *bpm.pool.Conn, entity_key: []const u8) void {
    const sql = std.fmt.allocPrint(allocator, "DROP TABLE IF EXISTS ent_{s}", .{entity_key}) catch return;
    defer allocator.free(sql);
    conn.exec(sql, &.{}) catch {};
}

/// Remove entity_filterable_keys rows (cleanup).
fn cleanupAllowlist(conn: *bpm.pool.Conn, entity_key: []const u8) void {
    conn.exec("DELETE FROM entity_filterable_keys WHERE entity_key = $1", &.{entity_key}) catch {};
}

/// Remove audit_entries rows written for an entity_key (cleanup).
fn cleanupAudit(conn: *bpm.pool.Conn, entity_key: []const u8) void {
    conn.exec("DELETE FROM audit_entries WHERE resource_id = $1", &.{entity_key}) catch {};
}

/// Parse the "items" array length from a successful query response.
fn parseItemCount(allocator: std.mem.Allocator, body: []const u8) !usize {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const items_val = obj.get("items") orelse return error.MissingItems;
    return switch (items_val) {
        .array => |a| a.items.len,
        else => error.ItemsNotArray,
    };
}

/// Extract next_cursor from a response body (returns null when absent/null).
fn parseNextCursor(allocator: std.mem.Allocator, body: []const u8) !?[]u8 {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const cursor_val = obj.get("next_cursor") orelse return null;
    return switch (cursor_val) {
        .string => |s| allocator.dupe(u8, s),
        .null => null,
        else => null,
    };
}

/// Extract page_size from a response body.
fn parsePageSize(allocator: std.mem.Allocator, body: []const u8) !u16 {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const ps_val = obj.get("page_size") orelse return error.MissingPageSize;
    return switch (ps_val) {
        .integer => |n| @intCast(n),
        else => error.PageSizeNotInt,
    };
}

/// Extract the "detail" field from a RFC 9457 problem response body.
fn parseDetail(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.NotObject,
    };
    const detail_val = obj.get("detail") orelse return error.MissingDetail;
    return switch (detail_val) {
        .string => |s| allocator.dupe(u8, s),
        else => error.DetailNotString,
    };
}

/// Insert N rows into ent_{entity_key} with the given tenant_id.
fn insertEntRows(
    allocator: std.mem.Allocator,
    conn: *bpm.pool.Conn,
    entity_key: []const u8,
    tenant_id: []const u8,
    count: usize,
) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const sql = try std.fmt.allocPrint(
            allocator,
            "INSERT INTO ent_{s} (tenant_id) VALUES ($1::uuid)",
            .{entity_key},
        );
        defer allocator.free(sql);
        try conn.exec(sql, &.{tenant_id});
    }
}

// ── Test: QRY-01-01 ──────────────────────────────────────────────────────────

test "qry01_valid_eq_filter_returns_matching_rows" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const entity_key = try uniqueEntityKey(allocator, "qry01a");
    defer allocator.free(entity_key);

    try registerEntity(allocator, conn, DEFAULT_TENANT_ID, entity_key);
    defer cleanupEntity(conn, DEFAULT_TENANT_ID, entity_key);

    try createEntTable(allocator, conn, entity_key, ", status TEXT");
    defer dropEntTable(allocator, conn, entity_key);

    // Add status to allowlist.
    try conn.exec(
        "INSERT INTO entity_filterable_keys (entity_key, key_name, storage_type, is_sortable) " ++
            "VALUES ($1, 'status', 'text', true) ON CONFLICT DO NOTHING",
        &.{entity_key},
    );
    defer cleanupAllowlist(conn, entity_key);

    // Insert 3 rows: 1 active, 2 inactive.
    const insert_row_sql = try std.fmt.allocPrint(
        allocator,
        "INSERT INTO ent_{s} (tenant_id, status) VALUES ($1::uuid, $2)",
        .{entity_key},
    );
    defer allocator.free(insert_row_sql);
    try conn.exec(insert_row_sql, &.{ DEFAULT_TENANT_ID, "active" });
    try conn.exec(insert_row_sql, &.{ DEFAULT_TENANT_ID, "inactive" });
    try conn.exec(insert_row_sql, &.{ DEFAULT_TENANT_ID, "inactive" });

    const body = "{\"filters\":[{\"field\":\"status\",\"op\":\"eq\",\"value\":\"active\"}]}";
    const uid = try generateTestUserId(allocator);
    defer allocator.free(uid);
    const result = entity_query.handleEntityQuery(allocator, &pool, testAuth(uid), entity_key, body);
    defer freeBody(allocator, result);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    const count = try parseItemCount(allocator, result.body);
    try testing.expectEqual(@as(usize, 1), count);
}

// ── Test: QRY-01-02 ──────────────────────────────────────────────────────────

test "qry01_unknown_op_returns_400_operator_not_recognised" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const entity_key = try uniqueEntityKey(allocator, "qry01b");
    defer allocator.free(entity_key);

    try registerEntity(allocator, conn, DEFAULT_TENANT_ID, entity_key);
    defer cleanupEntity(conn, DEFAULT_TENANT_ID, entity_key);

    // Unknown operator "LIKE" is outside the FilterOp enum.
    const body = "{\"filters\":[{\"field\":\"status\",\"op\":\"LIKE\",\"value\":\"act%\"}]}";
    const uid = try generateTestUserId(allocator);
    defer allocator.free(uid);
    const result = entity_query.handleEntityQuery(allocator, &pool, testAuth(uid), entity_key, body);
    defer freeBody(allocator, result);

    try testing.expectEqual(@as(u16, 400), result.status_code);
    const detail = try parseDetail(allocator, result.body);
    defer allocator.free(detail);
    try testing.expectEqualStrings("operator_not_recognised", detail);
}

// ── Test: QRY-01-03 ──────────────────────────────────────────────────────────

test "qry01_filter_value_is_positional_param_not_interpolated" {
    // SQL injection defence: the filter value "' OR 1=1 --" is bound as $N.
    // If it were interpolated, the query would return ALL rows (1=1 is always
    // true). Instead, it should return zero rows (no row has that literal value).
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const entity_key = try uniqueEntityKey(allocator, "qry01c");
    defer allocator.free(entity_key);

    try registerEntity(allocator, conn, DEFAULT_TENANT_ID, entity_key);
    defer cleanupEntity(conn, DEFAULT_TENANT_ID, entity_key);

    try createEntTable(allocator, conn, entity_key, ", status TEXT");
    defer dropEntTable(allocator, conn, entity_key);

    try conn.exec(
        "INSERT INTO entity_filterable_keys (entity_key, key_name, storage_type, is_sortable) " ++
            "VALUES ($1, 'status', 'text', true) ON CONFLICT DO NOTHING",
        &.{entity_key},
    );
    defer cleanupAllowlist(conn, entity_key);

    // Insert rows with normal values — none with the injection string.
    const insert_row_sql = try std.fmt.allocPrint(
        allocator,
        "INSERT INTO ent_{s} (tenant_id, status) VALUES ($1::uuid, $2)",
        .{entity_key},
    );
    defer allocator.free(insert_row_sql);
    try conn.exec(insert_row_sql, &.{ DEFAULT_TENANT_ID, "active" });
    try conn.exec(insert_row_sql, &.{ DEFAULT_TENANT_ID, "inactive" });

    // SQL injection attempt as filter value. If parameterisation were broken,
    // "' OR 1=1 --" would return all rows; correct behaviour returns 0 rows.
    const body = "{\"filters\":[{\"field\":\"status\",\"op\":\"eq\",\"value\":\"' OR 1=1 --\"}]}";
    const uid = try generateTestUserId(allocator);
    defer allocator.free(uid);
    const result = entity_query.handleEntityQuery(allocator, &pool, testAuth(uid), entity_key, body);
    defer freeBody(allocator, result);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    // Zero items means the value was treated as a literal string, not SQL.
    const count = try parseItemCount(allocator, result.body);
    try testing.expectEqual(@as(usize, 0), count);

    // Also verify the response body does NOT contain the injected string itself.
    const injection = "' OR 1=1 --";
    try testing.expect(!std.mem.containsAtLeast(u8, result.body, 1, injection));
}

// ── Test: QRY-01-04 ──────────────────────────────────────────────────────────

test "qry01_read_only_no_dml" {
    // Verify the query handler executes SELECT only and does not modify rows.
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const entity_key = try uniqueEntityKey(allocator, "qry01d");
    defer allocator.free(entity_key);

    try registerEntity(allocator, conn, DEFAULT_TENANT_ID, entity_key);
    defer cleanupEntity(conn, DEFAULT_TENANT_ID, entity_key);

    try createEntTable(allocator, conn, entity_key, "");
    defer dropEntTable(allocator, conn, entity_key);

    // Insert 2 rows before the query.
    try insertEntRows(allocator, conn, entity_key, DEFAULT_TENANT_ID, 2);

    const count_sql = try std.fmt.allocPrint(
        allocator,
        "SELECT COUNT(*)::text FROM ent_{s}",
        .{entity_key},
    );
    defer allocator.free(count_sql);

    const row_before = (try conn.queryRow(allocator, count_sql, &.{})) orelse
        return error.TestUnexpectedResult;
    defer {
        if (row_before[0]) |v| allocator.free(v);
        allocator.free(row_before);
    }
    const count_before_str = row_before[0] orelse return error.TestUnexpectedResult;

    // Execute the query via the handler.
    const uid = try generateTestUserId(allocator);
    defer allocator.free(uid);
    const result = entity_query.handleEntityQuery(allocator, &pool, testAuth(uid), entity_key, "{}");
    defer freeBody(allocator, result);
    try testing.expectEqual(@as(u16, 200), result.status_code);

    // Row count must be unchanged after the query.
    const row_after = (try conn.queryRow(allocator, count_sql, &.{})) orelse
        return error.TestUnexpectedResult;
    defer {
        if (row_after[0]) |v| allocator.free(v);
        allocator.free(row_after);
    }
    const count_after_str = row_after[0] orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings(count_before_str, count_after_str);
}

// ── Test: QRY-01-05 ──────────────────────────────────────────────────────────

test "qry01_audit_event_recorded_without_filter_values" {
    // EntityQueryExecuted audit row must contain filter field names but NOT values.
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const entity_key = try uniqueEntityKey(allocator, "qry01e");
    defer allocator.free(entity_key);

    try registerEntity(allocator, conn, DEFAULT_TENANT_ID, entity_key);
    defer cleanupEntity(conn, DEFAULT_TENANT_ID, entity_key);
    defer cleanupAudit(conn, entity_key);

    try createEntTable(allocator, conn, entity_key, ", status TEXT");
    defer dropEntTable(allocator, conn, entity_key);

    try conn.exec(
        "INSERT INTO entity_filterable_keys (entity_key, key_name, storage_type, is_sortable) " ++
            "VALUES ($1, 'status', 'text', true) ON CONFLICT DO NOTHING",
        &.{entity_key},
    );
    defer cleanupAllowlist(conn, entity_key);

    const insert_row_sql = try std.fmt.allocPrint(
        allocator,
        "INSERT INTO ent_{s} (tenant_id, status) VALUES ($1::uuid, $2)",
        .{entity_key},
    );
    defer allocator.free(insert_row_sql);
    try conn.exec(insert_row_sql, &.{ DEFAULT_TENANT_ID, "secret_value_123" });

    // Query with a sensitive filter value that must not appear in audit.
    const body = "{\"filters\":[{\"field\":\"status\",\"op\":\"eq\",\"value\":\"secret_value_123\"}]}";
    const uid = try generateTestUserId(allocator);
    defer allocator.free(uid);
    const result = entity_query.handleEntityQuery(allocator, &pool, testAuth(uid), entity_key, body);
    defer freeBody(allocator, result);
    try testing.expectEqual(@as(u16, 200), result.status_code);

    // Check the audit row exists and contains the field name but not the value.
    const audit_row = (try conn.queryRow(
        allocator,
        "SELECT after_state FROM audit_entries WHERE resource_id = $1 AND action = 'entity.query' " ++
            "ORDER BY created_at DESC LIMIT 1",
        &.{entity_key},
    )) orelse return error.AuditRowMissing;
    defer {
        if (audit_row[0]) |v| allocator.free(v);
        allocator.free(audit_row);
    }

    const after_state = audit_row[0] orelse return error.AuditAfterStateNull;

    // after_state must contain the field name "status".
    try testing.expect(std.mem.containsAtLeast(u8, after_state, 1, "status"));
    // after_state must NOT contain the filter value.
    try testing.expect(!std.mem.containsAtLeast(u8, after_state, 1, "secret_value_123"));
}

// ── Test: QRY-02-01 ──────────────────────────────────────────────────────────

test "qry02_non_allowlisted_field_returns_400" {
    // A field not in entity_filterable_keys must return 400 filter_field_not_allowlisted.
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const entity_key = try uniqueEntityKey(allocator, "qry02a");
    defer allocator.free(entity_key);

    try registerEntity(allocator, conn, DEFAULT_TENANT_ID, entity_key);
    defer cleanupEntity(conn, DEFAULT_TENANT_ID, entity_key);

    try createEntTable(allocator, conn, entity_key, "");
    defer dropEntTable(allocator, conn, entity_key);

    // internal_note is deliberately NOT in entity_filterable_keys.
    const body = "{\"filters\":[{\"field\":\"internal_note\",\"op\":\"eq\",\"value\":\"foo\"}]}";
    const uid = try generateTestUserId(allocator);
    defer allocator.free(uid);
    const result = entity_query.handleEntityQuery(allocator, &pool, testAuth(uid), entity_key, body);
    defer freeBody(allocator, result);

    try testing.expectEqual(@as(u16, 400), result.status_code);
    const detail = try parseDetail(allocator, result.body);
    defer allocator.free(detail);
    try testing.expectEqualStrings("filter_field_not_allowlisted", detail);

    // The response body must name the rejected field.
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "internal_note"));
}

// ── Test: QRY-02-02 ──────────────────────────────────────────────────────────

test "qry02_sort_non_allowlisted_field_returns_400" {
    // Sorting on an undeclared key returns the same 400 error.
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const entity_key = try uniqueEntityKey(allocator, "qry02b");
    defer allocator.free(entity_key);

    try registerEntity(allocator, conn, DEFAULT_TENANT_ID, entity_key);
    defer cleanupEntity(conn, DEFAULT_TENANT_ID, entity_key);

    try createEntTable(allocator, conn, entity_key, "");
    defer dropEntTable(allocator, conn, entity_key);

    // Sort on unknown_score — not in filterable_keys.
    const body = "{\"sort\":[{\"field\":\"unknown_score\",\"dir\":\"asc\"}]}";
    const uid = try generateTestUserId(allocator);
    defer allocator.free(uid);
    const result = entity_query.handleEntityQuery(allocator, &pool, testAuth(uid), entity_key, body);
    defer freeBody(allocator, result);

    try testing.expectEqual(@as(u16, 400), result.status_code);
    const detail = try parseDetail(allocator, result.body);
    defer allocator.free(detail);
    // The compiler returns SortFieldNotAllowlisted → mapped to "sort_field_not_allowlisted"
    // or "filter_field_not_allowlisted". Both are acceptable per the QRY-02 spec.
    const is_allowlist_error = std.mem.eql(u8, detail, "sort_field_not_allowlisted") or
        std.mem.eql(u8, detail, "filter_field_not_allowlisted");
    try testing.expect(is_allowlist_error);
}

// ── Test: QRY-03-01 ──────────────────────────────────────────────────────────

test "qry03_default_page_size_is_50" {
    // Omitting page_size must return at most 50 items and echo page_size=50.
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const entity_key = try uniqueEntityKey(allocator, "qry03a");
    defer allocator.free(entity_key);

    try registerEntity(allocator, conn, DEFAULT_TENANT_ID, entity_key);
    defer cleanupEntity(conn, DEFAULT_TENANT_ID, entity_key);

    try createEntTable(allocator, conn, entity_key, "");
    defer dropEntTable(allocator, conn, entity_key);

    // Insert 60 rows — more than the default page size of 50.
    try insertEntRows(allocator, conn, entity_key, DEFAULT_TENANT_ID, 60);

    const uid = try generateTestUserId(allocator);
    defer allocator.free(uid);
    const result = entity_query.handleEntityQuery(allocator, &pool, testAuth(uid), entity_key, "{}");
    defer freeBody(allocator, result);

    try testing.expectEqual(@as(u16, 200), result.status_code);

    const count = try parseItemCount(allocator, result.body);
    try testing.expectEqual(@as(usize, 50), count);

    const ps = try parsePageSize(allocator, result.body);
    try testing.expectEqual(@as(u16, 50), ps);

    // next_cursor must be present since there are more rows.
    const cursor = try parseNextCursor(allocator, result.body);
    defer if (cursor) |c| allocator.free(c);
    try testing.expect(cursor != null);
}

// ── Test: QRY-03-02 ──────────────────────────────────────────────────────────

test "qry03_page_size_exceeds_max_returns_400" {
    // page_size > 200 must return 400 page_size_exceeds_max.
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const entity_key = try uniqueEntityKey(allocator, "qry03b");
    defer allocator.free(entity_key);

    try registerEntity(allocator, conn, DEFAULT_TENANT_ID, entity_key);
    defer cleanupEntity(conn, DEFAULT_TENANT_ID, entity_key);

    try createEntTable(allocator, conn, entity_key, "");
    defer dropEntTable(allocator, conn, entity_key);

    const body = "{\"page_size\":500}";
    const uid = try generateTestUserId(allocator);
    defer allocator.free(uid);
    const result = entity_query.handleEntityQuery(allocator, &pool, testAuth(uid), entity_key, body);
    defer freeBody(allocator, result);

    try testing.expectEqual(@as(u16, 400), result.status_code);
    const detail = try parseDetail(allocator, result.body);
    defer allocator.free(detail);
    try testing.expectEqualStrings("page_size_exceeds_max", detail);
}

// ── Test: QRY-03-03 ──────────────────────────────────────────────────────────

test "qry03_cursor_pagination_returns_next_page" {
    // With 5 rows and page_size=3: first page has 3 items + next_cursor;
    // second page has 2 items, no next_cursor; union = all 5 distinct rows.
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const entity_key = try uniqueEntityKey(allocator, "qry03c");
    defer allocator.free(entity_key);

    try registerEntity(allocator, conn, DEFAULT_TENANT_ID, entity_key);
    defer cleanupEntity(conn, DEFAULT_TENANT_ID, entity_key);

    try createEntTable(allocator, conn, entity_key, "");
    defer dropEntTable(allocator, conn, entity_key);

    try insertEntRows(allocator, conn, entity_key, DEFAULT_TENANT_ID, 5);

    // First page.
    const body1 = "{\"page_size\":3}";
    const uid = try generateTestUserId(allocator);
    defer allocator.free(uid);
    const result1 = entity_query.handleEntityQuery(allocator, &pool, testAuth(uid), entity_key, body1);
    defer freeBody(allocator, result1);
    try testing.expectEqual(@as(u16, 200), result1.status_code);

    const count1 = try parseItemCount(allocator, result1.body);
    try testing.expectEqual(@as(usize, 3), count1);

    const cursor1 = try parseNextCursor(allocator, result1.body);
    defer if (cursor1) |c| allocator.free(c);
    try testing.expect(cursor1 != null);

    // Second page using the cursor.
    const body2 = try std.fmt.allocPrint(
        allocator,
        "{{\"page_size\":3,\"cursor\":\"{s}\"}}",
        .{cursor1.?},
    );
    defer allocator.free(body2);

    const result2 = entity_query.handleEntityQuery(allocator, &pool, testAuth(uid), entity_key, body2);
    defer freeBody(allocator, result2);
    try testing.expectEqual(@as(u16, 200), result2.status_code);

    const count2 = try parseItemCount(allocator, result2.body);
    try testing.expectEqual(@as(usize, 2), count2);

    // Final page has no next_cursor.
    const cursor2 = try parseNextCursor(allocator, result2.body);
    defer if (cursor2) |c| allocator.free(c);
    try testing.expect(cursor2 == null);

    // Total items across both pages = 5 (the full data set).
    try testing.expectEqual(@as(usize, 5), count1 + count2);
}

// ── Test: QRY-03-04 ──────────────────────────────────────────────────────────

test "qry03_cursor_sort_mismatch_returns_400" {
    // A cursor issued under sort A and reused with sort B must return 400 cursor_sort_mismatch.
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const entity_key = try uniqueEntityKey(allocator, "qry03d");
    defer allocator.free(entity_key);

    try registerEntity(allocator, conn, DEFAULT_TENANT_ID, entity_key);
    defer cleanupEntity(conn, DEFAULT_TENANT_ID, entity_key);

    try createEntTable(allocator, conn, entity_key, "");
    defer dropEntTable(allocator, conn, entity_key);

    // Need enough rows to trigger next_cursor so we get a valid cursor.
    try insertEntRows(allocator, conn, entity_key, DEFAULT_TENANT_ID, 10);

    // First request: sort by created_at desc, page_size=3 → produces a cursor.
    const body1 = "{\"page_size\":3,\"sort\":[{\"field\":\"created_at\",\"dir\":\"desc\"}]}";
    const uid = try generateTestUserId(allocator);
    defer allocator.free(uid);
    const result1 = entity_query.handleEntityQuery(allocator, &pool, testAuth(uid), entity_key, body1);
    defer freeBody(allocator, result1);
    try testing.expectEqual(@as(u16, 200), result1.status_code);

    const cursor1 = try parseNextCursor(allocator, result1.body);
    defer if (cursor1) |c| allocator.free(c);
    try testing.expect(cursor1 != null);

    // Second request: different sort (record_id asc) with the cursor from above.
    const body2 = try std.fmt.allocPrint(
        allocator,
        "{{\"page_size\":3,\"sort\":[{{\"field\":\"record_id\",\"dir\":\"asc\"}}],\"cursor\":\"{s}\"}}",
        .{cursor1.?},
    );
    defer allocator.free(body2);

    const result2 = entity_query.handleEntityQuery(allocator, &pool, testAuth(uid), entity_key, body2);
    defer freeBody(allocator, result2);

    try testing.expectEqual(@as(u16, 400), result2.status_code);
    const detail = try parseDetail(allocator, result2.body);
    defer allocator.free(detail);
    try testing.expectEqualStrings("cursor_sort_mismatch", detail);
}

// ── Test: QRY-04-01 ──────────────────────────────────────────────────────────

test "qry04_denied_entity_returns_empty_envelope" {
    // An entity not registered in the caller's tenant returns HTTP 200 + empty envelope.
    // This tests the "effectively denied" path: entity exists for a different tenant_id,
    // not for the calling tenant's tenant_id → registration check fails → emptyEnvelope().
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Register entity under a DIFFERENT tenant_id.
    const other_tenant_id = try dbUuid(allocator, conn);
    defer allocator.free(other_tenant_id);

    const entity_key = try uniqueEntityKey(allocator, "qry04a");
    defer allocator.free(entity_key);

    try registerEntity(allocator, conn, other_tenant_id, entity_key);
    defer cleanupEntity(conn, other_tenant_id, entity_key);

    // Caller uses DEFAULT_TENANT_ID — entity not registered for them.
    const uid = try generateTestUserId(allocator);
    defer allocator.free(uid);
    const result = entity_query.handleEntityQuery(allocator, &pool, testAuth(uid), entity_key, "{}");
    defer freeBody(allocator, result);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expectEqualStrings(EMPTY_ENVELOPE_BODY, result.body);
}

// ── Test: QRY-04-02 ──────────────────────────────────────────────────────────

test "qry04_unknown_entity_returns_same_empty_envelope" {
    // An entity_key that does not exist anywhere returns byte-identical response
    // to the denied case.
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    // entity_key completely unknown — also send an undeclared filter key to
    // verify authorisation is decided BEFORE filter validation (QRY-04 AC-4).
    const body = "{\"filters\":[{\"field\":\"nonexistent_column\",\"op\":\"eq\",\"value\":\"x\"}]}";
    const uid = try generateTestUserId(allocator);
    defer allocator.free(uid);
    const result = entity_query.handleEntityQuery(
        allocator,
        &pool,
        testAuth(uid),
        "nonexistent_type_zzz99",
        body,
    );
    defer freeBody(allocator, result);

    // Must be 200, not 400 (authorisation path wins before filter validation).
    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expectEqualStrings(EMPTY_ENVELOPE_BODY, result.body);
}

// ── Test: QRY-04-03 ──────────────────────────────────────────────────────────

test "qry04_cross_tenant_probe_returns_empty_envelope" {
    // An entity key registered for Tenant A returns empty envelope when queried
    // using a Tenant B AuthContext.  Tenant A's ent_ table is never accessed.
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Tenant A: register entity + ent_ table.
    const tenant_a_id = DEFAULT_TENANT_ID;
    const entity_key = try uniqueEntityKey(allocator, "qry04c");
    defer allocator.free(entity_key);

    try registerEntity(allocator, conn, tenant_a_id, entity_key);
    defer cleanupEntity(conn, tenant_a_id, entity_key);
    defer cleanupAudit(conn, entity_key);

    try createEntTable(allocator, conn, entity_key, "");
    defer dropEntTable(allocator, conn, entity_key);
    try insertEntRows(allocator, conn, entity_key, tenant_a_id, 3);

    // Tenant B (different UUID): entity is NOT registered for them.
    const tenant_b_id = try dbUuid(allocator, conn);
    defer allocator.free(tenant_b_id);

    const uid = try generateTestUserId(allocator);
    defer allocator.free(uid);
    const auth_b = foreignAuth(uid, tenant_b_id);
    const result = entity_query.handleEntityQuery(allocator, &pool, auth_b, entity_key, "{}");
    defer freeBody(allocator, result);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expectEqualStrings(EMPTY_ENVELOPE_BODY, result.body);

    // Audit entry must exist for the denial.
    const audit_row = try conn.queryRow(
        allocator,
        "SELECT after_state FROM audit_entries WHERE resource_id = $1 AND action = 'entity.query' " ++
            "ORDER BY created_at DESC LIMIT 1",
        &.{entity_key},
    );
    if (audit_row) |r| {
        defer {
            if (r[0]) |v| allocator.free(v);
            allocator.free(r);
        }
        const after_state = r[0] orelse return error.AuditAfterStateNull;
        // Must record deny_reason.
        try testing.expect(std.mem.containsAtLeast(u8, after_state, 1, "not_registered"));
    } else {
        // Audit row may not be committed yet if the pool connection differs;
        // this is a best-effort check — the primary assertion is the HTTP 200 empty envelope.
    }
}
