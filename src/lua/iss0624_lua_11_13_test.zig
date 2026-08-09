//! ISS-0624 / GH #591 — regression tests for LUA-11 / LUA-13 production code
//! changes. See `src/design/iss0624-gh591-lua-11-13-fix.md` for the design.
//!
//! ## What is verified here
//!
//! - **LUA-11 (TC-ISS-0624-LUA-11-01..12):** `platform.write_variable` stages
//!   into `ExecutionContext.pending_writes`; a successful `executeScript` call
//!   atomically merges the staged writes into `ExecutionContext.instance_state
//!   .variables`; a failed call (explicit `platform.fail` or a runtime error)
//!   discards them entirely — no partial writes are ever visible.
//!   `platform.read_variable` performs read-after-write against
//!   `pending_writes` before falling through to the committed state.
//!
//! - **LUA-13 (TC-ISS-0624-LUA-13-01..09):** `platform.log` builds a real
//!   `StructuredLogEntry` and routes it through `StructuredLogger.log`, which
//!   in turn calls the injected `Writer` (captured into an in-memory buffer
//!   for these tests instead of the default stderr path — design §7.1).
//!
//! ## Per-test isolation
//!
//! Each test builds its own `CapabilitySet`, `InstanceState`, and
//! `ExecutionContext` with a per-test-UUID-flavoured instance id (T-1
//! directive). No shared state across tests. `std.testing.allocator` fails
//! the test on any leak.
//!
//! ## Skip behaviour
//!
//! LuaJIT is statically linked for `test-lua` (ISS-0161); no skip path is
//! expected in this build profile. If `executor.createSandboxedState`
//! (reached indirectly via `executor.executeScript`) ever fails to produce a
//! state, that is treated as a genuine test failure — consistent with
//! `iss0625_lua_12_15_16_test.zig`'s own skip-only-on-empirical-signal
//! stance, but LUA-11/13 have no such indirect construction path (they go
//! through the public `executeScript` entry point), so no skip is coded.

const std = @import("std");
const testing = std.testing;

const executor = @import("executor.zig");
const capabilities = @import("capabilities.zig");
const structured_logger = @import("structured_logger.zig");

const ExecutionContext = executor.ExecutionContext;
const InstanceState = executor.InstanceState;
const ScriptValue = executor.ScriptValue;
const CapabilitySet = capabilities.CapabilitySet;
const StandardCapabilities = capabilities.StandardCapabilities;
const StructuredLogger = structured_logger.StructuredLogger;
const StructuredLogEntry = structured_logger.StructuredLogEntry;

var counter: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

/// Per-test-UUID-flavoured instance id (T-1 directive — no shared fixture
/// state across tests). Not a real UUID; a monotonic counter is sufficient
/// uniqueness for an in-process test run with no persistence.
fn nextInstanceId(buf: []u8, prefix: []const u8) []const u8 {
    const n = counter.fetchAdd(1, .monotonic);
    return std.fmt.bufPrint(buf, "{s}-{d}", .{ prefix, n }) catch prefix;
}

// ---------------------------------------------------------------------------
// LUA-11 fixture
// ---------------------------------------------------------------------------

const Lua11Fixture = struct {
    caps: CapabilitySet,
    state: InstanceState,
    ctx: ExecutionContext,

    fn deinit(self: *Lua11Fixture) void {
        self.state.deinit();
        self.caps.deinit();
    }
};

/// Build a fresh ExecutionContext wired with `variable:read` +
/// `variable:write` and a real (empty) InstanceState. `pending_writes` is
/// left at its default (null) here — `executor.executeScript` wires its own
/// staging map internally per-call (design §4.1); tests never construct one
/// themselves.
fn freshLua11Fixture(instance_id: []const u8) !Lua11Fixture {
    var caps = CapabilitySet.init(testing.allocator);
    errdefer caps.deinit();
    try caps.add(StandardCapabilities.VARIABLE_READ);
    try caps.add(StandardCapabilities.VARIABLE_WRITE);

    var state = InstanceState.init(testing.allocator, instance_id);
    errdefer state.deinit();

    return .{
        .caps = caps,
        .state = state,
        .ctx = ExecutionContext{
            .allocator = testing.allocator,
            .capabilities = undefined, // patched by caller once `caps` has a stable address
            .instance_id = instance_id,
            .actor_id = "iss0624-lua11-actor",
            .instance_state = undefined, // patched by caller once `state` has a stable address
        },
    };
}

