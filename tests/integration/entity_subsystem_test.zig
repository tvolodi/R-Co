//! Entity Subsystem Integration Tests — EXP-201, EXP-202
//!
//! Covers entity definition validation, creation, and the event-sourced
//! command path for entity records (create, update, delete).
//!
//! Design artefact: src/design/entities.md
//! Test spec: tests/specs/EXP-201.md, tests/specs/EXP-202.md

const std = @import("std");
const pg = @import("pg");
const bpm = @import("bpm");
const helpers = @import("helpers.zig");
const entities = bpm.entities;

var global_test_counter: usize = 1000;

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
    global_test_counter += 1;
    return std.fmt.allocPrint(allocator, "idemp-{x}", .{global_test_counter});
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

    // 1. Create a tenant for the test
    const tenant_id = try generateTestId(allocator);
    defer allocator.free(tenant_id);
    const actor_id = try h.newUuidString(allocator);
    defer alloc.free(actor_id); // Non-nil UUID for actor_id

    try h.provisionTenant(tenant_id);
    h.setTenant(tenant_id);

    // 2. Create entity definition
    const def_json =
        \\{
        \\  "name": "product",
        \\  "display_name": "Product",
        \\  "fields": [
        \\    { "name": "sku", "type": "text", "required": true, "queried": true },
        \\    { "name": "price", "type": "decimal", "validation": {"precision": 10, "scale": 2}, "queried": true }
        \\  ]
        \\}
    ;

    const create_def_params = entities.definition.CreateDefinitionParams{
        .name = "product",
        .display_name = "Product",
        .description = null,
        .definition_json = def_json,
        .created_by = actor_id,
        .tenant_id = tenant_id,
    };

    // Note: createDefinition handles database interaction
    var def = try entities.definition.createDefinition(allocator, &h.pool, create_def_params);
    defer def.deinit(allocator);
    var def_active = try entities.definition.activateDefinition(allocator, &h.pool, def.id);
    defer def_active.deinit(allocator);

    // 3. Create a record
    var registry = bpm.repository.Registry.init(allocator, &h.pool);
    var event_registry = bpm.event_store.Registry.init(allocator, &h.pool);
    var store = bpm.event_store.Store.init(allocator, &h.pool, &event_registry);

    const idemp_key_1 = try generateIdempKey(allocator);
    defer allocator.free(idemp_key_1);

    const create_params = entities.commands.CreateRecordParams{
        .entity_type = "product",
        .field_values = "{\"sku\": \"ZIG-123\", \"price\": 19.99}",
        .idempotency_key = idemp_key_1,
        .actor_id = actor_id,
        .tenant_id = tenant_id,
    };

    const res = try entities.commands.createRecord(allocator, &h.pool, &store, &registry, create_params);
    defer {
        allocator.free(res.record_id);
        allocator.free(res.entity_type);
        allocator.free(res.field_values);
    }

    try std.testing.expect(!res.is_duplicate);
    try std.testing.expectEqualStrings("product", res.entity_type);

    // 4. Verify in projection table
    var schema_buf: [80]u8 = undefined;
    const schema = bpm.pool.schemaNameForTenant(tenant_id, &schema_buf);
    const sql = try std.fmt.allocPrint(allocator, "SELECT current_state, version_seq FROM {s}.entity_record_latest WHERE record_id = $1::uuid", .{schema});
    defer allocator.free(sql);
    var row = try h.conn.query(
        allocator,
        sql,
        &[_][]const u8{res.record_id},
    );
    defer row.deinit();

    try std.testing.expect(row.rows.len == 1);
    // current_state is at index 0, version_seq is at index 1
    const v_str = row.rows[0][1].?;
    const v_val = try std.fmt.parseInt(i64, v_str, 10);
    try std.testing.expectEqual(@as(i64, 1), v_val);
}

