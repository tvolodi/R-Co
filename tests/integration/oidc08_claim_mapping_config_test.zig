//! OIDC-08 — Standard claim mapping integration tests.
//!
//! Tests for the DB-backed config loading function:
//!   - loadClaimMappingConfig
//!
//! All tests connect to real PostgreSQL via BPM_TEST_DB_URL.
//! No mocks, no stubs, no in-memory fakes.

const std = @import("std");
const portable_env = @import("env");
const testing = std.testing;
const pg = @import("pg");
const cm = @import("claim_mapping");
const pool_mod = @import("pool");

const DEFAULT_CLAIM_MAPPING_CONFIG = cm.DEFAULT_CLAIM_MAPPING_CONFIG;

fn testDbUrl(allocator: std.mem.Allocator) ![]u8 {
    const env = portable_env.globalEnviron();
    return env.getAlloc(allocator, "BPM_TEST_DB_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => {
            std.debug.print("BPM_TEST_DB_URL is not set — skipping integration test\n", .{});
            return error.SkipZigTest;
        },
        else => return err,
    };
}

fn makePool(allocator: std.mem.Allocator, url: []const u8) !pool_mod.Pool {
    return pool_mod.Pool.init(std.testing.io, allocator, .{ .url = url, .pool_size = 5 });
}

fn insertConfigRow(pool: *pool_mod.Pool, realm: []const u8) !void {
    const conn = pool.acquire() catch |err| return err;
    defer pool.release(conn);

    try conn.exec(
        \\INSERT INTO realm_claim_mapping_config
        \\(realm, tenant_id_claim, roles_claim_paths, email_claim,
        \\ preferred_username_claim, display_name_claim)
        \\VALUES ($1, $2, $3, $4, $5, $6)
        \\ON CONFLICT (realm) DO UPDATE SET
        \\  tenant_id_claim = EXCLUDED.tenant_id_claim,
        \\  roles_claim_paths = EXCLUDED.roles_claim_paths,
        \\  email_claim = EXCLUDED.email_claim,
        \\  preferred_username_claim = EXCLUDED.preferred_username_claim,
        \\  display_name_claim = EXCLUDED.display_name_claim
    ,
        &[_][]const u8{
            realm,
            "tenant_id",
            "{custom_realm.roles}",
            "email_address",
            "username",
            "full_name",
        },
    );
}

fn deleteConfigRow(pool: *pool_mod.Pool, realm: []const u8) !void {
    const conn = pool.acquire() catch return;
    defer pool.release(conn);
    conn.exec("DELETE FROM realm_claim_mapping_config WHERE realm = $1", &[_][]const u8{realm}) catch {};
}

// ---------------------------------------------------------------------------
// TC-OIDC-08-I01: Config loaded from DB when row exists
// ---------------------------------------------------------------------------

test "TC-OIDC-08-I01: config loaded from DB when row exists" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // Ensure clean state
    try deleteConfigRow(&pool, "test-realm-i01");

    // Insert a config row
    try insertConfigRow(&pool, "test-realm-i01");

    // Load the config
    const config = (try cm.loadClaimMappingConfig(alloc, &pool, "test-realm-i01")) orelse
        return error.TestUnexpectedResult;
    defer {
        alloc.free(config.realm);
        alloc.free(config.tenant_id_claim);
        for (config.roles_claim_paths) |p| alloc.free(p);
        alloc.free(config.roles_claim_paths);
        alloc.free(config.email_claim);
        alloc.free(config.preferred_username_claim);
        alloc.free(config.display_name_claim);
    }

    try testing.expectEqualStrings("test-realm-i01", config.realm);
    try testing.expectEqualStrings("tenant_id", config.tenant_id_claim);
    try testing.expectEqualStrings("email_address", config.email_claim);
    try testing.expectEqualStrings("username", config.preferred_username_claim);
    try testing.expectEqualStrings("full_name", config.display_name_claim);
    // roles_claim_paths should contain our custom path
    try testing.expect(config.roles_claim_paths.len > 0);
    try testing.expectEqualStrings("custom_realm.roles", config.roles_claim_paths[0]);
}

// ---------------------------------------------------------------------------
// TC-OIDC-08-I02: Config returns null when no row exists
// ---------------------------------------------------------------------------

test "TC-OIDC-08-I02: config returns null when no row exists" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    // Ensure no row exists for this realm
    try deleteConfigRow(&pool, "unknown-realm-i02");

    const config = try cm.loadClaimMappingConfig(alloc, &pool, "unknown-realm-i02");
    try testing.expect(config == null);
}

// ---------------------------------------------------------------------------
// TC-OIDC-08-I03: Config with custom non-default paths
// ---------------------------------------------------------------------------

test "TC-OIDC-08-I03: config with custom non-default claim paths" {
    const alloc = testing.allocator;
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool = try makePool(alloc, url);
    defer pool.deinit();

    const realm_name = "custom-paths-realm-i03";

    // Clean up first
    try deleteConfigRow(&pool, realm_name);

    // Insert with completely custom paths
    {
        const conn = pool.acquire() catch |err| return err;
        defer pool.release(conn);
        try conn.exec(
            \\INSERT INTO realm_claim_mapping_config
            \\(realm, tenant_id_claim, roles_claim_paths, email_claim,
            \\ preferred_username_claim, display_name_claim)
            \\VALUES ($1, $2, $3, $4, $5, $6)
            \\ON CONFLICT (realm) DO UPDATE SET
            \\  tenant_id_claim = EXCLUDED.tenant_id_claim,
            \\  roles_claim_paths = EXCLUDED.roles_claim_paths,
            \\  email_claim = EXCLUDED.email_claim,
            \\  preferred_username_claim = EXCLUDED.preferred_username_claim,
            \\  display_name_claim = EXCLUDED.display_name_claim
        ,
            &[_][]const u8{
                realm_name,
                "custom.tenant.path",
                "{app_metadata.roles,legacy_roles}",
                "contact.email",
                "user.preferred_name",
                "profile.display_name",
            },
        );
    }

    const config_opt = try cm.loadClaimMappingConfig(alloc, &pool, realm_name);
    const config = config_opt orelse return error.TestUnexpectedResult;
    defer {
        alloc.free(config.realm);
        alloc.free(config.tenant_id_claim);
        for (config.roles_claim_paths) |p| alloc.free(p);
        alloc.free(config.roles_claim_paths);
        alloc.free(config.email_claim);
        alloc.free(config.preferred_username_claim);
        alloc.free(config.display_name_claim);
    }

    try testing.expectEqualStrings(realm_name, config.realm);
    try testing.expectEqualStrings("custom.tenant.path", config.tenant_id_claim);
    try testing.expect(config.roles_claim_paths.len >= 2);
    try testing.expectEqualStrings("app_metadata.roles", config.roles_claim_paths[0]);
    try testing.expectEqualStrings("legacy_roles", config.roles_claim_paths[1]);
    try testing.expectEqualStrings("contact.email", config.email_claim);
    try testing.expectEqualStrings("user.preferred_name", config.preferred_username_claim);
    try testing.expectEqualStrings("profile.display_name", config.display_name_claim);

    // Clean up
    try deleteConfigRow(&pool, realm_name);
}