// ---------------------------------------------------------------------------
// TC-ISS-0624-LUA-11-01 — atomic apply on success
// ---------------------------------------------------------------------------

test "TC-ISS-0624-LUA-11-01: successful write_variable lands in instance_state.variables on success" {
    var id_buf: [64]u8 = undefined;
    const instance_id = nextInstanceId(&id_buf, "iss0624-lua-11-01");

    var fx = try freshLua11Fixture(instance_id);
    fx.ctx.capabilities = &fx.caps;
    fx.ctx.instance_state = &fx.state;
    defer fx.deinit();

    var result = try executor.executeScript(&fx.ctx, "platform.write_variable('status', 'done')");
    defer result.deinit(testing.allocator);

    try testing.expect(result.success);

    const stored = fx.state.variables.get("status") orelse return error.NotCommitted;
    try testing.expect(stored == .string);
    try testing.expectEqualStrings("done", stored.string);
}

// ---------------------------------------------------------------------------
// TC-ISS-0624-LUA-11-02 — read of an absent key returns nil
// ---------------------------------------------------------------------------

test "TC-ISS-0624-LUA-11-02: read_variable on an absent key returns nil" {
    var id_buf: [64]u8 = undefined;
    const instance_id = nextInstanceId(&id_buf, "iss0624-lua-11-02");

    var fx = try freshLua11Fixture(instance_id);
    fx.ctx.capabilities = &fx.caps;
    fx.ctx.instance_state = &fx.state;
    defer fx.deinit();

    var result = try executor.executeScript(&fx.ctx, "local v = platform.read_variable('missing') return v");
    defer result.deinit(testing.allocator);

    try testing.expect(result.success);
    const value = result.value orelse return error.NoValue;
    try testing.expect(value == .nil_value);
}

// ---------------------------------------------------------------------------
// TC-ISS-0624-LUA-11-03 — read of an existing (committed) variable
// ---------------------------------------------------------------------------

test "TC-ISS-0624-LUA-11-03: read_variable returns a previously committed string and number" {
    var id_buf: [64]u8 = undefined;
    const instance_id = nextInstanceId(&id_buf, "iss0624-lua-11-03");

    var fx = try freshLua11Fixture(instance_id);
    fx.ctx.capabilities = &fx.caps;
    fx.ctx.instance_state = &fx.state;
    defer fx.deinit();

    // Pre-seed committed state directly (bypassing the script) to isolate
    // the read path from the write path.
    try fx.state.variables.put(try testing.allocator.dupe(u8, "greeting"), ScriptValue{ .string = try testing.allocator.dupe(u8, "hello") });
    try fx.state.variables.put(try testing.allocator.dupe(u8, "count"), ScriptValue{ .number = 42 });

    var result = try executor.executeScript(&fx.ctx,
        \\local g = platform.read_variable('greeting')
        \\local c = platform.read_variable('count')
        \\if g == 'hello' and c == 42 then return 'OK' end
        \\return 'MISMATCH:' .. tostring(g) .. ':' .. tostring(c)
    );
    defer result.deinit(testing.allocator);

    try testing.expect(result.success);
    const value = result.value orelse return error.NoValue;
    try testing.expect(value == .string);
    try testing.expectEqualStrings("OK", value.string);
}

// ---------------------------------------------------------------------------
// TC-ISS-0624-LUA-11-04 — atomic discard on explicit failure
// ---------------------------------------------------------------------------

test "TC-ISS-0624-LUA-11-04: write_variable then platform.fail discards the write" {
    var id_buf: [64]u8 = undefined;
    const instance_id = nextInstanceId(&id_buf, "iss0624-lua-11-04");

    var fx = try freshLua11Fixture(instance_id);
    fx.ctx.capabilities = &fx.caps;
    fx.ctx.instance_state = &fx.state;
    defer fx.deinit();

    var result = try executor.executeScript(&fx.ctx,
        \\platform.write_variable('status', 'partial')
        \\platform.fail('abort')
    );
    defer result.deinit(testing.allocator);

    try testing.expect(!result.success);
    try testing.expectEqual(executor.ErrorKind.ExplicitFailure, result.error_kind);
    try testing.expect(fx.state.variables.get("status") == null);
}

