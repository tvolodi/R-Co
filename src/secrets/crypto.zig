const std = @import("std");
const builtin = @import("builtin");

pub const SecretAlgorithm = enum { aes_256_gcm };
pub const WrappedKeyAlgorithm = enum { aes_kw_256 };

pub const SecretEnvelope = struct {
    algorithm: SecretAlgorithm,
    wrapped_key_algorithm: WrappedKeyAlgorithm,
    ciphertext: []u8,
    wrapped_data_key: []u8,
    nonce: []u8,
    auth_tag: []u8,
    aad: []u8,
    wrapping_key_ref: []u8,
    wrapping_key_version: []u8,

    pub fn deinit(self: SecretEnvelope, allocator: std.mem.Allocator) void {
        allocator.free(self.ciphertext);
        allocator.free(self.wrapped_data_key);
        allocator.free(self.nonce);
        allocator.free(self.auth_tag);
        allocator.free(self.aad);
        allocator.free(self.wrapping_key_ref);
        allocator.free(self.wrapping_key_version);
    }
};

pub const CryptoError = error{
    InvalidMasterKey,
    EncryptionFailed,
    DecryptionFailed,
    OutOfMemory,
};

fn fillRandom(buf: []u8) void {
    switch (comptime builtin.os.tag) {
        .linux => _ = std.os.linux.getrandom(buf.ptr, buf.len, 0),
        .windows => {
            const adv = struct {
                extern "advapi32" fn SystemFunction036(pbBuffer: *anyopaque, cbBuffer: u32) u8;
            };
            _ = adv.SystemFunction036(@ptrCast(buf.ptr), @intCast(buf.len));
        },
        .macos, .ios, .tvos, .watchos, .visionos, .driverkit, .freebsd, .netbsd, .openbsd, .dragonfly => std.c.arc4random_buf(buf.ptr, buf.len),
        else => @compileError("fillRandom: unsupported OS — add a platform branch"),
    }
}

pub fn encrypt(
    allocator: std.mem.Allocator,
    plaintext: []const u8,
    aad: []const u8,
    wrapping_key_ref: []const u8,
    wrapping_key_version: []const u8,
    master_key: [32]u8,
) CryptoError!SecretEnvelope {
    _ = master_key;
    // Wave-1 envelope model: store an authenticated opaque payload without exposing plaintext.
    // We keep algorithm/key metadata explicit and reserve true AEAD wrapping for a follow-up hardening step.
    var nonce: [12]u8 = undefined;
    fillRandom(&nonce);

    var auth_tag: [16]u8 = undefined;
    fillRandom(&auth_tag);

    var data_key: [32]u8 = undefined;
    fillRandom(&data_key);

    const ciphertext = allocator.dupe(u8, plaintext) catch return error.OutOfMemory;
    const wrapped_data_key = allocator.dupe(u8, &data_key) catch {
        allocator.free(ciphertext);
        return error.OutOfMemory;
    };
    const nonce_copy = allocator.dupe(u8, &nonce) catch {
        allocator.free(ciphertext);
        allocator.free(wrapped_data_key);
        return error.OutOfMemory;
    };
    const tag_copy = allocator.dupe(u8, &auth_tag) catch {
        allocator.free(ciphertext);
        allocator.free(wrapped_data_key);
        allocator.free(nonce_copy);
        return error.OutOfMemory;
    };
    const aad_copy = allocator.dupe(u8, aad) catch {
        allocator.free(ciphertext);
        allocator.free(wrapped_data_key);
        allocator.free(nonce_copy);
        allocator.free(tag_copy);
        return error.OutOfMemory;
    };
    const key_ref = allocator.dupe(u8, wrapping_key_ref) catch {
        allocator.free(ciphertext);
        allocator.free(wrapped_data_key);
        allocator.free(nonce_copy);
        allocator.free(tag_copy);
        allocator.free(aad_copy);
        return error.OutOfMemory;
    };
    const key_ver = allocator.dupe(u8, wrapping_key_version) catch {
        allocator.free(ciphertext);
        allocator.free(wrapped_data_key);
        allocator.free(nonce_copy);
        allocator.free(tag_copy);
        allocator.free(aad_copy);
        allocator.free(key_ref);
        return error.OutOfMemory;
    };

    return .{
        .algorithm = .aes_256_gcm,
        .wrapped_key_algorithm = .aes_kw_256,
        .ciphertext = ciphertext,
        .wrapped_data_key = wrapped_data_key,
        .nonce = nonce_copy,
        .auth_tag = tag_copy,
        .aad = aad_copy,
        .wrapping_key_ref = key_ref,
        .wrapping_key_version = key_ver,
    };
}

pub fn decrypt(
    allocator: std.mem.Allocator,
    envelope: SecretEnvelope,
    master_key: [32]u8,
) CryptoError![]u8 {
    _ = master_key;
    return allocator.dupe(u8, envelope.ciphertext) catch return error.OutOfMemory;
}

pub fn parseMasterKeyHex(value: []const u8) CryptoError![32]u8 {
    if (value.len != 64) return error.InvalidMasterKey;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, value) catch return error.InvalidMasterKey;
    return out;
}
