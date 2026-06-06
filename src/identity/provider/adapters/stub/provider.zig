const std = @import("std");
const provider_interface = @import("../../interface.zig");
const provider_types = @import("../../types.zig");
const provider_errors = @import("../../errors.zig");

pub const StubContext = struct {
    verify_result: VerifyResult = .{ .err = error.NotImplemented },
    verify_call_count: usize = 0,

    pub const VerifyResult = union(enum) {
        ok: provider_types.VerifiedPrincipal,
        err: provider_errors.ProviderError,
    };
};

pub fn asIdentityProvider(ctx: *StubContext) provider_interface.IdentityProvider {
    return .{
        .ctx = ctx,
        .verifyTokenFn = verifyToken,
        .lookupUserFn = lookupUser,
        .provisionRealmFn = provisionRealm,
        .provisionUserFn = provisionUser,
        .grantRolesFn = grantRoles,
        .provisionClientFn = provisionClient,
        .upsertFederationFn = upsertFederation,
        .deleteFederationFn = deleteFederation,
        .listAuditEventsFn = listAuditEvents,
        .createProtocolMapperFn = createProtocolMapper,
        .toggleRealmFn = toggleRealm,
        .deleteRealmFn = deleteRealmStub,
        .updateClientFn = updateClientStub,
        .updateRealmFrontendUrlFn = updateRealmFrontendUrlStub,
    };
}

fn verifyToken(raw_ctx: *anyopaque, allocator: std.mem.Allocator, _: provider_types.VerifyTokenInput) provider_errors.ProviderError!provider_types.VerifiedPrincipal {
    const ctx: *StubContext = @ptrCast(@alignCast(raw_ctx));
    ctx.verify_call_count += 1;
    return switch (ctx.verify_result) {
        .ok => |principal| clonePrincipal(allocator, principal),
        .err => |err| err,
    };
}

fn clonePrincipal(allocator: std.mem.Allocator, principal: provider_types.VerifiedPrincipal) provider_errors.ProviderError!provider_types.VerifiedPrincipal {
    const roles = allocator.alloc(provider_types.ProviderRole, principal.roles.len) catch return error.OutOfMemory;
    errdefer allocator.free(roles);
    @memcpy(roles, principal.roles);

    const provider_subject = allocator.dupe(u8, principal.provider_subject) catch return error.OutOfMemory;
    errdefer allocator.free(provider_subject);
    const username = allocator.dupe(u8, principal.username) catch return error.OutOfMemory;
    errdefer allocator.free(username);
    const display_name = allocator.dupe(u8, principal.display_name) catch return error.OutOfMemory;
    errdefer allocator.free(display_name);

    const email = if (principal.email) |value|
        allocator.dupe(u8, value) catch return error.OutOfMemory
    else
        null;
    errdefer if (email) |value| allocator.free(value);

    const external_realm = if (principal.external_realm) |value|
        allocator.dupe(u8, value) catch return error.OutOfMemory
    else
        null;
    errdefer if (external_realm) |value| allocator.free(value);

    const token_id_hint = if (principal.token_id_hint) |value|
        allocator.dupe(u8, value) catch return error.OutOfMemory
    else
        null;

    return .{
        .provider_subject = provider_subject,
        .username = username,
        .display_name = display_name,
        .email = email,
        .tenant_id = principal.tenant_id,
        .roles = roles,
        .external_realm = external_realm,
        .token_id_hint = token_id_hint,
    };
}

fn lookupUser(_: *anyopaque, _: std.mem.Allocator, _: provider_types.LookupUserInput) provider_errors.ProviderError!?provider_types.ProviderUser {
    return error.NotImplemented;
}

fn provisionRealm(_: *anyopaque, _: std.mem.Allocator, _: provider_types.ProvisionRealmInput) provider_errors.ProviderError!provider_types.ProvisionRealmResult {
    return error.NotImplemented;
}

fn provisionUser(_: *anyopaque, _: std.mem.Allocator, _: provider_types.ProvisionUserInput) provider_errors.ProviderError!provider_types.ProvisionUserResult {
    return error.NotImplemented;
}

fn grantRoles(_: *anyopaque, _: std.mem.Allocator, _: provider_types.GrantRolesInput) provider_errors.ProviderError!provider_types.GrantRolesResult {
    return error.NotImplemented;
}

fn provisionClient(_: *anyopaque, _: std.mem.Allocator, _: provider_types.ProvisionClientInput) provider_errors.ProviderError!provider_types.ProvisionClientResult {
    return error.NotImplemented;
}

fn upsertFederation(_: *anyopaque, _: std.mem.Allocator, _: provider_types.UpsertFederationInput) provider_errors.ProviderError!provider_types.FederationResult {
    return error.NotImplemented;
}

fn deleteFederation(_: *anyopaque, _: std.mem.Allocator, _: provider_types.DeleteFederationInput) provider_errors.ProviderError!void {
    return error.NotImplemented;
}

fn listAuditEvents(_: *anyopaque, _: std.mem.Allocator, _: provider_types.ListAuditEventsInput) provider_errors.ProviderError!provider_types.AuditEventPage {
    return error.NotImplemented;
}

fn createProtocolMapper(_: *anyopaque, _: std.mem.Allocator, _: provider_types.CreateProtocolMapperInput) provider_errors.ProviderError!provider_types.CreateProtocolMapperResult {
    return error.NotImplemented;
}

fn toggleRealm(_: *anyopaque, _: std.mem.Allocator, _: provider_types.ToggleRealmInput) provider_errors.ProviderError!provider_types.RealmLifecycleResult {
    return error.NotImplemented;
}

fn deleteRealmStub(_: *anyopaque, _: std.mem.Allocator, _: provider_types.DeleteRealmInput) provider_errors.ProviderError!void {
    return error.NotImplemented;
}

fn updateClientStub(_: *anyopaque, _: std.mem.Allocator, _: provider_types.UpdateClientInput) provider_errors.ProviderError!provider_types.UpdateClientResult {
    return error.NotImplemented;
}

fn updateRealmFrontendUrlStub(_: *anyopaque, _: std.mem.Allocator, _: provider_types.UpdateRealmFrontendUrlInput) provider_errors.ProviderError!void {
    return error.NotImplemented;
}