//! ENV-03: Process definition promotion from test tenant to production tenant.
//!
//! POST /api/v1/tenants/:test_tenant_id/promote/:definition_name
//!
//! Exports an ACTIVE definition from the test tenant and imports it as a new
//! DRAFT on the paired production tenant. Roles are checked, audit entries are
//! written on both tenants, and unresolved service references are reported as
//! warnings.

const std = @import("std");
const pool_mod = @import("pool");
const tenant_context_mod = @import("tenant_context");
const export_import = @import("export_import.zig");
const store_mod = @import("store.zig");
const graph_mod = @import("graph");

// ── Error set ──────────────────────────────────────────────────────────────────

pub const PromotionError = error{
    TestTenantNotFound, // :test_tenant_id does not exist                → 404
    NotATestTenant, // tenant_type != 'test'                          → 422
    ProductionTenantInactive, // linked production tenant status != 'ACTIVE'   → 409
    ActiveDefinitionNotFound, // no ACTIVE definition with given name          → 404
    MissingDesignerRoleOnTest, // caller lacks PROCESS_DESIGNER on test tenant  → 403
    MissingDesignerRoleOnProd, // caller lacks PROCESS_DESIGNER on prod tenant  → 403
    ExportFailed, //                                                → 500
    ImportFailed, //                                                → 500
    AuditWriteFailed, //                                                → 500
    PoolExhausted,
    OutOfMemory,
};

pub const PromotionResult = struct {
    definition_id: []const u8, // new definition_id on production tenant (owned)
    version: []const u8, // version string (owned)
    status: []const u8, // always "DRAFT" (owned)
    warnings: []const []const u8, // unresolved service reference names (each owned)

    pub fn deinit(self: PromotionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.definition_id);
        allocator.free(self.version);
        allocator.free(self.status);
        for (self.warnings) |w| allocator.free(w);
        allocator.free(self.warnings);
    }
};

// ── Public API ─────────────────────────────────────────────────────────────────

