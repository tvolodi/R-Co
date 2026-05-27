//! OIDC-08 — Standard claim mapping.
//!
//! Defines the deterministic, purely functional claim-mapping layer that
//! transforms verified OIDC claims into a provider-agnostic internal
//! `IdentityContext` struct.  Mapping rules are configurable per realm so
//! that tokens from different providers produce structurally equivalent
//! identity contexts.
//!
//! ## Key invariants
//!
//! 1. `mapVerifiedClaims` performs **zero I/O** — no database queries,
//!    network calls, or filesystem access.  All data is passed as arguments.
//!
//! 2. `sub` is always required.  `mapVerifiedClaims` errors with
//!    `MappingError.SubClaimMissing` if the subject is empty — although
//!    OIDC-07 should already enforce this.
//!
//! 3. Missing optional claims produce defaults, never errors:
//!    - email → `""`
//!    - preferred_username → `external_user_id` (the sub value)
//!    - roles → `&.{}`
//!    - display_name → `null`
//!    - tenant_id → `null`
//!
//! 4. Two `IdentityContext` values with the same `(external_user_id, realm)`
//!    tuple are equivalent regardless of differences in other fields.

const std = @import("std");

// ---------------------------------------------------------------------------
// Error sets
// ---------------------------------------------------------------------------

/// Errors that can occur when loading configuration from the database.
pub const ClaimMappingError = error{
    RealmConfigNotFound,
    PoolExhausted,
    ConfigParseFailed,
    OutOfMemory,
};

