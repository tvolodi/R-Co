//! Entity Subsystem Integration Tests — EXP-201, EXP-202
//!
//! Covers entity definition validation, creation, and the event-sourced
//! command path for entity records (create, update, delete).
//!
//! Design artefact: src/design/entities.md
//! Test spec: tests/specs/EXP-201.md, tests/specs/EXP-202.md
//!
//! Requires: BPM_TEST_DB_URL environment variable pointing at a real
//! PostgreSQL database — read internally by helpers.TestHarness.init().

const std = @import("std");
const pg = @import("pg");
const portable_env = @import("env");
const bpm = @import("bpm");
const helpers = @import("helpers.zig");
const entities = bpm.entities;
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

// Root-level export required so pool connections apply the tenant-schema
// search_path instead of falling back to search_path=public. Same reason as
// exp201_202_entities_test.zig and audit_iss103_test.zig.
pub const api_tenant_context = bpm.api_tenant_context;

/// ISS-0150 / GH #466: this file was written against a `TestHarness` that
/// exposed a `pool` field. No such field has ever existed — TestHarness owns a
/// single `pg.Conn` inside an always-rolled-back transaction, while the
/// entities command path needs a real `*Pool` it can `acquire()` from. Because
/// the file's Run artifact was attached to no build step, the mismatch never
/// produced a compile error and every block below silently never ran. Each test
/// now builds its own Pool the same way its sibling exp201_202_entities_test.zig
/// does; the harness is still constructed so migrations are applied and the
/// ambient tenant context is reset between blocks.
fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print(
                "BPM_TEST_DB_URL is required for EXP-201/EXP-202 entity subsystem integration tests\n",
                .{},
            );
            return error.MissingTestDatabaseUrl;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_<id>,public (schema isolation).
    bpm.api_tenant_context.set(bpm.api_tenant_context.DEFAULT_TENANT_ID);
    return Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 5 });
}

/// Best-effort removal of every row this file's fixtures create for one entity
/// type. Registered with `defer` so a mid-test failure still cleans up: the
/// rows live in committed pool connections, not in the harness transaction.
fn cleanupEntityType(conn: *bpm.pool.Conn, entity_type: []const u8) void {
    conn.exec("DELETE FROM entity_record_latest WHERE entity_type = $1", &.{entity_type}) catch {};
    conn.exec("DELETE FROM entity_type_instances WHERE entity_type = $1", &.{entity_type}) catch {};
    conn.exec("DELETE FROM entity_definitions WHERE name = $1", &.{entity_type}) catch {};
}

/// Per-test entity type name. A literal name shared across blocks would collide
/// with the previous run's leftovers and with concurrently running blocks; the
/// random suffix makes each block's definition its own.
fn uniqueEntityType(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    var bytes: [6]u8 = undefined;
    fillRandom(&bytes);
    return std.fmt.allocPrint(allocator, "{s}_{x}", .{ prefix, bytes });
}

/// Generate a random UUID-based tenant ID to avoid collisions across test runs.
/// Previous deterministic counter-based IDs (e.g., 000003e9-...) would reuse the
/// same tenant schema across runs, leaving stale events that triggered false
/// duplicate detection in the event store.
fn generateTestId(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [16]u8 = undefined;
    fillRandom(&bytes);
    // Set version 4 (random UUID) and variant bits per RFC 4122.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        bytes[0],  bytes[1],  bytes[2],  bytes[3],
        bytes[4],  bytes[5],  bytes[6],  bytes[7],
        bytes[8],  bytes[9],  bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15],
    });
}

fn fillRandom(buf: []u8) void {
    const builtin = @import("builtin");
    switch (comptime builtin.os.tag) {
        .windows => {
            const adv = struct {
                extern "advapi32" fn SystemFunction036(pbBuffer: *anyopaque, cbBuffer: u32) u8;
            };
            _ = adv.SystemFunction036(@ptrCast(buf.ptr), @intCast(buf.len));
        },
        else => {
            var prng = std.Random.DefaultPrng.init(@as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())))));
            prng.random().bytes(buf);
        },
    }
}

