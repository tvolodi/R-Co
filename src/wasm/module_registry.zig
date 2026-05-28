//! Wasm module registration and version management.
//!
//! Manages module lifecycle: registration, validation, activation, and hot reload.

const std = @import("std");
const bindings = @import("wasmtime_bindings.zig");
const engine_mod = @import("engine.zig");
const capabilities_mod = @import("capabilities.zig");
const instance_mod = @import("instance.zig");
const pool_mod = @import("pool.zig");

/// Metadata for a registered module version.
pub const ModuleVersion = struct {
    module_id: []const u8,
    version: u32,
    artifact_hash: []const u8,
    activated_at_ms: u64, // milliseconds since epoch
    is_active: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ModuleVersion) void {
        self.allocator.free(self.artifact_hash);
    }
};

/// Module registry with version management.
pub const ModuleRegistry = struct {
    modules: std.StringHashMap(*ModuleVersion),
    pools: std.StringHashMap(*pool_mod.InstancePool),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ModuleRegistry {
        return ModuleRegistry{
            .modules = std.StringHashMap(*ModuleVersion).init(allocator),
            .pools = std.StringHashMap(*pool_mod.InstancePool).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ModuleRegistry) void {
        var module_iter = self.modules.valueIterator();
        while (module_iter.next()) |version| {
            version.*.deinit();
            self.allocator.destroy(version.*);
        }
        self.modules.deinit();

        var pool_iter = self.pools.valueIterator();
        while (pool_iter.next()) |pool_ptr| {
            pool_ptr.*.deinit();
            self.allocator.destroy(pool_ptr.*);
        }
        self.pools.deinit();
    }

    /// Activate a module version.
    pub fn activate(
        self: *ModuleRegistry,
        module_id: []const u8,
        artifact_hash: []const u8,
        config: instance_mod.InstanceConfig,
    ) !ModuleVersion {
        const current = self.modules.get(module_id);
        const new_version: u32 = if (current) |v| v.version + 1 else 1;

        const module_id_copy = try self.allocator.dupe(u8, module_id);
        errdefer self.allocator.free(module_id_copy);

        const hash_copy = try self.allocator.dupe(u8, artifact_hash);
        errdefer self.allocator.free(hash_copy);

        // Placeholder: use constant time (will use real clock in Stage 10)
        const now_ms: u64 = 1000000;

        const new_mod = try self.allocator.create(ModuleVersion);
        new_mod.* = ModuleVersion{
            .module_id = module_id_copy,
            .version = new_version,
            .artifact_hash = hash_copy,
            .activated_at_ms = now_ms,
            .is_active = true,
            .allocator = self.allocator,
        };

        // Mark old version as inactive
        if (current) |old| {
            old.is_active = false;
        }

        try self.modules.put(module_id, new_mod);

        // Create instance pool for new version
        const pool_key = try std.fmt.allocPrint(
            self.allocator,
            "{s}:{d}",
            .{ module_id, new_version },
        );
        defer self.allocator.free(pool_key);

        const pool = try self.allocator.create(pool_mod.InstancePool);
        pool.* = try pool_mod.InstancePool.init(module_id, config, 10, self.allocator);

        try self.pools.put(pool_key, pool);

        return new_mod.*;
    }

    /// Get the active pool for a module.
    pub fn getActivePool(self: *ModuleRegistry, module_id: []const u8) !*pool_mod.InstancePool {
        const version = self.modules.get(module_id) orelse return error.ModuleNotFound;
        if (!version.is_active) {
            return error.ModuleNotFound;
        }

        const pool_key = try std.fmt.allocPrint(
            self.allocator,
            "{s}:{d}",
            .{ module_id, version.version },
        );
        defer self.allocator.free(pool_key);

        return self.pools.get(pool_key) orelse error.PoolNotFound;
    }

    /// Get the current active version for a module.
    pub fn getActiveVersion(self: *const ModuleRegistry, module_id: []const u8) ?*const ModuleVersion {
        return self.modules.get(module_id);
    }
};
