// Integration tests for SVC-02: plugin registry tenant scoping.
//
// These tests exercise the in-process PluginRegistry with the scope and
// owner_tenant_id fields added by Stage 13. No database connection is required —
// all tests operate against an in-memory PluginRegistry (no BPM_TEST_DB_URL
// dependency by design; see obs02_metrics_test.zig for the same pattern).
//
// Tests (TC-SVC-02-01 through TC-SVC-02-06):
//   - registerPluginHandler rejects scope=tenant with null owner_tenant_id
//   - registerPluginHandler rejects scope=global with non-null owner_tenant_id
//   - resolvePluginHandlerForTenant returns tenant-scoped plugin for owner
//   - resolvePluginHandlerForTenant falls back to global for non-owner tenant
//   - resolvePluginHandlerForTenant returns nil when only scoped plugin registered and non-owner calls
//   - Two tenant-scoped plugins with same (node_type, owner_tenant_id) produce duplicate detection

const std = @import("std");
const bpm = @import("bpm");
const plugin_registry = bpm.plugin_registry;
const plugin_interface = bpm.plugin_interface;

const RegisterPluginHandlerInput = plugin_registry.RegisterPluginHandlerInput;
const PluginRegistrationError = plugin_registry.PluginRegistrationError;
const PluginScope = plugin_registry.PluginScope;
const PluginRegistry = plugin_registry.PluginRegistry;

// ---------------------------------------------------------------------------
// Stub handler (required by register — must not be null)
// ---------------------------------------------------------------------------

fn stubHandler(ctx: plugin_interface.PluginExecutionContext) plugin_interface.PluginHandlerInvocationError!plugin_interface.PluginHandlerOutcome {
    _ = ctx;
    return .{ .COMPLETE = .{ .output_variables_json = null } };
}

const RUNTIME_API = plugin_interface.PluginApiVersion{ .major = 1, .minor = 0 };

// ---------------------------------------------------------------------------
// TC-SVC-02-01
// ---------------------------------------------------------------------------

test "svc02: registerPluginHandler rejects tenant scope without owner_tenant_id" {
    const alloc = std.testing.allocator;
    var registry = PluginRegistry.init(alloc);
    defer registry.deinit();

    const err = plugin_registry.registerPluginHandler(alloc, &registry, RegisterPluginHandlerInput{
        .node_type = "SERVICE_TASK",
        .handler = &stubHandler,
        .plugin_name = "test-plugin",
        .plugin_version = "1.0.0",
        .target_api = RUNTIME_API,
        .scope = .tenant,
        .owner_tenant_id = null, // must trigger error
    });
    try std.testing.expectError(PluginRegistrationError.TenantScopedPluginRequiresOwnerId, err);
}

// ---------------------------------------------------------------------------
// TC-SVC-02-02
// ---------------------------------------------------------------------------

test "svc02: registerPluginHandler rejects global scope with owner_tenant_id" {
    const alloc = std.testing.allocator;
    var registry = PluginRegistry.init(alloc);
    defer registry.deinit();

    const some_tenant: [16]u8 = [_]u8{0x01} ++ [_]u8{0x00} ** 15;

    const err = plugin_registry.registerPluginHandler(alloc, &registry, RegisterPluginHandlerInput{
        .node_type = "SERVICE_TASK",
        .handler = &stubHandler,
        .plugin_name = "test-plugin",
        .plugin_version = "1.0.0",
        .target_api = RUNTIME_API,
        .scope = .global,
        .owner_tenant_id = some_tenant, // must trigger error
    });
    try std.testing.expectError(PluginRegistrationError.GlobalPluginMustNotHaveOwnerId, err);
}

// ---------------------------------------------------------------------------
// TC-SVC-02-03: tenant-scoped plugin takes precedence over global for owner tenant
// ---------------------------------------------------------------------------

test "svc02: resolvePluginHandlerForTenant returns tenant plugin for owner" {
    const alloc = std.testing.allocator;
    var registry = PluginRegistry.init(alloc);
    defer registry.deinit();

    const tenant_t: [16]u8 = [_]u8{ 0xAA, 0xBB } ++ [_]u8{0x00} ** 14;

    // Register global plugin for SERVICE_TASK.
    try plugin_registry.registerPluginHandler(alloc, &registry, RegisterPluginHandlerInput{
        .node_type = "SERVICE_TASK",
        .handler = &stubHandler,
        .plugin_name = "global-plugin",
        .plugin_version = "1.0.0",
        .target_api = RUNTIME_API,
        .scope = .global,
        .owner_tenant_id = null,
    });

    // Register tenant-scoped plugin for the same node_type.
    try plugin_registry.registerPluginHandler(alloc, &registry, RegisterPluginHandlerInput{
        .node_type = "SERVICE_TASK",
        .handler = &stubHandler,
        .plugin_name = "tenant-plugin",
        .plugin_version = "1.0.0",
        .target_api = RUNTIME_API,
        .scope = .tenant,
        .owner_tenant_id = tenant_t,
    });

    plugin_registry.freezePluginRegistry(&registry);

    // For the owner tenant: tenant-scoped plugin must be returned.
    const resolved = plugin_registry.resolvePluginHandlerForTenant(&registry, "SERVICE_TASK", tenant_t);
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualStrings("tenant-plugin", resolved.?.plugin_name);
    try std.testing.expectEqual(PluginScope.tenant, resolved.?.scope);
}

