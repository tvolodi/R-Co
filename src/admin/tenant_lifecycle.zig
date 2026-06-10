//! ENV-05: Test tenant lifecycle management.
//!
//! POST   /api/v1/admin/tenants/:test_tenant_id/reset   (platform-admin only)
//! DELETE /api/v1/admin/tenants/:test_tenant_id         (platform-admin only)
//!
//! Reset: TRUNCATE all business data tables in tenant schema, preserving
//!        identity/config tables.
//! Delete: DROP SCHEMA CASCADE, delete Keycloak realm, remove public rows.

const std = @import("std");
const pool_mod = @import("pool");
const identity_provider = @import("identity_provider");
const tenant_context_mod = @import("tenant_context");

// ── Error set ──────────────────────────────────────────────────────────────────

pub const TenantLifecycleError = error{
    TenantNotFound,             // :test_tenant_id does not exist     → 404
    NotATestTenant,             // tenant_type != 'test'              → 422
    TenantHasActiveInstances,   // active process instances exist     → 409
    SchemaDropFailed,           // DROP SCHEMA CASCADE failed         → 500
    RealmDeleteFailed,          // Keycloak realm deletion failed     → 500
    PublicRowDeleteFailed,      // could not remove public table rows → 500
    PoolExhausted,
    OutOfMemory,
};

pub const ResetResult = struct {
    reset_at: []const u8,             // ISO 8601 UTC timestamp (owned)
    tables_truncated: []const []const u8, // list of table names (owned)

    pub fn deinit(self: ResetResult, allocator: std.mem.Allocator) void {
        allocator.free(self.reset_at);
        for (self.tables_truncated) |t| allocator.free(t);
        allocator.free(self.tables_truncated);
    }
};

pub const HandlerResult = struct {
    status_code: u16,
    body: []const u8,
};

// ── Tables truncated during reset ──────────────────────────────────────────────

const RESET_TABLES = [_][]const u8{
    "tokens",
    "timers",
    "tasks",
    "dead_letter_items",
    "webhook_subscriptions",
    "audit_entries",
    "audit_log",
    "instance_projections",
    "events_archive",
    "events",
    "process_definitions",
};

// ── Public functions ────────────────────────────────────────────────────────────

/// Truncate all business data tables in the test tenant's schema.
/// Identity and configuration tables are preserved.
pub fn resetTestTenant(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    test_tenant_id: []const u8,
) TenantLifecycleError!ResetResult {
    // ── Step 1: Verify tenant exists and is test type ─────────────────────────
    const saved = tenant_context_mod.get();
    defer if (saved.len > 0) tenant_context_mod.set(saved) else tenant_context_mod.clear();
    tenant_context_mod.clear();

    {
        const conn = pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => TenantLifecycleError.PoolExhausted,
            else => TenantLifecycleError.TenantNotFound,
        };
        defer pool.release(conn);

        // Security: test_tenant_id bound as $1::uuid — no SQL string interpolation.
        const row = conn.queryRow(
            allocator,
            "SELECT tenant_type FROM public.tenant WHERE id = $1::uuid LIMIT 1",
            &[_][]const u8{test_tenant_id},
        ) catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => TenantLifecycleError.PoolExhausted,
            else => TenantLifecycleError.TenantNotFound,
        };
        if (row == null) return TenantLifecycleError.TenantNotFound;
        const r = row.?;
        defer {
            for (r) |col| if (col) |v| allocator.free(v);
            allocator.free(r);
        }
        const tenant_type = r[0] orelse "production";
        if (!std.mem.eql(u8, tenant_type, "test")) return TenantLifecycleError.NotATestTenant;
    }

    // ── Step 2: Check for active process instances ────────────────────────────
    tenant_context_mod.set(test_tenant_id);
    {
        const conn = pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => TenantLifecycleError.PoolExhausted,
            else => TenantLifecycleError.TenantNotFound,
        };
        defer pool.release(conn);

        const row = conn.queryRow(
            allocator,
            \\SELECT COUNT(*)::text
            \\FROM instance_projections
            \\WHERE status NOT IN ('COMPLETED', 'CANCELLED', 'FAILED')
        ,
            &[_][]const u8{},
        ) catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => TenantLifecycleError.PoolExhausted,
            else => TenantLifecycleError.TenantNotFound,
        };
        if (row) |r| {
            defer {
                for (r) |col| if (col) |v| allocator.free(v);
                allocator.free(r);
            }
            const count = std.fmt.parseInt(u64, r[0] orelse "0", 10) catch 0;
            if (count > 0) return TenantLifecycleError.TenantHasActiveInstances;
        }
    }

    // ── Step 3: TRUNCATE all business data tables in a single statement ───────
    tenant_context_mod.set(test_tenant_id);
    {
        const conn = pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => TenantLifecycleError.PoolExhausted,
            else => TenantLifecycleError.TenantNotFound,
        };
        defer pool.release(conn);

        conn.exec(
            \\TRUNCATE tokens, timers, tasks, dead_letter_items, webhook_subscriptions,
            \\         audit_entries, audit_log, instance_projections,
            \\         events_archive, events, process_definitions
            \\CASCADE
        ,
            &[_][]const u8{},
        ) catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => TenantLifecycleError.PoolExhausted,
            else => TenantLifecycleError.TenantNotFound,
        };
    }

    // ── Step 4: Build result ──────────────────────────────────────────────────
    // Build a simple ISO timestamp string from the system clock.
    const reset_at = buildIsoTimestamp(allocator) catch return TenantLifecycleError.OutOfMemory;
    errdefer allocator.free(reset_at);

    const tables = try allocator.alloc([]const u8, RESET_TABLES.len);
    var filled: usize = 0;
    errdefer {
        for (tables[0..filled]) |t| allocator.free(t);
        allocator.free(tables);
    }
    for (RESET_TABLES) |name| {
        tables[filled] = allocator.dupe(u8, name) catch return TenantLifecycleError.OutOfMemory;
        filled += 1;
    }

    return ResetResult{
        .reset_at        = reset_at,
        .tables_truncated = tables,
    };
}

