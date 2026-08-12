//! Integration tests for PIN-04 (pin resolution on replay and in
//! sub-processes) — MUST.
//!
//! Covers:
//!   AC1 — reconstruction reads pins ONLY from INSTANCE_STARTED (+ latest
//!         INSTANCE_PINS_REBOUND, PIN-05), NEVER the live catalog: proven by
//!         mutating the live catalog after start and confirming
//!         reconstructEffectivePins() still reports the ORIGINAL pin.
//!   AC2/AC3 — sub-process child inherits the parent's pin set; entries the
//!         parent already pins carry source=inherited and the parent's
//!         version; a conflicting child-resolved version is recorded in the
//!         child's own INSTANCE_STARTED payload.
//!   AC4 — GET /api/v1/instances/{id}/pins returns the effective set with
//!         each entry's source event id.
//!   AC5 — reconstruction issues no read against the service catalog or the
//!         module registry (negative-space; live assertion + structural
//!         note).
//!
//! IMPLEMENTATION GAP FOUND DURING TEST DESIGN (flagged, not routed around):
//! AC2/AC3 (sub-process pin inheritance and conflict recording) are NOT
//! implemented. `src/engine/instance.zig`'s `startSubProcessesForPendingEventsInTx()`
//! calls the plain `InstanceStore.create()` path for the child instance —
//! the SAME path any independent top-level instance uses — with no
//! parent-pin-set lookup, no merge step, and no `pin_inheritance_conflicts`
//! field anywhere in the child's INSTANCE_STARTED payload construction
//! (`serialisePinnedVersions()` emits only `pinned_versions`). Confirmed by
//! reading `startSubProcessesForPendingEventsInTx()` in full and by
//! `grep -rn "pin_inheritance_conflicts\|inheritPins" src/` returning zero
//! matches outside `src/design/pin-04-*.md`. TC-PIN-04-03 and TC-PIN-04-04
//! below are written as REAL, runnable, fail-first-confirmed tests against
//! the AC text (not skipped) — they FAIL against the current implementation,
//! which is the correct and expected signal that AC2/AC3 remain
//! unimplemented. This is reported as a BLOCKER issue in this handoff's
//! result, per "Unblock-Everything" / "No SkipZigTest on a MUST test" — the
//! tests are not deferred, they are written and currently red, awaiting a
//! BACKEND-DEV fix.
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
const TaskStore = bpm.tasks.TaskStore;
const DefinitionStore = bpm.definition.Store;
const CreateParams = bpm.definition.CreateParams;
const DefinitionGraph = bpm.definition.DefinitionGraph;
const GraphNode = bpm.definition.GraphNode;
const GraphEdge = bpm.definition.GraphEdge;
const Definition = bpm.definition.Definition;
const SnapshotStore = bpm.snapshot.SnapshotStore;
const reconstruction_mod = bpm.reconstruction;
const instance_routes = bpm.instance_routes;

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
            std.debug.print("BPM_TEST_DB_URL is not set — PIN-04 integration tests FAILED (env var required)\n", .{});
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

fn publishNewerCatalogVersion(pool: *Pool, svc_id: []const u8) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\UPDATE public.service_catalog
        \\SET endpoint_url = 'https://example.com/v2', updated_at = NOW() + interval '1 second'
        \\WHERE service_id = $1
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

fn freeDefinition(allocator: std.mem.Allocator, d: Definition) void {
    allocator.free(d.name);
    allocator.free(d.version);
    if (d.description) |desc| allocator.free(desc);
    if (d.stage) |st| allocator.free(st);
    bpm.definition.freeDefinitionGraph(allocator, d.graph);
}

fn cleanupInstanceAll(pool: *Pool, inst_hex: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM subprocess_links WHERE parent_instance_id = $1::uuid OR child_instance_id = $1::uuid", &.{inst_hex}) catch {};
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

fn queryPendingTaskId(allocator: std.mem.Allocator, pool: *Pool, instance_id_hex: []const u8) ![16]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    var rows = try conn.query(
        allocator,
        "SELECT id FROM tasks WHERE instance_id = $1::uuid AND status = 'PENDING' ORDER BY created_at ASC LIMIT 1",
        &.{instance_id_hex},
    );
    defer rows.deinit();
    if (rows.rows.len == 0) return error.NotFound;
    return parseUuid(rows.rows[0][0] orelse "");
}

