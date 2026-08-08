const std = @import("std");
const types = @import("types.zig");
const mock_catalog_mod = @import("mock_catalog.zig");

pub const ServiceMockCatalog = mock_catalog_mod.ServiceMockCatalog;

pub fn executeMockedServiceCall(
    allocator: std.mem.Allocator,
    ctx: *const types.SimulationContext,
    catalog: *const ServiceMockCatalog,
    service_key: []const u8,
    request: types.ServiceRequest,
) types.SimulationError!types.MockResponse {
    if (ctx.seed.uuid_seed == 0) return error.InvalidSimulationContext;
    if (!isValidServiceKey(service_key)) return error.InvalidServiceKey;
    if (!isValidFingerprint(request.request_fingerprint)) return error.InvalidRequestFingerprint;

    // `catalog.resolve` clones its stored response using the CATALOG's own
    // allocator (`ServiceMockCatalog.init`'s allocator), not this function's
    // `allocator` parameter — the two are frequently different (e.g.
    // `call_service.zig`'s simulation path uses `std.heap.page_allocator`
    // while a test-constructed catalog typically uses `std.testing.allocator`).
    // Discovered via ISS-0169 tranche 2 (limiter_wiring_test.zig
    // TC-LUA-10-02): a caller that frees the returned `MockResponse` with its
    // own allocator (exactly what `response.deinit(allocator)` in
    // `platformCallService` does, and always did) corrupts the allocator's
    // internal state on free because the memory was never owned by that
    // allocator. `allocator` was previously discarded entirely (`_ =
    // allocator;`), which is what let this mismatch go unnoticed — nothing in
    // this codebase exercised the simulation path against a real activated
    // `simulation_runtime` before this test existed. The re-clone below makes
    // the returned `MockResponse` genuinely owned by the CALLER's allocator,
    // matching every other caller-owns-the-allocator contract in this module
    // family (e.g. `computeFingerprint` in call_service.zig).
    const catalog_owned = try catalog.resolve(service_key, request.request_fingerprint);
    defer catalog_owned.deinit(catalog.allocator);
    const response = catalog_owned.clone(allocator) catch return error.OutOfMemory;

    // ISS-0169 / GH #495 tranche 2, design §5.4 / §11 item 3: honour a
    // test-only artificial delay so TC-LUA-10-02 (limiter_wiring_test.zig)
    // can exercise "a host function call that takes real wall-clock time"
    // without LUA-12's real HTTP client existing yet. Zero (the field's
    // default) is a same-tick no-op, matching every other simulation test's
    // existing behaviour exactly. This module is compiled both with and
    // without `link_libc` (see simulation_test_root.zig vs lua_test_root.zig
    // in build.zig), so the wait below deliberately does NOT reach into
    // libc — it polls the same NTDLL/POSIX wall-clock primitive
    // `scenario_runner.zig`'s `currentMillisecondTimestamp` already uses
    // without a libc dependency.
    if (response.delay_ms > 0) {
        waitMs(response.delay_ms);
    }

    return response;
}

/// Busy-poll (yielding the OS thread between checks) until `ms` milliseconds
/// of real wall-clock time have elapsed. No libc dependency and no
/// `std.Thread.sleep` (does not exist in this Zig version — see
/// `src/lua/timeout.zig`'s `sleepNanos` for the full investigation of the
/// same constraint in the production watchdog). This is test-only code
/// reached solely through `MockResponse.delay_ms`, which no production
/// caller ever sets, so busy-polling's CPU cost is acceptable here.
fn waitMs(ms: u32) void {
    const deadline = currentMillisecondTimestamp() + @as(i64, ms);
    while (currentMillisecondTimestamp() < deadline) {
        std.Thread.yield() catch {};
    }
}

fn currentMillisecondTimestamp() i64 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const ft: i64 = windows.ntdll.RtlGetSystemTimePrecise();
        const unix_100ns: i64 = ft - 116_444_736_000_000_000;
        return @divTrunc(unix_100ns, 10_000);
    }

    const posix = std.posix;
    var ts: posix.timespec = undefined;
    _ = posix.system.clock_gettime(.REALTIME, &ts);
    const sec_ms: i64 = ts.sec * 1000;
    const nsec_ms: i64 = @divTrunc(ts.nsec, 1_000_000);
    return sec_ms + nsec_ms;
}

fn isValidServiceKey(s: []const u8) bool {
    if (s.len == 0 or s.len > 128) return false;
    if (!(std.ascii.isLower(s[0]) or std.ascii.isDigit(s[0]))) return false;

    for (s) |c| {
        if (std.ascii.isLower(c) or std.ascii.isDigit(c)) continue;
        if (c == '.' or c == '_' or c == '-') continue;
        return false;
    }
    return true;
}

fn isValidFingerprint(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!is_hex) return false;
    }
    return true;
}
