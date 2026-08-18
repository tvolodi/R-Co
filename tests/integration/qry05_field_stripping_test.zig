//! Integration tests for QRY-05 — Entity query field stripping.
//!
//! POST /api/v1/entities/{entity_key}/query
//!
//! Test spec artefact: tests/specs/QRY-05.md
//! Design artefact:    src/design/WF02-qry05-sbx01-03-20260818.md
//! Run ID:             WF02-qry05-sbx01-03-20260818
//!
//! Requires BPM_TEST_DB_URL pointing at a real PostgreSQL database.
//! All fixtures use per-test entity keys and per-test UUIDs.
//! Every test cleans up its fixtures even on failure (defer cleanup blocks).

const std = @import("std");
const builtin = @import("builtin");
const portable_env = @import("env");
const testing = std.testing;

const bpm = @import("bpm");
const helpers = @import("helpers.zig");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const entity_query = bpm.entity_query_routes;
const auth_mod = bpm.api_auth;

pub const api_tenant_context = bpm.api_tenant_context;

const DEFAULT_TENANT_ID = auth_mod.DEFAULT_TENANT_ID;

// ── Utilities ─────────────────────────────────────────────────────────────────

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print(
                "BPM_TEST_DB_URL is not set — QRY-05 integration tests require it\n",
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
        .token_id = "integration-qry05",
        .principal = "integration-qry05",
        .tenant_id = DEFAULT_TENANT_ID.*,
    };
}

fn tenantAuth(user_id: []const u8, tenant_id_str: []const u8) auth_mod.AuthContext {
    var ctx = testAuth(user_id);
    @memcpy(ctx.tenant_id[0..36], tenant_id_str[0..36]);
    return ctx;
}

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

fn uniqueEntityKey(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    var bytes: [4]u8 = undefined;
    fillRandom(&bytes);
    return std.fmt.allocPrint(allocator, "{s}_{x}", .{ prefix, bytes });
}

fn generateTestUserId(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    fillRandom(&bytes);
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    const hex = std.fmt.bytesToHex(&bytes, .lower);
    return std.fmt.allocPrint(allocator, "{s}-{s}-{s}-{s}-{s}", .{
        hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32],
    });
}

fn freeBody(allocator: std.mem.Allocator, result: entity_query.HandlerResult) void {
    const EMPTY = "{\"items\":[],\"next_cursor\":null,\"page_size\":50}";
    if (std.mem.eql(u8, result.body, EMPTY)) return;
    if (result.body.len == 0) return;
    allocator.free(result.body);
}

/// Register an entity with a numeric typed column (for unit_cost_eur tests).
fn registerEntityWithNumericField(
    allocator: std.mem.Allocator,
    conn: *bpm.pool.Conn,
    tenant_id: []const u8,
    entity_key: []const u8,
    field_name: []const u8,
) !void {
    const def_json = try std.fmt.allocPrint(
        allocator,
        "{{\"fields\":[{{\"name\":\"{s}\",\"queried\":true,\"storage_type\":\"numeric\"}}]}}",
        .{field_name},
    );
    defer allocator.free(def_json);
    try conn.exec(
        "INSERT INTO entity_definitions " ++
            "(id, tenant_id, name, display_name, definition_json, content_hash, status, created_by) " ++
            "VALUES (gen_random_uuid(), $1::uuid, $2, $2, $3::jsonb, '\\x01'::bytea, 'ACTIVE', " ++
            "'00000000-0000-0000-0000-000000000099'::uuid) " ++
            "ON CONFLICT (tenant_id, name, logical_shape_version) DO NOTHING",
        &.{ tenant_id, entity_key, def_json },
    );
}