/// Errors that can occur during the pure mapping function.
pub const MappingError = error{
    SubClaimMissing,
    ClaimPathMalformed,
    ClaimTypeMismatch,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

/// Per-realm claim mapping configuration.
pub const ClaimMappingConfig = struct {
    realm: []const u8,
    tenant_id_claim: []const u8,
    roles_claim_paths: []const []const u8,
    email_claim: []const u8,
    preferred_username_claim: []const u8,
    display_name_claim: []const u8,
};

/// Canonical internal identity produced by the claim-mapping layer.
pub const IdentityContext = struct {
    external_user_id: []const u8,
    tenant_id: ?[]const u8,
    realm: []const u8,
    roles: []const []const u8,
    email: []const u8,
    preferred_username: []const u8,
    display_name: ?[]const u8,

    /// Free all owned memory.
    pub fn deinit(self: *IdentityContext, allocator: std.mem.Allocator) void {
        allocator.free(self.external_user_id);
        if (self.tenant_id) |v| allocator.free(v);
        allocator.free(self.realm);
        for (self.roles) |r| allocator.free(r);
        allocator.free(self.roles);
        allocator.free(self.email);
        allocator.free(self.preferred_username);
        if (self.display_name) |v| allocator.free(v);
    }
};

/// Default claim mapping configuration.
pub const DEFAULT_CLAIM_MAPPING_CONFIG: ClaimMappingConfig = .{
    .realm = "",
    .tenant_id_claim = "tenant_id",
    .roles_claim_paths = &.{ "realm_access.roles", "roles" },
    .email_claim = "email",
    .preferred_username_claim = "preferred_username",
    .display_name_claim = "name",
};

// ---------------------------------------------------------------------------
// Configuration loading (I/O boundary)
// ---------------------------------------------------------------------------

/// Load the per-realm claim mapping configuration from the database.
/// Returns `null` when no explicit config row exists for the realm.
pub fn loadClaimMappingConfig(
    allocator: std.mem.Allocator,
    pool: *@import("pool").Pool,
    realm: []const u8,
) ClaimMappingError!?ClaimMappingConfig {
    const conn = pool.acquire() catch |err| switch (err) {
        error.PoolExhausted => return error.PoolExhausted,
        error.StaleConnection => return error.PoolExhausted,
        else => return error.PoolExhausted,
    };
    defer pool.release(conn);

    const row = conn.queryRow(
        allocator,
        \\SELECT tenant_id_claim, roles_claim_paths::text, email_claim,
        \\       preferred_username_claim, display_name_claim
        \\  FROM realm_claim_mapping_config
        \\ WHERE realm = $1
    ,
        &[_][]const u8{realm},
    ) catch |err| switch (err) {
        error.PoolExhausted => return error.PoolExhausted,
        error.StaleConnection => return error.PoolExhausted,
        error.QueryFailed => return error.ConfigParseFailed,
        else => return error.ConfigParseFailed,
    };

    const row_data = row orelse return null;
    defer {
        for (row_data) |col| {
            if (col) |c| allocator.free(c);
        }
        allocator.free(row_data);
    }

    if (row_data.len < 5) return error.ConfigParseFailed;

    const tenant_id_claim = if (row_data[0]) |v|
        try allocator.dupe(u8, v)
    else
        try allocator.dupe(u8, "tenant_id");

    const roles_paths_text = if (row_data[1]) |v| v else {
        allocator.free(tenant_id_claim);
        return error.ConfigParseFailed;
    };
    const roles_claim_paths = try parsePgTextArray(allocator, roles_paths_text);

    const email_claim = if (row_data[2]) |v|
        try allocator.dupe(u8, v)
    else
        try allocator.dupe(u8, "email");

    const preferred_username_claim = if (row_data[3]) |v|
        try allocator.dupe(u8, v)
    else
        try allocator.dupe(u8, "preferred_username");

    const display_name_claim = if (row_data[4]) |v|
        try allocator.dupe(u8, v)
    else
        try allocator.dupe(u8, "name");

    return ClaimMappingConfig{
        .realm = try allocator.dupe(u8, realm),
        .tenant_id_claim = tenant_id_claim,
        .roles_claim_paths = roles_claim_paths,
        .email_claim = email_claim,
        .preferred_username_claim = preferred_username_claim,
        .display_name_claim = display_name_claim,
    };
}

// ---------------------------------------------------------------------------
// Pure mapping function (no I/O)
// ---------------------------------------------------------------------------

/// Transform verified OIDC claims into a canonical internal IdentityContext.
///
/// `subject` is the OIDC `sub` claim.  `raw_claims_json` is the full decoded
/// JWT payload as a JSON string.  This function performs **NO I/O**.
pub fn mapVerifiedClaims(
    allocator: std.mem.Allocator,
    config: ClaimMappingConfig,
    subject: []const u8,
    raw_claims_json: []const u8,
) MappingError!IdentityContext {
    if (subject.len == 0) return error.SubClaimMissing;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw_claims_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ClaimPathMalformed,
    };
    defer parsed.deinit();

    const root = parsed.value;

    const external_user_id = try allocator.dupe(u8, subject);
    errdefer allocator.free(external_user_id);

    const realm = try allocator.dupe(u8, config.realm);
    errdefer allocator.free(realm);

    // Resolve tenant_id.
    const tid_path = try splitPath(allocator, config.tenant_id_claim);
    defer allocator.free(tid_path);
    const tenant_id = if (resolveJsonPath(root, tid_path)) |tv| blk: {
        if (tv != .string) break :blk null;
        break :blk try allocator.dupe(u8, tv.string);
    } else null;
    errdefer if (tenant_id) |v| allocator.free(v);

    // Resolve roles: try each path, take first array.
    var roles_buf: [][]const u8 = &.{};
    errdefer {
        for (roles_buf) |r| allocator.free(r);
        allocator.free(roles_buf);
    }
    for (config.roles_claim_paths) |pstr| {
        const p = try splitPath(allocator, pstr);
        defer allocator.free(p);
        if (resolveJsonPath(root, p)) |v| {
            if (v == .array) {
                const arr = v.array;
                roles_buf = try allocator.alloc([]const u8, arr.items.len);
                for (arr.items, 0..) |item, i| {
                    roles_buf[i] = try allocator.dupe(u8, switch (item) {
                        .string => |s| s,
                        else => "",
                    });
                }
                break;
            }
        }
    }
    const roles: []const []const u8 = roles_buf;

    // Resolve email.
    const ep = try splitPath(allocator, config.email_claim);
    defer allocator.free(ep);
    const email = if (resolveJsonPath(root, ep)) |ev| blk: {
        if (ev != .string) break :blk try allocator.dupe(u8, "");
        break :blk try allocator.dupe(u8, ev.string);
    } else try allocator.dupe(u8, "");

    // Resolve preferred_username; defaults to subject.
    const up = try splitPath(allocator, config.preferred_username_claim);
    defer allocator.free(up);
    const preferred_username = if (resolveJsonPath(root, up)) |uv| blk: {
        if (uv != .string) break :blk try allocator.dupe(u8, subject);
        break :blk try allocator.dupe(u8, uv.string);
    } else try allocator.dupe(u8, subject);

    // Resolve display_name; null when absent.
    const dp = try splitPath(allocator, config.display_name_claim);
    defer allocator.free(dp);
    const display_name = if (resolveJsonPath(root, dp)) |dv| blk: {
        if (dv != .string) break :blk null;
        break :blk try allocator.dupe(u8, dv.string);
    } else null;

    return IdentityContext{
        .external_user_id = external_user_id,
        .tenant_id = tenant_id,
        .realm = realm,
        .roles = roles,
        .email = email,
        .preferred_username = preferred_username,
        .display_name = display_name,
    };
}

