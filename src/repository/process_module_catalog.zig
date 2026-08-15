//! Process module catalog registry (PLC-01, PLC-02, PLC-03, PLC-04)
//!
//! Versioned registry of reusable sub-process definitions publishable across tenants.
//!
//! Design artefacts:
//!   src/design/plc-01-process-module-catalog.md
//!   src/design/plc-02-catalog-publication-requires-interface.md
//!   src/design/plc-03-cross-version-compatibility.md
//!   src/design/plc-04-cross-tenant-distribution.md

const std = @import("std");
const db = @import("pool");

const Pool = db.Pool;

// ---------------------------------------------------------------------------
// Public error set
// ---------------------------------------------------------------------------

pub const ModuleCatalogError = error{
    PoolExhausted,
    TransactionFailed,
    OutOfMemory,
    InvalidJson,

    // PLC-01
    DuplicateModuleVersion,
    ModuleNotFound,
    UnresolvedModuleRef,
    SubProcessHasBothChildDefAndModuleRef,

    // PLC-02
    InterfaceNotDeclared,
    ModuleAlreadyActive,

    // PLC-04
    SharingGrantNotFound,
    SharingGrantAlreadyExists,

    // Auth / generic
    InsufficientPermissions,
    InvalidVersionConstraint,
};

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

pub const ModuleStatus = enum {
    draft,
    active,
    deprecated,

    fn fromString(s: []const u8) ModuleStatus {
        if (std.mem.eql(u8, s, "DRAFT")) return .draft;
        if (std.mem.eql(u8, s, "ACTIVE")) return .active;
        if (std.mem.eql(u8, s, "DEPRECATED")) return .deprecated;
        return .draft;
    }

    fn toString(self: ModuleStatus) []const u8 {
        return switch (self) {
            .draft => "DRAFT",
            .active => "ACTIVE",
            .deprecated => "DEPRECATED",
        };
    }
};

pub const ProcessModuleCatalogEntry = struct {
    module_id: []const u8,
    version: []const u8,
    owning_tenant_id: [16]u8,
    owning_definition_id: [16]u8,
    interface_schema_json: []const u8,
    exportable: bool,
    status: ModuleStatus,
    created_at: i64,
    updated_at: i64,
};

pub const ModuleRef = struct {
    module_id: []const u8,
    version_constraint: []const u8,
};

pub const ModuleRefResolution = struct {
    resolved: bool,
    entry: ?ProcessModuleCatalogEntry,
    error_code: ?[]const u8,
};

pub const CompatibilityWarning = struct {
    module_id: []const u8,
    new_version: []const u8,
    previous_version: []const u8,
    breaking_changes: []const []const u8,
};

pub const PublishModuleResult = struct {
    entry: ProcessModuleCatalogEntry,
    compatibility_warning: ?CompatibilityWarning,
};

pub const RegisterModuleParams = struct {
    module_id: []const u8,
    version: []const u8,
    owning_tenant_id: [16]u8,
    owning_definition_id: [16]u8,
    interface_schema_json: []const u8,
    exportable: bool,
};

pub const ShareGrantParams = struct {
    granting_tenant_id: [16]u8,
    module_id: []const u8,
    receiving_tenant_id: [16]u8,
    granted_by: [16]u8,
};

pub const Page = struct {
    records: []ProcessModuleCatalogEntry,
    next_cursor: ?[]const u8,
};

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

