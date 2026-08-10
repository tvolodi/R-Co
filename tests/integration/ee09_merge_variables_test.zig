//! Integration tests for EE-09 — Variable Scoping and Merge.
//!
//! Tests exercise InstanceStore.completeTask() against a real PostgreSQL
//! database, verifying all three merge paths and the EE-10 ERROR transition
//! on schema violation.
//!
//! DIRECTIVE T-1: all tests use a real database; no mocks or stubs.
//!
//! Requires: BPM_TEST_DB_URL environment variable pointing to the test database.
//!
//! Isolation: each test creates its own definition, instance, and task rows,
//! then cleans up in FK order (tasks → events → instance_definition_snapshots
//! → instance_projections → variable_schemas → process_definitions) after the
//! assertion phase.
//!
//! Requirement traceability:
//!   EE-09 → TC-EE-09-01 through TC-EE-09-08
//!   (see tests/specs/EE-09.md for full Given/When/Then specs)
const std = @import("std");
const portable_env = @import("env");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;

const DefinitionStore = bpm.definition.Store;
const Definition = bpm.definition.Definition;
const CreateParams = bpm.definition.CreateParams;
const GraphNode = bpm.definition.GraphNode;
const GraphEdge = bpm.definition.GraphEdge;
const DefinitionGraph = bpm.definition.DefinitionGraph;

const SnapshotStore = bpm.snapshot.SnapshotStore;
const InstanceStore = bpm.engine.InstanceStore;
const InstanceStatus = bpm.engine.InstanceStatus;
const CompleteTaskError = bpm.engine.CompleteTaskError;

const TaskStore = bpm.tasks.TaskStore;

/// Fake "created_by" UUID; no FK constraint on process_definitions.created_by.
// GH-512 retention: conventional creator_uuid_str module-scope fixture (no FK constraint, stable identity for created_by column)
const creator_uuid_str = "00000000-0000-0000-0000-000000000099";

// ---------------------------------------------------------------------------
// Read BPM_TEST_DB_URL; return SkipZigTest if absent.
// ---------------------------------------------------------------------------
fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — skipping EE-09 integration tests\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_default,public (schema isolation).
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

fn parseUuid(_: std.mem.Allocator, s: []const u8) ![16]u8 {
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    for (s) |c| {
        if (c == '-') continue;
        if (i >= 32) return error.InvalidUuid;
        buf[i] = c;
        i += 1;
    }
    if (i != 32) return error.InvalidUuid;
    var out: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, buf[0..32]);
    return out;
}

/// Render [16]u8 UUID as lowercase hex with hyphens (36 chars).
fn uuidToHexStr(allocator: std.mem.Allocator, uuid: [16]u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            uuid[0],  uuid[1],  uuid[2],  uuid[3],
            uuid[4],  uuid[5],  uuid[6],  uuid[7],
            uuid[8],  uuid[9],  uuid[10], uuid[11],
            uuid[12], uuid[13], uuid[14], uuid[15],
        },
    );
}

/// Free allocator-owned fields of a Definition.
fn freeDefinition(allocator: std.mem.Allocator, d: Definition) void {
    allocator.free(d.name);
    allocator.free(d.version);
    if (d.description) |desc| allocator.free(desc);
    if (d.stage) |st| allocator.free(st);
    bpm.definition.freeDefinitionGraph(allocator, d.graph);
}

