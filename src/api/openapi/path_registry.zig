const std = @import("std");
const model = @import("model.zig");

pub const EndpointDescriptor = model.EndpointDescriptor;
pub const RouteModuleDescriptor = model.RouteModuleDescriptor;

pub const PathRegistryError = error{
    DuplicatePathOperation,
};

pub const PathRegistry = struct {
    allocator: std.mem.Allocator,
    endpoints: std.ArrayList(EndpointDescriptor),

    pub fn init(allocator: std.mem.Allocator) PathRegistry {
        return .{
            .allocator = allocator,
            .endpoints = .empty,
        };
    }

    pub fn deinit(self: *PathRegistry) void {
        self.endpoints.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addEndpoint(self: *PathRegistry, endpoint: EndpointDescriptor) (PathRegistryError || error{OutOfMemory})!void {
        for (self.endpoints.items) |existing| {
            if (std.mem.eql(u8, existing.path, endpoint.path) and existing.method == endpoint.method) {
                return error.DuplicatePathOperation;
            }
        }
        try self.endpoints.append(self.allocator, endpoint);
    }

    pub fn addModule(self: *PathRegistry, module_desc: RouteModuleDescriptor) (PathRegistryError || error{OutOfMemory})!void {
        _ = module_desc.module_name;
        for (module_desc.endpoints) |endpoint| {
            try self.addEndpoint(endpoint);
        }
    }

    pub fn toOwnedSlice(self: *PathRegistry, allocator: std.mem.Allocator) error{OutOfMemory}![]EndpointDescriptor {
        return try allocator.dupe(EndpointDescriptor, self.endpoints.items);
    }
};
