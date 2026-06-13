const std = @import("std");

pub const reference = @import("reference.zig");
pub const redaction = @import("redaction.zig");
pub const crypto = @import("crypto.zig");
pub const store = @import("store.zig");
pub const resolver = @import("resolver.zig");
pub const webhook_keys = @import("integration/webhook_keys.zig");

pub const SecretRef = reference.SecretRef;
pub const SecretRefParseError = reference.SecretRefParseError;
pub const SecretPurpose = store.SecretPurpose;
pub const SecretError = store.SecretError;
pub const PutSecretInput = store.PutSecretInput;
pub const PutSecretOutput = store.PutSecretOutput;
pub const ResolveSecretInput = store.ResolveSecretInput;
pub const ResolvedSecret = store.ResolvedSecret;
pub const Consumer = store.Consumer;
pub const Store = store.Store;
pub const StoreConfig = store.StoreConfig;

pub const SecretService = struct {
    store: *Store,

    pub fn putSecret(self: *SecretService, allocator: std.mem.Allocator, input: PutSecretInput) SecretError!PutSecretOutput {
        return self.store.putSecret(allocator, input);
    }

    pub fn resolveSecret(self: *SecretService, allocator: std.mem.Allocator, input: ResolveSecretInput) SecretError!ResolvedSecret {
        return self.store.resolveSecret(allocator, input);
    }

    pub fn disableSecretVersion(
        self: *SecretService,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
        namespace: []const u8,
        name: []const u8,
        key_id: []const u8,
        actor_id: []const u8,
    ) SecretError!void {
        return self.store.disableSecretVersion(allocator, tenant_id, namespace, name, key_id, actor_id);
    }
};

test "EXP-501 module compiles and canonical ref roundtrip" {
    const allocator = std.testing.allocator;
    const parsed = try reference.parseSecretRef("sec://tenant/default/webhook/primary#k1");
    const text = try reference.canonicalizeSecretRef(allocator, parsed);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("sec://tenant/default/webhook/primary#k1", text);
}