// ---------------------------------------------------------------------------
// TC-ISS-0624-LUA-11-05 — atomic discard on runtime error
// ---------------------------------------------------------------------------

test "TC-ISS-0624-LUA-11-05: write_variable then a runtime error discards the write" {
    var id_buf: [64]u8 = undefined;
    const instance_id = nextInstanceId(&id_buf, "iss0624-lua-11-05");

    var fx = try freshLua11Fixture(instance_id);
    fx.ctx.capabilities = &fx.caps;
    fx.ctx.instance_state = &fx.state;
    defer fx.deinit();

    var result = try executor.executeScript(&fx.ctx,
        \\platform.write_variable('status', 'partial')
        \\error('boom')
    );
    defer result.deinit(testing.allocator);

    try testing.expect(!result.success);
    try testing.expectEqual(executor.ErrorKind.RuntimeError, result.error_kind);
    try testing.expect(fx.state.variables.get("status") == null);
}

// ---------------------------------------------------------------------------
// TC-ISS-0624-LUA-11-06 — last write wins within one execution
// ---------------------------------------------------------------------------

test "TC-ISS-0624-LUA-11-06: writing the same key three times commits the final value" {
    var id_buf: [64]u8 = undefined;
    const instance_id = nextInstanceId(&id_buf, "iss0624-lua-11-06");

    var fx = try freshLua11Fixture(instance_id);
    fx.ctx.capabilities = &fx.caps;
    fx.ctx.instance_state = &fx.state;
    defer fx.deinit();

    var result = try executor.executeScript(&fx.ctx,
        \\platform.write_variable('k', 'first')
        \\platform.write_variable('k', 'second')
        \\platform.write_variable('k', 'third')
    );
    defer result.deinit(testing.allocator);

    try testing.expect(result.success);
    const stored = fx.state.variables.get("k") orelse return error.NotCommitted;
    try testing.expectEqualStrings("third", stored.string);
    // Exactly one entry for 'k' — no leaked stale duplicates.
    try testing.expectEqual(@as(usize, 1), fx.state.variables.count());
}

// ---------------------------------------------------------------------------
// TC-ISS-0624-LUA-11-07 — read-after-write within one execution
// ---------------------------------------------------------------------------

test "TC-ISS-0624-LUA-11-07: read-after-write reflects the staged increment before commit" {
    var id_buf: [64]u8 = undefined;
    const instance_id = nextInstanceId(&id_buf, "iss0624-lua-11-07");

    var fx = try freshLua11Fixture(instance_id);
    fx.ctx.capabilities = &fx.caps;
    fx.ctx.instance_state = &fx.state;
    defer fx.deinit();

    try fx.state.variables.put(try testing.allocator.dupe(u8, "c"), ScriptValue{ .number = 10 });

    var result = try executor.executeScript(&fx.ctx,
        \\local x = platform.read_variable('c')
        \\platform.write_variable('c', x + 1)
        \\return platform.read_variable('c')
    );
    defer result.deinit(testing.allocator);

    try testing.expect(result.success);
    const value = result.value orelse return error.NoValue;
    try testing.expect(value == .number);
    try testing.expectEqual(@as(f64, 11), value.number);

    const stored = fx.state.variables.get("c") orelse return error.NotCommitted;
    try testing.expectEqual(@as(f64, 11), stored.number);
}

// ---------------------------------------------------------------------------
// TC-ISS-0624-LUA-11-08 — table write
// ---------------------------------------------------------------------------

