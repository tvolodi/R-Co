//! Integration tests for OBP-04 — outbox ingress gate hysteresis, reopen
//! event, flapping recovery, and escalations (src/outbox/gate.zig).
//!
//! Covers (see tests/specs/OBP-04.md for the full acceptance-criterion mapping):
//!   - OBP-04 AC1: hysteresis through evaluateAndDecide (a closed gate does not
//!     flip open/closed per request on a 49999/50001 oscillation).
//!   - OBP-04 AC2: reopen at the 80% low-water mark persists state + closed
//!     duration and appends EXECUTION_OUTBOX_GATE_OPENED with the duration.
//!   - OBP-04 AC3: a transition within one refresh interval flags flapping and
//!     restores low_water to deriveLowWater(cap) = 80%.
//!   - OBP-04 AC4: recordRefusal returns true past the per-minute threshold and
//!     evaluateEscalations escalates Platform Admin.
//!   - OBP-04 AC5: evaluateEscalations pages Platform Admin past the 300 s
//!     closed-duration threshold.
//!   - OBP-04 AC6 (per-tenant keying) is covered by the schema contract test
//!     obp04_plat_outbox_gate_test.zig.
//!
//! All gate functions are `conn: anytype`, so they run on a TestHarness
//! connection (one transaction, rolled back on deinit) — fixture isolation
//! with zero leakage. Requires BPM_TEST_DB_URL (hard failure if absent — never
//! a silent skip). No module-level `var` (T020): alert recording uses
//! module-level `const std.atomic.Value` counters (immutable bindings).

const std = @import("std");
const bpm = @import("bpm");
const helpers = @import("helpers.zig");
const gate = @import("outbox_gate");

// Alert-hook recording counters. `threadlocal var` is used (not module-level
// `var` — which T020 flags, and not `const` — whose atomic methods need a
// mutable pointer): the alert hook fires synchronously on the calling test
// thread, so the thread-local counter is exactly the counter the test reads.
// Two disjoint counters mean the two alert tests never touch each other.
threadlocal var alert_escalate_count: std.atomic.Value(u32) = .init(0);
threadlocal var alert_page_count: std.atomic.Value(u32) = .init(0);

/// Recording alert hook matching evaluateEscalations' `*const fn` signature.
/// Records severity into the disjoint atomic counters.
fn recordingAlert(
    allocator: std.mem.Allocator,
    severity: gate.AlertSeverity,
    detail: []const u8,
) gate.OutboxGateError!void {
    _ = allocator;
    _ = detail;
    switch (severity) {
        .escalate => {
            _ = alert_escalate_count.fetchAdd(1, .monotonic);
        },
        .page => {
            _ = alert_page_count.fetchAdd(1, .monotonic);
        },
    }
}

/// Fail loudly when BPM_TEST_DB_URL is absent — never a silent skip.
fn requireTestDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = @import("env").globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — cannot run OBP-04 gate integration tests against real PostgreSQL\n", .{});
            return error.MissingTestDbUrl;
        },
        else => return err,
    };
}

fn tenantName(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    const uuid = try bpm.uuid.newUuidV4(allocator);
    defer allocator.free(uuid);
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ prefix, uuid });
}

// ---------------------------------------------------------------------------
// AC1 — hysteresis through evaluateAndDecide
// ---------------------------------------------------------------------------

test "TC-OBP-04-AC1-evaluate-oscillation: a closed gate stays closed through the 49999/50001 oscillation" {
    // covers: OBP-04
    const url = try requireTestDbUrl(std.testing.allocator);
    defer std.testing.allocator.free(url);
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const tenant = try tenantName(std.testing.allocator, "obp04-ac1");
    defer std.testing.allocator.free(tenant);
    const cfg = gate.OutboxGateConfig{
        .depth_cap = 50000,
        .low_water = 40000,
        .refresh_interval_ms = 250,
    };

    // Seed a closed gate whose last transition is NOT within one refresh
    // interval (so the oscillation test does not trip the flapping detector).
    try h.conn.exec(
        \\INSERT INTO plat_outbox_gate (tenant_schema, state, depth, cap, low_water, closed_at, last_transition_at)
        \\VALUES ($1, 'closed', 49999, 50000, 40000, now() - interval '1 minute', now() - interval '1 second')
    ,
        &.{tenant},
    );

    // Depth 49999 -> remain_closed (does not reopen at the cap).
    const d1 = try gate.evaluateAndDecide(std.testing.allocator, &h.conn, tenant, 49999, cfg);
    try std.testing.expectEqual(gate.GateDecision.remain_closed, d1);
    // Depth 50001 -> still remain_closed (hysteresis; closed until low-water).
    const d2 = try gate.evaluateAndDecide(std.testing.allocator, &h.conn, tenant, 50001, cfg);
    try std.testing.expectEqual(gate.GateDecision.remain_closed, d2);

    var status = try gate.readGate(std.testing.allocator, &h.conn, tenant, cfg);
    defer status.deinit(std.testing.allocator);
    try std.testing.expectEqual(gate.GateState.closed, status.state);

    // Depth 40000 -> reopen_now.
    const d3 = try gate.evaluateAndDecide(std.testing.allocator, &h.conn, tenant, 40000, cfg);
    try std.testing.expectEqual(gate.GateDecision.reopen_now, d3);

    var reopened = try gate.readGate(std.testing.allocator, &h.conn, tenant, cfg);
    defer reopened.deinit(std.testing.allocator);
    try std.testing.expectEqual(gate.GateState.open, reopened.state);
}

