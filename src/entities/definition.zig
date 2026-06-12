//! Entity definition CRUD — EXP-201
//!
//! Manages entity_definitions table: create, read, list, getByType.
//! Integrates with the repository artifact system (kind = "entity") for
//! canonicalisation, hashing, and versioning.
//!
//! Design artefact: src/design/entities.md

const std = @import("std");
const db = @import("pool");
const canonicaliser = @import("../repository/canonicaliser.zig");
const validator_mod = @import("validator.zig");
const entities_mod = @import("mod.zig");

const Pool = db.Pool;
const PoolError = db.PoolError;
const Uuid = entities_mod.Uuid;
const DEFAULT_TENANT_ID = entities_mod.DEFAULT_TENANT_ID;

// ---------------------------------------------------------------------------
// Public error set
// ---------------------------------------------------------------------------

pub const EntityDefinitionError = error{
    PoolExhausted,
    DefinitionNotFound,
    DefinitionNameExists,
    DefinitionNotActive,
    InvalidJson,
    ContentHashInvalid,
    TransactionFailed,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

pub const DefinitionRecord = struct {
    id: []const u8,
    tenant_id: []const u8,
    name: []const u8,
    display_name: []const u8,
    description: ?[]const u8,
    definition_json: []const u8,
    content_hash: []const u8,
    logical_shape_version: u32,
    status: []const u8,
    created_by: []const u8,
    created_at: i64,
    updated_at: i64,

    pub fn deinit(self: *DefinitionRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.tenant_id);
        allocator.free(self.name);
        allocator.free(self.display_name);
        if (self.description) |d| allocator.free(d);
        allocator.free(self.definition_json);
        allocator.free(self.content_hash);
        allocator.free(self.status);
        allocator.free(self.created_by);
    }
};

pub const CreateDefinitionParams = struct {
    name: []const u8,
    display_name: []const u8,
    description: ?[]const u8,
    definition_json: []const u8,
    created_by: []const u8,
    tenant_id: []const u8 = DEFAULT_TENANT_ID,
};

pub const ListDefinitionsOpts = struct {
    tenant_id: []const u8 = DEFAULT_TENANT_ID,
    status: ?[]const u8 = null,
    cursor: ?[]const u8 = null,
    page_size: u16 = 50,
};

// ---------------------------------------------------------------------------
// Row helpers
// ---------------------------------------------------------------------------

