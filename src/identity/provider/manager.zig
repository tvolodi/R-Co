const std = @import("std");
const interface = @import("interface.zig");
const types = @import("types.zig");
const errors = @import("errors.zig");

pub const AuthMode = enum {
    local_only,
    dual_accept,
    oidc_only,
};

pub const Manager = struct {
    provider: ?interface.IdentityProvider = null,
    auth_mode: AuthMode = .dual_accept,
    expected_audience: []const u8 = "",
    expected_issuer: ?[]const u8 = null,

    pub fn shouldVerifyExternalToken(self: Manager, raw_token: []const u8) bool {
        if (self.provider == null) return false;
        if (self.auth_mode == .local_only) return false;
        return looksLikeJwt(raw_token);
    }

    pub fn verifyBearerToken(self: Manager, allocator: std.mem.Allocator, raw_token: []const u8) errors.ProviderError!types.VerifiedPrincipal {
        const provider = self.provider orelse return error.NotImplemented;
        return provider.verifyToken(allocator, .{
            .raw_token = raw_token,
            .expected_audience = self.expected_audience,
            .expected_issuer = self.expected_issuer,
            .now_unix_seconds = 0,
        });
    }

    /// Verify a bearer token against an explicit expected issuer.
    /// Used by the multi-realm tenant fallback path (ISS-UAT-V6-002):
    /// after confirming the issuer matches a registered tenant realm via the
    /// database, this method re-verifies the token's signature with the
    /// tenant-specific issuer URL so all other JWT claims are still validated.
    pub fn verifyBearerTokenWithIssuer(self: Manager, allocator: std.mem.Allocator, raw_token: []const u8, expected_issuer: []const u8) errors.ProviderError!types.VerifiedPrincipal {
        const provider = self.provider orelse return error.NotImplemented;
        return provider.verifyToken(allocator, .{
            .raw_token = raw_token,
            .expected_audience = self.expected_audience,
            .expected_issuer = expected_issuer,
            .now_unix_seconds = 0,
        });
    }

    pub fn lookupUser(self: Manager, allocator: std.mem.Allocator, input: types.LookupUserInput) errors.ProviderError!?types.ProviderUser {
        const provider = self.provider orelse return error.NotImplemented;
        return provider.lookupUser(allocator, input);
    }

    pub fn provisionRealm(self: Manager, allocator: std.mem.Allocator, input: types.ProvisionRealmInput) errors.ProviderError!types.ProvisionRealmResult {
        const provider = self.provider orelse return error.NotImplemented;
        return provider.provisionRealm(allocator, input);
    }

    pub fn provisionUser(self: Manager, allocator: std.mem.Allocator, input: types.ProvisionUserInput) errors.ProviderError!types.ProvisionUserResult {
        const provider = self.provider orelse return error.NotImplemented;
        return provider.provisionUser(allocator, input);
    }

    pub fn grantRoles(self: Manager, allocator: std.mem.Allocator, input: types.GrantRolesInput) errors.ProviderError!types.GrantRolesResult {
        const provider = self.provider orelse return error.NotImplemented;
        return provider.grantRoles(allocator, input);
    }

    pub fn provisionClient(self: Manager, allocator: std.mem.Allocator, input: types.ProvisionClientInput) errors.ProviderError!types.ProvisionClientResult {
        const provider = self.provider orelse return error.NotImplemented;
        return provider.provisionClient(allocator, input);
    }

    pub fn upsertFederation(self: Manager, allocator: std.mem.Allocator, input: types.UpsertFederationInput) errors.ProviderError!types.FederationResult {
        const provider = self.provider orelse return error.NotImplemented;
        return provider.upsertFederation(allocator, input);
    }

    pub fn deleteFederation(self: Manager, allocator: std.mem.Allocator, input: types.DeleteFederationInput) errors.ProviderError!void {
        const provider = self.provider orelse return error.NotImplemented;
        return provider.deleteFederation(allocator, input);
    }

    pub fn listAuditEvents(self: Manager, allocator: std.mem.Allocator, input: types.ListAuditEventsInput) errors.ProviderError!types.AuditEventPage {
        const provider = self.provider orelse return error.NotImplemented;
        return provider.listAuditEvents(allocator, input);
    }

    // --- OIDC-13 ---
    pub fn createProtocolMapper(self: Manager, allocator: std.mem.Allocator, input: types.CreateProtocolMapperInput) errors.ProviderError!types.CreateProtocolMapperResult {
        const provider = self.provider orelse return error.NotImplemented;
        return provider.createProtocolMapper(allocator, input);
    }

    // --- OIDC-15 ---
    pub fn toggleRealm(self: Manager, allocator: std.mem.Allocator, input: types.ToggleRealmInput) errors.ProviderError!types.RealmLifecycleResult {
        const provider = self.provider orelse return error.NotImplemented;
        return provider.toggleRealm(allocator, input);
    }

    pub fn deleteRealm(self: Manager, allocator: std.mem.Allocator, input: types.DeleteRealmInput) errors.ProviderError!void {
        const provider = self.provider orelse return error.NotImplemented;
        return provider.deleteRealm(allocator, input);
    }

    // --- F8: Tenant management ---
    pub fn updateClient(self: Manager, allocator: std.mem.Allocator, input: types.UpdateClientInput) errors.ProviderError!types.UpdateClientResult {
        const provider = self.provider orelse return error.NotImplemented;
        return provider.updateClient(allocator, input);
    }

    pub fn updateRealmFrontendUrl(self: Manager, allocator: std.mem.Allocator, input: types.UpdateRealmFrontendUrlInput) errors.ProviderError!void {
        const provider = self.provider orelse return error.NotImplemented;
        return provider.updateRealmFrontendUrl(allocator, input);
    }

    // --- ISS-0071: Realm-existence guard ---
    pub fn checkRealmExists(self: Manager, allocator: std.mem.Allocator, input: types.CheckRealmExistsInput) errors.ProviderError!bool {
        const provider = self.provider orelse return true; // no provider = local-only mode, treat realm as present
        return provider.checkRealmExists(allocator, input);
    }
};

fn looksLikeJwt(token: []const u8) bool {
    var dot_count: usize = 0;
    for (token) |c| {
        if (std.ascii.isWhitespace(c) or std.ascii.isControl(c)) return false;
        const allowed = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '-' or
            c == '_' or
            c == '.' or
            c == '~';
        if (!allowed) return false;
        if (c == '.') dot_count += 1;
    }
    if (dot_count != 2) return false;

    const first_dot = std.mem.indexOfScalar(u8, token, '.') orelse return false;
    const second_dot_rel = std.mem.indexOfScalar(u8, token[first_dot + 1 ..], '.') orelse return false;
    const second_dot = first_dot + 1 + second_dot_rel;

    const header = token[0..first_dot];
    const payload = token[first_dot + 1 .. second_dot];
    const signature = token[second_dot + 1 ..];
    if (header.len == 0 or payload.len == 0 or signature.len == 0) return false;
    if (!isJwtSegmentLexicallyDecodable(header)) return false;
    if (!isJwtSegmentLexicallyDecodable(payload)) return false;
    return true;
}

fn isJwtSegmentLexicallyDecodable(segment: []const u8) bool {
    if (segment.len == 0) return false;
    if (segment.len % 4 == 1) return false;
    for (segment) |c| {
        const valid = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '-' or
            c == '_';
        if (!valid) return false;
    }
    return true;
}

pub fn defaultManager() Manager {
    return .{};
}