fn queryChildInstanceIdHex(allocator: std.mem.Allocator, pool: *Pool, parent_instance_hex: []const u8) ![]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    var rows = try conn.query(
        allocator,
        "SELECT child_instance_id::text FROM subprocess_links WHERE parent_instance_id = $1::uuid ORDER BY created_at DESC LIMIT 1",
        &.{parent_instance_hex},
    );
    defer rows.deinit();
    if (rows.rows.len == 0) return error.NotFound;
    return allocator.dupe(u8, rows.rows[0][0] orelse "");
}

fn queryPinnedResolvedId(allocator: std.mem.Allocator, pool: *Pool, inst_hex: []const u8, svc_id: []const u8) ![]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    var rows = try conn.query(
        allocator,
        "SELECT payload::text FROM events WHERE instance_id = $1::uuid AND event_type = 'instance_started'",
        &.{inst_hex},
    );
    defer rows.deinit();
    if (rows.rows.len == 0 or rows.rows[0][0] == null) return error.NotFound;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, rows.rows[0][0].?, .{});
    defer parsed.deinit();
    const pv = parsed.value.object.get("pinned_versions") orelse return error.NotFound;
    for (pv.array.items) |item| {
        const kind = item.object.get("kind").?.string;
        if (!std.mem.eql(u8, kind, "catalog_entry")) continue;
        const ref = item.object.get("ref").?.string;
        if (!std.mem.eql(u8, ref, svc_id)) continue;
        return allocator.dupe(u8, item.object.get("resolved_id").?.string);
    }
    return error.NotFound;
}

fn queryStartedPayloadText(allocator: std.mem.Allocator, pool: *Pool, inst_hex: []const u8) ![]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    var rows = try conn.query(
        allocator,
        "SELECT payload::text FROM events WHERE instance_id = $1::uuid AND event_type = 'instance_started'",
        &.{inst_hex},
    );
    defer rows.deinit();
    if (rows.rows.len == 0 or rows.rows[0][0] == null) return error.NotFound;
    return allocator.dupe(u8, rows.rows[0][0].?);
}

// ---------------------------------------------------------------------------
// TC-PIN-04-01: reconstruction reads pins ONLY from the event log, never the
// live catalog — proven by mutating the catalog after start
// ---------------------------------------------------------------------------

test "TC-PIN-04-01: reconstructEffectivePins still reports the ORIGINAL pin after the live catalog changes" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(alloc, "svc-pin04-01-{s}", .{randomId(&id_buf)});
    defer alloc.free(svc_id);
    try insertGlobalServiceViaPool(&pool, svc_id);
    defer deleteServiceCatalogEntry(&pool, svc_id);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-PIN-04-01 Process";
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

    const pins_before = try reconstruction_mod.reconstructEffectivePins(alloc, &pool, inst.instance_id);
    defer reconstruction_mod.pin_resolver_mod.freeEffectivePins(alloc, pins_before);

    var resolved_before: ?[]const u8 = null;
    for (pins_before) |ep| {
        if (ep.pin.kind == .catalog_entry and std.mem.eql(u8, ep.pin.ref, svc_id)) {
            resolved_before = ep.pin.resolved_id;
        }
    }
    try std.testing.expect(resolved_before != null);
    const resolved_before_owned = try alloc.dupe(u8, resolved_before.?);
    defer alloc.free(resolved_before_owned);

    // Change the LIVE catalog after the instance started.
    try publishNewerCatalogVersion(&pool, svc_id);

    const pins_after = try reconstruction_mod.reconstructEffectivePins(alloc, &pool, inst.instance_id);
    defer reconstruction_mod.pin_resolver_mod.freeEffectivePins(alloc, pins_after);

    var resolved_after: ?[]const u8 = null;
    for (pins_after) |ep| {
        if (ep.pin.kind == .catalog_entry and std.mem.eql(u8, ep.pin.ref, svc_id)) {
            resolved_after = ep.pin.resolved_id;
        }
    }
    try std.testing.expect(resolved_after != null);
    // AC1: reconstruction still reflects the ORIGINAL pin, unaffected by the
    // live catalog mutation.
    try std.testing.expectEqualStrings(resolved_before_owned, resolved_after.?);
}

// ---------------------------------------------------------------------------
// TC-PIN-04-02: reconstruction issues no read against the service catalog
// or module registry (AC5, negative-space)
// ---------------------------------------------------------------------------