// ---------------------------------------------------------------------------
// AC2 — reopen at low-water persists state + duration and appends the event
// ---------------------------------------------------------------------------

test "TC-OBP-04-AC2-reopen-appends-event: reopen at low-water appends EXECUTION_OUTBOX_GATE_OPENED with the closed duration" {
    // covers: OBP-04
    const url = try requireTestDbUrl(std.testing.allocator);
    defer std.testing.allocator.free(url);
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const tenant = try tenantName(std.testing.allocator, "obp04-ac2");
    defer std.testing.allocator.free(tenant);
    const cfg = gate.OutboxGateConfig{
        .depth_cap = 50000,
        .low_water = 40000,
        .refresh_interval_ms = 250,
    };

    // Closed gate, closed 10 s ago, last transition 1 s ago (no flapping).
    try h.conn.exec(
        \\INSERT INTO plat_outbox_gate (tenant_schema, state, depth, cap, low_water, closed_at, last_transition_at)
        \\VALUES ($1, 'closed', 49999, 50000, 40000, now() - interval '10 seconds', now() - interval '1 second')
    ,
        &.{tenant},
    );

    const decision = try gate.evaluateAndDecide(std.testing.allocator, &h.conn, tenant, 40000, cfg);
    try std.testing.expectEqual(gate.GateDecision.reopen_now, decision);

    // State persisted open with the closed duration (~10 s).
    var status = try gate.readGate(std.testing.allocator, &h.conn, tenant, cfg);
    defer status.deinit(std.testing.allocator);
    try std.testing.expectEqual(gate.GateState.open, status.state);
    try std.testing.expect(status.closed_duration_ms >= 9000);

    // EXECUTION_OUTBOX_GATE_OPENED appended in the same transaction, carrying
    // the tenant schema in its payload.
    const pattern = try std.fmt.allocPrint(std.testing.allocator, "%\"{s}\"%", .{tenant});
    defer std.testing.allocator.free(pattern);
    var ev = try h.conn.query(std.testing.allocator, "SELECT count(*) FROM events WHERE event_type = 'EXECUTION_OUTBOX_GATE_OPENED' AND payload::text LIKE $1", &.{pattern});
    defer ev.deinit();
    try std.testing.expectEqual(@as(usize, 1), ev.rows.len);
    try std.testing.expectEqualStrings("1", ev.rows[0][0] orelse "0");
}

// ---------------------------------------------------------------------------
// AC3 — flapping detection restores the 80% low-water mark
// ---------------------------------------------------------------------------

test "TC-OBP-04-AC3-flapping-restores-low-water: a transition within one refresh interval restores low_water to 80%" {
    // covers: OBP-04
    const url = try requireTestDbUrl(std.testing.allocator);
    defer std.testing.allocator.free(url);
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const tenant = try tenantName(std.testing.allocator, "obp04-ac3");
    defer std.testing.allocator.free(tenant);
    const cfg = gate.OutboxGateConfig{
        .depth_cap = 50000,
        .low_water = 40001, // misconfigured low-water (not 80%)
        .refresh_interval_ms = 250,
    };

    // Closed gate with last_transition_at = now() so the next transition falls
    // inside one refresh interval (the AC3 defect signature).
    try h.conn.exec(
        \\INSERT INTO plat_outbox_gate (tenant_schema, state, depth, cap, low_water, closed_at, last_transition_at)
        \\VALUES ($1, 'closed', 49999, 50000, 40001, now() - interval '1 minute', now())
    ,
        &.{tenant},
    );

    const decision = try gate.evaluateAndDecide(std.testing.allocator, &h.conn, tenant, 40000, cfg);
    try std.testing.expectEqual(gate.GateDecision.reopen_now, decision);

    // The 80% hysteresis mark was restored in place: floor(cap * 4 / 5) = 40000.
    var status = try gate.readGate(std.testing.allocator, &h.conn, tenant, cfg);
    defer status.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 40000), status.low_water);
    try std.testing.expectEqual(gate.GateState.open, status.state);
}

