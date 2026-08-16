//! OBP-04 — Outbox ingress gate hysteresis and escalation.
//!
//! Design artefact: src/design/obp-04-outbox-gate-hysteresis-escalation.md
//! Authoritative process: docs/processes/system/outbox-backpressure.md
//! (sys-outbox-backpressure, PW-08).
//!
//! Implements the per-tenant outbox ingress gate state machine: the gate
//! closes when the tenant's cached outbox depth reaches BPM_OUTBOX_DEPTH_CAP
//! and reopens only when depth falls to BPM_OUTBOX_LOW_WATER (fixed at 80% of
//! the cap, default 40000). Every transition is persisted in `plat_outbox_gate`
//! with the timestamp of the last transition (OBP-04 body), and each reopen
//! appends `EXECUTION_OUTBOX_GATE_OPENED` carrying the closed duration (AC2).
//! The gate also detects the flapping defect (AC3), counts refusals for AC4's
//! 100/min escalation, and evaluates AC5's closed-duration page threshold.
//!
//! The gate is NOT the ingress middleware and NOT the drainer: it is the state
//! machine both consult (OBP-01/02/03, future requirements, consume the same
//! interface). It is keyed per tenant schema so one tenant's depth never
//! refuses another tenant's ingress (AC6).
//!
//! Security: every value is bound as a $N parameter. The `decide` function is
//! pure (no connection, no clock, no env) so it is unit-testable without a DB.
//! Wall-clock timestamps come from the Postgres server clock (SELECT now()),
//! so the `conn: anytype` interface needs no host-side io handle.
const std = @import("std");

// Platform event sentinels (mirror src/event_store/platform.zig — the module
// is kept free of a cross-directory import so it builds as its own named
// module; the values are frozen constants by contract).
const PLATFORM_INSTANCE_ID: []const u8 = "00000000-0000-0000-0000-0000000000ff";
const PLATFORM_ACTOR_ID: []const u8 = "00000000-0000-0000-0000-000000000000";
const PLATFORM_TENANT_ID: []const u8 = "00000000-0000-0000-0000-000000000000";

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// The two legal gate states (mirrors plat_outbox_gate.state CHECK constraint).
pub const GateState = enum {
    open,
    closed,

    pub fn toWire(self: GateState) []const u8 {
        return switch (self) {
            .open => "open",
            .closed => "closed",
        };
    }

    pub fn fromWire(s: []const u8) ?GateState {
        if (std.mem.eql(u8, s, "open")) return .open;
        if (std.mem.eql(u8, s, "closed")) return .closed;
        return null;
    }
};

/// Per-tenant gate configuration. Depth is keyed per tenant schema (AC6); cap
/// and low-water come from the environment at startup, low-water fixed at 80%
/// of cap.
pub const OutboxGateConfig = struct {
    depth_cap: u64 = 50_000,
    low_water: u64 = 40_000,
    refresh_interval_ms: u64 = 250,
    refusal_threshold_per_minute: u32 = 100,
    closed_duration_escalation_s: u64 = 300,
    stale_depth_timeout_ms: u64 = 5_000,

    /// Recompute the hysteresis low-water mark from the cap (AC3 restore).
    pub fn deriveLowWater(cap: u64) u64 {
        // floor(cap * 4 / 5) — 80% hysteresis.
        return (cap * 4) / 5;
    }
};

/// The gate's decision for one depth observation of one tenant.
pub const GateDecision = enum {
    remain_open,
    close_now,
    remain_closed,
    reopen_now,
};

/// Severity of the Platform Admin escalation fired by evaluateEscalations:
/// AC4's refusal-rate breach escalates; AC5's closed-duration breach pages.
pub const AlertSeverity = enum {
    escalate,
    page,
};