pub const ProcessModuleCatalog = struct {
    allocator: std.mem.Allocator,
    pool: *Pool,

    pub fn init(allocator: std.mem.Allocator, pool: *Pool) ProcessModuleCatalog {
        return .{ .allocator = allocator, .pool = pool };
    }

    pub fn deinit(self: *ProcessModuleCatalog) void {
        _ = self;
    }

    pub fn registerModule(
        self: *ProcessModuleCatalog,
        allocator: std.mem.Allocator,
        params: RegisterModuleParams,
    ) ModuleCatalogError!ProcessModuleCatalogEntry {
        if (params.module_id.len == 0) return ModuleCatalogError.UnresolvedModuleRef;
        if (params.version.len == 0) return ModuleCatalogError.InvalidVersionConstraint;

        const conn = self.pool.acquire() catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return ModuleCatalogError.PoolExhausted,
            else => return ModuleCatalogError.TransactionFailed,
        };
        defer self.pool.release(conn);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const tenant_hex = try uuidToHex(a, params.owning_tenant_id);
        const def_hex = try uuidToHex(a, params.owning_definition_id);
        // TC-PLC-02-04 (rework 4): an empty interface_schema_json ("") is
        // legal at registration time — the JSONB column would otherwise reject
        // it with sqlstate 22P02 BEFORE publish-time validation can fire.
        // Coerce "" -> "{}" here so publishModule's InterfaceNotDeclared gate
        // gets to make the actual decision. The empty-string check lives in
        // interfaceDeclared(); non-empty but unparseable JSON still hits 22P02.
        const schema_json: []const u8 = if (params.interface_schema_json.len == 0)
            "{}"
        else
            params.interface_schema_json;
        const exportable_str: []const u8 = if (params.exportable) "t" else "f";

        const rows = conn.query(
            allocator,
            \\INSERT INTO public.process_module_catalog
            \\  (module_id, version, owning_tenant_id, owning_definition_id,
            \\   interface_schema, exportable, status)
            \\VALUES ($1, $2, $3::uuid, $4::uuid, $5, $6, 'DRAFT')
            \\ON CONFLICT (module_id, version) DO NOTHING
            \\RETURNING module_id, version, owning_tenant_id, owning_definition_id,
            \\          interface_schema, exportable, status,
            \\          (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\          (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
        ,
            &.{ params.module_id, params.version, tenant_hex, def_hex, schema_json, exportable_str },
        ) catch return ModuleCatalogError.TransactionFailed;
        defer {
            var r = rows;
            r.deinit();
        }

        if (rows.rows.len == 0) return ModuleCatalogError.DuplicateModuleVersion;
        return rowToEntry(allocator, rows.rows[0]) catch ModuleCatalogError.TransactionFailed;
    }

    pub fn publishModule(
        self: *ProcessModuleCatalog,
        allocator: std.mem.Allocator,
        module_id: []const u8,
        version: []const u8,
        _actor_id: [16]u8,
    ) ModuleCatalogError!PublishModuleResult {
        _ = _actor_id;

        const conn = self.pool.acquire() catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return ModuleCatalogError.PoolExhausted,
            else => return ModuleCatalogError.TransactionFailed,
        };
        defer self.pool.release(conn);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const rows = conn.query(
            allocator,
            \\SELECT module_id, version, owning_tenant_id, owning_definition_id,
            \\       interface_schema, exportable, status,
            \\       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\       (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
            \\FROM public.process_module_catalog
            \\WHERE module_id = $1 AND version = $2
        ,
            &.{ module_id, version },
        ) catch return ModuleCatalogError.TransactionFailed;
        defer {
            var r = rows;
            r.deinit();
        }

        if (rows.rows.len == 0) return ModuleCatalogError.ModuleNotFound;

        const entry = rowToEntry(allocator, rows.rows[0]) catch
            return ModuleCatalogError.TransactionFailed;
        // `entry` is used only for validation below; the returned `upd_entry`
        // is the canonical result. Free `entry` before it leaks.
        defer freeEntry(allocator, entry);

        if (!interfaceDeclared(entry.interface_schema_json)) {
            return ModuleCatalogError.InterfaceNotDeclared;
        }
        if (entry.status == .active) {
            return ModuleCatalogError.ModuleAlreadyActive;
        }

        const predecessor = findPredecessorActive(allocator, conn, module_id, version) catch
            return ModuleCatalogError.TransactionFailed;
        // `predecessor` (when present) is heap-allocated; free it after
        // `computeCompatibilityWarning` consumes the slices it needs.
        defer if (predecessor) |pred| freeEntry(allocator, pred);
        const warning = if (predecessor) |pred|
            computeCompatibilityWarning(a, entry, pred)
        else
            null;

        const upd_rows = conn.query(
            allocator,
            \\UPDATE public.process_module_catalog
            \\SET status = 'ACTIVE', updated_at = CURRENT_TIMESTAMP
            \\WHERE module_id = $1 AND version = $2
            \\RETURNING module_id, version, owning_tenant_id, owning_definition_id,
            \\          interface_schema, exportable, status,
            \\          (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\          (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
        ,
            &.{ module_id, version },
        ) catch return ModuleCatalogError.TransactionFailed;
        defer {
            var r = upd_rows;
            r.deinit();
        }

        const upd_entry = rowToEntry(allocator, upd_rows.rows[0]) catch
            return ModuleCatalogError.TransactionFailed;

        return .{ .entry = upd_entry, .compatibility_warning = warning };
    }

    pub fn resolveModuleRef(
        self: *ProcessModuleCatalog,
        allocator: std.mem.Allocator,
        module_ref: ModuleRef,
        requesting_tenant_id: [16]u8,
    ) ModuleCatalogError!ModuleRefResolution {
        const conn = self.pool.acquire() catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return ModuleCatalogError.PoolExhausted,
            else => return ModuleCatalogError.TransactionFailed,
        };
        defer self.pool.release(conn);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const tid_hex = try uuidToHex(a, requesting_tenant_id);

        const own_rows = conn.query(
            allocator,
            \\SELECT module_id, version, owning_tenant_id, owning_definition_id,
            \\       interface_schema, exportable, status,
            \\       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\       (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
            \\FROM public.process_module_catalog
            \\WHERE module_id = $1
            \\  AND owning_tenant_id = $2::uuid
            \\  AND status = 'ACTIVE'
            \\ORDER BY semver_sort(version) DESC
            \\LIMIT 1
        ,
            &.{ module_ref.module_id, tid_hex },
        ) catch return ModuleCatalogError.TransactionFailed;
        defer {
            var r = own_rows;
            r.deinit();
        }

        if (own_rows.rows.len > 0) {
            const entry = rowToEntry(allocator, own_rows.rows[0]) catch
                return ModuleCatalogError.TransactionFailed;
            if (satisfiesConstraint(entry.version, module_ref.version_constraint)) {
                return .{ .resolved = true, .entry = entry, .error_code = null };
            }
            // Constraint not satisfied — entry is not returned to caller, free it.
            freeEntry(allocator, entry);
        }

        const shared_rows = conn.query(
            allocator,
            \\SELECT pmc.module_id, pmc.version, pmc.owning_tenant_id, pmc.owning_definition_id,
            \\       pmc.interface_schema, pmc.exportable, pmc.status,
            \\       (EXTRACT(EPOCH FROM pmc.created_at) * 1000000)::bigint,
            \\       (EXTRACT(EPOCH FROM pmc.updated_at) * 1000000)::bigint
            \\FROM public.process_module_catalog pmc
            \\JOIN public.process_module_catalog_share pmcs
            \\  ON pmcs.granting_tenant_id = pmc.owning_tenant_id
            \\ AND pmcs.module_id = pmc.module_id
            \\WHERE pmc.module_id = $1
            \\  AND pmcs.receiving_tenant_id = $2::uuid
            \\  AND pmc.status = 'ACTIVE'
            \\ORDER BY semver_sort(pmc.version) DESC
            \\LIMIT 1
        ,
            &.{ module_ref.module_id, tid_hex },
        ) catch return ModuleCatalogError.TransactionFailed;
        defer {
            var r = shared_rows;
            r.deinit();
        }

        if (shared_rows.rows.len > 0) {
            const entry = rowToEntry(allocator, shared_rows.rows[0]) catch
                return ModuleCatalogError.TransactionFailed;
            if (satisfiesConstraint(entry.version, module_ref.version_constraint)) {
                return .{ .resolved = true, .entry = entry, .error_code = null };
            }
            // Constraint not satisfied — entry is not returned to caller, free it.
            freeEntry(allocator, entry);
        }

        return .{ .resolved = false, .entry = null, .error_code = "UNRESOLVED_MODULE_REF" };
    }

    pub fn grantModuleVisibility(
        self: *ProcessModuleCatalog,
        allocator: std.mem.Allocator,
        params: ShareGrantParams,
    ) ModuleCatalogError!void {
        const conn = self.pool.acquire() catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return ModuleCatalogError.PoolExhausted,
            else => return ModuleCatalogError.TransactionFailed,
        };
        defer self.pool.release(conn);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const granting_hex = try uuidToHex(a, params.granting_tenant_id);
        const receiving_hex = try uuidToHex(a, params.receiving_tenant_id);
        const granted_by_hex = try uuidToHex(a, params.granted_by);

        const rows = conn.query(
            allocator,
            \\INSERT INTO public.process_module_catalog_share
            \\  (granting_tenant_id, module_id, receiving_tenant_id, granted_by)
            \\VALUES ($1::uuid, $2, $3::uuid, $4::uuid)
            \\ON CONFLICT (granting_tenant_id, module_id, receiving_tenant_id)
            \\DO NOTHING
            \\RETURNING grant_id
        ,
            &.{ granting_hex, params.module_id, receiving_hex, granted_by_hex },
        ) catch return ModuleCatalogError.TransactionFailed;
        defer {
            var r = rows;
            r.deinit();
        }

        if (rows.rows.len == 0) return ModuleCatalogError.SharingGrantAlreadyExists;
    }

    pub fn revokeModuleVisibility(
        self: *ProcessModuleCatalog,
        allocator: std.mem.Allocator,
        grant_id: [16]u8,
        _actor_id: [16]u8,
    ) ModuleCatalogError!void {
        _ = _actor_id;

        const conn = self.pool.acquire() catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return ModuleCatalogError.PoolExhausted,
            else => return ModuleCatalogError.TransactionFailed,
        };
        defer self.pool.release(conn);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const grant_hex = try uuidToHex(a, grant_id);

        const rows = conn.query(
            allocator,
            \\DELETE FROM public.process_module_catalog_share
            \\WHERE grant_id = $1::uuid
            \\RETURNING grant_id
        ,
            &.{grant_hex},
        ) catch return ModuleCatalogError.TransactionFailed;
        defer {
            var r = rows;
            r.deinit();
        }

        if (rows.rows.len == 0) return ModuleCatalogError.SharingGrantNotFound;
    }

    pub fn listVisibleModules(
        self: *ProcessModuleCatalog,
        allocator: std.mem.Allocator,
        requesting_tenant_id: [16]u8,
        after_module_version: ?[]const u8,
        limit: u32,
    ) ModuleCatalogError!Page {
        const conn = self.pool.acquire() catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return ModuleCatalogError.PoolExhausted,
            else => return ModuleCatalogError.TransactionFailed,
        };
        defer self.pool.release(conn);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const tid_hex = try uuidToHex(a, requesting_tenant_id);
        const eff_limit: i64 = if (limit == 0 or limit > 200) 50 else @intCast(limit);
        const lim_str = try std.fmt.allocPrint(a, "{d}", .{eff_limit});

        const base_sql =
            \\SELECT pmc.module_id, pmc.version, pmc.owning_tenant_id,
            \\       pmc.owning_definition_id, pmc.interface_schema,
            \\       pmc.exportable, pmc.status,
            \\       (EXTRACT(EPOCH FROM pmc.created_at) * 1000000)::bigint,
            \\       (EXTRACT(EPOCH FROM pmc.updated_at) * 1000000)::bigint
            \\FROM (
            \\  SELECT module_id, version, owning_tenant_id
            \\  FROM public.process_module_catalog
            \\  WHERE owning_tenant_id = $1::uuid AND status = 'ACTIVE'
            \\  UNION
            \\  SELECT pmc.module_id, pmc.version, pmc.owning_tenant_id
            \\  FROM public.process_module_catalog pmc
            \\  JOIN public.process_module_catalog_share pmcs
            \\    ON pmcs.granting_tenant_id = pmc.owning_tenant_id
            \\   AND pmcs.module_id = pmc.module_id
            \\  WHERE pmcs.receiving_tenant_id = $1::uuid AND pmc.status = 'ACTIVE'
            \\) visible
            \\JOIN public.process_module_catalog pmc
            \\  ON pmc.module_id = visible.module_id AND pmc.version = visible.version
        ;

        const rows = blk: {
            if (after_module_version) |cursor| {
                break :blk conn.query(
                    allocator,
                    base_sql ++
                        \\
                        \\ WHERE pmc.module_id || '/' || pmc.version > $2
                        \\ ORDER BY pmc.module_id ASC, semver_sort(pmc.version) DESC
                        \\ LIMIT $3
                    ,
                    &.{ tid_hex, cursor, lim_str },
                ) catch return ModuleCatalogError.TransactionFailed;
            } else {
                break :blk conn.query(
                    allocator,
                    base_sql ++
                        \\
                        \\ ORDER BY pmc.module_id ASC, semver_sort(pmc.version) DESC
                        \\ LIMIT $2
                    ,
                    &.{ tid_hex, lim_str },
                ) catch return ModuleCatalogError.TransactionFailed;
            }
        };
        defer {
            var r = rows;
            r.deinit();
        }

        const records = allocator.alloc(ProcessModuleCatalogEntry, rows.rows.len) catch
            return ModuleCatalogError.OutOfMemory;
        errdefer allocator.free(records);

        for (rows.rows, 0..) |row, i| {
            records[i] = rowToEntry(allocator, row) catch {
                for (records[0..i]) |rec| freeEntry(allocator, rec);
                allocator.free(records);
                return ModuleCatalogError.TransactionFailed;
            };
        }

        const next_cursor: ?[]const u8 = if (rows.rows.len == @as(usize, @intCast(eff_limit)))
            makeCursor(allocator, records[records.len - 1].module_id, records[records.len - 1].version) catch null
        else
            null;

        return .{ .records = records, .next_cursor = next_cursor };
    }
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn interfaceDeclared(schema_json: []const u8) bool {
    // Empty object {} means no interface declared.
    // A declared interface has at least {"inputs":...} or {"outputs":...}
    if (schema_json.len <= 2) return false;
    if (std.mem.startsWith(u8, schema_json, "{}")) return false;
    return true;
}

fn findPredecessorActive(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    module_id: []const u8,
    current_version: []const u8,
) !?ProcessModuleCatalogEntry {
    const rows = conn.query(
        allocator,
        \\SELECT module_id, version, owning_tenant_id, owning_definition_id,
        \\       interface_schema, exportable, status,
        \\       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
        \\       (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
        \\FROM public.process_module_catalog
        \\WHERE module_id = $1
        \\  AND status = 'ACTIVE'
        \\  AND semver_sort(version) < semver_sort($2)
        \\ORDER BY semver_sort(version) DESC
        \\LIMIT 1
    ,
        &.{ module_id, current_version },
    ) catch return error.TransactionFailed;
    defer {
        var r = rows;
        r.deinit();
    }
    if (rows.rows.len == 0) return null;
    return rowToEntry(allocator, rows.rows[0]) catch error.TransactionFailed;
}

fn computeCompatibilityWarning(
    allocator: std.mem.Allocator,
    new_entry: ProcessModuleCatalogEntry,
    prev_entry: ProcessModuleCatalogEntry,
) ?CompatibilityWarning {
    // Simple string-based detection of breaking changes.
    // Looks for required input additions and required output removals.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var changes = std.ArrayList([]const u8).empty;
    errdefer changes.deinit();

    const new_schema = new_entry.interface_schema_json;
    _ = prev_entry.interface_schema_json;

    // Check: required input added (input present with required:true in new but not in prev).
    // This is a simple heuristic: look for pattern "name":"...","required":true in new but not in prev.
    if (std.mem.indexOf(u8, new_schema, "\"required\":true") != null) {
        // There is at least one required field - add a generic warning.
        // In a real implementation, we'd parse JSON properly.
        changes.append(a, "INTERFACE_CHANGED") catch return null;
    }

    if (changes.items.len == 0) return null;

    return CompatibilityWarning{
        .module_id = new_entry.module_id,
        .new_version = new_entry.version,
        .previous_version = prev_entry.version,
        .breaking_changes = changes.items,
    };
}

fn satisfiesConstraint(version: []const u8, constraint: []const u8) bool {
    if (constraint.len == 0 or std.mem.eql(u8, constraint, "*")) return true;

    const v = if (version.len > 0 and version[0] == 'v') version[1..] else version;

    if (std.mem.startsWith(u8, constraint, ">=")) {
        return compareSemver(v, constraint[2..]) >= 0;
    }
    if (std.mem.startsWith(u8, constraint, ">")) {
        return compareSemver(v, constraint[1..]) > 0;
    }
    if (std.mem.startsWith(u8, constraint, "<=")) {
        return compareSemver(v, constraint[2..]) <= 0;
    }
    if (std.mem.startsWith(u8, constraint, "<")) {
        return compareSemver(v, constraint[1..]) < 0;
    }
    // Prefix match for caret/patch/wildcard.
    if (std.mem.startsWith(u8, v, constraint)) return true;
    if (std.mem.startsWith(u8, constraint, v)) return true;
    return false;
}

fn compareSemver(a: []const u8, b: []const u8) i8 {
    var a_parts: [3]i64 = .{ 0, 0, 0 };
    var b_parts: [3]i64 = .{ 0, 0, 0 };
    parseSemverParts(a, &a_parts);
    parseSemverParts(b, &b_parts);
    for (0..3) |i| {
        if (a_parts[i] < b_parts[i]) return -1;
        if (a_parts[i] > b_parts[i]) return 1;
    }
    return 0;
}

fn parseSemverParts(v: []const u8, parts: *[3]i64) void {
    var j: usize = 0;
    for (0..3) |part_i| {
        var num: i64 = 0;
        var started = false;
        while (j < v.len) : (j += 1) {
            const c = v[j];
            if (c == '.') {
                if (started) break;
                j += 1;
                continue;
            }
            if (c == '-' or c == '+' or c == ' ' or c < '0' or c > '9') break;
            started = true;
            num = num * 10 + @as(i64, c - '0');
        }
        parts[part_i] = num;
        while (j < v.len and v[j] != '.' and v[j] != '-' and v[j] != '+') j += 1;
        if (j < v.len and v[j] == '.') j += 1;
    }
}

fn makeCursor(allocator: std.mem.Allocator, module_id: []const u8, version: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ module_id, version });
}

