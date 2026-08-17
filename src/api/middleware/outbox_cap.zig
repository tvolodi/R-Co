//! OBP-02 — External ingress refusal middleware.
//!
//! Design artefact: src/design/obp-02-ingress-refusal.md
//! Authoritative process: docs/processes/system/outbox-backpressure.md
//! (sys-outbox-backpressure, PW-08) steps 3–6.
//!
//! Reads DepthCache (OBP-01) before any handler runs. Returns HTTP 429 with
//! Retry-After: 5 when depth >= cap or the cache is stale. Does NOT take a
//! pool connection for refused requests. Pushes RefusalEvent to an in-process
//! queue; the drainer flushes them asynchronously via gate.flushRefusalEvents.
//!
//! Security: no user input is interpolated into SQL. Response body is built
//! from bounded integer fields only.
const std = @import("std");
const depth_mod = @import("outbox_depth");

/// Portable millisecond wall-clock timestamp.
/// std.time.milliTimestamp() was removed in Zig 0.16; use OS primitives.
fn currentMilliTimestamp() i64 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const ft: i64 = windows.ntdll.RtlGetSystemTimePrecise();
        const unix_100ns: i64 = ft - 116_444_736_000_000_000;
        return @divTrunc(unix_100ns, 10_000);
    } else {
        const posix = std.posix;
        var ts: posix.timespec = undefined;
        _ = posix.system.clock_gettime(.REALTIME, &ts);
        return ts.sec * 1_000 + @divTrunc(ts.nsec, 1_000_000);
    }
}

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

/// JSON body returned on every 429. Fields map directly to requirement body.
pub const OutboxCapBody = struct {
    @"error": []const u8,
    depth: u64,
    cap: u64,
};

/// One pending refusal event, queued for async DB append by the drainer.
pub const RefusalEvent = struct {
    tenant_schema: []const u8,
    depth: u64,
    cap: u64,
    refused_at_ms: i64,
};

// Ring-buffer constants for the bounded MPSC queue.
pub const QUEUE_CAPACITY: usize = 1024;

/// Bounded MPSC ring-buffer queue of RefusalEvent values. The middleware
/// pushes; the drainer pops and flushes to the DB. If the queue is full,
/// push is silently dropped (events are best-effort — refusing correctly takes
/// priority over blocking the response path).
pub const RefusalEventQueue = struct {
    buf: [QUEUE_CAPACITY]RefusalEvent,
    head: std.atomic.Value(usize), // next pop position
    tail: std.atomic.Value(usize), // next push position

    pub fn init() RefusalEventQueue {
        return .{
            .buf = undefined,
            .head = std.atomic.Value(usize).init(0),
            .tail = std.atomic.Value(usize).init(0),
        };
    }

    /// Push one event. Silently drops when the queue is full.
    pub fn push(self: *RefusalEventQueue, event: RefusalEvent) void {
        const tail = self.tail.load(.acquire);
        const head = self.head.load(.acquire);
        const next_tail = (tail + 1) % QUEUE_CAPACITY;
        if (next_tail == head) return; // full — drop
        self.buf[tail] = event;
        self.tail.store(next_tail, .release);
    }

    /// Pop one event, or null when empty.
    pub fn pop(self: *RefusalEventQueue) ?RefusalEvent {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.acquire);
        if (head == tail) return null; // empty
        const event = self.buf[head];
        self.head.store((head + 1) % QUEUE_CAPACITY, .release);
        return event;
    }
};

// ---------------------------------------------------------------------------
// Middleware configuration
// ---------------------------------------------------------------------------

pub const OutboxCapConfig = struct {
    depth_cap: u64,
    retry_after_seconds: u16 = 5,
};

/// Function-pointer type for the inner handler, matching ratelimit.zig's shape.
pub const Handler = *const fn (ctx: *anyopaque) anyerror!void;

// ---------------------------------------------------------------------------
// apply — the middleware entry point
// ---------------------------------------------------------------------------

