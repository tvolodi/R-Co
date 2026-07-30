const std = @import("std");
const builtin = @import("builtin");
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

pub const SecretAlgorithm = enum { aes_256_gcm };
pub const WrappedKeyAlgorithm = enum { aes_kw_256 };

const WRAP_NONCE_LEN = Aes256Gcm.nonce_length;
const WRAP_TAG_LEN = Aes256Gcm.tag_length;
const DEK_LEN = 32;
const WRAPPED_DEK_LEN = WRAP_NONCE_LEN + DEK_LEN + WRAP_TAG_LEN;

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
    // Envelope encryption per src/design/exp-05-secrets-module.md: a fresh
    // per-secret data encryption key (DEK) encrypts the plaintext via
    // AES-256-GCM; the DEK itself is wrapped (encrypted) with the host
    // master key via a second, independently-nonced AES-256-GCM operation
    // (Zig stdlib has no dedicated AES-KW primitive, so a second AEAD layer
    // is used instead; wrapped_data_key = wrap_nonce || enc(DEK) || wrap_tag).
    var nonce: [Aes256Gcm.nonce_length]u8 = undefined;
    fillRandom(&nonce);

    var data_key: [DEK_LEN]u8 = undefined;
    fillRandom(&data_key);
    defer std.crypto.secureZero(u8, &data_key);

    const ciphertext = allocator.alloc(u8, plaintext.len) catch return error.OutOfMemory;
    errdefer allocator.free(ciphertext);
    var auth_tag: [Aes256Gcm.tag_length]u8 = undefined;
    Aes256Gcm.encrypt(ciphertext, &auth_tag, plaintext, aad, nonce, data_key);

    var wrap_nonce: [WRAP_NONCE_LEN]u8 = undefined;
    fillRandom(&wrap_nonce);

    const wrapped_data_key = allocator.alloc(u8, WRAPPED_DEK_LEN) catch return error.OutOfMemory;
    errdefer allocator.free(wrapped_data_key);
    var wrap_tag: [WRAP_TAG_LEN]u8 = undefined;
    Aes256Gcm.encrypt(wrapped_data_key[WRAP_NONCE_LEN..][0..DEK_LEN], &wrap_tag, &data_key, wrapping_key_ref, wrap_nonce, master_key);
    wrapped_data_key[0..WRAP_NONCE_LEN].* = wrap_nonce;
    wrapped_data_key[WRAP_NONCE_LEN + DEK_LEN ..][0..WRAP_TAG_LEN].* = wrap_tag;

    const nonce_copy = allocator.dupe(u8, &nonce) catch return error.OutOfMemory;
    errdefer allocator.free(nonce_copy);
    const tag_copy = allocator.dupe(u8, &auth_tag) catch return error.OutOfMemory;
    errdefer allocator.free(tag_copy);
    const aad_copy = allocator.dupe(u8, aad) catch return error.OutOfMemory;
    errdefer allocator.free(aad_copy);
    const key_ref = allocator.dupe(u8, wrapping_key_ref) catch return error.OutOfMemory;
    errdefer allocator.free(key_ref);
    const key_ver = allocator.dupe(u8, wrapping_key_version) catch return error.OutOfMemory;
    errdefer allocator.free(key_ver);

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
    if (envelope.wrapped_data_key.len != WRAPPED_DEK_LEN) return error.DecryptionFailed;
    if (envelope.nonce.len != Aes256Gcm.nonce_length) return error.DecryptionFailed;
    if (envelope.auth_tag.len != Aes256Gcm.tag_length) return error.DecryptionFailed;

    const wrap_nonce: [WRAP_NONCE_LEN]u8 = envelope.wrapped_data_key[0..WRAP_NONCE_LEN].*;
    const wrapped_dek = envelope.wrapped_data_key[WRAP_NONCE_LEN..][0..DEK_LEN];
    const wrap_tag: [WRAP_TAG_LEN]u8 = envelope.wrapped_data_key[WRAP_NONCE_LEN + DEK_LEN ..][0..WRAP_TAG_LEN].*;

    var data_key: [DEK_LEN]u8 = undefined;
    defer std.crypto.secureZero(u8, &data_key);
    Aes256Gcm.decrypt(&data_key, wrapped_dek, wrap_tag, envelope.wrapping_key_ref, wrap_nonce, master_key) catch return error.DecryptionFailed;

    const nonce: [Aes256Gcm.nonce_length]u8 = envelope.nonce[0..Aes256Gcm.nonce_length].*;
    const auth_tag: [Aes256Gcm.tag_length]u8 = envelope.auth_tag[0..Aes256Gcm.tag_length].*;

    const plaintext = allocator.alloc(u8, envelope.ciphertext.len) catch return error.OutOfMemory;
    errdefer allocator.free(plaintext);
    Aes256Gcm.decrypt(plaintext, envelope.ciphertext, auth_tag, envelope.aad, nonce, data_key) catch return error.DecryptionFailed;

    return plaintext;
}

pub fn parseMasterKeyHex(value: []const u8) CryptoError![32]u8 {
    if (value.len != 64) return error.InvalidMasterKey;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, value) catch return error.InvalidMasterKey;
    return out;
}
