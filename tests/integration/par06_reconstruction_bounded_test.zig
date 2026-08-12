//! Integration tests for PAR-06's BEHAVIOURAL acceptance criteria (window
//! maintenance, bounded reconstruction, partition pruning, repair-on-NULL,
//! archived-instance merge) — as distinct from
//! par06_instance_projections_event_window_test.zig, which covers only the
//! migration's schema slice (columns + index) per that file's own header.
//!
//! Implementation note (ISS-0675 / GH-716, filed by BACKEND-DEV before this
//! step): src/event_store/store.zig's Store.reconstructBounded() is DEAD
//! CODE -- not called anywhere in src/ or tests/. The actually-wired PAR-06
//! reconstruction entry point is src/engine/reconstruction.zig's
//! reconstructInstance(). Every test below exercises that live path, not the
//! unreferenced Store.reconstructBounded().
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
const Instance = bpm.engine.Instance;
const DefinitionStore = bpm.definition.Store;
const CreateParams = bpm.definition.CreateParams;
const DefinitionGraph = bpm.definition.DefinitionGraph;
const GraphNode = bpm.definition.GraphNode;
const GraphEdge = bpm.definition.GraphEdge;
const SnapshotStore = bpm.snapshot.SnapshotStore;
const Registry = bpm.registry.Registry;
const RegisterParams = bpm.registry.RegisterParams;
const Store = bpm.store.Store;
const AppendParams = bpm.store.AppendParams;
const reconstruction_mod = bpm.reconstruction;

pub const api_tenant_context = bpm.api_tenant_context;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const minimal_nodes = [_]GraphNode{
    .{ .id = "S", .node_type = .START, .label = null, .attributes = null },
    .{ .id = "T", .node_type = .HUMAN_TASK, .label = null, .attributes = "{\"role\":\"tester\"}" },
    .{ .id = "E", .node_type = .END, .label = null, .attributes = null },
};
const minimal_edges = [_]GraphEdge{
    .{ .id = "e1", .source = "S", .target = "T", .condition = null, .is_default = false },
    .{ .id = "e2", .source = "T", .target = "E", .condition = null, .is_default = false },
};
const minimal_graph = DefinitionGraph{ .nodes = &minimal_nodes, .edges = &minimal_edges };

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — skipping PAR-06 reconstruction test\n", .{});
            return error.SkipZigTest;
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

fn parseUuid(s: []const u8) ![16]u8 {
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

fn freeInstance(allocator: std.mem.Allocator, inst: Instance) void {
    if (inst.correlation_key) |ck| allocator.free(ck);
    allocator.free(inst.initial_variables);
    allocator.free(inst.definition_snapshot);
}

fn cleanupInstanceAll(pool: *Pool, inst_hex: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM instance_state_snapshots WHERE instance_id = $1::uuid", &.{inst_hex}) catch {};
    conn.exec("DELETE FROM events WHERE instance_id = $1::uuid", &.{inst_hex}) catch {};
    conn.exec("DELETE FROM events_archive WHERE instance_id = $1::uuid", &.{inst_hex}) catch {};
    conn.exec("DELETE FROM instance_definition_snapshots WHERE instance_id = $1::uuid", &.{inst_hex}) catch {};
    conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{inst_hex}) catch {};
    conn.exec("DELETE FROM instance_sequence WHERE instance_id = $1::uuid", &.{inst_hex}) catch {};
}

fn cleanupDefinitionByName(pool: *Pool, name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM process_definitions WHERE name = $1", &.{name}) catch {};
}

fn cleanupEventType(pool: *Pool, type_name: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM event_type_registry WHERE name = $1", &.{type_name}) catch {};
}

/// Read (first_event_at, last_event_at) as UTC microseconds; null if either column is NULL.
const Window = struct { first_us: ?i64, last_us: ?i64 };

fn readWindow(alloc: std.mem.Allocator, pool: *Pool, inst_hex: []const u8) !Window {
    const conn = try pool.acquire();
    defer pool.release(conn);
    var rows = try conn.query(
        alloc,
        \\SELECT (EXTRACT(EPOCH FROM first_event_at) * 1000000)::bigint,
        \\       (EXTRACT(EPOCH FROM last_event_at) * 1000000)::bigint
        \\FROM instance_projections WHERE instance_id = $1::uuid
    ,
        &.{inst_hex},
    );
    defer rows.deinit();
    if (rows.rows.len == 0) return Window{ .first_us = null, .last_us = null };
    const row = rows.rows[0];
    const first_us: ?i64 = if (row.len > 0 and row[0] != null) (std.fmt.parseInt(i64, row[0].?, 10) catch null) else null;
    const last_us: ?i64 = if (row.len > 1 and row[1] != null) (std.fmt.parseInt(i64, row[1].?, 10) catch null) else null;
    return Window{ .first_us = first_us, .last_us = last_us };
}

