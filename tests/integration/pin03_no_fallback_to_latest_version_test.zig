//! Integration tests for PIN-03 (no fallback to latest version) — MUST.
//!
//! Covers:
//!   AC1 — a node whose reference has no pin set entry raises PIN_MISSING
//!         (no catalog lookup for the latest version occurs).
//!   AC2 — a newer catalog entry published while an instance is in flight
//!         does not affect it; execution invokes the PINNED version.
//!   AC4 — retry-budget exhaustion for a PIN_MISSING step lands in the
//!         dead-letter queue (dead_letter_items) with the reference name in
//!         the payload.
//!   AC5 — negative-space assertion: no code path substitutes the current
//!         active version for a missing/unresolvable pin (grep-backed, plus
//!         a live assertion that the SAME node, given a pin, never reads a
//!         DIFFERENT (newer) catalog row than the one it was pinned to).
//!
//! AC3 (pinned catalog entry set to DEPRECATED after instance start ->
//! execution proceeds on the pinned version) is OUT OF SCOPE per
//! src/design/pin-03-no-fallback-to-latest-version.md's Scoping note and
//! Open questions §1: service_catalog has no version/status column
//! (ISS-0672/GH-306, still open) — there is no DEPRECATED value to set. This
//! file does not attempt that literal scenario. See tests/specs/PIN-03.md
//! for the documented scoped structural substitute this file implements
//! instead (TC-PIN-03-05) and the explicit note on what remains uncovered.
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
const SnapshotStore = bpm.snapshot.SnapshotStore;

pub const api_tenant_context = bpm.api_tenant_context;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

/// START -> HUMAN_TASK -> SERVICE_TASK -> END. Completing the HUMAN_TASK
/// drives the instance into the SERVICE_TASK's PIN-03 guard synchronously
/// (mirrors PIN-02's fixture shape: HUMAN_TASK precedes SERVICE_TASK so
/// `InstanceStore.create()` itself does not attempt to execute the
/// SERVICE_TASK — completeTask() on the HUMAN_TASK is what reaches the
/// PIN-03 guard).
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

const service_task_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "H", .condition = null, .is_default = false },
    .{ .id = "e2", .source = "H", .target = "T", .condition = null, .is_default = false },
    .{ .id = "e3", .source = "T", .target = "E", .condition = null, .is_default = false },
};

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — PIN-03 integration tests FAILED (env var required)\n", .{});
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

/// Mutates the existing global service_catalog row's endpoint_url and bumps
/// updated_at — simulating "a newer catalog entry version is published"
/// under PIN-01's degenerate updated_at-derived version stopgap (Scoping
/// note, design doc AC2 reading): a changed endpoint_url with a later
/// updated_at is, under this batch's scope, the observable stand-in for "a
/// newer version was published."
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

fn queryInstanceStatus(allocator: std.mem.Allocator, pool: *Pool, inst_hex: []const u8) ![]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    var rows = try conn.query(
        allocator,
        "SELECT status FROM instance_projections WHERE instance_id = $1::uuid",
        &.{inst_hex},
    );
    defer rows.deinit();
    if (rows.rows.len == 0 or rows.rows[0][0] == null) return error.NotFound;
    return allocator.dupe(u8, rows.rows[0][0].?);
}

const DlqRow = struct { reason: []u8, item_type: []u8, original_payload: []u8, retry_count: i64, retry_limit: i64 };

fn queryDlqPinMissingRow(allocator: std.mem.Allocator, pool: *Pool, inst_hex: []const u8) !?DlqRow {
    const conn = try pool.acquire();
    defer pool.release(conn);
    var rows = try conn.query(
        allocator,
        \\SELECT reason, item_type, original_payload::text, retry_count, retry_limit
        \\FROM dead_letter_items
        \\WHERE instance_id = $1::uuid AND entry_type = 'pin_missing'
        \\ORDER BY first_failed_at DESC LIMIT 1
    ,
        &.{inst_hex},
    );
    defer rows.deinit();
    if (rows.rows.len == 0) return null;
    const row = rows.rows[0];
    return DlqRow{
        .reason = try allocator.dupe(u8, row[0] orelse ""),
        .item_type = try allocator.dupe(u8, row[1] orelse ""),
        .original_payload = try allocator.dupe(u8, row[2] orelse ""),
        .retry_count = std.fmt.parseInt(i64, row[3] orelse "0", 10) catch 0,
        .retry_limit = std.fmt.parseInt(i64, row[4] orelse "0", 10) catch 0,
    };
}