/// Register an entity with two numeric fields.
fn registerEntityWithTwoNumericFields(
    allocator: std.mem.Allocator,
    conn: *bpm.pool.Conn,
    tenant_id: []const u8,
    entity_key: []const u8,
    field1: []const u8,
    field2: []const u8,
) !void {
    const def_json = try std.fmt.allocPrint(
        allocator,
        "{{\"fields\":[" ++
            "{{\"name\":\"{s}\",\"queried\":true,\"storage_type\":\"numeric\"}}," ++
            "{{\"name\":\"{s}\",\"queried\":true,\"storage_type\":\"numeric\"}}" ++
            "]}}",
        .{ field1, field2 },
    );
    defer allocator.free(def_json);
    try conn.exec(
        "INSERT INTO entity_definitions " ++
            "(id, tenant_id, name, display_name, definition_json, content_hash, status, created_by) " ++
            "VALUES (gen_random_uuid(), $1::uuid, $2, $2, $3::jsonb, '\\x01'::bytea, 'ACTIVE', " ++
            "'00000000-0000-0000-0000-000000000099'::uuid) " ++
            "ON CONFLICT (tenant_id, name, logical_shape_version) DO NOTHING",
        &.{ tenant_id, entity_key, def_json },
    );
}

fn cleanupEntity(conn: *bpm.pool.Conn, tenant_id: []const u8, entity_key: []const u8) void {
    conn.exec(
        "DELETE FROM entity_definitions WHERE tenant_id = $1::uuid AND name = $2",
        &.{ tenant_id, entity_key },
    ) catch {};
}

fn createEntTableWithNumericCol(
    allocator: std.mem.Allocator,
    conn: *bpm.pool.Conn,
    entity_key: []const u8,
    col_name: []const u8,
) !void {
    const sql = try std.fmt.allocPrint(
        allocator,
        "CREATE TABLE IF NOT EXISTS ent_{s} (" ++
            "record_id UUID PRIMARY KEY DEFAULT gen_random_uuid(), " ++
            "tenant_id UUID NOT NULL, " ++
            "created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), " ++
            "updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), " ++
            "{s} NUMERIC" ++
            ")",
        .{ entity_key, col_name },
    );
    defer allocator.free(sql);
    try conn.exec(sql, &.{});
}

fn createEntTableWithTwoCols(
    allocator: std.mem.Allocator,
    conn: *bpm.pool.Conn,
    entity_key: []const u8,
    col1: []const u8,
    col2: []const u8,
) !void {
    const sql = try std.fmt.allocPrint(
        allocator,
        "CREATE TABLE IF NOT EXISTS ent_{s} (" ++
            "record_id UUID PRIMARY KEY DEFAULT gen_random_uuid(), " ++
            "tenant_id UUID NOT NULL, " ++
            "created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), " ++
            "updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), " ++
            "{s} NUMERIC, " ++
            "{s} TEXT" ++
            ")",
        .{ entity_key, col1, col2 },
    );
    defer allocator.free(sql);
    try conn.exec(sql, &.{});
}

fn dropEntTable(allocator: std.mem.Allocator, conn: *bpm.pool.Conn, entity_key: []const u8) void {
    const sql = std.fmt.allocPrint(
        allocator,
        "DROP TABLE IF EXISTS ent_{s}",
        .{entity_key},
    ) catch return;
    defer allocator.free(sql);
    conn.exec(sql, &.{}) catch {};
}

fn cleanupAllowlist(conn: *bpm.pool.Conn, entity_key: []const u8) void {
    conn.exec(
        "DELETE FROM entity_filterable_keys WHERE entity_key = $1",
        &.{entity_key},
    ) catch {};
}

/// Register a field restriction: caller must hold required_grant to read field_name.
fn addFieldRestriction(
    conn: *bpm.pool.Conn,
    entity_key: []const u8,
    field_name: []const u8,
    required_grant: []const u8,
) !void {
    try conn.exec(
        "INSERT INTO entity_field_restrictions (entity_key, field_name, required_grant) " ++
            "VALUES ($1, $2, $3) ON CONFLICT (entity_key, field_name) DO NOTHING",
        &.{ entity_key, field_name, required_grant },
    );
}