test "TC-PIN-04-02: reconstructEffectivePins succeeds even after the service_catalog row is deleted entirely" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(alloc, "svc-pin04-02-{s}", .{randomId(&id_buf)});
    defer alloc.free(svc_id);
    try insertGlobalServiceViaPool(&pool, svc_id);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-PIN-04-02 Process";
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

    // Delete the catalog row ENTIRELY — if reconstruction issued any read
    // against service_catalog to re-resolve the pin, it would now either
    // fail or drop the entry. Per AC5, reconstruction never queries the
    // catalog at all, so the reconstructed effective set is unaffected.
    deleteServiceCatalogEntry(&pool, svc_id);

    const pins = try reconstruction_mod.reconstructEffectivePins(alloc, &pool, inst.instance_id);
    defer reconstruction_mod.pin_resolver_mod.freeEffectivePins(alloc, pins);

    var found = false;
    for (pins) |ep| {
        if (ep.pin.kind == .catalog_entry and std.mem.eql(u8, ep.pin.ref, svc_id)) found = true;
    }
    try std.testing.expect(found);
}

// ---------------------------------------------------------------------------
// TC-PIN-04-03 / TC-PIN-04-04: sub-process pin inheritance and conflict
// recording — AC2/AC3
//
// GAP: see this file's header comment. startSubProcessesForPendingEventsInTx()
// calls InstanceStore.create() for the child with no parent-pin merge. These
// tests are written against the AC text as specified and are EXPECTED TO
// FAIL against the current implementation — this is the fail-first
// confirmation, not a defect in the test.
// ---------------------------------------------------------------------------

