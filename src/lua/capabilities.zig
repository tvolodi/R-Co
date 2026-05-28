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
    /// Caller owns the returned memory.
    pub fn summary(self: *const CapabilitySet, allocator: std.mem.Allocator) ![]const u8 {
        if (self.grants.count() == 0) {
            return allocator.dupe(u8, "(none)");
        }

        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();

        var iter = self.grants.keyIterator();
        var first = true;
        while (iter.next()) |key| {
            if (!first) {
                try buf.appendSlice(", ");
            }
            try buf.appendSlice(key.*);
            first = false;
        }

        return buf.toOwnedSlice();
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
