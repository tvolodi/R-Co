//! Event types and payloads for script failures and errors (LUA-15, LUA-16).
//!
//! Defines event structures for capturing explicit script failures and runtime errors
//! in a structured format that can be emitted to the event store.

const std = @import("std");
const time_source = @import("time_source.zig");
const executor = @import("executor.zig");

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
