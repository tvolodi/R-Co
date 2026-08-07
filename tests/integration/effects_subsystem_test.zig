//! Integration tests for EXP-301, EXP-302, EXP-303 — Async Effects Subsystem
//!
//! Covers:
//!   - EXP-301: Effects outbox, worker polling, backoff schedule, result re-entry
//!   - EXP-302: SERVICE_TASK migration to async effects, EFFECT_WAIT state
//!   - EXP-303: Stub executor for deterministic testing
//!
//! These tests exercise the complete effects subsystem against a real PostgreSQL
//! database. All test fixtures use per-test UUIDs and clean up after themselves.
//! No HTTP mocks; HTTP tests use a real http.Client against a local test server
//! or stub executor.
//!
//! Requires: BPM_TEST_DB_URL environment variable.
//! Isolation: TestHarness wraps each test in a transaction rolled back on deinit.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const helpers = @import("helpers.zig");
const TestHarness = helpers.TestHarness;
// ISS-0149 / GH #465: cross-platform environ reader, same import every other
// integration test uses to reach BPM_TEST_DB_URL.
const portable_env = @import("env");

const bpm = @import("bpm");
// ISS-0137 / GH #439: src/bpm.zig exports this as `effects_mod`, not `effects`
// (see also effects_stub / effects_queue / effects_worker beside it). The file
// was wired into no build target, so the wrong name never surfaced.
const effects = bpm.effects_mod;
const store_mod = bpm.store;
const registry_mod = bpm.registry;
const transition_mod = bpm.transition;
const graph_mod = bpm.definition;
const EffectSpec = effects.EffectSpec;
const EffectKind = effects.EffectKind;
const HttpEffectSpec = effects.HttpEffectSpec;
const EffectDeliveryResult = effects.EffectDeliveryResult;
// ISS-0149 / GH #465: StubEffectsExecutor lives in src/effects/stub.zig, re-exported
// by src/bpm.zig as `effects_stub` — `effects/mod.zig` does not re-export it. Same for
// the queue and worker modules (`effects_queue` / `effects_worker`). This file was
// wired into no build target until GH #439, so the wrong names never surfaced.
const StubEffectsExecutor = bpm.effects_stub.StubEffectsExecutor;

const Queue = bpm.effects_queue;
const Worker = bpm.effects_worker;

// ---------------------------------------------------------------------------
// Test Helpers
// ---------------------------------------------------------------------------

/// Generate a fresh UUID string for test isolation.
///
/// ISS-0149 / GH #465: previously hand-rolled the hyphenated rendering through
/// `std.io.fixedBufferStream`, which Zig 0.16 removed (`std` has no `io` member).
/// `bpm.uuid.generateUuidV4Into` produces the identical canonical 36-byte form
/// from the same CSPRNG, so delegate rather than re-derive.
fn generateTestUuid(allocator: std.mem.Allocator) ![]u8 {
    var hex_buf: [36]u8 = undefined;
    bpm.uuid.generateUuidV4Into(&hex_buf);
    return allocator.dupe(u8, &hex_buf);
}

fn parseUuid(allocator: std.mem.Allocator, s: []const u8) ![16]u8 {
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
    _ = allocator;
    return out;
}

/// ISS-0158 / GH #479: generate a fresh instance UUID as raw bytes, freeing the
/// intermediate hex string.
///
/// Six TC-EXP-302 blocks wrote `parseUuid(alloc, try generateTestUuid(alloc))`,
/// which leaks: `generateTestUuid` allocates the 36-byte hex form and nothing
/// holds a reference to free it once `parseUuid` has converted it. Those blocks
/// were reported as "leaked 1 allocations" by the test runner. Callers that
/// also need the hex form keep the two-step spelling with its own `defer free`.
fn generateInstanceUuidBytes(allocator: std.mem.Allocator) ![16]u8 {
    const hex = try generateTestUuid(allocator);
    defer allocator.free(hex);
    return try parseUuid(allocator, hex);
}

fn makeObjectMap(allocator: std.mem.Allocator) std.json.ObjectMap {
    return std.json.ObjectMap.init(allocator, &.{}, &.{}) catch unreachable;
}

fn freeInstanceState(allocator: std.mem.Allocator, state: transition_mod.InstanceState) void {
    for (state.tokens) |token| {
        allocator.free(token.node_id);
        allocator.free(token.branch_id);
        if (token.token_id) |id| allocator.free(id);
        if (token.waiting_child_instance_id) |id| allocator.free(id);
    }
    allocator.free(state.tokens);
    // ISS-0149 / GH #465: ObjectMap.deinit takes *Self in Zig 0.16, so the map
    // needs a mutable binding — `state` is passed by value here.
    var variables = state.variables;
    variables.deinit(allocator);
    var join_counters = state.join_counters;
    join_counters.deinit(allocator);
    for (state.pending_task_nodes) |node_id| allocator.free(node_id);
    allocator.free(state.pending_task_nodes);
    for (state.cancelled_branch_ids) |branch_id| allocator.free(branch_id);
    allocator.free(state.cancelled_branch_ids);
    if (state.error_detail) |detail| allocator.free(detail);
}

fn freeTransitionResult(allocator: std.mem.Allocator, result: transition_mod.TransitionResult) void {
    for (result.emitted_events) |event| {
        allocator.free(event.idempotency_key);
        switch (event.payload) {
            .effect_emitted => |payload| {
                allocator.free(payload.node_id);
                allocator.free(payload.token_id);
                allocator.free(payload.correlation_key);
                allocator.free(payload.kind);
                allocator.free(payload.spec_json);
            },
            else => {},
        }
    }
    allocator.free(result.emitted_events);
    freeInstanceState(allocator, result.state);
}

/// ISS-0158 / GH #479: `attrs` MUST stay `comptime`.
///
/// `&[_]GraphNode{...}` yields a pointer to a temporary. When every field is
/// comptime-known, Zig promotes that temporary to static (const) memory and the
/// pointer outlives the function. The moment ONE field is a runtime value — as
/// `attrs` was — the array becomes a stack local instead, and the returned
/// slice dangles the instant this function returns.
///
/// That is exactly what produced the "transition() emits nothing on
/// SERVICE_TASK entry" symptom this issue was filed for. Reading the returned
/// graph showed `svc` and `end` with empty ids and BOTH reporting
/// `node_type == .START` — reclaimed stack bytes, not the nodes written here.
/// `processNodeEntry` therefore never saw a `.SERVICE_TASK` node and never
/// reached the emit branch, so `emitted_events` came back empty and the
/// assertions indexed `emitted_events[0]` on a zero-length slice.
///
/// Production `transition()` was never at fault: a graph built inline with a
/// comptime-known attrs literal emits exactly one `effect_emitted` and parks
/// the token on `svc`, as EXP-302 requires. Marking `attrs` comptime restores
/// full comptime-known-ness so the nodes live in static memory again.
fn makeServiceTaskGraph(comptime attrs: ?[]const u8) graph_mod.DefinitionGraph {
    const nodes = &[_]graph_mod.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "svc", .node_type = .SERVICE_TASK, .label = null, .attributes = attrs },
        .{ .id = "end", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = &[_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "svc", .condition = null, .transform = null, .is_default = false },
        .{ .id = "e2", .source = "svc", .target = "end", .condition = null, .transform = null, .is_default = false },
    };
    return .{ .nodes = nodes, .edges = edges };
}

fn makeSequenceGraph() graph_mod.DefinitionGraph {
    const nodes = &[_]graph_mod.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "svc1", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"url\":\"http://127.0.0.1:18192/one\",\"method\":\"POST\"}" },
        .{ .id = "svc2", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"url\":\"http://127.0.0.1:18192/two\",\"method\":\"POST\"}" },
        .{ .id = "end", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = &[_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "svc1", .condition = null, .transform = null, .is_default = false },
        .{ .id = "e2", .source = "svc1", .target = "svc2", .condition = null, .transform = null, .is_default = false },
        .{ .id = "e3", .source = "svc2", .target = "end", .condition = null, .transform = null, .is_default = false },
    };
    return .{ .nodes = nodes, .edges = edges };
}

fn makeParallelGraph() graph_mod.DefinitionGraph {
    const nodes = &[_]graph_mod.GraphNode{
        .{ .id = "start", .node_type = .START, .label = null, .attributes = null },
        .{ .id = "split", .node_type = .PARALLEL_GATEWAY, .label = null, .attributes = null },
        .{ .id = "svc_left", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"url\":\"http://127.0.0.1:18192/left\",\"method\":\"POST\"}" },
        .{ .id = "svc_right", .node_type = .SERVICE_TASK, .label = null, .attributes = "{\"url\":\"http://127.0.0.1:18192/right\",\"method\":\"POST\"}" },
        .{ .id = "end", .node_type = .END, .label = null, .attributes = null },
    };
    const edges = &[_]graph_mod.GraphEdge{
        .{ .id = "e1", .source = "start", .target = "split", .condition = null, .transform = null, .is_default = false },
        .{ .id = "e2", .source = "split", .target = "svc_left", .condition = null, .transform = null, .is_default = false },
        .{ .id = "e3", .source = "split", .target = "svc_right", .condition = null, .transform = null, .is_default = false },
        .{ .id = "e4", .source = "svc_left", .target = "end", .condition = null, .transform = null, .is_default = false },
        .{ .id = "e5", .source = "svc_right", .target = "end", .condition = null, .transform = null, .is_default = false },
    };
    return .{ .nodes = nodes, .edges = edges };
}

fn makeInitialState(allocator: std.mem.Allocator, instance_id: [16]u8) transition_mod.InstanceState {
    return .{
        .instance_id = instance_id,
        .status = .ACTIVE,
        .tokens = &.{},
        .variables = makeObjectMap(allocator),
        .join_counters = makeObjectMap(allocator),
        .pending_task_nodes = &.{},
        .error_detail = null,
        .cancelled_branch_ids = &.{},
    };
}

// ISS-0149 / GH #465: Zig 0.16 moved the allocator from ObjectMap's handle onto
// each call, so `deinit()` now takes it explicitly. `makeInitialState` always
// builds both maps with the same allocator, so pass it back through here.
fn freeSeedState(allocator: std.mem.Allocator, state: transition_mod.InstanceState) void {
    var variables = state.variables;
    variables.deinit(allocator);
    var join_counters = state.join_counters;
    join_counters.deinit(allocator);
}