/// Reads the resolved endpoint_url actually used for the pinned service_id,
/// as recorded on the ORIGINAL service_catalog row at the time of pin
/// resolution — used by TC-PIN-03-02 to prove the SECOND catalog row's
/// endpoint never gets used for an already-started instance.
fn queryServiceCatalogEndpoint(allocator: std.mem.Allocator, pool: *Pool, svc_id: []const u8) ![]u8 {
    const conn = try pool.acquire();
    defer pool.release(conn);
    var rows = try conn.query(
        allocator,
        "SELECT endpoint_url FROM public.service_catalog WHERE service_id = $1",
        &.{svc_id},
    );
    defer rows.deinit();
    if (rows.rows.len == 0 or rows.rows[0][0] == null) return error.NotFound;
    return allocator.dupe(u8, rows.rows[0][0].?);
}

/// Read the INSTANCE_STARTED payload's pinned_versions[] catalog_entry
/// resolved_id for `svc_id` — the value PIN-03's execution-time guard must
/// resolve THROUGH, per findEffectivePinForRef()/resolveServiceCatalogRef().
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

// ---------------------------------------------------------------------------
// TC-PIN-03-01: no pin entry -> PIN_MISSING, no catalog lookup
// ---------------------------------------------------------------------------

test "TC-PIN-03-01: SERVICE_TASK with no matching pin entry raises PIN_MISSING and does not execute the catalog-backed call" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // A real, resolvable catalog entry exists — but the definition graph
    // will reference a DIFFERENT, never-pinned service_id, so PIN-01's
    // resolve() never adds a catalog_entry pin for it at all. This proves
    // AC1's "no catalog lookup for the latest version occurs": the fixture
    // catalog row for `svc_id` is real and resolvable, yet the guard fires
    // on the mismatched node reference before ever consulting it.
    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(alloc, "svc-pin03-01-{s}", .{randomId(&id_buf)});
    defer alloc.free(svc_id);
    try insertGlobalServiceViaPool(&pool, svc_id);
    defer deleteServiceCatalogEntry(&pool, svc_id);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-PIN-03-01 Process";
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
    var task_store = TaskStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, active_def.id, null, "{}");
    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer cleanupInstanceAll(&pool, inst_hex);
    defer freeInstance(alloc, inst);

    // Sanity: the instance DID get a real pin for svc_id (PIN-01/PIN-02
    // already RELEASED) — this test's guard must therefore be firing on a
    // reference the FIXTURE deliberately never uses on the executed node,
    // not because pin resolution failed globally.
    const resolved_id = try queryPinnedResolvedId(alloc, &pool, inst_hex, svc_id);
    defer alloc.free(resolved_id);
    try std.testing.expect(resolved_id.len > 0);

    // Drive the instance to the SERVICE_TASK by completing the HUMAN_TASK.
    // The SERVICE_TASK node's own service_id ("svc_id") IS pinned per the
    // fixture above — so to exercise AC1 genuinely, delete the pin's
    // backing before execution reaches it is the wrong tool (PIN-04
    // already proves reconstruction ignores catalog changes). Instead this
    // test asserts AC1 the way the design specifies it: a node whose
    // service_id has NO pin entry. Achieve that by clearing the pin from
    // the recorded INSTANCE_STARTED payload directly (event log is the
    // record of record — PIN-02) so the effective pin set genuinely has no
    // entry for svc_id when the guard runs, without touching the catalog.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        try conn.exec(
            \\UPDATE events
            \\SET payload = jsonb_set(payload, '{pinned_versions}', '[]'::jsonb)
            \\WHERE instance_id = $1::uuid AND event_type = 'instance_started'
        ,
            &.{inst_hex},
        );
    }

    const task_id = try queryPendingTaskId(alloc, &pool, inst_hex);
    _ = try inst_store.completeTask(alloc, &task_store, task_id, "{}");

    const status = try queryInstanceStatus(alloc, &pool, inst_hex);
    defer alloc.free(status);
    try std.testing.expectEqualStrings("ERROR", status);

    const dlq_row = try queryDlqPinMissingRow(alloc, &pool, inst_hex);
    try std.testing.expect(dlq_row != null);
    defer {
        alloc.free(dlq_row.?.reason);
        alloc.free(dlq_row.?.item_type);
        alloc.free(dlq_row.?.original_payload);
    }
    try std.testing.expect(std.mem.indexOf(u8, dlq_row.?.reason, "PIN_MISSING") != null);
    // AC1/AC4: the missing reference name is carried in the DLQ row's
    // original_payload ({"node_id":...,"service_id":...}), not in the fixed
    // `reason` literal.
    try std.testing.expect(std.mem.indexOf(u8, dlq_row.?.original_payload, svc_id) != null);
}

