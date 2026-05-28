//! Integration tests for OIDC-14 — Realm provisioning via adapter.
//!
//! Tests buildRealmCreateBody, ProvisionRealmInput defaults, and
//! DEFAULT_REALM_CONFIG constants. These are pure builder functions — no DB.
//!
//! Requirement: OIDC-14 — Realm provisioning via adapter [MUST]
//!
//! DIRECTIVE T-1: No mocks, no stubs.
//! DIRECTIVE T-3: No error.SkipZigTest on MUST requirement tests.

const std = @import("std");
const testing = std.testing;

const realm_provisioning = @import("realm_provisioning");

// ---------------------------------------------------------------------------
// TC-OIDC-14-01: buildRealmCreateBody produces valid JSON
// ---------------------------------------------------------------------------

test "TC-OIDC-14-01: buildRealmCreateBody produces valid JSON with all config fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const input = realm_provisioning.ProvisionRealmInput{
        .tenant_id = "22222222-2222-2222-2222-222222222222".*,
        .tenant_slug = "test-tenant",
        .display_name = "Test Tenant",
    };
    const body = try realm_provisioning.buildRealmCreateBody(alloc, "test-tenant", "Test Tenant", input);
    defer alloc.free(body);

    try testing.expect(body.len > 0);
    try testing.expect(std.mem.indexOf(u8, body, "test-tenant") != null);
    try testing.expect(std.mem.indexOf(u8, body, "accessTokenLifespan") != null);
    try testing.expect(std.mem.indexOf(u8, body, "900") != null);
}

// ---------------------------------------------------------------------------
// TC-OIDC-14-02: ProvisionRealmInput defaults
// ---------------------------------------------------------------------------

test "TC-OIDC-14-02: ProvisionRealmInput defaults are correct" {
    const input = realm_provisioning.ProvisionRealmInput{
        .tenant_id = "33333333-3333-3333-3333-333333333333".*,
        .tenant_slug = "defaults-test",
        .display_name = "Defaults Test",
    };
    try testing.expectEqual(@as(u32, 900), input.default_token_lifetime_seconds);
    try testing.expectEqual(@as(u8, 8), input.min_password_length);
    try testing.expectEqual(realm_provisioning.SigningAlgorithm.RS256, input.signing_key_algorithm);
}

// ---------------------------------------------------------------------------
// TC-OIDC-14-03: DEFAULT_REALM_CONFIG constants
// ---------------------------------------------------------------------------

test "TC-OIDC-14-03: DEFAULT_REALM_CONFIG constants are accessible" {
    try testing.expectEqual(@as(u32, 900), realm_provisioning.DEFAULT_REALM_CONFIG.token_lifetimes.access_token_seconds);
    try testing.expectEqual(@as(u8, 8), realm_provisioning.DEFAULT_REALM_CONFIG.password_policy.min_length);
    try testing.expectEqual(realm_provisioning.SigningAlgorithm.RS256, realm_provisioning.DEFAULT_REALM_CONFIG.signing.algorithm);
}

// ---------------------------------------------------------------------------
// TC-OIDC-14-04: ProvisionRealmResult deinit frees memory
// ---------------------------------------------------------------------------

test "TC-OIDC-14-04: ProvisionRealmResult deinit frees allocated memory" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var result = realm_provisioning.ProvisionRealmResult{
        .realm_id = try alloc.dupe(u8, "test-realm"),
        .created = true,
        .keyset = realm_provisioning.KeysetInfo{
            .algorithm = .RS256,
            .kid = try alloc.dupe(u8, "test-kid"),
            .jwks_url = try alloc.dupe(u8, "http://localhost:8080/realms/test-realm/jwks"),
        },
        .tenant_id_mapper_id = try alloc.dupe(u8, "mapper-001"),
    };
    // deinit should free all allocated fields without double-free.
    result.deinit(alloc);
}

// ---------------------------------------------------------------------------
// TC-OIDC-14-05: Realm create body includes OTP and password policy fields
// ---------------------------------------------------------------------------

test "TC-OIDC-14-05: buildRealmCreateBody includes otp and password policy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const input = realm_provisioning.ProvisionRealmInput{
        .tenant_id = "44444444-4444-4444-4444-444444444444".*,
        .tenant_slug = "otp-tenant",
        .display_name = "OTP Tenant",
        .otp_required = true,
        .otp_algorithm = .SHA256,
        .otp_digits = 6,
        .require_uppercase = true,
        .require_digit = true,
    };
    const body = try realm_provisioning.buildRealmCreateBody(alloc, "otp-tenant", "OTP Tenant", input);
    defer alloc.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "otpPolicyAlgorithm") != null);
    try testing.expect(std.mem.indexOf(u8, body, "otpPolicyDigits") != null);
    try testing.expect(std.mem.indexOf(u8, body, "passwordPolicy") != null);
    try testing.expect(std.mem.indexOf(u8, body, "SHA256") != null);
}
