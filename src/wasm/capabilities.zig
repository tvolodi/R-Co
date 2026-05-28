//! Capability-based authorization for Wasm modules.
//!
//! Modules declare required capabilities (variable:read, service:call:payment_api, etc.)
//! at registration time. These are validated against the module's declared capabilities.
//! At instantiation, only host functions matching granted capabilities are provided to the module.

const std = @import("std");

pub const StandardCapabilities = struct {
    const read_variable = "variable:read";
    const write_variable = "variable:write";
    const call_service = "service:call:*";
    const log = "audit:log";
    const uuid = "uuid:generate";
    const time_read = "time:read";
};

/// A set of granted capabilities (authorization tokens for host API functions).
pub const CapabilitySet = struct {
    capabilities: std.StringHashMap(bool), // Key = capability string, Value = always true
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CapabilitySet {
        return CapabilitySet{
            .capabilities = std.StringHashMap(bool).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CapabilitySet) void {
        var iter = self.capabilities.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.capabilities.deinit();
    }

    /// Add a capability to the set.
    pub fn add(self: *CapabilitySet, capability: []const u8) !void {
        const cap_copy = try self.allocator.dupe(u8, capability);
        try self.capabilities.put(cap_copy, true);
    }

    /// Check if a capability is in the set.
    pub fn has(self: *const CapabilitySet, capability: []const u8) bool {
        return self.capabilities.contains(capability);
    }

    /// Check if a wildcard capability matches (e.g., "service:call:*" matches "service:call:payment_api").
    pub fn hasWildcard(self: *const CapabilitySet, target: []const u8) bool {
        var iter = self.capabilities.keyIterator();
        while (iter.next()) |key| {
            const cap = key.*;
            if (std.mem.endsWith(u8, cap, ":*")) {
                const prefix = cap[0 .. cap.len - 1]; // Remove trailing *
                if (std.mem.startsWith(u8, target, prefix)) {
                    return true;
                }
            } else if (std.mem.eql(u8, cap, target)) {
                return true;
            }
        }
        return false;
    }

    /// Get all capabilities as a slice.
    pub fn all(self: *const CapabilitySet, allocator: std.mem.Allocator) ![][]const u8 {
        var result = std.ArrayList([]const u8).init(allocator);
        defer result.deinit();

        var iter = self.capabilities.keyIterator();
        while (iter.next()) |key| {
            try result.append(key.*);
        }

        return result.toOwnedSlice();
    }

    /// Create a copy of this capability set.
    pub fn clone(self: *const CapabilitySet) !CapabilitySet {
        var new_set = CapabilitySet.init(self.allocator);
        var iter = self.capabilities.keyIterator();
        while (iter.next()) |key| {
            try new_set.add(key.*);
        }
        return new_set;
    }

    /// Count the number of capabilities.
    pub fn count(self: *const CapabilitySet) usize {
        return self.capabilities.count();
    }
};

/// Module-declared capability descriptor (from get_capabilities export).
pub const ModuleCapabilities = struct {
    capabilities: []const []const u8,
    max_fuel: u64,
    max_memory_pages: u32,
    timeout_seconds: u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ModuleCapabilities) void {
        for (self.capabilities) |cap| {
            self.allocator.free(cap);
        }
        self.allocator.free(self.capabilities);
    }
};

/// Validate that module-declared capabilities are a subset of granted capabilities.
pub fn validateCapabilities(
    module_caps: []const []const u8,
    granted_caps: *const CapabilitySet,
) !void {
    for (module_caps) |module_cap| {
        if (!granted_caps.hasWildcard(module_cap)) {
            return error.UnauthorizedCapability;
        }
    }
}