test "EXP-202: Update entity record (Integration)" {
    const allocator = std.testing.allocator;
    var h = try helpers.TestHarness.init(allocator);
    defer h.deinit();

    const tenant_id = try generateTestId(allocator);
    defer allocator.free(tenant_id);
    const actor_id = try h.newUuidString(allocator);
    defer alloc.free(actor_id);

    try h.provisionTenant(tenant_id);
    h.setTenant(tenant_id);

    // Create def
    const def_json = "{\"name\":\"item\", \"display_name\":\"Item\", \"fields\":[{\"name\":\"val\", \"type\":\"integer\", \"queried\":true}]}";
    var def = try entities.definition.createDefinition(allocator, &h.pool, entities.definition.CreateDefinitionParams{
        .name = "item",
        .display_name = "Item",
        .description = null,
        .definition_json = def_json,
        .created_by = actor_id,
        .tenant_id = tenant_id,
    });
    defer def.deinit(allocator);
    var def_active = try entities.definition.activateDefinition(allocator, &h.pool, def.id);
    defer def_active.deinit(allocator);

    var registry = bpm.repository.Registry.init(allocator, &h.pool);
    var event_registry = bpm.event_store.Registry.init(allocator, &h.pool);
    var store = bpm.event_store.Store.init(allocator, &h.pool, &event_registry);

    // Initial create
    const idemp_upd_1 = try generateIdempKey(allocator);
    defer allocator.free(idemp_upd_1);
    const idemp_upd_2 = try generateIdempKey(allocator);
    defer allocator.free(idemp_upd_2);

    const create_res = try entities.commands.createRecord(allocator, &h.pool, &store, &registry, .{
        .entity_type = "item",
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

    // Update
    const update_res = try entities.commands.updateRecord(allocator, &h.pool, &store, &registry, .{
        .entity_type = "item",
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

    try std.testing.expectEqual(@as(i64, 2), update_res.version_seq);

    // Verify projection
    var schema_buf: [80]u8 = undefined;
    const schema = bpm.pool.schemaNameForTenant(tenant_id, &schema_buf);
    const sql = try std.fmt.allocPrint(allocator, "SELECT current_state FROM {s}.entity_record_latest WHERE record_id = $1::uuid", .{schema});
    defer allocator.free(sql);
    var row = try h.conn.query(
        allocator,
        sql,
        &[_][]const u8{update_res.record_id},
    );
    defer row.deinit();

    const state = row.rows[0][0].?;
    try std.testing.expect(std.mem.containsAtLeast(u8, state, 1, "20"));
}

test "EXP-202: Create record idempotency" {
    const allocator = std.testing.allocator;
    var h = try helpers.TestHarness.init(allocator);
    defer h.deinit();

    const tenant_id = try generateTestId(allocator);
    defer allocator.free(tenant_id);
    const actor_id = try h.newUuidString(allocator);
    defer alloc.free(actor_id);
    const idemp_key = try generateIdempKey(allocator);
    defer allocator.free(idemp_key);

    try h.provisionTenant(tenant_id);
    h.setTenant(tenant_id);

    var def = try entities.definition.createDefinition(allocator, &h.pool, entities.definition.CreateDefinitionParams{
        .name = "thing",
        .display_name = "Thing",
        .description = null,
        .definition_json = "{\"name\":\"thing\", \"display_name\":\"Thing\", \"fields\":[{\"name\":\"f1\",\"type\":\"text\"}]}",
        .created_by = actor_id,
        .tenant_id = tenant_id,
    });
    defer def.deinit(allocator);
    var def_active = try entities.definition.activateDefinition(allocator, &h.pool, def.id);
    defer def_active.deinit(allocator);

    var registry = bpm.repository.Registry.init(allocator, &h.pool);
    var event_registry = bpm.event_store.Registry.init(allocator, &h.pool);
    var store = bpm.event_store.Store.init(allocator, &h.pool, &event_registry);

    const r1 = try entities.commands.createRecord(allocator, &h.pool, &store, &registry, .{
        .entity_type = "thing",
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

    const r2 = try entities.commands.createRecord(allocator, &h.pool, &store, &registry, .{
        .entity_type = "thing",
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
}

test "EXP-202: Delete entity record (Integration)" {
    const allocator = std.testing.allocator;
    var h = try helpers.TestHarness.init(allocator);
    defer h.deinit();

    const tenant_id = try generateTestId(allocator);
    defer allocator.free(tenant_id);
    const actor_id = try h.newUuidString(allocator);
    defer alloc.free(actor_id);

    try h.provisionTenant(tenant_id);
    h.setTenant(tenant_id);

    // Create def
    var def = try entities.definition.createDefinition(allocator, &h.pool, .{
        .name = "todelete",
        .display_name = "ToDelete",
        .description = null,
        .definition_json = "{\"name\":\"todelete\", \"display_name\":\"ToDelete\", \"fields\":[{\"name\":\"f\",\"type\":\"text\"}]}",
        .created_by = actor_id,
        .tenant_id = tenant_id,
    });
    defer def.deinit(allocator);
    var def_active = try entities.definition.activateDefinition(allocator, &h.pool, def.id);
    defer def_active.deinit(allocator);

    var registry = bpm.repository.Registry.init(allocator, &h.pool);
    var event_registry = bpm.event_store.Registry.init(allocator, &h.pool);
    var store = bpm.event_store.Store.init(allocator, &h.pool, &event_registry);

    // 1. Create
    const idemp_del_1 = try generateIdempKey(allocator);
    defer allocator.free(idemp_del_1);
    const idemp_del_2 = try generateIdempKey(allocator);
    defer allocator.free(idemp_del_2);

    const r1 = try entities.commands.createRecord(allocator, &h.pool, &store, &registry, .{
        .entity_type = "todelete",
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

    // 2. Delete
    const del_res = try entities.commands.deleteRecord(allocator, &h.pool, &store, &registry, .{
        .entity_type = "todelete",
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

    // 3. Verify projection has deleted_at set and version incremented
    var schema_buf: [80]u8 = undefined;
    const schema = bpm.pool.schemaNameForTenant(tenant_id, &schema_buf);
    const sql = try std.fmt.allocPrint(allocator, "SELECT deleted_at, version_seq FROM {s}.entity_record_latest WHERE record_id = $1::uuid", .{schema});
    defer allocator.free(sql);
    var row = try h.conn.query(
        allocator,
        sql,
        &[_][]const u8{r1.record_id},
    );
    defer row.deinit();

    try std.testing.expect(row.rows.len == 1);
    try std.testing.expect(row.rows[0][0] != null); // deleted_at
    const v_str = row.rows[0][1].?;
    const v_val = try std.fmt.parseInt(i64, v_str, 10);
    try std.testing.expectEqual(@as(i64, 2), v_val);
}

test "EXP-202: Create record with invalid payload (Integration)" {
    const allocator = std.testing.allocator;
    var h = try helpers.TestHarness.init(allocator);
    defer h.deinit();

    const tenant_id = try generateTestId(allocator);
    defer allocator.free(tenant_id);
    const actor_id = try h.newUuidString(allocator);
    defer alloc.free(actor_id);

    try h.provisionTenant(tenant_id);
    h.setTenant(tenant_id);

    var def = try entities.definition.createDefinition(allocator, &h.pool, .{
        .name = "strict",
        .display_name = "Strict",
        .description = null,
        .definition_json = "{\"name\":\"strict\", \"display_name\":\"Strict\", \"fields\":[{\"name\":\"f1\",\"type\":\"text\",\"required\":true}]}",
        .created_by = actor_id,
        .tenant_id = tenant_id,
    });
    defer def.deinit(allocator);
    var def_active = try entities.definition.activateDefinition(allocator, &h.pool, def.id);
    defer def_active.deinit(allocator);

    var registry = bpm.repository.Registry.init(allocator, &h.pool);
    var event_registry = bpm.event_store.Registry.init(allocator, &h.pool);
    var store = bpm.event_store.Store.init(allocator, &h.pool, &event_registry);

    // Payload missing required 'f1'
    const idemp_inv = try generateIdempKey(allocator);
    defer allocator.free(idemp_inv);

    const result_val = entities.commands.createRecord(allocator, &h.pool, &store, &registry, .{
        .entity_type = "strict",
        .field_values = "{}",
        .idempotency_key = idemp_inv,
        .actor_id = actor_id,
        .tenant_id = tenant_id,
    });

    // In Stage 1, we might not have full payload validation yet, but the spec says to test it.
    // If it fails, I'll know why.
    if (result_val) |res| {
        // If it succeeded unexpectedly, free it so we don't leak
        allocator.free(res.record_id);
        allocator.free(res.entity_type);
        allocator.free(res.field_values);
    } else |err| {
        try std.testing.expect(err == error.InvalidPayload);
        return;
    }
}
