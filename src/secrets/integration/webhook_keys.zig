const std = @import("std");
const store_mod = @import("../store.zig");

pub const WebhookKeyOwner = struct {
    store: *store_mod.Store,

    pub fn putWebhookHmacSecret(
        self: *WebhookKeyOwner,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
        name: []const u8,
        plaintext: []const u8,
        actor_id: []const u8,
    ) store_mod.SecretError!store_mod.PutSecretOutput {
        return self.store.putSecret(allocator, .{
            .tenant_id = tenant_id,
            .namespace = "webhook",
            .name = name,
            .purpose = .webhook_hmac,
            .plaintext_value = plaintext,
            .key_id = null,
            .actor_id = actor_id,
        });
    }
};