fn cleanupFieldRestrictions(conn: *bpm.pool.Conn, entity_key: []const u8) void {
    conn.exec(
        "DELETE FROM entity_field_restrictions WHERE entity_key = $1",
        &.{entity_key},
    ) catch {};
}

/// Grant a user the named grant for an entity.
fn grantUserField(
    conn: *bpm.pool.Conn,
    user_id: []const u8,
    entity_key: []const u8,
    grant_name: []const u8,
) !void {
    try conn.exec(
        "INSERT INTO user_entity_grants (user_id, entity_key, grant_name) " ++
            "VALUES ($1::uuid, $2, $3) ON CONFLICT DO NOTHING",
        &.{ user_id, entity_key, grant_name },
    );
}

fn cleanupUserGrants(conn: *bpm.pool.Conn, user_id: []const u8, entity_key: []const u8) void {
    conn.exec(
        "DELETE FROM user_entity_grants WHERE user_id = $1::uuid AND entity_key = $2",
        &.{ user_id, entity_key },
    ) catch {};
}

/// Insert N rows into ent_{entity_key} with the given tenant_id and a cost value.
fn insertEntRowsWithCost(
    allocator: std.mem.Allocator,
    conn: *bpm.pool.Conn,
    entity_key: []const u8,
    tenant_id: []const u8,
    cost_col: []const u8,
    cost_val: []const u8,
    count: usize,
) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const sql = try std.fmt.allocPrint(
            allocator,
            "INSERT INTO ent_{s} (tenant_id, {s}) VALUES ($1::uuid, $2::numeric)",
            .{ entity_key, cost_col },
        );
        defer allocator.free(sql);
        try conn.exec(sql, &.{ tenant_id, cost_val });
    }
}

fn cleanupEntRows(allocator: std.mem.Allocator, conn: *bpm.pool.Conn, entity_key: []const u8, tenant_id: []const u8) void {
    const sql = std.fmt.allocPrint(
        allocator,
        "DELETE FROM ent_{s} WHERE tenant_id = $1::uuid",
        .{entity_key},
    ) catch return;
    defer allocator.free(sql);
    conn.exec(sql, &.{tenant_id}) catch {};
}

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

/// Returns true if any item in the response body contains the given key.
fn anyItemHasKey(allocator: std.mem.Allocator, body: []const u8, key: []const u8) !bool {
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
    const items_val = obj.get("items") orelse return false;
    const items = switch (items_val) {
        .array => |a| a,
        else => return false,
    };
    for (items.items) |item| {
        const item_obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        if (item_obj.get(key) != null) return true;
    }
    return false;
}

/// Returns true if every item in a non-empty response contains the given key.
fn allItemsHaveKey(allocator: std.mem.Allocator, body: []const u8, key: []const u8) !bool {
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
    const items_val = obj.get("items") orelse return false;
    const items = switch (items_val) {
        .array => |a| a,
        else => return false,
    };
    if (items.items.len == 0) return false;
    for (items.items) |item| {
        const item_obj = switch (item) {
            .object => |o| o,
            else => return false,
        };
        if (item_obj.get(key) == null) return false;
    }
    return true;
}

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

// ── TC-QRY-05-01: Ungranted caller — restricted field absent from every item ──

test "qry05_01_ungranted_caller_field_absent_from_items" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const entity_key = try uniqueEntityKey(allocator, "qry05a");
    defer allocator.free(entity_key);

    const user_id = try generateTestUserId(allocator);
    defer allocator.free(user_id);

    try registerEntityWithNumericField(allocator, conn, DEFAULT_TENANT_ID, entity_key, "unit_cost_eur");
    defer cleanupEntity(conn, DEFAULT_TENANT_ID, entity_key);
    defer cleanupAllowlist(conn, entity_key);
    defer cleanupFieldRestrictions(conn, entity_key);

    try createEntTableWithNumericCol(allocator, conn, entity_key, "unit_cost_eur");
    defer dropEntTable(allocator, conn, entity_key);
    defer cleanupEntRows(allocator, conn, entity_key, DEFAULT_TENANT_ID);

    try addFieldRestriction(conn, entity_key, "unit_cost_eur", "entity.read.cost");
    // User has NO grant for entity.read.cost

    try insertEntRowsWithCost(allocator, conn, entity_key, DEFAULT_TENANT_ID, "unit_cost_eur", "99.50", 2);

    const auth = testAuth(user_id);
    const result = entity_query.handleEntityQuery(allocator, &pool, auth, entity_key, "{\"filters\":[],\"page_size\":50}");
    defer freeBody(allocator, result);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    const count = try parseItemCount(allocator, result.body);
    try testing.expectEqual(@as(usize, 2), count);

    // unit_cost_eur must NOT appear in any item
    const has_field = try anyItemHasKey(allocator, result.body, "unit_cost_eur");
    try testing.expect(!has_field);
}