fn generateIdempKey(allocator: std.mem.Allocator) ![]u8 {
    // Per-test random suffix instead of a module-level shared counter — a
    // module-level `var` mutated across test blocks is itself a fixture-
    // isolation violation (T020; see docs/anti-patterns.md's
    // "Shared mutable tenant or fixture state across integration test blocks"
    // entry) since test blocks may interleave or run out of order.
    var bytes: [8]u8 = undefined;
    fillRandom(&bytes);
    // Zig 0.16 removed std.fmt.fmtSliceHexLower; `{x}` on a byte slice now
    // formats as lower-case hex directly.
    return std.fmt.allocPrint(allocator, "idemp-{x}", .{bytes});
}

test "EXP-201: Valid entity definition validation" {
    const allocator = std.testing.allocator;
    var v = entities.validator.Validator.init(allocator);
    defer v.deinit();

    const valid_json =
        \\{
        \\  "name": "customer",
        \\  "display_name": "Customer Profile",
        \\  "fields": [
        \\    { "name": "email", "type": "text", "required": true, "queried": true },
        \\    { "name": "age", "type": "integer", "queried": true },
        \\    { "name": "metadata", "type": "json" }
        \\  ]
        \\}
    ;

    try v.validateDefinition(valid_json);
}

test "EXP-201: Entity name format validation" {
    const allocator = std.testing.allocator;
    var v = entities.validator.Validator.init(allocator);
    defer v.deinit();

    const invalid_json =
        \\{
        \\  "name": "Invalid-Name",
        \\  "display_name": "Test",
        \\  "fields": [{ "name": "f1", "type": "text" }]
        \\}
    ;

    const result = v.validateDefinition(invalid_json);
    try std.testing.expectError(entities.EntityValidationError.InvalidNameFormat, result);

    const errs = v.lastErrors();
    try std.testing.expect(errs.len > 0);
    try std.testing.expectEqualStrings("/name", errs[0].field_path);
}

test "EXP-201: Queried and JSON exclusion rule" {
    const allocator = std.testing.allocator;
    var v = entities.validator.Validator.init(allocator);
    defer v.deinit();

    const invalid_json =
        \\{
        \\  "name": "order",
        \\  "display_name": "Order",
        \\  "fields": [
        \\    { "name": "raw_payload", "type": "json", "queried": true }
        \\  ]
        \\}
    ;

    const result = v.validateDefinition(invalid_json);
    try std.testing.expectError(entities.EntityValidationError.FieldQueriedAndJson, result);
}

test "EXP-201: Duplicate field name validation" {
    const allocator = std.testing.allocator;
    var v = entities.validator.Validator.init(allocator);
    defer v.deinit();

    const invalid_json =
        \\{
        \\  "name": "customer",
        \\  "display_name": "Customer",
        \\  "fields": [
        \\    { "name": "email", "type": "text" },
        \\    { "name": "email", "type": "text" }
        \\  ]
        \\}
    ;

    const result = v.validateDefinition(invalid_json);
    try std.testing.expectError(entities.EntityValidationError.FieldNameConflict, result);
}

test "EXP-201: Missing Enum Values" {
    const allocator = std.testing.allocator;
    var v = entities.validator.Validator.init(allocator);
    defer v.deinit();

    const invalid_json =
        \\{
        \\  "name": "user",
        \\  "display_name": "User",
        \\  "fields": [
        \\    { "name": "status", "type": "enum", "validation": {} }
        \\  ]
        \\}
    ;

    const result = v.validateDefinition(invalid_json);
    try std.testing.expectError(entities.EntityValidationError.MissingEnumValues, result);
}

test "EXP-201: Invalid Decimal Spec" {
    const allocator = std.testing.allocator;
    var v = entities.validator.Validator.init(allocator);
    defer v.deinit();

    const invalid_json =
        \\{
        \\  "name": "product",
        \\  "fields": [
        \\    { "name": "price", "type": "decimal", "validation": { "precision": 10 } }
        \\  ]
        \\}
    ;

    const result = v.validateDefinition(invalid_json);
    try std.testing.expectError(entities.EntityValidationError.InvalidDecimalSpec, result);
}

test "EXP-201: Index Field Not Queried" {
    const allocator = std.testing.allocator;
    var v = entities.validator.Validator.init(allocator);
    defer v.deinit();

    const invalid_json =
        \\{
        \\  "name": "e",
        \\  "fields": [{ "name": "f", "type": "text", "queried": false }],
        \\  "indexes": [{ "name": "idx", "fields": ["f"] }]
        \\}
    ;

    const result = v.validateDefinition(invalid_json);
    try std.testing.expectError(entities.EntityValidationError.IndexFieldNotQueried, result);
}

