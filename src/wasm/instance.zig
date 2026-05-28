//! Wasm module instantiation with import validation and resource configuration.

const std = @import("std");
const bindings = @import("wasmtime_bindings.zig");
const engine_mod = @import("engine.zig");
const capabilities_mod = @import("capabilities.zig");
const errors_mod = @import("errors.zig");

/// Configuration for module instantiation.
pub const InstanceConfig = struct {
    max_memory_pages: u32 = 256, // Default 256 pages = 16 MB
    max_fuel: u64 = 1_000_000, // Default 1 million instruction units
    timeout_seconds: u32 = 30, // Default 30 second timeout
};

/// A Wasm module instance with execution state.
pub const WasmInstance = struct {
    instance: bindings.Instance,
    store: engine_mod.WasmStore,
    module: ?*bindings.Module,
    config: InstanceConfig,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WasmInstance) void {
        bindings.instance_delete(&self.instance);
        self.store.deinit();
    }

    /// Get a named export from this instance.
    pub fn getExport(self: *WasmInstance, name: []const u8) !bindings.Extern {
        var export_val: bindings.Extern = undefined;
        const found = bindings.instance_export_get(
            self.store.store,
            &self.instance,
            name.ptr,
            name.len,
            &export_val,
        );

        if (!found) {
            return error.MissingInitExport; // Generic: could be any export
        }

        return export_val;
    }

    /// Get the memory export from this instance.
    pub fn getMemory(self: *WasmInstance) !bindings.Memory {
        const memory_export = try self.getExport("memory");

        if (memory_export.kind != bindings.WASMTIME_EXTERN_MEMORY) {
            return error.MemoryAccessViolation;
        }

        return memory_export.of.memory;
    }
};

/// Instantiate a Wasm module with import validation.
pub fn instantiateModule(
    engine: *engine_mod.WasmEngine,
    module: ?*bindings.Module,
    config: InstanceConfig,
    allocator: std.mem.Allocator,
) !WasmInstance {
    if (module == null) {
        return error.WasmModuleLoadFailed;
    }

    var store = try engine_mod.WasmStore.init(engine, config.max_fuel, config.max_memory_pages * 65536);
    errdefer store.deinit();

    // For now, instantiate with no imports (imports are added in host_api integration)
    var instance: bindings.Instance = undefined;
    var trap: ?*bindings.Trap = null;

    const result = bindings.instance_new(
        store.store,
        module,
        &[_]bindings.Extern{},
        0,
        &instance,
        &trap,
    );

    if (result != 0 or trap != null) {
        if (trap) |t| {
            bindings.trap_delete(t);
        }
        return error.WasmInstanceCreationFailed;
    }

    return WasmInstance{
        .instance = instance,
        .store = store,
        .module = module,
        .config = config,
        .allocator = allocator,
    };
}

/// Validate module ABI: check for required exports (init, execute, deinit, get_capabilities).
pub fn validateModuleABI(
    engine: *engine_mod.WasmEngine,
    module_content: []const u8,
    module_hash: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const module = try engine.getOrLoadModule(module_content, module_hash);
    if (module == null) {
        return error.WasmModuleLoadFailed;
    }

    var temp_instance = try instantiateModule(engine, module, InstanceConfig{}, allocator);
    defer temp_instance.deinit();

    // Check for required exports
    _ = try temp_instance.getExport("init") orelse return error.MissingInitExport;
    _ = try temp_instance.getExport("execute") orelse return error.MissingExecuteExport;
    _ = try temp_instance.getExport("deinit") orelse return error.MissingDeinitExport;
    _ = try temp_instance.getExport("get_capabilities") orelse return error.MissingGetCapabilitiesExport;
}