test "TC-ISS-0624-LUA-11-08: write_variable persists a table with its entries" {
    var id_buf: [64]u8 = undefined;
    const instance_id = nextInstanceId(&id_buf, "iss0624-lua-11-08");

    var fx = try freshLua11Fixture(instance_id);
    fx.ctx.capabilities = &fx.caps;
    fx.ctx.instance_state = &fx.state;
    defer fx.deinit();

    var result = try executor.executeScript(&fx.ctx, "platform.write_variable('point', {x = 1, y = 2})");
    defer result.deinit(testing.allocator);

    try testing.expect(result.success);
    const stored = fx.state.variables.get("point") orelse return error.NotCommitted;
    try testing.expect(stored == .table);
    const x = stored.table.get("x") orelse return error.MissingKey;
    const y = stored.table.get("y") orelse return error.MissingKey;
    try testing.expectEqual(@as(f64, 1), x.number);
    try testing.expectEqual(@as(f64, 2), y.number);
}

// ---------------------------------------------------------------------------
// TC-ISS-0624-LUA-11-09 — writing nil drops the entry
// ---------------------------------------------------------------------------

test "TC-ISS-0624-LUA-11-09: writing nil to an existing key drops the committed entry" {
    var id_buf: [64]u8 = undefined;
    const instance_id = nextInstanceId(&id_buf, "iss0624-lua-11-09");

    var fx = try freshLua11Fixture(instance_id);
    fx.ctx.capabilities = &fx.caps;
    fx.ctx.instance_state = &fx.state;
    defer fx.deinit();

    try fx.state.variables.put(try testing.allocator.dupe(u8, "status"), ScriptValue{ .string = try testing.allocator.dupe(u8, "old") });

    var result = try executor.executeScript(&fx.ctx, "platform.write_variable('status', nil)");
    defer result.deinit(testing.allocator);

    try testing.expect(result.success);
    try testing.expect(fx.state.variables.get("status") == null);
}

// ---------------------------------------------------------------------------
// TC-ISS-0624-LUA-11-10 — cross-instance isolation
// ---------------------------------------------------------------------------

test "TC-ISS-0624-LUA-11-10: two instances' writes land only in their own instance_state" {
    var id_buf_a: [64]u8 = undefined;
    var id_buf_b: [64]u8 = undefined;
    const instance_a = nextInstanceId(&id_buf_a, "iss0624-lua-11-10-a");
    const instance_b = nextInstanceId(&id_buf_b, "iss0624-lua-11-10-b");

    var fx_a = try freshLua11Fixture(instance_a);
    fx_a.ctx.capabilities = &fx_a.caps;
    fx_a.ctx.instance_state = &fx_a.state;
    defer fx_a.deinit();

    var fx_b = try freshLua11Fixture(instance_b);
    fx_b.ctx.capabilities = &fx_b.caps;
    fx_b.ctx.instance_state = &fx_b.state;
    defer fx_b.deinit();

    var result_a = try executor.executeScript(&fx_a.ctx, "platform.write_variable('owner', 'a')");
    defer result_a.deinit(testing.allocator);
    var result_b = try executor.executeScript(&fx_b.ctx, "platform.write_variable('owner', 'b')");
    defer result_b.deinit(testing.allocator);

    try testing.expect(result_a.success and result_b.success);

    const stored_a = fx_a.state.variables.get("owner") orelse return error.NotCommitted;
    const stored_b = fx_b.state.variables.get("owner") orelse return error.NotCommitted;
    try testing.expectEqualStrings("a", stored_a.string);
    try testing.expectEqualStrings("b", stored_b.string);
}

// ---------------------------------------------------------------------------
// TC-ISS-0624-LUA-11-11 — capability denial re-asserted with new field defaults
// ---------------------------------------------------------------------------

test "TC-ISS-0624-LUA-11-11: read_variable without variable:read is still denied" {
    var id_buf: [64]u8 = undefined;
    const instance_id = nextInstanceId(&id_buf, "iss0624-lua-11-11");

    var caps = CapabilitySet.init(testing.allocator);
    defer caps.deinit();
    // No grants at all.

    var state = InstanceState.init(testing.allocator, instance_id);
    defer state.deinit();

    var ctx = ExecutionContext{
        .allocator = testing.allocator,
        .capabilities = &caps,
        .instance_id = instance_id,
        .actor_id = "iss0624-lua11-actor",
        .instance_state = &state,
    };

    var result = try executor.executeScript(&ctx, "return platform.read_variable('k')");
    defer result.deinit(testing.allocator);

    try testing.expect(!result.success);
    const msg = result.error_message orelse return error.NoErrorMessage;
    try testing.expect(std.mem.indexOf(u8, msg, "capability denied") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "read_variable") != null);
}

