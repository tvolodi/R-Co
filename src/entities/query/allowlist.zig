//! QRY-02 — Entity field allowlist loader.
//!
//! Loads filterable/sortable fields from entity_filterable_keys (per-tenant schema)
//! and merges built-in typed columns. Typed columns shadow same-name JSONB keys.

const std = @import("std");
const db = @import("pool");

pub const ColumnKind = enum { typed_column, jsonb_key };

pub const FieldStorageType = enum {
    text,
    numeric,
    boolean,
    timestamptz,

    pub fn fromString(s: []const u8) ?FieldStorageType {
        const map = std.StaticStringMap(FieldStorageType).initComptime(.{
            .{ "text", .text },
            .{ "numeric", .numeric },
            .{ "boolean", .boolean },
            .{ "timestamptz", .timestamptz },
        });
        return map.get(s);
    }
};

pub const AllowlistedField = struct {
    name: []const u8,
    kind: ColumnKind,
    storage_type: FieldStorageType,
    is_sortable: bool,
};

pub const EntityAllowlist = struct {
    fields: []AllowlistedField,

    pub fn find(self: *const EntityAllowlist, name: []const u8) ?AllowlistedField {
        for (self.fields) |f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }
};

pub const AllowlistError = error{ DbError, OutOfMemory };

const BUILTIN_FIELDS = [_]struct {
    name: []const u8,
    storage_type: FieldStorageType,
    is_sortable: bool,
}{
    .{ .name = "record_id", .storage_type = .text, .is_sortable = true },
    .{ .name = "tenant_id", .storage_type = .text, .is_sortable = false },
    .{ .name = "created_at", .storage_type = .timestamptz, .is_sortable = true },
    .{ .name = "updated_at", .storage_type = .timestamptz, .is_sortable = true },
};

pub fn loadAllowlist(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    tenant_id: []const u8,
    entity_key: []const u8,
) AllowlistError!EntityAllowlist {
    _ = tenant_id;

    const rows = conn.query(
        allocator,
        "SELECT key_name, storage_type, is_sortable FROM entity_filterable_keys WHERE entity_key = $1 ORDER BY key_name",
        &.{entity_key},
    ) catch return AllowlistError.DbError;
    var rows_owned = rows;
    defer rows_owned.deinit();

    var fields: std.ArrayList(AllowlistedField) = .empty;
    errdefer {
        for (fields.items) |f| allocator.free(f.name);
        fields.deinit(allocator);
    }

    for (BUILTIN_FIELDS) |bf| {
        const name_copy = allocator.dupe(u8, bf.name) catch return AllowlistError.OutOfMemory;
        fields.append(allocator, .{
            .name = name_copy,
            .kind = .typed_column,
            .storage_type = bf.storage_type,
            .is_sortable = bf.is_sortable,
        }) catch {
            allocator.free(name_copy);
            return AllowlistError.OutOfMemory;
        };
    }

    for (rows_owned.rows) |row| {
        if (row.len < 3) continue;
        const key_name = row[0] orelse continue;
        const storage_type_str = row[1] orelse continue;
        const is_sortable_str = row[2] orelse "t";

        const shadowed = blk: {
            for (BUILTIN_FIELDS) |bf| {
                if (std.mem.eql(u8, bf.name, key_name)) break :blk true;
            }
            break :blk false;
        };
        if (shadowed) continue;

        const storage_type = FieldStorageType.fromString(storage_type_str) orelse .text;
        const is_sortable = std.mem.eql(u8, is_sortable_str, "t") or
            std.mem.eql(u8, is_sortable_str, "true") or
            std.mem.eql(u8, is_sortable_str, "1");

        const name_copy = allocator.dupe(u8, key_name) catch return AllowlistError.OutOfMemory;
        fields.append(allocator, .{
            .name = name_copy,
            .kind = .jsonb_key,
            .storage_type = storage_type,
            .is_sortable = is_sortable,
        }) catch {
            allocator.free(name_copy);
            return AllowlistError.OutOfMemory;
        };
    }

    return EntityAllowlist{ .fields = try fields.toOwnedSlice(allocator) };
}

pub fn deinitAllowlist(allocator: std.mem.Allocator, al: *EntityAllowlist) void {
    for (al.fields) |f| allocator.free(f.name);
    allocator.free(al.fields);
}
