//! IDN-05: Per-tenant named-role registry.
//!
//! Provides `TenantRoleStore` for managing the `tenant_role` table and
//! `resolveRoleInTx` for in-transaction ROLE assignee resolution (EE-03).
//!
//! Design artefact: src/design/idn05-role-registry.md
const std = @import("std");
const db = @import("pool");

// ── Uuid type (mirrors definition/graph.zig) ─────────────────────────────────

pub const Uuid = [16]u8;

// ── Domain types ─────────────────────────────────────────────────────────────

/// A single role-to-group binding.  All string fields are caller-owned;
/// call `deinit(allocator)` when the value is no longer needed.
pub const TenantRole = struct {
    id: []const u8,
    name: []const u8,
    group_id: []const u8,
    created_at: i64, // UTC epoch microseconds

    pub fn deinit(self: TenantRole, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.group_id);
    }
};

/// Errors produced by `TenantRoleStore` methods.
pub const TenantRoleError = error{
    GroupNotFound,
    RoleNameInvalid,
    GroupIdInvalid,
    PoolExhausted,
    PersistenceFailed,
    OutOfMemory,
};

// ── TenantRoleStore ───────────────────────────────────────────────────────────

pub const TenantRoleStore = struct {
    pool: *db.Pool,

    pub fn init(pool: *db.Pool) TenantRoleStore {
        return .{ .pool = pool };
    }

    // ── listRoles ─────────────────────────────────────────────────────────────

    /// Return all role bindings for the calling tenant, sorted by name ASC.
    /// Returns an empty slice (not an error) when the table is empty.
    /// Caller owns the returned slice and each element; call `deinit` on each.
    pub fn listRoles(
        self: *TenantRoleStore,
        allocator: std.mem.Allocator,
    ) TenantRoleError![]TenantRole {
        const conn = self.pool.acquire() catch return TenantRoleError.PoolExhausted;
        defer self.pool.release(conn);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var qr = conn.query(
            a,
            \\SELECT id, name, group_id,
            \\    (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint
            \\FROM tenant_role
            \\ORDER BY name ASC
        ,
            &.{},
        ) catch return TenantRoleError.PersistenceFailed;
        defer qr.deinit();

        const roles = allocator.alloc(TenantRole, qr.rows.len) catch return TenantRoleError.OutOfMemory;
        var count: usize = 0;
        errdefer {
            for (roles[0..count]) |r| r.deinit(allocator);
            allocator.free(roles);
        }

        for (qr.rows) |row| {
            const id_raw = colGet(row, 0);
            const name_raw = colGet(row, 1);
            const gid_raw = colGet(row, 2);
            const cat_raw = colGet(row, 3);

            const id = allocator.dupe(u8, id_raw) catch return TenantRoleError.OutOfMemory;
            errdefer allocator.free(id);
            const name_dup = allocator.dupe(u8, name_raw) catch return TenantRoleError.OutOfMemory;
            errdefer allocator.free(name_dup);
            const gid_dup = allocator.dupe(u8, gid_raw) catch return TenantRoleError.OutOfMemory;
            errdefer allocator.free(gid_dup);

            roles[count] = TenantRole{
                .id = id,
                .name = name_dup,
                .group_id = gid_dup,
                .created_at = std.fmt.parseInt(i64, cat_raw, 10) catch 0,
            };
            count += 1;
        }

        return roles;
    }

    // ── upsertRole ────────────────────────────────────────────────────────────

    /// Create or update (re-bind) a role name → group_id mapping.
    ///
    /// Security: all user-supplied values bound as $N positional parameters.
    /// No SQL string interpolation of `name` or `group_id`.
    pub fn upsertRole(
        self: *TenantRoleStore,
        allocator: std.mem.Allocator,
        name: []const u8,
        group_id: []const u8,
    ) TenantRoleError!TenantRole {
        if (!isValidRoleName(name)) return TenantRoleError.RoleNameInvalid;
        if (!isValidUuidHex(group_id)) return TenantRoleError.GroupIdInvalid;

        const conn = self.pool.acquire() catch return TenantRoleError.PoolExhausted;
        defer self.pool.release(conn);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        conn.begin() catch return TenantRoleError.PersistenceFailed;
        errdefer conn.rollback() catch {};

        // Step a: existence check — group must exist in tenant schema.
        // Security: group_id bound as $1::uuid — no interpolation.
        const exists_row = conn.queryRow(
            a,
            "SELECT id FROM groups WHERE id = $1::uuid",
            &.{group_id},
        ) catch return TenantRoleError.PersistenceFailed;

        if (exists_row == null) {
            conn.rollback() catch {};
            return TenantRoleError.GroupNotFound;
        }

        // Step b: upsert binding.
        // Security: $1=name (TEXT), $2=group_id (UUID) — both bound as params.
        var qr = conn.query(
            a,
            \\INSERT INTO tenant_role (name, group_id)
            \\VALUES ($1, $2::uuid)
            \\ON CONFLICT (name) DO UPDATE SET group_id = EXCLUDED.group_id
            \\RETURNING id, name, group_id,
            \\    (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint
        ,
            &.{ name, group_id },
        ) catch return TenantRoleError.PersistenceFailed;
        defer qr.deinit();

        if (qr.rows.len == 0) {
            conn.rollback() catch {};
            return TenantRoleError.PersistenceFailed;
        }

        const row = qr.rows[0];
        const id_raw = colGet(row, 0);
        const name_raw = colGet(row, 1);
        const gid_raw = colGet(row, 2);
        const cat_raw = colGet(row, 3);

        const id = allocator.dupe(u8, id_raw) catch return TenantRoleError.OutOfMemory;
        errdefer allocator.free(id);
        const name_dup = allocator.dupe(u8, name_raw) catch return TenantRoleError.OutOfMemory;
        errdefer allocator.free(name_dup);
        const gid_dup = allocator.dupe(u8, gid_raw) catch return TenantRoleError.OutOfMemory;
        errdefer allocator.free(gid_dup);

        conn.commit() catch return TenantRoleError.PersistenceFailed;

        return TenantRole{
            .id = id,
            .name = name_dup,
            .group_id = gid_dup,
            .created_at = std.fmt.parseInt(i64, cat_raw, 10) catch 0,
        };
    }
};

// ── resolveRoleInTx ───────────────────────────────────────────────────────────

/// Resolve a role name to a group UUID inside an existing DB transaction.
///
/// Called from `applyTransition` in src/engine/instance.zig; does NOT
/// acquire a new connection — uses the caller's already-open `conn`.
/// Returns null if the role is unbound, the table does not exist, or any
/// transient DB error occurs.  Errors are treated as "unbound" so the
/// task activation transaction never fails due to role lookup issues.
///
/// Security: `name` bound as $1 positional parameter — no interpolation.
pub fn resolveRoleInTx(conn: *db.Conn, name: []const u8) ?Uuid {
    // Use the global SMP allocator for the transient query result; the
    // returned Uuid is a value type ([16]u8) that requires no allocation.
    const a = std.heap.smp_allocator;
    const row = conn.queryRow(
        a,
        "SELECT group_id FROM tenant_role WHERE name = $1",
        &.{name},
    ) catch return null;

    const r = row orelse return null;
    defer {
        for (r) |col| if (col) |c| a.free(c);
        a.free(r);
    }

    if (r.len == 0 or r[0] == null) return null;
    return parseUuidHex(r[0].?) catch null;
}

// ── Validation helpers ────────────────────────────────────────────────────────

/// Validate a role name: non-empty, ≤ 128 UTF-8 codepoints, no control chars.
fn isValidRoleName(name: []const u8) bool {
    if (name.len == 0) return false;
    var cp_count: usize = 0;
    var i: usize = 0;
    while (i < name.len) {
        const c = name[i];
        if (c <= 0x1F or c == 0x7F) return false; // ASCII control chars
        const width: usize = if (c & 0x80 == 0) 1 else if (c & 0xE0 == 0xC0) 2 else if (c & 0xF0 == 0xE0) 3 else 4;
        cp_count += 1;
        if (cp_count > 128) return false;
        i += @min(width, name.len - i);
    }
    return true;
}

/// Validate a 36-char UUID hex string (8-4-4-4-12 format with hyphens).
fn isValidUuidHex(s: []const u8) bool {
    if (s.len != 36) return false;
    for (s, 0..) |c, i| {
        const is_dash_pos = (i == 8 or i == 13 or i == 18 or i == 23);
        if (is_dash_pos) {
            if (c != '-') return false;
        } else {
            if (!std.ascii.isHex(c)) return false;
        }
    }
    return true;
}

/// Parse a 36-char UUID hex string to a raw [16]u8 Uuid value.
fn parseUuidHex(hex: []const u8) error{InvalidUuid}!Uuid {
    if (hex.len != 36) return error.InvalidUuid;
    var uuid: Uuid = undefined;
    var byte_idx: usize = 0;
    var i: usize = 0;
    while (i < hex.len) {
        if (hex[i] == '-') {
            i += 1;
            continue;
        }
        if (i + 1 >= hex.len or byte_idx >= 16) return error.InvalidUuid;
        const hi = std.fmt.charToDigit(hex[i], 16) catch return error.InvalidUuid;
        const lo = std.fmt.charToDigit(hex[i + 1], 16) catch return error.InvalidUuid;
        uuid[byte_idx] = (hi << 4) | lo;
        byte_idx += 1;
        i += 2;
    }
    if (byte_idx != 16) return error.InvalidUuid;
    return uuid;
}

/// Safe column accessor: returns "" for out-of-range or NULL columns.
fn colGet(row: []?[]u8, idx: usize) []const u8 {
    if (idx >= row.len) return "";
    return row[idx] orelse "";
}