// ---------------------------------------------------------------------------
// Identity equivalence
// ---------------------------------------------------------------------------

pub fn identityContextsEquivalent(a: IdentityContext, b: IdentityContext) bool {
    return std.mem.eql(u8, a.external_user_id, b.external_user_id) and
        std.mem.eql(u8, a.realm, b.realm);
}

// ---------------------------------------------------------------------------
// JSON path resolution
// ---------------------------------------------------------------------------

pub fn resolveJsonPath(document: std.json.Value, path: []const []const u8) ?std.json.Value {
    var current = document;
    for (path) |segment| {
        switch (current) {
            .object => |obj| {
                current = obj.get(segment) orelse return null;
            },
            else => return null,
        }
    }
    return current;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn splitPath(allocator: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    if (path.len == 0) return &.{};
    var segments: std.ArrayList([]const u8) = .empty;
    errdefer segments.deinit(allocator);
    var it = std.mem.splitScalar(u8, path, '.');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        try segments.append(allocator, seg);
    }
    return try segments.toOwnedSlice(allocator);
}

fn parsePgTextArray(allocator: std.mem.Allocator, input: []const u8) ClaimMappingError![]const []const u8 {
    if (input.len < 2 or input[0] != '{' or input[input.len - 1] != '}') {
        return error.ConfigParseFailed;
    }
    const inner = input[1 .. input.len - 1];
    if (inner.len == 0) return &.{};
    var items: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (items.items) |item| allocator.free(item);
        items.deinit(allocator);
    }
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |segment| {
        const trimmed = std.mem.trim(u8, segment, " ");
        const dup = try allocator.dupe(u8, trimmed);
        try items.append(allocator, dup);
    }
    return try items.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "resolveJsonPath — simple top-level key" {
    const allocator = std.testing.allocator;
    const json = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"sub": "user123"}
    , .{});
    defer json.deinit();
    const path = try splitPath(allocator, "sub");
    defer allocator.free(path);
    const result = resolveJsonPath(json.value, path);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("user123", result.?.string);
}

test "resolveJsonPath — nested path" {
    const allocator = std.testing.allocator;
    const json = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"realm_access": {"roles": ["admin", "user"]}}
    , .{});
    defer json.deinit();
    const path = try splitPath(allocator, "realm_access.roles");
    defer allocator.free(path);
    const result = resolveJsonPath(json.value, path);
    try std.testing.expect(result != null);
    try std.testing.expect(result.? == .array);
}

test "resolveJsonPath — missing path returns null" {
    const allocator = std.testing.allocator;
    const json = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"sub": "user123"}
    , .{});
    defer json.deinit();
    const path = try splitPath(allocator, "nonexistent.key");
    defer allocator.free(path);
    const result = resolveJsonPath(json.value, path);
    try std.testing.expect(result == null);
}

test "identityContextsEquivalent — same user, different fields" {
    const a = IdentityContext{
        .external_user_id = "user-abc",
        .tenant_id = null,
        .realm = "keycloak",
        .roles = &.{},
        .email = "",
        .preferred_username = "user-abc",
        .display_name = null,
    };
    const b = IdentityContext{
        .external_user_id = "user-abc",
        .tenant_id = "tenant-1",
        .realm = "keycloak",
        .roles = &.{"admin"},
        .email = "user@example.com",
        .preferred_username = "user-abc",
        .display_name = "User",
    };
    try std.testing.expect(identityContextsEquivalent(a, b));
}