fn expectEffectEmitted(event: transition_mod.EmittedEvent) !transition_mod.EffectEmittedPayload {
    return switch (event.payload) {
        .effect_emitted => |payload| payload,
        else => error.InvalidState,
    };
}

// ISS-0149 / GH #465: `conn` is `anytype` because these seeds are called both with
// TestHarness's raw `pg.Conn` (rolled-back tx) and with EffectsPoolFixture's
// `*pool.Conn` (autocommitting), which are distinct types exposing the same
// exec/query surface. Same rationale as Queue.insertEffectInTx's own `anytype`.
fn seedInstanceProjection(conn: anytype, instance_id: []const u8, definition_id: []const u8) !void {
    try conn.exec(
        \\INSERT INTO instance_projections (
        \\  instance_id, definition_id, correlation_key, status,
        \\  current_nodes, variables, error_detail, last_event_seq,
        \\  started_at, completed_at, cancelled_at, updated_at
        \\)
        \\VALUES (
        \\  $1::uuid, $2::uuid, NULL, 'ACTIVE',
        \\  '[]'::jsonb, '{}'::jsonb, NULL, 0,
        \\  NOW(), NULL, NULL, NOW()
        \\)
    , &.{ instance_id, definition_id });
}

fn seedInstanceWait(conn: anytype, instance_id: []const u8, node_id: []const u8, correlation_key: []const u8) ![]u8 {
    const wait_id = try generateTestUuid(std.testing.allocator);
    errdefer std.testing.allocator.free(wait_id);
    const ref_id = try generateTestUuid(std.testing.allocator);
    errdefer std.testing.allocator.free(ref_id);
    try conn.exec(
        \\INSERT INTO instance_waits (id, instance_id, kind, ref_id, node_id, catch_event_key)
        \\VALUES ($1::uuid, $2::uuid, 'catch_event', $3::uuid, $4, $5)
    , &.{ wait_id, instance_id, ref_id, node_id, correlation_key });
    std.testing.allocator.free(ref_id);
    return wait_id;
}

