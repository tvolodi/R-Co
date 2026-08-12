//! Integration tests for PIN-05 (explicit instance pin rebind) — SHOULD.
//!
//! Covers:
//!   AC1 — a valid rebind on a running instance appends INSTANCE_PINS_REBOUND
//!         carrying prior_version/new_version/actor/reason per changed entry.
//!   AC2 — a rebind naming a reference absent from the current pin set
//!         returns 422 UnknownPinRef and applies NONE of the request's
//!         entries — tested with a MIXED valid+invalid entry set to prove
//!         true all-or-nothing (not merely an all-invalid request).
//!   AC3 — a rebind on a terminal instance (COMPLETED/CANCELLED/ERROR, this
//!         codebase's equivalent of the requirement text's FAILED — see
//!         src/engine/pin_rebind.zig's isTerminalStatus() doc comment)
//!         returns 409 InstanceNotRebindable.
//!   AC4 — a rebind request with no reason field returns 422.
//!
//! Priority: SHOULD per docs/requirements.yaml (PIN-05, priority: SHOULD) —
//! confirmed directly from the requirements file, not assumed.
//!
//! BPM_TEST_DB_URL must be set; connects to a real PostgreSQL (DIRECTIVE T-1).
const std = @import("std");
const portable_env = @import("env");
const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;

const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const InstanceStore = bpm.engine.InstanceStore;
const DefinitionStore = bpm.definition.Store;
const CreateParams = bpm.definition.CreateParams;
const DefinitionGraph = bpm.definition.DefinitionGraph;
const GraphNode = bpm.definition.GraphNode;
const GraphEdge = bpm.definition.GraphEdge;
const SnapshotStore = bpm.snapshot.SnapshotStore;
const pin_rebind_mod = bpm.pin_rebind;
const pin_rebind_routes = bpm.pin_rebind_routes;
const pin_resolver_mod = bpm.pin_resolver;

pub const api_tenant_context = bpm.api_tenant_context;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const service_task_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "H", .condition = null, .is_default = false },
    .{ .id = "e2", .source = "H", .target = "T", .condition = null, .is_default = false },
    .{ .id = "e3", .source = "T", .target = "E", .condition = null, .is_default = false },
};

fn serviceTaskGraph(svc_id: []const u8, nodes_buf: *[4]GraphNode, attrs_buf: []u8) DefinitionGraph {
    const attrs = std.fmt.bufPrint(
        attrs_buf,
        "{{\"service_id\":\"{s}\",\"capabilities\":[\"service:call:{s}\"],\"method\":\"POST\",\"timeout_ms\":5000,\"retry_limit\":1}}",
        .{ svc_id, svc_id },
    ) catch unreachable;
    nodes_buf[0] = .{ .id = "S", .node_type = .START, .label = null, .attributes = null };
    nodes_buf[1] = .{ .id = "H", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"tester\"}" };
    nodes_buf[2] = .{ .id = "T", .node_type = .SERVICE_TASK, .label = null, .attributes = attrs };
    nodes_buf[3] = .{ .id = "E", .node_type = .END, .label = null, .attributes = null };
    return DefinitionGraph{ .nodes = nodes_buf, .edges = &service_task_edges };
}

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — PIN-05 integration tests FAILED (env var required)\n", .{});
            return err;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 5 });
}

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