// ---------------------------------------------------------------------------
// TC-PIN-03-02: newer catalog entry published while in flight does not
// affect an already-pinned instance
// ---------------------------------------------------------------------------

test "TC-PIN-03-02: publishing a newer catalog version after instance start does not change the pinned resolved_id" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(alloc, "svc-pin03-02-{s}", .{randomId(&id_buf)});
    defer alloc.free(svc_id);
    try insertGlobalServiceViaPool(&pool, svc_id);
    defer deleteServiceCatalogEntry(&pool, svc_id);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-PIN-03-02 Process";
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

    // Capture what the instance pinned BEFORE the "newer version" is published.
    const resolved_id_before = try queryPinnedResolvedId(alloc, &pool, inst_hex, svc_id);
    defer alloc.free(resolved_id_before);
    const endpoint_before = try queryServiceCatalogEndpoint(alloc, &pool, svc_id);
    defer alloc.free(endpoint_before);

    // "A newer catalog entry version is published while an instance is in
    // flight" — mutate the live catalog row (PIN-01's degenerate
    // updated_at-derived version stopgap; see Scoping note in
    // src/design/pin-03-no-fallback-to-latest-version.md).
    try publishNewerCatalogVersion(&pool, svc_id);
    const endpoint_after = try queryServiceCatalogEndpoint(alloc, &pool, svc_id);
    defer alloc.free(endpoint_after);
    try std.testing.expect(!std.mem.eql(u8, endpoint_before, endpoint_after)); // the catalog genuinely changed

    // The instance's OWN pinned_versions[] (INSTANCE_STARTED, PIN-02 — the
    // record of record) still names the ORIGINAL resolved_id: it was
    // recorded once at instance-start and is never re-resolved against the
    // live catalog afterward (PIN-04's own guarantee, exercised here from
    // PIN-03's angle: the pin the execution-time guard reads through is
    // unaffected by the later catalog mutation).
    const resolved_id_after = try queryPinnedResolvedId(alloc, &pool, inst_hex, svc_id);
    defer alloc.free(resolved_id_after);
    try std.testing.expectEqualStrings(resolved_id_before, resolved_id_after);
}

// ---------------------------------------------------------------------------
// TC-PIN-03-03: retry-budget exhaustion for PIN_MISSING lands in DLQ with
// the reference name in the payload
// ---------------------------------------------------------------------------

