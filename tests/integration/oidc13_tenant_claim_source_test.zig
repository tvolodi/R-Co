//! Integration tests for OIDC-13 — Tenant claim source.
//!
//! Tests validateTenantClaimSource, rejectClientTenantIdOverride, and
//! buildTenantIdMapperBody. These are pure functions — no DB needed.
//!
//! Requirement: OIDC-13 — Tenant claim source [MUST]
//!
//! DIRECTIVE T-1: No mocks, no stubs.
//! DIRECTIVE T-3: No error.SkipZigTest on MUST requirement tests.

const std = @import("std");
const testing = std.testing;

const tenant_claim_source = @import("tenant_claim_source");

// ---------------------------------------------------------------------------
// TC-OIDC-13-01: validateTenantClaimSource returns valid for well-formed UUID
// ---------------------------------------------------------------------------

test "TC-OIDC-13-01: validateTenantClaimSource valid UUID" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const claim_value = "00000000-0000-0000-0000-000000000000";
    const result = try tenant_claim_source.validateTenantClaimSource(claim_value, alloc);
    try testing.expect(result.valid);
    try testing.expectEqual(@as(?[]const u8, null), result.reason);
}

// ---------------------------------------------------------------------------
// TC-OIDC-13-02: validateTenantClaimSource returns invalid for missing claim
// ---------------------------------------------------------------------------

test "TC-OIDC-13-02: validateTenantClaimSource missing claim" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try tenant_claim_source.validateTenantClaimSource(null, alloc);
    try testing.expect(!result.valid);
    try testing.expect(result.reason != null);
}

// ---------------------------------------------------------------------------
// TC-OIDC-13-03: validateTenantClaimSource returns invalid for short value
// ---------------------------------------------------------------------------

test "TC-OIDC-13-03: validateTenantClaimSource invalid length" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try tenant_claim_source.validateTenantClaimSource("too-short", alloc);
    try testing.expect(!result.valid);
}

// ---------------------------------------------------------------------------
// TC-OIDC-13-04: rejectClientTenantIdOverride passes
// ---------------------------------------------------------------------------

test "TC-OIDC-13-04: rejectClientTenantIdOverride no override" {
    try tenant_claim_source.rejectClientTenantIdOverride(false, false);
}

// ---------------------------------------------------------------------------
// TC-OIDC-13-05: rejectClientTenantIdOverride rejects header
// ---------------------------------------------------------------------------

test "TC-OIDC-13-05: rejectClientTenantIdOverride header rejected" {
    const result = tenant_claim_source.rejectClientTenantIdOverride(true, false);
    try testing.expectError(error.ClientOverridesTenantId, result);
}

// ---------------------------------------------------------------------------
// TC-OIDC-13-06: rejectClientTenantIdOverride rejects query param
// ---------------------------------------------------------------------------

test "TC-OIDC-13-06: rejectClientTenantIdOverride query param rejected" {
    const result = tenant_claim_source.rejectClientTenantIdOverride(false, true);
    try testing.expectError(error.ClientOverridesTenantId, result);
}

// ---------------------------------------------------------------------------
// TC-OIDC-13-07: buildTenantIdMapperBody produces valid JSON
// ---------------------------------------------------------------------------

test "TC-OIDC-13-07: buildTenantIdMapperBody produces valid Keycloak JSON" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const config = tenant_claim_source.TenantClaimMapperConfig{
        .tenant_id = "11111111-1111-1111-1111-111111111111".*,
        .claim_name = "tenant_id",
        .add_to_access_token = true,
        .add_to_id_token = true,
        .add_to_userinfo = true,
    };
    const body = try tenant_claim_source.buildTenantIdMapperBody(alloc, config);
    defer alloc.free(body);

    try testing.expect(body.len > 0);
    try testing.expect(std.mem.indexOf(u8, body, "oidc-hardcoded-claim-mapper") != null);
// GH-512 retention: doc-identity fixture (matched against substring assertions in payload/correlation_id checks)
    try testing.expect(std.mem.indexOf(u8, body, "11111111-1111-1111-1111-111111111111") != null);
}
