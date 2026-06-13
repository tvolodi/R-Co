const std = @import("std");
const store_mod = @import("store.zig");

pub const Resolver = struct {
    store: *store_mod.Store,

    pub fn resolve(self: *Resolver, allocator: std.mem.Allocator, tenant_id: []const u8, secret_ref: []const u8, consumer: store_mod.Consumer) store_mod.SecretError!store_mod.ResolvedSecret {
        return self.store.resolveSecret(allocator, .{
            .tenant_id = tenant_id,
            .secret_ref = secret_ref,
            .consumer = consumer,
        });
    }
};
