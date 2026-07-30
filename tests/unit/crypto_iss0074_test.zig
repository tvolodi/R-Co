//! ISS-0074 fix unit tests: real envelope encryption in src/secrets/crypto.zig.
//!
//! Covers all test cases in tests/specs/ISS-0074-fix.md (TC-ISS-0074-01 through 09).
//! Pure unit tests — no DB, no network.

const std = @import("std");
const testing = std.testing;
const crypto = @import("secrets_crypto");

fn testKey(fill: u8) [32]u8 {
    var key: [32]u8 = undefined;
    @memset(&key, fill);
    return key;
}

test "TC-ISS-0074-01: ciphertext is not plaintext" {
    const allocator = testing.allocator;
    const plaintext = "super-secret-webhook-hmac-key-value";
    const key = testKey(0x11);

    var envelope = try crypto.encrypt(allocator, plaintext, "aad", "ref", "v1", key);
    defer envelope.deinit(allocator);

    try testing.expect(!std.mem.eql(u8, envelope.ciphertext, plaintext));
}

test "TC-ISS-0074-02: round trip for short, medium, and long secrets" {
    const allocator = testing.allocator;
    const key = testKey(0x22);

    const short = "s3cr3t";
    const medium = "sk_live_" ++ "a" ** 40;
    var long_buf: [4096]u8 = undefined;
    @memset(&long_buf, 'z');
    const cases = [_][]const u8{ short, medium, &long_buf };

    for (cases) |plaintext| {
        var envelope = try crypto.encrypt(allocator, plaintext, "tenant:ns:name:purpose", "ref", "v1", key);
        defer envelope.deinit(allocator);

        const decrypted = try crypto.decrypt(allocator, envelope, key);
        defer allocator.free(decrypted);

        try testing.expectEqualSlices(u8, plaintext, decrypted);
    }
}

test "TC-ISS-0074-03: round trip with empty plaintext" {
    const allocator = testing.allocator;
    const key = testKey(0x33);

    var envelope = try crypto.encrypt(allocator, "", "aad", "ref", "v1", key);
    defer envelope.deinit(allocator);

    const decrypted = try crypto.decrypt(allocator, envelope, key);
    defer allocator.free(decrypted);

    try testing.expectEqual(@as(usize, 0), decrypted.len);
}

test "TC-ISS-0074-04: tampered ciphertext fails decryption" {
    const allocator = testing.allocator;
    const key = testKey(0x44);

    var envelope = try crypto.encrypt(allocator, "tamper-me", "aad", "ref", "v1", key);
    defer envelope.deinit(allocator);

    envelope.ciphertext[0] ^= 0xff;

    try testing.expectError(error.DecryptionFailed, crypto.decrypt(allocator, envelope, key));
}

test "TC-ISS-0074-05: tampered auth_tag fails decryption" {
    const allocator = testing.allocator;
    const key = testKey(0x55);

    var envelope = try crypto.encrypt(allocator, "tamper-tag", "aad", "ref", "v1", key);
    defer envelope.deinit(allocator);

    envelope.auth_tag[0] ^= 0xff;

    try testing.expectError(error.DecryptionFailed, crypto.decrypt(allocator, envelope, key));
}

test "TC-ISS-0074-06: tampered wrapped_data_key fails decryption" {
    const allocator = testing.allocator;
    const key = testKey(0x66);

    var envelope = try crypto.encrypt(allocator, "tamper-wrap", "aad", "ref", "v1", key);
    defer envelope.deinit(allocator);

    envelope.wrapped_data_key[0] ^= 0xff;

    try testing.expectError(error.DecryptionFailed, crypto.decrypt(allocator, envelope, key));
}

test "TC-ISS-0074-07: wrong master key fails decryption" {
    const allocator = testing.allocator;
    const key = testKey(0x77);
    const wrong_key = testKey(0x78);

    var envelope = try crypto.encrypt(allocator, "wrong-key-test", "aad", "ref", "v1", key);
    defer envelope.deinit(allocator);

    try testing.expectError(error.DecryptionFailed, crypto.decrypt(allocator, envelope, wrong_key));
}

test "TC-ISS-0074-08: two encryptions of the same plaintext differ" {
    const allocator = testing.allocator;
    const key = testKey(0x88);
    const plaintext = "same-plaintext-twice";

    var envelope1 = try crypto.encrypt(allocator, plaintext, "aad", "ref", "v1", key);
    defer envelope1.deinit(allocator);
    var envelope2 = try crypto.encrypt(allocator, plaintext, "aad", "ref", "v1", key);
    defer envelope2.deinit(allocator);

    try testing.expect(!std.mem.eql(u8, envelope1.ciphertext, envelope2.ciphertext));
    try testing.expect(!std.mem.eql(u8, envelope1.nonce, envelope2.nonce));
}

test "TC-ISS-0074-09: tampered aad fails decryption" {
    const allocator = testing.allocator;
    const key = testKey(0x99);

    var envelope = try crypto.encrypt(allocator, "aad-bound-secret", "original-aad", "ref", "v1", key);
    defer envelope.deinit(allocator);

    envelope.aad[0] ^= 0xff;

    try testing.expectError(error.DecryptionFailed, crypto.decrypt(allocator, envelope, key));
}
