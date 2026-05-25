const std = @import("std");

pub const PluginApiVersion = struct {
    major: u16,
    minor: u16,
};

pub const PluginExecutionContext = struct {
    allocator: std.mem.Allocator,
    instance_id: [16]u8,
    definition_id: [16]u8,
    node_id: []const u8,
    node_type: []const u8,
    instance_variables_json: []const u8,
    node_config_json: []const u8,
    trace_id: []const u8,
};

pub const PluginCompleteOutcome = struct {
    output_variables_json: ?[]const u8,
};

pub const PluginErrorOutcome = struct {
    reason: []const u8,
};

pub const PluginHandlerOutcomeTag = enum {
    COMPLETE,
    ERROR,
};

pub const PluginHandlerOutcome = union(PluginHandlerOutcomeTag) {
    COMPLETE: PluginCompleteOutcome,
    ERROR: PluginErrorOutcome,
};

pub const PluginHandlerInvocationError = error{
    PanicCaught,
    InvalidOutcome,
    InvalidOutputVariables,
    InvalidErrorReason,
    OutOfMemory,
};

pub const PluginNodeHandler = fn (
    ctx: PluginExecutionContext,
) PluginHandlerInvocationError!PluginHandlerOutcome;

pub const PluginNodeHandlerPtr = *const PluginNodeHandler;

pub fn invokePluginHandlerSafely(
    allocator: std.mem.Allocator,
    handler: PluginNodeHandlerPtr,
    ctx: PluginExecutionContext,
) PluginHandlerInvocationError!PluginHandlerOutcome {
    _ = allocator;
    return handler(ctx);
}

pub fn validateOutcome(
    outcome: PluginHandlerOutcome,
) PluginHandlerInvocationError!void {
    switch (outcome) {
        .COMPLETE => {},
        .ERROR => |err_outcome| {
            if (err_outcome.reason.len == 0) return error.InvalidErrorReason;
        },
    }
}

pub fn invocationErrorReason(invocation_err: PluginHandlerInvocationError) []const u8 {
    return switch (invocation_err) {
        error.PanicCaught => "PLUGIN_PANIC_CAUGHT",
        error.InvalidOutcome => "PLUGIN_OUTCOME_INVALID",
        error.InvalidOutputVariables => "PLUGIN_OUTPUT_INVALID",
        error.InvalidErrorReason => "PLUGIN_ERROR_REASON_INVALID",
        error.OutOfMemory => "PLUGIN_OUT_OF_MEMORY",
    };
}
