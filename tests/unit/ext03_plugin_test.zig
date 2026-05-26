const std = @import("std");
const bpm = @import("bpm");

const plugin_interface = bpm.plugin_interface;
const plugin_registry = bpm.plugin_registry;

test "EXT-03: plugin registration lifecycle enforces freeze" {
    var registry = plugin_registry.PluginRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try plugin_registry.registerPluginHandler(std.testing.allocator, &registry, .{
        .node_type = "SERVICE_TASK",
        .handler = &completeHandler,
        .plugin_name = "ext03-test",
        .plugin_version = "1.0.0",
        .target_api = .{ .major = 1, .minor = 0 },
    });

    plugin_registry.freezePluginRegistry(&registry);

    try std.testing.expectError(
        error.RegistryLocked,
        plugin_registry.registerPluginHandler(std.testing.allocator, &registry, .{
            .node_type = "HUMAN_TASK",
            .handler = &completeHandler,
            .plugin_name = "ext03-test",
            .plugin_version = "1.0.1",
            .target_api = .{ .major = 1, .minor = 0 },
        }),
    );
}

test "EXT-03: duplicate node type registration is rejected" {
    var registry = plugin_registry.PluginRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try plugin_registry.registerPluginHandler(std.testing.allocator, &registry, .{
        .node_type = "SERVICE_TASK",
        .handler = &completeHandler,
        .plugin_name = "ext03-test-a",
        .plugin_version = "1.0.0",
        .target_api = .{ .major = 1, .minor = 0 },
    });

    try std.testing.expectError(
        error.DuplicateNodeType,
        plugin_registry.registerPluginHandler(std.testing.allocator, &registry, .{
            .node_type = "SERVICE_TASK",
            .handler = &completeHandler,
            .plugin_name = "ext03-test-b",
            .plugin_version = "1.1.0",
            .target_api = .{ .major = 1, .minor = 0 },
        }),
    );
}

test "EXT-03: incompatible major API version is rejected" {
    var registry = plugin_registry.PluginRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try std.testing.expectError(
        error.IncompatibleApiVersion,
        plugin_registry.registerPluginHandler(std.testing.allocator, &registry, .{
            .node_type = "SERVICE_TASK",
            .handler = &completeHandler,
            .plugin_name = "ext03-test",
            .plugin_version = "2.0.0",
            .target_api = .{ .major = 2, .minor = 0 },
        }),
    );
}

test "EXT-03: compatible minor API version is accepted" {
    var registry = plugin_registry.PluginRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try plugin_registry.registerPluginHandler(std.testing.allocator, &registry, .{
        .node_type = "SERVICE_TASK",
        .handler = &completeHandler,
        .plugin_name = "ext03-test",
        .plugin_version = "1.0.0",
        .target_api = .{ .major = 1, .minor = 0 },
    });

    const registration = plugin_registry.resolvePluginHandler(&registry, "SERVICE_TASK");
    try std.testing.expect(registration != null);
}

test "EXT-03: registration rejects empty node type" {
    var registry = plugin_registry.PluginRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try std.testing.expectError(
        error.InvalidNodeType,
        plugin_registry.registerPluginHandler(std.testing.allocator, &registry, .{
            .node_type = "",
            .handler = &completeHandler,
            .plugin_name = "ext03-test",
            .plugin_version = "1.0.0",
            .target_api = .{ .major = 1, .minor = 0 },
        }),
    );
}

test "EXT-03: registration rejects null handler" {
    var registry = plugin_registry.PluginRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try std.testing.expectError(
        error.InvalidHandler,
        plugin_registry.registerPluginHandler(std.testing.allocator, &registry, .{
            .node_type = "SERVICE_TASK",
            .handler = null,
            .plugin_name = "ext03-test",
            .plugin_version = "1.0.0",
            .target_api = .{ .major = 1, .minor = 0 },
        }),
    );
}