// ---------------------------------------------------------------------------
// ISS-0149 / GH #465 — EffectsPoolFixture
//
// Six blocks in this file drive `Worker.sweepOnce` / `Worker.reenterEffectResult`,
// which take a `*db.Pool` and acquire their OWN connection. They previously wrote
// `&h.pool`, a field TestHarness has never had — this file compiled against no
// build target until GH #439, so the reference was never checked.
//
// Simply swapping in a pool is not enough: TestHarness wraps its connection in a
// transaction that `deinit()` only ever rolls back, so any fixture written through
// `h.conn` is invisible to a separately-acquired pool connection. These blocks must
// therefore seed through the pool itself (autocommitting) and delete their own rows
// explicitly, since no rollback will do it for them.
//
// Per the anti-patterns catalogue's autocommitted-fixture entry, every value written
// here derives from a per-test UUID, never a static literal, so re-runs cannot collide.
// ---------------------------------------------------------------------------
const EffectsPoolFixture = struct {
    pool: bpm.pool.Pool,
    conn: *bpm.pool.Conn,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) !EffectsPoolFixture {
        const env = portable_env.globalEnviron();
        const url = env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
            error.EnvironmentVariableMissing => {
                std.debug.print("BPM_TEST_DB_URL is required for integration tests\n", .{});
                return error.MissingTestDatabaseUrl;
            },
            else => return err,
        };
        defer allocator.free(url);

        // Match every other integration test's makePool(): establish the tenant
        // context BEFORE Pool.init so each acquire() routes search_path the same
        // way (see the ISS-0145 anti-pattern on ambient tenant_context ordering).
        bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
        var pool = try bpm.pool.Pool.init(std.testing.io, allocator, .{
            .url = url,
            .pool_size = 2,
        });
        errdefer pool.deinit();
        const conn = try pool.acquire();
        return .{ .pool = pool, .conn = conn, .allocator = allocator };
    }

    fn deinit(self: *EffectsPoolFixture) void {
        self.pool.release(self.conn);
        self.pool.deinit();
    }

    /// Delete every autocommitted row this fixture may have created, children
    /// before parents. Registered with `defer` BEFORE any insert, so it runs even
    /// if the test body fails mid-way (INV-TI-2).
    fn cleanup(self: *EffectsPoolFixture, instance_id: []const u8) void {
        self.conn.exec("DELETE FROM effects_outbox WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
        self.conn.exec("DELETE FROM instance_waits WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
        self.conn.exec("DELETE FROM events WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
        self.conn.exec("DELETE FROM instance_projections WHERE instance_id = $1::uuid", &.{instance_id}) catch {};
    }
};

/// Create a minimal test tenant and instance for effects testing.
fn setupTestInstance(
    allocator: std.mem.Allocator,
    harness: *TestHarness,
    instance_id: []const u8,
) !void {
    _ = instance_id;
    _ = allocator;
    _ = harness;
    // Minimal setup — in a full integration test, would create tenant, definition, instance
    // via API or direct DB calls. For now, the test inserts rows directly as needed.
}

// ---------------------------------------------------------------------------
// TC-EXP-301-01: Effects Outbox Insert and Query for Due Effects
// ---------------------------------------------------------------------------

test "TC-EXP-301-01: insertEffectInTx inserts row with pending status and future next_attempt_at" {
    var h = try TestHarness.init(testing.allocator);
    defer h.deinit();

    const effect_event_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(effect_event_id);
    const instance_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(instance_id);
    const node_id = "SERVICE_TASK_1";
    const token_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(token_id);
    const correlation_key = try std.fmt.allocPrint(testing.allocator, "{s}:{s}", .{ node_id, token_id });
    defer testing.allocator.free(correlation_key);

    const http_spec = HttpEffectSpec{
        .url = "http://example.com/webhook",
        .method = "POST",
        .headers_json = "{}",
        .body_json = "{\"data\": \"test\"}",
        .timeout_ms = 30_000,
        .retry_limit = 5,
        .secret_ref = null,
    };

    // ISS-0149 / GH #465: Zig 0.16 removed `std.io.fixedBufferStream` and the
    // free `std.json.stringify`; the allocating form is the current API.
    const spec_json = try std.json.Stringify.valueAlloc(testing.allocator, http_spec, .{});
    defer testing.allocator.free(spec_json);

    const spec = EffectSpec{
        .effect_event_id = effect_event_id,
        // ISS-0149 / GH #465: EffectSpec gained tenant_id after this file was
        // written; src/effects/worker.zig uses "default" on the re-entry path.
        .tenant_id = "default",
        .instance_id = instance_id,
        .node_id = node_id,
        .token_id = token_id,
        .correlation_key = correlation_key,
        .kind = .http_call,
        .spec_json = try testing.allocator.dupe(u8, spec_json),
    };
    defer testing.allocator.free(spec.spec_json);

    // Insert effect
    const delivery_id = try Queue.insertEffectInTx(testing.allocator, &h.conn, spec);
    defer testing.allocator.free(delivery_id);

    // Verify row was inserted
    var rows = h.conn.query(
        testing.allocator,
        \\SELECT status, attempt_count, (next_attempt_at > NOW())::text as is_future
        \\FROM effects_outbox WHERE effect_delivery_id = $1::uuid
    ,
        &.{delivery_id},
    ) catch |err| {
        std.debug.print("Query error: {}\n", .{err});
        return error.QueryFailed;
    };
    defer rows.deinit();

    try testing.expect(rows.rows.len == 1);
    try testing.expectEqualStrings(rows.rows[0][0] orelse "", "pending");
    try testing.expectEqualStrings(rows.rows[0][1] orelse "", "0");
    try testing.expectEqualStrings(rows.rows[0][2] orelse "", "true"); // is_future = true
}

// ---------------------------------------------------------------------------
// TC-EXP-301-02: Worker Sweeps and Finds Due Effects
// ---------------------------------------------------------------------------

test "TC-EXP-301-02: sweepOnce selects pending effects with past next_attempt_at" {
    var h = try TestHarness.init(testing.allocator);
    defer h.deinit();

    const effect_event_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(effect_event_id);
    const instance_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(instance_id);
    const token_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(token_id);
    const correlation_key = try std.fmt.allocPrint(testing.allocator, "TASK_1:{s}", .{token_id});
    defer testing.allocator.free(correlation_key);

    const spec = EffectSpec{
        .effect_event_id = effect_event_id,
        // ISS-0149 / GH #465: EffectSpec gained tenant_id after this file was
        // written; src/effects/worker.zig uses "default" on the re-entry path.
        .tenant_id = "default",
        .instance_id = instance_id,
        .node_id = "TASK_1",
        .token_id = token_id,
        .correlation_key = correlation_key,
        .kind = .http_call,
        .spec_json = "{}",
    };

    const delivery_id = try Queue.insertEffectInTx(testing.allocator, &h.conn, spec);
    defer testing.allocator.free(delivery_id);

    // Force next_attempt_at into the past (for testing)
    h.conn.exec(
        "UPDATE effects_outbox SET next_attempt_at = NOW() - INTERVAL '1 minute' WHERE effect_delivery_id = $1::uuid",
        &.{delivery_id},
    ) catch return error.UpdateFailed;

    // Query for due effects (this is what the worker does)
    var due_rows = h.conn.query(
        testing.allocator,
        \\SELECT effect_delivery_id, status FROM effects_outbox
        \\WHERE status = 'pending' AND next_attempt_at <= NOW()
        \\FOR UPDATE SKIP LOCKED
    ,
        &.{},
    ) catch return error.QueryFailed;
    defer due_rows.deinit();

    try testing.expect(due_rows.rows.len >= 1);
    try testing.expectEqualStrings(due_rows.rows[0][1] orelse "", "pending");
}

// ---------------------------------------------------------------------------
// TC-EXP-301-03: HTTP Delivery Success — Mark Delivered and Re-enter
// ---------------------------------------------------------------------------

test "TC-EXP-301-03: markDelivered sets status=delivered and records http_status" {
    var h = try TestHarness.init(testing.allocator);
    defer h.deinit();

    const effect_event_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(effect_event_id);
    const instance_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(instance_id);
    const token_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(token_id);
    const correlation_key = try std.fmt.allocPrint(testing.allocator, "TASK_1:{s}", .{token_id});
    defer testing.allocator.free(correlation_key);

    const spec = EffectSpec{
        .effect_event_id = effect_event_id,
        // ISS-0149 / GH #465: EffectSpec gained tenant_id after this file was
        // written; src/effects/worker.zig uses "default" on the re-entry path.
        .tenant_id = "default",
        .instance_id = instance_id,
        .node_id = "TASK_1",
        .token_id = token_id,
        .correlation_key = correlation_key,
        .kind = .http_call,
        .spec_json = "{}",
    };

    const delivery_id = try Queue.insertEffectInTx(testing.allocator, &h.conn, spec);
    defer testing.allocator.free(delivery_id);

    // Mark as delivered with HTTP 200
    try Queue.markDelivered(testing.allocator, &h.conn, delivery_id, 200);

    // Verify status and http_status
    var rows = h.conn.query(
        testing.allocator,
        "SELECT status, last_http_status FROM effects_outbox WHERE effect_delivery_id = $1::uuid",
        &.{delivery_id},
    ) catch return error.QueryFailed;
    defer rows.deinit();

    try testing.expect(rows.rows.len == 1);
    try testing.expectEqualStrings(rows.rows[0][0] orelse "", "delivered");
    try testing.expectEqualStrings(rows.rows[0][1] orelse "", "200");
}

// ---------------------------------------------------------------------------
// TC-EXP-301-04: HTTP Delivery Retriable Failure — Mark Retry
// ---------------------------------------------------------------------------

test "TC-EXP-301-04: markRetry increments attempt_count and updates next_attempt_at" {
    var h = try TestHarness.init(testing.allocator);
    defer h.deinit();

    const effect_event_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(effect_event_id);
    const instance_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(instance_id);
    const token_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(token_id);
    const correlation_key = try std.fmt.allocPrint(testing.allocator, "TASK_1:{s}", .{token_id});
    defer testing.allocator.free(correlation_key);

    const spec = EffectSpec{
        .effect_event_id = effect_event_id,
        // ISS-0149 / GH #465: EffectSpec gained tenant_id after this file was
        // written; src/effects/worker.zig uses "default" on the re-entry path.
        .tenant_id = "default",
        .instance_id = instance_id,
        .node_id = "TASK_1",
        .token_id = token_id,
        .correlation_key = correlation_key,
        .kind = .http_call,
        .spec_json = "{}",
    };

    const delivery_id = try Queue.insertEffectInTx(testing.allocator, &h.conn, spec);
    defer testing.allocator.free(delivery_id);

    var before = h.conn.query(
        testing.allocator,
        "SELECT attempt_count, next_attempt_at FROM effects_outbox WHERE effect_delivery_id = $1::uuid",
        &.{delivery_id},
    ) catch return error.QueryFailed;
    defer before.deinit();
    try testing.expect(before.rows.len == 1);

    // Mark as retry with 30s backoff
    try Queue.markRetry(testing.allocator, &h.conn, delivery_id, 500, "Service Unavailable", 30_000);

    var after = h.conn.query(
        testing.allocator,
        \\SELECT attempt_count, (next_attempt_at > NOW())::text as is_future, status
        \\FROM effects_outbox WHERE effect_delivery_id = $1::uuid
    ,
        &.{delivery_id},
    ) catch return error.QueryFailed;
    defer after.deinit();

    try testing.expect(after.rows.len == 1);
    try testing.expectEqualStrings(after.rows[0][0] orelse "", "1");
    try testing.expectEqualStrings(after.rows[0][1] orelse "", "true"); // is_future
    try testing.expectEqualStrings(after.rows[0][2] orelse "", "pending");
}

// ---------------------------------------------------------------------------
// TC-EXP-301-05: Backoff Schedule Verification (Integration)
// ---------------------------------------------------------------------------

test "TC-EXP-301-05: backoff schedule follows expected intervals" {
    var h = try TestHarness.init(testing.allocator);
    defer h.deinit();

    const instance_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(instance_id);

    const base_spec_json = "{\"url\":\"http://example.com/backoff\",\"method\":\"POST\"}";
    const expected_backoff = [_]u32{ 5_000, 30_000, 120_000, 600_000 };

    // Create one effect row per attempt_count (0..4).
    var delivery_ids: [5][]const u8 = undefined;
    for (0..5) |i| {
        const effect_event_id = try generateTestUuid(testing.allocator);
        defer testing.allocator.free(effect_event_id);

        const token_id = try std.fmt.allocPrint(testing.allocator, "tok-{d}", .{i});
        defer testing.allocator.free(token_id);
        const node_id = "SERVICE_TASK_BACKOFF";
        const correlation_key = try std.fmt.allocPrint(testing.allocator, "{s}:{s}", .{ node_id, token_id });
        defer testing.allocator.free(correlation_key);

        const spec = EffectSpec{
            .effect_event_id = effect_event_id,
            // ISS-0149 / GH #465: EffectSpec gained tenant_id after this file was written.
            .tenant_id = "default",
            .instance_id = instance_id,
            .node_id = node_id,
            .token_id = token_id,
            .correlation_key = correlation_key,
            .kind = .http_call,
            .spec_json = base_spec_json,
        };

        const delivery_id = try Queue.insertEffectInTx(testing.allocator, &h.conn, spec);
        delivery_ids[i] = delivery_id;

        // Seed row i to attempt_count=i using tiny retry intervals.
        for (0..i) |_| {
            try Queue.markRetry(
                testing.allocator,
                &h.conn,
                delivery_id,
                500,
                "seed attempt_count",
                1,
            );
        }
    }

    defer for (delivery_ids) |id| testing.allocator.free(id);

    for (delivery_ids, 0..) |delivery_id, i| {
        var before_rows = h.conn.query(
            testing.allocator,
            \\SELECT
            \\  attempt_count::text,
            \\  EXTRACT(EPOCH FROM next_attempt_at) * 1000
            \\FROM effects_outbox
            \\WHERE effect_delivery_id = $1::uuid
        ,
            &.{delivery_id},
        ) catch return error.QueryFailed;
        defer before_rows.deinit();

        try testing.expectEqual(@as(usize, 1), before_rows.rows.len);

        const attempt_before = try std.fmt.parseInt(u8, before_rows.rows[0][0] orelse "", 10);
        try testing.expectEqual(@as(u8, @intCast(i)), attempt_before);

        const next_ms_before = std.fmt.parseFloat(f64, before_rows.rows[0][1] orelse "") catch return error.QueryFailed;

        if (attempt_before + 1 >= effects.EFFECT_MAX_ATTEMPTS) {
            try Queue.markDeadLettered(&h.conn, delivery_id, "max attempts exhausted");

            var terminal_rows = h.conn.query(
                testing.allocator,
                "SELECT status, attempt_count::text, last_error FROM effects_outbox WHERE effect_delivery_id = $1::uuid",
                &.{delivery_id},
            ) catch return error.QueryFailed;
            defer terminal_rows.deinit();

            try testing.expectEqual(@as(usize, 1), terminal_rows.rows.len);
            try testing.expectEqualStrings("dead_lettered", terminal_rows.rows[0][0] orelse "");
            try testing.expectEqualStrings("4", terminal_rows.rows[0][1] orelse "");
            try testing.expectEqualStrings("max attempts exhausted", terminal_rows.rows[0][2] orelse "");
            continue;
        }

        const expected_delay = expected_backoff[i];

        try Queue.markRetry(
            testing.allocator,
            &h.conn,
            delivery_id,
            500,
            "schedule check",
            expected_delay,
        );

        var after_rows = h.conn.query(
            testing.allocator,
            \\SELECT
            \\  attempt_count::text,
            \\  EXTRACT(EPOCH FROM next_attempt_at) * 1000,
            \\  status
            \\FROM effects_outbox
            \\WHERE effect_delivery_id = $1::uuid
        ,
            &.{delivery_id},
        ) catch return error.QueryFailed;
        defer after_rows.deinit();

        try testing.expectEqual(@as(usize, 1), after_rows.rows.len);
        const attempt_after = try std.fmt.parseInt(u8, after_rows.rows[0][0] orelse "", 10);
        const next_ms_after = std.fmt.parseFloat(f64, after_rows.rows[0][1] orelse "") catch return error.QueryFailed;
        try testing.expectEqual(attempt_before + 1, attempt_after);
        try testing.expectEqualStrings("pending", after_rows.rows[0][2] orelse "");

        const observed_delta_ms = next_ms_after - next_ms_before;
        const expected_ms = @as(f64, @floatFromInt(expected_delay));
        const lower_bound = expected_ms - 500.0;
        const upper_bound = expected_ms + 500.0;
        try testing.expect(observed_delta_ms >= lower_bound);
        try testing.expect(observed_delta_ms <= upper_bound);
    }
}

// ---------------------------------------------------------------------------
// TC-EXP-301-06: Max Retries Exhausted — Dead-Letter Queue
// ---------------------------------------------------------------------------

test "TC-EXP-301-06: max_attempts reached triggers dead_lettering" {
    var h = try TestHarness.init(testing.allocator);
    defer h.deinit();

    const effect_event_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(effect_event_id);
    const instance_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(instance_id);
    const token_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(token_id);
    const correlation_key = try std.fmt.allocPrint(testing.allocator, "TASK_1:{s}", .{token_id});
    defer testing.allocator.free(correlation_key);

    const spec = EffectSpec{
        .effect_event_id = effect_event_id,
        // ISS-0149 / GH #465: EffectSpec gained tenant_id after this file was
        // written; src/effects/worker.zig uses "default" on the re-entry path.
        .tenant_id = "default",
        .instance_id = instance_id,
        .node_id = "TASK_1",
        .token_id = token_id,
        .correlation_key = correlation_key,
        .kind = .http_call,
        .spec_json = "{}",
    };

    const delivery_id = try Queue.insertEffectInTx(testing.allocator, &h.conn, spec);
    defer testing.allocator.free(delivery_id);

    // Simulate 5 failed attempts
    for (0..5) |_| {
        try Queue.markRetry(testing.allocator, &h.conn, delivery_id, 500, "Failed", 5_000);
    }

    // After 5 retries, mark as dead-lettered
    try Queue.markDeadLettered(&h.conn, delivery_id, "Max attempts exhausted");

    var rows = h.conn.query(
        testing.allocator,
        "SELECT status, attempt_count FROM effects_outbox WHERE effect_delivery_id = $1::uuid",
        &.{delivery_id},
    ) catch return error.QueryFailed;
    defer rows.deinit();

    try testing.expect(rows.rows.len == 1);
    try testing.expectEqualStrings(rows.rows[0][0] orelse "", "dead_lettered");
    try testing.expectEqualStrings(rows.rows[0][1] orelse "", "5");
}

// ---------------------------------------------------------------------------
// TC-EXP-301-07: Idempotency via effect_event_id Header
// ---------------------------------------------------------------------------

test "TC-EXP-301-07: HTTP adapter injects Idempotency-Key header from effect_event_id" {
    const allocator = testing.allocator;
    // ISS-0149 / GH #465: sweepOnce acquires its own pool connection, so the
    // fixture must be autocommitted through that same pool rather than written
    // inside TestHarness's rolled-back transaction.
    var h = try EffectsPoolFixture.init(allocator);
    defer h.deinit();

    const instance_id = try generateTestUuid(allocator);
    defer allocator.free(instance_id);
    defer h.cleanup(instance_id);
    const effect_event_id = try generateTestUuid(allocator);
    defer allocator.free(effect_event_id);
    const definition_id = try generateTestUuid(allocator);
    defer allocator.free(definition_id);
    const correlation_key = try std.fmt.allocPrint(allocator, "svc:{s}", .{effect_event_id});
    defer allocator.free(correlation_key);
    try seedInstanceProjection(h.conn, instance_id, definition_id);

    const delivery_id = try Queue.insertEffectInTx(allocator, h.conn, .{
        .effect_event_id = effect_event_id,
        // ISS-0149 / GH #465: EffectSpec gained tenant_id after this file was
        // written; src/effects/worker.zig uses "default" on the re-entry path.
        .tenant_id = "default",
        .instance_id = instance_id,
        .node_id = "svc",
        .token_id = effect_event_id,
        .correlation_key = correlation_key,
        .kind = .http_call,
        .spec_json = "{\"url\":\"http://127.0.0.1:18192/hook\",\"method\":\"POST\"}",
    });
    defer allocator.free(delivery_id);

    const CaptureServer = struct {
        request_count: usize = 0,
        idempotency_key: [256]u8 = undefined,
        idempotency_key_len: usize = 0,
        thread: ?std.Thread = null,

        fn start(self: *@This()) !void {
            self.thread = try std.Thread.spawn(.{}, run, .{self});
        }

        fn join(self: *@This()) void {
            if (self.thread) |t| t.join();
        }

        fn run(self: *@This()) void {
            const addr = std.Io.net.IpAddress.parse("127.0.0.1", 18192) catch return;
            var server = addr.listen(std.testing.io, .{ .reuse_address = true }) catch return;
            defer server.deinit(std.testing.io);
            var stream = server.accept(std.testing.io) catch return;
            defer stream.close(std.testing.io);
            var recv_buffer: [4096]u8 = undefined;
            var send_buffer: [4096]u8 = undefined;
            var reader = stream.reader(std.testing.io, &recv_buffer);
            var writer = stream.writer(std.testing.io, &send_buffer);
            var http_server: std.http.Server = .init(&reader.interface, &writer.interface);
            var request = http_server.receiveHead() catch return;
            self.request_count += 1;
            var header_it = request.iterateHeaders();
            while (header_it.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "idempotency-key")) {
                    const copy_len = @min(self.idempotency_key.len, header.value.len);
                    @memcpy(self.idempotency_key[0..copy_len], header.value[0..copy_len]);
                    self.idempotency_key_len = copy_len;
                }
            }
            request.respond("{}", .{ .status = .ok, .keep_alive = false }) catch return;
        }
    };

    var server: CaptureServer = .{};
    try server.start();
    defer server.join();

    try h.conn.exec("UPDATE effects_outbox SET next_attempt_at = NOW() - INTERVAL '1 minute' WHERE effect_delivery_id = $1::uuid", &.{ delivery_id });
    Worker.sweepOnce(allocator, &h.pool, .http, .{ .max_rows_per_cycle = 1 });

    try testing.expectEqual(@as(usize, 1), server.request_count);
    // The Idempotency-Key header must be byte-identical to the effect_event_id.
    try testing.expectEqualStrings(effect_event_id, server.idempotency_key[0..server.idempotency_key_len]);
}

