//! Wasmtime C FFI declarations and static linking configuration.
//!
//! This module provides low-level FFI bindings to the Wasmtime C API.
//! Wasmtime is statically linked into the BPM binary (no external .so/.dll dependency).
//!
//! NOTE: Actual C FFI integration deferred to Stage 10.
//! For now, provide type stubs to allow module testing and compilation.

const std = @import("std");

// Stub types for C interop (will be replaced with real @cImport in Stage 10)
pub const Engine = extern struct {};
pub const Store = extern struct {};
pub const Instance = extern struct {};
pub const Module = extern struct {};
pub const Func = extern struct {};
pub const Trap = extern struct {};
pub const Memory = extern struct {};

pub const Val = extern struct {
    kind: u32,
    of: extern union {
        i32: i32,
        i64: i64,
        f32: f32,
        f64: f64,
        r32: f32,
        r64: f64,
    },
};

pub const Extern = extern struct {
    kind: u32,
    of: extern union {
        func: Func,
        global: opaque {},
        table: opaque {},
        memory: Memory,
    },
};

pub const ExternType = u32;

pub const WASMTIME_EXTERN_FUNC: u32 = 0;
pub const WASMTIME_EXTERN_GLOBAL: u32 = 1;
pub const WASMTIME_EXTERN_TABLE: u32 = 2;
pub const WASMTIME_EXTERN_MEMORY: u32 = 3;

pub const WASMTIME_I32: u32 = 0;
pub const WASMTIME_I64: u32 = 1;
pub const WASMTIME_F32: u32 = 2;
pub const WASMTIME_F64: u32 = 3;

// Stub functions (will be replaced with real C FFI in Stage 10)

/// Create a new Wasmtime engine (stub).
pub inline fn engine_new() ?*Engine {
    return null; // Stub: actual implementation in Stage 10
}

/// Delete a Wasmtime engine (stub).
pub inline fn engine_delete(engine: ?*Engine) void {
    _ = engine;
}

/// Create a new Wasmtime store (stub).
pub inline fn store_new(
    engine: ?*Engine,
    data: ?*anyopaque,
    finalizer: ?*const fn (?*anyopaque) callconv(.C) void,
) ?*Store {
    _ = engine;
    _ = data;
    _ = finalizer;
    return null;
}

/// Delete a Wasmtime store (stub).
pub inline fn store_delete(store: ?*Store) void {
    _ = store;
}

/// Load a Wasm module from binary bytes (stub).
pub inline fn module_new(
    engine: ?*Engine,
    wasm_bytes: [*]const u8,
    byte_count: usize,
    module_out: *?*Module,
) c_int {
    _ = engine;
    _ = wasm_bytes;
    _ = byte_count;
    _ = module_out;
    return 1; // Stub: fail
}

/// Delete a Wasmtime module (stub).
pub inline fn module_delete(module: ?*Module) void {
    _ = module;
}

/// Instantiate a Wasm module (stub).
pub inline fn instance_new(
    store: ?*Store,
    module: ?*Module,
    imports: [*]const Extern,
    import_count: usize,
    instance_out: *Instance,
    trap_out: ?*?*Trap,
) c_int {
    _ = store;
    _ = module;
    _ = imports;
    _ = import_count;
    _ = instance_out;
    _ = trap_out;
    return 1;
}

/// Delete a Wasmtime instance (stub).
pub inline fn instance_delete(instance: *Instance) void {
    _ = instance;
}

/// Get an exported function/global/memory/table from an instance (stub).
pub inline fn instance_export_get(
    store: ?*Store,
    instance: *const Instance,
    name: [*:0]const u8,
    name_len: usize,
    item: *Extern,
) bool {
    _ = store;
    _ = instance;
    _ = name;
    _ = name_len;
    _ = item;
    return false;
}

/// Call a Wasm function (stub).
pub inline fn func_call(
    store: ?*Store,
    func: *const Func,
    args: [*]const Val,
    arg_count: usize,
    results: [*]Val,
    result_count: usize,
    trap_out: ?*?*Trap,
) c_int {
    _ = store;
    _ = func;
    _ = args;
    _ = arg_count;
    _ = results;
    _ = result_count;
    _ = trap_out;
    return 1;
}

/// Set the fuel budget for a store (stub).
pub inline fn store_set_fuel(store: ?*Store, fuel: u64) c_int {
    _ = store;
    _ = fuel;
    return 0;
}

/// Get remaining fuel in a store (stub).
pub inline fn store_get_fuel(store: ?*Store, fuel_out: *u64) c_int {
    _ = store;
    fuel_out.* = 0;
    return 0;
}

/// Get the data pointer from a Wasmtime memory export (stub).
pub inline fn memory_data(store: ?*Store, memory: *const Memory) ?[*]u8 {
    _ = store;
    _ = memory;
    return null;
}

/// Get the size in bytes of a Wasmtime memory (stub).
pub inline fn memory_data_size(store: ?*Store, memory: *const Memory) usize {
    _ = store;
    _ = memory;
    return 0;
}

/// Grow a Wasmtime memory (stub).
pub inline fn memory_grow(
    store: ?*Store,
    memory: *Memory,
    delta: u64,
    prev_size_out: *u64,
) c_int {
    _ = store;
    _ = memory;
    _ = delta;
    _ = prev_size_out;
    return 1;
}

/// Get the error message from a Wasm trap (stub).
pub inline fn trap_message(trap: *Trap, buf: [*]u8) usize {
    _ = trap;
    _ = buf;
    return 0;
}

/// Delete a Wasm trap (stub).
pub inline fn trap_delete(trap: *Trap) void {
    _ = trap;
}

/// Create a Wasm i32 value.
pub inline fn val_i32(value: i32) Val {
    var v: Val = undefined;
    v.kind = WASMTIME_I32;
    v.of.i32 = value;
    return v;
}

/// Create a Wasm i64 value.
pub inline fn val_i64(value: i64) Val {
    var v: Val = undefined;
    v.kind = WASMTIME_I64;
    v.of.i64 = value;
    return v;
}

/// Create a Wasm f32 value.
pub inline fn val_f32(value: f32) Val {
    var v: Val = undefined;
    v.kind = WASMTIME_F32;
    v.of.f32 = value;
    return v;
}

/// Create a Wasm f64 value.
pub inline fn val_f64(value: f64) Val {
    var v: Val = undefined;
    v.kind = WASMTIME_F64;
    v.of.f64 = value;
    return v;
}