/// Apply the capacity check. Called from the middleware chain for every
/// inbound request. Returns a written 429 response if the gate is closed or
/// the depth cache is stale; otherwise delegates to `next`.
///
/// `response_writer` must implement:
///   - writeHeader(status: u16, headers: anytype) !void
///   - writeBody(body: []const u8) !void
pub fn apply(
    allocator: std.mem.Allocator,
    depth_cache: *const depth_mod.DepthCache,
    refusal_queue: *RefusalEventQueue,
    config: OutboxCapConfig,
    tenant_schema: []const u8,
    response_writer: anytype,
    next: Handler,
    next_ctx: *anyopaque,
) anyerror!void {
    const cached = depth_mod.readCached(depth_cache, tenant_schema);

    const at_cap = cached.is_stale or cached.depth >= config.depth_cap;
    if (!at_cap) {
        return next(next_ctx);
    }

    // Build the 429 response body without taking a pool connection.
    const effective_depth = if (cached.is_stale) config.depth_cap else cached.depth;

    // Use fmt.allocPrint for simple fixed-shape JSON (no escaping needed: all
    // values are either the constant string "outbox_at_capacity" or integers).
    const body_json = try std.fmt.allocPrint(
        allocator,
        "{{\"error\":\"outbox_at_capacity\",\"depth\":{d},\"cap\":{d}}}",
        .{ effective_depth, config.depth_cap },
    );
    defer allocator.free(body_json);

    try response_writer.writeHeader(429, .{
        .@"Content-Type" = "application/json",
        .@"Retry-After" = "5",
    });
    try response_writer.writeBody(body_json);

    // Push a RefusalEvent for async DB append (best-effort; queue drop is acceptable).
    refusal_queue.push(RefusalEvent{
        .tenant_schema = tenant_schema,
        .depth = effective_depth,
        .cap = config.depth_cap,
        .refused_at_ms = currentMilliTimestamp(),
    });
}

// ---------------------------------------------------------------------------
// Tests — pure middleware logic (no DB, stub response writer)
// ---------------------------------------------------------------------------

const TestWriter = struct {
    status: u16 = 0,
    body: []const u8 = "",
    headers_written: bool = false,

    pub fn writeHeader(self: *@This(), status: u16, _: anytype) !void {
        self.status = status;
        self.headers_written = true;
    }
    pub fn writeBody(self: *@This(), body: []const u8) !void {
        self.body = body;
    }
};

fn noopHandler(_: *anyopaque) anyerror!void {}

test "obp02: depth below cap — delegates to next handler" {
    var cache = depth_mod.DepthCache.init(std.testing.allocator, 5_000);
    defer cache.deinit();
    // Stub conn for writeFresh.
    const StubConn = struct {
        pub fn exec(_: @This(), _: []const u8, _: *const [1][]const u8) !void {}
    };
    try depth_mod.writeFresh(&cache, StubConn{}, "t1", 100);

    var queue = RefusalEventQueue.init();
    var writer = TestWriter{};
    const config = OutboxCapConfig{ .depth_cap = 50_000 };
    var dummy: u8 = 0;

    try apply(std.testing.allocator, &cache, &queue, config, "t1", &writer, noopHandler, &dummy);
    try std.testing.expectEqual(@as(u16, 0), writer.status); // not a 429
}

test "obp02: depth at cap — returns 429 with correct body" {
    var cache = depth_mod.DepthCache.init(std.testing.allocator, 5_000);
    defer cache.deinit();
    const StubConn = struct {
        pub fn exec(_: @This(), _: []const u8, _: *const [1][]const u8) !void {}
    };
    try depth_mod.writeFresh(&cache, StubConn{}, "t1", 50_000);

    var queue = RefusalEventQueue.init();
    var writer = TestWriter{};
    const config = OutboxCapConfig{ .depth_cap = 50_000 };
    var dummy: u8 = 0;

    try apply(std.testing.allocator, &cache, &queue, config, "t1", &writer, noopHandler, &dummy);
    try std.testing.expectEqual(@as(u16, 429), writer.status);
    try std.testing.expect(writer.headers_written);
    // Event was queued.
    const ev = queue.pop();
    try std.testing.expect(ev != null);
    try std.testing.expectEqualStrings("t1", ev.?.tenant_schema);
}

test "obp02: stale cache — returns 429 (fail-closed)" {
    var cache = depth_mod.DepthCache.init(std.testing.allocator, 0); // stale_timeout_ms=0 → always stale
    defer cache.deinit();
    const StubConn = struct {
        pub fn exec(_: @This(), _: []const u8, _: *const [1][]const u8) !void {}
    };
    try depth_mod.writeFresh(&cache, StubConn{}, "t1", 0);

    var queue = RefusalEventQueue.init();
    var writer = TestWriter{};
    const config = OutboxCapConfig{ .depth_cap = 50_000 };
    var dummy: u8 = 0;

    try apply(std.testing.allocator, &cache, &queue, config, "t1", &writer, noopHandler, &dummy);
    try std.testing.expectEqual(@as(u16, 429), writer.status);
}