/// Fully decommission a test tenant.
pub fn deleteTestTenant(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    idp_manager: identity_provider.manager.Manager,
    test_tenant_id: []const u8,
) TenantLifecycleError!void {
    // ── Step 1: Verify tenant exists and is test type ─────────────────────────
    const saved = tenant_context_mod.get();
    defer if (saved.len > 0) tenant_context_mod.set(saved) else tenant_context_mod.clear();
    tenant_context_mod.clear();

    var realm_id_buf: [256]u8 = undefined;
    var realm_id_len: usize = 0;

    {
        const conn = pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => TenantLifecycleError.PoolExhausted,
            else => TenantLifecycleError.TenantNotFound,
        };
        defer pool.release(conn);

        // Security: test_tenant_id bound as $1::uuid — no SQL string interpolation.
        const row = conn.queryRow(
            allocator,
            "SELECT tenant_type, idp_realm_id FROM public.tenant WHERE id = $1::uuid LIMIT 1",
            &[_][]const u8{test_tenant_id},
        ) catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => TenantLifecycleError.PoolExhausted,
            else => TenantLifecycleError.TenantNotFound,
        };
        if (row == null) return TenantLifecycleError.TenantNotFound;
        const r = row.?;
        defer {
            for (r) |col| if (col) |v| allocator.free(v);
            allocator.free(r);
        }
        const tenant_type = r[0] orelse "production";
        if (!std.mem.eql(u8, tenant_type, "test")) return TenantLifecycleError.NotATestTenant;

        const realm_id_raw = r[1] orelse "";
        if (realm_id_raw.len > 0 and realm_id_raw.len <= realm_id_buf.len) {
            @memcpy(realm_id_buf[0..realm_id_raw.len], realm_id_raw);
            realm_id_len = realm_id_raw.len;
        }
    }

    // ── Step 2: DROP SCHEMA CASCADE ──────────────────────────────────────────
    // Build schema name: tenant_ + UUID without dashes.
    // The UUID is validated to be a UUID format before use.
    const schema_name = buildSchemaName(allocator, test_tenant_id) catch return TenantLifecycleError.SchemaDropFailed;
    defer allocator.free(schema_name);

    {
        tenant_context_mod.clear();
        const conn = pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => TenantLifecycleError.PoolExhausted,
            else => TenantLifecycleError.SchemaDropFailed,
        };
        defer pool.release(conn);

        // Security: schema_name is built from a validated UUID (hex + underscores only).
        // We use format string but the schema name contains only [a-z0-9_] from the UUID.
        const drop_sql = std.fmt.allocPrint(
            allocator,
            "DROP SCHEMA IF EXISTS {s} CASCADE",
            .{schema_name},
        ) catch return TenantLifecycleError.SchemaDropFailed;
        defer allocator.free(drop_sql);

        conn.exec(drop_sql, &[_][]const u8{}) catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => TenantLifecycleError.PoolExhausted,
            else => TenantLifecycleError.SchemaDropFailed,
        };
    }

    // ── Step 3: Delete Keycloak realm ────────────────────────────────────────
    if (realm_id_len > 0) {
        const realm_id = realm_id_buf[0..realm_id_len];
        idp_manager.deleteRealm(allocator, .{ .realm_id = realm_id }) catch {
            // Log failure; return error. Public rows NOT removed.
            return TenantLifecycleError.RealmDeleteFailed;
        };
    }

    // ── Step 4: Remove rows from public schema ────────────────────────────────
    {
        tenant_context_mod.clear();
        const conn = pool.acquire() catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => TenantLifecycleError.PoolExhausted,
            else => TenantLifecycleError.PublicRowDeleteFailed,
        };
        defer pool.release(conn);

        // Security: test_tenant_id bound as $1::uuid in all statements.
        conn.exec(
            "DELETE FROM public.tenant_realm_binding WHERE tenant_id = $1::uuid",
            &[_][]const u8{test_tenant_id},
        ) catch {};
        conn.exec(
            "DELETE FROM public.tenant_hostnames WHERE tenant_id = $1::uuid",
            &[_][]const u8{test_tenant_id},
        ) catch {};
        conn.exec(
            "DELETE FROM public.tenant_schemas WHERE tenant_id = $1::uuid",
            &[_][]const u8{test_tenant_id},
        ) catch {};
        conn.exec(
            "DELETE FROM public.tenant WHERE id = $1::uuid",
            &[_][]const u8{test_tenant_id},
        ) catch |err| return switch (err) {
            pool_mod.PoolError.ExhaustedPool => TenantLifecycleError.PoolExhausted,
            else => TenantLifecycleError.PublicRowDeleteFailed,
        };
    }
}

