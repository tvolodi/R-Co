//! Integration tests for EXP-201 and EXP-202 entities subsystem.
//! These tests run against real PostgreSQL using BPM_TEST_DB_URL.

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;

const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

// Root-level export required so pool connections apply tenant-schema search_path
// instead of falling back to search_path=public (see audit_iss103_test.zig).
pub const api_tenant_context = bpm.api_tenant_context;
const entities = bpm.entities;
const event_store = bpm.store;
const event_registry = bpm.registry;
const uuid_mod = bpm.uuid;

const TestFixture = struct {
    tenant_id: []const u8,
    actor_id: []const u8,
    entity_type: []const u8,
    idempotency_create: []const u8,
    idempotency_update: []const u8,
    idempotency_delete: []const u8,

    fn deinit(self: *TestFixture, allocator: std.mem.Allocator) void {
        allocator.free(self.tenant_id);
        allocator.free(self.actor_id);
        allocator.free(self.entity_type);
        allocator.free(self.idempotency_create);
        allocator.free(self.idempotency_update);
        allocator.free(self.idempotency_delete);
    }
};

fn newFixture(allocator: std.mem.Allocator, prefix: []const u8) !TestFixture {
    const tenant_id = try uuid_mod.newUuidV4(allocator);
    errdefer allocator.free(tenant_id);

    const actor_id = try uuid_mod.newUuidV4(allocator);
    errdefer allocator.free(actor_id);

    const entity_seed = try uuid_mod.newUuidV4(allocator);
    defer allocator.free(entity_seed);

    const entity_type = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ prefix, entity_seed[0..8] });
    errdefer allocator.free(entity_type);

    const idempotency_create = try uuid_mod.newUuidV4(allocator);
    errdefer allocator.free(idempotency_create);

    const idempotency_update = try uuid_mod.newUuidV4(allocator);
    errdefer allocator.free(idempotency_update);

    const idempotency_delete = try uuid_mod.newUuidV4(allocator);
    errdefer allocator.free(idempotency_delete);

    return .{
        .tenant_id = tenant_id,
        .actor_id = actor_id,
        .entity_type = entity_type,
        .idempotency_create = idempotency_create,
        .idempotency_update = idempotency_update,
        .idempotency_delete = idempotency_delete,
    };
}

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is required for EXP-201/202 integration tests\n", .{});
            return error.MissingTestDatabaseUrl;
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

fn cleanupEntityType(conn: *bpm.pool.Conn, entity_type: []const u8) void {
    conn.exec("DELETE FROM entity_record_latest WHERE entity_type = $1", &.{entity_type}) catch {};
    conn.exec("DELETE FROM entity_type_instances WHERE entity_type = $1", &.{entity_type}) catch {};
    conn.exec("DELETE FROM entity_definitions WHERE name = $1", &.{entity_type}) catch {};
}

fn asText(value: ?[]u8) []const u8 {
    return value orelse "";
}

