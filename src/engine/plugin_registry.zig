const std = @import("std");
const plugin_interface = @import("plugin_interface.zig");

pub const RuntimeApiVersion = plugin_interface.PluginApiVersion{
    .major = 1,
    .minor = 0,
};

/// Plugin handler scope (SVC-02).
pub const PluginScope = enum { global, tenant };

pub const PluginRegistrationError = error{
    DuplicateNodeType,
    InvalidNodeType,
    InvalidHandler,
    RegistryLocked,
    IncompatibleApiVersion,
    OutOfMemory,
    TenantScopedPluginRequiresOwnerId, // new SVC-02
    GlobalPluginMustNotHaveOwnerId, // new SVC-02
};

pub const RegisterPluginHandlerInput = struct {
    node_type: []const u8,
    handler: ?plugin_interface.PluginNodeHandlerPtr,
    plugin_name: []const u8,
    plugin_version: []const u8,
    target_api: plugin_interface.PluginApiVersion,
    scope: PluginScope = .global, // SVC-02
    owner_tenant_id: ?[16]u8 = null, // SVC-02
};

pub const PluginRegistration = struct {
    node_type: []const u8,
    handler: plugin_interface.PluginNodeHandlerPtr,
    plugin_name: []const u8,
    plugin_version: []const u8,
    target_api: plugin_interface.PluginApiVersion,
    scope: PluginScope = .global, // SVC-02
    owner_tenant_id: ?[16]u8 = null, // SVC-02
};

pub const ResolvedNodeHandlerKind = enum {
    plugin,
    builtin,
};

pub const PluginRegistry = struct {
    allocator: std.mem.Allocator,
    // Keyed by node_type; multiple registrations per node_type allowed (different scopes/tenants).
    entries: std.StringHashMap(PluginRegistration),
    // Additional tenant-scoped entries stored separately so global lookups still work via entries.
    tenant_entries: std.ArrayList(PluginRegistration),
    locked: bool,

    pub fn init(allocator: std.mem.Allocator) PluginRegistry {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(PluginRegistration).init(allocator),
            .tenant_entries = .empty,
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

        for (self.tenant_entries.items) |reg| {
            self.allocator.free(reg.node_type);
            self.allocator.free(reg.plugin_name);
            self.allocator.free(reg.plugin_version);
        }
        self.tenant_entries.deinit(self.allocator);
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

    // SVC-02 scope validation.
    if (input.scope == .tenant and input.owner_tenant_id == null)
        return error.TenantScopedPluginRequiresOwnerId;
    if (input.scope == .global and input.owner_tenant_id != null)
        return error.GlobalPluginMustNotHaveOwnerId;

    // Check for duplicate global node type BEFORE allocating strings.
    if (input.scope == .global and registry.entries.contains(input.node_type))
        return error.DuplicateNodeType;

    const node_type = allocator.dupe(u8, input.node_type) catch return error.OutOfMemory;
    errdefer allocator.free(node_type);
    const plugin_name = allocator.dupe(u8, input.plugin_name) catch return error.OutOfMemory;
    errdefer allocator.free(plugin_name);
    const plugin_version = allocator.dupe(u8, input.plugin_version) catch return error.OutOfMemory;
    errdefer allocator.free(plugin_version);

    const reg = PluginRegistration{
        .node_type = node_type,
        .handler = handler,
        .plugin_name = plugin_name,
        .plugin_version = plugin_version,
        .target_api = input.target_api,
        .scope = input.scope,
        .owner_tenant_id = input.owner_tenant_id,
    };

    if (input.scope == .tenant) {
        // Tenant-scoped entries go into the tenant_entries list.
        registry.tenant_entries.append(registry.allocator, reg) catch return error.OutOfMemory;
    } else {
        registry.entries.put(node_type, reg) catch return error.OutOfMemory;
    }
}

pub fn freezePluginRegistry(registry: *PluginRegistry) void {
    // SVC-02: validate no two tenant-scoped plugins share (node_type, owner_tenant_id).
    const items = registry.tenant_entries.items;
    for (items, 0..) |a_reg, i| {
        for (items[i + 1 ..]) |b_reg| {
            if (std.mem.eql(u8, a_reg.node_type, b_reg.node_type)) {
                if (a_reg.owner_tenant_id != null and b_reg.owner_tenant_id != null) {
                    if (std.mem.eql(u8, &a_reg.owner_tenant_id.?, &b_reg.owner_tenant_id.?)) {
                        // Fatal startup error: duplicate (node_type, owner_tenant_id).
                        std.debug.panic(
                            "freezePluginRegistry: duplicate tenant-scoped plugin for node_type='{s}'",
                            .{a_reg.node_type},
                        );
                    }
                }
            }
        }
    }
    registry.locked = true;
}

pub fn resolvePluginHandler(
    registry: *const PluginRegistry,
    node_type: []const u8,
) ?PluginRegistration {
    return registry.entries.get(node_type);
}

/// Resolve the highest-priority eligible handler for node_type for tenant (SVC-02).
/// Priority: tenant-scoped plugin > global plugin > nil.
pub fn resolvePluginHandlerForTenant(
    registry: *const PluginRegistry,
    node_type: []const u8,
    tenant_id: [16]u8,
) ?PluginRegistration {
    // Check tenant-scoped entries first (higher priority).
    for (registry.tenant_entries.items) |reg| {
        if (!std.mem.eql(u8, reg.node_type, node_type)) continue;
        if (reg.owner_tenant_id) |owner| {
            if (std.mem.eql(u8, &owner, &tenant_id)) return reg;
        }
    }
    // Fall back to global entries.
    return registry.entries.get(node_type);
}

pub fn resolveNodeHandlerKind(
    registry: *const PluginRegistry,
    node_type: []const u8,
    has_builtin_handler: bool,
) ?ResolvedNodeHandlerKind {
    if (registry.entries.contains(node_type)) return .plugin;
    for (registry.tenant_entries.items) |reg| {
        if (std.mem.eql(u8, reg.node_type, node_type)) return .plugin;
    }
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
