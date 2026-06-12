//! Entity event types — EXP-202
//!
//! Defines the three entity event types and provides helpers for building
//! event payloads for ENTITY_RECORD_CREATED, ENTITY_RECORD_UPDATED, and
//! ENTITY_RECORD_DELETED.
//!
//! Design artefact: src/design/entities.md (Entity event family section)

const std = @import("std");
const entities_mod = @import("mod.zig");

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

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

pub const EntityEventPayload = struct {
    entity_type: []const u8,
    entity_def_version: u32,
    record_id: []const u8,
    field_values: []const u8,
    changed_fields: ?[]const u8 = null,
    prior_field_values: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Payload builders
// ---------------------------------------------------------------------------

/// Build a CREATED event payload as JSON bytes.
/// Caller owns the returned slice.
pub fn buildCreatedPayload(
    allocator: std.mem.Allocator,
    entity_type: []const u8,
    entity_def_version: u32,
    record_id: []const u8,
    field_values: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"entity_type":"{s}","entity_def_version":{d},"record_id":"{s}","field_values":{s}}}
    , .{ entity_type, entity_def_version, record_id, field_values });
}

/// Build an UPDATED event payload as JSON bytes.
/// Caller owns the returned slice.
pub fn buildUpdatedPayload(
    allocator: std.mem.Allocator,
    entity_type: []const u8,
    entity_def_version: u32,
    record_id: []const u8,
    field_values: []const u8,
    changed_fields: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"entity_type":"{s}","entity_def_version":{d},"record_id":"{s}","field_values":{s},"changed_fields":{s}}}
    , .{ entity_type, entity_def_version, record_id, field_values, changed_fields });
}

/// Build a DELETED event payload as JSON bytes.
/// Caller owns the returned slice.
pub fn buildDeletedPayload(
    allocator: std.mem.Allocator,
    entity_type: []const u8,
    entity_def_version: u32,
    record_id: []const u8,
    prior_field_values: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"entity_type":"{s}","entity_def_version":{d},"record_id":"{s}","prior_field_values":{s}}}
    , .{ entity_type, entity_def_version, record_id, prior_field_values });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "buildCreatedPayload produces valid JSON" {
    const payload = try buildCreatedPayload(std.testing.allocator, "customer", 1, "550e8400-e29b-41d4-a716-446655440000",
        \\{"email":"test@example.com"}
    );
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "ENTITY_RECORD_CREATED") == null); // payload, not type
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"entity_type\":\"customer\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"entity_def_version\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"record_id\":\"550e8400") != null);
}

test "EntityEventType wireName" {
    try std.testing.expectEqualStrings("ENTITY_RECORD_CREATED", EntityEventType.entity_record_created.wireName());
    try std.testing.expectEqualStrings("ENTITY_RECORD_UPDATED", EntityEventType.entity_record_updated.wireName());
    try std.testing.expectEqualStrings("ENTITY_RECORD_DELETED", EntityEventType.entity_record_deleted.wireName());
}
