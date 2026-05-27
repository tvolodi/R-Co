//! OIDC-08 — Standard claim mapping unit tests.
//!
//! Tests for the pure functions in src/oidc/claim_mapping.zig:
//!   - mapVerifiedClaims (all default variants, edge cases, type mismatches)
//!   - identityContextsEquivalent (equivalence by (external_user_id, realm))
//!   - resolveJsonPath (dot-separated path resolution)
//!
//! These tests are pure function tests — no database, no network.

const std = @import("std");
const testing = std.testing;
const cm = @import("claim_mapping");

const IdentityContext = cm.IdentityContext;
const ClaimMappingConfig = cm.ClaimMappingConfig;
const DEFAULT_CLAIM_MAPPING_CONFIG = cm.DEFAULT_CLAIM_MAPPING_CONFIG;

// ---------------------------------------------------------------------------
// TC-OIDC-08-U01: Basic mapping with all standard claims present
// ---------------------------------------------------------------------------

test "TC-OIDC-08-U01: basic mapping with all standard claims present" {
    const alloc = testing.allocator;
    const config = ClaimMappingConfig{
        .realm = "keycloak",
        .tenant_id_claim = "tenant_id",
        .roles_claim_paths = &.{"realm_access.roles"},
        .email_claim = "email",
        .preferred_username_claim = "preferred_username",
        .display_name_claim = "name",
    };
    const raw_json =
        \\{"sub": "user-001", "email": "alice@example.com", "preferred_username": "alice",
        \\ "name": "Alice Smith", "tenant_id": "tenant-alpha",
        \\ "realm_access": {"roles": ["admin", "operator"]}}
    ;
    var ctx = try cm.mapVerifiedClaims(alloc, config, "user-001", raw_json);
    defer ctx.deinit(alloc);
    try testing.expectEqualStrings("user-001", ctx.external_user_id);
    try testing.expectEqualStrings("keycloak", ctx.realm);
    try testing.expectEqualStrings("tenant-alpha", ctx.tenant_id.?);
    try testing.expectEqualStrings("alice@example.com", ctx.email);
    try testing.expectEqualStrings("alice", ctx.preferred_username);
    try testing.expectEqualStrings("Alice Smith", ctx.display_name.?);
    try testing.expectEqual(@as(usize, 2), ctx.roles.len);
    try testing.expectEqualStrings("admin", ctx.roles[0]);
    try testing.expectEqualStrings("operator", ctx.roles[1]);
}

// ---------------------------------------------------------------------------
// TC-OIDC-08-U02: Sub claim missing returns error
// ---------------------------------------------------------------------------

test "TC-OIDC-08-U02: sub claim missing returns error" {
    const alloc = testing.allocator;
    const result = cm.mapVerifiedClaims(alloc, DEFAULT_CLAIM_MAPPING_CONFIG, "", "{}");
    try testing.expectError(error.SubClaimMissing, result);
}

// ---------------------------------------------------------------------------
// TC-OIDC-08-U03: Missing email defaults to empty string
// ---------------------------------------------------------------------------

test "TC-OIDC-08-U03: missing email defaults to empty string" {
    const alloc = testing.allocator;
    const raw_json = \\{"sub": "user-002"}
    ;
    var ctx = try cm.mapVerifiedClaims(alloc, DEFAULT_CLAIM_MAPPING_CONFIG, "user-002", raw_json);
    defer ctx.deinit(alloc);
    try testing.expectEqualStrings("", ctx.email);
}

// ---------------------------------------------------------------------------
// TC-OIDC-08-U04: Missing preferred_username defaults to sub value
// ---------------------------------------------------------------------------

test "TC-OIDC-08-U04: missing preferred_username defaults to sub value" {
    const alloc = testing.allocator;
    const raw_json = \\{"sub": "user-003"}
    ;
    var ctx = try cm.mapVerifiedClaims(alloc, DEFAULT_CLAIM_MAPPING_CONFIG, "user-003", raw_json);
    defer ctx.deinit(alloc);
    try testing.expectEqualStrings("user-003", ctx.preferred_username);
}

// ---------------------------------------------------------------------------
// TC-OIDC-08-U05: Missing roles defaults to empty list
// ---------------------------------------------------------------------------

test "TC-OIDC-08-U05: missing roles defaults to empty list" {
    const alloc = testing.allocator;
    const raw_json = \\{"sub": "user-004"}
    ;
    var ctx = try cm.mapVerifiedClaims(alloc, DEFAULT_CLAIM_MAPPING_CONFIG, "user-004", raw_json);
    defer ctx.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), ctx.roles.len);
}

// ---------------------------------------------------------------------------
// TC-OIDC-08-U06: Missing display_name defaults to null
// ---------------------------------------------------------------------------