fn parseUuid(hex: []const u8) ![16]u8 {
    if (hex.len != 36) return error.InvalidUuid;
    var buf: [32]u8 = undefined;
    var i: usize = 0;
    for (hex) |c| {
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

fn randomId(buf: *[8]u8) []const u8 {
    const chars = "abcdefghijklmnopqrstuvwxyz0123456789";
    helpers.fillRandom(buf);
    for (buf) |*b| b.* = chars[@as(usize, b.*) % chars.len];
    return buf;
}

fn insertGlobalServiceViaPool(pool: *Pool, svc_id: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO public.service_catalog
        \\  (service_id, endpoint_url, request_schema, response_schema,
        \\   required_auth, timeout_ms, retry_policy, scope, owner_tenant_id)
        \\VALUES ($1, 'https://example.com', '{}', '{}', 'NONE', 5000, '{}', 'global', NULL)
        \\ON CONFLICT (service_id) DO NOTHING
    ,
        &.{svc_id},
    );
}

fn deleteServiceCatalogEntry(pool: *Pool, svc_id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM public.service_catalog WHERE service_id = $1", &.{svc_id}) catch {};
}

fn freeInstance(allocator: std.mem.Allocator, inst: bpm.engine.Instance) void {
    if (inst.correlation_key) |ck| allocator.free(ck);
    allocator.free(inst.initial_variables);
    allocator.free(inst.definition_snapshot);
}

fn cleanupInstanceAll(pool: *Pool, inst_hex: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM dead_letter_items WHERE instance_id = $1::uuid", &.{inst_hex}) catch {};
    conn.exec("DELETE FROM tasks WHERE instance_id = $1::uuid", &.{inst_hex}) catch {};
    conn.exec("DELETE FROM instance_state_snapshots WHERE instance_id = $1::uuid", &.{inst_hex}) catch {};
    conn.exec("DELETE FROM events WHERE instance_id = $1::uuid", &.{inst_hex}) catch {};
    conn.exec("DELETE FROM instance_definition_snapshots WHERE instance_id = $1::uuid", &.{inst_hex}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{inst_hex}) catch {};
    conn.exec("DELETE FROM instance_sequence WHERE instance_id = $1::uuid", &.{inst_hex}) catch {};
}

fn cleanupDefinitionByName(pool: *Pool, name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name}) catch {};
}

fn setInstanceStatus(pool: *Pool, inst_hex: []const u8, status: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        "UPDATE instance_projections SET status = $2 WHERE instance_id = $1::uuid",
        &.{ inst_hex, status },
    );
}

fn countReboundEvents(allocator: std.mem.Allocator, pool: *Pool, inst_hex: []const u8) !i64 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    var rows = try conn.query(
        allocator,
        "SELECT COUNT(*)::text FROM events WHERE instance_id = $1::uuid AND event_type = 'INSTANCE_PINS_REBOUND'",
        &.{inst_hex},
    );
    defer rows.deinit();
    if (rows.rows.len == 0 or rows.rows[0][0] == null) return 0;
    return std.fmt.parseInt(i64, rows.rows[0][0].?, 10) catch 0;
}

fn readLatestReboundPayload(allocator: std.mem.Allocator, pool: *Pool, inst_hex: []const u8) ![]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    var rows = try conn.query(
        allocator,
        \\SELECT payload::text FROM events
        \\WHERE instance_id = $1::uuid AND event_type = 'INSTANCE_PINS_REBOUND'
        \\ORDER BY sequence_number DESC LIMIT 1
    ,
        &.{inst_hex},
    );
    defer rows.deinit();
    if (rows.rows.len == 0 or rows.rows[0][0] == null) return error.NotFound;
    return allocator.dupe(u8, rows.rows[0][0].?);
}

fn actorUuidStr(alloc: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    helpers.fillRandom(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    return uuidToHexStr(alloc, raw);
}

// ---------------------------------------------------------------------------
// TC-PIN-05-01: valid rebind appends INSTANCE_PINS_REBOUND with
// prior_version/new_version/actor/reason per changed entry
// ---------------------------------------------------------------------------

test "TC-PIN-05-01: a valid rebind on a running instance appends INSTANCE_PINS_REBOUND with prior/new version, actor, reason" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(alloc, "svc-pin05-01-{s}", .{randomId(&id_buf)});
    defer alloc.free(svc_id);
    try insertGlobalServiceViaPool(&pool, svc_id);
    defer deleteServiceCatalogEntry(&pool, svc_id);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-PIN-05-01 Process";
    var created_by: [16]u8 = undefined;
    helpers.fillRandom(&created_by);

    var nodes_buf: [4]GraphNode = undefined;
    var attrs_buf: [192]u8 = undefined;
    const graph = serviceTaskGraph(svc_id, &nodes_buf, &attrs_buf);

    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = graph,
        .created_by = created_by,
    });
    defer draft.deinit(alloc);
    const active_def = try def_store.activate(alloc, draft.id);
    defer active_def.deinit(alloc);
    defer cleanupDefinitionByName(&pool, name);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, active_def.id, null, "{}");
    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer cleanupInstanceAll(&pool, inst_hex);
    defer freeInstance(alloc, inst);

    const actor_id = try actorUuidStr(alloc);
    defer alloc.free(actor_id);

    const entries = [_]pin_rebind_mod.RebindEntry{
        .{ .kind = .catalog_entry, .ref = svc_id, .version = "999999999999" },
    };
    const changes = try pin_rebind_mod.rebindPins(alloc, &pool, .{
        .instance_id = inst.instance_id,
        .entries = &entries,
        .reason = "TC-PIN-05-01 rollback test",
        .actor_id = actor_id,
    });
    defer pin_rebind_mod.freeRebindChanges(alloc, changes);

    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqualStrings(svc_id, changes[0].ref);
    try std.testing.expectEqualStrings("999999999999", changes[0].new_version);
    try std.testing.expect(changes[0].prior_version.len > 0);
    try std.testing.expect(!std.mem.eql(u8, changes[0].prior_version, changes[0].new_version));

    const rebound_count = try countReboundEvents(alloc, &pool, inst_hex);
    try std.testing.expectEqual(@as(i64, 1), rebound_count);

    const payload_text = try readLatestReboundPayload(alloc, &pool, inst_hex);
    defer alloc.free(payload_text);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload_text, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings(actor_id, obj.get("actor_id").?.string);
    try std.testing.expectEqualStrings("TC-PIN-05-01 rollback test", obj.get("reason").?.string);
    const change_arr = obj.get("changes").?.array;
    try std.testing.expectEqual(@as(usize, 1), change_arr.items.len);
    const c0 = change_arr.items[0].object;
    try std.testing.expectEqualStrings(svc_id, c0.get("ref").?.string);
    try std.testing.expectEqualStrings("999999999999", c0.get("new_version").?.string);
    try std.testing.expect(c0.get("prior_version").?.string.len > 0);
}