// ---------------------------------------------------------------------------
// TC-EE-09-01: New key insert — output_variables adds a key absent from the
//              instance map; no VARIABLE_OVERWRITTEN event appended.
// ---------------------------------------------------------------------------
test "TC-EE-09-01: new key insert — key inserted, no VARIABLE_OVERWRITTEN event" {
    const allocator = std.testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(allocator, &pool);
    defer def_store.deinit();
    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    var task_store = TaskStore.init(&pool);

    // Create a minimal definition: START → HUMAN_TASK → END
    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = "Task", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"u1\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "T", .target = "E", .condition = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const created_by = try parseUuid(allocator, creator_uuid_str);
    const def = try def_store.create(allocator, CreateParams{
        .name = "EE09-TC01",
        .version = "1.0",
        .description = null,
        .stage = null,
        .created_by = created_by,
        .graph = graph,
    });
    defer {
        allocator.free(def.name);
        allocator.free(def.version);
        bpm.definition.freeDefinitionGraph(allocator, def.graph);
    }
    defer cleanup: {
        const conn = pool.acquire() catch break :cleanup;
        defer pool.release(conn);
        conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{"EE09-TC01"}) catch {};
    }

    // Activate the definition.
    const activated = try def_store.activate(allocator, def.id);
    defer freeDefinition(allocator, activated);

    // Start an instance with existing_key = "old_value".
    const inst = try inst_store.create(allocator, def.id, null, "{\"existing_key\":\"old_value\"}");
    defer {
        allocator.free(inst.initial_variables);
        allocator.free(inst.definition_snapshot);
        if (inst.correlation_key) |ck| allocator.free(ck);
    }
    const inst_id_hex = try uuidToHexStr(allocator, inst.instance_id);
    defer allocator.free(inst_id_hex);

    // Retrieve the pending task.
    const tasks_list = try task_store.list(allocator, inst.instance_id, null, null, 50, 0);
    defer {
        for (tasks_list) |t| bpm.tasks.freeTask(allocator, t);
        allocator.free(tasks_list);
    }
    try std.testing.expect(tasks_list.len > 0);
    const task_id = tasks_list[0].task_id;

    // Complete the task with a new key not present in the instance map.
    _ = try inst_store.completeTask(allocator, &task_store, task_id, "{\"new_key\":\"new_value\"}");

    // Verify: instance_projections.variables contains both keys.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const rows = try conn.query(
            allocator,
            "SELECT variables FROM instance_projections WHERE instance_id = $1::uuid",
            &.{inst_id_hex},
        );
        defer {
            var r = rows;
            r.deinit();
        }
        try std.testing.expect(rows.rows.len == 1);
        const vars_json = rows.rows[0][0] orelse "";
        try std.testing.expect(std.mem.indexOf(u8, vars_json, "new_key") != null);
        try std.testing.expect(std.mem.indexOf(u8, vars_json, "existing_key") != null);
    }

    // Verify: no VARIABLE_OVERWRITTEN event exists for this instance.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const rows = try conn.query(
            allocator,
            "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'VARIABLE_OVERWRITTEN'",
            &.{inst_id_hex},
        );
        defer {
            var r = rows;
            r.deinit();
        }
        // COUNT(*) returns "0" for no matching rows.
        const count_str = rows.rows[0][0] orelse "0";
        try std.testing.expectEqualStrings("0", count_str);
    }
}

// ---------------------------------------------------------------------------
// TC-EE-09-02: Existing key overwrite (no schema) — key overwritten; one
//              VARIABLE_OVERWRITTEN event appended with correct old/new values.
// ---------------------------------------------------------------------------
test "TC-EE-09-02: existing key overwrite (no schema) — VARIABLE_OVERWRITTEN event appended" {
    const allocator = std.testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(allocator, &pool);
    defer def_store.deinit();
    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    var task_store = TaskStore.init(&pool);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = "Task", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"u1\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "T", .target = "E", .condition = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const created_by = try parseUuid(allocator, creator_uuid_str);
    const def = try def_store.create(allocator, CreateParams{
        .name = "EE09-TC02",
        .version = "1.0",
        .description = null,
        .stage = null,
        .created_by = created_by,
        .graph = graph,
    });
    defer {
        allocator.free(def.name);
        allocator.free(def.version);
        bpm.definition.freeDefinitionGraph(allocator, def.graph);
    }
    defer cleanup: {
        const conn = pool.acquire() catch break :cleanup;
        defer pool.release(conn);
        conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{"EE09-TC02"}) catch {};
    }

    const activated = try def_store.activate(allocator, def.id);
    defer freeDefinition(allocator, activated);

    const inst = try inst_store.create(allocator, def.id, null, "{\"score\":42}");
    defer {
        allocator.free(inst.initial_variables);
        allocator.free(inst.definition_snapshot);
        if (inst.correlation_key) |ck| allocator.free(ck);
    }
    const inst_id_hex = try uuidToHexStr(allocator, inst.instance_id);
    defer allocator.free(inst_id_hex);

    const tasks_list = try task_store.list(allocator, inst.instance_id, null, null, 50, 0);
    defer {
        for (tasks_list) |t| bpm.tasks.freeTask(allocator, t);
        allocator.free(tasks_list);
    }
    try std.testing.expect(tasks_list.len > 0);
    const task_id = tasks_list[0].task_id;

    _ = try inst_store.completeTask(allocator, &task_store, task_id, "{\"score\":99}");

    // Verify: instance variable updated.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const rows = try conn.query(
            allocator,
            "SELECT variables FROM instance_projections WHERE instance_id = $1::uuid",
            &.{inst_id_hex},
        );
        defer {
            var r = rows;
            r.deinit();
        }
        const vars_json = rows.rows[0][0] orelse "";
        try std.testing.expect(std.mem.indexOf(u8, vars_json, "99") != null);
    }

    // Verify: exactly one VARIABLE_OVERWRITTEN event with correct key.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const rows = try conn.query(
            allocator,
            "SELECT payload FROM events WHERE instance_id = $1::uuid AND event_type = 'VARIABLE_OVERWRITTEN'",
            &.{inst_id_hex},
        );
        defer {
            var r = rows;
            r.deinit();
        }
        try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
        const payload = rows.rows[0][0] orelse "";
        try std.testing.expect(std.mem.indexOf(u8, payload, "score") != null);
        try std.testing.expect(std.mem.indexOf(u8, payload, "42") != null);
        try std.testing.expect(std.mem.indexOf(u8, payload, "99") != null);
    }
}

