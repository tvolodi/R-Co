const std = @import("std");
const plugin_interface = @import("plugin_interface.zig");

pub const RuntimeApiVersion = plugin_interface.PluginApiVersion{
    .major = 1,
    .minor = 0,
};

pub const PluginRegistrationError = error{
    DuplicateNodeType,
    InvalidNodeType,
    InvalidHandler,
    RegistryLocked,
    IncompatibleApiVersion,
    OutOfMemory,
};

pub const RegisterPluginHandlerInput = struct {
    node_type: []const u8,
    handler: ?plugin_interface.PluginNodeHandlerPtr,
    plugin_name: []const u8,
    plugin_version: []const u8,
    target_api: plugin_interface.PluginApiVersion,
};

pub const PluginRegistration = struct {
    node_type: []const u8,
    handler: plugin_interface.PluginNodeHandlerPtr,
    plugin_name: []const u8,
    plugin_version: []const u8,
    target_api: plugin_interface.PluginApiVersion,
};

pub const ResolvedNodeHandlerKind = enum {
    plugin,
    builtin,
};

pub const PluginRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(PluginRegistration),
    locked: bool,

    pub fn init(allocator: std.mem.Allocator) PluginRegistry {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(PluginRegistration).init(allocator),
            .locked = false,
        };
    }

    pub fn deinit(self: *PluginRegistry) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.node_type);
            self.allocator.free(entry.value_ptr.plugin_name);
            self.allocator.free(entry.value_ptr.plugin_version);
        }
        self.entries.deinit();
    }
};

pub fn isCompatibleApiVersion(target: plugin_interface.PluginApiVersion) bool {
    if (target.major != RuntimeApiVersion.major) return false;
    return target.minor <= RuntimeApiVersion.minor;
}

pub fn registerPluginHandler(
    allocator: std.mem.Allocator,
    registry: *PluginRegistry,
    input: RegisterPluginHandlerInput,
) PluginRegistrationError!void {
    if (registry.locked) return error.RegistryLocked;
    if (input.node_type.len == 0) return error.InvalidNodeType;
    if (!isCompatibleApiVersion(input.target_api)) return error.IncompatibleApiVersion;
    const handler = input.handler orelse return error.InvalidHandler;

    if (registry.entries.contains(input.node_type)) return error.DuplicateNodeType;

    const node_type = allocator.dupe(u8, input.node_type) catch return error.OutOfMemory;
    errdefer allocator.free(node_type);
    const plugin_name = allocator.dupe(u8, input.plugin_name) catch return error.OutOfMemory;
    errdefer allocator.free(plugin_name);
    const plugin_version = allocator.dupe(u8, input.plugin_version) catch return error.OutOfMemory;
    errdefer allocator.free(plugin_version);

    registry.entries.put(node_type, .{
        .node_type = node_type,
        .handler = handler,
        .plugin_name = plugin_name,
        .plugin_version = plugin_version,
        .target_api = input.target_api,
    }) catch return error.OutOfMemory;
}

pub fn freezePluginRegistry(registry: *PluginRegistry) void {
    registry.locked = true;
}

pub fn resolvePluginHandler(
    registry: *const PluginRegistry,
    node_type: []const u8,
) ?PluginRegistration {
    return registry.entries.get(node_type);
}

pub fn resolveNodeHandlerKind(
    registry: *const PluginRegistry,
    node_type: []const u8,
    has_builtin_handler: bool,
) ?ResolvedNodeHandlerKind {
    if (registry.entries.contains(node_type)) return .plugin;
    if (has_builtin_handler) return .builtin;
    return null;
}

var global_registry: ?PluginRegistry = null;

fn ensureGlobalRegistry() *PluginRegistry {
    if (global_registry == null) {
        global_registry = PluginRegistry.init(std.heap.smp_allocator);
    }
    return &global_registry.?;
}

pub fn registerGlobalPluginHandler(
    allocator: std.mem.Allocator,
    input: RegisterPluginHandlerInput,
) PluginRegistrationError!void {
    const registry = ensureGlobalRegistry();
    try registerPluginHandler(allocator, registry, input);
}

pub fn freezeGlobalPluginRegistry() void {
    const registry = ensureGlobalRegistry();
    freezePluginRegistry(registry);
}

pub fn resolveGlobalPluginHandler(node_type: []const u8) ?PluginRegistration {
    const registry = ensureGlobalRegistry();
    return resolvePluginHandler(registry, node_type);
}

pub fn resolveGlobalNodeHandlerKind(
    node_type: []const u8,
    has_builtin_handler: bool,
) ?ResolvedNodeHandlerKind {
    const registry = ensureGlobalRegistry();
    return resolveNodeHandlerKind(registry, node_type, has_builtin_handler);
}

pub fn resetGlobalRegistryForTests() void {
    if (global_registry) |*reg| {
        reg.deinit();
    }
    global_registry = PluginRegistry.init(std.heap.smp_allocator);
}
