//! OBP-01 — Per-tenant outbox depth cache.
//!
//! Design artefact: src/design/obp-01-outbox-depth-cap.md
//!
//! Owns the per-tenant in-memory depth counter that OBP-02's middleware and
//! OBP-03's outbox.emit() read without taking a pool connection. The drainer
//! calls writeFresh() at the end of every 250 ms sweep; readCached() is
//! lockless on the read path and never touches the DB.
//!
//! Security: no user input is interpolated into SQL in this module. The only
//! DB write (depth_refreshed_at UPDATE) is parameterised.
const std = @import("std");

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// One per-tenant cache entry. writeFresh() acquires mu before updating both
/// atomics so readers never observe a torn state (depth from one cycle,
/// refreshed_at from another).
pub const DepthEntry = struct {
    depth: std.atomic.Value(u64),
    refreshed_at_ms: std.atomic.Value(i64),
    mu: std.atomic.Mutex,
};

/// Result of a readCached() call.
pub const CachedDepth = struct {
    depth: u64,
    /// True when the last write was more than stale_timeout_ms ago, or when no
    /// entry exists for the tenant. A stale read is treated as at-cap by both
    /// OBP-02 and OBP-03 (fail-closed).
    is_stale: bool,
};

pub const DepthCacheError = error{
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// DepthCache
// ---------------------------------------------------------------------------

/// Global per-tenant depth cache. Exactly one instance is created at startup
/// and shared by pointer. All functions are safe to call from multiple threads.
pub const DepthCache = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(*DepthEntry),
    map_mu: std.atomic.Mutex,
    stale_timeout_ms: i64,

    pub fn init(allocator: std.mem.Allocator, stale_timeout_ms: i64) DepthCache {
        return DepthCache{
            .allocator = allocator,
            .entries = std.StringHashMap(*DepthEntry).init(allocator),
            .map_mu = .unlocked,
            .stale_timeout_ms = stale_timeout_ms,
        };
    }

    pub fn deinit(self: *DepthCache) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            self.allocator.destroy(kv.value_ptr.*);
            self.allocator.free(kv.key_ptr.*);
        }
        self.entries.deinit();
    }
};

// ---------------------------------------------------------------------------
// writeFresh — called by the drainer after each sweep
// ---------------------------------------------------------------------------

// Spin-wait until tryLock succeeds (std.Thread.Mutex removed in Zig 0.16).
fn spinLock(mu: *std.atomic.Mutex) void {
    while (!mu.tryLock()) std.atomic.spinLoopHint();
}

/// Portable millisecond wall-clock timestamp.
/// std.time.milliTimestamp() was removed in Zig 0.16; use OS primitives.
fn currentMilliTimestamp() i64 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const ft: i64 = windows.ntdll.RtlGetSystemTimePrecise();
        const unix_100ns: i64 = ft - 116_444_736_000_000_000;
        return @divTrunc(unix_100ns, 10_000); // 100-ns → ms
    } else {
        const posix = std.posix;
        var ts: posix.timespec = undefined;
        _ = posix.system.clock_gettime(.REALTIME, &ts);
        return ts.sec * 1_000 + @divTrunc(ts.nsec, 1_000_000);
    }
}

/// Write a freshly-counted depth for one tenant. Also updates
/// plat_outbox_gate.depth_refreshed_at via `conn` (fire-and-forget: a DB
/// failure leaves the in-memory cache updated and the caller receives no error).
pub fn writeFresh(
    cache: *DepthCache,
    conn: anytype,
    tenant_schema: []const u8,
    depth: u64,
) DepthCacheError!void {
    const now_ms = currentMilliTimestamp();

    // --- update in-memory cache ---
    spinLock(&cache.map_mu);
    const entry_ptr = cache.entries.getPtr(tenant_schema);
    if (entry_ptr) |eptr| {
        const entry = eptr.*;
        cache.map_mu.unlock();
        spinLock(&entry.mu);
        entry.depth.store(depth, .release);
        entry.refreshed_at_ms.store(now_ms, .release);
        entry.mu.unlock();
    } else {
        // First write for this tenant — allocate a new entry.
        const entry = cache.allocator.create(DepthEntry) catch {
            cache.map_mu.unlock();
            return error.OutOfMemory;
        };
        entry.* = DepthEntry{
            .depth = std.atomic.Value(u64).init(depth),
            .refreshed_at_ms = std.atomic.Value(i64).init(now_ms),
            .mu = .unlocked,
        };
        const key = cache.allocator.dupe(u8, tenant_schema) catch {
            cache.allocator.destroy(entry);
            cache.map_mu.unlock();
            return error.OutOfMemory;
        };
        cache.entries.put(key, entry) catch {
            cache.allocator.free(key);
            cache.allocator.destroy(entry);
            cache.map_mu.unlock();
            return error.OutOfMemory;
        };
        cache.map_mu.unlock();
    }

    // --- fire-and-forget DB update (observability / restart recovery) ---
    conn.exec(
        "UPDATE plat_outbox_gate SET depth_refreshed_at = now(), updated_at = now() WHERE tenant_schema = $1",
        &.{tenant_schema},
    ) catch {};
}

// ---------------------------------------------------------------------------
// readCached — called from the request path (OBP-02) and from emit() (OBP-03)
// ---------------------------------------------------------------------------

/// Read the cached depth for one tenant. Lockless on the hot path. Returns
/// is_stale=true if no entry exists or if the last refresh was more than
/// stale_timeout_ms ago. No allocator, no DB access.
pub fn readCached(
    cache: *const DepthCache,
    tenant_schema: []const u8,
) CachedDepth {
    // Acquire the lock only for the map lookup; immediately release.
    const mu = @as(*std.atomic.Mutex, @constCast(&cache.map_mu));
    spinLock(mu);
    const entry_opt = cache.entries.get(tenant_schema);
    mu.unlock();

    const entry = entry_opt orelse return CachedDepth{ .depth = 0, .is_stale = true };

    const depth = entry.depth.load(.acquire);
    const refreshed_at_ms = entry.refreshed_at_ms.load(.acquire);
    const now_ms = currentMilliTimestamp();
    const age_ms = now_ms - refreshed_at_ms;
    const is_stale = age_ms >= cache.stale_timeout_ms;

    return CachedDepth{ .depth = depth, .is_stale = is_stale };
}

// ---------------------------------------------------------------------------
// Tests — pure in-memory behaviour (no DB)
// ---------------------------------------------------------------------------

test "obp01: readCached returns stale when no entry exists" {
    var cache = DepthCache.init(std.testing.allocator, 5_000);
    defer cache.deinit();
    const result = readCached(&cache, "tenant_a");
    try std.testing.expect(result.is_stale);
    try std.testing.expectEqual(@as(u64, 0), result.depth);
}

test "obp01: per-tenant isolation — writeFresh(A) does not affect readCached(B)" {
    var cache = DepthCache.init(std.testing.allocator, 5_000);
    defer cache.deinit();
    // Stub conn that ignores exec calls.
    const StubConn = struct {
        pub fn exec(_: @This(), _: []const u8, _: *const [1][]const u8) !void {}
    };
    const conn = StubConn{};
    try writeFresh(&cache, conn, "tenant_a", 49999);
    const b = readCached(&cache, "tenant_b");
    try std.testing.expect(b.is_stale); // TC-OBP-01-AC4
    const a = readCached(&cache, "tenant_a");
    try std.testing.expectEqual(@as(u64, 49999), a.depth);
    try std.testing.expect(!a.is_stale);
}
