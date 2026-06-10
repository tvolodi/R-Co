//! Service catalog registry (REPO-07, SVC-01, SVC-04)
//!
//! Service registration with endpoint URLs, request/response schemas, and auth requirements.
//! Used by SERVICE_TASK nodes and Lua service calls.
//! Extended in Stage 13 (SVC-01, SVC-04) with tenant-scoping (scope + owner_tenant_id).
//!
//! Design artefact: src/design/svc-01-04-service-scope.md

const std = @import("std");
const db = @import("pool");

const Pool = db.Pool;

// ---------------------------------------------------------------------------
// Public error set
// ---------------------------------------------------------------------------

pub const CatalogError = error{
    // existing
    PoolExhausted,
    ServiceIdTooLong,
    ServiceIdEmpty,
    ServiceIdInvalid,
    ServiceNotFound,
    DuplicateService,
    InvalidAuthMethod,
    InvalidSchema,
    EndpointUrlInvalid,
    TimeoutInvalid,
    TransactionFailed,
    OutOfMemory,
    InvalidJson,
    // new (SVC-01, SVC-04)
    InvalidScopeConstraint, // scope=tenant with no owner_tenant_id, or scope=global with owner
    TenantNotFound, // owner_tenant_id does not resolve to a known tenant
    ServiceInUse, // DELETE blocked by active definitions
    ConflictingActiveDefinitions, // PATCH scope change blocked by other tenants' active defs
};

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

pub const AuthMethod = enum {
    NONE,
    API_KEY,
    OAUTH2,
    MUTUAL_TLS,
};

/// Service catalog scope (SVC-01).
pub const ServiceScope = enum { global, tenant };

pub const ServiceCatalogRecord = struct {
    service_id: []const u8,
    endpoint_url: []const u8,
    request_schema: []const u8,
    response_schema: []const u8,
    required_auth: AuthMethod,
    timeout_ms: u32,
    retry_policy: []const u8,
    scope: ServiceScope,
    owner_tenant_id: ?[16]u8, // null when scope = global
    created_at: i64,
    updated_at: i64,
};

pub const RegisterServiceParams = struct {
    service_id: []const u8,
    endpoint_url: []const u8,
    request_schema: []const u8,
    response_schema: []const u8,
    required_auth: AuthMethod,
    timeout_ms: u32,
    retry_policy: ?[]const u8,
    scope: ServiceScope,
    owner_tenant_id: ?[16]u8,
};

pub const UpdateServiceScopeParams = struct {
    scope: ServiceScope,
    owner_tenant_id: ?[16]u8,
};

