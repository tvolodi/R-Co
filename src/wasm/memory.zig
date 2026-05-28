//! Memory isolation and pointer validation for Wasm modules.
//!
//! Before the host dereferences any pointer received from a module,
//! it must validate bounds and alignment. This prevents:
//! - Out-of-bounds reads/writes
//! - Integer overflow in pointer arithmetic
//! - Invalid memory layout assumptions

const std = @import("std");
const bindings = @import("wasmtime_bindings.zig");
const engine_mod = @import("engine.zig");

pub const MemoryError = error{
    PointerOutOfBounds,
    LengthOutOfBounds,
    NullPointer,
    UnalignedPointer,
    MemoryAccessViolation,
};

/// Validate a pointer and length against the module's linear memory.
/// Fails if the pointer is null, out of bounds, or would overflow.
pub fn validatePointer(
    store: *engine_mod.WasmStore,
    memory: *const bindings.Memory,
    ptr: i32,
    len: u32,
) !void {
    if (ptr == 0) {
        return error.NullPointer;
    }

    if (ptr < 0) {
        return error.PointerOutOfBounds;
    }

    const ptr_u: u64 = @as(u64, @as(u32, @intCast(ptr)));
    const memory_size = bindings.memory_data_size(store.store, memory);

    // Check for overflow in pointer + length
    if (ptr_u + @as(u64, len) > memory_size) {
        return error.PointerOutOfBounds;
    }
}

/// Read a string from module linear memory.
/// Validates pointer and length before dereferencing.
pub fn readStringFromMemory(
    store: *engine_mod.WasmStore,
    memory: *const bindings.Memory,
    ptr: i32,
    len: u32,
    allocator: std.mem.Allocator,
) ![]const u8 {
    try validatePointer(store, memory, ptr, len);

    const ptr_u: u32 = @as(u32, @intCast(ptr));
    const memory_data = bindings.memory_data(store.store, memory) orelse return error.MemoryAccessViolation;
    const slice = memory_data[ptr_u .. ptr_u + len];

    return try allocator.dupe(u8, slice);
}

/// Write a string to module linear memory.
/// Validates pointer and length before dereferencing.
pub fn writeStringToMemory(
    store: *engine_mod.WasmStore,
    memory: *const bindings.Memory,
    ptr: i32,
    buf: []const u8,
) !void {
    try validatePointer(store, memory, ptr, @as(u32, @intCast(buf.len)));

    const ptr_u: u32 = @as(u32, @intCast(ptr));
    const memory_data = bindings.memory_data(store.store, memory) orelse return error.MemoryAccessViolation;
    @memcpy(memory_data[ptr_u .. ptr_u + buf.len], buf);
}

/// Enforce memory growth cap.
/// Called when module requests memory growth via grow() instruction.
pub fn enforceMemoryCap(
    store: *engine_mod.WasmStore,
    memory: *bindings.Memory,
    delta_pages: u64,
) !void {
    const current_size = bindings.memory_data_size(store.store, memory);
    const new_size = current_size + (delta_pages * 65536); // 1 page = 64 KB

    if (new_size > store.memory_cap) {
        return error.MemoryCapExceeded;
    }

    var prev_size: u64 = undefined;
    const result = bindings.memory_grow(store.store, memory, delta_pages, &prev_size);
    if (result != 0) {
        return error.MemoryGrowthFailed;
    }
}

pub const MemoryGrowthFailed = error{MemoryGrowthFailed};
