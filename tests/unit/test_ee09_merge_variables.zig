//! Unit tests for EE-09 — Variable Scoping and Merge.
//!
//! Covers the pure-function and compile-time portions of EE-09:
//!   - json_schema.validate() for all constraint keywords (type, enum,
//!     minimum, maximum, maxLength)
//!   - InstanceStore.mergeVariables() empty-output fast path (no DB required)
//!   - MergeVariablesError type completeness (compile-time)
//!
//! These tests run under `zig build test` without a database connection.
//! Integration-layer tests (TC-EE-09-01 through TC-EE-09-08, exercising the
//! full completeTask flow against a real PostgreSQL database) are specified
//! in tests/specs/EE-09.md and belong in tests/integration/ee09_merge_variables_test.zig.
//!
//! Requirement traceability:
//!   EE-09 → TC-EE-09-U01 … TC-EE-09-U10
//!   (see tests/specs/EE-09.md for full Given/When/Then specs)
//!
//! Run with: zig build test

const std = @import("std");
const testing = std.testing;

const bpm = @import("bpm");
const json_schema = bpm.json_schema_mod;
const instance_mod = bpm.engine_instance;

// ---------------------------------------------------------------------------
// TC-EE-09-U01: type:string passes for a string value
// ---------------------------------------------------------------------------
test "TC-EE-09-U01: json_schema type:string passes for string value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const schema = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"type\":\"string\"}",
        .{ .allocate = .alloc_always },
    );

    const val = std.json.Value{ .string = "hello" };
    const result = json_schema.validate(val, schema.value);
    try testing.expect(result.valid);
}

// ---------------------------------------------------------------------------
// TC-EE-09-U02: type:string fails for an integer value
// ---------------------------------------------------------------------------
test "TC-EE-09-U02: json_schema type:string fails for integer value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const schema = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"type\":\"string\"}",
        .{ .allocate = .alloc_always },
    );

    const val = std.json.Value{ .integer = 42 };
    const result = json_schema.validate(val, schema.value);
    try testing.expect(!result.valid);
    try testing.expect(result.message.len > 0);
}

// ---------------------------------------------------------------------------
// TC-EE-09-U03: enum constraint passes for an allowed value
// ---------------------------------------------------------------------------
test "TC-EE-09-U03: json_schema enum passes for allowed value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const schema = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"type\":\"string\",\"enum\":[\"pending\",\"approved\"]}",
        .{ .allocate = .alloc_always },
    );

    const val = std.json.Value{ .string = "approved" };
    const result = json_schema.validate(val, schema.value);
    try testing.expect(result.valid);
}

// ---------------------------------------------------------------------------
// TC-EE-09-U04: enum constraint fails for a disallowed value
// ---------------------------------------------------------------------------
test "TC-EE-09-U04: json_schema enum fails for disallowed value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const schema = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"type\":\"string\",\"enum\":[\"pending\",\"approved\"]}",
        .{ .allocate = .alloc_always },
    );

    const val = std.json.Value{ .string = "rejected" };
    const result = json_schema.validate(val, schema.value);
    try testing.expect(!result.valid);
}

// ---------------------------------------------------------------------------
// TC-EE-09-U05: minimum/maximum passes for an in-range integer
// ---------------------------------------------------------------------------
test "TC-EE-09-U05: json_schema minimum/maximum passes for in-range integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const schema = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"type\":\"integer\",\"minimum\":0,\"maximum\":100}",
        .{ .allocate = .alloc_always },
    );

    const val = std.json.Value{ .integer = 50 };
    const result = json_schema.validate(val, schema.value);
    try testing.expect(result.valid);
}

// ---------------------------------------------------------------------------
// TC-EE-09-U06: minimum fails for a below-range value
// ---------------------------------------------------------------------------
test "TC-EE-09-U06: json_schema minimum fails for below-range value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const schema = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"type\":\"integer\",\"minimum\":0,\"maximum\":100}",
        .{ .allocate = .alloc_always },
    );

    const val = std.json.Value{ .integer = -1 };
    const result = json_schema.validate(val, schema.value);
    try testing.expect(!result.valid);
}