test "TC-EXP-201-01: create definition persists canonical content hash and metadata" {
    const allocator = testing.allocator;

    var h = try TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    var fixture = try newFixture(allocator, "exp201_customer");
    defer fixture.deinit(allocator);

    const definition_json =
        \\{"name":"exp201_customer","display_name":"EXP Customer","fields":[{"name":"email","display_name":"Email","type":"text","queried":true}]}
    ;

    const conn = try pool.acquire();
    defer pool.release(conn);
    cleanupEntityType(conn, fixture.entity_type);
    defer cleanupEntityType(conn, fixture.entity_type);

    var created = try entities.definition.createDefinition(allocator, &pool, .{
        .name = fixture.entity_type,
        .display_name = "EXP Customer",
        .description = "exp201 integration",
        .definition_json = definition_json,
        .created_by = fixture.actor_id,
        .tenant_id = fixture.tenant_id,
    });
    defer created.deinit(allocator);

    try testing.expectEqualStrings(fixture.entity_type, created.name);
    try testing.expectEqualStrings("DRAFT", created.status);
    try testing.expect(created.content_hash.len > 0);

    const row = (try conn.queryRow(
        allocator,
        "SELECT status, encode(content_hash, 'hex') FROM entity_definitions WHERE id = $1::uuid AND tenant_id = $2::uuid",
        &.{ created.id, fixture.tenant_id },
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (row[0]) |v| allocator.free(v);
        if (row[1]) |v| allocator.free(v);
        allocator.free(row);
    }

    try testing.expectEqualStrings("DRAFT", asText(row[0]));
    try testing.expect(asText(row[1]).len > 0);
}

test "TC-EXP-201-02: activate definition marks definition ACTIVE" {
    const allocator = testing.allocator;

    var h = try TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    var fixture = try newFixture(allocator, "exp201_activate");
    defer fixture.deinit(allocator);

    const definition_json =
        \\{"name":"exp201_activate","display_name":"EXP Activate","fields":[{"name":"email","display_name":"Email","type":"text","queried":true}]}
    ;

    const conn = try pool.acquire();
    defer pool.release(conn);
    cleanupEntityType(conn, fixture.entity_type);
    defer cleanupEntityType(conn, fixture.entity_type);

    var created = try entities.definition.createDefinition(allocator, &pool, .{
        .name = fixture.entity_type,
        .display_name = "EXP Activate",
        .description = "exp201 activate",
        .definition_json = definition_json,
        .created_by = fixture.actor_id,
        .tenant_id = fixture.tenant_id,
    });
    defer created.deinit(allocator);

    var activated = try entities.definition.activateDefinition(allocator, &pool, created.id);
    defer activated.deinit(allocator);
    try testing.expectEqualStrings("ACTIVE", activated.status);

    const row = (try conn.queryRow(
        allocator,
        "SELECT status FROM entity_definitions WHERE id = $1::uuid AND tenant_id = $2::uuid",
        &.{ created.id, fixture.tenant_id },
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (row[0]) |v| allocator.free(v);
        allocator.free(row);
    }

    try testing.expectEqualStrings("ACTIVE", asText(row[0]));
}

test "TC-EXP-201-03: validator rejects queried json field" {
    const allocator = testing.allocator;

    var v = entities.validator.Validator.init(allocator);
    defer v.deinit();

    const invalid_definition =
        \\{"name":"bad_entity","display_name":"Bad","fields":[{"name":"payload","display_name":"Payload","type":"json","queried":true}]}
    ;

    const result = v.validateDefinition(invalid_definition);
    try testing.expectError(entities.EntityValidationError.FieldQueriedAndJson, result);
}

test "TC-EXP-202-01: create record writes latest projection row" {
    const allocator = testing.allocator;

    var h = try TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    var fixture = try newFixture(allocator, "exp202_create");
    defer fixture.deinit(allocator);

    const conn = try pool.acquire();
    defer pool.release(conn);

    const definition_json =
        \\{"name":"exp202_order","display_name":"EXP Order","fields":[{"name":"code","display_name":"Code","type":"text","queried":true},{"name":"amount","display_name":"Amount","type":"integer","queried":false}]}
    ;

    cleanupEntityType(conn, fixture.entity_type);
    defer cleanupEntityType(conn, fixture.entity_type);

    var def = try entities.definition.createDefinition(allocator, &pool, .{
        .name = fixture.entity_type,
        .display_name = "EXP Order",
        .description = "exp202 integration",
        .definition_json = definition_json,
        .created_by = fixture.actor_id,
        .tenant_id = fixture.tenant_id,
    });
    defer def.deinit(allocator);

    var active_def = try entities.definition.activateDefinition(allocator, &pool, def.id);
    defer active_def.deinit(allocator);

    var registry = event_registry.Registry.init(allocator, &pool);
    defer registry.deinit();

    var store = event_store.Store.init(allocator, &pool, &registry);
    defer store.deinit();

    const create_res = try entities.commands.createRecord(allocator, &pool, &store, &registry, .{
        .entity_type = fixture.entity_type,
        .field_values = "{\"code\":\"A-001\",\"amount\":100}",
        .idempotency_key = fixture.idempotency_create,
        .actor_id = fixture.actor_id,
        .tenant_id = fixture.tenant_id,
    });
    defer allocator.free(create_res.record_id);
    defer allocator.free(create_res.entity_type);
    defer allocator.free(create_res.field_values);

    const create_row = (try conn.queryRow(
        allocator,
        "SELECT current_state::text, version_seq::text FROM entity_record_latest WHERE tenant_id = $1::uuid AND entity_type = $2 AND record_id = $3::uuid",
        &.{ fixture.tenant_id, fixture.entity_type, create_res.record_id },
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (create_row[0]) |v| allocator.free(v);
        if (create_row[1]) |v| allocator.free(v);
        allocator.free(create_row);
    }

    try testing.expect(std.mem.indexOf(u8, asText(create_row[0]), "A-001") != null);
    const version_created = try std.fmt.parseInt(i64, asText(create_row[1]), 10);
    try testing.expect(version_created > 0);
}

test "TC-EXP-202-02: update record increments version sequence and updates state" {
    const allocator = testing.allocator;

    var h = try TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    var fixture = try newFixture(allocator, "exp202_update");
    defer fixture.deinit(allocator);

    const conn = try pool.acquire();
    defer pool.release(conn);

    const definition_json =
        \\{"name":"exp202_order","display_name":"EXP Order","fields":[{"name":"code","display_name":"Code","type":"text","queried":true},{"name":"amount","display_name":"Amount","type":"integer","queried":false}]}
    ;

    cleanupEntityType(conn, fixture.entity_type);
    defer cleanupEntityType(conn, fixture.entity_type);

    var def = try entities.definition.createDefinition(allocator, &pool, .{
        .name = fixture.entity_type,
        .display_name = "EXP Order",
        .description = "exp202 update",
        .definition_json = definition_json,
        .created_by = fixture.actor_id,
        .tenant_id = fixture.tenant_id,
    });
    defer def.deinit(allocator);

    var active_def = try entities.definition.activateDefinition(allocator, &pool, def.id);
    defer active_def.deinit(allocator);

    var registry = event_registry.Registry.init(allocator, &pool);
    defer registry.deinit();

    var store = event_store.Store.init(allocator, &pool, &registry);
    defer store.deinit();

    const create_res = try entities.commands.createRecord(allocator, &pool, &store, &registry, .{
        .entity_type = fixture.entity_type,
        .field_values = "{\"code\":\"A-001\",\"amount\":100}",
        .idempotency_key = fixture.idempotency_create,
        .actor_id = fixture.actor_id,
        .tenant_id = fixture.tenant_id,
    });
    defer allocator.free(create_res.record_id);
    defer allocator.free(create_res.entity_type);
    defer allocator.free(create_res.field_values);

    const create_row = (try conn.queryRow(
        allocator,
        "SELECT version_seq::text FROM entity_record_latest WHERE tenant_id = $1::uuid AND entity_type = $2 AND record_id = $3::uuid",
        &.{ fixture.tenant_id, fixture.entity_type, create_res.record_id },
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (create_row[0]) |v| allocator.free(v);
        allocator.free(create_row);
    }

    const version_before = try std.fmt.parseInt(i64, asText(create_row[0]), 10);

    const update_res = try entities.commands.updateRecord(allocator, &pool, &store, &registry, .{
        .entity_type = fixture.entity_type,
        .record_id = create_res.record_id,
        .field_values = "{\"code\":\"A-001\",\"amount\":250}",
        .idempotency_key = fixture.idempotency_update,
        .actor_id = fixture.actor_id,
        .tenant_id = fixture.tenant_id,
    });
    defer allocator.free(update_res.record_id);
    defer allocator.free(update_res.entity_type);
    defer allocator.free(update_res.field_values);

    const update_row = (try conn.queryRow(
        allocator,
        "SELECT current_state::text, version_seq::text FROM entity_record_latest WHERE tenant_id = $1::uuid AND entity_type = $2 AND record_id = $3::uuid",
        &.{ fixture.tenant_id, fixture.entity_type, create_res.record_id },
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (update_row[0]) |v| allocator.free(v);
        if (update_row[1]) |v| allocator.free(v);
        allocator.free(update_row);
    }

    try testing.expect(std.mem.indexOf(u8, asText(update_row[0]), "250") != null);
    const version_after = try std.fmt.parseInt(i64, asText(update_row[1]), 10);
    try testing.expect(version_after > version_before);
}

test "TC-EXP-202-03: delete record marks projection row as deleted" {
    const allocator = testing.allocator;

    var h = try TestHarness.init(allocator);
    defer h.deinit();

    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    var fixture = try newFixture(allocator, "exp202_delete");
    defer fixture.deinit(allocator);

    const conn = try pool.acquire();
    defer pool.release(conn);

    const definition_json =
        \\{"name":"exp202_order","display_name":"EXP Order","fields":[{"name":"code","display_name":"Code","type":"text","queried":true},{"name":"amount","display_name":"Amount","type":"integer","queried":false}]}
    ;

    cleanupEntityType(conn, fixture.entity_type);
    defer cleanupEntityType(conn, fixture.entity_type);

    var def = try entities.definition.createDefinition(allocator, &pool, .{
        .name = fixture.entity_type,
        .display_name = "EXP Order",
        .description = "exp202 delete",
        .definition_json = definition_json,
        .created_by = fixture.actor_id,
        .tenant_id = fixture.tenant_id,
    });
    defer def.deinit(allocator);

    var active_def = try entities.definition.activateDefinition(allocator, &pool, def.id);
    defer active_def.deinit(allocator);

    var registry = event_registry.Registry.init(allocator, &pool);
    defer registry.deinit();

    var store = event_store.Store.init(allocator, &pool, &registry);
    defer store.deinit();

    const create_res = try entities.commands.createRecord(allocator, &pool, &store, &registry, .{
        .entity_type = fixture.entity_type,
        .field_values = "{\"code\":\"A-001\",\"amount\":100}",
        .idempotency_key = fixture.idempotency_create,
        .actor_id = fixture.actor_id,
        .tenant_id = fixture.tenant_id,
    });
    defer allocator.free(create_res.record_id);
    defer allocator.free(create_res.entity_type);
    defer allocator.free(create_res.field_values);

    const delete_res = try entities.commands.deleteRecord(allocator, &pool, &store, &registry, .{
        .entity_type = fixture.entity_type,
        .record_id = create_res.record_id,
        .idempotency_key = fixture.idempotency_delete,
        .actor_id = fixture.actor_id,
        .tenant_id = fixture.tenant_id,
    });
    defer allocator.free(delete_res.record_id);
    defer allocator.free(delete_res.entity_type);
    defer allocator.free(delete_res.field_values);

    const delete_row = (try conn.queryRow(
        allocator,
        "SELECT deleted_at IS NOT NULL FROM entity_record_latest WHERE tenant_id = $1::uuid AND entity_type = $2 AND record_id = $3::uuid",
        &.{ fixture.tenant_id, fixture.entity_type, create_res.record_id },
    )) orelse return error.TestUnexpectedResult;
    defer {
        if (delete_row[0]) |v| allocator.free(v);
        allocator.free(delete_row);
    }

    const is_deleted = std.mem.eql(u8, asText(delete_row[0]), "t") or std.mem.eql(u8, asText(delete_row[0]), "true");
    try testing.expect(is_deleted);
}
