//! Event types and payloads for script failures and errors (LUA-15, LUA-16).
//!
//! Defines event structures for capturing explicit script failures and runtime errors
//! in a structured format that can be emitted to the event store.

const std = @import("std");
const time_source = @import("time_source.zig");
const executor = @import("executor.zig");
const instruction_limiter = @import("instruction_limiter.zig");
const host_context = @import("host_context.zig");

pub const EventType = enum {
    SCRIPT_ERROR,
    SCRIPT_FAILED,

    pub fn toString(self: EventType) []const u8 {
        return switch (self) {
            .SCRIPT_ERROR => "SCRIPT_ERROR",
            .SCRIPT_FAILED => "SCRIPT_FAILED",
        };
    }
};

pub const ScriptErrorPayload = struct {
    error_message: []const u8,
    stack_trace: []const u8,
    instruction_count: u64,
    memory_peak_bytes: u64,
    capabilities_at_failure: []const u8,

    /// LUA-16: free the owned slices. After `deinit`, the fields are set
    /// to empty slices (NOT null) so a second `deinit` is a no-op and the
    /// type stays `[]const u8` (not `?[]const u8`). Per design §10.1.
    pub fn deinit(self: *ScriptErrorPayload, allocator: std.mem.Allocator) void {
        allocator.free(self.error_message);
        self.error_message = &[_]u8{};
        allocator.free(self.stack_trace);
        self.stack_trace = &[_]u8{};
        allocator.free(self.capabilities_at_failure);
        self.capabilities_at_failure = &[_]u8{};
    }
};

pub const ScriptFailedPayload = struct {
    reason: []const u8,
    details: ?executor.ScriptValue,
};

pub const Event = union(EventType) {
    SCRIPT_ERROR: ScriptErrorPayload,
    SCRIPT_FAILED: ScriptFailedPayload,

    pub fn eventType(self: Event) EventType {
        return std.meta.activeTag(self);
    }
};

pub const EventRecord = struct {
    event_type: EventType,
    instance_id: []const u8,
    payload: Event,
    timestamp: time_source.DateTime,
    trace_id: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *EventRecord) void {
        switch (self.payload) {
            .SCRIPT_ERROR => |err_payload| {
                self.allocator.free(err_payload.error_message);
                self.allocator.free(err_payload.stack_trace);
                self.allocator.free(err_payload.capabilities_at_failure);
            },
            .SCRIPT_FAILED => |fail_payload| {
                self.allocator.free(fail_payload.reason);
                if (fail_payload.details) |details| {
                    var details_copy = details;
                    details_copy.deinit(self.allocator);
                }
            },
        }
    }
};

pub const ScriptFailure = struct {
    reason: []const u8,
    details: ?executor.ScriptValue,
    trace_id: []const u8,
    instance_id: []const u8,
};

// ---------------------------------------------------------------------------
// LUA-15 / LUA-16 constructors (iss0625-gh592-lua-12-15-16.md §2.5)
// ---------------------------------------------------------------------------

/// LUA-15: build a `ScriptFailedPayload` from the explicit-failure view the
/// host_context helpers returned. The view's `reason` slice is moved into
/// the payload (no copy); the `details` `ScriptValue` is moved the same
/// way. Caller should free nothing on the view after this — both fields
/// are owned by the payload now.
pub fn buildScriptFailedPayload(
    view: host_context.ExplicitFailureView,
) ScriptFailedPayload {
    return ScriptFailedPayload{
        .reason = view.reason orelse "",
        .details = view.details,
    };
}

/// LUA-16: build a `ScriptErrorPayload` from the captured stack trace and
/// the instruction limiter (if any). Owns the copies inside.
///
/// If `limiter` is null, sets `instruction_count = 0`,
/// `memory_peak_bytes = 0`, and writes `capabilities_at_failure = skip_reason`
/// (decision D-3 in the design). When the limiter is present, the count is
/// read from it (LUA-08); memory peak is left at 0 because LUA-09 lands in
/// a different run.
pub fn buildScriptErrorPayload(
    error_message: []const u8,
    stack_trace: []const u8,
    limiter: ?*const instruction_limiter.InstructionLimiter,
    skip_reason: []const u8,
    allocator: std.mem.Allocator,
) !ScriptErrorPayload {
    const instruction_count: u64 = if (limiter) |l|
        instruction_limiter.getInstructionCount(l)
    else
        0;
    const memory_peak_bytes: u64 = 0; // LUA-09 deferred.
    const capabilities_value: []const u8 = if (limiter == null)
        try allocator.dupe(u8, skip_reason)
    else
        try allocator.dupe(u8, "ok");

    return ScriptErrorPayload{
        .error_message = try allocator.dupe(u8, error_message),
        .stack_trace = try allocator.dupe(u8, stack_trace),
        .instruction_count = instruction_count,
        .memory_peak_bytes = memory_peak_bytes,
        .capabilities_at_failure = capabilities_value,
    };
}