test "EXT-03: plugin handler precedence shadows built-in handler" {
    var registry = plugin_registry.PluginRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try plugin_registry.registerPluginHandler(std.testing.allocator, &registry, .{
        .node_type = "SERVICE_TASK",
        .handler = &completeHandler,
        .plugin_name = "ext03-test",
        .plugin_version = "1.0.0",
        .target_api = .{ .major = 1, .minor = 0 },
    });

    const resolved = plugin_registry.resolveNodeHandlerKind(&registry, "SERVICE_TASK", true);
    try std.testing.expect(resolved != null);
    try std.testing.expect(resolved.? == .plugin);
}

test "EXT-03: built-in handler is selected when plugin is not registered" {
    var registry = plugin_registry.PluginRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const resolved = plugin_registry.resolveNodeHandlerKind(&registry, "SERVICE_TASK", true);
    try std.testing.expect(resolved != null);
    try std.testing.expect(resolved.? == .builtin);
}

test "EXT-03: missing plugin and missing built-in returns no handler" {
    var registry = plugin_registry.PluginRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const resolved = plugin_registry.resolveNodeHandlerKind(&registry, "SERVICE_TASK", false);
    try std.testing.expect(resolved == null);
}

test "EXT-03: safe invocation forwards COMPLETE outcome" {
    const ctx = testContext();
    const outcome = try plugin_interface.invokePluginHandlerSafely(
        std.testing.allocator,
        &completeHandler,
        ctx,
    );

    switch (outcome) {
        .COMPLETE => |complete| try std.testing.expect(complete.output_variables_json == null),
        .ERROR => try std.testing.expect(false),
    }
}

test "EXT-03: safe invocation forwards ERROR outcome" {
    const ctx = testContext();
    const outcome = try plugin_interface.invokePluginHandlerSafely(
        std.testing.allocator,
        &errorHandler,
        ctx,
    );

    switch (outcome) {
        .COMPLETE => try std.testing.expect(false),
        .ERROR => |err_outcome| try std.testing.expectEqualStrings("PLUGIN_FAIL", err_outcome.reason),
    }
}

test "EXT-03: COMPLETE outcome with output payload passes validation" {
    try plugin_interface.validateOutcome(.{
        .COMPLETE = .{ .output_variables_json = "{\"plugin\":true}" },
    });
}

test "EXT-03: ERROR outcome with reason passes validation" {
    try plugin_interface.validateOutcome(.{
        .ERROR = .{ .reason = "plugin_error" },
    });
}

test "EXT-03: invocation error reason maps panic to deterministic reason code" {
    const reason = plugin_interface.invocationErrorReason(error.PanicCaught);
    try std.testing.expectEqualStrings("PLUGIN_PANIC_CAUGHT", reason);
}

test "EXT-03: outcome validation rejects empty error reason" {
    try std.testing.expectError(
        error.InvalidErrorReason,
        plugin_interface.validateOutcome(.{
            .ERROR = .{ .reason = "" },
        }),
    );
}

fn completeHandler(
    ctx: plugin_interface.PluginExecutionContext,
) plugin_interface.PluginHandlerInvocationError!plugin_interface.PluginHandlerOutcome {
    _ = ctx;
    return .{
        .COMPLETE = .{ .output_variables_json = null },
    };
}

fn errorHandler(
    ctx: plugin_interface.PluginExecutionContext,
) plugin_interface.PluginHandlerInvocationError!plugin_interface.PluginHandlerOutcome {
    _ = ctx;
    return .{
        .ERROR = .{ .reason = "PLUGIN_FAIL" },
    };
}

fn testContext() plugin_interface.PluginExecutionContext {
    return .{
        .allocator = std.testing.allocator,
        .instance_id = std.mem.zeroes([16]u8),
        .definition_id = [16]u8{1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1},
        .node_id = "node-1",
        .node_type = "SERVICE_TASK",
        .instance_variables_json = "{}",
        .node_config_json = "{}",
        .trace_id = "trace-ext03",
    };
}