/// Promote the ACTIVE definition named `definition_name` from the test tenant
/// to the linked production tenant.
///
/// The caller must pass:
///   - allocator:       for all returned strings
///   - pool:            shared DB connection pool
///   - test_tenant_id:  the :test_tenant_id path parameter (UUID string)
///   - definition_name: the :definition_name path parameter
///   - actor_id:        the authenticated user's UUID string
pub fn promoteDefinition(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    test_tenant_id: []const u8,
    definition_name: []const u8,
    actor_id: []const u8,
) PromotionError!PromotionResult {
    // ── Step 1: Look up test tenant and linked production tenant ──────────────
    var prod_tenant_id_buf: [36]u8 = undefined;
    var prod_tenant_id_len: usize = 0;
    var prod_status_buf: [32]u8 = undefined;
    var prod_status_len: usize = 0;

    {
        // Query public schema directly (always accessible regardless of search_path).
        tenant_context_mod.clear();
        const conn = pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => PromotionError.PoolExhausted,
            else => PromotionError.ExportFailed,
        };
        defer pool.release(conn);

        // Security: test_tenant_id bound as $1::uuid — no SQL string interpolation.
        const row = conn.queryRow(
            allocator,
            \\SELECT t.tenant_type, t.production_tenant_id::text,
            \\       p.status
            \\FROM public.tenant t
            \\LEFT JOIN public.tenant p ON p.id = t.production_tenant_id
            \\WHERE t.id = $1::uuid
            \\LIMIT 1
        ,
            &[_][]const u8{test_tenant_id},
        ) catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => PromotionError.PoolExhausted,
            else => PromotionError.ExportFailed,
        };

        if (row == null) return PromotionError.TestTenantNotFound;
        const r = row.?;
        defer {
            for (r) |col| if (col) |v| allocator.free(v);
            allocator.free(r);
        }

        const tenant_type = r[0] orelse return PromotionError.TestTenantNotFound;
        if (!std.mem.eql(u8, tenant_type, "test")) return PromotionError.NotATestTenant;

        const prod_id = r[1] orelse return PromotionError.ExportFailed;
        const prod_status_raw = r[2] orelse "INACTIVE";

        if (prod_id.len <= prod_tenant_id_buf.len) {
            @memcpy(prod_tenant_id_buf[0..prod_id.len], prod_id);
            prod_tenant_id_len = prod_id.len;
        } else {
            return PromotionError.ExportFailed;
        }
        if (prod_status_raw.len <= prod_status_buf.len) {
            @memcpy(prod_status_buf[0..prod_status_raw.len], prod_status_raw);
            prod_status_len = prod_status_raw.len;
        }
    }
    const prod_tenant_id = prod_tenant_id_buf[0..prod_tenant_id_len];
    const prod_status = prod_status_buf[0..prod_status_len];

    if (!std.mem.eql(u8, prod_status, "ACTIVE")) return PromotionError.ProductionTenantInactive;

    // ── Step 2: Role checks ────────────────────────────────────────────────────
    // PLATFORM_ADMIN: skip role checks (covered by auth middleware).
    // For PROCESS_DESIGNER: check roles table in each tenant schema.
    // Since this endpoint is called with actor_id already authenticated,
    // we check the roles table in each schema.
    const saved_ctx = blk: {
        const s = tenant_context_mod.get();
        break :blk if (s.len > 0) s else "";
    };
    defer if (saved_ctx.len > 0) tenant_context_mod.set(saved_ctx) else tenant_context_mod.clear();

    // Check role on test tenant schema.
    tenant_context_mod.set(test_tenant_id);
    {
        const conn = pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => PromotionError.PoolExhausted,
            else => PromotionError.ExportFailed,
        };
        defer pool.release(conn);

        // Security: actor_id bound as $1::uuid — no SQL string interpolation.
        // Join user_roles → roles to look up by role name (roles.name, not role_name column).
        const row = conn.queryRow(
            allocator,
            \\SELECT EXISTS (
            \\    SELECT 1 FROM user_roles ur
            \\    JOIN roles r ON r.id = ur.role_id
            \\    WHERE ur.user_id = $1::uuid
            \\      AND r.name IN ('PROCESS_DESIGNER', 'PLATFORM_ADMIN')
            \\) AS has_role
        ,
            &[_][]const u8{actor_id},
        ) catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => PromotionError.PoolExhausted,
            else => PromotionError.ExportFailed,
        };
        if (row) |r| {
            defer {
                for (r) |col| if (col) |v| allocator.free(v);
                allocator.free(r);
            }
            const val = r[0] orelse "f";
            if (!std.mem.eql(u8, val, "t") and !std.mem.eql(u8, val, "true")) {
                return PromotionError.MissingDesignerRoleOnTest;
            }
        } else {
            return PromotionError.MissingDesignerRoleOnTest;
        }
    }

    // Check role on production tenant schema.
    tenant_context_mod.set(prod_tenant_id);
    {
        const conn = pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => PromotionError.PoolExhausted,
            else => PromotionError.ExportFailed,
        };
        defer pool.release(conn);

        // Security: actor_id bound as $1::uuid — no SQL string interpolation.
        const row = conn.queryRow(
            allocator,
            \\SELECT EXISTS (
            \\    SELECT 1 FROM user_roles ur
            \\    JOIN roles r ON r.id = ur.role_id
            \\    WHERE ur.user_id = $1::uuid
            \\      AND r.name IN ('PROCESS_DESIGNER', 'PLATFORM_ADMIN')
            \\) AS has_role
        ,
            &[_][]const u8{actor_id},
        ) catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => PromotionError.PoolExhausted,
            else => PromotionError.ExportFailed,
        };
        if (row) |r| {
            defer {
                for (r) |col| if (col) |v| allocator.free(v);
                allocator.free(r);
            }
            const val = r[0] orelse "f";
            if (!std.mem.eql(u8, val, "t") and !std.mem.eql(u8, val, "true")) {
                return PromotionError.MissingDesignerRoleOnProd;
            }
        } else {
            return PromotionError.MissingDesignerRoleOnProd;
        }
    }

    // ── Step 3: Find ACTIVE definition by name in test tenant schema ──────────
    tenant_context_mod.set(test_tenant_id);
    var source_def_id_buf: [36]u8 = undefined;
    var source_def_id_len: usize = 0;
    var source_def_id_uuid: graph_mod.Uuid = std.mem.zeroes(graph_mod.Uuid);

    {
        const conn = pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => PromotionError.PoolExhausted,
            else => PromotionError.ExportFailed,
        };
        defer pool.release(conn);

        // Security: definition_name bound as $1 — no SQL string interpolation.
        const row = conn.queryRow(
            allocator,
            \\SELECT id::text
            \\FROM process_definitions
            \\WHERE name = $1 AND status = 'ACTIVE'
            \\LIMIT 1
        ,
            &[_][]const u8{definition_name},
        ) catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => PromotionError.PoolExhausted,
            else => PromotionError.ExportFailed,
        };
        if (row == null) return PromotionError.ActiveDefinitionNotFound;
        const r = row.?;
        defer {
            for (r) |col| if (col) |v| allocator.free(v);
            allocator.free(r);
        }
        const id_str = r[0] orelse return PromotionError.ActiveDefinitionNotFound;
        if (id_str.len > source_def_id_buf.len) return PromotionError.ExportFailed;
        @memcpy(source_def_id_buf[0..id_str.len], id_str);
        source_def_id_len = id_str.len;
        source_def_id_uuid = parseUuidStr(id_str) catch return PromotionError.ExportFailed;
    }
    const source_def_id = source_def_id_buf[0..source_def_id_len];

    // ── Step 4: Export definition from test tenant ────────────────────────────
    tenant_context_mod.set(test_tenant_id);
    var ei_store = export_import.ExportImportStore{ .pool = pool };
    const export_doc = ei_store.exportDefinition(allocator, source_def_id_uuid) catch |err| switch (err) {
        export_import.ExportImportError.DefinitionNotFound => return PromotionError.ActiveDefinitionNotFound,
        export_import.ExportImportError.PoolExhausted => return PromotionError.PoolExhausted,
        else => return PromotionError.ExportFailed,
    };
    defer {
        allocator.free(export_doc.name);
        allocator.free(export_doc.version);
        allocator.free(export_doc.description);
        allocator.free(export_doc.exported_at);
        for (export_doc.graph.nodes) |node| {
            allocator.free(node.id);
            if (node.label) |l| allocator.free(l);
            if (node.attributes) |a| allocator.free(a);
        }
        allocator.free(export_doc.graph.nodes);
        for (export_doc.graph.edges) |edge| {
            allocator.free(edge.id);
            allocator.free(edge.source);
            allocator.free(edge.target);
            if (edge.condition) |c| allocator.free(c);
            if (edge.transform) |t| allocator.free(t);
        }
        allocator.free(export_doc.graph.edges);
    }

    // ── Step 5: Import as DRAFT on production tenant ──────────────────────────
    // Determine the next version for this definition name on production.
    tenant_context_mod.set(prod_tenant_id);
    const next_version = blk: {
        const conn = pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => PromotionError.PoolExhausted,
            else => PromotionError.ImportFailed,
        };
        defer pool.release(conn);

        const row = conn.queryRow(
            allocator,
            \\SELECT COALESCE(MAX(version::int), 0)::text AS max_ver
            \\FROM process_definitions
            \\WHERE name = $1
        ,
            &[_][]const u8{export_doc.name},
        ) catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => PromotionError.PoolExhausted,
            else => PromotionError.ImportFailed,
        };
        const max_ver: u32 = if (row) |r| blk2: {
            defer {
                for (r) |col| if (col) |v| allocator.free(v);
                allocator.free(r);
            }
            break :blk2 std.fmt.parseInt(u32, r[0] orelse "0", 10) catch 0;
        } else 0;
        break :blk max_ver + 1;
    };
    const next_version_str = std.fmt.allocPrint(allocator, "{d}", .{next_version}) catch return PromotionError.OutOfMemory;
    defer allocator.free(next_version_str);

    // Build a modified export doc with the new version.
    var import_doc = export_doc;
    import_doc.version = next_version_str;

    const new_def = ei_store.importDefinition(allocator, import_doc) catch |err| switch (err) {
        export_import.ExportImportError.PoolExhausted => return PromotionError.PoolExhausted,
        else => return PromotionError.ImportFailed,
    };
    // ISS-0647 / GH-652 (env03/iss206 leak cluster): the comment that used to
    // sit here ("Definition struct has no deinit; individual string fields
    // will be freed by the request arena") was incorrect on both counts —
    // graph.zig's Definition DOES define `deinit` (frees .name, .version,
    // .description, .stage, and the nested DefinitionGraph's node/edge
    // dupes), and this function is also called directly from integration
    // tests with a DebugAllocator, not just from behind an HTTP request
    // arena. Only new_def.id and new_def.version are copied out below before
    // new_def itself is released, so it must be deinit'd once those copies
    // exist — otherwise every field importDefinition allocated (in
    // particular the parseGraphJson node/edge dupes) leaks on every call.
    const new_def_id = uuidToHexStr(allocator, new_def.id) catch return PromotionError.OutOfMemory;
    errdefer allocator.free(new_def_id);

    const new_def_version = allocator.dupe(u8, new_def.version) catch return PromotionError.OutOfMemory;
    errdefer allocator.free(new_def_version);

    new_def.deinit(allocator);

    // ── Step 6: Collect unresolved service references ─────────────────────────
    tenant_context_mod.set(prod_tenant_id);
    const warnings = collectUnresolvedServiceRefs(allocator, pool, new_def_id, prod_tenant_id) catch
        try allocator.alloc([]const u8, 0);

    // ── Step 7: Write audit entries on both tenants ───────────────────────────
    // Audit on test tenant.
    tenant_context_mod.set(test_tenant_id);
    writePromotionAudit(allocator, pool, actor_id, source_def_id, new_def_id, prod_tenant_id) catch
        return PromotionError.AuditWriteFailed;

    // Audit on production tenant.
    tenant_context_mod.set(prod_tenant_id);
    writePromotionAudit(allocator, pool, actor_id, new_def_id, source_def_id, test_tenant_id) catch
        return PromotionError.AuditWriteFailed;

    const status_str = allocator.dupe(u8, "DRAFT") catch return PromotionError.OutOfMemory;

    return PromotionResult{
        .definition_id = new_def_id,
        .version = new_def_version,
        .status = status_str,
        .warnings = warnings,
    };
}

