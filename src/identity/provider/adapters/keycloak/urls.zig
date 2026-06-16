const std = @import("std");
const keycloak_config = @import("config.zig");

pub fn discovery(allocator: std.mem.Allocator, config: keycloak_config.Config, realm_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/realms/{s}/.well-known/openid-configuration", .{ config.base_url, realm_name });
}

pub fn adminToken(allocator: std.mem.Allocator, config: keycloak_config.Config) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/realms/{s}/protocol/openid-connect/token", .{ config.base_url, config.admin_realm });
}

pub fn realmsCollection(allocator: std.mem.Allocator, config: keycloak_config.Config) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/admin/realms", .{config.adminBase()});
}

pub fn realm(allocator: std.mem.Allocator, config: keycloak_config.Config, realm_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/admin/realms/{s}", .{ config.adminBase(), realm_id });
}

pub fn userById(allocator: std.mem.Allocator, config: keycloak_config.Config, realm_id: []const u8, user_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/admin/realms/{s}/users/{s}", .{ config.adminBase(), realm_id, user_id });
}

pub fn usersByExternalId(allocator: std.mem.Allocator, config: keycloak_config.Config, realm_id: []const u8, external_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/admin/realms/{s}/users?q=external_id:{s}&exact=true", .{ config.adminBase(), realm_id, external_id });
}

pub fn usersByUsername(allocator: std.mem.Allocator, config: keycloak_config.Config, realm_id: []const u8, username: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/admin/realms/{s}/users?username={s}&exact=true", .{ config.adminBase(), realm_id, username });
}

pub fn usersCollection(allocator: std.mem.Allocator, config: keycloak_config.Config, realm_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/admin/realms/{s}/users", .{ config.adminBase(), realm_id });
}

pub fn rolesCollection(allocator: std.mem.Allocator, config: keycloak_config.Config, realm_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/admin/realms/{s}/roles", .{ config.adminBase(), realm_id });
}

pub fn role(allocator: std.mem.Allocator, config: keycloak_config.Config, realm_id: []const u8, role_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/admin/realms/{s}/roles/{s}", .{ config.adminBase(), realm_id, role_name });
}

pub fn userRoleMappings(allocator: std.mem.Allocator, config: keycloak_config.Config, realm_id: []const u8, user_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/admin/realms/{s}/users/{s}/role-mappings/realm", .{ config.adminBase(), realm_id, user_id });
}

pub fn clientsByName(allocator: std.mem.Allocator, config: keycloak_config.Config, realm_id: []const u8, client_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/admin/realms/{s}/clients?clientId={s}", .{ config.adminBase(), realm_id, client_name });
}

pub fn clientById(allocator: std.mem.Allocator, config: keycloak_config.Config, realm_id: []const u8, client_uuid: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/admin/realms/{s}/clients/{s}", .{ config.adminBase(), realm_id, client_uuid });
}

pub fn clientsCollection(allocator: std.mem.Allocator, config: keycloak_config.Config, realm_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/admin/realms/{s}/clients", .{ config.adminBase(), realm_id });
}

pub fn federationInstance(allocator: std.mem.Allocator, config: keycloak_config.Config, realm_id: []const u8, alias: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/admin/realms/{s}/identity-provider/instances/{s}", .{ config.adminBase(), realm_id, alias });
}

pub fn federationCollection(allocator: std.mem.Allocator, config: keycloak_config.Config, realm_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/admin/realms/{s}/identity-provider/instances", .{ config.adminBase(), realm_id });
}

pub fn auditEvents(allocator: std.mem.Allocator, config: keycloak_config.Config, realm_id: []const u8, first: usize, max: u16, from_timestamp_ms: i64, to_timestamp_ms: i64) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/admin/realms/{s}/admin-events?first={d}&max={d}&dateFrom={d}&dateTo={d}",
        .{ config.adminBase(), realm_id, first, max, from_timestamp_ms, to_timestamp_ms },
    );
}

// --- OIDC-13: Protocol mapper URLs ---

pub fn protocolMappersCollection(allocator: std.mem.Allocator, config: keycloak_config.Config, realm_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/admin/realms/{s}/protocol-mappers/models", .{ config.adminBase(), realm_id });
}

pub fn clientProtocolMappersCollection(allocator: std.mem.Allocator, config: keycloak_config.Config, realm_id: []const u8, client_uuid: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/admin/realms/{s}/clients/{s}/protocol-mappers/models", .{ config.adminBase(), realm_id, client_uuid });
}

pub fn protocolMapperById(allocator: std.mem.Allocator, config: keycloak_config.Config, realm_id: []const u8, mapper_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/admin/realms/{s}/protocol-mappers/models/{s}", .{ config.adminBase(), realm_id, mapper_id });
}

// --- OIDC-15: Realm lifecycle URLs ---

pub fn toggleRealm(allocator: std.mem.Allocator, config: keycloak_config.Config, realm_id: []const u8) ![]u8 {
    // The same URL as realm() — enable/disable is a PUT update.
    return realm(allocator, config, realm_id);
}

pub fn keysCollection(allocator: std.mem.Allocator, config: keycloak_config.Config, realm_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/admin/realms/{s}/keys", .{ config.adminBase(), realm_id });
}