test "EXP-202: Create entity record (Integration)" {
    const allocator = std.testing.allocator;
    var h = try helpers.TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    // 1. Per-test fixtures — random tenant/actor/entity-type so concurrent or
    //    repeated runs never collide on a shared row.
    const tenant_id = try allocator.dupe(u8, bpm.api_tenant_context.DEFAULT_TENANT_ID);
    defer allocator.free(tenant_id);
    const actor_id = try h.newUuidString(allocator);
    defer allocator.free(actor_id);
    const entity_type = try uniqueEntityType(allocator, "product");
    defer allocator.free(entity_type);

    const conn = try pool.acquire();
    defer pool.release(conn);
    cleanupEntityType(conn, entity_type);
    defer cleanupEntityType(conn, entity_type);

    // 2. Create and activate the entity definition.
    const def_json = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "name": "{s}",
        \\  "display_name": "Product",
        \\  "fields": [
        \\    {{ "name": "sku", "type": "text", "required": true, "queried": true }},
        \\    {{ "name": "price", "type": "decimal", "validation": {{"precision": 10, "scale": 2}}, "queried": true }}
        \\  ]
        \\}}
    , .{entity_type});
    defer allocator.free(def_json);

    var def = try entities.definition.createDefinition(allocator, &pool, .{
        .name = entity_type,
        .display_name = "Product",
        .description = null,
        .definition_json = def_json,
        .created_by = actor_id,
        .tenant_id = tenant_id,
    });
    defer def.deinit(allocator);
    var def_active = try entities.definition.activateDefinition(allocator, &pool, def.id);
    defer def_active.deinit(allocator);

    // 3. Create a record through the event-sourced command path.
    var registry = bpm.registry.Registry.init(allocator, &pool);
    defer registry.deinit();
    var store = bpm.store.Store.init(allocator, &pool, &registry);
    defer store.deinit();

    const idemp_key_1 = try generateIdempKey(allocator);
    defer allocator.free(idemp_key_1);

    const res = try entities.commands.createRecord(allocator, &pool, &store, &registry, .{
        .entity_type = entity_type,
        .field_values = "{\"sku\": \"ZIG-123\", \"price\": 19.99}",
        .idempotency_key = idemp_key_1,
        .actor_id = actor_id,
        .tenant_id = tenant_id,
    });
    defer {
        allocator.free(res.record_id);
        allocator.free(res.entity_type);
        allocator.free(res.field_values);
    }

    try std.testing.expect(!res.is_duplicate);
    try std.testing.expectEqualStrings(entity_type, res.entity_type);

    // 4. The projection row must exist, carry the submitted state, and be at
    //    version 1 — the first event in this record's stream.
    const row = (try conn.queryRow(
        allocator,
        "SELECT current_state::text, version_seq::text FROM entity_record_latest WHERE tenant_id = $1::uuid AND entity_type = $2 AND record_id = $3::uuid",
        &.{ tenant_id, entity_type, res.record_id },
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (row[0]) |v| allocator.free(v);
        if (row[1]) |v| allocator.free(v);
        allocator.free(row);
    }

    const state = row[0] orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, state, "ZIG-123") != null);
    const v_val = try std.fmt.parseInt(i64, row[1] orelse return error.TestUnexpectedResult, 10);
    try std.testing.expectEqual(@as(i64, 1), v_val);
}

