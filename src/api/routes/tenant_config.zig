//! GET /api/tenant-config?host={hostname}
//!
//! Public endpoint (no auth required) that returns the OIDC authority URL
//! and client_id for the tenant associated with the given hostname.
//! If no binding is found, or on any DB error, returns the default tenant config.
//!
//! Requirement: OIDC-F-05

const std = @import("std");
const db_pool = @import("pool");
const response = @import("../response.zig");
const logger = @import("../../obs/logger.zig");
const env = @import("env");

pub const HandlerResult = response.HandlerResult;

pub const TenantConfigError = error{
    /// Database pool exhausted — no connection available.
    PoolExhausted,
    /// Query or row-fetch failed.
    PersistenceFailed,
    /// Allocator out of memory.
    OutOfMemory,
};

pub const TenantConfigResponse = struct {
    oidc_authority: []const u8,
    client_id: []const u8,
};

/// Read an environment variable; returns default if not set or on error.
fn getEnvVar(allocator: std.mem.Allocator, name: []const u8, default: []const u8) []const u8 {
    const environ = env.globalEnviron();
    return (environ.getAlloc(allocator, name) catch null) orelse default;
}

/// Parse a query parameter by key from a raw query string.
fn getQueryParam(query_str: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query_str, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOf(u8, pair, "=") orelse continue;
        if (std.ascii.eqlIgnoreCase(pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

/// Handle GET /api/tenant-config?host={hostname}.
///
/// Returns JSON { "oidc_authority": "...", "client_id": "..." }.
/// Never returns an error to the caller — DB failures fall through to
/// the default tenant config so the frontend login page always renders.
pub fn handleTenantConfig(
    allocator: std.mem.Allocator,
    pool: *db_pool.Pool,
    query_str: []const u8,
) HandlerResult {
    // Check BPM_IDP_BASE_URL first (matches .env file), then KEYCLOAK_BASE_URL for compat.
    // Fallback uses "localhost" instead of "127.0.0.1" so browser OIDC origin matches.
    const keycloak_base = getEnvVar(allocator, "BPM_IDP_BASE_URL", getEnvVar(allocator, "KEYCLOAK_BASE_URL", "http://localhost:8081"));
    const client_id = getEnvVar(allocator, "OIDC_CLIENT_ID", "bpm-platform-api");

    var realm_id: []const u8 = "bpm-default";
    var realm_resolved = false;

    // Step 1: ?realm=<slug> lookup — bypasses hostname lookup when slug resolves.
    if (getQueryParam(query_str, "realm")) |slug| {
        if (resolveTenantBySlug(allocator, pool, slug)) |realm_opt| {
            if (realm_opt) |r| {
                realm_id = r;
                realm_resolved = true;
            }
        } else |err| {
            const fields = [_]logger.LogField{
                .{ .key = "error", .value = .{ .string = @errorName(err) } },
                .{ .key = "slug", .value = .{ .string = slug } },
            };
            logger.log(allocator, .WARN, "api.tenant_config", "realm slug lookup failed; falling through to host", &fields) catch {};
        }
    }

    // Step 2: ?host=<hostname> lookup — only when realm not already resolved.
    if (!realm_resolved) {
        if (getQueryParam(query_str, "host")) |host| {
            if (queryRealmByHostname(allocator, pool, host)) |realm_opt| {
                if (realm_opt) |r| {
                    realm_id = r;
                }
            } else |err| {
                const fields = [_]logger.LogField{
                    .{ .key = "error", .value = .{ .string = @errorName(err) } },
                    .{ .key = "hostname", .value = .{ .string = host } },
                };
                logger.log(allocator, .WARN, "api.tenant_config", "hostname lookup failed; using default realm", &fields) catch {};
            }
        }
    }

    const authority = std.fmt.allocPrint(allocator, "{s}/realms/{s}", .{ keycloak_base, realm_id }) catch {
        return .{
            .status_code = 200,
            .body = "{\"oidc_authority\":\"http://localhost:8081/realms/bpm-default\",\"client_id\":\"bpm-platform-api\"}",
            .content_type = "application/json",
        };
    };

    const body = std.fmt.allocPrint(
        allocator,
        "{{\"oidc_authority\":\"{s}\",\"client_id\":\"{s}\"}}",
        .{ authority, client_id },
    ) catch {
        return .{
            .status_code = 200,
            .body = "{\"oidc_authority\":\"http://localhost:8081/realms/bpm-default\",\"client_id\":\"bpm-platform-api\"}",
            .content_type = "application/json",
        };
    };

    return .{
        .status_code = 200,
        .body = body,
        .content_type = "application/json",
    };
}

/// Query tenant by slug to get its idp_realm_id.
/// Returns null if no tenant row matches the slug.
fn resolveTenantBySlug(
    allocator: std.mem.Allocator,
    pool: *db_pool.Pool,
    slug: []const u8,
) TenantConfigError!?[]const u8 {
    const conn = pool.acquire() catch |err| return switch (err) {
        db_pool.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        \\SELECT idp_realm_id FROM public.tenant WHERE slug = $1 LIMIT 1
    ,
        &[_][]const u8{slug},
    ) catch |err| return switch (err) {
        db_pool.PoolError.StaleConnection,
        db_pool.PoolError.ConnectionFailed,
        db_pool.PoolError.QueryFailed,
        => error.PersistenceFailed,
        db_pool.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };

    const row_data = row orelse return null;
    defer {
        for (row_data) |col| {
            if (col) |c| allocator.free(c);
        }
        allocator.free(row_data);
    }

    if (row_data.len < 1) return null;
    const realm = row_data[0] orelse return null;
    return try allocator.dupe(u8, realm);
}

/// Query tenant_hostnames -> tenant to resolve idp_realm_id for a given hostname.
/// Returns null if no binding is found.
fn queryRealmByHostname(
    allocator: std.mem.Allocator,
    pool: *db_pool.Pool,
    hostname: []const u8,
) TenantConfigError!?[]const u8 {
    const conn = pool.acquire() catch |err| return switch (err) {
        db_pool.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        \\SELECT t.idp_realm_id
        \\FROM tenant_hostnames th
        \\JOIN tenant t ON t.id = th.tenant_id
        \\WHERE th.hostname = $1
        \\LIMIT 1
    ,
        &[_][]const u8{hostname},
    ) catch |err| return switch (err) {
        db_pool.PoolError.StaleConnection,
        db_pool.PoolError.ConnectionFailed,
        db_pool.PoolError.QueryFailed,
        => error.PersistenceFailed,
        db_pool.PoolError.ExhaustedPool => error.PoolExhausted,
        else => error.PersistenceFailed,
    };

    const row_data = row orelse return null;
    defer {
        for (row_data) |col| {
            if (col) |c| allocator.free(c);
        }
        allocator.free(row_data);
    }

    if (row_data.len < 1) return null;
    const realm = row_data[0] orelse return null;
    return try allocator.dupe(u8, realm);
}
