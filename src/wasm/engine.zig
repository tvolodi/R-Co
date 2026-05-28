//! Wasmtime engine and store initialization and lifecycle management.
//!
//! The engine is a global singleton created once at platform startup.
//! Stores are created per-invocation or per-pooled-instance to hold execution state and linear memory.

const std = @import("std");
const bindings = @import("wasmtime_bindings.zig");
const errors = @import("errors.zig");

/// Global Wasmtime engine with module caching.
pub const WasmEngine = struct {
    engine: ?*bindings.Engine,
    module_cache: std.StringHashMap(?*bindings.Module), // Keyed by module content hash
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !WasmEngine {
        const engine = bindings.engine_new() orelse return error.WasmEngineInitFailed;

        return WasmEngine{
            .engine = engine,
            .module_cache = std.StringHashMap(?*bindings.Module).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WasmEngine) void {
        var iter = self.module_cache.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.*) |module| {
                bindings.module_delete(module);
            }
        }
        self.module_cache.deinit();
        bindings.engine_delete(self.engine);
    }

    /// Load or retrieve a cached module.
    /// The module_hash is a SHA-256 hex digest used as the cache key.
    pub fn getOrLoadModule(
        self: *WasmEngine,
        module_content: []const u8,
        module_hash: []const u8,
    ) !?*bindings.Module {
        if (self.module_cache.get(module_hash)) |cached| {
            return cached;
        }

        var module: ?*bindings.Module = null;
        const result = bindings.module_new(self.engine, module_content.ptr, module_content.len, &module);

        if (result != 0 or module == null) {
            return error.WasmModuleLoadFailed;
        }

        const hash_copy = try self.allocator.dupe(u8, module_hash);
        try self.module_cache.put(hash_copy, module);

        return module;
    }
};

/// Per-invocation execution context and linear memory.
pub const WasmStore = struct {
    store: ?*bindings.Store,
    fuel_limit: u64,
    memory_cap: u64,

    pub fn init(
        engine: *WasmEngine,
        fuel_limit: u64,
        memory_cap: u64,
    ) !WasmStore {
        const store = bindings.store_new(engine.engine, null, null) orelse return error.WasmStoreInitFailed;

        // Set fuel budget
        if (bindings.store_set_fuel(store, fuel_limit) != 0) {
            bindings.store_delete(store);
            return error.InvalidFuelBudget;
        }

        return WasmStore{
            .store = store,
            .fuel_limit = fuel_limit,
            .memory_cap = memory_cap,
        };
    }

    pub fn deinit(self: *WasmStore) void {
        bindings.store_delete(self.store);
    }

    /// Get the remaining fuel in this store.
    pub fn getRemainingFuel(self: *WasmStore) !u64 {
        var fuel_remaining: u64 = undefined;
        if (bindings.store_get_fuel(self.store, &fuel_remaining) != 0) {
            return error.FuelQueryFailed;
        }
        return fuel_remaining;
    }

    /// Get the fuel consumed (initial budget - remaining).
    pub fn getFuelConsumed(self: *WasmStore) !u64 {
        const remaining = try self.getRemainingFuel();
        return if (remaining < self.fuel_limit) self.fuel_limit - remaining else 0;
    }

    /// Set a new fuel budget.
    pub fn setFuelBudget(self: *WasmStore, new_limit: u64) !void {
        if (new_limit < 1000) {
            return error.InvalidFuelBudget;
        }
        if (bindings.store_set_fuel(self.store, new_limit) != 0) {
            return error.FuelLimitOutOfRange;
        }
        self.fuel_limit = new_limit;
    }
};

pub const FuelError = error{
    FuelExhausted,
    InvalidFuelBudget,
    FuelQueryFailed,
    FuelLimitOutOfRange,
};