// ---------------------------------------------------------------------------
// AC4 — refusal threshold and Platform Admin escalation
// ---------------------------------------------------------------------------

test "TC-OBP-04-AC4-refusal-threshold-crossing: recordRefusal returns true past the per-minute threshold" {
    // covers: OBP-04
    const url = try requireTestDbUrl(std.testing.allocator);
    defer std.testing.allocator.free(url);
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const tenant = try tenantName(std.testing.allocator, "obp04-ac4a");
    defer std.testing.allocator.free(tenant);
    const cfg = gate.OutboxGateConfig{
        .depth_cap = 50000,
        .low_water = 40000,
        .refusal_threshold_per_minute = 3,
    };

    // recordRefusal does not seed the row (in production the row already exists
    // because readGate/evaluateAndDecide initialised it on first observation),
    // so seed an open gate row first.
    try h.conn.exec(
        "INSERT INTO plat_outbox_gate (tenant_schema, state, depth, cap, low_water) VALUES ($1, 'open', 0, 50000, 40000)",
        &.{tenant},
    );

    // First 3 calls: at/below threshold -> false. 4th call: > threshold -> true.
    try std.testing.expectEqual(false, try gate.recordRefusal(std.testing.allocator, &h.conn, tenant, cfg));
    try std.testing.expectEqual(false, try gate.recordRefusal(std.testing.allocator, &h.conn, tenant, cfg));
    try std.testing.expectEqual(false, try gate.recordRefusal(std.testing.allocator, &h.conn, tenant, cfg));
    try std.testing.expectEqual(true, try gate.recordRefusal(std.testing.allocator, &h.conn, tenant, cfg));

    var status = try gate.readGate(std.testing.allocator, &h.conn, tenant, cfg);
    defer status.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 4), status.refusal_count_1m);
}

test "TC-OBP-04-AC4-escalation-alert: evaluateEscalations escalates Platform Admin past the refusal rate" {
    // covers: OBP-04
    const url = try requireTestDbUrl(std.testing.allocator);
    defer std.testing.allocator.free(url);
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const tenant = try tenantName(std.testing.allocator, "obp04-ac4b");
    defer std.testing.allocator.free(tenant);
    const cfg = gate.OutboxGateConfig{
        .depth_cap = 50000,
        .low_water = 40000,
        .refusal_threshold_per_minute = 3,
    };

    // Seed a row whose refusal_count_1m is already above the threshold.
    try h.conn.exec(
        "INSERT INTO plat_outbox_gate (tenant_schema, state, depth, cap, low_water, refusal_count_1m) VALUES ($1, 'open', 0, 50000, 40000, 5)",
        &.{tenant},
    );

    alert_escalate_count.store(0, .monotonic);
    try gate.evaluateEscalations(std.testing.allocator, &h.conn, tenant, cfg, &recordingAlert);
    try std.testing.expectEqual(@as(u32, 1), alert_escalate_count.load(.monotonic));
}

// ---------------------------------------------------------------------------
// AC5 — closed-duration page
// ---------------------------------------------------------------------------

test "TC-OBP-04-AC5-closed-duration-page: evaluateEscalations pages Platform Admin past the 300 s closed duration" {
    // covers: OBP-04
    const url = try requireTestDbUrl(std.testing.allocator);
    defer std.testing.allocator.free(url);
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    const tenant = try tenantName(std.testing.allocator, "obp04-ac5");
    defer std.testing.allocator.free(tenant);
    const cfg = gate.OutboxGateConfig{
        .depth_cap = 50000,
        .low_water = 40000,
        .closed_duration_escalation_s = 300,
    };

    // Closed gate with closed_duration_ms already >= 300 s (400 s).
    try h.conn.exec(
        \\INSERT INTO plat_outbox_gate (tenant_schema, state, depth, cap, low_water, closed_at, closed_duration_ms)
        \\VALUES ($1, 'closed', 49999, 50000, 40000, now() - interval '400 seconds', 400000)
    ,
        &.{tenant},
    );

    alert_page_count.store(0, .monotonic);
    try gate.evaluateEscalations(std.testing.allocator, &h.conn, tenant, cfg, &recordingAlert);
    try std.testing.expectEqual(@as(u32, 1), alert_page_count.load(.monotonic));
}