fn freeReconstState(alloc: std.mem.Allocator, state: bpm.transition.InstanceState) void {
    var s = state;
    for (s.tokens) |tok| {
        alloc.free(tok.node_id);
        alloc.free(tok.branch_id);
        if (tok.token_id) |t| alloc.free(t);
        if (tok.waiting_child_instance_id) |w| alloc.free(w);
    }
    alloc.free(s.tokens);
    reconstruction_mod.freeObjectMap(alloc, &s.variables);
    reconstruction_mod.freeObjectMap(alloc, &s.join_counters);
    for (s.pending_task_nodes) |n| alloc.free(n);
    alloc.free(s.pending_task_nodes);
    if (s.error_detail) |e| alloc.free(e);
    for (s.cancelled_branch_ids) |b| alloc.free(b);
    alloc.free(s.cancelled_branch_ids);
}

// ---------------------------------------------------------------------------
// TC-PAR-06-01: last_event_at advances in the same transaction as append
// ---------------------------------------------------------------------------

// KNOWN FAILING against current code — ISS-0677 / GH-719 (filed during this
// same handoff): InstanceStore.create()'s hand-rolled INSTANCE_STARTED
// insert never sets instance_projections.first_event_at/.last_event_at (only
// Store.append() does). This assertion on w1 (the window immediately after
// create()) is expected to fail until ISS-0677 is fixed — that is real,
// correct fail-first signal for PAR-06 AC4, not a defect in this test. Do
// NOT silence/skip this assertion to make the suite green; fix ISS-0677
// instead.
test "TC-PAR-06-01: Store.append advances last_event_at, first_event_at stays fixed via COALESCE" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-PAR-06-01 Process";
    var created_by: [16]u8 = undefined;
    helpers.fillRandom(&created_by);

    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
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

    // After INSTANCE_STARTED alone: first_event_at and last_event_at both set.
    const w1 = try readWindow(alloc, &pool, inst_hex);
    try std.testing.expect(w1.first_us != null);
    try std.testing.expect(w1.last_us != null);
    const first_after_start = w1.first_us.?;
    const last_after_start = w1.last_us.?;

    // Append a second event directly via Store.append() to the same instance.
    var registry = Registry.init(alloc, &pool);
    defer registry.deinit();
    const type_name = try std.fmt.allocPrint(alloc, "PAR06_TEST_EVENT_{s}", .{inst_hex[0..8]});
    defer alloc.free(type_name);
    _ = registry.registerType(alloc, RegisterParams{
        .name = type_name,
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};
    defer cleanupEventType(&pool, type_name);

    var store = Store.init(alloc, &pool, &registry);
    defer store.deinit();

    const idem_key = try std.fmt.allocPrint(alloc, "par06-01-{s}", .{inst_hex});
    defer alloc.free(idem_key);
    var append_result = try store.append(alloc, AppendParams{
        .instance_id = inst.instance_id,
        .event_type = type_name,
        .payload = "{}",
        .actor_id = h.newUuid(),
        .idempotency_key = idem_key,
        .metadata = null,
    });
    defer append_result.record.deinit(alloc);

    const w2 = try readWindow(alloc, &pool, inst_hex);
    try std.testing.expect(w2.first_us != null);
    try std.testing.expect(w2.last_us != null);

    // first_event_at is UNCHANGED (COALESCE — set once, on the first append).
    try std.testing.expectEqual(first_after_start, w2.first_us.?);
    // last_event_at ADVANCED (unconditionally overwritten on every append).
    try std.testing.expect(w2.last_us.? > last_after_start);
}

// ---------------------------------------------------------------------------
// TC-PAR-06-02: bounded reconstruction reads exactly the committed events
// ---------------------------------------------------------------------------

test "TC-PAR-06-02: reconstructInstance replays all committed events within the bounded window" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-PAR-06-02 Process";
    var created_by: [16]u8 = undefined;
    helpers.fillRandom(&created_by);

    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
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

    const reconst_state = try reconstruction_mod.reconstructInstance(
        alloc,
        &pool,
        &snap_store,
        inst.instance_id,
        false,
    );
    defer freeReconstState(alloc, reconst_state);

    // The instance started with a HUMAN_TASK as its first non-START node —
    // reconstruction must show it ACTIVE with a pending token, proving
    // INSTANCE_STARTED (the only committed event so far) was replayed.
    try std.testing.expectEqual(bpm.transition.InstanceStatus.ACTIVE, reconst_state.status);
    try std.testing.expect(reconst_state.tokens.len >= 1);
}

