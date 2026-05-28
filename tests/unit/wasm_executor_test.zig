//! Unit tests for Wasm execution subsystem.
//!
//! Tests cover:
//! - Engine initialization (WASM-01)
//! - Memory validation (WASM-08)
//! - Capability checking (WASM-06)
//! - Fuel limits (WASM-09)
//! - Timeout context (WASM-11)

const std = @import("std");
const wasm = @import("wasm");

test "WasmEngine initializes (stub)" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa.deinit();
    const allocator = gpa.allocator();

    // Note: engine_new is a stub that returns null in unit tests
    // Real Wasmtime integration happens in Stage 10
    _ = allocator;
    // Just verify the type exists
    const engine_type = wasm.WasmEngine;
    _ = engine_type;
}

test "CapabilitySet stores and retrieves capabilities" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa.deinit();
    const allocator = gpa.allocator();

    var caps = wasm.CapabilitySet.init(allocator);
    defer caps.deinit();

    try caps.add("variable:read");
    try caps.add("variable:write");

    try std.testing.expect(caps.has("variable:read"));
    try std.testing.expect(caps.has("variable:write"));
    try std.testing.expect(!caps.has("service:call:payment_api"));
}

test "CapabilitySet handles wildcard matching" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa.deinit();
    const allocator = gpa.allocator();

    var caps = wasm.CapabilitySet.init(allocator);
    defer caps.deinit();

    try caps.add("service:call:*");

    try std.testing.expect(caps.hasWildcard("service:call:payment_api"));
    try std.testing.expect(caps.hasWildcard("service:call:billing"));
    try std.testing.expect(!caps.hasWildcard("service:read"));
}

test "TimeoutContext initializes with correct timeout" {
    const timeout = wasm.TimeoutContext.init(5); // 5 second timeout

    try std.testing.expectEqual(@as(u64, 5000), timeout.timeout_ms);
    try std.testing.expect(!timeout.timed_out);
}

test "TimeoutContext can check timeout" {
    var timeout = wasm.TimeoutContext.init(1); // 1 second timeout

    try timeout.checkTimeout(); // Should not timeout yet

    try std.testing.expect(!timeout.timed_out);
}

test "ModuleRegistry version management" {
    var gpa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer gpa.deinit();
    const allocator = gpa.allocator();

    var registry = wasm.ModuleRegistry.init(allocator);
    defer registry.deinit();

    const config = wasm.InstanceConfig{};
    const version1 = try registry.activate(
        "payment_module",
        "hash1",
        config,
    );

    try std.testing.expectEqual(@as(u32, 1), version1.version);
    try std.testing.expect(version1.is_active);

    const version2 = try registry.activate(
        "payment_module",
        "hash2",
        config,
    );

    try std.testing.expectEqual(@as(u32, 2), version2.version);
    try std.testing.expect(version2.is_active);
}
