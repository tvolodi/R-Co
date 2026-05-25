const std = @import("std");

pub const SigningError = error{
    EmptySecret,
    OutOfMemory,
};

pub fn buildSignatureHeader(
    allocator: std.mem.Allocator,
    secret: []const u8,
    body_bytes: []const u8,
) SigningError![]u8 {
    if (secret.len == 0) return error.EmptySecret;

    var mac: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&mac, body_bytes, secret);

    const hex = std.fmt.bytesToHex(&mac, .lower);
    const header = allocator.alloc(u8, "sha256=".len + hex.len) catch return error.OutOfMemory;
    @memcpy(header[0..7], "sha256=");
    @memcpy(header[7..], &hex);
    return header;
}

test "EXT-02 signature header format" {
    const allocator = std.testing.allocator;

    const header = try buildSignatureHeader(allocator, "secret-key", "{\"a\":1}");
    defer allocator.free(header);

    try std.testing.expect(std.mem.startsWith(u8, header, "sha256="));
    try std.testing.expectEqual(@as(usize, 71), header.len);
}

test "TC-EXT-02-U06 and TC-EXT-02-U07: signature helper formats sha256 header and rejects empty secret" {
    const allocator = std.testing.allocator;
    const header = try buildSignatureHeader(allocator, "secret-key", "{\"a\":1}");
    defer allocator.free(header);

    try std.testing.expect(std.mem.startsWith(u8, header, "sha256="));
    try std.testing.expectEqual(@as(usize, 71), header.len);
    try std.testing.expectError(error.EmptySecret, buildSignatureHeader(allocator, "", "{\"a\":1}"));
}
