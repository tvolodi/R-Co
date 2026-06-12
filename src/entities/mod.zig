//! Dynamic Entity Subsystem — EXP-201, EXP-202
//!
//! Public re-exports for the entities module. Each sub-module is documented
//! individually. The module introduces a first-class dynamic-entity abstraction
//! where entity types are defined by JSON schemas and entity records are
//! managed exclusively through event-sourced commands.
//!
//! Design artefact: src/design/entities.md

pub const definition = @import("definition.zig");
pub const validator = @import("validator.zig");
pub const commands = @import("commands.zig");
pub const projector = @import("projector.zig");
pub const events = @import("events.zig");

pub const EntityDefinitionError = definition.EntityDefinitionError;
pub const EntityValidationError = validator.EntityValidationError;
pub const EntityCommandError = commands.EntityCommandError;
pub const EntityProjectorError = projector.EntityProjectorError;

pub const DefinitionRecord = definition.DefinitionRecord;
pub const CreateDefinitionParams = definition.CreateDefinitionParams;
pub const ListDefinitionsOpts = definition.ListDefinitionsOpts;

pub const ValidationError = validator.ValidationError;
pub const FieldDef = validator.FieldDef;
pub const FieldType = validator.FieldType;
pub const IndexDef = validator.IndexDef;
pub const FKDef = validator.FKDef;
pub const ConstraintDef = validator.ConstraintDef;

pub const RecordResult = commands.RecordResult;
pub const CreateRecordParams = commands.CreateRecordParams;
pub const UpdateRecordParams = commands.UpdateRecordParams;
pub const DeleteRecordParams = commands.DeleteRecordParams;

pub const RecordSnapshot = projector.RecordSnapshot;

pub const EntityEventType = events.EntityEventType;

const std = @import("std");

/// Raw 16-byte UUID v4 representation (re-exported for convenience).
pub const Uuid = [16]u8;

/// Default tenant ID constant (matches event_store).
pub const DEFAULT_TENANT_ID = "00000000-0000-0000-0000-000000000000";

/// Parse a UUID string into 16 bytes. Returns error if the string is not
/// a valid UUID format.
pub fn parseUuid(str: []const u8) !Uuid {
    if (str.len != 36) return error.InvalidUuid;
    var result: Uuid = undefined;
    var byte_idx: usize = 0;
    var i: usize = 0;
    while (i < 36 and byte_idx < 16) : (i += 1) {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (str[i] != '-') return error.InvalidUuid;
            continue;
        }
        const hi = try hexChar(str[i]);
        i += 1;
        if (i >= 36) return error.InvalidUuid;
        const lo = try hexChar(str[i]);
        result[byte_idx] = (hi << 4) | lo;
        byte_idx += 1;
    }
    if (byte_idx != 16) return error.InvalidUuid;
    return result;
}

fn hexChar(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidUuid,
    };
}

/// Format a 16-byte UUID as a lowercase string. Caller must free the result.
pub fn formatUuid(allocator: std.mem.Allocator, uuid: Uuid) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{
            uuid[0],  uuid[1],  uuid[2],  uuid[3],
            uuid[4],  uuid[5],  uuid[6],  uuid[7],
            uuid[8],  uuid[9],  uuid[10], uuid[11],
            uuid[12], uuid[13], uuid[14], uuid[15],
        },
    );
}

/// Check if a UUID is all zeros (nil UUID).
pub fn isNilUuid(uuid: Uuid) bool {
    return @as(u128, @bitCast(uuid)) == 0;
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "parseUuid valid" {
    const uuid = try parseUuid("550e8400-e29b-41d4-a716-446655440000");
    try std.testing.expect(uuid[0] == 0x55);
    try std.testing.expect(uuid[15] == 0x00);
}

test "parseUuid invalid length" {
    _ = parseUuid("short") catch |err| {
        try std.testing.expect(err == error.InvalidUuid);
        return;
    };
    try std.testing.expect(false);
}

test "formatUuid round-trip" {
    const input = "550e8400-e29b-41d4-a716-446655440000";
    const uuid = try parseUuid(input);
    const formatted = try formatUuid(std.testing.allocator, uuid);
    defer std.testing.allocator.free(formatted);
    try std.testing.expectEqualStrings(input, formatted);
}

test "isNilUuid" {
    try std.testing.expect(isNilUuid(.{0} ** 16));
    try std.testing.expect(!isNilUuid(try parseUuid("550e8400-e29b-41d4-a716-446655440000")));
}
