//! OBP-03 — Typed outbox overflow on internal emit path.
//!
//! Design artefact: src/design/obp-03-outbox-overflow.md
//!
//! Thin wrapper around effects/queue.zig::insertEffectInTx that adds the
//! per-tenant depth pre-check. All BPM engine paths that emit an effect must
//! call emit() rather than calling insertEffectInTx directly.
//!
//! If depth >= cap OR the cache entry is stale, emit() returns
//! error.OutboxOverflow without touching the database. The calling step body
//! propagates the error; the engine rolls back and retries under the node's
//! existing policy.
//!
//! Compile-time enforcement: OutboxOverflow is part of EffectQueueError
//! (see src/effects/mod.zig). Any caller that omits it from its own error set
//! produces a Zig compile error (OBP-03 AC2).
//!
//! Security: all SQL is delegated to insertEffectInTx which uses parameterised
//! queries. This module contains no SQL.
const std = @import("std");
const depth_mod = @import("depth.zig");
const queue = @import("effects_queue");

pub const EffectSpec = queue.EffectSpec;
pub const EffectQueueError = queue.EffectQueueError;

/// Emit one outbox effect from within a step transaction.
///
/// Checks the in-memory depth cache BEFORE calling insertEffectInTx. If the
/// cached depth is at or above `cap`, or if the cache entry is stale, returns
/// error.OutboxOverflow without inserting any row and without touching `conn`.
///
/// MUST be called inside an already-open transaction on `conn`.
/// The caller MUST declare OutboxOverflow in its error set (OBP-03 AC2).
pub fn emit(
    allocator: std.mem.Allocator,
    conn: anytype,
    depth_cache: *const depth_mod.DepthCache,
    cap: u64,
    spec: EffectSpec,
) EffectQueueError![]const u8 {
    const tenant_schema = spec.tenant_id; // per-tenant keying via tenant_id field
    const cached = depth_mod.readCached(depth_cache, tenant_schema);

    if (cached.is_stale or cached.depth >= cap) {
        return error.OutboxOverflow;
    }

    return queue.insertEffectInTx(allocator, conn, spec);
}

// ---------------------------------------------------------------------------
// Tests — pure depth-check logic (no DB)
// ---------------------------------------------------------------------------

// Stub connection for overflow tests. Zig compiles all branches of anytype
// functions, so we must provide query() with the right shape.
const StubQueryRows = struct {
    rows: []const []const ?[]const u8 = &.{},
    pub fn deinit(self: *@This()) void {
        _ = self;
    }
};
const OverflowStubConn = struct {
    pub fn exec(_: @This(), _: []const u8, _: anytype) !void {}
    pub fn query(_: @This(), _: std.mem.Allocator, _: []const u8, _: anytype) !StubQueryRows {
        return StubQueryRows{};
    }
};

test "obp03: emit returns OutboxOverflow when depth at cap" {
    var cache = depth_mod.DepthCache.init(std.testing.allocator, 5_000);
    defer cache.deinit();
    const StubExec = struct {
        pub fn exec(_: @This(), _: []const u8, _: *const [1][]const u8) !void {}
    };
    try depth_mod.writeFresh(&cache, StubExec{}, "tenant_x", 50_000);

    const spec = EffectSpec{
        .effect_event_id = "evt-id",
        .tenant_id = "tenant_x",
        .instance_id = "inst-id",
        .node_id = "node-id",
        .token_id = "tok-id",
        .correlation_key = "corr-key",
        .kind = .http_call,
        .spec_json = "{}",
    };
    const result = emit(std.testing.allocator, OverflowStubConn{}, &cache, 50_000, spec);
    try std.testing.expectError(error.OutboxOverflow, result);
}

test "obp03: emit returns OutboxOverflow when cache is stale" {
    var cache = depth_mod.DepthCache.init(std.testing.allocator, 0); // stale_timeout_ms=0
    defer cache.deinit();
    const StubExec = struct {
        pub fn exec(_: @This(), _: []const u8, _: *const [1][]const u8) !void {}
    };
    try depth_mod.writeFresh(&cache, StubExec{}, "tenant_y", 0);

    const spec = EffectSpec{
        .effect_event_id = "evt-id",
        .tenant_id = "tenant_y",
        .instance_id = "inst-id",
        .node_id = "node-id",
        .token_id = "tok-id",
        .correlation_key = "corr-key",
        .kind = .http_call,
        .spec_json = "{}",
    };
    const result = emit(std.testing.allocator, OverflowStubConn{}, &cache, 50_000, spec);
    try std.testing.expectError(error.OutboxOverflow, result);
}