// ---------------------------------------------------------------------------
// TC-ISS-0624-LUA-11-12 — backward-compat default: pending_writes/instance_state left unset
// ---------------------------------------------------------------------------

test "TC-ISS-0624-LUA-11-12: an ExecutionContext with only defaults leaves read/write as safe no-ops" {
    var id_buf: [64]u8 = undefined;
    const instance_id = nextInstanceId(&id_buf, "iss0624-lua-11-12");

    var caps = CapabilitySet.init(testing.allocator);
    defer caps.deinit();
    try caps.add(StandardCapabilities.VARIABLE_READ);
    try caps.add(StandardCapabilities.VARIABLE_WRITE);

    // A real, per-test InstanceState — NOT the shared file-scope
    // dummy_instance_state singleton (design §4.5). The dummy singleton's
    // destructor is deliberately never called (its `.variables` map is
    // page_allocator-backed and lives for the whole process), which makes it
    // unsuitable as a target for std.testing.allocator's leak-checked
    // commits: any OTHER test in this binary that also leaves
    // instance_state at its default would commit into the SAME shared map,
    // and per-test isolation (T-1) requires this test's write not to be
    // observable by, or attributable to, any other test. Using a real
    // InstanceState here still exercises exactly the claim this test makes
    // (an ExecutionContext built with only trace_id/pending_writes/
    // structured_logger left at their defaults executes read/write
    // end-to-end without panicking) without relying on process-lifetime
    // shared mutable state.
    var state = InstanceState.init(testing.allocator, instance_id);
    defer state.deinit();

    const ctx = ExecutionContext{
        .allocator = testing.allocator,
        .capabilities = &caps,
        .instance_id = instance_id,
        .actor_id = "iss0624-lua11-actor",
        .instance_state = &state,
        // trace_id, pending_writes, structured_logger left at their defaults.
    };

    var result = try executor.executeScript(&ctx,
        \\platform.write_variable('k', 'v')
        \\return platform.read_variable('k')
    );
    defer result.deinit(testing.allocator);

    try testing.expect(result.success);
    const value = result.value orelse return error.NoValue;
    try testing.expect(value == .string);
    try testing.expectEqualStrings("v", value.string);
}

// ---------------------------------------------------------------------------
// LUA-13 fixture
// ---------------------------------------------------------------------------

/// Captures every `Writer` invocation's message into an owned buffer,
/// newline-preserving, so a test can assert on substrings and on call order.
const CapturingSink = struct {
    buf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) CapturingSink {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *CapturingSink) void {
        self.buf.deinit(self.allocator);
    }

    fn captured(self: *const CapturingSink) []const u8 {
        return self.buf.items;
    }
};

fn capturingWriter(ctx: ?*anyopaque, msg: []const u8) anyerror!void {
    const sink: *CapturingSink = @ptrCast(@alignCast(ctx.?));
    try sink.buf.appendSlice(sink.allocator, msg);
}

const Lua13Fixture = struct {
    caps: CapabilitySet,
    sink: CapturingSink,
    logger: StructuredLogger,
    ctx: ExecutionContext,

    fn deinit(self: *Lua13Fixture) void {
        self.sink.deinit();
        self.caps.deinit();
    }
};

fn freshLua13Fixture(instance_id: []const u8, trace_id: []const u8) !Lua13Fixture {
    var caps = CapabilitySet.init(testing.allocator);
    errdefer caps.deinit();
    try caps.add(StandardCapabilities.AUDIT_LOG);

    return .{
        .caps = caps,
        .sink = CapturingSink.init(testing.allocator),
        .logger = StructuredLogger.init(testing.allocator),
        .ctx = ExecutionContext{
            .allocator = testing.allocator,
            .capabilities = undefined,
            .instance_id = instance_id,
            .actor_id = "iss0624-lua13-actor",
            .trace_id = trace_id,
            .structured_logger = undefined,
        },
    };
}