test "TC-OIDC-08-U06: missing display_name defaults to null" {
    const alloc = testing.allocator;
    const raw_json = \\{"sub": "user-005"}
    ;
    var ctx = try cm.mapVerifiedClaims(alloc, DEFAULT_CLAIM_MAPPING_CONFIG, "user-005", raw_json);
    defer ctx.deinit(alloc);
    try testing.expect(ctx.display_name == null);
}

// ---------------------------------------------------------------------------
// TC-OIDC-08-U07: Missing tenant_id defaults to null
// ---------------------------------------------------------------------------

test "TC-OIDC-08-U07: missing tenant_id defaults to null" {
    const alloc = testing.allocator;
    const raw_json = \\{"sub": "user-006"}
    ;
    var ctx = try cm.mapVerifiedClaims(alloc, DEFAULT_CLAIM_MAPPING_CONFIG, "user-006", raw_json);
    defer ctx.deinit(alloc);
    try testing.expect(ctx.tenant_id == null);
}

// ---------------------------------------------------------------------------
// TC-OIDC-08-U08: Nested role path resolved from realm_access.roles
// ---------------------------------------------------------------------------

test "TC-OIDC-08-U08: roles from nested realm_access.roles path" {
    const alloc = testing.allocator;
    const config = ClaimMappingConfig{
        .realm = "keycloak",
        .tenant_id_claim = "tenant_id",
        .roles_claim_paths = &.{"realm_access.roles"},
        .email_claim = "email",
        .preferred_username_claim = "preferred_username",
        .display_name_claim = "name",
    };
    const raw_json =
        \\{"sub": "user-007", "realm_access": {"roles": ["admin", "user", "viewer"]}}
    ;
    var ctx = try cm.mapVerifiedClaims(alloc, config, "user-007", raw_json);
    defer ctx.deinit(alloc);
    try testing.expectEqual(@as(usize, 3), ctx.roles.len);
    try testing.expectEqualStrings("admin", ctx.roles[0]);
    try testing.expectEqualStrings("user", ctx.roles[1]);
    try testing.expectEqualStrings("viewer", ctx.roles[2]);
}

// ---------------------------------------------------------------------------
// TC-OIDC-08-U09: Role path fallback — first path missing, second used
// ---------------------------------------------------------------------------

test "TC-OIDC-08-U09: roles path fallback when first path missing" {
    const alloc = testing.allocator;
    const config = ClaimMappingConfig{
        .realm = "keycloak",
        .tenant_id_claim = "tenant_id",
        .roles_claim_paths = &.{ "realm_access.roles", "roles" },
        .email_claim = "email",
        .preferred_username_claim = "preferred_username",
        .display_name_claim = "name",
    };
    // Only top-level "roles", no "realm_access"
    const raw_json =
        \\{"sub": "user-008", "roles": ["fallback-role"]}
    ;
    var ctx = try cm.mapVerifiedClaims(alloc, config, "user-008", raw_json);
    defer ctx.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), ctx.roles.len);
    try testing.expectEqualStrings("fallback-role", ctx.roles[0]);
}

// ---------------------------------------------------------------------------
// TC-OIDC-08-U10: Claim not a string — email non-string defaults to empty
// ---------------------------------------------------------------------------

test "TC-OIDC-08-U10: email non-string defaults to empty string" {
    const alloc = testing.allocator;
    const raw_json =
        \\{"sub": "user-009", "email": 42}
    ;
    var ctx = try cm.mapVerifiedClaims(alloc, DEFAULT_CLAIM_MAPPING_CONFIG, "user-009", raw_json);
    defer ctx.deinit(alloc);
    try testing.expectEqualStrings("", ctx.email);
}

// ---------------------------------------------------------------------------
// TC-OIDC-08-U11: Claim not a string — preferred_username non-string defaults to sub
// ---------------------------------------------------------------------------

test "TC-OIDC-08-U11: preferred_username non-string defaults to sub" {
    const alloc = testing.allocator;
    const raw_json =
        \\{"sub": "user-010", "preferred_username": false}
    ;
    var ctx = try cm.mapVerifiedClaims(alloc, DEFAULT_CLAIM_MAPPING_CONFIG, "user-010", raw_json);
    defer ctx.deinit(alloc);
    try testing.expectEqualStrings("user-010", ctx.preferred_username);
}

// ---------------------------------------------------------------------------
// TC-OIDC-08-U12: Claim not a string — display_name non-string defaults to null
// ---------------------------------------------------------------------------

test "TC-OIDC-08-U12: display_name non-string defaults to null" {
    const alloc = testing.allocator;
    const raw_json =
        \\{"sub": "user-011", "name": ["not", "a", "string"]}
    ;
    var ctx = try cm.mapVerifiedClaims(alloc, DEFAULT_CLAIM_MAPPING_CONFIG, "user-011", raw_json);
    defer ctx.deinit(alloc);
    try testing.expect(ctx.display_name == null);
}

