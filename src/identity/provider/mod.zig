pub const errors = @import("errors.zig");
pub const types = @import("types.zig");
pub const interface = @import("interface.zig");
pub const manager = @import("manager.zig");

pub const adapters = struct {
    pub const keycloak = @import("adapters/keycloak/provider.zig");
    pub const stub = @import("adapters/stub/provider.zig");
};