// ---------------------------------------------------------------------------
// TC-EE-09-04: Schema violation — merge NOT applied; instance → ERROR;
//              EXECUTION_ERROR event appended; HTTP layer returns 422.
// ---------------------------------------------------------------------------
test "TC-EE-09-04: schema violation — merge aborted, instance transitions to ERROR" {
    const allocator = std.testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(allocator, &pool);
    defer def_store.deinit();
    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    var task_store = TaskStore.init(&pool);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = "Task", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"u1\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "T", .target = "E", .condition = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const created_by = try parseUuid(allocator, creator_uuid_str);
    const def = try def_store.create(allocator, CreateParams{
        .name = "EE09-TC04",
        .version = "1.0",
        .description = null,
        .stage = null,
        .created_by = created_by,
        .graph = graph,
    });
    defer {
        allocator.free(def.name);
        allocator.free(def.version);
        bpm.definition.freeDefinitionGraph(allocator, def.graph);
    }
    defer cleanup: {
        const conn = pool.acquire() catch break :cleanup;
        defer pool.release(conn);
        conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{"EE09-TC04"}) catch {};
    }

    const activated = try def_store.activate(allocator, def.id);
    defer freeDefinition(allocator, activated);

    // Register a variable schema for "status" with enum constraint.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);

        // Build definition_id hex for parameterised query.
        var def_id_hex_buf: [36]u8 = undefined;
        const def_id_hex = try std.fmt.bufPrint(
            &def_id_hex_buf,
            "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
            .{
                def.id[0],  def.id[1],  def.id[2],  def.id[3],
                def.id[4],  def.id[5],  def.id[6],  def.id[7],
                def.id[8],  def.id[9],  def.id[10], def.id[11],
                def.id[12], def.id[13], def.id[14], def.id[15],
            },
        );

        try conn.exec(
            "INSERT INTO variable_schemas (definition_id, variable_key, json_schema) VALUES ($1::uuid, $2, $3::jsonb)",
            &.{ def_id_hex, "status", "{\"type\":\"string\",\"enum\":[\"pending\",\"approved\",\"rejected\"]}" },
        );
    }

    const inst = try inst_store.create(allocator, def.id, null, "{\"status\":\"pending\"}");
    defer {
        allocator.free(inst.initial_variables);
        allocator.free(inst.definition_snapshot);
        if (inst.correlation_key) |ck| allocator.free(ck);
    }
    const inst_id_hex = try uuidToHexStr(allocator, inst.instance_id);
    defer allocator.free(inst_id_hex);

    const tasks_list = try task_store.list(allocator, inst.instance_id, null, null, 50, 0);
    defer {
        for (tasks_list) |t| bpm.tasks.freeTask(allocator, t);
        allocator.free(tasks_list);
    }
    try std.testing.expect(tasks_list.len > 0);
    const task_id = tasks_list[0].task_id;

    // Complete the task with a schema-violating value.
    const complete_err = inst_store.completeTask(
        allocator,
        &task_store,
        task_id,
        "{\"status\":\"unknown_state\"}",
    );
    try std.testing.expectError(CompleteTaskError.InstanceInError, complete_err);

    // Verify: instance_projections.status is now ERROR.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const rows = try conn.query(
            allocator,
            "SELECT status, variables FROM instance_projections WHERE instance_id = $1::uuid",
            &.{inst_id_hex},
        );
        defer {
            var r = rows;
            r.deinit();
        }
        try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
        const status_str = rows.rows[0][0] orelse "";
        try std.testing.expectEqualStrings("ERROR", status_str);

        // variables must remain unchanged (merge was NOT applied).
        const vars_json = rows.rows[0][1] orelse "";
        try std.testing.expect(std.mem.indexOf(u8, vars_json, "pending") != null);
        try std.testing.expect(std.mem.indexOf(u8, vars_json, "unknown_state") == null);
    }

    // Verify: an EXECUTION_ERROR event exists.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const rows = try conn.query(
            allocator,
            "SELECT payload FROM events WHERE instance_id = $1::uuid AND event_type = 'EXECUTION_ERROR'",
            &.{inst_id_hex},
        );
        defer {
            var r = rows;
            r.deinit();
        }
        try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
        const payload = rows.rows[0][0] orelse "";
        try std.testing.expect(std.mem.indexOf(u8, payload, "SCHEMA_VIOLATION") != null);
    }

    // Verify: no VARIABLE_OVERWRITTEN event.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const rows = try conn.query(
            allocator,
            "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'VARIABLE_OVERWRITTEN'",
            &.{inst_id_hex},
        );
        defer {
            var r = rows;
            r.deinit();
        }
        const count_str = rows.rows[0][0] orelse "0";
        try std.testing.expectEqualStrings("0", count_str);
    }
}