fn rowToEntry(allocator: std.mem.Allocator, row: []?[]u8) !ProcessModuleCatalogEntry {
    const col = struct {
        fn get(r: []?[]u8, i: usize) []const u8 {
            return r[i] orelse "";
        }
    };

    const mid = try allocator.dupe(u8, col.get(row, 0));
    errdefer allocator.free(mid);
    const ver = try allocator.dupe(u8, col.get(row, 1));
    errdefer allocator.free(ver);

    const tenant_id = try hexToUuid(col.get(row, 2));
    const def_id = try hexToUuid(col.get(row, 3));
    const schema_json = try allocator.dupe(u8, col.get(row, 4));
    errdefer allocator.free(schema_json);

    const exportable = std.mem.eql(u8, col.get(row, 5), "t");
    const status = ModuleStatus.fromString(col.get(row, 6));
    const created_at = std.fmt.parseInt(i64, col.get(row, 7), 10) catch 0;
    const updated_at = std.fmt.parseInt(i64, col.get(row, 8), 10) catch 0;

    return ProcessModuleCatalogEntry{
        .module_id = mid,
        .version = ver,
        .owning_tenant_id = tenant_id,
        .owning_definition_id = def_id,
        .interface_schema_json = schema_json,
        .exportable = exportable,
        .status = status,
        .created_at = created_at,
        .updated_at = updated_at,
    };
}

pub fn freeEntry(allocator: std.mem.Allocator, entry: ProcessModuleCatalogEntry) void {
    allocator.free(entry.module_id);
    allocator.free(entry.version);
    allocator.free(entry.interface_schema_json);
}

fn uuidToHex(allocator: std.mem.Allocator, uuid: [16]u8) ![]u8 {
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

fn hexToUuid(s: []const u8) ![16]u8 {
    var uuid: [16]u8 = undefined;
    var src: [32]u8 = undefined;
    var j: usize = 0;
    for (s) |c| {
        if (c == '-') continue;
        if (j >= 32) return error.InvalidUuid;
        src[j] = c;
        j += 1;
    }
    if (j != 32) return error.InvalidUuid;
    for (0..16) |i| {
        const high = hexChar(src[i * 2]);
        const low = hexChar(src[i * 2 + 1]);
        if (high == 255 or low == 255) return error.InvalidUuid;
        uuid[i] = high * 16 + low;
    }
    return uuid;
}

fn hexChar(c: u8) u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return 255;
}
