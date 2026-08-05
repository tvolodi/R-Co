//! Integration tests for ISS-0072 — GET /api/tenant-config ?realm= hint.
//!
//! Covers: OIDC-F-05 (backend realm-slug lookup path)
//! Test cases: TC-OIDC-F05-01, TC-OIDC-F05-02, TC-OIDC-F05-03
//!
//! All tests require a real PostgreSQL database via BPM_TEST_DB_URL.
//!
//! DIRECTIVE T-1: No mocks — all state persisted to real PostgreSQL.
//! No error.SkipZigTest on any MUST test block.
//! All fixtures use per-test UUID-derived slugs with cleanup on defer.

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;
const bpm = @import("bpm");
const Pool = bpm.pool.Pool;
const PoolConfig = bpm.pool.PoolConfig;
const tenant_config = bpm.tenant_config_routes;

// ---------------------------------------------------------------------------
// OS-level random bytes (Zig 0.16: std.crypto.random removed)
// ---------------------------------------------------------------------------

fn fillRandom(buf: []u8) void {
    const builtin = @import("builtin");
    switch (comptime builtin.os.tag) {
        .linux => _ = std.os.linux.getrandom(buf.ptr, buf.len, 0),
        .windows => {
            const adv = struct {
                extern "advapi32" fn SystemFunction036(pbBuffer: *anyopaque, cbBuffer: u32) u8;
            };
            _ = adv.SystemFunction036(@ptrCast(buf.ptr), @intCast(buf.len));
        },
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .freebsd, .netbsd, .openbsd, .dragonfly => std.c.arc4random_buf(buf.ptr, buf.len),
        else => @compileError("fillRandom: unsupported OS — add a platform branch"),
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn testDbUrl(alloc: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(alloc, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is required for ISS-0072 tenant-config realm integration tests\n", .{});
            return err;
        },
        else => return err,
    };
}

fn makePool(alloc: std.mem.Allocator, url: []const u8) !Pool {
    return Pool.init(std.testing.io, alloc, PoolConfig{ .url = url, .pool_size = 3 });
}

/// Generate a UUID v4 string (36 chars, dash-separated).
fn generateUuid(alloc: std.mem.Allocator) ![]u8 {
    var raw: [16]u8 = undefined;
    fillRandom(&raw);
    raw[6] = (raw[6] & 0x0f) | 0x40; // version 4
    raw[8] = (raw[8] & 0x3f) | 0x80; // variant
    const hex_chars = "0123456789abcdef";
    const out = try alloc.alloc(u8, 36);
    const parts = [_]usize{ 4, 2, 2, 2, 6 };
    var o: usize = 0;
    var b: usize = 0;
    for (parts, 0..) |byte_count, pi| {
        if (pi > 0) {
            out[o] = '-';
            o += 1;
        }
        for (0..byte_count) |_| {
            out[o] = hex_chars[raw[b] >> 4];
            out[o + 1] = hex_chars[raw[b] & 0x0f];
            o += 2;
            b += 1;
        }
    }
    return out;
}

/// Generate a short unique slug: "iss0072-<12 random hex chars>".
fn generateSlug(alloc: std.mem.Allocator) ![]u8 {
    var rand_bytes: [6]u8 = undefined;
    fillRandom(&rand_bytes);
    return std.fmt.allocPrint(alloc, "iss0072-{s}", .{std.fmt.bytesToHex(&rand_bytes, .lower)});
}

/// Insert a minimal tenant row (autocommit — visible to all subsequent connections).
fn insertTestTenant(
    pool: *Pool,
    id: []const u8,
    slug: []const u8,
    idp_realm_id: []const u8,
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO public.tenant (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $3, 'ACTIVE', $4, 'test', $5::uuid)
        \\ON CONFLICT (id) DO NOTHING
    , &[_][]const u8{ id, slug, slug, idp_realm_id, "00000000-0000-0000-0000-000000000000" });
}

/// Delete the test tenant row. Silent on failure so defer cleanup is safe.
fn deleteTestTenant(pool: *Pool, id: []const u8) void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec(
        "DELETE FROM public.tenant WHERE id = $1::uuid",
        &[_][]const u8{id},
    ) catch {};
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// TC-OIDC-F05-01: ?realm=<slug> returns oidc_authority containing the tenant's idp_realm_id.
// Inserts a tenant with a unique per-test slug, calls handleTenantConfig with
// ?realm=<slug>, asserts the response body contains the slug (= idp_realm_id).
test "TC-OIDC-F05-01: realm=slug returns oidc_authority containing idp_realm_id for existing tenant" {
    // Pool uses testing.allocator directly (long-lived across handler calls).
    const alloc = testing.allocator;

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const id = try generateUuid(alloc);
    defer alloc.free(id);

    const slug = try generateSlug(alloc);
    defer alloc.free(slug);

    // slug == idp_realm_id so that authority URL contains the slug.
    try insertTestTenant(&pool, id, slug, slug);
    defer deleteTestTenant(&pool, id);

    const query_str = try std.fmt.allocPrint(alloc, "realm={s}", .{slug});
    defer alloc.free(query_str);

    // handleTenantConfig allocates several intermediate strings that it does not
    // free (request-scoped pattern assumes arena allocator at call site).
    // Use an arena to prevent testing.allocator leak reports.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const handler_alloc = arena.allocator();

    const result = tenant_config.handleTenantConfig(handler_alloc, &pool, query_str);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, slug));
}

// TC-OIDC-F05-02: ?realm= with non-existent slug falls back to bpm-default.
// Calls handleTenantConfig with a slug that has no tenant row.
// Expects HTTP 200 with oidc_authority containing "bpm-default".
test "TC-OIDC-F05-02: realm=no-such-slug falls back to bpm-default authority" {
    const alloc = testing.allocator;

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const handler_alloc = arena.allocator();

    const result = tenant_config.handleTenantConfig(
        handler_alloc,
        &pool,
        "realm=no-such-realm-iss0072-xyz",
    );

    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "bpm-default"));
}

// TC-OIDC-F05-03: ?host=127.0.0.1 still returns 200 (non-regression for existing path).
// No tenant_hostnames row exists for 127.0.0.1 in the test DB, so the handler
// falls through to the default realm. Verifies the ?host= path was not broken.
test "TC-OIDC-F05-03: host=127.0.0.1 returns 200 with bpm-default (non-regression)" {
    const alloc = testing.allocator;

    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const handler_alloc = arena.allocator();

    const result = tenant_config.handleTenantConfig(
        handler_alloc,
        &pool,
        "host=127.0.0.1",
    );

    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expect(std.mem.containsAtLeast(u8, result.body, 1, "bpm-default"));
}