// ---------------------------------------------------------------------------
// TC-EXP-301-08: Idempotent Effect Append via Event Store Deduplication
// ---------------------------------------------------------------------------

test "TC-EXP-301-08: duplicate EFFECT_EMITTED events with same idempotency key are deduplicated" {
    const allocator = testing.allocator;
    // ISS-0149 / GH #465: Store/Registry take a *Pool and acquire their own
    // connections, so the instance_projections fixture they depend on must be
    // committed rather than living in TestHarness's rolled-back transaction.
    var h = try EffectsPoolFixture.init(allocator);
    defer h.deinit();

    var registry = registry_mod.Registry.init(allocator, &h.pool);
    defer registry.deinit();
    _ = registry.registerType(allocator, .{
        .name = "EFFECT_EMITTED",
        .schema_version = 1,
        .json_schema = "{}",
        .description = null,
    }) catch {};

    var store = store_mod.Store.init(allocator, &h.pool, &registry);
    defer store.deinit();

    const instance_id = try generateTestUuid(allocator);
    defer allocator.free(instance_id);
    defer h.cleanup(instance_id);
    const definition_id = try generateTestUuid(allocator);
    defer allocator.free(definition_id);
    try seedInstanceProjection(h.conn, instance_id, definition_id);

    const instance_uuid = try parseUuid(allocator, instance_id);
    const actor_uuid = try parseUuid(allocator, definition_id);
    const idem_key = try generateTestUuid(allocator);
    defer allocator.free(idem_key);

    const params = store_mod.AppendParams{
        .instance_id = instance_uuid,
        .event_type = "EFFECT_EMITTED",
        .payload = "{\"node_id\":\"svc\",\"correlation_key\":\"svc:tok\",\"kind\":\"http_call\"}",
        .actor_id = actor_uuid,
        .idempotency_key = idem_key,
        .metadata = null,
        .pipeline_run_id = null,
    };

    const first = try store.append(allocator, params);
    const second = try store.append(allocator, params);
    try testing.expect(!first.is_duplicate);
    try testing.expect(second.is_duplicate);

    var rows = try h.conn.query(allocator, "SELECT COUNT(*) FROM events WHERE idempotency_key = $1", &.{ idem_key });
    defer rows.deinit();
    try testing.expectEqualStrings("1", rows.rows[0][0].?);
}

// ---------------------------------------------------------------------------
// TC-EXP-301-09: Email Adapter (Stub — Placeholder)
// ---------------------------------------------------------------------------

test "TC-EXP-301-09: email adapter returns 200 (stub, no SMTP)" {
    // ISS-0149 / GH #465: sweepOnce acquires its own pool connection — see the
    // EffectsPoolFixture comment above.
    var h = try EffectsPoolFixture.init(testing.allocator);
    defer h.deinit();

    const instance_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(instance_id);
    defer h.cleanup(instance_id);
    const effect_event_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(effect_event_id);
    const definition_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(definition_id);
    const token_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(token_id);
    const correlation_key = try std.fmt.allocPrint(testing.allocator, "EMAIL_1:{s}", .{token_id});
    defer testing.allocator.free(correlation_key);
    try seedInstanceProjection(h.conn, instance_id, definition_id);

    const spec = EffectSpec{
        .effect_event_id = effect_event_id,
        // ISS-0149 / GH #465: EffectSpec gained tenant_id after this file was
        // written; src/effects/worker.zig uses "default" on the re-entry path.
        .tenant_id = "default",
        .instance_id = instance_id,
        .node_id = "EMAIL_1",
        .token_id = token_id,
        .correlation_key = correlation_key,
        .kind = .email,
        .spec_json = "{\"to\":\"test@example.com\",\"subject\":\"Test\",\"body\":\"Hello\"}",
    };

    const delivery_id = try Queue.insertEffectInTx(testing.allocator, h.conn, spec);
    defer testing.allocator.free(delivery_id);
    try h.conn.exec("UPDATE effects_outbox SET next_attempt_at = NOW() - INTERVAL '1 minute' WHERE effect_delivery_id = $1::uuid", &.{ delivery_id });
    Worker.sweepOnce(testing.allocator, &h.pool, .http, .{ .max_rows_per_cycle = 1 });

    var rows = try h.conn.query(
        testing.allocator,
        "SELECT status, last_error FROM effects_outbox WHERE effect_delivery_id = $1::uuid",
        &.{delivery_id},
    );
    defer rows.deinit();

    // The email stub (no secret_ref in spec) succeeds with 200, so the row is
    // marked delivered — last_error stays NULL. The test title says "stub, no SMTP"
    // which is a success path, not a SecretResolutionFailed path.
    try testing.expectEqualStrings("delivered", rows.rows[0][0].?);
    try testing.expect(rows.rows[0][1] == null);
}

// ---------------------------------------------------------------------------
// TC-EXP-301-10: Worker Skips Non-Pending Rows
// ---------------------------------------------------------------------------

test "TC-EXP-301-10: worker query filters out delivered and dead_lettered rows" {
    var h = try TestHarness.init(testing.allocator);
    defer h.deinit();

    // Create three effects with different statuses
    const effect_id_1 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(effect_id_1);
    const effect_id_2 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(effect_id_2);
    const effect_id_3 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(effect_id_3);
    const instance_id_1 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(instance_id_1);
    const token_id_1 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(token_id_1);
    const correlation_key_1 = try std.fmt.allocPrint(testing.allocator, "T1:{s}", .{token_id_1});
    defer testing.allocator.free(correlation_key_1);
    const token_id_2 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(token_id_2);
    const correlation_key_2 = try std.fmt.allocPrint(testing.allocator, "T1:{s}", .{token_id_2});
    defer testing.allocator.free(correlation_key_2);
    const token_id_3 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(token_id_3);
    const correlation_key_3 = try std.fmt.allocPrint(testing.allocator, "T1:{s}", .{token_id_3});
    defer testing.allocator.free(correlation_key_3);

    const spec1 = EffectSpec{
        .effect_event_id = effect_id_1,
        // ISS-0149 / GH #465: EffectSpec gained tenant_id after this file was written.
        .tenant_id = "default",
        .instance_id = instance_id_1,
        .node_id = "T1",
        .token_id = token_id_1,
        .correlation_key = correlation_key_1,
        .kind = .http_call,
        .spec_json = "{}",
    };
    var spec2 = spec1;
    spec2.effect_event_id = effect_id_2;
    spec2.token_id = token_id_2;
    spec2.correlation_key = correlation_key_2;
    var spec3 = spec1;
    spec3.effect_event_id = effect_id_3;
    spec3.token_id = token_id_3;
    spec3.correlation_key = correlation_key_3;

    const id1 = try Queue.insertEffectInTx(testing.allocator, &h.conn, spec1);
    defer testing.allocator.free(id1);
    const id2 = try Queue.insertEffectInTx(testing.allocator, &h.conn, spec2);
    defer testing.allocator.free(id2);
    const id3 = try Queue.insertEffectInTx(testing.allocator, &h.conn, spec3);
    defer testing.allocator.free(id3);

    // Mark first as delivered, second as pending, third as dead-lettered
    try Queue.markDelivered(testing.allocator, &h.conn, id1, 200);
    h.conn.exec(
        "UPDATE effects_outbox SET status = 'dead_lettered' WHERE effect_delivery_id = $1::uuid",
        &.{id3},
    ) catch return error.UpdateFailed;

    // Query should only return the pending one
    var rows = h.conn.query(
        testing.allocator,
        "SELECT effect_delivery_id FROM effects_outbox WHERE status = 'pending' ORDER BY created_at",
        &.{},
    ) catch return error.QueryFailed;
    defer rows.deinit();

    try testing.expect(rows.rows.len >= 1);
    // Should contain id2 (the only pending one we just created)
}

