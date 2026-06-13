const std = @import("std");

pub const SecretRef = struct {
    tenant_id: []const u8,
    namespace: []const u8,
    name: []const u8,
    key_id: ?[]const u8,
};

pub const SecretRefParseError = error{
    InvalidScheme,
    MissingTenant,
    MissingNamespace,
    MissingName,
    InvalidCharacters,
    InvalidKeyId,
};

pub fn parseSecretRef(ref_text: []const u8) SecretRefParseError!SecretRef {
    const prefix = "sec://tenant/";
    if (!std.mem.startsWith(u8, ref_text, prefix)) return error.InvalidScheme;

    const body = ref_text[prefix.len..];
    const slash1 = std.mem.indexOfScalar(u8, body, '/') orelse return error.MissingTenant;
    const tenant_id = body[0..slash1];
    if (tenant_id.len == 0) return error.MissingTenant;

    const rest = body[slash1 + 1 ..];
    const slash2 = std.mem.indexOfScalar(u8, rest, '/') orelse return error.MissingNamespace;
    const namespace = rest[0..slash2];
    if (namespace.len == 0) return error.MissingNamespace;

    const tail = rest[slash2 + 1 ..];
    if (tail.len == 0) return error.MissingName;

    const hash_index = std.mem.indexOfScalar(u8, tail, '#');
    const name = if (hash_index) |idx| tail[0..idx] else tail;
    if (name.len == 0) return error.MissingName;

    const key_id = if (hash_index) |idx| blk: {
        const value = tail[idx + 1 ..];
        if (value.len == 0) return error.InvalidKeyId;
        if (!isKeyId(value)) return error.InvalidKeyId;
        break :blk value;
    } else null;

    if (!isSegment(tenant_id) or !isSegment(namespace) or !isSegment(name)) {
        return error.InvalidCharacters;
    }

    return .{
        .tenant_id = tenant_id,
        .namespace = namespace,
        .name = name,
        .key_id = key_id,
    };
}

pub fn canonicalizeSecretRef(allocator: std.mem.Allocator, ref: SecretRef) ![]u8 {
    if (ref.key_id) |key_id| {
        return std.fmt.allocPrint(allocator, "sec://tenant/{s}/{s}/{s}#{s}", .{ ref.tenant_id, ref.namespace, ref.name, key_id });
    }
    return std.fmt.allocPrint(allocator, "sec://tenant/{s}/{s}/{s}", .{ ref.tenant_id, ref.namespace, ref.name });
}

fn isSegment(value: []const u8) bool {
    for (value) |ch| {
        if (std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_' or ch == '-') continue;
        return false;
    }
    return true;
}

fn isKeyId(value: []const u8) bool {
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') continue;
        return false;
    }
    return true;
}

test "EXP-501 reference parser handles canonical and pinned refs" {
    const parsed = try parseSecretRef("sec://tenant/tenant_1/webhook/hmac-main#k1");
    try std.testing.expectEqualStrings("tenant_1", parsed.tenant_id);
    try std.testing.expectEqualStrings("webhook", parsed.namespace);
    try std.testing.expectEqualStrings("hmac-main", parsed.name);
    try std.testing.expectEqualStrings("k1", parsed.key_id.?);

    const parsed2 = try parseSecretRef("sec://tenant/tenant_1/webhook/hmac-main");
    try std.testing.expect(parsed2.key_id == null);
}
