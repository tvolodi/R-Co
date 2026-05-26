const std = @import("std");
const provider_interface = @import("../../interface.zig");
const provider_types = @import("../../types.zig");
const provider_errors = @import("../../errors.zig");

pub const Adapter = struct {
    pub fn asIdentityProvider(self: *Adapter) provider_interface.IdentityProvider {
        return .{
            .ctx = self,
            .verifyTokenFn = verifyToken,
            .lookupUserFn = lookupUser,
            .provisionRealmFn = provisionRealm,
            .provisionUserFn = provisionUser,
            .grantRolesFn = grantRoles,
            .provisionClientFn = provisionClient,
            .upsertFederationFn = upsertFederation,
            .deleteFederationFn = deleteFederation,
            .listAuditEventsFn = listAuditEvents,
        };
    }
};

fn verifyToken(_: *anyopaque, _: std.mem.Allocator, _: provider_types.VerifyTokenInput) provider_errors.ProviderError!provider_types.VerifiedPrincipal {
    return error.NotImplemented;
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