fn setupParentChildWithServiceTaskChild(
    alloc: std.mem.Allocator,
    def_store: *DefinitionStore,
    parent_name: []const u8,
    child_name: []const u8,
    child_svc_id: []const u8,
) !struct { parent: Definition, child: Definition } {
    var created_by: [16]u8 = undefined;
    helpers.fillRandom(&created_by);

    var child_attrs_buf: [192]u8 = undefined;
    const child_svc_attrs = std.fmt.bufPrint(
        &child_attrs_buf,
        "{{\"service_id\":\"{s}\",\"capabilities\":[\"service:call:{s}\"],\"method\":\"POST\",\"timeout_ms\":5000,\"retry_limit\":1}}",
        .{ child_svc_id, child_svc_id },
    ) catch unreachable;

    const child_nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "CT", .node_type = .SERVICE_TASK, .label = "Child Service", .attributes = child_svc_attrs },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
    };
    const child_edges = [_]GraphEdge{
        .{ .id = "ce1", .source = "S", .target = "CT", .condition = null, .is_default = false },
        .{ .id = "ce2", .source = "CT", .target = "E", .condition = null, .is_default = false },
    };

    const child_draft = try def_store.create(alloc, CreateParams{
        .name = child_name,
        .version = "1.0",
        .description = null,
        .graph = DefinitionGraph{ .nodes = &child_nodes, .edges = &child_edges },
        .created_by = created_by,
    });
    const child_active = try def_store.activate(alloc, child_draft.id);
    freeDefinition(alloc, child_draft);

    const child_id_hex = try uuidToHexStr(alloc, child_active.id);
    defer alloc.free(child_id_hex);

    const parent_attrs = try std.fmt.allocPrint(alloc, "{{\"child_definition_id\":\"{s}\"}}", .{child_id_hex});
    defer alloc.free(parent_attrs);

    // TEST-FIXTURE FIX (flagged in this handoff's result, not silently
    // applied): this file's own header comment/TC-PIN-04-03 doc comment and
    // tests/specs/PIN-04.md's "Given" both state the parent and child
    // SERVICE_TASK nodes reference the SAME service_id -- but this fixture,
    // as originally written by TEST-DESIGNER, gave the PARENT graph no
    // SERVICE_TASK node at all (only START/HUMAN_TASK/SUB_PROCESS/END), so
    // PinResolver.resolve() (which derives catalog_entry pins solely by
    // scanning SERVICE_TASK nodes anywhere in the graph, independent of
    // position/reachability -- src/engine/pin_resolver.zig resolve() Step
    // 2/3) never produced a shared_svc_id pin on the PARENT to inherit from
    // -- queryPinnedResolvedId(parent_hex, shared_svc_id) returned
    // error.NotFound for BOTH TC-PIN-04-03 and TC-PIN-04-04, confirmed via
    // debug instrumentation (payload dump showed pinned_versions containing
    // only the always-present variable_schema pin, zero catalog_entry
    // entries).
    //
    // Adding a PARENT-side SERVICE_TASK node (PS) for shared_svc_id makes the
    // fixture match its own documented intent: the parent resolves and pins
    // shared_svc_id at instance-CREATE time (resolve() scans the whole graph
    // up front, regardless of node position/reachability), which is the
    // precondition AC2/AC3 require to be testable at all. PS must NOT
    // actually be entered by any token during either create()'s initial
    // transition OR completeTask()'s cascade: confirmed by reading both in
    // full that a SERVICE_TASK with no registered plugin handler
    // (src/engine/instance.zig processServiceTaskRuntimeInTx(), the
    // no-plugin branch) falls through to a REAL outbound HTTP call via
    // service_task_mod.executeHttpRequest() against service_catalog's
    // endpoint_url -- not viable in this test environment and forbidden by
    // this repo's "no external network calls" rule regardless. PS is
    // therefore wired as the FALSE branch of an EXCLUSIVE_GATEWAY (GW)
    // inserted between PT and SP: the TRUE/default branch (GW -> SP,
    // unconditioned edge, matches EXCLUSIVE_GATEWAY's documented
    // first-true-condition-wins behavior against a graph with only one
    // conditionless edge) is the ONLY one ever taken, so PT -> GW -> SP is
    // functionally identical to the original PT -> SP edge; the dead branch
    // (GW -> PS, condition "false") satisfies graph_mod.validateGraph()'s
    // CHK-04 "every non-START/END node needs both incoming and outgoing
    // edges" rule for PS via PS -> E2 (a second END node) without PS ever
    // being reached at runtime. This is a test-fixture correction, not an
    // implementation work-around -- src/engine/instance.zig's inheritance
    // logic (createInternal() Step d.6) is unaffected by this edit.
    const parent_svc_attrs = try std.fmt.allocPrint(
        alloc,
        "{{\"service_id\":\"{s}\",\"capabilities\":[\"service:call:{s}\"],\"method\":\"POST\",\"timeout_ms\":5000,\"retry_limit\":1}}",
        .{ child_svc_id, child_svc_id },
    );
    defer alloc.free(parent_svc_attrs);

    const parent_nodes = [_]GraphNode{
        .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "PT", .node_type = .HUMAN_TASK, .label = "Parent Task", .attributes = "{\"role\":\"tester\",\"assignee_type\":\"USER\",\"assignee_ref\":\"tester\"}" },
        .{ .id = "GW", .node_type = .EXCLUSIVE_GATEWAY, .label = "Gateway", .attributes = null },
        .{ .id = "PS", .node_type = .SERVICE_TASK, .label = "Parent Service (dead branch, pin-resolution only)", .attributes = parent_svc_attrs },
        .{ .id = "SP", .node_type = .SUB_PROCESS, .label = "Sub", .attributes = parent_attrs },
        .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
        .{ .id = "E2", .node_type = .END, .label = null, .attributes = null },
    };
    const parent_edges = [_]GraphEdge{
        .{ .id = "pe1", .source = "S", .target = "PT", .condition = null, .is_default = false },
        .{ .id = "pe1b", .source = "PT", .target = "GW", .condition = null, .is_default = false },
        // GW's edge selection (src/engine/transition.zig EXCLUSIVE_GATEWAY
        // case): non-default edges are only candidates when their condition
        // evaluates true; is_default=true is the fallback taken when no
        // non-default edge matches. pe2 -> SP is marked is_default=true so it
        // is ALWAYS chosen (SP is the only edge whose condition could ever be
        // true, and it has none) -- pe2b -> PS's "false" condition never
        // matches, so PS is provably never entered at runtime.
        .{ .id = "pe2", .source = "GW", .target = "SP", .condition = null, .is_default = true },
        .{ .id = "pe2b", .source = "GW", .target = "PS", .condition = "false", .is_default = false },
        .{ .id = "pe2c", .source = "PS", .target = "E2", .condition = null, .is_default = false },
        .{ .id = "pe3", .source = "SP", .target = "E", .condition = null, .is_default = false },
    };

    const parent_draft = try def_store.create(alloc, CreateParams{
        .name = parent_name,
        .version = "1.0",
        .description = null,
        .graph = DefinitionGraph{ .nodes = &parent_nodes, .edges = &parent_edges },
        .created_by = created_by,
    });
    const parent_active = try def_store.activate(alloc, parent_draft.id);
    freeDefinition(alloc, parent_draft);

    return .{ .parent = parent_active, .child = child_active };
}

