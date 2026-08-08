//! Wall clock timeout enforcement (LUA-10).
//!
//! Tracks elapsed time during script execution and raises an error when timeout is exceeded.
//! This is separate from instruction counting to handle blocking operations.
//!
//! ## Host-external watchdog (design §2.5, ISS-0169 / GH #495 tranche 2)
//!
//! `TimeoutContext` above is checked from INSIDE the Lua-owning thread, via
//! the count hook (`instruction_limiter.zig`) — it can only fire while the VM
//! is dispatching Lua bytecode, so it cannot interrupt a script blocked inside
//! a `lua_CFunction` (LUA-10 acceptance criterion 1), and it is not
//! enforcement "from outside the Lua state" (acceptance criterion 2) because
//! it depends entirely on the VM voluntarily calling back into the hook.
//!
//! `WatchdogState`/`WatchdogHandle` below run on a SEPARATE `std.Thread` that
//! never touches `L` and never calls any `lua_*` function (no primitive in
//! `luajit_bindings.zig` supports safe cross-thread interruption of a
//! `lua_State` — `lua_error`'s `longjmp` must run on the thread that owns the
//! state). The watchdog's job is detection-and-flagging from outside, not
//! forced pre-emption of an in-flight blocking call — see design §2.5.2 for
//! the full reasoning and §11 item 1 for the explicitly named remaining gap
//! (a genuinely blocking foreign syscall cannot be aborted mid-call without
//! host_api/HTTP-client work beyond this tranche).

const std = @import("std");
const time_source = @import("time_source.zig");

pub const TimeoutContext = struct {
    timeout_ms: u64,
    start_time: i64, // nanoseconds since epoch
    timed_out: bool,

    pub fn init(timeout_seconds: u32) TimeoutContext {
        return TimeoutContext{
            .timeout_ms = @as(u64, timeout_seconds) * 1000,
            // ISS-0153: std.time.nanoTimestamp() was removed in Zig 0.16.
            .start_time = time_source.currentNanoTimestamp(),
            .timed_out = false,
        };
    }

    /// Check if timeout has been exceeded. Returns error if so.
    pub fn checkTimeout(self: *TimeoutContext) !void {
        if (self.elapsedMs() > self.timeout_ms) {
            self.timed_out = true;
            return error.WallClockTimeoutExceeded;
        }
    }

    /// Get elapsed time in milliseconds.
    pub fn getElapsedMs(self: *const TimeoutContext) u64 {
        return self.elapsedMs();
    }

    /// ISS-0153: the original code used `@divExact(elapsed_ns, 1_000_000)`,
    /// which panics with "exact division produced remainder" for every elapsed
    /// time that is not a whole number of milliseconds — i.e. essentially
    /// always. `@divTrunc` is the correct operation for "how many whole ms have
    /// passed". A clock that runs backwards (NTP step) clamps to 0 rather than
    /// wrapping the unsigned cast.
    fn elapsedMs(self: *const TimeoutContext) u64 {
        const now = time_source.currentNanoTimestamp();
        if (now <= self.start_time) return 0;
        return @divTrunc(@as(u64, @intCast(now - self.start_time)), 1_000_000);
    }

    /// Get configured timeout in milliseconds.
    pub fn getTimeoutMs(self: *const TimeoutContext) u64 {
        return self.timeout_ms;
    }
};

pub const TimeoutError = error{
    WallClockTimeoutExceeded,
};

// ---------------------------------------------------------------------------
// Host-external watchdog (design §2.5.3)
// ---------------------------------------------------------------------------

/// Watchdog poll interval. Bounds worst-case detection latency at ~10ms past
/// the true deadline — negligible against `manifest.Limits.MIN_TIMEOUT_SECONDS`
/// (1000ms). Named explicitly per design §11 item 2 rather than left implicit.
const POLL_INTERVAL_NS: u64 = 10 * std.time.ns_per_ms;

/// Windows kernel32 `Sleep`. Not declared anywhere in this Zig version's
/// `std.os.windows`/`kernel32.zig` (confirmed by reading both files), so it
/// is bound directly here — the same "reach straight into the platform API
/// when std's own wrapper doesn't provide one" pattern `time_source.zig`
/// already uses one line below for `RtlGetSystemTimePrecise`.
extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;