// ── HTTP handlers ───────────────────────────────────────────────────────────────

/// Handle POST /api/v1/admin/tenants/:test_tenant_id/reset
pub fn handleReset(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    test_tenant_id: []const u8,
) HandlerResult {
    const result = resetTestTenant(allocator, pool, test_tenant_id) catch |err| {
        return switch (err) {
            TenantLifecycleError.TenantNotFound => errorResult(allocator, 404, "tenant_not_found"),
            TenantLifecycleError.NotATestTenant => blk: {
                const body = std.fmt.allocPrint(
                    allocator,
                    "{{\"error\":\"not_a_test_tenant\",\"detail\":\"reset is only allowed for test tenants\"}}",
                    .{},
                ) catch break :blk errorResult(allocator, 422, "not_a_test_tenant");
                break :blk .{ .status_code = 422, .body = body };
            },
            TenantLifecycleError.TenantHasActiveInstances => blk: {
                const body = std.fmt.allocPrint(
                    allocator,
                    "{{\"error\":\"active_instances\",\"detail\":\"tenant has active instances; stop or cancel them before resetting\"}}",
                    .{},
                ) catch break :blk errorResult(allocator, 409, "active_instances");
                break :blk .{ .status_code = 409, .body = body };
            },
            TenantLifecycleError.PoolExhausted => errorResult(allocator, 503, "service_unavailable"),
            else => errorResult(allocator, 500, "internal_error"),
        };
    };
    defer result.deinit(allocator);

    // Serialize { reset_at, tables_truncated }.
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    buf.appendSlice(allocator, "{\"reset_at\":\"") catch
        return errorResult(allocator, 500, "serialization_failed");
    buf.appendSlice(allocator, result.reset_at) catch
        return errorResult(allocator, 500, "serialization_failed");
    buf.appendSlice(allocator, "\",\"tables_truncated\":[") catch
        return errorResult(allocator, 500, "serialization_failed");
    for (result.tables_truncated, 0..) |t, idx| {
        if (idx > 0) buf.append(allocator, ',') catch
            return errorResult(allocator, 500, "serialization_failed");
        buf.append(allocator, '"') catch
            return errorResult(allocator, 500, "serialization_failed");
        buf.appendSlice(allocator, t) catch
            return errorResult(allocator, 500, "serialization_failed");
        buf.append(allocator, '"') catch
            return errorResult(allocator, 500, "serialization_failed");
    }
    buf.appendSlice(allocator, "]}") catch
        return errorResult(allocator, 500, "serialization_failed");

    const body = buf.toOwnedSlice(allocator) catch
        return errorResult(allocator, 500, "serialization_failed");
    return .{ .status_code = 200, .body = body };
}