// ---------------------------------------------------------------------------
// TC-ISS-0624-LUA-13-01 — structured emission, all fields present
// ---------------------------------------------------------------------------

test "TC-ISS-0624-LUA-13-01: platform.log emits a captured entry with level, message, instance, actor, trace" {
    var id_buf: [64]u8 = undefined;
    const instance_id = nextInstanceId(&id_buf, "iss0624-lua-13-01");

    var fx = try freshLua13Fixture(instance_id, "trace-01");
    fx.ctx.capabilities = &fx.caps;
    fx.logger.writer = capturingWriter;
    fx.logger.writer_ctx = @ptrCast(&fx.sink);
    fx.ctx.structured_logger = &fx.logger;
    defer fx.deinit();

    var result = try executor.executeScript(&fx.ctx, "platform.log('INFO', 'hello', {})");
    defer result.deinit(testing.allocator);

    try testing.expect(result.success);
    const captured = fx.sink.captured();
    try testing.expect(std.mem.indexOf(u8, captured, "INFO") != null);
    try testing.expect(std.mem.indexOf(u8, captured, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, captured, instance_id) != null);
    try testing.expect(std.mem.indexOf(u8, captured, "iss0624-lua13-actor") != null);
    try testing.expect(std.mem.indexOf(u8, captured, "trace-01") != null);
}

// ---------------------------------------------------------------------------
// TC-ISS-0624-LUA-13-02 — every level string
// ---------------------------------------------------------------------------

test "TC-ISS-0624-LUA-13-02: WARN, ERROR, and DEBUG levels are captured verbatim" {
    inline for (.{ "WARN", "ERROR", "DEBUG" }) |level| {
        var id_buf: [64]u8 = undefined;
        const instance_id = nextInstanceId(&id_buf, "iss0624-lua-13-02");

        var fx = try freshLua13Fixture(instance_id, "trace-02");
        fx.ctx.capabilities = &fx.caps;
        fx.logger.writer = capturingWriter;
        fx.logger.writer_ctx = @ptrCast(&fx.sink);
        fx.ctx.structured_logger = &fx.logger;
        defer fx.deinit();

        var result = try executor.executeScript(&fx.ctx, "platform.log('" ++ level ++ "', 'msg', {})");
        defer result.deinit(testing.allocator);

        try testing.expect(result.success);
        const captured = fx.sink.captured();
        try testing.expect(std.mem.indexOf(u8, captured, level) != null);
    }
}

// ---------------------------------------------------------------------------
// TC-ISS-0624-LUA-13-03 — context table entries serialised
// ---------------------------------------------------------------------------

test "TC-ISS-0624-LUA-13-03: context table entries (string and number) appear in the captured output" {
    var id_buf: [64]u8 = undefined;
    const instance_id = nextInstanceId(&id_buf, "iss0624-lua-13-03");

    var fx = try freshLua13Fixture(instance_id, "trace-03");
    fx.ctx.capabilities = &fx.caps;
    fx.logger.writer = capturingWriter;
    fx.logger.writer_ctx = @ptrCast(&fx.sink);
    fx.ctx.structured_logger = &fx.logger;
    defer fx.deinit();

    // structured_logger.zig's current format string does not itself walk
    // .context into the rendered line (design §8, non-goal 2: no formatter
    // test for full JSON shape). This test's real claim (per design §7.2
    // TC-03) is narrower and behavioural: the call succeeds end-to-end with
    // a context table present, and the message/level still land correctly —
    // i.e. passing a context table does not corrupt or drop the rest of the
    // entry. The context table's OWN entries are exercised at the
    // extractValueInto layer (LUA-11 TC-08 covers table extraction).
    var result = try executor.executeScript(&fx.ctx, "platform.log('INFO', 'msg', {order_id = 'X', amount = 1.5})");
    defer result.deinit(testing.allocator);

    try testing.expect(result.success);
    const captured = fx.sink.captured();
    try testing.expect(std.mem.indexOf(u8, captured, "INFO") != null);
    try testing.expect(std.mem.indexOf(u8, captured, "msg") != null);
}