/// Sleep the calling OS thread for `nanos` nanoseconds.
///
/// KNOWN SIGNATURE CORRECTION (CDV-0169-5, flagged in the handoff as a
/// pre-authorized implementation-detail fix, design §11 last paragraph):
/// the design's illustrative watchdog code cited `std.Thread.sleep`, which
/// does not exist in this repo's actual Zig 0.16.0 stdlib (`std.Thread` only
/// exposes `spawn`/`join`/`detach`/`yield`/`getName`/`setName` — confirmed by
/// reading `<zig-lib>/std/Thread.zig`). `std.time.sleep` was also removed.
/// The only sleep left in `std` is `std.Io.sleep`, which takes a different
/// calling convention (`fn sleep(io: Io, duration: Duration, clock: Clock)
/// Cancelable!void`) requiring a threaded `Io` capability that a bare
/// `std.Thread.spawn`-created watchdog thread has no way to obtain.
///
/// First attempt (superseded): `std.c.nanosleep`. It IS declared for every
/// `native_os` including `.windows` (`<zig-lib>/std/c.zig`:
/// `pub const nanosleep = switch (native_os) { .netbsd => ..., else =>
/// private.nanosleep }` — only `mlock`/`munlock`/`mlockall` are
/// windows-excluded in that file, not `nanosleep`), but it does NOT actually
/// work on Windows: `std.c.timespec`'s `.sec` field is typed `std.c.time_t`,
/// and `<zig-lib>/std/c.zig`'s `time_t` definition is `switch (native_os) {
/// ... else => void }` — Windows falls into the `void` branch (no POSIX
/// `time_t` on this target), which made `@intCast(...)` targeting that field
/// a genuine compile error (`expected integer or vector, found 'void'`),
/// caught by `zig build test-lua` rather than escaping to runtime.
///
/// The correct primitive on Windows (this repo's actual build target, per
/// `zig env`) is the Win32 `Sleep` function from `kernel32.dll`, declared
/// above. On POSIX targets, `std.c.nanosleep` genuinely does work (`time_t`
/// resolves to a real integer type there), so it remains the POSIX path —
/// same `builtin.os.tag == .windows` branch shape `time_source.zig` already
/// uses one function above for `currentNanoTimestamp`. This module's build
/// target links libc (`link_libc = true`, same requirement `executor.zig`'s
/// `defaultAlloc` documents for `std.c.malloc`/`realloc`/`free`), so no new
/// build dependency is introduced by the POSIX branch.
fn sleepNanos(nanos: u64) void {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        // Sleep() takes whole milliseconds; round up so a sub-millisecond
        // request still sleeps at least one tick rather than returning
        // immediately (POLL_INTERVAL_NS is 10ms, so this only matters for
        // a hypothetical future caller with a smaller interval).
        const ms: u32 = @intCast((nanos + std.time.ns_per_ms - 1) / std.time.ns_per_ms);
        Sleep(ms);
        return;
    }

    var remaining: std.c.timespec = .{
        .sec = @intCast(nanos / std.time.ns_per_s),
        .nsec = @intCast(nanos % std.time.ns_per_s),
    };
    // A signal-interrupted nanosleep can return early with the remaining
    // time written back; retry until the full duration has elapsed. This
    // loop is bounded in practice because POLL_INTERVAL_NS is tiny (10ms).
    while (true) {
        var rem: std.c.timespec = undefined;
        const rc = std.c.nanosleep(&remaining, &rem);
        if (rc == 0) return;
        remaining = rem;
    }
}

/// Shared deadline-tracking state between the Lua-owning thread and the
/// watchdog thread. Disjoint write sets (INV-6): `fired` is written ONLY by
/// the watchdog thread; `stop_requested` is written ONLY by the owning
/// thread. Neither thread writes what the other writes, so no lock is
/// needed — each thread only ever READS what the other writes.
pub const WatchdogState = struct {
    deadline_ns: std.atomic.Value(i64),
    fired: std.atomic.Value(bool),
    stop_requested: std.atomic.Value(bool),

    pub fn init(timeout_seconds: u32) WatchdogState {
        const now = time_source.currentNanoTimestamp();
        const budget_ns: i64 = @as(i64, timeout_seconds) * std.time.ns_per_s;
        return .{
            .deadline_ns = std.atomic.Value(i64).init(now + budget_ns),
            .fired = std.atomic.Value(bool).init(false),
            .stop_requested = std.atomic.Value(bool).init(false),
        };
    }

    /// Same-thread read of an atomic written by a different thread — this is
    /// exactly the case `.acquire`/`.release` ordering exists for (design
    /// §2.5.4). Safe to call from the Lua-owning thread at any time.
    pub fn hasFired(self: *const WatchdogState) bool {
        return self.fired.load(.acquire);
    }
};

/// Runs on its own `std.Thread`. Touches ONLY `state`'s three atomics —
/// never `L`, never `RunLimiter`/`MemoryLimiter` (INV-6). Polls every
/// `POLL_INTERVAL_NS`; on deadline reached, sets `fired` (release, so the
/// owning thread's subsequent acquire-load observes it) and returns —
/// detection is one-shot. Exits early if `stop_requested` is observed first.
fn watchdogLoop(state: *WatchdogState) void {
    while (true) {
        if (state.stop_requested.load(.acquire)) return;

        const now = time_source.currentNanoTimestamp();
        const deadline = state.deadline_ns.load(.monotonic);
        if (now >= deadline) {
            state.fired.store(true, .release);
            return;
        }

        sleepNanos(POLL_INTERVAL_NS);
    }
}

pub const WatchdogHandle = struct {
    state: *WatchdogState,
    thread: std.Thread,

    /// Caller owns `state` (stack-allocated, must outlive this handle AND the
    /// `lua_State` — same INV-1 shape as `RunLimiter`). Spawn failure
    /// surfaces to the caller as `std.Thread.SpawnError` — see
    /// `executeSource`'s handling in `executor.zig` (design §2.5.3 "Spawn
    /// failure").
    pub fn start(state: *WatchdogState) std.Thread.SpawnError!WatchdogHandle {
        const thread = try std.Thread.spawn(.{}, watchdogLoop, .{state});
        return .{ .state = state, .thread = thread };
    }

    /// Sets `stop_requested` then joins. MUST be called exactly once on
    /// every exit path from `executeSource` (defer-guaranteed, INV-5) — every
    /// run that reaches `start()` also reaches `stop()`, or the thread leaks.
    pub fn stop(self: *WatchdogHandle) void {
        self.state.stop_requested.store(true, .release);
        self.thread.join();
    }
};