// ---------------------------------------------------------------------------
// TC-PAR-06-03: partition pruning — EXPLAIN shows exactly one partition scanned
// ---------------------------------------------------------------------------

test "TC-PAR-06-03: bounded query plan prunes to the instance's own month partition" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const conn = try pool.acquire();
    defer pool.release(conn);

    const inst_hex = try h.newUuidString(alloc);
    defer alloc.free(inst_hex);

    // A window comfortably inside the CURRENT month (guaranteed attached —
    // every fresh bpm_test provisioning attaches at least the current month
    // per PAR-02's proactive maintenance).
    var now_rows = try conn.query(alloc, "SELECT (EXTRACT(EPOCH FROM date_trunc('month', now())) * 1000000)::bigint", &.{});
    defer now_rows.deinit();
    const month_start_us = std.fmt.parseInt(i64, now_rows.rows[0][0] orelse "0", 10) catch 0;
    const window_start = month_start_us + 1_000_000; // 1s into the month
    const window_end = month_start_us + 2_000_000; // 2s into the month

    var start_buf: [24]u8 = undefined;
    var end_buf: [24]u8 = undefined;
    const start_text = std.fmt.bufPrint(&start_buf, "{d}", .{window_start}) catch unreachable;
    const end_text = std.fmt.bufPrint(&end_buf, "{d}", .{window_end}) catch unreachable;

    // Bounded form (matches PAR-06's exact query shape).
    var explain_bounded = try conn.query(
        alloc,
        \\EXPLAIN (FORMAT JSON) SELECT event_id FROM events
        \\WHERE instance_id = $1::uuid
        \\  AND created_at >= to_timestamp($2::bigint / 1000000.0)
        \\  AND created_at <  to_timestamp($3::bigint / 1000000.0)
    ,
        &.{ inst_hex, start_text, end_text },
    );
    defer explain_bounded.deinit();
    try std.testing.expect(explain_bounded.rows.len >= 1);
    const bounded_plan_json = explain_bounded.rows[0][0] orelse "";

    // Discriminating check (fail-first proof, per the spec's own note):
    // an UNBOUNDED form scans every attached partition. Count distinct
    // "events_" partition-name occurrences in each plan's raw JSON text as a
    // cheap proxy for "how many partitions does this plan reference" —
    // avoids a full JSON-tree walk while still being a real structural
    // signal (each scanned partition's own relation name appears once per
    // Scan node in EXPLAIN's JSON output).
    var explain_unbounded = try conn.query(
        alloc,
        "EXPLAIN (FORMAT JSON) SELECT event_id FROM events WHERE instance_id = $1::uuid",
        &.{inst_hex},
    );
    defer explain_unbounded.deinit();
    const unbounded_plan_json = explain_unbounded.rows[0][0] orelse "";

    const bounded_count = countPartitionMentions(bounded_plan_json);
    const unbounded_count = countPartitionMentions(unbounded_plan_json);

    // The bounded plan touches at most 1 partition; the unbounded plan
    // touches strictly more (proving pruning is real, not coincidental —
    // the platform has 3+ months of partitions attached per PAR-02's
    // proactive lead_months maintenance).
    try std.testing.expect(bounded_count <= 1);
    try std.testing.expect(unbounded_count > bounded_count);
}

fn countPartitionMentions(plan_json: []const u8) usize {
    // PostgreSQL's EXPLAIN (FORMAT JSON) always renders a space after the
    // colon ("Relation Name": "events_2026_08", not "Relation Name":"...") —
    // the marker below must match that exact rendering.
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, plan_json, idx, "\"Relation Name\": \"events_2")) |pos| {
        count += 1;
        idx = pos + 1;
    }
    return count;
}

// ---------------------------------------------------------------------------
// TC-PAR-06-04: ReconstructionWindowMissing repair path
// ---------------------------------------------------------------------------