test "TC-PIN-04-03: sub-process child inherits the parent's pin for a ref both share, tagged source=inherited" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // The SAME service_id is used by BOTH parent and child SERVICE_TASK
    // nodes — the parent's pin for it must be inherited by the child
    // (AC2), tagged source=inherited, per the design's merge semantics.
    var id_buf: [8]u8 = undefined;
    const shared_svc_id = try std.fmt.allocPrint(alloc, "svc-pin04-03-{s}", .{randomId(&id_buf)});
    defer alloc.free(shared_svc_id);
    try insertGlobalServiceViaPool(&pool, shared_svc_id);
    defer deleteServiceCatalogEntry(&pool, shared_svc_id);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const parent_name = "TC-PIN-04-03 Parent";
    const child_name = "TC-PIN-04-03 Child";
    defer cleanupDefinitionByName(&pool, parent_name);
    defer cleanupDefinitionByName(&pool, child_name);

    const defs = try setupParentChildWithServiceTaskChild(alloc, &def_store, parent_name, child_name, shared_svc_id);
    defer freeDefinition(alloc, defs.parent);
    defer freeDefinition(alloc, defs.child);

    var snap_store = SnapshotStore{ .pool = &pool };
    var task_store = TaskStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const parent_instance = try inst_store.create(alloc, defs.parent.id, null, "{}");
    defer freeInstance(alloc, parent_instance);
    const parent_hex = try uuidToHexStr(alloc, parent_instance.instance_id);
    defer alloc.free(parent_hex);
    defer cleanupInstanceAll(&pool, parent_hex);

    // Publish a NEWER catalog version AFTER the parent started but BEFORE
    // the child starts — the parent's already-resolved pin is the fixed
    // point AC2 says the child must inherit, not a fresh re-resolution.
    try publishNewerCatalogVersion(&pool, shared_svc_id);

    const parent_task_id = try queryPendingTaskId(alloc, &pool, parent_hex);
    _ = try inst_store.completeTask(alloc, &task_store, parent_task_id, "{}");

    const child_hex = try queryChildInstanceIdHex(alloc, &pool, parent_hex);
    defer alloc.free(child_hex);
    defer cleanupInstanceAll(&pool, child_hex);

    const parent_resolved_id = try queryPinnedResolvedId(alloc, &pool, parent_hex, shared_svc_id);
    defer alloc.free(parent_resolved_id);

    const child_payload_text = try queryStartedPayloadText(alloc, &pool, child_hex);
    defer alloc.free(child_payload_text);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, child_payload_text, .{});
    defer parsed.deinit();
    const pv = parsed.value.object.get("pinned_versions") orelse return error.MissingPinnedVersions;

    var child_entry: ?std.json.Value = null;
    for (pv.array.items) |item| {
        const kind = item.object.get("kind").?.string;
        if (!std.mem.eql(u8, kind, "catalog_entry")) continue;
        const ref = item.object.get("ref").?.string;
        if (!std.mem.eql(u8, ref, shared_svc_id)) continue;
        child_entry = item;
    }
    try std.testing.expect(child_entry != null);

    // AC2: the child's entry for the SHARED ref carries the PARENT's
    // version and source=inherited.
    const child_source = child_entry.?.object.get("source").?.string;
    try std.testing.expectEqualStrings("inherited", child_source);
    const child_resolved_id = child_entry.?.object.get("resolved_id").?.string;
    try std.testing.expectEqualStrings(parent_resolved_id, child_resolved_id);
}