test "EXP-202: Update entity record (Integration)" {
    const allocator = std.testing.allocator;
    var h = try helpers.TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const tenant_id = try allocator.dupe(u8, bpm.api_tenant_context.DEFAULT_TENANT_ID);
    defer allocator.free(tenant_id);
    const actor_id = try h.newUuidString(allocator);
    defer allocator.free(actor_id);
    const entity_type = try uniqueEntityType(allocator, "item");
    defer allocator.free(entity_type);

    const conn = try pool.acquire();
    defer pool.release(conn);
    cleanupEntityType(conn, entity_type);
    defer cleanupEntityType(conn, entity_type);

    const def_json = try std.fmt.allocPrint(
        allocator,
        "{{\"name\":\"{s}\", \"display_name\":\"Item\", \"fields\":[{{\"name\":\"val\", \"type\":\"integer\", \"queried\":true}}]}}",
        .{entity_type},
    );
    defer allocator.free(def_json);

    var def = try entities.definition.createDefinition(allocator, &pool, .{
        .name = entity_type,
        .display_name = "Item",
        .description = null,
        .definition_json = def_json,
        .created_by = actor_id,
        .tenant_id = tenant_id,
    });
    defer def.deinit(allocator);
    var def_active = try entities.definition.activateDefinition(allocator, &pool, def.id);
    defer def_active.deinit(allocator);

    var registry = bpm.registry.Registry.init(allocator, &pool);
    defer registry.deinit();
    var store = bpm.store.Store.init(allocator, &pool, &registry);
    defer store.deinit();

    const idemp_upd_1 = try generateIdempKey(allocator);
    defer allocator.free(idemp_upd_1);
    const idemp_upd_2 = try generateIdempKey(allocator);
    defer allocator.free(idemp_upd_2);

    const create_res = try entities.commands.createRecord(allocator, &pool, &store, &registry, .{
        .entity_type = entity_type,
        .field_values = "{\"val\": 10}",
        .idempotency_key = idemp_upd_1,
        .actor_id = actor_id,
        .tenant_id = tenant_id,
    });
    defer {
        allocator.free(create_res.record_id);
        allocator.free(create_res.entity_type);
        allocator.free(create_res.field_values);
    }

    const update_res = try entities.commands.updateRecord(allocator, &pool, &store, &registry, .{
        .entity_type = entity_type,
        .record_id = create_res.record_id,
        .field_values = "{\"val\": 20}",
        .idempotency_key = idemp_upd_2,
        .actor_id = actor_id,
        .tenant_id = tenant_id,
    });
    defer {
        allocator.free(update_res.record_id);
        allocator.free(update_res.entity_type);
        allocator.free(update_res.field_values);
    }

    // An update appends a second event to the same stream, so the projection
    // must advance from version 1 to version 2 and carry the new value.
    try std.testing.expectEqual(@as(i64, 2), update_res.version_seq);
    try std.testing.expectEqualStrings(create_res.record_id, update_res.record_id);

    const row = (try conn.queryRow(
        allocator,
        "SELECT current_state::text, version_seq::text FROM entity_record_latest WHERE tenant_id = $1::uuid AND entity_type = $2 AND record_id = $3::uuid",
        &.{ tenant_id, entity_type, update_res.record_id },
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (row[0]) |v| allocator.free(v);
        if (row[1]) |v| allocator.free(v);
        allocator.free(row);
    }

    const state = row[0] orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, state, "20") != null);
    const v_val = try std.fmt.parseInt(i64, row[1] orelse return error.TestUnexpectedResult, 10);
    try std.testing.expectEqual(@as(i64, 2), v_val);
}