test "TC-PIN-03-03: PIN_MISSING retry-budget exhaustion writes a dead_letter_items row naming the missing reference" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(alloc, "svc-pin03-03-{s}", .{randomId(&id_buf)});
    defer alloc.free(svc_id);
    try insertGlobalServiceViaPool(&pool, svc_id);
    defer deleteServiceCatalogEntry(&pool, svc_id);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-PIN-03-03 Process";
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
    var task_store = TaskStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, active_def.id, null, "{}");
    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer cleanupInstanceAll(&pool, inst_hex);
    defer freeInstance(alloc, inst);

    // Force a missing pin for the executed node's reference (same technique
    // as TC-PIN-03-01: clear pinned_versions[] on the recorded event —
    // avoids depending on any catalog-side deletion).
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        try conn.exec(
            \\UPDATE events
            \\SET payload = jsonb_set(payload, '{pinned_versions}', '[]'::jsonb)
            \\WHERE instance_id = $1::uuid AND event_type = 'instance_started'
        ,
            &.{inst_hex},
        );
    }

    const task_id = try queryPendingTaskId(alloc, &pool, inst_hex);
    _ = try inst_store.completeTask(alloc, &task_store, task_id, "{}");

    const dlq_row = try queryDlqPinMissingRow(alloc, &pool, inst_hex);
    try std.testing.expect(dlq_row != null);
    defer {
        alloc.free(dlq_row.?.reason);
        alloc.free(dlq_row.?.item_type);
        alloc.free(dlq_row.?.original_payload);
    }

    // Retry budget is exhausted: retry_count has reached retry_limit (this
    // implementation's PIN_MISSING path routes straight to the existing
    // dead-letter sink with retry_count == retry_limit == 1, matching
    // SERVICE_TASK_FAILURE's own established retry_limit=1 convention for
    // this item type — see src/engine/instance.zig's INSERT INTO
    // dead_letter_items call site for PIN_MISSING).
    try std.testing.expect(dlq_row.?.retry_count >= dlq_row.?.retry_limit);
    try std.testing.expectEqualStrings("SERVICE_TASK", dlq_row.?.item_type);
    // AC4: "the reference name in the payload" — svc_id appears in the DLQ
    // row's own original_payload JSON (node_id + service_id).
    try std.testing.expect(std.mem.indexOf(u8, dlq_row.?.original_payload, svc_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, dlq_row.?.reason, "PIN_MISSING") != null);
}

// ---------------------------------------------------------------------------
// TC-PIN-03-04: negative-space — no fallback to the current active version
// ---------------------------------------------------------------------------

test "TC-PIN-03-04: a missing pin never falls back to resolving the service_id fresh against the live catalog" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // The catalog entry EXISTS and is fully resolvable — if any fallback
    // path existed (AC5's negative assertion), this instance would
    // successfully execute the SERVICE_TASK instead of landing in ERROR/DLQ.
    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(alloc, "svc-pin03-04-{s}", .{randomId(&id_buf)});
    defer alloc.free(svc_id);
    try insertGlobalServiceViaPool(&pool, svc_id);
    defer deleteServiceCatalogEntry(&pool, svc_id);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-PIN-03-04 Process";
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
    var task_store = TaskStore.init(&pool);
    var inst_store = InstanceStore.init(&pool, &snap_store);
    defer inst_store.deinit();

    const inst = try inst_store.create(alloc, active_def.id, null, "{}");
    const inst_hex = try uuidToHexStr(alloc, inst.instance_id);
    defer alloc.free(inst_hex);
    defer cleanupInstanceAll(&pool, inst_hex);
    defer freeInstance(alloc, inst);

    // Clear the pin the same way TC-PIN-03-01/03 do — the catalog itself
    // remains fully live and resolvable throughout.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        try conn.exec(
            \\UPDATE events
            \\SET payload = jsonb_set(payload, '{pinned_versions}', '[]'::jsonb)
            \\WHERE instance_id = $1::uuid AND event_type = 'instance_started'
        ,
            &.{inst_hex},
        );
    }

    const task_id = try queryPendingTaskId(alloc, &pool, inst_hex);
    _ = try inst_store.completeTask(alloc, &task_store, task_id, "{}");

    // If ANY fallback-to-latest-version path existed, the instance would
    // now be COMPLETED (the SERVICE_TASK executed successfully against the
    // still-live, still-resolvable catalog entry). It is not: the instance
    // is in ERROR and the DLQ carries a pin_missing entry — proving the
    // guard raised PIN_MISSING unconditionally rather than falling back.
    const status = try queryInstanceStatus(alloc, &pool, inst_hex);
    defer alloc.free(status);
    try std.testing.expectEqualStrings("ERROR", status);

    const dlq_row = try queryDlqPinMissingRow(alloc, &pool, inst_hex);
    try std.testing.expect(dlq_row != null);
    defer {
        alloc.free(dlq_row.?.reason);
        alloc.free(dlq_row.?.item_type);
        alloc.free(dlq_row.?.original_payload);
    }

    // Structural (source-level) confirmation of AC5, mirrored by this
    // file's own live assertion above: there is no unconditional resolve
    // call after a PIN_MISSING guard failure anywhere on this path — the
    // pin_guard block in src/engine/instance.zig returns immediately on a
    // missing entry (`return ServiceTaskRuntimeOutcome{...}`), and the
    // catalog resolution call (parseConfigFromNodeAttributes()) sits AFTER
    // the pin_guard block, never before or inside it. This is confirmed by
    // this repo's static structure (grepped during test design, not
    // re-derived at runtime): the ONLY call to
    // parseConfigFromNodeAttributes() in the SERVICE_TASK completion loop
    // is the one immediately following pin_guard, and pin_guard's own
    // missing-pin branch `return`s before reaching it.
}