// ---------------------------------------------------------------------------
// TC-EE-09-05: Empty output_variables — no events emitted; instance variables
//              remain unchanged; one TASK_COMPLETED event exists.
// ---------------------------------------------------------------------------
test "TC-EE-09-05: empty output_variables — no events, variables unchanged" {
    const allocator = std.testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(allocator, &pool);
    defer def_store.deinit();
    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    var task_store = TaskStore.init(&pool);

    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = "Task", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"u1\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "T", .target = "E", .condition = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const created_by = try parseUuid(allocator, creator_uuid_str);
    const def = try def_store.create(allocator, CreateParams{
        .name = "EE09-TC05",
        .version = "1.0",
        .description = null,
        .stage = null,
        .created_by = created_by,
        .graph = graph,
    });
    defer {
        allocator.free(def.name);
        allocator.free(def.version);
        bpm.definition.freeDefinitionGraph(allocator, def.graph);
    }
    defer cleanup: {
        const conn = pool.acquire() catch break :cleanup;
        defer pool.release(conn);
        conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{"EE09-TC05"}) catch {};
    }

    const activated = try def_store.activate(allocator, def.id);
    defer freeDefinition(allocator, activated);

    const inst = try inst_store.create(allocator, def.id, null, "{\"key1\":\"value1\"}");
    defer {
        allocator.free(inst.initial_variables);
        allocator.free(inst.definition_snapshot);
        if (inst.correlation_key) |ck| allocator.free(ck);
    }
    const inst_id_hex = try uuidToHexStr(allocator, inst.instance_id);
    defer allocator.free(inst_id_hex);

    const tasks_list = try task_store.list(allocator, inst.instance_id, null, null, 50, 0);
    defer {
        for (tasks_list) |t| bpm.tasks.freeTask(allocator, t);
        allocator.free(tasks_list);
    }
    try std.testing.expect(tasks_list.len > 0);
    const task_id = tasks_list[0].task_id;

    _ = try inst_store.completeTask(allocator, &task_store, task_id, "{}");

    // Verify: variables unchanged.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const rows = try conn.query(
            allocator,
            "SELECT variables FROM instance_projections WHERE instance_id = $1::uuid",
            &.{inst_id_hex},
        );
        defer {
            var r = rows;
            r.deinit();
        }
        const vars_json = rows.rows[0][0] orelse "";
        try std.testing.expect(std.mem.indexOf(u8, vars_json, "key1") != null);
        try std.testing.expect(std.mem.indexOf(u8, vars_json, "value1") != null);
    }

    // Verify: no VARIABLE_OVERWRITTEN event.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const rows = try conn.query(
            allocator,
            "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'VARIABLE_OVERWRITTEN'",
            &.{inst_id_hex},
        );
        defer {
            var r = rows;
            r.deinit();
        }
        const count_str = rows.rows[0][0] orelse "0";
        try std.testing.expectEqualStrings("0", count_str);
    }

    // Verify: exactly one TASK_COMPLETED event.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const rows = try conn.query(
            allocator,
            "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'task_completed'",
            &.{inst_id_hex},
        );
        defer {
            var r = rows;
            r.deinit();
        }
        const count_str = rows.rows[0][0] orelse "0";
        try std.testing.expectEqualStrings("1", count_str);
    }
}

