const std = @import("std");

pub const AuthTokenKind = enum {
    legacy_internal,
    oidc_bearer,
};

pub const UnifiedAuthContext = struct {
    subject_id: []const u8,
    tenant_id: []const u8,
    roles: []const []const u8,
    token_kind: AuthTokenKind,
    issued_at_unix: i64,
};

pub const CoexistenceAuthError = error{
    TenantContextMismatch,
    RoleNormalizationFailed,
    EquivalenceViolation,
    OutOfMemory,
};

pub fn normalizeAuthContext(
    allocator: std.mem.Allocator,
    input: UnifiedAuthContext,
) CoexistenceAuthError!UnifiedAuthContext {
    var role_list = try allocator.alloc([]const u8, input.roles.len);
    errdefer allocator.free(role_list);

    for (input.roles, 0..) |role, idx| {
        role_list[idx] = try allocator.dupe(u8, role);
    }

    std.mem.sort([]const u8, role_list, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    return .{
        .subject_id = try allocator.dupe(u8, input.subject_id),
        .tenant_id = try allocator.dupe(u8, input.tenant_id),
        .roles = role_list,
        .token_kind = input.token_kind,
        .issued_at_unix = input.issued_at_unix,
    };
}

pub fn freeNormalizedContext(allocator: std.mem.Allocator, ctx: UnifiedAuthContext) void {
    allocator.free(ctx.subject_id);
    allocator.free(ctx.tenant_id);
    for (ctx.roles) |role| allocator.free(role);
    allocator.free(ctx.roles);
}

pub fn assertAuthEquivalence(
    allocator: std.mem.Allocator,
    legacy_ctx: UnifiedAuthContext,
    oidc_ctx: UnifiedAuthContext,
) CoexistenceAuthError!void {
    const legacy = try normalizeAuthContext(allocator, legacy_ctx);
    defer freeNormalizedContext(allocator, legacy);

    const oidc = try normalizeAuthContext(allocator, oidc_ctx);
    defer freeNormalizedContext(allocator, oidc);

    if (!std.mem.eql(u8, legacy.subject_id, oidc.subject_id)) return error.EquivalenceViolation;
    if (!std.mem.eql(u8, legacy.tenant_id, oidc.tenant_id)) return error.TenantContextMismatch;
    if (legacy.roles.len != oidc.roles.len) return error.RoleNormalizationFailed;

    for (legacy.roles, 0..) |role, idx| {
        if (!std.mem.eql(u8, role, oidc.roles[idx])) return error.EquivalenceViolation;
    }
}