test "identityContextsEquivalent — different user, same realm" {
    const a = IdentityContext{
        .external_user_id = "user-abc",
        .tenant_id = null,
        .realm = "keycloak",
        .roles = &.{},
        .email = "",
        .preferred_username = "user-abc",
        .display_name = null,
    };
    const b = IdentityContext{
        .external_user_id = "user-xyz",
        .tenant_id = null,
        .realm = "keycloak",
        .roles = &.{},
        .email = "",
        .preferred_username = "user-xyz",
        .display_name = null,
    };
    try std.testing.expect(!identityContextsEquivalent(a, b));
}

test "mapVerifiedClaims — basic mapping" {
    const allocator = std.testing.allocator;
    const config = ClaimMappingConfig{
        .realm = "keycloak",
        .tenant_id_claim = "tenant_id",
        .roles_claim_paths = &.{"realm_access.roles"},
        .email_claim = "email",
        .preferred_username_claim = "preferred_username",
        .display_name_claim = "name",
    };
    const raw_json = 
        \\{"sub": "user-123", "email": "user@example.com", "preferred_username": "jdoe", "name": "John Doe"}
    ;
    var ctx = try mapVerifiedClaims(allocator, config, "user-123", raw_json);
    defer ctx.deinit(allocator);
    try std.testing.expectEqualStrings("user-123", ctx.external_user_id);
    try std.testing.expectEqualStrings("keycloak", ctx.realm);
    try std.testing.expect(ctx.tenant_id == null);
    try std.testing.expectEqualStrings("user@example.com", ctx.email);
    try std.testing.expectEqualStrings("jdoe", ctx.preferred_username);
    try std.testing.expectEqualStrings("John Doe", ctx.display_name.?);
    try std.testing.expectEqual(@as(usize, 0), ctx.roles.len);
}

test "mapVerifiedClaims — sub claim missing" {
    const allocator = std.testing.allocator;
    const config = DEFAULT_CLAIM_MAPPING_CONFIG;
    const result = mapVerifiedClaims(allocator, config, "", "{}");
    try std.testing.expectError(error.SubClaimMissing, result);
}

test "mapVerifiedClaims — roles from nested claim" {
    const allocator = std.testing.allocator;
    const config = ClaimMappingConfig{
        .realm = "keycloak",
        .tenant_id_claim = "tenant_id",
        .roles_claim_paths = &.{"realm_access.roles"},
        .email_claim = "email",
        .preferred_username_claim = "preferred_username",
        .display_name_claim = "name",
    };
    const raw_json = 
        \\{"sub": "user-456", "realm_access": {"roles": ["admin", "user"]}}
    ;
    var ctx = try mapVerifiedClaims(allocator, config, "user-456", raw_json);
    defer ctx.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), ctx.roles.len);
    try std.testing.expectEqualStrings("admin", ctx.roles[0]);
    try std.testing.expectEqualStrings("user", ctx.roles[1]);
}

test "mapVerifiedClaims — missing email defaults to empty string" {
    const allocator = std.testing.allocator;
    const config = DEFAULT_CLAIM_MAPPING_CONFIG;
    const raw_json = 
        \\{"sub": "user-789"}
    ;
    var ctx = try mapVerifiedClaims(allocator, config, "user-789", raw_json);
    defer ctx.deinit(allocator);
    try std.testing.expectEqualStrings("", ctx.email);
    try std.testing.expectEqualStrings("user-789", ctx.preferred_username);
    try std.testing.expect(ctx.display_name == null);
    try std.testing.expectEqual(@as(usize, 0), ctx.roles.len);
}

test "parsePgTextArray — simple elements" {
    const allocator = std.testing.allocator;
    const result = try parsePgTextArray(allocator, "{realm_access.roles,roles}");
    defer {
        for (result) |item| allocator.free(item);
        allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("realm_access.roles", result[0]);
    try std.testing.expectEqualStrings("roles", result[1]);
}

test "parsePgTextArray — empty array" {
    const allocator = std.testing.allocator;
    const result = try parsePgTextArray(allocator, "{}");
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}
