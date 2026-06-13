//! Entity event types and payload builders — EXP-201/202
//!
//! Defines the event types and payload construction helpers for the entity
//! record subsystem.
const std = @import("std");

pub const EntityEventType = enum {
    entity_record_created,
    entity_record_updated,
    entity_record_deleted,

    pub fn wireName(self: EntityEventType) []const u8 {
        return switch (self) {
            .entity_record_created => "ENTITY_RECORD_CREATED",
            .entity_record_updated => "ENTITY_RECORD_UPDATED",
            .entity_record_deleted => "ENTITY_RECORD_DELETED",
        };
    }
};

/// Build JSON payload for ENTITY_RECORD_CREATED event.
pub fn buildCreatedPayload(
    allocator: std.mem.Allocator,
    entity_type: []const u8,
    logical_shape_version: []const u8,
    record_id: []const u8,
    field_values: []const u8,
) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"entity_type\":\"{s}\",\"logical_shape_version\":\"{s}\",\"record_id\":\"{s}\",\"field_values\":{s}}}",
        .{ entity_type, logical_shape_version, record_id, field_values },
    );
}

/// Build JSON payload for ENTITY_RECORD_UPDATED event.
pub fn buildUpdatedPayload(
    allocator: std.mem.Allocator,
    entity_type: []const u8,
    record_id: []const u8,
    field_values: []const u8,
) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"entity_type\":\"{s}\",\"record_id\":\"{s}\",\"field_values\":{s}}}",
        .{ entity_type, record_id, field_values },
    );
}

/// Build JSON payload for ENTITY_RECORD_DELETED event.
pub fn buildDeletedPayload(
    allocator: std.mem.Allocator,
    entity_type: []const u8,
    record_id: []const u8,
) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"entity_type\":\"{s}\",\"record_id\":\"{s}\"}}",
        .{ entity_type, record_id },
    );
}