// ---------------------------------------------------------------------------
// TC-EXP-301-11: EFFECT_COMPLETED Re-entry Persists Event and Resolves Wait
// ---------------------------------------------------------------------------

test "TC-EXP-301-11: reenterEffectResult success inserts EFFECT_COMPLETED and resolves wait" {
    const allocator = testing.allocator;
    // ISS-0149 / GH #465: reenterEffectResult takes a *Pool and acquires its own
    // connection — see the EffectsPoolFixture comment above.
    var h = try EffectsPoolFixture.init(allocator);
    defer h.deinit();

    const instance_id = try generateTestUuid(allocator);
    defer allocator.free(instance_id);
    defer h.cleanup(instance_id);
    const definition_id = try generateTestUuid(allocator);
    defer allocator.free(definition_id);
    const token_id = try generateTestUuid(allocator);
    defer allocator.free(token_id);
    const correlation_key = try std.fmt.allocPrint(allocator, "svc:{s}", .{token_id});
    defer allocator.free(correlation_key);

    try seedInstanceProjection(h.conn, instance_id, definition_id);
    const wait_id = try seedInstanceWait(h.conn, instance_id, "svc", correlation_key);
    defer allocator.free(wait_id);

    try Worker.reenterEffectResult(allocator, .{
        .pool = &h.pool,
        .correlation_key = correlation_key,
        .succeeded = true,
        .response_body = "{\"result\":\"ok\"}",
        .http_status = 200,
    });

    var event_rows = try h.conn.query(
        allocator,
        \\SELECT event_type, payload::text
        \\FROM events
        \\WHERE instance_id = $1::uuid
        \\  AND event_type = 'EFFECT_COMPLETED'
        \\ORDER BY sequence_no DESC
        \\LIMIT 1
    ,
        &.{instance_id},
    );
    defer event_rows.deinit();
    try testing.expectEqual(@as(usize, 1), event_rows.rows.len);
    try testing.expectEqualStrings("EFFECT_COMPLETED", event_rows.rows[0][0].?);
    try testing.expect(std.mem.containsAtLeast(u8, event_rows.rows[0][1].?, 1, correlation_key));

    var wait_rows = try h.conn.query(
        allocator,
        "SELECT resolved_at IS NOT NULL FROM instance_waits WHERE id = $1::uuid",
        &.{wait_id},
    );
    defer wait_rows.deinit();
    try testing.expectEqual(@as(usize, 1), wait_rows.rows.len);
    try testing.expectEqualStrings("t", wait_rows.rows[0][0].?);
}

// ---------------------------------------------------------------------------
// TC-EXP-301-12: EFFECT_FAILED Re-entry Persists Event and Resolves Wait
// ---------------------------------------------------------------------------

test "TC-EXP-301-12: reenterEffectResult failure inserts EFFECT_FAILED and resolves wait" {
    const allocator = testing.allocator;
    // ISS-0149 / GH #465: reenterEffectResult takes a *Pool and acquires its own
    // connection — see the EffectsPoolFixture comment above.
    var h = try EffectsPoolFixture.init(allocator);
    defer h.deinit();

    const instance_id = try generateTestUuid(allocator);
    defer allocator.free(instance_id);
    defer h.cleanup(instance_id);
    const definition_id = try generateTestUuid(allocator);
    defer allocator.free(definition_id);
    const token_id = try generateTestUuid(allocator);
    defer allocator.free(token_id);
    const correlation_key = try std.fmt.allocPrint(allocator, "svc:{s}", .{token_id});
    defer allocator.free(correlation_key);

    try seedInstanceProjection(h.conn, instance_id, definition_id);
    const wait_id = try seedInstanceWait(h.conn, instance_id, "svc", correlation_key);
    defer allocator.free(wait_id);

    try Worker.reenterEffectResult(allocator, .{
        .pool = &h.pool,
        .correlation_key = correlation_key,
        .succeeded = false,
        .response_body = null,
        .http_status = 500,
    });

    var event_rows = try h.conn.query(
        allocator,
        \\SELECT event_type, payload::text
        \\FROM events
        \\WHERE instance_id = $1::uuid
        \\  AND event_type = 'EFFECT_FAILED'
        \\ORDER BY sequence_no DESC
        \\LIMIT 1
    ,
        &.{instance_id},
    );
    defer event_rows.deinit();
    try testing.expectEqual(@as(usize, 1), event_rows.rows.len);
    try testing.expectEqualStrings("EFFECT_FAILED", event_rows.rows[0][0].?);
    try testing.expect(std.mem.containsAtLeast(u8, event_rows.rows[0][1].?, 1, correlation_key));

    var wait_rows = try h.conn.query(
        allocator,
        "SELECT resolved_at IS NOT NULL FROM instance_waits WHERE id = $1::uuid",
        &.{wait_id},
    );
    defer wait_rows.deinit();
    try testing.expectEqual(@as(usize, 1), wait_rows.rows.len);
    try testing.expectEqualStrings("t", wait_rows.rows[0][0].?);
}

// ---------------------------------------------------------------------------
// TC-EXP-302-01: SERVICE_TASK Emits Effect on Activation
// ---------------------------------------------------------------------------

test "TC-EXP-302-01: SERVICE_TASK activation emits effect_emitted in async path" {
    var h = try TestHarness.init(testing.allocator);
    defer h.deinit();

    const instance_id_hex = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(instance_id_hex);
    const instance_id = try parseUuid(testing.allocator, instance_id_hex);
    const definition_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(definition_id);

    const state = makeInitialState(testing.allocator, instance_id);
    defer freeSeedState(testing.allocator, state);

    var initial_vars = makeObjectMap(testing.allocator);
    defer initial_vars.deinit(testing.allocator);

    const graph = makeServiceTaskGraph("{\"url\":\"http://127.0.0.1:18192/hook\",\"method\":\"POST\"}");
    const result = try transition_mod.transition(
        testing.allocator,
        graph,
        state,
        .{ .instance_started = .{ .initial_variables = initial_vars, .start_node_id = "start" } },
        1,
    );
    defer freeTransitionResult(testing.allocator, result);

    try testing.expectEqual(@as(usize, 1), result.emitted_events.len);
    const emitted = try expectEffectEmitted(result.emitted_events[0]);
    try testing.expectEqualStrings("svc", emitted.node_id);
    try testing.expectEqualStrings("http_call", emitted.kind);
    try testing.expectEqualStrings("{\"url\":\"http://127.0.0.1:18192/hook\",\"method\":\"POST\"}", emitted.spec_json);
    try testing.expectEqual(@as(usize, 1), result.state.tokens.len);
    try testing.expectEqualStrings("svc", result.state.tokens[0].node_id);
    try testing.expect(result.state.status == .ACTIVE);

    const effect_event_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(effect_event_id);
    const delivery_id = try Queue.insertEffectInTx(testing.allocator, &h.conn, .{
        .effect_event_id = effect_event_id,
        // ISS-0149 / GH #465: EffectSpec gained tenant_id after this file was
        // written; src/effects/worker.zig uses "default" on the re-entry path.
        .tenant_id = "default",
        .instance_id = instance_id_hex,
        .node_id = emitted.node_id,
        .token_id = emitted.token_id,
        .correlation_key = emitted.correlation_key,
        .kind = .http_call,
        .spec_json = emitted.spec_json,
    });
    defer testing.allocator.free(delivery_id);

    var count_rows = h.conn.query(
        testing.allocator,
        "SELECT COUNT(*) FROM effects_outbox WHERE effect_delivery_id = $1::uuid AND status = 'pending'",
        &.{delivery_id},
    ) catch return error.QueryFailed;
    defer count_rows.deinit();
    try testing.expectEqual(@as(usize, 1), count_rows.rows.len);
    try testing.expectEqualStrings("1", count_rows.rows[0][0].?);
}

// ---------------------------------------------------------------------------
// TC-EXP-302-02: SERVICE_TASK Parks Token and Persists Wait/Outbox Rows
// ---------------------------------------------------------------------------