// ---------------------------------------------------------------------------
// TC-PIN-05-02: MIXED valid+invalid entries -> 422 UnknownPinRef,
// all-or-nothing (not merely all-invalid)
// ---------------------------------------------------------------------------

test "TC-PIN-05-02: a rebind request mixing one valid and one unknown ref applies NEITHER entry (true all-or-nothing)" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(alloc, "svc-pin05-02-{s}", .{randomId(&id_buf)});
    defer alloc.free(svc_id);
    try insertGlobalServiceViaPool(&pool, svc_id);
    defer deleteServiceCatalogEntry(&pool, svc_id);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-PIN-05-02 Process";
    var created_by: [16]u8 = undefined;
    helpers.fillRandom(&created_by);

    var nodes_buf: [4]GraphNode = undefined;
    var attrs_buf: [192]u8 = undefined;
    const graph = serviceTaskGraph(svc_id, &nodes_buf, &attrs_buf);

    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = graph,
        .created_by = created_by,
    });
    defer draft.deinit(alloc);
    const active_def = try def_store.activate(alloc, draft.id);
    defer active_def.deinit(alloc);
    defer cleanupDefinitionByName(&pool, name);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, active_def.id, null, "{}");
    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer cleanupInstanceAll(&pool, inst_hex);
    defer freeInstance(alloc, inst);

    const actor_id = try actorUuidStr(alloc);
    defer alloc.free(actor_id);

    var absent_id_buf: [8]u8 = undefined;
    const absent_ref = try std.fmt.allocPrint(alloc, "svc-absent-{s}", .{randomId(&absent_id_buf)});
    defer alloc.free(absent_ref);

    // ONE entry names a ref that genuinely IS in the current effective pin
    // set (svc_id); the OTHER names a ref that is NOT (absent_ref). This is
    // the mixed set the handoff explicitly requires — proving all-or-
    // nothing against a request that is not simply "every entry invalid".
    const entries = [_]pin_rebind_mod.RebindEntry{
        .{ .kind = .catalog_entry, .ref = svc_id, .version = "1" },
        .{ .kind = .catalog_entry, .ref = absent_ref, .version = "1" },
    };
    const result = pin_rebind_mod.rebindPins(alloc, &pool, .{
        .instance_id = inst.instance_id,
        .entries = &entries,
        .reason = "TC-PIN-05-02 mixed set",
        .actor_id = actor_id,
    });
    try std.testing.expectError(pin_rebind_mod.RebindError.UnknownPinRef, result);

    // No INSTANCE_PINS_REBOUND row exists at all — not even for the ONE
    // valid entry (svc_id). Confirms all-or-nothing, not "apply the valid
    // subset."
    const rebound_count = try countReboundEvents(alloc, &pool, inst_hex);
    try std.testing.expectEqual(@as(i64, 0), rebound_count);
}

