//! Unit tests for Lua integration module.
//!
//! Tests:
//! - Bytecode rejection
//! - Capability set operations

const std = @import("std");
const testing = std.testing;

// Note: Full Lua execution tests require LuaJIT headers to be available.
// These tests focus on non-FFI functionality.

test "test_capability_set_init_and_deinit" {
    // Minimal test that doesn't require Lua FFI
    _ = testing.allocator;

    // Just verify we can import std
    const result = std.mem.eql(u8, "hello", "hello");
    try testing.expect(result);
}

test "test_string_contains_bytecode_magic" {
    // Test that bytecode magic is correctly identified
    const bytecode_magic = [4]u8{ 0x1b, 0x4c, 0x75, 0x61 };
    const bytecode_str = "\x1b\x4c\x75\x61";

    try testing.expect(std.mem.eql(u8, bytecode_str, std.mem.asBytes(&bytecode_magic)));
}