test "TC-EXP-302-02: SERVICE_TASK transition leaves a parked token and persisted wait rows" {
    var h = try TestHarness.init(testing.allocator);
    defer h.deinit();

    const instance_id_hex = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(instance_id_hex);
    const instance_id = try parseUuid(testing.allocator, instance_id_hex);
    const state = makeInitialState(testing.allocator, instance_id);
    defer freeSeedState(testing.allocator, state);

    var initial_vars = makeObjectMap(testing.allocator);
    defer initial_vars.deinit(testing.allocator);

    const graph = makeServiceTaskGraph("{\"url\":\"http://127.0.0.1:18192/hook\",\"method\":\"POST\"}");
    const result = try transition_mod.transition(
        testing.allocator,
        graph,
        state,
        .{ .instance_started = .{ .initial_variables = initial_vars, .start_node_id = "start" } },
        1,
    );
    defer freeTransitionResult(testing.allocator, result);

    const emitted = try expectEffectEmitted(result.emitted_events[0]);
    try testing.expectEqual(@as(usize, 1), result.state.tokens.len);
    try testing.expectEqualStrings("svc", result.state.tokens[0].node_id);

    const effect_event_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(effect_event_id);
    const delivery_id = try Queue.insertEffectInTx(testing.allocator, &h.conn, .{
        .effect_event_id = effect_event_id,
        // ISS-0149 / GH #465: EffectSpec gained tenant_id after this file was
        // written; src/effects/worker.zig uses "default" on the re-entry path.
        .tenant_id = "default",
        .instance_id = instance_id_hex,
        .node_id = emitted.node_id,
        .token_id = emitted.token_id,
        .correlation_key = emitted.correlation_key,
        .kind = .http_call,
        .spec_json = emitted.spec_json,
    });
    defer testing.allocator.free(delivery_id);

    const wait_id = try seedInstanceWait(&h.conn, instance_id_hex, emitted.node_id, emitted.correlation_key);
    defer testing.allocator.free(wait_id);

    var outbox_rows = try h.conn.query(
        testing.allocator,
        "SELECT status, node_id, correlation_key FROM effects_outbox WHERE effect_delivery_id = $1::uuid",
        &.{delivery_id},
    );
    defer outbox_rows.deinit();
    try testing.expectEqual(@as(usize, 1), outbox_rows.rows.len);
    try testing.expectEqualStrings("pending", outbox_rows.rows[0][0].?);
    try testing.expectEqualStrings("svc", outbox_rows.rows[0][1].?);
    try testing.expectEqualStrings(emitted.correlation_key, outbox_rows.rows[0][2].?);

    var wait_rows = try h.conn.query(
        testing.allocator,
        "SELECT node_id, catch_event_key FROM instance_waits WHERE id = $1::uuid",
        &.{wait_id},
    );
    defer wait_rows.deinit();
    try testing.expectEqual(@as(usize, 1), wait_rows.rows.len);
    try testing.expectEqualStrings("svc", wait_rows.rows[0][0].?);
    try testing.expectEqualStrings(emitted.correlation_key, wait_rows.rows[0][1].?);
}

// ---------------------------------------------------------------------------
// TC-EXP-302-03: EFFECT_COMPLETED Re-entry Continues the Instance
// ---------------------------------------------------------------------------

test "TC-EXP-302-03: EFFECT_COMPLETED re-entry advances the token and merges response body" {
    const instance_id = try generateInstanceUuidBytes(testing.allocator);
    const state = makeInitialState(testing.allocator, instance_id);
    defer freeSeedState(testing.allocator, state);

    var initial_vars = makeObjectMap(testing.allocator);
    defer initial_vars.deinit(testing.allocator);

    const graph = makeServiceTaskGraph("{\"url\":\"http://127.0.0.1:18192/hook\",\"method\":\"POST\"}");
    const started = try transition_mod.transition(
        testing.allocator,
        graph,
        state,
        .{ .instance_started = .{ .initial_variables = initial_vars, .start_node_id = "start" } },
        1,
    );
    defer freeTransitionResult(testing.allocator, started);

    const emitted = try expectEffectEmitted(started.emitted_events[0]);
    const completed = try transition_mod.transition(
        testing.allocator,
        graph,
        started.state,
        .{ .effect_completed = .{ .correlation_key = emitted.correlation_key, .response_body_json = "{\"result\":\"ok\"}" } },
        2,
    );
    defer freeTransitionResult(testing.allocator, completed);

    try testing.expectEqual(@as(usize, 0), completed.emitted_events.len);
    try testing.expect(completed.state.status == .COMPLETED);
    try testing.expectEqual(@as(usize, 0), completed.state.tokens.len);
    try testing.expect(completed.state.variables.get("effect_result") != null);
}

// ---------------------------------------------------------------------------
// TC-EXP-302-04: EFFECT_FAILED Re-entry Drives ERROR
// ---------------------------------------------------------------------------

test "TC-EXP-302-04: EFFECT_FAILED re-entry marks the instance ERROR" {
    const instance_id = try generateInstanceUuidBytes(testing.allocator);
    const state = makeInitialState(testing.allocator, instance_id);
    defer freeSeedState(testing.allocator, state);

    var initial_vars = makeObjectMap(testing.allocator);
    defer initial_vars.deinit(testing.allocator);

    const graph = makeServiceTaskGraph("{\"url\":\"http://127.0.0.1:18192/hook\",\"method\":\"POST\"}");
    const started = try transition_mod.transition(
        testing.allocator,
        graph,
        state,
        .{ .instance_started = .{ .initial_variables = initial_vars, .start_node_id = "start" } },
        1,
    );
    defer freeTransitionResult(testing.allocator, started);

    const emitted = try expectEffectEmitted(started.emitted_events[0]);
    const failed = try transition_mod.transition(
        testing.allocator,
        graph,
        started.state,
        .{ .effect_failed = .{ .correlation_key = emitted.correlation_key, .error_detail = "max attempts exhausted" } },
        2,
    );
    defer freeTransitionResult(testing.allocator, failed);

    try testing.expectEqual(@as(usize, 0), failed.emitted_events.len);
    try testing.expect(failed.state.status == .ERROR);
    try testing.expectEqual(@as(usize, 0), failed.state.tokens.len);
    try testing.expect(failed.state.error_detail != null);
}

// ---------------------------------------------------------------------------
// TC-EXP-302-05: sync_inline:true Keeps SERVICE_TASK Inline
// ---------------------------------------------------------------------------

test "TC-EXP-302-05: sync_inline true suppresses async effect emission" {
    const instance_id = try generateInstanceUuidBytes(testing.allocator);
    const state = makeInitialState(testing.allocator, instance_id);
    defer freeSeedState(testing.allocator, state);

    var initial_vars = makeObjectMap(testing.allocator);
    defer initial_vars.deinit(testing.allocator);

    const graph = makeServiceTaskGraph("{\"sync_inline\":true,\"url\":\"http://127.0.0.1:18192/hook\",\"method\":\"POST\"}");
    const result = try transition_mod.transition(
        testing.allocator,
        graph,
        state,
        .{ .instance_started = .{ .initial_variables = initial_vars, .start_node_id = "start" } },
        1,
    );
    defer freeTransitionResult(testing.allocator, result);

    try testing.expectEqual(@as(usize, 0), result.emitted_events.len);
    try testing.expectEqual(@as(usize, 1), result.state.tokens.len);
    try testing.expectEqualStrings("svc", result.state.tokens[0].node_id);
    try testing.expect(result.state.status == .ACTIVE);
}

// ---------------------------------------------------------------------------
// TC-EXP-302-06: EFFECT_COMPLETED Captures Response Body
// ---------------------------------------------------------------------------

test "TC-EXP-302-06: response body is available after EFFECT_COMPLETED re-entry" {
    const instance_id = try generateInstanceUuidBytes(testing.allocator);
    const state = makeInitialState(testing.allocator, instance_id);
    defer freeSeedState(testing.allocator, state);

    var initial_vars = makeObjectMap(testing.allocator);
    defer initial_vars.deinit(testing.allocator);

    const graph = makeServiceTaskGraph("{\"url\":\"http://127.0.0.1:18192/hook\",\"method\":\"POST\"}");
    const started = try transition_mod.transition(
        testing.allocator,
        graph,
        state,
        .{ .instance_started = .{ .initial_variables = initial_vars, .start_node_id = "start" } },
        1,
    );
    defer freeTransitionResult(testing.allocator, started);

    const emitted = try expectEffectEmitted(started.emitted_events[0]);
    const response_body = "{\"invoice_id\":\"INV-123\"}";
    const completed = try transition_mod.transition(
        testing.allocator,
        graph,
        started.state,
        .{ .effect_completed = .{ .correlation_key = emitted.correlation_key, .response_body_json = response_body } },
        2,
    );
    defer freeTransitionResult(testing.allocator, completed);

    try testing.expect(completed.state.variables.get("effect_result") != null);
    try testing.expectEqualStrings(response_body, completed.state.variables.get("effect_result").?.string);
}

// ---------------------------------------------------------------------------
// TC-EXP-302-07: Multiple SERVICE_TASK Nodes in Sequence
// ---------------------------------------------------------------------------

test "TC-EXP-302-07: sequential SERVICE_TASK nodes emit distinct effects" {
    const instance_id = try generateInstanceUuidBytes(testing.allocator);
    const state = makeInitialState(testing.allocator, instance_id);
    defer freeSeedState(testing.allocator, state);

    var initial_vars = makeObjectMap(testing.allocator);
    defer initial_vars.deinit(testing.allocator);

    const graph = makeSequenceGraph();
    const started = try transition_mod.transition(
        testing.allocator,
        graph,
        state,
        .{ .instance_started = .{ .initial_variables = initial_vars, .start_node_id = "start" } },
        1,
    );
    defer freeTransitionResult(testing.allocator, started);

    const first_emitted = try expectEffectEmitted(started.emitted_events[0]);
    const first_completed = try transition_mod.transition(
        testing.allocator,
        graph,
        started.state,
        .{ .effect_completed = .{ .correlation_key = first_emitted.correlation_key, .response_body_json = "{\"step\":1}" } },
        2,
    );
    defer freeTransitionResult(testing.allocator, first_completed);

    try testing.expectEqual(@as(usize, 1), first_completed.emitted_events.len);
    const second_emitted = try expectEffectEmitted(first_completed.emitted_events[0]);
    try testing.expect(!std.mem.eql(u8, first_emitted.correlation_key, second_emitted.correlation_key));
    try testing.expectEqualStrings("svc2", first_completed.state.tokens[0].node_id);
}

// ---------------------------------------------------------------------------
// TC-EXP-302-08: SERVICE_TASK Within Parallel Branches
// ---------------------------------------------------------------------------