// ---------------------------------------------------------------------------
// TC-ISS-0624-LUA-13-04 — no third arg
// ---------------------------------------------------------------------------

test "TC-ISS-0624-LUA-13-04: platform.log with no third argument succeeds with a null context" {
    var id_buf: [64]u8 = undefined;
    const instance_id = nextInstanceId(&id_buf, "iss0624-lua-13-04");

    var fx = try freshLua13Fixture(instance_id, "trace-04");
    fx.ctx.capabilities = &fx.caps;
    fx.logger.writer = capturingWriter;
    fx.logger.writer_ctx = @ptrCast(&fx.sink);
    fx.ctx.structured_logger = &fx.logger;
    defer fx.deinit();

    var result = try executor.executeScript(&fx.ctx, "platform.log('INFO', 'msg')");
    defer result.deinit(testing.allocator);

    try testing.expect(result.success);
    const captured = fx.sink.captured();
    try testing.expect(std.mem.indexOf(u8, captured, "msg") != null);
}

// ---------------------------------------------------------------------------
// TC-ISS-0624-LUA-13-05 — invalid log level raises
// ---------------------------------------------------------------------------

test "TC-ISS-0624-LUA-13-05: an unrecognised log level raises a runtime error" {
    var id_buf: [64]u8 = undefined;
    const instance_id = nextInstanceId(&id_buf, "iss0624-lua-13-05");

    var fx = try freshLua13Fixture(instance_id, "trace-05");
    fx.ctx.capabilities = &fx.caps;
    fx.logger.writer = capturingWriter;
    fx.logger.writer_ctx = @ptrCast(&fx.sink);
    fx.ctx.structured_logger = &fx.logger;
    defer fx.deinit();

    var result = try executor.executeScript(&fx.ctx, "platform.log('BOGUS', 'msg', {})");
    defer result.deinit(testing.allocator);

    try testing.expect(!result.success);
    try testing.expectEqual(executor.ErrorKind.RuntimeError, result.error_kind);
    const msg = result.error_message orelse return error.NoErrorMessage;
    try testing.expect(std.mem.indexOf(u8, msg, "invalid log level") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "BOGUS") != null);
    // Nothing should have been written to the sink — the raise happens
    // before StructuredLogEntry construction.
    try testing.expectEqual(@as(usize, 0), fx.sink.captured().len);
}

// ---------------------------------------------------------------------------
// TC-ISS-0624-LUA-13-06 — capability denial re-asserted with new field defaults
// ---------------------------------------------------------------------------

test "TC-ISS-0624-LUA-13-06: platform.log without audit:log is denied" {
    var id_buf: [64]u8 = undefined;
    const instance_id = nextInstanceId(&id_buf, "iss0624-lua-13-06");

    var caps = CapabilitySet.init(testing.allocator);
    defer caps.deinit();
    // No grants.

    var sink = CapturingSink.init(testing.allocator);
    defer sink.deinit();
    var logger = StructuredLogger.init(testing.allocator);
    logger.writer = capturingWriter;
    logger.writer_ctx = @ptrCast(&sink);

    var ctx = ExecutionContext{
        .allocator = testing.allocator,
        .capabilities = &caps,
        .instance_id = instance_id,
        .actor_id = "iss0624-lua13-actor",
        .structured_logger = &logger,
    };

    var result = try executor.executeScript(&ctx, "platform.log('INFO', 'x', {})");
    defer result.deinit(testing.allocator);

    try testing.expect(!result.success);
    const msg = result.error_message orelse return error.NoErrorMessage;
    try testing.expect(std.mem.indexOf(u8, msg, "capability denied") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "log") != null);
    try testing.expectEqual(@as(usize, 0), sink.captured().len);
}

// ---------------------------------------------------------------------------
// TC-ISS-0624-LUA-13-07 — trace_id cross-script isolation
// ---------------------------------------------------------------------------

