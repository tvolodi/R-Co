//! Capability-based authorization for Lua host API functions.
//!
//! This module defines a capability set — a collection of string grants that
//! determine what platform.* functions can be invoked from Lua scripts.
//!
//! A capability is a string like "service:call:payment" or "variable:read".
//! Each host function checks the capability before executing.

const std = @import("std");

pub const CapabilitySet = struct {
    grants: std.StringHashMap(void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CapabilitySet {
        return CapabilitySet{
            .grants = std.StringHashMap(void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CapabilitySet) void {
        var iter = self.grants.keyIterator();
        while (iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.grants.deinit();
    }

    /// Add a capability grant.
    pub fn add(self: *CapabilitySet, cap: []const u8) !void {
        const cap_copy = try self.allocator.dupe(u8, cap);
        errdefer self.allocator.free(cap_copy);
        try self.grants.put(cap_copy, {});
    }

    /// Check if a capability is granted.
    pub fn has(self: *const CapabilitySet, cap: []const u8) bool {
        return self.grants.contains(cap);
    }

    /// Get a summary string of granted capabilities for error messages.
    /// Caller owns the returned memory. Grants are listed in lexicographic
    /// order of their byte content.
    ///
    /// **Longjmp-unsafe (ERR-2).** This function allocates. Inside a context
    /// that may raise via `lua_error` (which longjmps), the returned slice
    /// would leak. The longjmp-safe twin is `writeGrants` in
    /// `src/lua/host_context.zig`, which walks the grant set directly into
    /// a fixed stack buffer. Use this `summary()` ONLY from contexts that
    /// own the result's lifetime cleanly (host-API startup diagnostics,
    /// audit log lines, REST error responses for missing capability
    /// metadata).
    pub fn summary(self: *const CapabilitySet, allocator: std.mem.Allocator) ![]const u8 {
        if (self.grants.count() == 0) {
            return allocator.dupe(u8, "(none)");
        }

        // Collect keys into a sortable list — std.StringHashMap iteration order
        // is undefined across Zig versions and allocator instances, so TC-CS-03
        // requires lexicographic ordering for deterministic output.
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(allocator);

        var iter = self.grants.keyIterator();
        while (iter.next()) |key| {
            try keys.append(allocator, key.*);
        }

        std.mem.sort([]const u8, keys.items, {}, lessThanStr);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);

        for (keys.items, 0..) |key, i| {
            if (i != 0) {
                try buf.appendSlice(allocator, ", ");
            }
            try buf.appendSlice(allocator, key);
        }

        return buf.toOwnedSlice(allocator);
    }

    /// Comparator used by `summary` to sort grant keys lexicographically.
    fn lessThanStr(_: void, lhs: []const u8, rhs: []const u8) bool {
        return std.mem.lessThan(u8, lhs, rhs);
    }
};

/// Standard capability strings.
pub const StandardCapabilities = struct {
    pub const SERVICE_CALL_PREFIX = "service:call:";
    pub const VARIABLE_READ = "variable:read";
    pub const VARIABLE_WRITE = "variable:write";
    pub const AUDIT_LOG = "audit:log";
    pub const EVENT_EMIT = "event:emit";
    pub const INSTANCE_READ = "instance:read";

    /// Construct a service-call capability for a specific service.
    pub fn serviceCall(allocator: std.mem.Allocator, service_id: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ SERVICE_CALL_PREFIX, service_id });
    }
};
