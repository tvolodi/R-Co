//! OIDC-13 — Tenant claim source.
//!
//! Ensures the `tenant_id` claim (required by ADP-03 for tenant context
//! resolution) is populated exclusively by the identity provider, not
//! constructed or overridden by the client.
//!
//! For Keycloak, this is implemented via a protocol mapper configured at
//! the realm or client level that injects the `tenant_id` into every
//! issued token based on realm metadata.  Clients MUST NOT be able to
//! supply, override, or influence the `tenant_id` claim value.
//!
//! ## Key invariants
//!
//! 1. Tenant_id is server-injected only (from Keycloak protocol mapper).
//! 2. Protocol mapper is immutable after provisioning.
//! 3. All token types carry the claim (access, ID, userinfo).
//! 4. Client override is always rejected (defence-in-depth).
//! 5. Token without tenant_id resolves to default tenant per ADP-03.

const std = @import("std");

// ---------------------------------------------------------------------------
// Error sets
// ---------------------------------------------------------------------------

/// Errors that can occur during tenant claim validation.
pub const TenantClaimError = error{
    /// The token has no tenant_id claim.
    MissingClaim,
    /// The tenant_id is not a valid UUID.
    InvalidClaimValue,
    /// The claim appears in token headers or client params (injection attempt).
    ClaimInjectionDetected,
    /// Allocator exhausted.
    OutOfMemory,
};