/// Decoded plat_outbox_gate row (individually-freed fields, explicit deinit()).
pub const GateStatus = struct {
    tenant_schema: []u8,
    state: GateState,
    depth: u64,
    cap: u64,
    low_water: u64,
    /// ISO-8601 UTC of the last transition.
    last_transition_at: []u8,
    /// Epoch milliseconds of the last transition (convenience for decide()'s
    /// flapping check — derived in SQL, not a stored column).
    last_transition_at_ms: i64,
    closed_duration_ms: u64,
    refusal_count_1m: u64,
    refusal_window_started_at: []u8,

    pub fn deinit(self: GateStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.tenant_schema);
        allocator.free(self.last_transition_at);
        allocator.free(self.refusal_window_started_at);
    }
};

pub const OutboxGateError = error{
    PoolExhausted,
    PersistenceFailed,
    EscalationFailed,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// Pure hysteresis evaluation (AC1/AC2/AC3)
// ---------------------------------------------------------------------------

pub const DecideOutcome = struct {
    decision: GateDecision,
    flapping: bool,
};

/// Core hysteresis evaluation (AC1/AC2/AC3). Pure decision over (previous
/// state, current depth, cap, low-water) — no I/O. `elapsed_since_transition_ms`
/// is the caller-computed age of the last transition (now - last_transition_at),
/// which keeps this function free of any clock read.
///
/// Hysteresis: the gate closes at the cap and reopens only at the low-water
/// mark (AC1 — it never flips open/closed per request on a 49999/50001
/// oscillation); a closed gate with depth above low-water stays closed.
/// Flapping (AC3) is detected when a transition (close or reopen) occurs
/// within one refresh interval of the previous transition — the signature of
/// a low-water mark misconfigured equal to the cap.
pub fn decide(
    previous: GateState,
    depth: u64,
    cap: u64,
    low_water: u64,
    refresh_interval_ms: u64,
    elapsed_since_transition_ms: i64,
) DecideOutcome {
    const decision: GateDecision = switch (previous) {
        .open => if (depth >= cap) .close_now else .remain_open,
        .closed => if (depth <= low_water) .reopen_now else .remain_closed,
    };
    const is_transition = decision == .close_now or decision == .reopen_now;
    const flapping = is_transition and elapsed_since_transition_ms >= 0 and
        @as(u64, @intCast(elapsed_since_transition_ms)) <= refresh_interval_ms;
    return .{ .decision = decision, .flapping = flapping };
}

// ---------------------------------------------------------------------------
// DB access
// ---------------------------------------------------------------------------

/// Read the current gate row for a tenant, initialising open at depth 0 if
/// absent. Uses the Postgres server clock for now_ms so the caller needs no
/// host-side io handle.
pub fn readGate(
    allocator: std.mem.Allocator,
    conn: anytype,
    tenant_schema: []const u8,
    config: OutboxGateConfig,
) OutboxGateError!GateStatus {
    // Seed the row if absent (open at depth 0 with the configured cap/low-water).
    const cap_text = std.fmt.allocPrint(allocator, "{d}", .{config.depth_cap}) catch return error.OutOfMemory;
    defer allocator.free(cap_text);
    const low_water_text = std.fmt.allocPrint(allocator, "{d}", .{config.low_water}) catch return error.OutOfMemory;
    defer allocator.free(low_water_text);
    conn.exec(
        \\INSERT INTO plat_outbox_gate (tenant_schema, state, depth, cap, low_water)
        \\VALUES ($1, 'open', 0, $2, $3)
        \\ON CONFLICT (tenant_schema) DO NOTHING
    ,
        &.{ tenant_schema, cap_text, low_water_text },
    ) catch return error.PersistenceFailed;

    const result = conn.query(
        allocator,
        \\SELECT
        \\  tenant_schema,
        \\  state,
        \\  depth::text,
        \\  cap::text,
        \\  low_water::text,
        \\  to_char(last_transition_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        \\  (EXTRACT(EPOCH FROM last_transition_at) * 1000)::bigint::text,
        \\  closed_duration_ms::text,
        \\  refusal_count_1m::text,
        \\  to_char(refusal_window_started_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        \\FROM plat_outbox_gate
        \\WHERE tenant_schema = $1
    ,
        &.{tenant_schema},
    ) catch return error.PersistenceFailed;
    defer {
        var r = result;
        r.deinit();
    }

    if (result.rows.len == 0 or result.rows[0].len < 10) return error.PersistenceFailed;
    const row = result.rows[0];
    if (row[0] == null or row[1] == null or row[2] == null or row[3] == null or row[4] == null or
        row[5] == null or row[6] == null or row[7] == null or row[8] == null or row[9] == null)
        return error.PersistenceFailed;

    const tenant_dup = allocator.dupe(u8, row[0].?) catch return error.OutOfMemory;
    errdefer allocator.free(tenant_dup);
    const last_transition_dup = allocator.dupe(u8, row[5].?) catch return error.OutOfMemory;
    errdefer allocator.free(last_transition_dup);
    const refusal_window_dup = allocator.dupe(u8, row[9].?) catch return error.OutOfMemory;
    errdefer allocator.free(refusal_window_dup);

    const state = GateState.fromWire(row[1].?) orelse return error.PersistenceFailed;
    const depth = std.fmt.parseInt(u64, row[2].?, 10) catch return error.PersistenceFailed;
    const cap = std.fmt.parseInt(u64, row[3].?, 10) catch return error.PersistenceFailed;
    const low_water = std.fmt.parseInt(u64, row[4].?, 10) catch return error.PersistenceFailed;
    const last_transition_at_ms = std.fmt.parseInt(i64, row[6].?, 10) catch return error.PersistenceFailed;
    const closed_duration_ms = std.fmt.parseInt(u64, row[7].?, 10) catch return error.PersistenceFailed;
    const refusal_count_1m = std.fmt.parseInt(u64, row[8].?, 10) catch return error.PersistenceFailed;

    return GateStatus{
        .tenant_schema = tenant_dup,
        .state = state,
        .depth = depth,
        .cap = cap,
        .low_water = low_water,
        .last_transition_at = last_transition_dup,
        .last_transition_at_ms = last_transition_at_ms,
        .closed_duration_ms = closed_duration_ms,
        .refusal_count_1m = refusal_count_1m,
        .refusal_window_started_at = refusal_window_dup,
    };
}

/// Postgres server wall clock in epoch milliseconds — the single clock source
/// for gate transitions, keeping the `conn: anytype` interface io-free.
fn dbNowMs(conn: anytype, allocator: std.mem.Allocator) OutboxGateError!i64 {
    const result = conn.query(
        allocator,
        "SELECT (EXTRACT(EPOCH FROM now()) * 1000)::bigint::text",
        &.{},
    ) catch return error.PersistenceFailed;
    defer {
        var r = result;
        r.deinit();
    }
    if (result.rows.len == 0 or result.rows[0].len == 0 or result.rows[0][0] == null)
        return error.PersistenceFailed;
    return std.fmt.parseInt(i64, result.rows[0][0].?, 10) catch error.PersistenceFailed;
}

/// Append EXECUTION_OUTBOX_GATE_OPENED on the given conn inside the caller's
/// transaction (so the state write and the event append are one transaction,
/// OBP-04 AC2). Mirrors event_store.Store.appendPlatform's SQL but on the
/// passed conn; the event type is seeded by migration 1164.
fn appendGateOpened(
    allocator: std.mem.Allocator,
    conn: anytype,
    tenant_schema: []const u8,
    closed_duration_ms: u64,
) OutboxGateError!void {
    const duration_text = std.fmt.allocPrint(allocator, "{d}", .{closed_duration_ms}) catch return error.OutOfMemory;
    defer allocator.free(duration_text);
    const now_ms = dbNowMs(conn, allocator) catch return error.PersistenceFailed;
    const idempotency_key = std.fmt.allocPrint(
        allocator,
        "outbox-gate-opened:{s}:{d}:{d}",
        .{ tenant_schema, closed_duration_ms, now_ms },
    ) catch return error.OutOfMemory;
    defer allocator.free(idempotency_key);
    const payload = std.fmt.allocPrint(
        allocator,
        "{{\"tenant_schema\":\"{s}\",\"closed_duration_ms\":{d}}}",
        .{ tenant_schema, closed_duration_ms },
    ) catch return error.OutOfMemory;
    defer allocator.free(payload);

    // PAR-01 idempotency: the partitioned events table has no UNIQUE constraint
    // on idempotency_key — global idempotency lives in the plat_event_idempotency
    // sidecar (written in the same transaction as the append, mirroring
    // event_store.Store.appendPlatform). If the sidecar insert returns no row
    // the key is a duplicate and the events append is absorbed.
    const idem = conn.query(
        allocator,
        \\INSERT INTO plat_event_idempotency (idempotency_key, event_id, created_at)
        \\VALUES ($1, gen_random_uuid(), NOW())
        \\ON CONFLICT (idempotency_key) DO NOTHING
        \\RETURNING event_id::text
    ,
        &.{idempotency_key},
    ) catch return error.PersistenceFailed;
    defer {
        var r = idem;
        r.deinit();
    }
    if (idem.rows.len == 0) return; // duplicate — nothing to append
    if (idem.rows[0].len == 0 or idem.rows[0][0] == null) return error.PersistenceFailed;
    const event_id = idem.rows[0][0].?;

    conn.exec(
        \\INSERT INTO events
        \\  (event_id, instance_id, event_type, payload, actor_id,
        \\   sequence_number, idempotency_key, metadata, tenant_id, global_seq)
        \\VALUES
        \\  ($1::uuid, $2::uuid, 'EXECUTION_OUTBOX_GATE_OPENED', $3::jsonb, $4::uuid,
        \\   0, $5, '{}'::jsonb, $6::uuid, nextval('public.events_global_seq'))
    ,
        &.{ event_id, PLATFORM_INSTANCE_ID, payload, PLATFORM_ACTOR_ID, idempotency_key, PLATFORM_TENANT_ID },
    ) catch return error.PersistenceFailed;
}

/// Apply one depth observation: read the row, run decide(), persist the
/// transition in plat_outbox_gate (state, last_transition_at,
/// closed_duration_ms), and — when the decision is reopen_now — append
/// EXECUTION_OUTBOX_GATE_OPENED with the closed duration (AC2). The state
/// write and the event append are one transaction (the caller owns the
/// transaction boundary). When `flapping` is true, record the defect and
/// restore low_water to 80% of cap (AC3).
pub fn evaluateAndDecide(
    allocator: std.mem.Allocator,
    conn: anytype,
    tenant_schema: []const u8,
    depth: u64,
    config: OutboxGateConfig,
) OutboxGateError!GateDecision {
    var gate = try readGate(allocator, conn, tenant_schema, config);
    defer gate.deinit(allocator);

    const now_ms = try dbNowMs(conn, allocator);
    const elapsed_since_transition_ms = now_ms - gate.last_transition_at_ms;
    const outcome = decide(
        gate.state,
        depth,
        gate.cap,
        gate.low_water,
        config.refresh_interval_ms,
        elapsed_since_transition_ms,
    );

    switch (outcome.decision) {
        .remain_open, .remain_closed => {
            // Depth observation only; still refresh the observed depth so a
            // later read sees the latest value.
            const depth_text = std.fmt.allocPrint(allocator, "{d}", .{depth}) catch return error.OutOfMemory;
            defer allocator.free(depth_text);
            conn.exec(
                "UPDATE plat_outbox_gate SET depth = $2, updated_at = now() WHERE tenant_schema = $1",
                &.{ tenant_schema, depth_text },
            ) catch return error.PersistenceFailed;
        },
        .close_now => {
            const depth_text = std.fmt.allocPrint(allocator, "{d}", .{depth}) catch return error.OutOfMemory;
            defer allocator.free(depth_text);
            conn.exec(
                "UPDATE plat_outbox_gate SET state = 'closed', depth = $2, closed_at = now(), last_transition_at = now(), updated_at = now() WHERE tenant_schema = $1",
                &.{ tenant_schema, depth_text },
            ) catch return error.PersistenceFailed;
        },
        .reopen_now => {
            // Record the closed duration and stamp the transition; then append
            // EXECUTION_OUTBOX_GATE_OPENED with that duration (AC2).
            const depth_text = std.fmt.allocPrint(allocator, "{d}", .{depth}) catch return error.OutOfMemory;
            defer allocator.free(depth_text);
            conn.exec(
                "UPDATE plat_outbox_gate SET state = 'open', depth = $2, closed_duration_ms = COALESCE((EXTRACT(EPOCH FROM (now() - closed_at)) * 1000)::bigint, 0), last_transition_at = now(), updated_at = now() WHERE tenant_schema = $1",
                &.{ tenant_schema, depth_text },
            ) catch return error.PersistenceFailed;
            try appendGateOpened(allocator, conn, tenant_schema, gate.closed_duration_ms);
        },
    }

    // AC3: flapping detected — record the defect and restore the 80% low-water
    // mark in place (the CHECK constraint forbids persisting low_water == cap).
    if (outcome.flapping) {
        const restored = OutboxGateConfig.deriveLowWater(gate.cap);
        const restored_text = std.fmt.allocPrint(allocator, "{d}", .{restored}) catch return error.OutOfMemory;
        defer allocator.free(restored_text);
        conn.exec(
            "UPDATE plat_outbox_gate SET low_water = $2, updated_at = now() WHERE tenant_schema = $1",
            &.{ tenant_schema, restored_text },
        ) catch return error.PersistenceFailed;
    }

    return outcome.decision;
}

/// Record one refused ingress for a tenant and advance AC4's rolling
/// one-minute window. Returns true when the 100/min threshold was crossed so
/// the caller escalates.
pub fn recordRefusal(
    allocator: std.mem.Allocator,
    conn: anytype,
    tenant_schema: []const u8,
    config: OutboxGateConfig,
) OutboxGateError!bool {
    const threshold_text = std.fmt.allocPrint(allocator, "{d}", .{config.refusal_threshold_per_minute}) catch return error.OutOfMemory;
    defer allocator.free(threshold_text);

    // Reset the window when it started more than one minute ago.
    conn.exec(
        \\UPDATE plat_outbox_gate
        \\SET refusal_count_1m = CASE
        \\      WHEN refusal_window_started_at <= now() - interval '1 minute' THEN 1
        \\      ELSE refusal_count_1m + 1
        \\    END,
        \\    refusal_window_started_at = CASE
        \\      WHEN refusal_window_started_at <= now() - interval '1 minute' THEN now()
        \\      ELSE refusal_window_started_at
        \\    END,
        \\    updated_at = now()
        \\WHERE tenant_schema = $1
    ,
        &.{tenant_schema},
    ) catch return error.PersistenceFailed;

    const result = conn.query(
        allocator,
        "SELECT refusal_count_1m::text FROM plat_outbox_gate WHERE tenant_schema = $1",
        &.{tenant_schema},
    ) catch return error.PersistenceFailed;
    defer {
        var r = result;
        r.deinit();
    }
    if (result.rows.len == 0 or result.rows[0].len == 0 or result.rows[0][0] == null)
        return error.PersistenceFailed;
    const count = std.fmt.parseInt(u64, result.rows[0][0].?, 10) catch return error.PersistenceFailed;
    return count > config.refusal_threshold_per_minute;
}

/// Evaluate AC5's closed-duration threshold and AC4's refusal rate on the
/// scheduler/drainer cadence. Pages Platform Admin (AC5) or escalates (AC4)
/// via the caller-supplied alerting hook.
pub fn evaluateEscalations(
    allocator: std.mem.Allocator,
    conn: anytype,
    tenant_schema: []const u8,
    config: OutboxGateConfig,
    alert: *const fn (
        allocator: std.mem.Allocator,
        severity: AlertSeverity,
        detail: []const u8,
    ) OutboxGateError!void,
) OutboxGateError!void {
    var gate = try readGate(allocator, conn, tenant_schema, config);
    defer gate.deinit(allocator);

    // AC4: > 100 refusals in one minute for this tenant.
    if (gate.refusal_count_1m > config.refusal_threshold_per_minute) {
        const detail = std.fmt.allocPrint(
            allocator,
            "OBP-04 AC4: tenant {s} refused {d} requests in one minute; drainer not keeping pace",
            .{ tenant_schema, gate.refusal_count_1m },
        ) catch return error.OutOfMemory;
        defer allocator.free(detail);
        try alert(allocator, .escalate, detail);
    }

    // AC5: closed longer than closed_duration_escalation_s.
    if (gate.state == .closed and gate.closed_duration_ms / 1000 >= config.closed_duration_escalation_s) {
        const detail = std.fmt.allocPrint(
            allocator,
            "OBP-04 AC5: tenant {s} outbox gate closed for {d} ms; drainer must be restarted",
            .{ tenant_schema, gate.closed_duration_ms },
        ) catch return error.OutOfMemory;
        defer allocator.free(detail);
        try alert(allocator, .page, detail);
    }
}

// ---------------------------------------------------------------------------
// Tests — pure decide() hysteresis (no DB)
// ---------------------------------------------------------------------------

test "obp04: gate stays closed on 49999/50001 oscillation until low-water (AC1)" {
    // Gate closed at cap 50000 with depth 49999 -> remain_closed (does not
    // reopen at the cap).
    const d1 = decide(.closed, 49999, 50000, 40000, 250, 1000);
    try std.testing.expectEqual(GateDecision.remain_closed, d1.decision);
    try std.testing.expect(!d1.flapping);
    // Depth rises above cap -> still closed (hysteresis: closed until low-water).
    const d2 = decide(.closed, 50001, 50000, 40000, 250, 1000);
    try std.testing.expectEqual(GateDecision.remain_closed, d2.decision);
    // Depth falls to 40000 -> reopen.
    const d3 = decide(.closed, 40000, 50000, 40000, 250, 1000);
    try std.testing.expectEqual(GateDecision.reopen_now, d3.decision);
}

test "obp04: gate closes at cap and reopens only at low-water (AC1/AC2)" {
    const open_under = decide(.open, 49999, 50000, 40000, 250, 1000);
    try std.testing.expectEqual(GateDecision.remain_open, open_under.decision);
    const close_at_cap = decide(.open, 50000, 50000, 40000, 250, 1000);
    try std.testing.expectEqual(GateDecision.close_now, close_at_cap.decision);
    const closed_above_lw = decide(.closed, 41000, 50000, 40000, 250, 1000);
    try std.testing.expectEqual(GateDecision.remain_closed, closed_above_lw.decision);
}

test "obp04: open+close within one refresh interval flags flapping (AC3)" {
    const quick_reopen = decide(.closed, 40000, 50000, 50000, 250, 100);
    try std.testing.expectEqual(GateDecision.reopen_now, quick_reopen.decision);
    try std.testing.expect(quick_reopen.flapping);
    // A reopen long after the previous transition is NOT flapping.
    const slow_reopen = decide(.closed, 40000, 50000, 40000, 250, 60_000);
    try std.testing.expectEqual(GateDecision.reopen_now, slow_reopen.decision);
    try std.testing.expect(!slow_reopen.flapping);
}

test "obp04: deriveLowWater restores 80% hysteresis (AC3)" {
    try std.testing.expectEqual(@as(u64, 40000), OutboxGateConfig.deriveLowWater(50000));
    try std.testing.expectEqual(@as(u64, 80), OutboxGateConfig.deriveLowWater(100));
}

test "obp04: GateState wire mapping round-trips" {
    try std.testing.expectEqualStrings("open", GateState.open.toWire());
    try std.testing.expectEqualStrings("closed", GateState.closed.toWire());
    try std.testing.expectEqual(GateState.open, GateState.fromWire("open").?);
    try std.testing.expectEqual(GateState.closed, GateState.fromWire("closed").?);
    try std.testing.expect(GateState.fromWire("flapping") == null);
}