// ── TC-QRY-05-02: Granted caller — restricted field present in every item ──

test "qry05_02_granted_caller_field_present_in_items" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const entity_key = try uniqueEntityKey(allocator, "qry05b");
    defer allocator.free(entity_key);

    const user_id = try generateTestUserId(allocator);
    defer allocator.free(user_id);

    try registerEntityWithNumericField(allocator, conn, DEFAULT_TENANT_ID, entity_key, "unit_cost_eur");
    defer cleanupEntity(conn, DEFAULT_TENANT_ID, entity_key);
    defer cleanupAllowlist(conn, entity_key);
    defer cleanupFieldRestrictions(conn, entity_key);
    defer cleanupUserGrants(conn, user_id, entity_key);

    try createEntTableWithNumericCol(allocator, conn, entity_key, "unit_cost_eur");
    defer dropEntTable(allocator, conn, entity_key);
    defer cleanupEntRows(allocator, conn, entity_key, DEFAULT_TENANT_ID);

    try addFieldRestriction(conn, entity_key, "unit_cost_eur", "entity.read.cost");
    try grantUserField(conn, user_id, entity_key, "entity.read.cost");

    try insertEntRowsWithCost(allocator, conn, entity_key, DEFAULT_TENANT_ID, "unit_cost_eur", "99.50", 2);

    const auth = testAuth(user_id);
    const result = entity_query.handleEntityQuery(allocator, &pool, auth, entity_key, "{\"filters\":[],\"page_size\":50}");
    defer freeBody(allocator, result);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    const count = try parseItemCount(allocator, result.body);
    try testing.expectEqual(@as(usize, 2), count);

    // unit_cost_eur must appear in every item
    const all_have = try allItemsHaveKey(allocator, result.body, "unit_cost_eur");
    try testing.expect(all_have);
}

// ── TC-QRY-05-03: Ungranted caller filters on restricted field → HTTP 400 ──

test "qry05_03_ungranted_filter_on_restricted_field_returns_400" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const entity_key = try uniqueEntityKey(allocator, "qry05c");
    defer allocator.free(entity_key);

    const user_id = try generateTestUserId(allocator);
    defer allocator.free(user_id);

    try registerEntityWithNumericField(allocator, conn, DEFAULT_TENANT_ID, entity_key, "unit_cost_eur");
    defer cleanupEntity(conn, DEFAULT_TENANT_ID, entity_key);
    defer cleanupAllowlist(conn, entity_key);
    defer cleanupFieldRestrictions(conn, entity_key);

    try createEntTableWithNumericCol(allocator, conn, entity_key, "unit_cost_eur");
    defer dropEntTable(allocator, conn, entity_key);

    try addFieldRestriction(conn, entity_key, "unit_cost_eur", "entity.read.cost");

    const body_json =
        \\{"filters":[{"field":"unit_cost_eur","op":"eq","value":99}],"page_size":50}
    ;
    const auth = testAuth(user_id);
    const result = entity_query.handleEntityQuery(allocator, &pool, auth, entity_key, body_json);
    defer freeBody(allocator, result);

    try testing.expectEqual(@as(u16, 400), result.status_code);
    const detail = try parseDetail(allocator, result.body);
    defer allocator.free(detail);
    try testing.expect(std.mem.eql(u8, detail, "filter_field_not_allowlisted"));
}