/// Handle DELETE /api/v1/admin/tenants/:test_tenant_id
pub fn handleDelete(
    pool: *pool_mod.Pool,
    allocator: std.mem.Allocator,
    idp_manager: identity_provider.manager.Manager,
    test_tenant_id: []const u8,
) HandlerResult {
    deleteTestTenant(allocator, pool, idp_manager, test_tenant_id) catch |err| {
        return switch (err) {
            TenantLifecycleError.TenantNotFound => errorResult(allocator, 404, "tenant_not_found"),
            TenantLifecycleError.NotATestTenant => blk: {
                const body = std.fmt.allocPrint(
                    allocator,
                    "{{\"error\":\"production_tenant_delete_forbidden\",\"detail\":\"production tenants cannot be deleted via this endpoint; use decommission procedure\"}}",
                    .{},
                ) catch break :blk errorResult(allocator, 422, "production_tenant_delete_forbidden");
                break :blk .{ .status_code = 422, .body = body };
            },
            TenantLifecycleError.PoolExhausted => errorResult(allocator, 503, "service_unavailable"),
            TenantLifecycleError.SchemaDropFailed,
            TenantLifecycleError.RealmDeleteFailed,
            TenantLifecycleError.PublicRowDeleteFailed,
            => errorResult(allocator, 500, "internal_error"),
            else => errorResult(allocator, 500, "internal_error"),
        };
    };

    const empty = allocator.alloc(u8, 0) catch return errorResult(allocator, 500, "internal_error");
    return .{ .status_code = 204, .body = empty };
}

// ── Helpers ──────────────────────────────────────────────────────────────────

fn errorResult(allocator: std.mem.Allocator, status: u16, code: []const u8) HandlerResult {
    const body = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{code}) catch
        "{\"error\":\"internal_error\"}";
    return .{ .status_code = status, .body = body };
}

/// Build schema name "tenant_<uuid_no_dashes>" from a UUID string.
/// Input must be a valid UUID format (36 chars including dashes).
/// Output only contains [a-z0-9_] — safe to use as an SQL identifier.
fn buildSchemaName(allocator: std.mem.Allocator, uuid_str: []const u8) ![]u8 {
    if (uuid_str.len != 36) return error.InvalidUuid;
    // Remove dashes: 32 hex chars + "tenant_" prefix = 39 chars
    var no_dashes: [32]u8 = undefined;
    var out: usize = 0;
    for (uuid_str) |c| {
        if (c == '-') continue;
        if (!isHexChar(c)) return error.InvalidUuid;
        if (out >= 32) return error.InvalidUuid;
        no_dashes[out] = c;
        out += 1;
    }
    if (out != 32) return error.InvalidUuid;
    return std.fmt.allocPrint(allocator, "tenant_{s}", .{no_dashes[0..32]});
}

fn isHexChar(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

/// Build an ISO 8601 UTC timestamp string using platform clock APIs.
fn buildIsoTimestamp(allocator: std.mem.Allocator) ![]u8 {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const ft: i64 = windows.ntdll.RtlGetSystemTimePrecise();
        // Convert 100ns intervals since Jan 1, 1601 to microseconds since Unix epoch.
        const unix_100ns: i64 = ft - 116_444_736_000_000_000;
        const unix_us: i64 = @divTrunc(unix_100ns, 10);
        const unix_secs: i64 = @divTrunc(unix_us, 1_000_000);
        const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(unix_secs) };
        const day = epoch.getEpochDay();
        const year_day = day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_secs = epoch.getDaySeconds();
        return std.fmt.allocPrint(
            allocator,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
            .{
                year_day.year,
                month_day.month.numeric(),
                month_day.day_index + 1,
                day_secs.getHoursIntoDay(),
                day_secs.getMinutesIntoHour(),
                day_secs.getSecondsIntoMinute(),
            },
        );
    } else {
        const posix = std.posix;
        var ts: posix.timespec = undefined;
        _ = posix.system.clock_gettime(.REALTIME, &ts);
        const unix_secs: i64 = ts.sec;
        const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(unix_secs) };
        const day = epoch.getEpochDay();
        const year_day = day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        const day_secs = epoch.getDaySeconds();
        return std.fmt.allocPrint(
            allocator,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
            .{
                year_day.year,
                month_day.month.numeric(),
                month_day.day_index + 1,
                day_secs.getHoursIntoDay(),
                day_secs.getMinutesIntoHour(),
                day_secs.getSecondsIntoMinute(),
            },
        );
    }
}