// ---------------------------------------------------------------------------
// TC-EE-09-U07: maxLength passes for a string within limit
// ---------------------------------------------------------------------------
test "TC-EE-09-U07: json_schema maxLength passes for short string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const schema = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"type\":\"string\",\"maxLength\":5}",
        .{ .allocate = .alloc_always },
    );

    const val = std.json.Value{ .string = "hi" };
    const result = json_schema.validate(val, schema.value);
    try testing.expect(result.valid);
}

// ---------------------------------------------------------------------------
// TC-EE-09-U08: maxLength fails for a string exceeding the limit
// ---------------------------------------------------------------------------
test "TC-EE-09-U08: json_schema maxLength fails for over-length string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const schema = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        "{\"type\":\"string\",\"maxLength\":5}",
        .{ .allocate = .alloc_always },
    );

    const val = std.json.Value{ .string = "toolong" };
    const result = json_schema.validate(val, schema.value);
    try testing.expect(!result.valid);
}

// ---------------------------------------------------------------------------
// TC-EE-09-U09: mergeVariables fast-path — empty output_variables returns
//               current_vars unchanged with no overwritten events and no DB call.
//
// The fast path in mergeVariables returns immediately when output_variables
// is empty (count == 0), cloning current_vars without touching any DB conn.
// We create a minimal InstanceStore with undefined pool/snapshot_store pointers
// (they are never dereferenced because `_ = self` discards self on entry, and
// the fast path exits before any DB call).  No mock or stub is involved.
// ---------------------------------------------------------------------------
test "TC-EE-09-U09: mergeVariables fast-path: empty output returns current_vars, no events" {
    const alloc = testing.allocator;

    // Minimal InstanceStore — pool/snapshot_store are undefined because the
    // fast path discards self immediately (`_ = self`) and exits before any
    // pool or conn access.
    var store = instance_mod.InstanceStore{
        .pool = undefined,
        .snapshot_store = undefined,
    };

    // Build current_vars with one entry.
    var current_vars: std.json.ObjectMap = .{};
    defer current_vars.deinit(alloc);
    try current_vars.put(alloc, "x", .{ .integer = 1 });

    // Empty output_variables triggers the fast path.
    const output_variables: std.json.ObjectMap = .{};

    // Dummy zero UUIDs — not dereferenced on the empty path.
    const zero_uuid = std.mem.zeroes([16]u8);

    var violation_out: ?instance_mod.SchemaViolationDetail = null;

    // Dummy conn storage — never accessed on the fast path.
    var dummy_conn: bpm.db_pool.Conn = undefined;

    var result = try store.mergeVariables(
        alloc,
        &dummy_conn,
        zero_uuid,
        zero_uuid,
        null,
        current_vars,
        output_variables,
        &violation_out,
    );
    defer result.merged.deinit(alloc);
    // overwritten_events is &.{} (comptime empty slice) on the fast path — nothing to free.

    // merged must contain the original variable.
    const x_val = result.merged.get("x") orelse return error.MissingKey;
    try testing.expectEqual(@as(i64, 1), x_val.integer);

    // No overwritten events emitted for an empty merge.
    try testing.expectEqual(@as(usize, 0), result.overwritten_events.len);

    // violation_out must remain null (no schema check occurred).
    try testing.expect(violation_out == null);
}

// ---------------------------------------------------------------------------
// TC-EE-09-U10: MergeVariablesError type completeness (compile-time)
//
// Verifies that the error set exported from instance_mod contains every
// variant that the EE-09 spec requires, so that handlers and tests written
// against those variants will compile.
// ---------------------------------------------------------------------------
test "TC-EE-09-U10: MergeVariablesError contains all required variants" {
    // Compile-time type assertions only — no runtime assertions needed.
    const e1: instance_mod.MergeVariablesError = error.SchemaViolation;
    const e2: instance_mod.MergeVariablesError = error.PersistenceFailed;
    const e3: instance_mod.MergeVariablesError = error.OutOfMemory;

    try testing.expect(e1 == error.SchemaViolation);
    try testing.expect(e2 == error.PersistenceFailed);
    try testing.expect(e3 == error.OutOfMemory);
}