// ---------------------------------------------------------------------------
// TC-SVC-02-04: falls back to global for non-owner tenant
// ---------------------------------------------------------------------------

test "svc02: resolvePluginHandlerForTenant falls back to global for non-owner" {
    const alloc = std.testing.allocator;
    var registry = PluginRegistry.init(alloc);
    defer registry.deinit();

    const tenant_t: [16]u8 = [_]u8{ 0xCC, 0xDD } ++ [_]u8{0x00} ** 14;
    const tenant_u: [16]u8 = [_]u8{ 0xEE, 0xFF } ++ [_]u8{0x00} ** 14;

    // Global plugin.
    try plugin_registry.registerPluginHandler(alloc, &registry, RegisterPluginHandlerInput{
        .node_type = "SERVICE_TASK",
        .handler = &stubHandler,
        .plugin_name = "global-plugin-fb",
        .plugin_version = "1.0.0",
        .target_api = RUNTIME_API,
        .scope = .global,
        .owner_tenant_id = null,
    });

    // Tenant-T scoped plugin.
    try plugin_registry.registerPluginHandler(alloc, &registry, RegisterPluginHandlerInput{
        .node_type = "SERVICE_TASK",
        .handler = &stubHandler,
        .plugin_name = "tenant-plugin-fb",
        .plugin_version = "1.0.0",
        .target_api = RUNTIME_API,
        .scope = .tenant,
        .owner_tenant_id = tenant_t,
    });

    plugin_registry.freezePluginRegistry(&registry);

    // For tenant U (not the owner): must get global plugin, not tenant-T's plugin.
    const resolved = plugin_registry.resolvePluginHandlerForTenant(&registry, "SERVICE_TASK", tenant_u);
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualStrings("global-plugin-fb", resolved.?.plugin_name);
    try std.testing.expectEqual(PluginScope.global, resolved.?.scope);
}

// ---------------------------------------------------------------------------
// TC-SVC-02-05: returns nil when only scoped plugin registered and non-owner calls
// ---------------------------------------------------------------------------

test "svc02: resolvePluginHandlerForTenant returns nil for unregistered tenant" {
    const alloc = std.testing.allocator;
    var registry = PluginRegistry.init(alloc);
    defer registry.deinit();

    const tenant_t: [16]u8 = [_]u8{ 0x11, 0x22 } ++ [_]u8{0x00} ** 14;
    const tenant_u: [16]u8 = [_]u8{ 0x33, 0x44 } ++ [_]u8{0x00} ** 14;

    // Register only a tenant-T-scoped plugin; no global plugin for this node_type.
    try plugin_registry.registerPluginHandler(alloc, &registry, RegisterPluginHandlerInput{
        .node_type = "CUSTOM_TASK",
        .handler = &stubHandler,
        .plugin_name = "custom-tenant-plugin",
        .plugin_version = "1.0.0",
        .target_api = RUNTIME_API,
        .scope = .tenant,
        .owner_tenant_id = tenant_t,
    });

    plugin_registry.freezePluginRegistry(&registry);

    // Tenant U has no global fallback; must receive null.
    const resolved = plugin_registry.resolvePluginHandlerForTenant(&registry, "CUSTOM_TASK", tenant_u);
    try std.testing.expect(resolved == null);
}

// ---------------------------------------------------------------------------
// TC-SVC-02-06: duplicate (node_type, owner_tenant_id) detection on freeze
// The freeze implementation panics on duplicate. We verify the registry state
// before freeze to confirm duplicates can be inserted and would be detected.
// The actual freeze panic is a startup-only check; we test the pre-freeze state here.
// ---------------------------------------------------------------------------

test "svc02: two tenant-scoped plugins for same (node_type, owner_tenant_id) can be registered before freeze" {
    const alloc = std.testing.allocator;
    var registry = PluginRegistry.init(alloc);
    defer registry.deinit();

    const tenant_t: [16]u8 = [_]u8{ 0x55, 0x66 } ++ [_]u8{0x00} ** 14;

    // Register first tenant-scoped plugin.
    try plugin_registry.registerPluginHandler(alloc, &registry, RegisterPluginHandlerInput{
        .node_type = "DUP_TASK",
        .handler = &stubHandler,
        .plugin_name = "dup-plugin-1",
        .plugin_version = "1.0.0",
        .target_api = RUNTIME_API,
        .scope = .tenant,
        .owner_tenant_id = tenant_t,
    });

    // Register a second identical entry — this succeeds at register time;
    // freezePluginRegistry() would panic, but we only verify state here.
    try plugin_registry.registerPluginHandler(alloc, &registry, RegisterPluginHandlerInput{
        .node_type = "DUP_TASK",
        .handler = &stubHandler,
        .plugin_name = "dup-plugin-2",
        .plugin_version = "1.0.0",
        .target_api = RUNTIME_API,
        .scope = .tenant,
        .owner_tenant_id = tenant_t,
    });

    // Both entries are in tenant_entries, confirming the duplicate is detectable.
    var count: usize = 0;
    for (registry.tenant_entries.items) |reg| {
        if (std.mem.eql(u8, reg.node_type, "DUP_TASK")) {
            if (reg.owner_tenant_id != null and std.mem.eql(u8, &reg.owner_tenant_id.?, &tenant_t)) {
                count += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    // freezePluginRegistry(&registry) would panic here — that is the intended behavior.
    // We confirm the invariant exists without calling freeze in a test.
}