test "TC-PAR-06-04: NULL window is transparently repaired by one scan during reconstruction" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-PAR-06-04 Process";
    var created_by: [16]u8 = undefined;
    helpers.fillRandom(&created_by);
    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
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

    // Simulate a pre-PAR-06 instance: force the window columns back to NULL
    // even though INSTANCE_STARTED already exists in `events`.
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        "UPDATE instance_projections SET first_event_at = NULL, last_event_at = NULL WHERE instance_id = $1::uuid",
        &.{inst_hex},
    );
    const w_before = try readWindow(alloc, &pool, inst_hex);
    try std.testing.expect(w_before.first_us == null);
    try std.testing.expect(w_before.last_us == null);

    // Reconstruction must succeed transparently (repair-and-retry is
    // internal, per the design's Open questions §4 and this codebase's
    // actual eventWindowForInstanceInTx() implementation).
    const reconst_state = try reconstruction_mod.reconstructInstance(
        alloc,
        &pool,
        &snap_store,
        inst.instance_id,
        false,
    );
    defer freeReconstState(alloc, reconst_state);
    try std.testing.expectEqual(bpm.transition.InstanceStatus.ACTIVE, reconst_state.status);

    // The projection row is repaired: both columns are now non-NULL.
    const w_after = try readWindow(alloc, &pool, inst_hex);
    try std.testing.expect(w_after.first_us != null);
    try std.testing.expect(w_after.last_us != null);
}

// ---------------------------------------------------------------------------
// TC-PAR-06-05: archived-instance merge
// ---------------------------------------------------------------------------

// KNOWN FAILING against current code — same root cause as TC-PAR-06-01
// (ISS-0677 / GH-719): the freshly-created instance's window is NULL
// immediately after InstanceStore.create() returns, so this test's manual
// last_event_at widen starts from a NULL baseline instead of
// INSTANCE_STARTED's real created_at, and the archived row can fall outside
// the window the (buggy) starting state produces. Expected to pass once
// ISS-0677 is fixed. Do NOT silence/skip; fix ISS-0677 instead.
test "TC-PAR-06-05: reconstruction merges events_archive rows within the bounded window" {
    const alloc = std.testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();

    const url = try testDbUrl(alloc);
    defer alloc.free(url);
    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var def_store = DefinitionStore.init(alloc, &pool);
    defer def_store.deinit();

    const name = "TC-PAR-06-05 Process";
    var created_by: [16]u8 = undefined;
    helpers.fillRandom(&created_by);
    const draft = try def_store.create(alloc, CreateParams{
        .name = name,
        .version = "1.0",
        .description = null,
        .graph = minimal_graph,
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

    const conn = try pool.acquire();
    defer pool.release(conn);

    // Manually insert a second "archived" event directly into events_archive
    // (simulating PAR-03 having already moved part of this instance's
    // lifetime), timestamped just after INSTANCE_STARTED but still inside
    // the current month (events_archive_<current month> is attached by
    // default — see the spec's own note). last_event_at is widened to cover
    // it so the bounded query's upper bound includes this row.
    const actor_hex = try h.newUuidString(alloc);
    defer alloc.free(actor_hex);
    const archived_event_id = try h.newUuidString(alloc);
    defer alloc.free(archived_event_id);
    const idem = try std.fmt.allocPrint(alloc, "par06-05-archived-{s}", .{inst_hex});
    defer alloc.free(idem);

    try conn.exec(
        \\INSERT INTO events_archive (event_id, instance_id, event_type, payload, actor_id,
        \\    created_at, sequence_number, idempotency_key, global_seq, tenant_id)
        \\VALUES ($1::uuid, $2::uuid, 'TASK_COMPLETED', '{"task_node_id":"T","output_variables":{}}',
        \\    $3::uuid, NOW(), 2, $4, 999999998, '00000000-0000-0000-0000-000000000000'::uuid)
    ,
        &.{ archived_event_id, inst_hex, actor_hex, idem },
    );
    defer conn.exec("DELETE FROM events_archive WHERE event_id = $1::uuid", &.{archived_event_id}) catch {};

    // Widen last_event_at so the bounded query's upper bound covers the
    // archived row's created_at (mirrors what Store.append() would have done
    // had this event genuinely been appended live before being archived).
    try conn.exec(
        "UPDATE instance_projections SET last_event_at = NOW() + INTERVAL '1 microsecond' WHERE instance_id = $1::uuid",
        &.{inst_hex},
    );

    const reconst_state = try reconstruction_mod.reconstructInstance(
        alloc,
        &pool,
        &snap_store,
        inst.instance_id,
        false,
    );
    defer freeReconstState(alloc, reconst_state);

    // TASK_COMPLETED on node "T" (the instance's only HUMAN_TASK) advances
    // the token past T to END — reconstruction reaching COMPLETED (or at
    // minimum no longer holding a pending token on "T") proves the merged
    // archived row was actually replayed, not silently dropped.
    try std.testing.expectEqual(bpm.transition.InstanceStatus.COMPLETED, reconst_state.status);
}