pub const ServiceCatalog = struct {
    allocator: std.mem.Allocator,
    pool: *Pool,
    _last_in_use_ids: [][16]u8 = &.{},
    _last_conflicting_ids: [][16]u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, pool: *Pool) ServiceCatalog {
        return ServiceCatalog{
            .allocator = allocator,
            .pool = pool,
        };
    }

    pub fn deinit(self: *ServiceCatalog) void {
        self.clearConflictBuffers();
    }

    fn clearConflictBuffers(self: *ServiceCatalog) void {
        if (self._last_in_use_ids.len > 0) {
            self.allocator.free(self._last_in_use_ids);
            self._last_in_use_ids = &.{};
        }
        if (self._last_conflicting_ids.len > 0) {
            self.allocator.free(self._last_conflicting_ids);
            self._last_conflicting_ids = &.{};
        }
    }

    // -----------------------------------------------------------------------
    // Conflict-context accessors (SVC-04)
    // -----------------------------------------------------------------------

    pub fn lastInUseDefinitionIds(self: *const ServiceCatalog) []const [16]u8 {
        return self._last_in_use_ids;
    }

    pub fn lastConflictingTenantIds(self: *const ServiceCatalog) []const [16]u8 {
        return self._last_conflicting_ids;
    }

    // -----------------------------------------------------------------------
    // register  (legacy alias)
    // -----------------------------------------------------------------------

    pub fn register(
        self: *ServiceCatalog,
        allocator: std.mem.Allocator,
        params: RegisterServiceParams,
    ) CatalogError!ServiceCatalogRecord {
        return self.registerService(allocator, params);
    }

    // -----------------------------------------------------------------------
    // registerService  (SVC-04)
    // -----------------------------------------------------------------------

    pub fn registerService(
        self: *ServiceCatalog,
        allocator: std.mem.Allocator,
        params: RegisterServiceParams,
    ) CatalogError!ServiceCatalogRecord {
        if (params.scope == .tenant and params.owner_tenant_id == null)
            return CatalogError.InvalidScopeConstraint;
        if (params.scope == .global and params.owner_tenant_id != null)
            return CatalogError.InvalidScopeConstraint;

        if (params.service_id.len == 0) return CatalogError.ServiceIdEmpty;
        if (params.service_id.len > 128) return CatalogError.ServiceIdTooLong;
        if (params.timeout_ms == 0 or params.timeout_ms > 3_600_000) return CatalogError.TimeoutInvalid;

        const conn = self.pool.acquire() catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return CatalogError.PoolExhausted,
            else => return CatalogError.TransactionFailed,
        };
        defer self.pool.release(conn);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const retry_policy = params.retry_policy orelse "{}";
        const auth_str = authMethodToString(params.required_auth);
        const scope_str = if (params.scope == .global) "global" else "tenant";

        // Convert numeric params to strings for pg driver.
        const timeout_str = std.fmt.allocPrint(a, "{d}", .{params.timeout_ms}) catch return CatalogError.TransactionFailed;

        if (params.scope == .tenant) {
            if (params.owner_tenant_id) |tid| {
                const tid_hex = uuidToHex(a, tid) catch return CatalogError.TransactionFailed;
                const check = conn.query(
                    allocator,
                    \\SELECT id FROM public.tenant WHERE id = $1::uuid
                ,
                    &.{tid_hex},
                ) catch return CatalogError.TransactionFailed;
                defer {
                    var r = check;
                    r.deinit();
                }
                if (check.rows.len == 0) return CatalogError.TenantNotFound;
            }
        }

        const owner_hex: []const u8 = if (params.owner_tenant_id) |tid|
            uuidToHex(a, tid) catch return CatalogError.TransactionFailed
        else
            "";

        const rows = conn.query(
            allocator,
            \\INSERT INTO public.service_catalog
            \\  (service_id, endpoint_url, request_schema, response_schema,
            \\   required_auth, timeout_ms, retry_policy, scope, owner_tenant_id)
            \\VALUES ($1, $2, $3, $4, $5, $6::bigint, $7, $8, NULLIF($9, '')::uuid)
            \\ON CONFLICT (service_id) DO NOTHING
            \\RETURNING service_id, endpoint_url, request_schema, response_schema,
            \\          required_auth, timeout_ms, retry_policy, scope, owner_tenant_id,
            \\          (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\          (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
        ,
            &.{
                params.service_id,
                params.endpoint_url,
                params.request_schema,
                params.response_schema,
                auth_str,
                timeout_str,
                retry_policy,
                scope_str,
                owner_hex,
            },
        ) catch return CatalogError.TransactionFailed;
        defer {
            var r = rows;
            r.deinit();
        }

        if (rows.rows.len == 0) return CatalogError.DuplicateService;
        return rowToRecord(allocator, rows.rows[0]) catch CatalogError.TransactionFailed;
    }

    // -----------------------------------------------------------------------
    // getService  (no scope check — internal/admin use)
    // -----------------------------------------------------------------------

    pub fn getService(
        self: *ServiceCatalog,
        allocator: std.mem.Allocator,
        service_id: []const u8,
    ) CatalogError!ServiceCatalogRecord {
        const conn = self.pool.acquire() catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return CatalogError.PoolExhausted,
            else => return CatalogError.TransactionFailed,
        };
        defer self.pool.release(conn);

        const rows = conn.query(
            allocator,
            \\SELECT service_id, endpoint_url, request_schema, response_schema,
            \\       required_auth, timeout_ms, retry_policy, scope, owner_tenant_id,
            \\       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\       (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
            \\FROM public.service_catalog
            \\WHERE service_id = $1
        ,
            &.{service_id},
        ) catch return CatalogError.TransactionFailed;
        defer {
            var r = rows;
            r.deinit();
        }

        if (rows.rows.len == 0) return CatalogError.ServiceNotFound;
        return rowToRecord(allocator, rows.rows[0]) catch CatalogError.TransactionFailed;
    }

    // -----------------------------------------------------------------------
    // getServiceForTenant  (SVC-01)
    // -----------------------------------------------------------------------

    pub fn getServiceForTenant(
        self: *ServiceCatalog,
        allocator: std.mem.Allocator,
        service_id: []const u8,
        tenant_id: [16]u8,
    ) CatalogError!ServiceCatalogRecord {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const conn = self.pool.acquire() catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return CatalogError.PoolExhausted,
            else => return CatalogError.TransactionFailed,
        };
        defer self.pool.release(conn);

        const tid_hex = uuidToHex(a, tenant_id) catch return CatalogError.TransactionFailed;

        const rows = conn.query(
            allocator,
            \\SELECT service_id, endpoint_url, request_schema, response_schema,
            \\       required_auth, timeout_ms, retry_policy, scope, owner_tenant_id,
            \\       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\       (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
            \\FROM public.service_catalog
            \\WHERE service_id = $1
            \\  AND (scope = 'global' OR owner_tenant_id = $2::uuid)
        ,
            &.{ service_id, tid_hex },
        ) catch return CatalogError.TransactionFailed;
        defer {
            var r = rows;
            r.deinit();
        }

        if (rows.rows.len == 0) return CatalogError.ServiceNotFound;
        return rowToRecord(allocator, rows.rows[0]) catch CatalogError.TransactionFailed;
    }

    // -----------------------------------------------------------------------
    // listServices  (legacy — no scope filter)
    // -----------------------------------------------------------------------

    pub fn listServices(
        self: *ServiceCatalog,
        allocator: std.mem.Allocator,
        after_id: ?[]const u8,
        limit: u32,
    ) CatalogError![]ServiceCatalogRecord {
        return self.listServicesForTenant(allocator, null, after_id, limit);
    }

    // -----------------------------------------------------------------------
    // listServicesForTenant  (SVC-01)
    // -----------------------------------------------------------------------

    pub fn listServicesForTenant(
        self: *ServiceCatalog,
        allocator: std.mem.Allocator,
        caller_tenant_id: ?[16]u8,
        after_id: ?[]const u8,
        limit: u32,
    ) CatalogError![]ServiceCatalogRecord {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const conn = self.pool.acquire() catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return CatalogError.PoolExhausted,
            else => return CatalogError.TransactionFailed,
        };
        defer self.pool.release(conn);

        const eff_limit: i64 = if (limit == 0 or limit > 200) 50 else @intCast(limit);
        const lim_str = std.fmt.allocPrint(a, "{d}", .{eff_limit}) catch return CatalogError.TransactionFailed;

        const rows = blk: {
            if (caller_tenant_id) |tid| {
                const tid_hex = uuidToHex(a, tid) catch return CatalogError.TransactionFailed;
                if (after_id) |aid| {
                    break :blk conn.query(
                        allocator,
                        \\SELECT service_id, endpoint_url, request_schema, response_schema,
                        \\       required_auth, timeout_ms, retry_policy, scope, owner_tenant_id,
                        \\       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
                        \\       (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
                        \\FROM public.service_catalog
                        \\WHERE (scope = 'global' OR owner_tenant_id = $1::uuid)
                        \\  AND service_id > $2
                        \\ORDER BY service_id ASC
                        \\LIMIT $3
                    ,
                        &.{ tid_hex, aid, lim_str },
                    ) catch return CatalogError.TransactionFailed;
                } else {
                    break :blk conn.query(
                        allocator,
                        \\SELECT service_id, endpoint_url, request_schema, response_schema,
                        \\       required_auth, timeout_ms, retry_policy, scope, owner_tenant_id,
                        \\       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
                        \\       (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
                        \\FROM public.service_catalog
                        \\WHERE (scope = 'global' OR owner_tenant_id = $1::uuid)
                        \\ORDER BY service_id ASC
                        \\LIMIT $2
                    ,
                        &.{ tid_hex, lim_str },
                    ) catch return CatalogError.TransactionFailed;
                }
            } else {
                if (after_id) |aid| {
                    break :blk conn.query(
                        allocator,
                        \\SELECT service_id, endpoint_url, request_schema, response_schema,
                        \\       required_auth, timeout_ms, retry_policy, scope, owner_tenant_id,
                        \\       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
                        \\       (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
                        \\FROM public.service_catalog
                        \\WHERE service_id > $1
                        \\ORDER BY service_id ASC
                        \\LIMIT $2
                    ,
                        &.{ aid, lim_str },
                    ) catch return CatalogError.TransactionFailed;
                } else {
                    break :blk conn.query(
                        allocator,
                        \\SELECT service_id, endpoint_url, request_schema, response_schema,
                        \\       required_auth, timeout_ms, retry_policy, scope, owner_tenant_id,
                        \\       (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
                        \\       (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
                        \\FROM public.service_catalog
                        \\ORDER BY service_id ASC
                        \\LIMIT $1
                    ,
                        &.{lim_str},
                    ) catch return CatalogError.TransactionFailed;
                }
            }
        };
        defer {
            var r = rows;
            r.deinit();
        }

        const records = allocator.alloc(ServiceCatalogRecord, rows.rows.len) catch
            return CatalogError.OutOfMemory;
        errdefer allocator.free(records);

        for (rows.rows, 0..) |row, i| {
            records[i] = rowToRecord(allocator, row) catch {
                for (records[0..i]) |rec| freeRecord(allocator, rec);
                allocator.free(records);
                return CatalogError.TransactionFailed;
            };
        }
        return records;
    }

    // -----------------------------------------------------------------------
    // updateServiceScope  (SVC-04)
    // -----------------------------------------------------------------------

    pub fn updateServiceScope(
        self: *ServiceCatalog,
        allocator: std.mem.Allocator,
        service_id: []const u8,
        params: UpdateServiceScopeParams,
    ) CatalogError!ServiceCatalogRecord {
        self.clearConflictBuffers();

        if (params.scope == .tenant and params.owner_tenant_id == null)
            return CatalogError.InvalidScopeConstraint;
        if (params.scope == .global and params.owner_tenant_id != null)
            return CatalogError.InvalidScopeConstraint;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const conn = self.pool.acquire() catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return CatalogError.PoolExhausted,
            else => return CatalogError.TransactionFailed,
        };
        defer self.pool.release(conn);

        const cur_rows = conn.query(
            allocator,
            \\SELECT scope FROM public.service_catalog WHERE service_id = $1
        ,
            &.{service_id},
        ) catch return CatalogError.TransactionFailed;
        defer {
            var r = cur_rows;
            r.deinit();
        }
        if (cur_rows.rows.len == 0) return CatalogError.ServiceNotFound;

        const cur_scope_str: []const u8 = if (cur_rows.rows[0][0]) |s| s else "";
        const currently_global = std.mem.eql(u8, cur_scope_str, "global");

        if (currently_global and params.scope == .tenant) {
            if (params.owner_tenant_id) |new_owner| {
                const new_owner_hex = uuidToHex(a, new_owner) catch return CatalogError.TransactionFailed;
                // Post-Stage-12: process_definitions lives in per-tenant schemas.
                // Use the cross-schema helper function (GBL-079) to find
                // ACTIVE definitions referencing this service across all tenants.
                const conflict_rows = conn.query(
                    allocator,
                    \\SELECT DISTINCT tenant_id::text
                    \\FROM public.bpm_active_defs_for_service($1)
                    \\WHERE tenant_id != $2::uuid
                ,
                    &.{ service_id, new_owner_hex },
                ) catch return CatalogError.TransactionFailed;
                defer {
                    var r = conflict_rows;
                    r.deinit();
                }
                if (conflict_rows.rows.len > 0) {
                    const ids = allocator.alloc([16]u8, conflict_rows.rows.len) catch
                        return CatalogError.OutOfMemory;
                    for (conflict_rows.rows, 0..) |row, i| {
                        const hex = if (row[0]) |s| s else "";
                        ids[i] = hexToUuid(hex) catch std.mem.zeroes([16]u8);
                    }
                    self._last_conflicting_ids = ids;
                    return CatalogError.ConflictingActiveDefinitions;
                }
            }
        }

        const scope_str: []const u8 = if (params.scope == .global) "global" else "tenant";
        const owner_hex: []const u8 = if (params.owner_tenant_id) |tid|
            uuidToHex(a, tid) catch return CatalogError.TransactionFailed
        else
            "";

        const upd_rows = conn.query(
            allocator,
            \\UPDATE public.service_catalog
            \\SET scope = $1, owner_tenant_id = NULLIF($2, '')::uuid, updated_at = NOW()
            \\WHERE service_id = $3
            \\RETURNING service_id, endpoint_url, request_schema, response_schema,
            \\          required_auth, timeout_ms, retry_policy, scope, owner_tenant_id,
            \\          (EXTRACT(EPOCH FROM created_at) * 1000000)::bigint,
            \\          (EXTRACT(EPOCH FROM updated_at) * 1000000)::bigint
        ,
            &.{ scope_str, owner_hex, service_id },
        ) catch return CatalogError.TransactionFailed;
        defer {
            var r = upd_rows;
            r.deinit();
        }

        if (upd_rows.rows.len == 0) return CatalogError.ServiceNotFound;
        return rowToRecord(allocator, upd_rows.rows[0]) catch CatalogError.TransactionFailed;
    }

    // -----------------------------------------------------------------------
    // deleteService  (SVC-04)
    // -----------------------------------------------------------------------

    pub fn deleteService(
        self: *ServiceCatalog,
        allocator: std.mem.Allocator,
        service_id: []const u8,
    ) CatalogError!void {
        self.clearConflictBuffers();

        const conn = self.pool.acquire() catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return CatalogError.PoolExhausted,
            else => return CatalogError.TransactionFailed,
        };
        defer self.pool.release(conn);

        // Post-Stage-12: process_definitions lives in per-tenant schemas.
        // Use the cross-schema helper function (GBL-079) introduced by migration
        // GBL-079_svc04_cross_schema_proc_def_refs.sql.
        const ref_rows = conn.query(
            allocator,
            \\SELECT definition_id::text
            \\FROM public.bpm_active_defs_for_service($1)
        ,
            &.{service_id},
        ) catch return CatalogError.TransactionFailed;
        defer {
            var r = ref_rows;
            r.deinit();
        }

        if (ref_rows.rows.len > 0) {
            const ids = allocator.alloc([16]u8, ref_rows.rows.len) catch
                return CatalogError.OutOfMemory;
            for (ref_rows.rows, 0..) |row, i| {
                const hex = if (row[0]) |s| s else "";
                ids[i] = hexToUuid(hex) catch std.mem.zeroes([16]u8);
            }
            self._last_in_use_ids = ids;
            return CatalogError.ServiceInUse;
        }

        conn.exec(
            \\DELETE FROM public.service_catalog WHERE service_id = $1
        ,
            &.{service_id},
        ) catch return CatalogError.TransactionFailed;
    }

    // -----------------------------------------------------------------------
    // exists  (legacy)
    // -----------------------------------------------------------------------

    pub fn exists(
        self: *ServiceCatalog,
        allocator: std.mem.Allocator,
        service_id: []const u8,
    ) CatalogError!bool {
        _ = self.getService(allocator, service_id) catch |err| switch (err) {
            CatalogError.ServiceNotFound => return false,
            else => return err,
        };
        return true;
    }
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn authMethodToString(m: AuthMethod) []const u8 {
    return switch (m) {
        .NONE => "NONE",
        .API_KEY => "API_KEY",
        .OAUTH2 => "OAUTH2",
        .MUTUAL_TLS => "MUTUAL_TLS",
    };
}

fn parseAuthMethod(s: []const u8) !AuthMethod {
    if (std.mem.eql(u8, s, "NONE")) return .NONE;
    if (std.mem.eql(u8, s, "API_KEY")) return .API_KEY;
    if (std.mem.eql(u8, s, "OAUTH2")) return .OAUTH2;
    if (std.mem.eql(u8, s, "MUTUAL_TLS")) return .MUTUAL_TLS;
    return error.InvalidAuthMethod;
}

fn parseScope(s: []const u8) ServiceScope {
    if (std.mem.eql(u8, s, "tenant")) return .tenant;
    return .global;
}

fn rowToRecord(allocator: std.mem.Allocator, row: []?[]u8) !ServiceCatalogRecord {
    const col = struct {
        fn get(r: []?[]u8, i: usize) []const u8 {
            if (i >= r.len) return "";
            return r[i] orelse "";
        }
    };

    const auth = parseAuthMethod(col.get(row, 4)) catch .NONE;
    const timeout_str = col.get(row, 5);
    const timeout_ms: u32 = @intCast(std.fmt.parseInt(i64, timeout_str, 10) catch 0);
    const scope = parseScope(col.get(row, 7));
    const owner_tenant_id: ?[16]u8 = blk: {
        const s = col.get(row, 8);
        if (s.len == 0) break :blk null;
        break :blk hexToUuid(s) catch null;
    };

    const service_id = try allocator.dupe(u8, col.get(row, 0));
    errdefer allocator.free(service_id);
    const endpoint_url = try allocator.dupe(u8, col.get(row, 1));
    errdefer allocator.free(endpoint_url);
    const request_schema = try allocator.dupe(u8, col.get(row, 2));
    errdefer allocator.free(request_schema);
    const response_schema = try allocator.dupe(u8, col.get(row, 3));
    errdefer allocator.free(response_schema);
    const retry_policy = try allocator.dupe(u8, col.get(row, 6));
    errdefer allocator.free(retry_policy);

    return ServiceCatalogRecord{
        .service_id = service_id,
        .endpoint_url = endpoint_url,
        .request_schema = request_schema,
        .response_schema = response_schema,
        .required_auth = auth,
        .timeout_ms = timeout_ms,
        .retry_policy = retry_policy,
        .scope = scope,
        .owner_tenant_id = owner_tenant_id,
        .created_at = std.fmt.parseInt(i64, col.get(row, 9), 10) catch 0,
        .updated_at = std.fmt.parseInt(i64, col.get(row, 10), 10) catch 0,
    };
}

fn freeRecord(allocator: std.mem.Allocator, rec: ServiceCatalogRecord) void {
    allocator.free(rec.service_id);
    allocator.free(rec.endpoint_url);
    allocator.free(rec.request_schema);
    allocator.free(rec.response_schema);
    allocator.free(rec.retry_policy);
}

fn uuidToHex(allocator: std.mem.Allocator, uuid: [16]u8) ![]u8 {
    const hex = try allocator.alloc(u8, 36);
    _ = std.fmt.bufPrint(hex, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        uuid[0],  uuid[1],  uuid[2],  uuid[3],
        uuid[4],  uuid[5],  uuid[6],  uuid[7],
        uuid[8],  uuid[9],  uuid[10], uuid[11],
        uuid[12], uuid[13], uuid[14], uuid[15],
    }) catch {
        allocator.free(hex);
        return error.InvalidUuid;
    };
    return hex;
}

fn hexToUuid(s: []const u8) ![16]u8 {
    var uuid: [16]u8 = undefined;
    var src: [32]u8 = undefined;
    if (s.len == 36) {
        var j: usize = 0;
        for (s) |c| {
            if (c != '-') {
                if (j >= 32) return error.InvalidUuid;
                src[j] = c;
                j += 1;
            }
        }
        if (j != 32) return error.InvalidUuid;
    } else if (s.len == 32) {
        @memcpy(&src, s);
    } else {
        return error.InvalidUuid;
    }
    for (0..16) |i| {
        uuid[i] = try std.fmt.parseInt(u8, src[i * 2 .. i * 2 + 2], 16);
    }
    return uuid;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ServiceCatalog initialization" {
    const allocator = std.testing.allocator;
    var catalog = ServiceCatalog.init(allocator, undefined);
    defer catalog.deinit();
}

test "AuthMethod enum values" {
    _ = AuthMethod.NONE;
    _ = AuthMethod.API_KEY;
    _ = AuthMethod.OAUTH2;
    _ = AuthMethod.MUTUAL_TLS;
}

test "ServiceScope enum values" {
    _ = ServiceScope.global;
    _ = ServiceScope.tenant;
}