// ---------------------------------------------------------------------------
// ISS-202: Two-Phase Merge Tests
// ---------------------------------------------------------------------------
// These tests verify the two-phase merge implementation where Phase 1
// validates ALL keys before any state change, and Phase 2 applies all keys
// only if Phase 1 succeeds.
//
// Key invariant: all-or-nothing merge — either all output variables are
// applied, or none are applied on failure.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// TC-ISS-202-01: Mixed valid/invalid keys — instance remains ERROR-free,
//                no variables applied, only EXECUTION_ERROR emitted.
//
// Given: A process instance with initial variables { "status": "pending" }
// And: A task that outputs { "status": "approved", "amount": 999999 }
// And: "amount" has a schema constraint { "type": "number", "maximum": 100 }
// When: Task is completed with the output variables
// Then: completeTask returns error.InstanceInError
// And:  Instance status is ERROR
// And:  Variables remain unchanged (pre-merge state: {"status": "pending"})
// And:  No VARIABLE_OVERWRITTEN events are emitted
// And:  Exactly one EXECUTION_ERROR event is emitted with reason containing
//       "amount" and the schema violation reason
// ---------------------------------------------------------------------------
test "TC-ISS-202-01: mixed valid/invalid keys — all-or-nothing merge failure, variables unchanged" {
    const allocator = std.testing.allocator;
    const url = try testDbUrl(allocator);
    defer allocator.free(url);

    var pool = try makePool(allocator, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(allocator, &pool);
    defer def_store.deinit();
    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    var task_store = TaskStore.init(&pool);

    // Create a minimal definition: START → HUMAN_TASK → END
    const nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "T", .node_type = .HUMAN_TASK, .label = "Task", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"u1\"}" },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = [_]GraphEdge{
        .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
        .{ .id = "e2", .source = "T", .target = "E", .condition = null, .is_default = false },
    };
    const graph = DefinitionGraph{ .nodes = &nodes, .edges = &edges };

    const created_by = try parseUuid(allocator, creator_uuid_str);
    const def = try def_store.create(allocator, CreateParams{
        .name = "ISS202-TC01",
        .version = "1.0",
        .description = null,
        .stage = null,
        .created_by = created_by,
        .graph = graph,
    });
    defer {
        allocator.free(def.name);
        allocator.free(def.version);
        bpm.definition.freeDefinitionGraph(allocator, def.graph);
    }
    // GH-654 / ISS-0649: registered immediately after creation (not at the end
    // of the test) so an early `try` failure anywhere below still runs this
    // cleanup instead of leaving an orphaned process_definitions row that
    // collides with the next run via DuplicateNameVersion.
    defer cleanup: {
        const conn = pool.acquire() catch break :cleanup;
        defer pool.release(conn);
        conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{"ISS202-TC01"}) catch {};
    }

    // Insert a variable schema: "amount" must be <= 100
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const def_id_hex = try std.fmt.allocPrint(allocator,
            "{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
            .{
                def.id[0],  def.id[1],  def.id[2],  def.id[3],
                def.id[4],  def.id[5],  def.id[6],  def.id[7],
                def.id[8],  def.id[9],  def.id[10], def.id[11],
                def.id[12], def.id[13], def.id[14], def.id[15],
            });
        defer allocator.free(def_id_hex);

        try conn.exec(
            \\INSERT INTO variable_schemas (definition_id, variable_key, json_schema)
            \\VALUES ($1::uuid, $2, $3)
        ,
            &.{ def_id_hex, "amount", "{\"type\":\"number\",\"maximum\":100}" },
        );
    }

    // Activate the definition, then start an instance through the real engine
    // (GH-654 / ISS-0649: the previous hand-rolled raw-SQL setup for
    // instance_projections/instance_definition_snapshots/tasks bypassed the
    // engine and was missing required NOT NULL / FK columns — tasks.token_id
    // in particular is a real FK into the tokens table that only the engine's
    // own instance-start path populates correctly. Every sibling test in this
    // file already uses this same activate+create+list pattern).
    const activated = try def_store.activate(allocator, def.id);
    defer freeDefinition(allocator, activated);

    const inst = try inst_store.create(allocator, def.id, null, "{\"status\":\"pending\"}");
    defer {
        allocator.free(inst.initial_variables);
        allocator.free(inst.definition_snapshot);
        if (inst.correlation_key) |ck| allocator.free(ck);
    }
    const inst_id_hex = try uuidToHexStr(allocator, inst.instance_id);
    defer allocator.free(inst_id_hex);

    const tasks_list = try task_store.list(allocator, inst.instance_id, null, null, 50, 0);
    defer {
        for (tasks_list) |t| bpm.tasks.freeTask(allocator, t);
        allocator.free(tasks_list);
    }
    try std.testing.expect(tasks_list.len > 0);
    const task_id = tasks_list[0].task_id;

    // Complete task with output variables: one valid (status), one invalid (amount=999999)
    const output_variables = "{\"status\":\"approved\",\"amount\":999999}";
    const result = inst_store.completeTask(allocator, &task_store, task_id, output_variables);

    // Verify: completeTask returned InstanceInError
    try std.testing.expectError(CompleteTaskError.InstanceInError, result);

    // Verify: instance status is ERROR
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const rows = try conn.query(
            allocator,
            "SELECT status FROM instance_projections WHERE instance_id = $1::uuid",
            &.{inst_id_hex},
        );
        defer {
            var r = rows;
            r.deinit();
        }
        const status_str = rows.rows[0][0] orelse "";
        try std.testing.expectEqualStrings("ERROR", status_str);
    }

    // Verify: variables unchanged (still {"status":"pending"})
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const rows = try conn.query(
            allocator,
            "SELECT variables FROM instance_projections WHERE instance_id = $1::uuid",
            &.{inst_id_hex},
        );
        defer {
            var r = rows;
            r.deinit();
        }
        const vars_json = rows.rows[0][0] orelse "";
        // Should still contain original "pending" and NOT contain "approved"
        try std.testing.expect(std.mem.indexOf(u8, vars_json, "pending") != null);
        try std.testing.expect(std.mem.indexOf(u8, vars_json, "approved") == null);
    }

    // Verify: no VARIABLE_OVERWRITTEN events (all-or-nothing)
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const rows = try conn.query(
            allocator,
            "SELECT COUNT(*) FROM events WHERE instance_id = $1::uuid AND event_type = 'VARIABLE_OVERWRITTEN'",
            &.{inst_id_hex},
        );
        defer {
            var r = rows;
            r.deinit();
        }
        const count_str = rows.rows[0][0] orelse "0";
        try std.testing.expectEqualStrings("0", count_str);
    }

    // Verify: EXECUTION_ERROR event exists with reason mentioning schema violation
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        const rows = try conn.query(
            allocator,
            "SELECT payload FROM events WHERE instance_id = $1::uuid AND event_type = 'EXECUTION_ERROR'",
            &.{inst_id_hex},
        );
        defer {
            var r = rows;
            r.deinit();
        }
        try std.testing.expect(rows.rows.len >= 1);
        const payload_json = rows.rows[0][0] orelse "";
        try std.testing.expect(std.mem.indexOf(u8, payload_json, "amount") != null);
    }
}
