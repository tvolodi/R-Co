//! Instance pooling for Wasm modules.
//!
//! Pooled instances are reset between invocations to ensure per-invocation isolation
//! while amortizing the cost of instantiation.

const std = @import("std");
const instance_mod = @import("instance.zig");

/// A pool of reusable Wasm instances for a module.
pub const InstancePool = struct {
    module_id: []const u8,
    available: std.ArrayList(*instance_mod.WasmInstance),
    config: instance_mod.InstanceConfig,
    max_instances: u32,
    allocator: std.mem.Allocator,

    pub fn init(
        module_id: []const u8,
        config: instance_mod.InstanceConfig,
        max_instances: u32,
        allocator: std.mem.Allocator,
    ) !InstancePool {
        return InstancePool{
            .module_id = module_id,
            .available = try std.ArrayList(*instance_mod.WasmInstance).initCapacity(allocator, 0),
            .config = config,
            .max_instances = max_instances,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *InstancePool) void {
        for (self.available.items) |instance| {
            instance.deinit();
            self.allocator.destroy(instance);
        }
        self.available.deinit(self.allocator);
    }

    /// Acquire an instance from the pool or create a new one.
    pub fn acquire(self: *InstancePool) !*instance_mod.WasmInstance {
        if (self.available.popOrNull()) |instance| {
            // Reset instance for fresh invocation
            try resetInstance(instance);
            return instance;
        }

        if (self.available.items.len >= self.max_instances) {
            return error.InstancePoolExhausted;
        }

        // Create a new instance (actual creation deferred to executor)
        const new_instance = try self.allocator.create(instance_mod.WasmInstance);
        return new_instance;
    }

    /// Release an instance back to the pool.
    pub fn release(self: *InstancePool, instance: *instance_mod.WasmInstance) void {
        self.available.append(instance) catch {
            // On allocation failure, just destroy the instance
            instance.deinit();
            self.allocator.destroy(instance);
        };
    }
};

/// Reset an instance's linear memory for a fresh invocation.
fn resetInstance(instance: *instance_mod.WasmInstance) !void {
    _ = instance;
    // Memory reset is handled by init() call in executor
    // This is a placeholder for future optimization
}