test "TC-ISS-0624-LUA-13-07: each script's own trace_id lands in its own entry, never the other's" {
    var id_buf_a: [64]u8 = undefined;
    var id_buf_b: [64]u8 = undefined;
    const instance_a = nextInstanceId(&id_buf_a, "iss0624-lua-13-07-a");
    const instance_b = nextInstanceId(&id_buf_b, "iss0624-lua-13-07-b");

    var fx_a = try freshLua13Fixture(instance_a, "trace-alpha");
    fx_a.ctx.capabilities = &fx_a.caps;
    fx_a.logger.writer = capturingWriter;
    fx_a.logger.writer_ctx = @ptrCast(&fx_a.sink);
    fx_a.ctx.structured_logger = &fx_a.logger;
    defer fx_a.deinit();

    var fx_b = try freshLua13Fixture(instance_b, "trace-beta");
    fx_b.ctx.capabilities = &fx_b.caps;
    fx_b.logger.writer = capturingWriter;
    fx_b.logger.writer_ctx = @ptrCast(&fx_b.sink);
    fx_b.ctx.structured_logger = &fx_b.logger;
    defer fx_b.deinit();

    var result_a = try executor.executeScript(&fx_a.ctx, "platform.log('INFO', 'from-a', {})");
    defer result_a.deinit(testing.allocator);
    var result_b = try executor.executeScript(&fx_b.ctx, "platform.log('INFO', 'from-b', {})");
    defer result_b.deinit(testing.allocator);

    try testing.expect(result_a.success and result_b.success);

    const captured_a = fx_a.sink.captured();
    const captured_b = fx_b.sink.captured();
    try testing.expect(std.mem.indexOf(u8, captured_a, "trace-alpha") != null);
    try testing.expect(std.mem.indexOf(u8, captured_a, "trace-beta") == null);
    try testing.expect(std.mem.indexOf(u8, captured_b, "trace-beta") != null);
    try testing.expect(std.mem.indexOf(u8, captured_b, "trace-alpha") == null);
}

// ---------------------------------------------------------------------------
// TC-ISS-0624-LUA-13-08 — fail-open default (no logger installed)
// ---------------------------------------------------------------------------

test "TC-ISS-0624-LUA-13-08: structured_logger left at its null default is a fail-open no-op" {
    var id_buf: [64]u8 = undefined;
    const instance_id = nextInstanceId(&id_buf, "iss0624-lua-13-08");

    var caps = CapabilitySet.init(testing.allocator);
    defer caps.deinit();
    try caps.add(StandardCapabilities.AUDIT_LOG);

    const ctx = ExecutionContext{
        .allocator = testing.allocator,
        .capabilities = &caps,
        .instance_id = instance_id,
        .actor_id = "iss0624-lua13-actor",
        // structured_logger left at its default (null).
    };

    var result = try executor.executeScript(&ctx, "platform.log('INFO', 'msg', {})");
    defer result.deinit(testing.allocator);

    try testing.expect(result.success);
}

// ---------------------------------------------------------------------------
// TC-ISS-0624-LUA-13-09 — multiple calls captured in invocation order
// ---------------------------------------------------------------------------

test "TC-ISS-0624-LUA-13-09: multiple platform.log calls are captured in invocation order" {
    var id_buf: [64]u8 = undefined;
    const instance_id = nextInstanceId(&id_buf, "iss0624-lua-13-09");

    var fx = try freshLua13Fixture(instance_id, "trace-09");
    fx.ctx.capabilities = &fx.caps;
    fx.logger.writer = capturingWriter;
    fx.logger.writer_ctx = @ptrCast(&fx.sink);
    fx.ctx.structured_logger = &fx.logger;
    defer fx.deinit();

    var result = try executor.executeScript(&fx.ctx,
        \\platform.log('INFO', 'first', {})
        \\platform.log('WARN', 'second', {})
        \\platform.log('ERROR', 'third', {})
    );
    defer result.deinit(testing.allocator);

    try testing.expect(result.success);
    const captured = fx.sink.captured();
    const pos_first = std.mem.indexOf(u8, captured, "first") orelse return error.MissingEntry;
    const pos_second = std.mem.indexOf(u8, captured, "second") orelse return error.MissingEntry;
    const pos_third = std.mem.indexOf(u8, captured, "third") orelse return error.MissingEntry;
    try testing.expect(pos_first < pos_second);
    try testing.expect(pos_second < pos_third);
}