// ── TC-QRY-05-04: Ungranted caller sorts on restricted field → HTTP 400 ──

test "qry05_04_ungranted_sort_on_restricted_field_returns_400" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const entity_key = try uniqueEntityKey(allocator, "qry05d");
    defer allocator.free(entity_key);

    const user_id = try generateTestUserId(allocator);
    defer allocator.free(user_id);

    try registerEntityWithNumericField(allocator, conn, DEFAULT_TENANT_ID, entity_key, "unit_cost_eur");
    defer cleanupEntity(conn, DEFAULT_TENANT_ID, entity_key);
    defer cleanupAllowlist(conn, entity_key);
    defer cleanupFieldRestrictions(conn, entity_key);

    try createEntTableWithNumericCol(allocator, conn, entity_key, "unit_cost_eur");
    defer dropEntTable(allocator, conn, entity_key);

    try addFieldRestriction(conn, entity_key, "unit_cost_eur", "entity.read.cost");

    const body_json =
        \\{"filters":[],"sort":[{"field":"unit_cost_eur","direction":"asc"}],"page_size":50}
    ;
    const auth = testAuth(user_id);
    const result = entity_query.handleEntityQuery(allocator, &pool, auth, entity_key, body_json);
    defer freeBody(allocator, result);

    try testing.expectEqual(@as(u16, 400), result.status_code);
    const detail = try parseDetail(allocator, result.body);
    defer allocator.free(detail);
    // sort uses the same filter_field_not_allowlisted path (narrowed allowlist)
    try testing.expect(std.mem.indexOf(u8, detail, "allowlisted") != null);
}

// ── TC-QRY-05-05: All restricted fields stripped — item retains record_id ──

test "qry05_05_stripping_all_fields_leaves_record_id" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const entity_key = try uniqueEntityKey(allocator, "qry05e");
    defer allocator.free(entity_key);

    const user_id = try generateTestUserId(allocator);
    defer allocator.free(user_id);

    // Two restricted fields; user holds grants for neither
    try registerEntityWithTwoNumericFields(
        allocator,
        conn,
        DEFAULT_TENANT_ID,
        entity_key,
        "unit_cost_eur",
        "secret_note",
    );
    defer cleanupEntity(conn, DEFAULT_TENANT_ID, entity_key);
    defer cleanupAllowlist(conn, entity_key);
    defer cleanupFieldRestrictions(conn, entity_key);

    try createEntTableWithTwoCols(allocator, conn, entity_key, "unit_cost_eur", "secret_note");
    defer dropEntTable(allocator, conn, entity_key);
    defer cleanupEntRows(allocator, conn, entity_key, DEFAULT_TENANT_ID);

    try addFieldRestriction(conn, entity_key, "unit_cost_eur", "entity.read.cost");
    try addFieldRestriction(conn, entity_key, "secret_note", "entity.read.notes");

    // Insert one row
    const insert_sql = try std.fmt.allocPrint(
        allocator,
        "INSERT INTO ent_{s} (tenant_id, unit_cost_eur, secret_note) VALUES ($1::uuid, 10, 'hidden')",
        .{entity_key},
    );
    defer allocator.free(insert_sql);
    try conn.exec(insert_sql, &.{DEFAULT_TENANT_ID});

    const auth = testAuth(user_id);
    const result = entity_query.handleEntityQuery(allocator, &pool, auth, entity_key, "{\"filters\":[],\"page_size\":50}");
    defer freeBody(allocator, result);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    const count = try parseItemCount(allocator, result.body);
    try testing.expectEqual(@as(usize, 1), count);

    // Item must contain record_id
    const has_record_id = try anyItemHasKey(allocator, result.body, "record_id");
    try testing.expect(has_record_id);

    // Neither restricted field should appear
    const has_cost = try anyItemHasKey(allocator, result.body, "unit_cost_eur");
    try testing.expect(!has_cost);

    const has_note = try anyItemHasKey(allocator, result.body, "secret_note");
    try testing.expect(!has_note);
}