fn freeRow(allocator: std.mem.Allocator, row: []?[]u8) void {
    for (row) |*col| if (col.*) |*v| allocator.free(v.*);
    allocator.free(row);
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Create a new entity definition. Validates, canonicalises, hashes, and
/// stores in entity_definitions table.
pub fn createDefinition(
    allocator: std.mem.Allocator,
    pool: *Pool,
    params: CreateDefinitionParams,
) EntityDefinitionError!DefinitionRecord {
    // Canonicalise the definition JSON
    const canonical = canonicaliser.canonicaliseJson(allocator, params.definition_json) catch |err| switch (err) {
        error.InvalidJson, error.InvalidBinary, error.NoSpaceLeft => return EntityDefinitionError.InvalidJson,
        error.OutOfMemory => return EntityDefinitionError.OutOfMemory,
    };
    defer allocator.free(canonical);

    // Hash the canonical form
    const content_hash = canonicaliser.hashContent(allocator, canonical, "application/json") catch |err| switch (err) {
        error.InvalidJson, error.InvalidBinary, error.NoSpaceLeft => return EntityDefinitionError.InvalidJson,
        error.OutOfMemory => return EntityDefinitionError.OutOfMemory,
    };

    const hash_hex = try bytesToHex(allocator, &content_hash);
    defer allocator.free(hash_hex);

    // Check for existing definition with same name+hash (idempotent)
    const existing = findByNameAndHash(allocator, pool, params.tenant_id, params.name, hash_hex) catch null;
    if (existing) |rec| return rec;

    // Compute next logical_shape_version for this (tenant, name)
    const next_version = getNextShapeVersion(allocator, pool, params.tenant_id, params.name) catch 1;
    const ver_str = std.fmt.allocPrint(allocator, "{d}", .{next_version}) catch return EntityDefinitionError.OutOfMemory;
    defer allocator.free(ver_str);

    const conn = pool.acquire() catch |err| switch (err) {
        PoolError.ExhaustedPool => return EntityDefinitionError.PoolExhausted,
        else => return EntityDefinitionError.TransactionFailed,
    };
    defer pool.release(conn);

    const row = conn.queryRow(allocator,
        \\INSERT INTO entity_definitions (tenant_id, name, display_name, description, definition_json, content_hash, logical_shape_version, created_by, status)
        \\VALUES ($1, $2, $3, $4, $5::jsonb, decode($6, 'hex'), $7::integer, $8::uuid, 'DRAFT')
        \\RETURNING id::text, tenant_id::text, name, display_name, description, definition_json::text, encode(content_hash, 'hex'), logical_shape_version::text, status, created_by::text, extract(epoch from created_at)::bigint * 1000000 as created_at, extract(epoch from updated_at)::bigint * 1000000 as updated_at
    , &[_][]const u8{
        params.tenant_id,
        params.name,
        params.display_name,
        params.description orelse "",
        canonical,
        hash_hex,
        ver_str,
        params.created_by,
    }) catch |err| switch (err) {
        PoolError.ExhaustedPool => return EntityDefinitionError.PoolExhausted,
        else => return EntityDefinitionError.TransactionFailed,
    };
    if (row == null) return EntityDefinitionError.TransactionFailed;
    defer freeRow(allocator, row.?);

    return parseDefinitionRow(allocator, row.?);
}

/// Get a definition by ID.
pub fn getDefinition(
    allocator: std.mem.Allocator,
    pool: *Pool,
    definition_id: []const u8,
) EntityDefinitionError!DefinitionRecord {
    const conn = pool.acquire() catch |err| switch (err) {
        PoolError.ExhaustedPool => return EntityDefinitionError.PoolExhausted,
        else => return EntityDefinitionError.TransactionFailed,
    };
    defer pool.release(conn);

    const row = conn.queryRow(allocator,
        \\SELECT id::text, tenant_id::text, name, display_name, description, definition_json::text, encode(content_hash, 'hex'), logical_shape_version::text, status, created_by::text, extract(epoch from created_at)::bigint * 1000000 as created_at, extract(epoch from updated_at)::bigint * 1000000 as updated_at
        \\FROM entity_definitions WHERE id = $1::uuid
    , &[_][]const u8{definition_id}) catch |err| switch (err) {
        PoolError.ExhaustedPool => return EntityDefinitionError.PoolExhausted,
        else => return EntityDefinitionError.TransactionFailed,
    };
    if (row == null) return EntityDefinitionError.DefinitionNotFound;
    defer freeRow(allocator, row.?);

    return try parseDefinitionRow(allocator, row.?);
}

/// Get the active definition by entity type name for a tenant.
pub fn getDefinitionByName(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id: []const u8,
    name: []const u8,
) EntityDefinitionError!DefinitionRecord {
    const conn = pool.acquire() catch |err| switch (err) {
        PoolError.ExhaustedPool => return EntityDefinitionError.PoolExhausted,
        else => return EntityDefinitionError.TransactionFailed,
    };
    defer pool.release(conn);

    const row = conn.queryRow(allocator,
        \\SELECT id::text, tenant_id::text, name, display_name, description, definition_json::text, encode(content_hash, 'hex'), logical_shape_version::text, status, created_by::text, extract(epoch from created_at)::bigint * 1000000 as created_at, extract(epoch from updated_at)::bigint * 1000000 as updated_at
        \\FROM entity_definitions
        \\WHERE tenant_id = $1 AND name = $2 AND status = 'ACTIVE'
        \\ORDER BY logical_shape_version DESC
        \\LIMIT 1
    , &[_][]const u8{ tenant_id, name }) catch |err| switch (err) {
        PoolError.ExhaustedPool => return EntityDefinitionError.PoolExhausted,
        else => return EntityDefinitionError.TransactionFailed,
    };
    if (row == null) return EntityDefinitionError.DefinitionNotFound;
    defer freeRow(allocator, row.?);

    return parseDefinitionRow(allocator, row.?);
}

/// List entity definitions with optional filters and pagination.
/// Caller owns the returned slice and must free each record and the slice.
pub fn listDefinitions(
    allocator: std.mem.Allocator,
    pool: *Pool,
    opts: ListDefinitionsOpts,
) EntityDefinitionError![]DefinitionRecord {
    const conn = pool.acquire() catch |err| switch (err) {
        PoolError.ExhaustedPool => return EntityDefinitionError.PoolExhausted,
        else => return EntityDefinitionError.TransactionFailed,
    };
    defer pool.release(conn);

    const has_status = opts.status != null and opts.status.?.len > 0;
    const limit = if (opts.page_size > 0) opts.page_size else 50;

    var sql: std.ArrayList(u8) = .empty;
    errdefer sql.deinit(allocator);
    sql.appendSlice(allocator,
        \\SELECT id::text, tenant_id::text, name, display_name, description, definition_json::text, encode(content_hash, 'hex'), logical_shape_version::text, status, created_by::text, extract(epoch from created_at)::bigint * 1000000 as created_at, extract(epoch from updated_at)::bigint * 1000000 as updated_at
        \\FROM entity_definitions
        \\WHERE tenant_id = $1
    ) catch return EntityDefinitionError.OutOfMemory;

    var params = std.ArrayList([]const u8).initCapacity(allocator, 8) catch return EntityDefinitionError.OutOfMemory;
    errdefer {
        sql.deinit(allocator);
        params.deinit(allocator);
    }
    params.append(allocator, opts.tenant_id) catch return EntityDefinitionError.OutOfMemory;

    if (has_status) {
        const param_idx = params.items.len + 1;
        const clause = std.fmt.allocPrint(allocator, " AND status = ${d}", .{param_idx}) catch return EntityDefinitionError.OutOfMemory;
        defer allocator.free(clause);
        sql.appendSlice(allocator, clause) catch return EntityDefinitionError.OutOfMemory;
        params.append(allocator, opts.status.?) catch return EntityDefinitionError.OutOfMemory;
    }

    sql.appendSlice(allocator, " ORDER BY name, logical_shape_version DESC") catch return EntityDefinitionError.OutOfMemory;
    const limit_clause = std.fmt.allocPrint(allocator, " LIMIT {d}", .{limit}) catch return EntityDefinitionError.OutOfMemory;
    defer allocator.free(limit_clause);
    sql.appendSlice(allocator, limit_clause) catch return EntityDefinitionError.OutOfMemory;

    var result = conn.query(allocator, sql.items, params.items) catch |err| switch (err) {
        PoolError.ExhaustedPool => return EntityDefinitionError.PoolExhausted,
        else => return EntityDefinitionError.TransactionFailed,
    };
    defer {
        for (result.rows) |row| {
            for (row) |*col| if (col.*) |*v| allocator.free(v.*);
            allocator.free(row);
        }
        allocator.free(result.rows);
        result.deinit();
    }
    sql.deinit(allocator);
    params.deinit(allocator);

    var results: std.ArrayList(DefinitionRecord) = .empty;
    errdefer {
        for (results.items) |*rec| {
            var r = rec.*;
            r.deinit(allocator);
        }
        results.deinit(allocator);
    }
    for (result.rows) |row| {
        results.append(allocator, parseDefinitionRow(allocator, row) catch continue) catch continue;
    }
    return results.toOwnedSlice(allocator);
}

/// Activate a definition by ID (sets status = 'ACTIVE').
pub fn activateDefinition(
    allocator: std.mem.Allocator,
    pool: *Pool,
    definition_id: []const u8,
) EntityDefinitionError!DefinitionRecord {
    const conn = pool.acquire() catch |err| switch (err) {
        PoolError.ExhaustedPool => return EntityDefinitionError.PoolExhausted,
        else => return EntityDefinitionError.TransactionFailed,
    };
    defer pool.release(conn);

    const row = conn.queryRow(allocator,
        \\UPDATE entity_definitions SET status = 'ACTIVE', updated_at = NOW()
        \\WHERE id = $1::uuid
        \\RETURNING id::text, tenant_id::text, name, display_name, description, definition_json::text, encode(content_hash, 'hex'), logical_shape_version::text, status, created_by::text, extract(epoch from created_at)::bigint * 1000000 as created_at, extract(epoch from updated_at)::bigint * 1000000 as updated_at
    , &[_][]const u8{definition_id}) catch |err| switch (err) {
        PoolError.ExhaustedPool => return EntityDefinitionError.PoolExhausted,
        else => return EntityDefinitionError.TransactionFailed,
    };
    if (row == null) return EntityDefinitionError.DefinitionNotFound;
    defer freeRow(allocator, row.?);

    return parseDefinitionRow(allocator, row.?);
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn findByNameAndHash(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id: []const u8,
    name: []const u8,
    hash_hex: []const u8,
) EntityDefinitionError!?DefinitionRecord {
    const conn = pool.acquire() catch return null;
    defer pool.release(conn);

    const row = conn.queryRow(allocator,
        \\SELECT id::text, tenant_id::text, name, display_name, description, definition_json::text, encode(content_hash, 'hex'), logical_shape_version::text, status, created_by::text, extract(epoch from created_at)::bigint * 1000000 as created_at, extract(epoch from updated_at)::bigint * 1000000 as updated_at
        \\FROM entity_definitions
        \\WHERE tenant_id = $1 AND name = $2 AND content_hash = decode($3, 'hex')
        \\ORDER BY logical_shape_version DESC LIMIT 1
    , &[_][]const u8{ tenant_id, name, hash_hex }) catch return null;
    if (row == null) return null;
    defer freeRow(allocator, row.?);

    return try parseDefinitionRow(allocator, row.?);
}

fn getNextShapeVersion(
    allocator: std.mem.Allocator,
    pool: *Pool,
    tenant_id: []const u8,
    name: []const u8,
) !u32 {
    const conn = pool.acquire() catch return 1;
    defer pool.release(conn);

    const row = conn.queryRow(allocator,
        \\SELECT (COALESCE(MAX(logical_shape_version), 0) + 1)::text as next_ver
        \\FROM entity_definitions
        \\WHERE tenant_id = $1 AND name = $2
    , &[_][]const u8{ tenant_id, name }) catch return 1;
    if (row == null) return 1;
    defer freeRow(allocator, row.?);
    if (row.?[0] == null) return 1;
    return std.fmt.parseInt(u32, row.?[0].?, 10) catch 1;
}

fn parseDefinitionRow(allocator: std.mem.Allocator, row: []?[]u8) EntityDefinitionError!DefinitionRecord {
    return DefinitionRecord{
        .id = allocator.dupe(u8, row[0] orelse "") catch return EntityDefinitionError.OutOfMemory,
        .tenant_id = allocator.dupe(u8, row[1] orelse DEFAULT_TENANT_ID) catch return EntityDefinitionError.OutOfMemory,
        .name = allocator.dupe(u8, row[2] orelse "unknown") catch return EntityDefinitionError.OutOfMemory,
        .display_name = allocator.dupe(u8, row[3] orelse "Unknown") catch return EntityDefinitionError.OutOfMemory,
        .description = if (row[4]) |d| allocator.dupe(u8, d) catch return EntityDefinitionError.OutOfMemory else null,
        .definition_json = allocator.dupe(u8, row[5] orelse "{}") catch return EntityDefinitionError.OutOfMemory,
        .content_hash = allocator.dupe(u8, row[6] orelse "") catch return EntityDefinitionError.OutOfMemory,
        .logical_shape_version = std.fmt.parseInt(u32, row[7] orelse "1", 10) catch 1,
        .status = allocator.dupe(u8, row[8] orelse "DRAFT") catch return EntityDefinitionError.OutOfMemory,
        .created_by = allocator.dupe(u8, row[9] orelse "") catch return EntityDefinitionError.OutOfMemory,
        .created_at = std.fmt.parseInt(i64, row[10] orelse "0", 10) catch 0,
        .updated_at = std.fmt.parseInt(i64, row[11] orelse "0", 10) catch 0,
    };
}

fn bytesToHex(allocator: std.mem.Allocator, bytes: *const [32]u8) ![]const u8 {
    var result = try allocator.alloc(u8, 64);
    const hex_chars = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        result[i * 2] = hex_chars[byte >> 4];
        result[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return result;
}