// ---------------------------------------------------------------------------
// TC-OIDC-08-U13: identityContextsEquivalent — same user, different fields
// ---------------------------------------------------------------------------

test "TC-OIDC-08-U13: identityContextsEquivalent same (external_user_id, realm)" {
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
    try testing.expect(cm.identityContextsEquivalent(a, b));
}

// ---------------------------------------------------------------------------
// TC-OIDC-08-U14: identityContextsEquivalent — different external_user_id
// ---------------------------------------------------------------------------

test "TC-OIDC-08-U14: identityContextsEquivalent different external_user_id" {
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
    try testing.expect(!cm.identityContextsEquivalent(a, b));
}

// ---------------------------------------------------------------------------
// TC-OIDC-08-U15: identityContextsEquivalent — different realm
// ---------------------------------------------------------------------------

test "TC-OIDC-08-U15: identityContextsEquivalent different realm" {
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
        .tenant_id = null,
        .realm = "okta",
        .roles = &.{},
        .email = "",
        .preferred_username = "user-abc",
        .display_name = null,
    };
    try testing.expect(!cm.identityContextsEquivalent(a, b));
}

// ---------------------------------------------------------------------------
// TC-OIDC-08-U16: resolveJsonPath — nested dot-separated path
// ---------------------------------------------------------------------------

test "TC-OIDC-08-U16: resolveJsonPath nested path returns value" {
    const alloc = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"a": {"b": {"c": "deep-value"}}}
    , .{});
    defer parsed.deinit();
    const path = [_][]const u8{"a", "b", "c"};
    const result = cm.resolveJsonPath(parsed.value, &path);
    try testing.expect(result != null);
    try testing.expectEqualStrings("deep-value", result.?.string);
}

// ---------------------------------------------------------------------------
// TC-OIDC-08-U17: resolveJsonPath — nonexistent path returns null
// ---------------------------------------------------------------------------

test "TC-OIDC-08-U17: resolveJsonPath nonexistent path returns null" {
    const alloc = testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"sub": "user"}
    , .{});
    defer parsed.deinit();
    const path = [_][]const u8{"nonexistent"};
    const result = cm.resolveJsonPath(parsed.value, &path);
    try testing.expect(result == null);
}

// ---------------------------------------------------------------------------
// TC-OIDC-08-U18: Non-JSON input returns ClaimPathMalformed error
// ---------------------------------------------------------------------------

test "TC-OIDC-08-U18: non-JSON input returns ClaimPathMalformed" {
    const alloc = testing.allocator;
    const result = cm.mapVerifiedClaims(alloc, DEFAULT_CLAIM_MAPPING_CONFIG, "user-012", "not valid json");
    try testing.expectError(error.ClaimPathMalformed, result);
}

// ---------------------------------------------------------------------------
// TC-OIDC-08-U19: Tenant_id claim from configured path
// ---------------------------------------------------------------------------

test "TC-OIDC-08-U19: tenant_id extracted from configured path" {
    const alloc = testing.allocator;
    const config = ClaimMappingConfig{
        .realm = "keycloak",
        .tenant_id_claim = "tenant_id",
        .roles_claim_paths = &.{"realm_access.roles"},
        .email_claim = "email",
        .preferred_username_claim = "preferred_username",
        .display_name_claim = "name",
    };
    const raw_json =
        \\{"sub": "user-013", "tenant_id": "custom-tenant"}
    ;
    var ctx = try cm.mapVerifiedClaims(alloc, config, "user-013", raw_json);
    defer ctx.deinit(alloc);
    try testing.expectEqualStrings("custom-tenant", ctx.tenant_id.?);
}

// ---------------------------------------------------------------------------
// Edge case: all optional claims missing simultaneously
// ---------------------------------------------------------------------------

test "TC-OIDC-08-U20: all optional claims missing simultaneously" {
    const alloc = testing.allocator;
    // Only sub present — everything else should get defaults
    const raw_json = \\{"sub": "bare-minimum"}
    ;
    var ctx = try cm.mapVerifiedClaims(alloc, DEFAULT_CLAIM_MAPPING_CONFIG, "bare-minimum", raw_json);
    defer ctx.deinit(alloc);
    try testing.expectEqualStrings("bare-minimum", ctx.external_user_id);
    try testing.expect(ctx.tenant_id == null);
    try testing.expectEqualStrings("", ctx.email);
    try testing.expectEqualStrings("bare-minimum", ctx.preferred_username);
    try testing.expect(ctx.display_name == null);
    try testing.expectEqual(@as(usize, 0), ctx.roles.len);
}
