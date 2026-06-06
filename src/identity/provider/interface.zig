const std = @import("std");
const types = @import("types.zig");
const errors = @import("errors.zig");

pub const IdentityProvider = struct {
    ctx: *anyopaque,

    verifyTokenFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, input: types.VerifyTokenInput) errors.ProviderError!types.VerifiedPrincipal,
    lookupUserFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, input: types.LookupUserInput) errors.ProviderError!?types.ProviderUser,

    provisionRealmFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, input: types.ProvisionRealmInput) errors.ProviderError!types.ProvisionRealmResult,
    provisionUserFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, input: types.ProvisionUserInput) errors.ProviderError!types.ProvisionUserResult,
    grantRolesFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, input: types.GrantRolesInput) errors.ProviderError!types.GrantRolesResult,
    provisionClientFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, input: types.ProvisionClientInput) errors.ProviderError!types.ProvisionClientResult,

    upsertFederationFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, input: types.UpsertFederationInput) errors.ProviderError!types.FederationResult,
    deleteFederationFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, input: types.DeleteFederationInput) errors.ProviderError!void,

    listAuditEventsFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, input: types.ListAuditEventsInput) errors.ProviderError!types.AuditEventPage,

    // --- OIDC-13: Protocol mapper ---
    createProtocolMapperFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, input: types.CreateProtocolMapperInput) errors.ProviderError!types.CreateProtocolMapperResult,

    // --- OIDC-15: Realm lifecycle operations ---
    toggleRealmFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, input: types.ToggleRealmInput) errors.ProviderError!types.RealmLifecycleResult,
    deleteRealmFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, input: types.DeleteRealmInput) errors.ProviderError!void,

    // --- F8: Tenant management ---
    updateClientFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, input: types.UpdateClientInput) errors.ProviderError!types.UpdateClientResult,
    updateRealmFrontendUrlFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, input: types.UpdateRealmFrontendUrlInput) errors.ProviderError!void,

    pub fn verifyToken(self: IdentityProvider, allocator: std.mem.Allocator, input: types.VerifyTokenInput) errors.ProviderError!types.VerifiedPrincipal {
        return self.verifyTokenFn(self.ctx, allocator, input);
    }

    pub fn lookupUser(self: IdentityProvider, allocator: std.mem.Allocator, input: types.LookupUserInput) errors.ProviderError!?types.ProviderUser {
        return self.lookupUserFn(self.ctx, allocator, input);
    }

    pub fn provisionRealm(self: IdentityProvider, allocator: std.mem.Allocator, input: types.ProvisionRealmInput) errors.ProviderError!types.ProvisionRealmResult {
        return self.provisionRealmFn(self.ctx, allocator, input);
    }

    pub fn provisionUser(self: IdentityProvider, allocator: std.mem.Allocator, input: types.ProvisionUserInput) errors.ProviderError!types.ProvisionUserResult {
        return self.provisionUserFn(self.ctx, allocator, input);
    }

    pub fn grantRoles(self: IdentityProvider, allocator: std.mem.Allocator, input: types.GrantRolesInput) errors.ProviderError!types.GrantRolesResult {
        return self.grantRolesFn(self.ctx, allocator, input);
    }

    pub fn provisionClient(self: IdentityProvider, allocator: std.mem.Allocator, input: types.ProvisionClientInput) errors.ProviderError!types.ProvisionClientResult {
        return self.provisionClientFn(self.ctx, allocator, input);
    }

    pub fn upsertFederation(self: IdentityProvider, allocator: std.mem.Allocator, input: types.UpsertFederationInput) errors.ProviderError!types.FederationResult {
        return self.upsertFederationFn(self.ctx, allocator, input);
    }

    pub fn deleteFederation(self: IdentityProvider, allocator: std.mem.Allocator, input: types.DeleteFederationInput) errors.ProviderError!void {
        return self.deleteFederationFn(self.ctx, allocator, input);
    }

    pub fn listAuditEvents(self: IdentityProvider, allocator: std.mem.Allocator, input: types.ListAuditEventsInput) errors.ProviderError!types.AuditEventPage {
        return self.listAuditEventsFn(self.ctx, allocator, input);
    }

    // --- OIDC-13 ---
    pub fn createProtocolMapper(self: IdentityProvider, allocator: std.mem.Allocator, input: types.CreateProtocolMapperInput) errors.ProviderError!types.CreateProtocolMapperResult {
        return self.createProtocolMapperFn(self.ctx, allocator, input);
    }

    // --- OIDC-15 ---
    pub fn toggleRealm(self: IdentityProvider, allocator: std.mem.Allocator, input: types.ToggleRealmInput) errors.ProviderError!types.RealmLifecycleResult {
        return self.toggleRealmFn(self.ctx, allocator, input);
    }

    pub fn deleteRealm(self: IdentityProvider, allocator: std.mem.Allocator, input: types.DeleteRealmInput) errors.ProviderError!void {
        return self.deleteRealmFn(self.ctx, allocator, input);
    }

    // --- F8: Tenant management ---
    pub fn updateClient(self: IdentityProvider, allocator: std.mem.Allocator, input: types.UpdateClientInput) errors.ProviderError!types.UpdateClientResult {
        return self.updateClientFn(self.ctx, allocator, input);
    }

    pub fn updateRealmFrontendUrl(self: IdentityProvider, allocator: std.mem.Allocator, input: types.UpdateRealmFrontendUrlInput) errors.ProviderError!void {
        return self.updateRealmFrontendUrlFn(self.ctx, allocator, input);
    }
};