test "TC-EXP-302-08: parallel SERVICE_TASK branches emit isolated effects" {
    const instance_id = try generateInstanceUuidBytes(testing.allocator);
    const state = makeInitialState(testing.allocator, instance_id);
    defer freeSeedState(testing.allocator, state);

    var initial_vars = makeObjectMap(testing.allocator);
    defer initial_vars.deinit(testing.allocator);

    const graph = makeParallelGraph();
    const split = try transition_mod.transition(
        testing.allocator,
        graph,
        state,
        .{ .instance_started = .{ .initial_variables = initial_vars, .start_node_id = "start" } },
        1,
    );
    defer freeTransitionResult(testing.allocator, split);

    var effect_emitted_count: usize = 0;
    var first_effect: ?transition_mod.EffectEmittedPayload = null;
    var second_effect: ?transition_mod.EffectEmittedPayload = null;
    for (split.emitted_events) |event| {
        const payload = expectEffectEmitted(event) catch continue;
        if (first_effect == null) {
            first_effect = payload;
        } else {
            second_effect = payload;
        }
        effect_emitted_count += 1;
    }

    try testing.expectEqual(@as(usize, 2), effect_emitted_count);
    try testing.expect(first_effect != null);
    try testing.expect(second_effect != null);
    try testing.expect(!std.mem.eql(u8, first_effect.?.correlation_key, second_effect.?.correlation_key));

    const completed_left = try transition_mod.transition(
        testing.allocator,
        graph,
        split.state,
        .{ .effect_completed = .{ .correlation_key = first_effect.?.correlation_key, .response_body_json = "{\"branch\":\"left\"}" } },
        2,
    );
    defer freeTransitionResult(testing.allocator, completed_left);
    try testing.expectEqual(@as(usize, 1), completed_left.state.tokens.len);

    const completed_right = try transition_mod.transition(
        testing.allocator,
        graph,
        completed_left.state,
        .{ .effect_completed = .{ .correlation_key = second_effect.?.correlation_key, .response_body_json = "{\"branch\":\"right\"}" } },
        3,
    );
    defer freeTransitionResult(testing.allocator, completed_right);

    try testing.expect(completed_right.state.status == .COMPLETED);
    try testing.expectEqual(@as(usize, 0), completed_right.emitted_events.len);
}

// ---------------------------------------------------------------------------
// TC-EXP-303-01: Stub Executor HTTP Call Counter
// ---------------------------------------------------------------------------

test "TC-EXP-303-01: StubEffectsExecutor increments http_call_count" {
    var executor = StubEffectsExecutor.init(testing.allocator);
    defer executor.deinit();
    executor.reset();

    try testing.expectEqual(executor.http_call_count, 0);
    try testing.expectEqual(executor.email_count, 0);
    const token_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(token_id);
    const correlation_key = try std.fmt.allocPrint(testing.allocator, "T1:{s}", .{token_id});
    defer testing.allocator.free(correlation_key);

    // Simulate an HTTP call
    // ISS-0149 / GH #465: this was an inline `try generateTestUuid(...)` with no
    // owner, so the 36-byte allocation leaked on every run — the struct field
    // only borrows the slice. Bind it so a defer can release it.
    const __uuid_1 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(__uuid_1);
    // ISS-0149 / GH #465: this was an inline `try generateTestUuid(...)` with no
    // owner, so the 36-byte allocation leaked on every run — the struct field
    // only borrows the slice. Bind it so a defer can release it.
    const __uuid_2 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(__uuid_2);
    const spec = EffectSpec{
        .effect_event_id = __uuid_1,
        // ISS-0149 / GH #465: EffectSpec gained tenant_id after this file was written.
        .tenant_id = "default",
        .instance_id = __uuid_2,
        .node_id = "T1",
        .token_id = token_id,
        .correlation_key = correlation_key,
        .kind = .http_call,
        .spec_json = "{}",
    };

    const result = executor.execute(testing.allocator, spec, 0) catch return error.ExecuteFailed;
    defer if (result.response_body) |b| testing.allocator.free(b);

    try testing.expectEqual(executor.http_call_count, 1);
    try testing.expectEqual(executor.email_count, 0);
}

// ---------------------------------------------------------------------------
// TC-EXP-303-02: Stub Executor Email Counter
// ---------------------------------------------------------------------------

test "TC-EXP-303-02: StubEffectsExecutor increments email_count independently" {
    var executor = StubEffectsExecutor.init(testing.allocator);
    defer executor.deinit();
    executor.reset();

    executor.http_call_count = 5;
    const token_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(token_id);
    const correlation_key = try std.fmt.allocPrint(testing.allocator, "E1:{s}", .{token_id});
    defer testing.allocator.free(correlation_key);

    // ISS-0149 / GH #465: this was an inline `try generateTestUuid(...)` with no
    // owner, so the 36-byte allocation leaked on every run — the struct field
    // only borrows the slice. Bind it so a defer can release it.
    const __uuid_3 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(__uuid_3);
    // ISS-0149 / GH #465: this was an inline `try generateTestUuid(...)` with no
    // owner, so the 36-byte allocation leaked on every run — the struct field
    // only borrows the slice. Bind it so a defer can release it.
    const __uuid_4 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(__uuid_4);
    const spec = EffectSpec{
        .effect_event_id = __uuid_3,
        // ISS-0149 / GH #465: EffectSpec gained tenant_id after this file was written.
        .tenant_id = "default",
        .instance_id = __uuid_4,
        .node_id = "E1",
        .token_id = token_id,
        .correlation_key = correlation_key,
        .kind = .email,
        .spec_json = "{}",
    };

    const result = executor.execute(testing.allocator, spec, 0) catch return error.ExecuteFailed;
    defer if (result.response_body) |b| testing.allocator.free(b);

    try testing.expectEqual(executor.http_call_count, 5);
    try testing.expectEqual(executor.email_count, 1);
}

// ---------------------------------------------------------------------------
// TC-EXP-303-06: Stub Executor reset() Clears State
// ---------------------------------------------------------------------------

test "TC-EXP-303-06: reset() clears counters and recorded map" {
    var executor = StubEffectsExecutor.init(testing.allocator);
    defer executor.deinit();

    executor.http_call_count = 3;
    executor.email_count = 2;
    const token_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(token_id);
    const correlation_key = try std.fmt.allocPrint(testing.allocator, "svc:{s}", .{token_id});
    defer testing.allocator.free(correlation_key);

    // ISS-0149 / GH #465: this was an inline `try generateTestUuid(...)` with no
    // owner, so the 36-byte allocation leaked on every run — the struct field
    // only borrows the slice. Bind it so a defer can release it.
    const __uuid_5 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(__uuid_5);
    // ISS-0149 / GH #465: this was an inline `try generateTestUuid(...)` with no
    // owner, so the 36-byte allocation leaked on every run — the struct field
    // only borrows the slice. Bind it so a defer can release it.
    const __uuid_6 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(__uuid_6);
    const spec = EffectSpec{
        .effect_event_id = __uuid_5,
        // ISS-0149 / GH #465: EffectSpec gained tenant_id after this file was written.
        .tenant_id = "default",
        .instance_id = __uuid_6,
        .node_id = "svc",
        .token_id = token_id,
        .correlation_key = correlation_key,
        .kind = .http_call,
        .spec_json = "{}",
    };
    const result = try executor.execute(testing.allocator, spec, 0);
    defer if (result.response_body) |b| testing.allocator.free(b);

    executor.reset();

    try testing.expectEqual(executor.http_call_count, 0);
    try testing.expectEqual(executor.email_count, 0);
    try testing.expect(executor.getRecorded(correlation_key) == null);
}

// ---------------------------------------------------------------------------
// TC-EXP-303-08: Stub Executor Idempotency Key Handling
// ---------------------------------------------------------------------------

test "TC-EXP-303-08: StubEffectsExecutor returns idempotency_key_sent from effect_event_id" {

    var executor = StubEffectsExecutor.init(testing.allocator);
    defer executor.deinit();
    executor.reset();
    const effect_event_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(effect_event_id);
    const instance_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(instance_id);
    const token_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(token_id);
    const correlation_key = try std.fmt.allocPrint(testing.allocator, "T1:{s}", .{token_id});
    defer testing.allocator.free(correlation_key);

    const spec = EffectSpec{
        .effect_event_id = effect_event_id,
        // ISS-0149 / GH #465: EffectSpec gained tenant_id after this file was
        // written; src/effects/worker.zig uses "default" on the re-entry path.
        .tenant_id = "default",
        .instance_id = instance_id,
        .node_id = "T1",
        .token_id = token_id,
        .correlation_key = correlation_key,
        .kind = .http_call,
        .spec_json = "{}",
    };

    const result = executor.execute(testing.allocator, spec, 0) catch return error.ExecuteFailed;
    defer if (result.response_body) |b| testing.allocator.free(b);

    try testing.expectEqualStrings(result.idempotency_key_sent, effect_event_id);
}

test "TC-EXP-303-03: StubEffectsExecutor recorded map preserves effect specs" {
    var executor = StubEffectsExecutor.init(testing.allocator);
    defer executor.deinit();
    executor.reset();
    const token_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(token_id);
    const correlation_key = try std.fmt.allocPrint(testing.allocator, "svc:{s}", .{token_id});
    defer testing.allocator.free(correlation_key);

    // ISS-0149 / GH #465: this was an inline `try generateTestUuid(...)` with no
    // owner, so the 36-byte allocation leaked on every run — the struct field
    // only borrows the slice. Bind it so a defer can release it.
    const __uuid_7 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(__uuid_7);
    // ISS-0149 / GH #465: this was an inline `try generateTestUuid(...)` with no
    // owner, so the 36-byte allocation leaked on every run — the struct field
    // only borrows the slice. Bind it so a defer can release it.
    const __uuid_8 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(__uuid_8);
    const spec = EffectSpec{
        .effect_event_id = __uuid_7,
        // ISS-0149 / GH #465: EffectSpec gained tenant_id after this file was written.
        .tenant_id = "default",
        .instance_id = __uuid_8,
        .node_id = "svc",
        .token_id = token_id,
        .correlation_key = correlation_key,
        .kind = .http_call,
        .spec_json = "{\"keep\":true}",
    };
    const result = try executor.execute(testing.allocator, spec, 0);
    defer if (result.response_body) |b| testing.allocator.free(b);
    try testing.expectEqualStrings("{\"keep\":true}", executor.getRecorded(correlation_key).?);
}

test "TC-EXP-303-04: StubEffectsExecutor reset clears counters and recorded state" {
    var executor = StubEffectsExecutor.init(testing.allocator);
    defer executor.deinit();
    executor.reset();
    const token_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(token_id);
    const correlation_key = try std.fmt.allocPrint(testing.allocator, "svc:{s}", .{token_id});
    defer testing.allocator.free(correlation_key);

    // ISS-0149 / GH #465: this was an inline `try generateTestUuid(...)` with no
    // owner, so the 36-byte allocation leaked on every run — the struct field
    // only borrows the slice. Bind it so a defer can release it.
    const __uuid_9 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(__uuid_9);
    // ISS-0149 / GH #465: this was an inline `try generateTestUuid(...)` with no
    // owner, so the 36-byte allocation leaked on every run — the struct field
    // only borrows the slice. Bind it so a defer can release it.
    const __uuid_10 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(__uuid_10);
    const spec = EffectSpec{
        .effect_event_id = __uuid_9,
        // ISS-0149 / GH #465: EffectSpec gained tenant_id after this file was written.
        .tenant_id = "default",
        .instance_id = __uuid_10,
        .node_id = "svc",
        .token_id = token_id,
        .correlation_key = correlation_key,
        .kind = .http_call,
        .spec_json = "{}",
    };
    const result = try executor.execute(testing.allocator, spec, 0);
    defer if (result.response_body) |b| testing.allocator.free(b);
    executor.reset();

    try testing.expectEqual(@as(u32, 0), executor.http_call_count);
    try testing.expectEqual(@as(u32, 0), executor.email_count);
    try testing.expect(executor.getRecorded("svc:tok") == null);
}

