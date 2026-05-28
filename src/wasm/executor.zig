//! Core Wasm module executor with state isolation and sandboxing.
//!
//! This module provides the main entry point for executing Wasm modules within the BPM platform.
//! Key responsibilities:
//! - Create and manage per-invocation Wasm instances
//! - Validate and enforce module ABI contract
//! - Execute modules and extract results
//! - Enforce resource limits (fuel, memory, timeout)
//! - Capability-based authorization

const std = @import("std");
const bindings = @import("wasmtime_bindings.zig");
const engine_mod = @import("engine.zig");
const instance_mod = @import("instance.zig");
const capabilities_mod = @import("capabilities.zig");
const memory_mod = @import("memory.zig");
const timeout_mod = @import("timeout.zig");
const errors_mod = @import("errors.zig");

/// Execution result from a Wasm module invocation.
pub const ExecutionResult = struct {
    success: bool,
    response: ?[]const u8 = null,
    error_type: ?ErrorType = null,
    error_message: ?[]const u8 = null,
    fuel_consumed: u64 = 0,
    wall_clock_elapsed_ms: u64 = 0,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ExecutionResult) void {
        if (self.response) |resp| {
            self.allocator.free(resp);
        }
        if (self.error_message) |msg| {
            self.allocator.free(msg);
        }
    }
};

pub const ErrorType = enum {
    TrapExecution,
    FuelExhausted,
    TimeoutExceeded,
    CapabilityDenied,
    MemoryAccessViolation,
    InitFailed,
    DeinitFailed,
};

/// Execution context for a module invocation.
pub const ExecutionContext = struct {
    module_id: []const u8,
    invocation_id: []const u8,
    instance_id: []const u8,
    actor_id: []const u8,
    capabilities: *const capabilities_mod.CapabilitySet,
    allocator: std.mem.Allocator,
};

/// Execute a Wasm module with the given payload.
pub fn executeModule(
    engine: *engine_mod.WasmEngine,
    module: ?*bindings.Module,
    _: []const u8,
    context: *ExecutionContext,
    config: instance_mod.InstanceConfig,
) !ExecutionResult {
    if (module == null) {
        return ExecutionResult{
            .success = false,
            .error_type = .TrapExecution,
            .error_message = try context.allocator.dupe(u8, "Module is null"),
            .fuel_consumed = 0,
            .wall_clock_elapsed_ms = 0,
            .allocator = context.allocator,
        };
    }

    var timeout_ctx = timeout_mod.TimeoutContext.init(config.timeout_seconds);

    // Create instance
    var instance = instance_mod.instantiateModule(engine, module, config, context.allocator) catch |err| {
        return ExecutionResult{
            .success = false,
            .error_type = .TrapExecution,
            .error_message = try context.allocator.dupe(u8, errors_mod.errorDescription(err)),
            .fuel_consumed = 0,
            .wall_clock_elapsed_ms = timeout_ctx.elapsedMs(),
            .allocator = context.allocator,
        };
    };
    defer instance.deinit();

    // Call init()
    const init_func = instance.getExport("init") catch |err| {
        return ExecutionResult{
            .success = false,
            .error_type = .InitFailed,
            .error_message = try context.allocator.dupe(u8, errors_mod.errorDescription(err)),
            .fuel_consumed = 0,
            .wall_clock_elapsed_ms = timeout_ctx.elapsedMs(),
            .allocator = context.allocator,
        };
    };

    if (init_func.kind != bindings.WASMTIME_EXTERN_FUNC) {
        return ExecutionResult{
            .success = false,
            .error_type = .InitFailed,
            .error_message = try context.allocator.dupe(u8, "init is not a function"),
            .fuel_consumed = 0,
            .wall_clock_elapsed_ms = timeout_ctx.elapsedMs(),
            .allocator = context.allocator,
        };
    }

    // Call init() - stub for now (will implement in Stage 10)
    _ = instance.getExport("init") catch {};

    // Call deinit() - best effort (stub for now)
    _ = instance.getExport("deinit") catch {};

    const fuel_consumed = try instance.store.getFuelConsumed();
    const elapsed_ms = timeout_ctx.elapsedMs();

    return ExecutionResult{
        .success = true,
        .response = try context.allocator.dupe(u8, "OK"),
        .fuel_consumed = fuel_consumed,
        .wall_clock_elapsed_ms = elapsed_ms,
        .allocator = context.allocator,
    };
}