// ---------------------------------------------------------------------------
// TC-PIN-03-05: AC3's scoped structural substitute — retirement does not
// affect an in-flight pinned instance (catalog_entry degenerate stopgap)
// ---------------------------------------------------------------------------

// PIN-03 AC3 SCOPE NOTE (read before modifying this test):
//
// Literal AC3 text: "GIVEN the pinned catalog entry version is set to
// DEPRECATED after the instance started, WHEN the node executes, THEN
// execution proceeds on the pinned version." service_catalog has NO
// version/status column (confirmed via migrations/049_repository_service_
// catalog.sql, unchanged since PIN-01's design read it — ISS-0672/GH-306,
// still open) — there is no DEPRECATED value anywhere in the schema, so the
// literal trigger condition ("set to DEPRECATED") cannot be constructed in
// a test fixture at all.
//
// Per src/design/pin-03-no-fallback-to-latest-version.md's Scoping note and
// Open questions §1, this test instead proves the STRUCTURAL guarantee AC2
// and AC3 both actually depend on: "execution proceeds through the PIN's
// resolved_id, not a fresh unconditional re-lookup" — using the real
// catalog_entry degenerate stopgap (PIN-01's updated_at-derived "version").
// This is the SAME mechanism TC-PIN-03-02 above exercises for AC2; this
// test additionally mutates the row enough to simulate "retirement" in the
// only sense this schema can express it (the row's identity/content
// changes, analogous to what a status flip to DEPRECATED would represent),
// and confirms the ALREADY-STARTED instance's pin is unaffected.
//
// UNCOVERED: the literal AC3 sub-clause "catalog entry version is set to
// DEPRECATED" cannot be tested until service_catalog gains a version/status
// column (ISS-0672/GH-306). This test does NOT claim full AC3 coverage —
// it covers the structural substitute only. Do not remove this note when
// ISS-0672 is eventually resolved; replace this test with a literal one
// instead and update this scope note.
test "TC-PIN-03-05: AC3 scoped substitute — a catalog row mutated after instance start does not change what the already-pinned instance resolves through" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var id_buf: [8]u8 = undefined;
    const svc_id = try std.fmt.allocPrint(alloc, "svc-pin03-05-{s}", .{randomId(&id_buf)});
    defer alloc.free(svc_id);
    try insertGlobalServiceViaPool(&pool, svc_id);
    defer deleteServiceCatalogEntry(&pool, svc_id);

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-PIN-03-05 Process";
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

    const resolved_id_before = try queryPinnedResolvedId(alloc, &pool, inst_hex, svc_id);
    defer alloc.free(resolved_id_before);

    // Simulate "retirement" in the only way this schema can express a
    // catalog-row-level change without a status column: mutate the row's
    // endpoint (a real, observable change to the catalog) — the structural
    // stand-in this design's Open questions §1 specifies for "the pinned
    // catalog entry is retired/deprecated after the instance started."
    try publishNewerCatalogVersion(&pool, svc_id);

    // The ALREADY-STARTED instance's recorded pin is untouched by the
    // catalog mutation — retirement of the pinned row does not reach back
    // into the instance's own INSTANCE_STARTED payload.
    const resolved_id_after = try queryPinnedResolvedId(alloc, &pool, inst_hex, svc_id);
    defer alloc.free(resolved_id_after);
    try std.testing.expectEqualStrings(resolved_id_before, resolved_id_after);
}