// ── Internal helpers ────────────────────────────────────────────────────────────

fn collectUnresolvedServiceRefs(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    definition_id: []const u8,
    prod_tenant_id: []const u8,
) ![]const []const u8 {
    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };
    defer pool.release(conn);

    // Security: definition_id bound as $1::uuid, prod_tenant_id as $2::uuid.
    var rows = conn.query(
        allocator,
        \\SELECT DISTINCT node_config->>'service_name' AS svc_name
        \\FROM process_definitions,
        \\     jsonb_array_elements(graph->'nodes') AS node_config
        \\WHERE id = $1::uuid
        \\  AND node_config->>'service_name' IS NOT NULL
        \\  AND node_config->>'service_name' NOT IN (
        \\      SELECT name FROM service_catalog
        \\      WHERE scope = 'global'
        \\         OR (scope = 'tenant' AND owner_tenant_id = $2::uuid)
        \\  )
    ,
        &[_][]const u8{ definition_id, prod_tenant_id },
    ) catch return try allocator.alloc([]const u8, 0);
    defer rows.deinit();

    const result = try allocator.alloc([]const u8, rows.rows.len);
    var filled: usize = 0;
    errdefer {
        for (result[0..filled]) |w| allocator.free(w);
        allocator.free(result);
    }
    for (rows.rows) |row| {
        const name = row[0] orelse continue;
        result[filled] = try allocator.dupe(u8, name);
        filled += 1;
    }
    return result[0..filled];
}