test "TC-EXP-303-05: StubEffectsExecutor failure response is configurable" {
    var executor = StubEffectsExecutor.init(testing.allocator);
    defer executor.deinit();
    executor.reset();
    executor.stub_status_code = 500;
    const token_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(token_id);
    const correlation_key = try std.fmt.allocPrint(testing.allocator, "svc:{s}", .{token_id});
    defer testing.allocator.free(correlation_key);

    // ISS-0149 / GH #465: this was an inline `try generateTestUuid(...)` with no
    // owner, so the 36-byte allocation leaked on every run — the struct field
    // only borrows the slice. Bind it so a defer can release it.
    const __uuid_11 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(__uuid_11);
    // ISS-0149 / GH #465: this was an inline `try generateTestUuid(...)` with no
    // owner, so the 36-byte allocation leaked on every run — the struct field
    // only borrows the slice. Bind it so a defer can release it.
    const __uuid_12 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(__uuid_12);
    const spec = EffectSpec{
        .effect_event_id = __uuid_11,
        // ISS-0149 / GH #465: EffectSpec gained tenant_id after this file was written.
        .tenant_id = "default",
        .instance_id = __uuid_12,
        .node_id = "svc",
        .token_id = token_id,
        .correlation_key = correlation_key,
        .kind = .http_call,
        .spec_json = "{}",
    };
    const result = try executor.execute(testing.allocator, spec, 0);
    defer if (result.response_body) |b| testing.allocator.free(b);
    try testing.expectEqual(@as(u16, 500), result.status_code);
}

test "TC-EXP-303-07: StubEffectsExecutor executes deterministically with no external I/O" {
    var executor = StubEffectsExecutor.init(testing.allocator);
    defer executor.deinit();
    executor.reset();
    const token_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(token_id);
    const correlation_key = try std.fmt.allocPrint(testing.allocator, "svc:{s}", .{token_id});
    defer testing.allocator.free(correlation_key);

    // ISS-0149 / GH #465: this was an inline `try generateTestUuid(...)` with no
    // owner, so the 36-byte allocation leaked on every run — the struct field
    // only borrows the slice. Bind it so a defer can release it.
    const __uuid_13 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(__uuid_13);
    // ISS-0149 / GH #465: this was an inline `try generateTestUuid(...)` with no
    // owner, so the 36-byte allocation leaked on every run — the struct field
    // only borrows the slice. Bind it so a defer can release it.
    const __uuid_14 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(__uuid_14);
    const spec = EffectSpec{
        .effect_event_id = __uuid_13,
        // ISS-0149 / GH #465: EffectSpec gained tenant_id after this file was written.
        .tenant_id = "default",
        .instance_id = __uuid_14,
        .node_id = "svc",
        .token_id = token_id,
        .correlation_key = correlation_key,
        .kind = .http_call,
        .spec_json = "{}",
    };

    const r1 = try executor.execute(testing.allocator, spec, 0);
    defer if (r1.response_body) |b| testing.allocator.free(b);
    const r2 = try executor.execute(testing.allocator, spec, 0);
    defer if (r2.response_body) |b| testing.allocator.free(b);

    try testing.expectEqual(@as(u32, 2), executor.http_call_count);
    try testing.expectEqualStrings(r1.idempotency_key_sent, r2.idempotency_key_sent);
}

test "TC-EXP-303-09: StubEffectsExecutor keeps different keys isolated" {
    var executor = StubEffectsExecutor.init(testing.allocator);
    defer executor.deinit();
    executor.reset();

    // ISS-0149 / GH #465: this was an inline `try generateTestUuid(...)` with no
    // owner, so the 36-byte allocation leaked on every run — the struct field
    // only borrows the slice. Bind it so a defer can release it.
    const __uuid_15 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(__uuid_15);
    // ISS-0149 / GH #465: this was an inline `try generateTestUuid(...)` with no
    // owner, so the 36-byte allocation leaked on every run — the struct field
    // only borrows the slice. Bind it so a defer can release it.
    const __uuid_16 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(__uuid_16);
    const spec_a = EffectSpec{
        .effect_event_id = __uuid_15,
        // ISS-0149 / GH #465: EffectSpec gained tenant_id after this file was written.
        .tenant_id = "default",
        .instance_id = __uuid_16,
        .node_id = "svc",
        .token_id = "tok-a",
        .correlation_key = "svc:tok-a",
        .kind = .http_call,
        .spec_json = "{\"a\":1}",
    };
    // ISS-0149 / GH #465: this was an inline `try generateTestUuid(...)` with no
    // owner, so the 36-byte allocation leaked on every run — the struct field
    // only borrows the slice. Bind it so a defer can release it.
    const __uuid_17 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(__uuid_17);
    // ISS-0149 / GH #465: this was an inline `try generateTestUuid(...)` with no
    // owner, so the 36-byte allocation leaked on every run — the struct field
    // only borrows the slice. Bind it so a defer can release it.
    const __uuid_18 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(__uuid_18);
    const spec_b = EffectSpec{
        .effect_event_id = __uuid_17,
        // ISS-0149 / GH #465: EffectSpec gained tenant_id after this file was written.
        .tenant_id = "default",
        .instance_id = __uuid_18,
        .node_id = "svc",
        .token_id = "tok-b",
        .correlation_key = "svc:tok-b",
        .kind = .http_call,
        .spec_json = "{\"b\":2}",
    };

    const r1 = try executor.execute(testing.allocator, spec_a, 0);
    defer if (r1.response_body) |b| testing.allocator.free(b);
    const r2 = try executor.execute(testing.allocator, spec_b, 0);
    defer if (r2.response_body) |b| testing.allocator.free(b);

    try testing.expectEqualStrings("{\"a\":1}", executor.getRecorded("svc:tok-a").?);
    try testing.expectEqualStrings("{\"b\":2}", executor.getRecorded("svc:tok-b").?);
}

test "TC-EXP-303-10: zero-attempt execution returns a deterministic result" {
    var executor = StubEffectsExecutor.init(testing.allocator);
    defer executor.deinit();
    executor.reset();
    const token_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(token_id);
    const correlation_key = try std.fmt.allocPrint(testing.allocator, "svc:{s}", .{token_id});
    defer testing.allocator.free(correlation_key);

    // ISS-0149 / GH #465: this was an inline `try generateTestUuid(...)` with no
    // owner, so the 36-byte allocation leaked on every run — the struct field
    // only borrows the slice. Bind it so a defer can release it.
    const __uuid_19 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(__uuid_19);
    // ISS-0149 / GH #465: this was an inline `try generateTestUuid(...)` with no
    // owner, so the 36-byte allocation leaked on every run — the struct field
    // only borrows the slice. Bind it so a defer can release it.
    const __uuid_20 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(__uuid_20);
    const spec = EffectSpec{
        .effect_event_id = __uuid_19,
        // ISS-0149 / GH #465: EffectSpec gained tenant_id after this file was written.
        .tenant_id = "default",
        .instance_id = __uuid_20,
        .node_id = "svc",
        .token_id = token_id,
        .correlation_key = correlation_key,
        .kind = .http_call,
        .spec_json = "{}",
    };
    const result = try executor.execute(testing.allocator, spec, 0);
    defer if (result.response_body) |b| testing.allocator.free(b);
    try testing.expectEqual(@as(u16, 200), result.status_code);
}

test "TC-EXP-303-11: changing the configured response changes behavior" {
    var executor = StubEffectsExecutor.init(testing.allocator);
    defer executor.deinit();
    executor.reset();
    const token_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(token_id);
    const correlation_key = try std.fmt.allocPrint(testing.allocator, "svc:{s}", .{token_id});
    defer testing.allocator.free(correlation_key);

    // ISS-0149 / GH #465: this was an inline `try generateTestUuid(...)` with no
    // owner, so the 36-byte allocation leaked on every run — the struct field
    // only borrows the slice. Bind it so a defer can release it.
    const __uuid_21 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(__uuid_21);
    // ISS-0149 / GH #465: this was an inline `try generateTestUuid(...)` with no
    // owner, so the 36-byte allocation leaked on every run — the struct field
    // only borrows the slice. Bind it so a defer can release it.
    const __uuid_22 = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(__uuid_22);
    const spec = EffectSpec{
        .effect_event_id = __uuid_21,
        // ISS-0149 / GH #465: EffectSpec gained tenant_id after this file was written.
        .tenant_id = "default",
        .instance_id = __uuid_22,
        .node_id = "svc",
        .token_id = token_id,
        .correlation_key = correlation_key,
        .kind = .http_call,
        .spec_json = "{}",
    };

    executor.stub_status_code = 201;
    const first = try executor.execute(testing.allocator, spec, 0);
    defer if (first.response_body) |b| testing.allocator.free(b);
    executor.stub_status_code = 503;
    const second = try executor.execute(testing.allocator, spec, 0);
    defer if (second.response_body) |b| testing.allocator.free(b);

    try testing.expectEqual(@as(u16, 201), first.status_code);
    try testing.expectEqual(@as(u16, 503), second.status_code);
}

// ---------------------------------------------------------------------------
// Integration sanity check
// ---------------------------------------------------------------------------

test "effects module imports compile successfully" {
    // Verify that the module compiles and key types are accessible
    const token_id = try generateTestUuid(testing.allocator);
    defer testing.allocator.free(token_id);
    const correlation_key = try std.fmt.allocPrint(testing.allocator, "svc:{s}", .{token_id});
    defer testing.allocator.free(correlation_key);
    const spec = EffectSpec{
        .effect_event_id = "test",
        // ISS-0149 / GH #465: EffectSpec gained tenant_id after this file was written.
        .tenant_id = "default",
        .instance_id = "inst",
        .node_id = "node",
        .token_id = token_id,
        .correlation_key = correlation_key,
        .kind = .http_call,
        .spec_json = "{}",
    };

    try testing.expectEqualStrings(spec.kind.toWire(), "http_call");
}