test "TC-PIN-04-04: a child ref resolving to a version differing from the inherited pin records the conflict in the child's INSTANCE_STARTED payload" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var id_buf: [8]u8 = undefined;
    const shared_svc_id = try std.fmt.allocPrint(alloc, "svc-pin04-04-{s}", .{randomId(&id_buf)});
    defer alloc.free(shared_svc_id);
    try insertGlobalServiceViaPool(&pool, shared_svc_id);
    defer deleteServiceCatalogEntry(&pool, shared_svc_id);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const parent_name = "TC-PIN-04-04 Parent";
    const child_name = "TC-PIN-04-04 Child";
    defer cleanupDefinitionByName(&pool, parent_name);
    defer cleanupDefinitionByName(&pool, child_name);

    const defs = try setupParentChildWithServiceTaskChild(alloc, &def_store, parent_name, child_name, shared_svc_id);
    defer freeDefinition(alloc, defs.parent);
    defer freeDefinition(alloc, defs.child);

    var snap_store = SnapshotStore{ .pool = &pool };
    var task_store = TaskStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const parent_instance = try inst_store.create(alloc, defs.parent.id, null, "{}");
    defer freeInstance(alloc, parent_instance);
    const parent_hex = try uuidToHexStr(alloc, parent_instance.instance_id);
    defer alloc.free(parent_hex);
    defer cleanupInstanceAll(&pool, parent_hex);

    const parent_resolved_id_at_start = try queryPinnedResolvedId(alloc, &pool, parent_hex, shared_svc_id);
    defer alloc.free(parent_resolved_id_at_start);

    // Publish a NEWER catalog version between parent-start and child-start
    // so the CHILD's own independent resolution (were it not overridden by
    // inheritance) would resolve a DIFFERENT resolved_id than the parent's
    // already-fixed pin — the conflict condition AC3 describes.
    try publishNewerCatalogVersion(&pool, shared_svc_id);

    const parent_task_id = try queryPendingTaskId(alloc, &pool, parent_hex);
    _ = try inst_store.completeTask(alloc, &task_store, parent_task_id, "{}");

    const child_hex = try queryChildInstanceIdHex(alloc, &pool, parent_hex);
    defer alloc.free(child_hex);
    defer cleanupInstanceAll(&pool, child_hex);

    const child_payload_text = try queryStartedPayloadText(alloc, &pool, child_hex);
    defer alloc.free(child_payload_text);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, child_payload_text, .{});
    defer parsed.deinit();

    // AC3: the conflict is recorded in the child's OWN INSTANCE_STARTED
    // payload (design's Open questions §2 proposes a
    // "pin_inheritance_conflicts" sibling array — this test asserts the
    // AC's observable text: a conflict record exists naming both versions).
    const conflicts = parsed.value.object.get("pin_inheritance_conflicts");
    try std.testing.expect(conflicts != null);
    try std.testing.expect(conflicts.?.array.items.len >= 1);

    var found_conflict = false;
    for (conflicts.?.array.items) |c| {
        const ref = c.object.get("ref") orelse continue;
        if (!std.mem.eql(u8, ref.string, shared_svc_id)) continue;
        found_conflict = true;
        const parent_version = c.object.get("parent_version") orelse return error.MissingParentVersion;
        try std.testing.expect(parent_version.string.len > 0);
    }
    try std.testing.expect(found_conflict);
}

// ---------------------------------------------------------------------------
// TC-PIN-04-05: GET /api/v1/instances/{id}/pins returns the effective set
// with each entry's source event id
// ---------------------------------------------------------------------------

test "TC-PIN-04-05: GET .../pins returns the effective pin set with a source_event_id per entry" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(alloc, "svc-pin04-05-{s}", .{randomId(&id_buf)});
    defer alloc.free(svc_id);
    try insertGlobalServiceViaPool(&pool, svc_id);
    defer deleteServiceCatalogEntry(&pool, svc_id);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-PIN-04-05 Process";
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

    const result = instance_routes.handleGetPins(&inst_store, alloc, inst_hex);
    defer alloc.free(result.body);
    try std.testing.expectEqual(@as(u16, 200), result.status_code);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, result.body, .{});
    defer parsed.deinit();
    const pins = parsed.value.object.get("pins") orelse return error.MissingPins;
    try std.testing.expect(pins.array.items.len >= 1);

    for (pins.array.items) |p| {
        const source_event_id = p.object.get("source_event_id") orelse return error.MissingSourceEventId;
        try std.testing.expect(source_event_id.string.len > 0);
        // Must be the INSTANCE_STARTED event id (no rebind has happened yet).
        _ = p.object.get("kind") orelse return error.MissingKind;
        _ = p.object.get("ref") orelse return error.MissingRef;
        _ = p.object.get("resolved_id") orelse return error.MissingResolvedId;
        _ = p.object.get("version") orelse return error.MissingVersion;
    }
}