fn writePromotionAudit(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    actor_id: []const u8,
    resource_id: []const u8,
    cross_ref_id: []const u8,
    cross_ref_tenant_id: []const u8,
) !void {
    const conn = pool.acquire() catch |err| return switch (err) {
        pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };
    defer pool.release(conn);

    // Build the after_state JSON in Zig from validated UUID strings.
    // cross_ref_id and cross_ref_tenant_id are validated UUIDs (hex digits and
    // dashes only) — safe to interpolate directly into a JSON literal.
    // This avoids the pg.zig parameter-type-inference failure that occurs when
    // $N parameters appear inside jsonb_build_object() variadic arguments.
    const after_state_json = std.fmt.allocPrint(
        allocator,
        "{{\"cross_reference_definition_id\":\"{s}\",\"cross_reference_tenant_id\":\"{s}\"}}",
        .{ cross_ref_id, cross_ref_tenant_id },
    ) catch return error.OutOfMemory;
    defer allocator.free(after_state_json);

    _ = conn.exec(
        \\INSERT INTO audit_entries (actor_id, action, resource_type, resource_id, after_state)
        \\VALUES ($1::uuid, 'DEFINITION_PROMOTED', 'process_definition', $2::uuid, $3::jsonb)
    ,
        &[_][]const u8{ actor_id, resource_id, after_state_json },
    ) catch |err| {
        return switch (err) {
            pool_mod.PoolError.ExhaustedPool => error.PoolExhausted,
            else => error.PersistenceFailed,
        };
    };
}

fn parseUuidStr(s: []const u8) !graph_mod.Uuid {
    // UUID format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (36 chars)
    if (s.len != 36) return error.InvalidUuid;
    var uuid: graph_mod.Uuid = undefined;
    var out_idx: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '-') continue;
        if (out_idx >= 16) return error.InvalidUuid;
        const hi = hexDigit(s[i]) orelse return error.InvalidUuid;
        i += 1;
        if (i >= s.len) return error.InvalidUuid;
        const lo = hexDigit(s[i]) orelse return error.InvalidUuid;
        uuid[out_idx] = (hi << 4) | lo;
        out_idx += 1;
    }
    if (out_idx != 16) return error.InvalidUuid;
    return uuid;
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn uuidToHexStr(allocator: std.mem.Allocator, uuid: graph_mod.Uuid) ![]u8 {
    const hex = "0123456789abcdef";
    const out = try allocator.alloc(u8, 36);
    // xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    const groups = [_]struct { start: usize, len: usize }{
        .{ .start = 0, .len = 4 },
        .{ .start = 4, .len = 2 },
        .{ .start = 6, .len = 2 },
        .{ .start = 8, .len = 2 },
        .{ .start = 10, .len = 6 },
    };
    var pos: usize = 0;
    for (groups, 0..) |g, gi| {
        if (gi > 0) {
            out[pos] = '-';
            pos += 1;
        }
        for (uuid[g.start .. g.start + g.len]) |b| {
            out[pos] = hex[b >> 4];
            out[pos + 1] = hex[b & 0xf];
            pos += 2;
        }
    }
    return out;
}