test "EXP-202: Create record idempotency" {
    const allocator = std.testing.allocator;
    var h = try helpers.TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const tenant_id = try allocator.dupe(u8, bpm.api_tenant_context.DEFAULT_TENANT_ID);
    defer allocator.free(tenant_id);
    const actor_id = try h.newUuidString(allocator);
    defer allocator.free(actor_id);
    const idemp_key = try generateIdempKey(allocator);
    defer allocator.free(idemp_key);
    const entity_type = try uniqueEntityType(allocator, "thing");
    defer allocator.free(entity_type);

    const conn = try pool.acquire();
    defer pool.release(conn);
    cleanupEntityType(conn, entity_type);
    defer cleanupEntityType(conn, entity_type);

    const def_json = try std.fmt.allocPrint(
        allocator,
        "{{\"name\":\"{s}\", \"display_name\":\"Thing\", \"fields\":[{{\"name\":\"f1\",\"type\":\"text\"}}]}}",
        .{entity_type},
    );
    defer allocator.free(def_json);

    var def = try entities.definition.createDefinition(allocator, &pool, .{
        .name = entity_type,
        .display_name = "Thing",
        .description = null,
        .definition_json = def_json,
        .created_by = actor_id,
        .tenant_id = tenant_id,
    });
    defer def.deinit(allocator);
    var def_active = try entities.definition.activateDefinition(allocator, &pool, def.id);
    defer def_active.deinit(allocator);

    var registry = bpm.registry.Registry.init(allocator, &pool);
    defer registry.deinit();
    var store = bpm.store.Store.init(allocator, &pool, &registry);
    defer store.deinit();

    const r1 = try entities.commands.createRecord(allocator, &pool, &store, &registry, .{
        .entity_type = entity_type,
        .field_values = "{\"f1\": \"val1\"}",
        .idempotency_key = idemp_key,
        .actor_id = actor_id,
        .tenant_id = tenant_id,
    });
    defer {
        allocator.free(r1.record_id);
        allocator.free(r1.entity_type);
        allocator.free(r1.field_values);
    }

    // Same idempotency key replayed: the second call must be recognised as a
    // duplicate and return the FIRST record rather than creating a second one.
    const r2 = try entities.commands.createRecord(allocator, &pool, &store, &registry, .{
        .entity_type = entity_type,
        .field_values = "{\"f1\": \"val1\"}",
        .idempotency_key = idemp_key,
        .actor_id = actor_id,
        .tenant_id = tenant_id,
    });
    defer {
        allocator.free(r2.record_id);
        allocator.free(r2.entity_type);
        allocator.free(r2.field_values);
    }

    try std.testing.expect(!r1.is_duplicate);
    try std.testing.expect(r2.is_duplicate);
    try std.testing.expectEqualStrings(r1.record_id, r2.record_id);

    // The replay must not have produced a second projection row.
    const count_row = (try conn.queryRow(
        allocator,
        "SELECT count(*)::text FROM entity_record_latest WHERE tenant_id = $1::uuid AND entity_type = $2",
        &.{ tenant_id, entity_type },
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (count_row[0]) |v| allocator.free(v);
        allocator.free(count_row);
    }
    try std.testing.expectEqualStrings("1", count_row[0] orelse return error.TestUnexpectedResult);
}

test "EXP-202: Delete entity record (Integration)" {
    const allocator = std.testing.allocator;
    var h = try helpers.TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const tenant_id = try allocator.dupe(u8, bpm.api_tenant_context.DEFAULT_TENANT_ID);
    defer allocator.free(tenant_id);
    const actor_id = try h.newUuidString(allocator);
    defer allocator.free(actor_id);
    const entity_type = try uniqueEntityType(allocator, "todelete");
    defer allocator.free(entity_type);

    const conn = try pool.acquire();
    defer pool.release(conn);
    cleanupEntityType(conn, entity_type);
    defer cleanupEntityType(conn, entity_type);

    const def_json = try std.fmt.allocPrint(
        allocator,
        "{{\"name\":\"{s}\", \"display_name\":\"ToDelete\", \"fields\":[{{\"name\":\"f\",\"type\":\"text\"}}]}}",
        .{entity_type},
    );
    defer allocator.free(def_json);

    var def = try entities.definition.createDefinition(allocator, &pool, .{
        .name = entity_type,
        .display_name = "ToDelete",
        .description = null,
        .definition_json = def_json,
        .created_by = actor_id,
        .tenant_id = tenant_id,
    });
    defer def.deinit(allocator);
    var def_active = try entities.definition.activateDefinition(allocator, &pool, def.id);
    defer def_active.deinit(allocator);

    var registry = bpm.registry.Registry.init(allocator, &pool);
    defer registry.deinit();
    var store = bpm.store.Store.init(allocator, &pool, &registry);
    defer store.deinit();

    const idemp_del_1 = try generateIdempKey(allocator);
    defer allocator.free(idemp_del_1);
    const idemp_del_2 = try generateIdempKey(allocator);
    defer allocator.free(idemp_del_2);

    const r1 = try entities.commands.createRecord(allocator, &pool, &store, &registry, .{
        .entity_type = entity_type,
        .field_values = "{\"f\": \"data\"}",
        .idempotency_key = idemp_del_1,
        .actor_id = actor_id,
        .tenant_id = tenant_id,
    });
    defer {
        allocator.free(r1.record_id);
        allocator.free(r1.entity_type);
        allocator.free(r1.field_values);
    }

    const del_res = try entities.commands.deleteRecord(allocator, &pool, &store, &registry, .{
        .entity_type = entity_type,
        .record_id = r1.record_id,
        .idempotency_key = idemp_del_2,
        .actor_id = actor_id,
        .tenant_id = tenant_id,
    });
    defer {
        allocator.free(del_res.record_id);
        allocator.free(del_res.entity_type);
        allocator.free(del_res.field_values);
    }

    // Delete is a soft delete in the event-sourced model: the projection row
    // survives with deleted_at stamped and the version advanced to 2.
    const row = (try conn.queryRow(
        allocator,
        "SELECT deleted_at::text, version_seq::text FROM entity_record_latest WHERE tenant_id = $1::uuid AND entity_type = $2 AND record_id = $3::uuid",
        &.{ tenant_id, entity_type, r1.record_id },
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (row[0]) |v| allocator.free(v);
        if (row[1]) |v| allocator.free(v);
        allocator.free(row);
    }

    try std.testing.expect(row[0] != null);
    const v_val = try std.fmt.parseInt(i64, row[1] orelse return error.TestUnexpectedResult, 10);
    try std.testing.expectEqual(@as(i64, 2), v_val);
}

test "EXP-202: Create record with invalid payload (Integration)" {
    const allocator = std.testing.allocator;
    var h = try helpers.TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);
    var pool = try makePool(allocator, url);
    defer pool.deinit();

    const tenant_id = try allocator.dupe(u8, bpm.api_tenant_context.DEFAULT_TENANT_ID);
    defer allocator.free(tenant_id);
    const actor_id = try h.newUuidString(allocator);
    defer allocator.free(actor_id);
    const entity_type = try uniqueEntityType(allocator, "strict");
    defer allocator.free(entity_type);

    const conn = try pool.acquire();
    defer pool.release(conn);
    cleanupEntityType(conn, entity_type);
    defer cleanupEntityType(conn, entity_type);

    const def_json = try std.fmt.allocPrint(
        allocator,
        "{{\"name\":\"{s}\", \"display_name\":\"Strict\", \"fields\":[{{\"name\":\"f1\",\"type\":\"text\",\"required\":true}}]}}",
        .{entity_type},
    );
    defer allocator.free(def_json);

    var def = try entities.definition.createDefinition(allocator, &pool, .{
        .name = entity_type,
        .display_name = "Strict",
        .description = null,
        .definition_json = def_json,
        .created_by = actor_id,
        .tenant_id = tenant_id,
    });
    defer def.deinit(allocator);
    var def_active = try entities.definition.activateDefinition(allocator, &pool, def.id);
    defer def_active.deinit(allocator);

    var registry = bpm.registry.Registry.init(allocator, &pool);
    defer registry.deinit();
    var store = bpm.store.Store.init(allocator, &pool, &registry);
    defer store.deinit();

    const idemp_inv = try generateIdempKey(allocator);
    defer allocator.free(idemp_inv);

    // Payload omits the required field `f1`. The original version of this block
    // accepted BOTH outcomes — an `if (result) |ok| {...} else |err| {...}` where
    // the success arm only freed memory — so it could not fail no matter what
    // createRecord did. That is the same "green without testing anything" defect
    // ISS-0150 exists to remove, so the expectation is now unconditional.
    const result_val = entities.commands.createRecord(allocator, &pool, &store, &registry, .{
        .entity_type = entity_type,
        .field_values = "{}",
        .idempotency_key = idemp_inv,
        .actor_id = actor_id,
        .tenant_id = tenant_id,
    });

    if (result_val) |res| {
        allocator.free(res.record_id);
        allocator.free(res.entity_type);
        allocator.free(res.field_values);
        std.debug.print(
            "createRecord accepted a payload missing required field 'f1' for entity_type={s}\n",
            .{entity_type},
        );
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqual(entities.commands.EntityCommandError.InvalidPayload, err);
    }

    // A rejected create must leave no projection row behind.
    const count_row = (try conn.queryRow(
        allocator,
        "SELECT count(*)::text FROM entity_record_latest WHERE tenant_id = $1::uuid AND entity_type = $2",
        &.{ tenant_id, entity_type },
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (count_row[0]) |v| allocator.free(v);
        allocator.free(count_row);
    }
    try std.testing.expectEqualStrings("0", count_row[0] orelse return error.TestUnexpectedResult);
}