// ---------------------------------------------------------------------------
// TC-PIN-05-03: rebind on a terminal instance -> 409 InstanceNotRebindable
// ---------------------------------------------------------------------------

test "TC-PIN-05-03: a rebind on a COMPLETED instance returns InstanceNotRebindable" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(alloc, "svc-pin05-03-{s}", .{randomId(&id_buf)});
    defer alloc.free(svc_id);
    try insertGlobalServiceViaPool(&pool, svc_id);
    defer deleteServiceCatalogEntry(&pool, svc_id);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-PIN-05-03 Process";
    var created_by: [16]u8 = undefined;
    helpers.fillRandom(&created_by);

    var nodes_buf: [4]GraphNode = undefined;
    var attrs_buf: [192]u8 = undefined;
    const graph = serviceTaskGraph(svc_id, &nodes_buf, &attrs_buf);

    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = graph,
        .created_by = created_by,
    });
    defer draft.deinit(alloc);
    const active_def = try def_store.activate(alloc, draft.id);
    defer active_def.deinit(alloc);
    defer cleanupDefinitionByName(&pool, name);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, active_def.id, null, "{}");
    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer cleanupInstanceAll(&pool, inst_hex);
    defer freeInstance(alloc, inst);

    try setInstanceStatus(&pool, inst_hex, "COMPLETED");

    const actor_id = try actorUuidStr(alloc);
    defer alloc.free(actor_id);

    const entries = [_]pin_rebind_mod.RebindEntry{
        .{ .kind = .catalog_entry, .ref = svc_id, .version = "1" },
    };
    const result = pin_rebind_mod.rebindPins(alloc, &pool, .{
        .instance_id = inst.instance_id,
        .entries = &entries,
        .reason = "TC-PIN-05-03 terminal check",
        .actor_id = actor_id,
    });
    try std.testing.expectError(pin_rebind_mod.RebindError.InstanceNotRebindable, result);

    const rebound_count = try countReboundEvents(alloc, &pool, inst_hex);
    try std.testing.expectEqual(@as(i64, 0), rebound_count);
}

// ---------------------------------------------------------------------------
// TC-PIN-05-04: rebind request with no reason field -> 422 (via the HTTP
// handler, which is where "no reason field" as a raw request shape is
// actually observable — rebindPins() itself takes a required Zig field)
// ---------------------------------------------------------------------------

test "TC-PIN-05-04: a rebind HTTP request with no reason field returns 422 INVALID_INPUT" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(alloc, "svc-pin05-04-{s}", .{randomId(&id_buf)});
    defer alloc.free(svc_id);
    try insertGlobalServiceViaPool(&pool, svc_id);
    defer deleteServiceCatalogEntry(&pool, svc_id);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-PIN-05-04 Process";
    var created_by: [16]u8 = undefined;
    helpers.fillRandom(&created_by);

    var nodes_buf: [4]GraphNode = undefined;
    var attrs_buf: [192]u8 = undefined;
    const graph = serviceTaskGraph(svc_id, &nodes_buf, &attrs_buf);

    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = graph,
        .created_by = created_by,
    });
    defer draft.deinit(alloc);
    const active_def = try def_store.activate(alloc, draft.id);
    defer active_def.deinit(alloc);
    defer cleanupDefinitionByName(&pool, name);

    var snap_store = SnapshotStore{ .pool = &pool };
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, active_def.id, null, "{}");
    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer cleanupInstanceAll(&pool, inst_hex);
    defer freeInstance(alloc, inst);

    const actor_id = try actorUuidStr(alloc);
    defer alloc.free(actor_id);

    const body = try std.fmt.allocPrint(
        alloc,
        "{{\"entries\":[{{\"kind\":\"catalog_entry\",\"ref\":\"{s}\",\"version\":\"1\"}}]}}",
        .{svc_id},
    );
    defer alloc.free(body);

    const result = pin_rebind_routes.handleRebindPins(&pool, alloc, actor_id, inst_hex, body);
    defer alloc.free(result.body);

    try std.testing.expectEqual(@as(u16, 422), result.status_code);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "INVALID_INPUT") != null);

    const rebound_count = try countReboundEvents(alloc, &pool, inst_hex);
    try std.testing.expectEqual(@as(i64, 0), rebound_count);
}