// ── TC-QRY-05-06: Cross-tenant field grant isolation ──────────────────────────
// Tenant A (DEFAULT_TENANT_ID): user_a holds the grant → field visible.
// Tenant B (tenant_b_id): user_b holds no grant → field absent.
// Verifies that grants scoped to one tenant's user do not bleed to another tenant.

test "qry05_06_cross_tenant_grant_isolation" {
    const allocator = testing.allocator;
    var lock = try helpers.acquireIntegrationLock(allocator);
    defer helpers.releaseIntegrationLock(&lock);

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const entity_key = try uniqueEntityKey(allocator, "qry05f");
    defer allocator.free(entity_key);

    // Tenant B gets a distinct UUID — a separate tenant schema from DEFAULT_TENANT_ID.
    const tenant_b_id = try generateTestUserId(allocator);
    defer allocator.free(tenant_b_id);

    const user_a = try generateTestUserId(allocator);
    defer allocator.free(user_a);
    const user_b = try generateTestUserId(allocator);
    defer allocator.free(user_b);

    // Register entity definition for tenant A (DEFAULT_TENANT_ID).
    try registerEntityWithNumericField(allocator, conn, DEFAULT_TENANT_ID, entity_key, "unit_cost_eur");
    defer cleanupEntity(conn, DEFAULT_TENANT_ID, entity_key);

    // Register entity definition for tenant B — distinct tenant_id row.
    try registerEntityWithNumericField(allocator, conn, tenant_b_id, entity_key, "unit_cost_eur");
    defer cleanupEntity(conn, tenant_b_id, entity_key);

    defer cleanupAllowlist(conn, entity_key);
    defer cleanupFieldRestrictions(conn, entity_key);
    defer cleanupUserGrants(conn, user_a, entity_key);

    try createEntTableWithNumericCol(allocator, conn, entity_key, "unit_cost_eur");
    defer dropEntTable(allocator, conn, entity_key);
    defer cleanupEntRows(allocator, conn, entity_key, DEFAULT_TENANT_ID);
    defer cleanupEntRows(allocator, conn, entity_key, tenant_b_id);

    try addFieldRestriction(conn, entity_key, "unit_cost_eur", "entity.read.cost");
    // user_a (tenant A) holds the grant; user_b (tenant B) does not.
    try grantUserField(conn, user_a, entity_key, "entity.read.cost");

    // Insert one row per tenant so both tenants have queryable data.
    try insertEntRowsWithCost(allocator, conn, entity_key, DEFAULT_TENANT_ID, "unit_cost_eur", "42.0", 1);
    try insertEntRowsWithCost(allocator, conn, entity_key, tenant_b_id, "unit_cost_eur", "99.0", 1);

    // user_a queries with tenant A context — should see unit_cost_eur.
    const auth_a = testAuth(user_a);
    const result_a = entity_query.handleEntityQuery(allocator, &pool, auth_a, entity_key, "{\"filters\":[],\"page_size\":50}");
    defer freeBody(allocator, result_a);
    try testing.expectEqual(@as(u16, 200), result_a.status_code);
    const a_has_field = try allItemsHaveKey(allocator, result_a.body, "unit_cost_eur");
    try testing.expect(a_has_field);

    // user_b queries with tenant B context — must NOT see unit_cost_eur.
    // Tenant A's grant for user_a must not bleed to tenant B's user_b.
    const auth_b = tenantAuth(user_b, tenant_b_id);
    const result_b = entity_query.handleEntityQuery(allocator, &pool, auth_b, entity_key, "{\"filters\":[],\"page_size\":50}");
    defer freeBody(allocator, result_b);
    try testing.expectEqual(@as(u16, 200), result_b.status_code);
    const b_has_field = try anyItemHasKey(allocator, result_b.body, "unit_cost_eur");
    try testing.expect(!b_has_field);
}