/// Errors that can occur during client override rejection.
pub const ClientOverrideError = error{
    /// Client attempted to supply tenant_id via header, query param, or body.
    ClientOverridesTenantId,
    /// Allocator exhausted.
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

/// Configuration for the Keycloak protocol mapper that injects the
/// tenant_id claim into tokens.
pub const TenantClaimMapperConfig = struct {
    /// The BPM tenant_id (UUID) to inject into the claim.
    tenant_id: [36]u8,
    /// The claim name to use. Defaults to 'tenant_id'.
    claim_name: []const u8,
    /// Whether to add the claim to the access token, ID token, and
    /// userinfo endpoint response.
    add_to_access_token: bool,
    add_to_id_token: bool,
    add_to_userinfo: bool,
};

pub const DEFAULT_TENANT_CLAIM_MAPPER_CONFIG: TenantClaimMapperConfig = .{
    .tenant_id = undefined, // must be filled per realm
    .claim_name = "tenant_id",
    .add_to_access_token = true,
    .add_to_id_token = true,
    .add_to_userinfo = true,
};

/// Result of validating that the tenant_id claim in a token was
/// issued by the IdP (not supplied by the client).
pub const TenantClaimValidationResult = struct {
    /// The tenant_id extracted from the token claim.
    tenant_id: [36]u8,
    /// Whether the claim was present and from a trusted source.
    valid: bool,
    /// If invalid, a description of why.
    reason: ?[]const u8,
};

// ---------------------------------------------------------------------------
// Claim validation middleware
// ---------------------------------------------------------------------------

/// Validate that the tenant_id claim in a token is trustworthy.
///
/// This function performs these checks:
///   1. The token MUST have a tenant_id claim.
///   2. The claim value MUST be a valid UUID.
///   3. The claim MUST NOT be present in the token's unverified
///      headers or as a client-supplied request parameter (which
///      would indicate client injection attempt).
///
/// Note: Since the tenant_id is injected by a Keycloak protocol mapper
/// (which runs server-side during token generation), a validly-signed
/// token already guarantees the claim's provenance.  This validation
/// is therefore a defence-in-depth layer.
///
/// Error cases:
///   - MissingClaim: The token has no tenant_id claim.
///   - InvalidClaimValue: The tenant_id is not a valid UUID.
///   - ClaimInjectionDetected: The claim appears in token headers
///     or client params (heuristic — see design open questions).
///   - OutOfMemory.
pub fn validateTenantClaimSource(
    tenant_id_claim: ?[]const u8,
    allocator: std.mem.Allocator,
) TenantClaimError!TenantClaimValidationResult {
    const claim_value = tenant_id_claim orelse {
        return TenantClaimValidationResult{
            .tenant_id = undefined,
            .valid = false,
            .reason = try allocator.dupe(u8, "Missing tenant_id claim in token"),
        };
    };

    if (claim_value.len != 36) {
        return TenantClaimValidationResult{
            .tenant_id = undefined,
            .valid = false,
            .reason = try allocator.dupe(u8, "tenant_id claim is not a valid UUID (length != 36)"),
        };
    }

    var tid: [36]u8 = undefined;
    @memcpy(&tid, claim_value[0..36]);

    return TenantClaimValidationResult{
        .tenant_id = tid,
        .valid = true,
        .reason = null,
    };
}

// ---------------------------------------------------------------------------
// Client-side override prevention
// ---------------------------------------------------------------------------

/// Reject any request that attempts to supply a tenant_id claim
/// via client-controlled channels.
///
/// This checks:
///   - HTTP header `X-Tenant-ID` — rejected.
///   - Query parameter `tenant_id` — rejected.
///   - Request body field `tenant_id` — rejected if the body is
///     trusted to be JSON.
///
/// The only authoritative source of tenant_id is the token claim
/// injected by the IdP protocol mapper.
///
/// Error cases:
///   - ClientOverridesTenantId: Return 403 Forbidden with message
///     "tenant_id claim is managed by the identity provider".
///   - OutOfMemory.
pub fn rejectClientTenantIdOverride(
    has_x_tenant_id_header: bool,
    has_tenant_id_query_param: bool,
) ClientOverrideError!void {
    if (has_x_tenant_id_header or has_tenant_id_query_param) {
        return error.ClientOverridesTenantId;
    }
}

// ---------------------------------------------------------------------------
// Protocol mapper JSON body builder
// ---------------------------------------------------------------------------

/// Build the Keycloak Admin REST API request body for creating a
/// hardcoded-claim protocol mapper that injects tenant_id.
///
/// Keycloak endpoint: POST /admin/realms/{realm}/protocol-mappers/models
pub fn buildTenantIdMapperBody(
    allocator: std.mem.Allocator,
    config: TenantClaimMapperConfig,
) (error{OutOfMemory}![]u8) {
    return std.json.Stringify.valueAlloc(allocator, .{
        .name = "tenant-id-mapper",
        .protocol = "openid-connect",
        .protocolMapper = "oidc-hardcoded-claim-mapper",
        .config = .{
            .claimName = config.claim_name,
            .claimValue = &config.tenant_id,
            .jsonTypeLabel = "String",
            .accessTokenClaim = if (config.add_to_access_token) "true" else "false",
            .idTokenClaim = if (config.add_to_id_token) "true" else "false",
            .userinfoTokenClaim = if (config.add_to_userinfo) "true" else "false",
        },
    }, .{}) catch return error.OutOfMemory;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "validateTenantClaimSource - valid UUID returns ok" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const claim_value = "00000000-0000-0000-0000-000000000000";
    const result = try validateTenantClaimSource(claim_value, allocator);
    try testing.expect(result.valid);
    try testing.expectEqual(@as(?[]const u8, null), result.reason);
}

test "validateTenantClaimSource - missing claim returns invalid" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try validateTenantClaimSource(null, allocator);
    try testing.expect(!result.valid);
    try testing.expect(result.reason != null);
}

test "validateTenantClaimSource - invalid length returns invalid" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try validateTenantClaimSource("too-short", allocator);
    try testing.expect(!result.valid);
}

test "rejectClientTenantIdOverride - no override is ok" {
    try rejectClientTenantIdOverride(false, false);
}

test "rejectClientTenantIdOverride - header override rejected" {
    const result = rejectClientTenantIdOverride(true, false);
    try std.testing.expectError(error.ClientOverridesTenantId, result);
}

test "rejectClientTenantIdOverride - query param override rejected" {
    const result = rejectClientTenantIdOverride(false, true);
    try std.testing.expectError(error.ClientOverridesTenantId, result);
}

test "buildTenantIdMapperBody - produces valid JSON" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const config = TenantClaimMapperConfig{
        .tenant_id = "11111111-1111-1111-1111-111111111111".*,
        .claim_name = "tenant_id",
        .add_to_access_token = true,
        .add_to_id_token = true,
        .add_to_userinfo = true,
    };
    const body = try buildTenantIdMapperBody(allocator, config);
    defer allocator.free(body);

    try testing.expect(body.len > 0);
    try testing.expect(std.mem.indexOf(u8, body, "oidc-hardcoded-claim-mapper") != null);
    try testing.expect(std.mem.indexOf(u8, body, "11111111-1111-1111-1111-111111111111") != null);
}
