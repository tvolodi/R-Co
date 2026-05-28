//! Integration preflight tests for OIDC-31 end-to-end authentication suite.
//!
//! Requirement: OIDC-31 [MUST]
//!
//! These tests verify the real-environment prerequisites for the OIDC E2E suite:
//! - test database connectivity
//! - Keycloak discovery endpoint reachability
//! - backend health endpoint reachability
//!
//! Optional role-token preflight checks are executed when role tokens are provided.

const std = @import("std");
const testing = std.testing;
const pool_mod = @import("pool");

fn freeRow(allocator: std.mem.Allocator, row: []?[]u8) void {
    for (row) |col| {
        if (col) |value| allocator.free(value);
    }
    allocator.free(row);
}

fn getEnvOrSkip(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        else => return err,
    };
}

fn getEnvOrNull(allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
    const env: std.process.Environ = .{ .block = .global };
    return env.getAlloc(allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };
}

fn expectHttpStatus(url: []const u8, headers: []const std.http.Header, expected_status: std.http.Status) !void {
    var client: std.http.Client = .{ .io = std.testing.io, .allocator = testing.allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{ .extra_headers = headers });
    defer req.deinit();

    try req.sendBodiless();

    var redirect_buf: [8192]u8 = undefined;
    const resp = try req.receiveHead(&redirect_buf);
    try testing.expectEqual(expected_status, resp.head.status);
}

fn bearerHeader(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
}

test "TC-OIDC-31-01: preflight validates DB, IDP discovery, and backend health" {
    const alloc = testing.allocator;

    const db_url = try getEnvOrSkip(alloc, "BPM_TEST_DB_URL");
    defer alloc.free(db_url);

    const api_base = try getEnvOrSkip(alloc, "BPM_TEST_URL");
    defer alloc.free(api_base);

    const idp_base = try getEnvOrSkip(alloc, "BPM_IDP_BASE_URL");
    defer alloc.free(idp_base);

    var db = try pool_mod.Pool.init(std.testing.io, alloc, .{ .url = db_url, .pool_size = 2 });
    defer db.deinit();

    {
        const conn = try db.acquire();
        defer db.release(conn);
        const row = (try conn.queryRow(alloc, "SELECT 1::text", &[_][]const u8{})) orelse return error.TestUnexpectedResult;
        defer freeRow(alloc, row);
        const one = row[0] orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("1", one);
    }

    const discovery_url = try std.fmt.allocPrint(alloc, "{s}/realms/bpm-default/.well-known/openid-configuration", .{idp_base});
    defer alloc.free(discovery_url);
    try expectHttpStatus(discovery_url, &.{}, .ok);

    const health_url = try std.fmt.allocPrint(alloc, "{s}/health/live", .{api_base});
    defer alloc.free(health_url);
    try expectHttpStatus(health_url, &.{}, .ok);
}

test "TC-OIDC-31-02: optional role tokens can authenticate backend health route" {
    const alloc = testing.allocator;

    const api_base = try getEnvOrSkip(alloc, "BPM_TEST_URL");
    defer alloc.free(api_base);

    const admin_token = try getEnvOrNull(alloc, "BPM_TEST_TOKEN_ADMIN");
    defer if (admin_token) |v| alloc.free(v);
    const designer_token = try getEnvOrNull(alloc, "BPM_TEST_TOKEN_DESIGNER");
    defer if (designer_token) |v| alloc.free(v);
    const worker_token = try getEnvOrNull(alloc, "BPM_TEST_TOKEN_WORKER");
    defer if (worker_token) |v| alloc.free(v);

    // If role-scoped tokens are not provided in this environment, skip this optional preflight.
    if (admin_token == null and designer_token == null and worker_token == null) {
        return error.SkipZigTest;
    }

    const health_url = try std.fmt.allocPrint(alloc, "{s}/health/live", .{api_base});
    defer alloc.free(health_url);

    const token_list = [_]?[]const u8{ admin_token, designer_token, worker_token };
    for (token_list) |token_opt| {
        if (token_opt) |token| {
            const auth_header = try bearerHeader(alloc, token);
            defer alloc.free(auth_header);
            const headers: []const std.http.Header = &.{.{ .name = "Authorization", .value = auth_header }};
            try expectHttpStatus(health_url, headers, .ok);
        }
    }
}
