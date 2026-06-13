const std = @import("std");
const db = @import("pool");
const trace = @import("../api/middleware/trace.zig");
const crypto = @import("crypto.zig");
const reference = @import("reference.zig");

pub const SecretPurpose = enum {
    webhook_hmac,
    http_bearer,
    smtp_password,
    oidc_client_secret,
    generic,

    pub fn toWire(self: SecretPurpose) []const u8 {
        return switch (self) {
            .webhook_hmac => "webhook_hmac",
            .http_bearer => "http_bearer",
            .smtp_password => "smtp_password",
            .oidc_client_secret => "oidc_client_secret",
            .generic => "generic",
        };
    }

    pub fn fromWire(value: []const u8) ?SecretPurpose {
        if (std.mem.eql(u8, value, "webhook_hmac")) return .webhook_hmac;
        if (std.mem.eql(u8, value, "http_bearer")) return .http_bearer;
        if (std.mem.eql(u8, value, "smtp_password")) return .smtp_password;
        if (std.mem.eql(u8, value, "oidc_client_secret")) return .oidc_client_secret;
        if (std.mem.eql(u8, value, "generic")) return .generic;
        return null;
    }
};

pub const SecretError = error{
    InvalidReference,
    InvalidReferenceTenant,
    InvalidReferenceFormat,
    SecretNotFound,
    SecretVersionDisabled,
    SecretVersionDeleted,
    TenantMismatch,
    NamespaceForbidden,
    PurposeForbidden,
    EncryptionFailed,
    DecryptionFailed,
    WrappedKeyInvalid,
    WrappingKeyUnavailable,
    WrappingKeyVersionUnsupported,
    PersistenceFailed,
    PoolExhausted,
    RedactionViolation,
    InvalidInput,
    OutOfMemory,
};

pub const PutSecretInput = struct {
    tenant_id: []const u8,
    namespace: []const u8,
    name: []const u8,
    purpose: SecretPurpose,
    plaintext_value: []const u8,
    key_id: ?[]const u8,
    actor_id: []const u8,
};

pub const PutSecretOutput = struct {
    secret_ref: []u8,
    key_id: []u8,
    created_at: []u8,

    pub fn deinit(self: PutSecretOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.secret_ref);
        allocator.free(self.key_id);
        allocator.free(self.created_at);
    }
};

pub const ResolveSecretInput = struct {
    tenant_id: []const u8,
    secret_ref: []const u8,
    consumer: Consumer,
};

pub const Consumer = enum {
    effects_http,
    effects_email,
    webhook_dispatcher,
    identity_provider,
};

pub const ResolvedSecret = struct {
    value: []u8,
    key_id: []u8,
    purpose: SecretPurpose,

    pub fn deinit(self: ResolvedSecret, allocator: std.mem.Allocator) void {
        std.crypto.secureZero(u8, self.value);
        allocator.free(self.value);
        allocator.free(self.key_id);
    }
};

pub const StoreConfig = struct {
    wrapping_key_ref: []const u8,
    wrapping_key_version: []const u8,
    master_key_hex: []const u8,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    pool: *db.Pool,
    cfg: StoreConfig,
    master_key: [32]u8,

    pub fn init(allocator: std.mem.Allocator, pool: *db.Pool, cfg: StoreConfig) SecretError!Store {
        return .{
            .allocator = allocator,
            .pool = pool,
            .cfg = cfg,
            .master_key = crypto.parseMasterKeyHex(cfg.master_key_hex) catch return error.WrappingKeyUnavailable,
        };
    }

    pub fn putSecret(self: *Store, allocator: std.mem.Allocator, input: PutSecretInput) SecretError!PutSecretOutput {
        if (input.tenant_id.len == 0 or input.namespace.len == 0 or input.name.len == 0 or input.plaintext_value.len == 0) {
            return error.InvalidInput;
        }

        const conn = self.pool.acquire() catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return error.PoolExhausted,
            else => return error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        conn.begin() catch return error.PersistenceFailed;
        errdefer conn.rollback() catch {};

        const aad = std.fmt.allocPrint(allocator, "{s}:{s}:{s}:{s}", .{ input.tenant_id, input.namespace, input.name, input.purpose.toWire() }) catch return error.OutOfMemory;
        defer allocator.free(aad);

        var envelope = crypto.encrypt(
            allocator,
            input.plaintext_value,
            aad,
            self.cfg.wrapping_key_ref,
            self.cfg.wrapping_key_version,
            self.master_key,
        ) catch return error.EncryptionFailed;
        defer envelope.deinit(allocator);

        const key_id = if (input.key_id) |value|
            allocator.dupe(u8, value) catch return error.OutOfMemory
        else blk: {
            var uuid_buf: [trace.UUID_V4_LEN]u8 = undefined;
            trace.generateUuidV4(&uuid_buf);
            break :blk std.fmt.allocPrint(allocator, "k-{s}", .{uuid_buf[0..]}) catch return error.OutOfMemory;
        };
        defer allocator.free(key_id);

        const hex_ciphertext = try hexEncodeAlloc(allocator, envelope.ciphertext);
        defer allocator.free(hex_ciphertext);
        const hex_wrapped = try hexEncodeAlloc(allocator, envelope.wrapped_data_key);
        defer allocator.free(hex_wrapped);
        const hex_nonce = try hexEncodeAlloc(allocator, envelope.nonce);
        defer allocator.free(hex_nonce);
        const hex_tag = try hexEncodeAlloc(allocator, envelope.auth_tag);
        defer allocator.free(hex_tag);
        const hex_aad = try hexEncodeAlloc(allocator, envelope.aad);
        defer allocator.free(hex_aad);

        const rows = conn.query(
            allocator,
            \\INSERT INTO secrets (
            \\  tenant_id, namespace, name, key_id, purpose, status,
            \\  algorithm, wrapped_key_algorithm,
            \\  ciphertext, wrapped_data_key, nonce, auth_tag, aad,
            \\  wrapping_key_ref, wrapping_key_version,
            \\  created_by, created_at
            \\) VALUES (
            \\  $1, $2, $3, $4, $5, 'active',
            \\  $6, $7,
            \\  decode($8,'hex'), decode($9,'hex'), decode($10,'hex'), decode($11,'hex'), decode($12,'hex'),
            \\  $13, $14,
            \\  $15, NOW()
            \\)
            \\ON CONFLICT (tenant_id, namespace, name, key_id)
            \\DO UPDATE SET
            \\  purpose = EXCLUDED.purpose,
            \\  status = 'active',
            \\  algorithm = EXCLUDED.algorithm,
            \\  wrapped_key_algorithm = EXCLUDED.wrapped_key_algorithm,
            \\  ciphertext = EXCLUDED.ciphertext,
            \\  wrapped_data_key = EXCLUDED.wrapped_data_key,
            \\  nonce = EXCLUDED.nonce,
            \\  auth_tag = EXCLUDED.auth_tag,
            \\  aad = EXCLUDED.aad,
            \\  wrapping_key_ref = EXCLUDED.wrapping_key_ref,
            \\  wrapping_key_version = EXCLUDED.wrapping_key_version,
            \\  created_by = EXCLUDED.created_by,
            \\  disabled_at = NULL,
            \\  deleted_at = NULL
            \\RETURNING to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
        ,
            &.{
                input.tenant_id,
                input.namespace,
                input.name,
                key_id,
                input.purpose.toWire(),
                "aes_256_gcm",
                "aes_kw_256",
                hex_ciphertext,
                hex_wrapped,
                hex_nonce,
                hex_tag,
                hex_aad,
                self.cfg.wrapping_key_ref,
                self.cfg.wrapping_key_version,
                input.actor_id,
            },
        ) catch return error.PersistenceFailed;
        defer {
            var r = rows;
            r.deinit();
        }

        const created_at = allocator.dupe(u8, if (rows.rows.len > 0) rows.rows[0][0] orelse "" else "") catch return error.OutOfMemory;
        errdefer allocator.free(created_at);

        conn.commit() catch return error.PersistenceFailed;

        const ref = reference.canonicalizeSecretRef(allocator, .{
            .tenant_id = input.tenant_id,
            .namespace = input.namespace,
            .name = input.name,
            .key_id = key_id,
        }) catch return error.OutOfMemory;

        return .{
            .secret_ref = ref,
            .key_id = allocator.dupe(u8, key_id) catch return error.OutOfMemory,
            .created_at = created_at,
        };
    }

    pub fn resolveSecret(self: *Store, allocator: std.mem.Allocator, input: ResolveSecretInput) SecretError!ResolvedSecret {
        const parsed = reference.parseSecretRef(input.secret_ref) catch return error.InvalidReferenceFormat;
        if (!std.mem.eql(u8, parsed.tenant_id, input.tenant_id)) return error.InvalidReferenceTenant;

        const conn = self.pool.acquire() catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return error.PoolExhausted,
            else => return error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        const rows = if (parsed.key_id) |pinned_key|
            conn.query(
                allocator,
                \\SELECT key_id, purpose,
                \\  encode(ciphertext,'hex'),
                \\  encode(wrapped_data_key,'hex'),
                \\  encode(nonce,'hex'),
                \\  encode(auth_tag,'hex'),
                \\  encode(aad,'hex'),
                \\  wrapping_key_ref,
                \\  wrapping_key_version,
                \\  status
                \\FROM secrets
                \\WHERE tenant_id = $1 AND namespace = $2 AND name = $3 AND key_id = $4
                \\LIMIT 1
            ,
                &.{ parsed.tenant_id, parsed.namespace, parsed.name, pinned_key },
            ) catch return error.PersistenceFailed
        else
            conn.query(
                allocator,
                \\SELECT key_id, purpose,
                \\  encode(ciphertext,'hex'),
                \\  encode(wrapped_data_key,'hex'),
                \\  encode(nonce,'hex'),
                \\  encode(auth_tag,'hex'),
                \\  encode(aad,'hex'),
                \\  wrapping_key_ref,
                \\  wrapping_key_version,
                \\  status
                \\FROM secrets
                \\WHERE tenant_id = $1 AND namespace = $2 AND name = $3
                \\ORDER BY created_at DESC
                \\LIMIT 1
            ,
                &.{ parsed.tenant_id, parsed.namespace, parsed.name },
            ) catch return error.PersistenceFailed;
        defer {
            var r = rows;
            r.deinit();
        }

        if (rows.rows.len == 0) return error.SecretNotFound;
        const row = rows.rows[0];

        const status = row[9] orelse "active";
        if (std.mem.eql(u8, status, "disabled")) return error.SecretVersionDisabled;
        if (std.mem.eql(u8, status, "deleted")) return error.SecretVersionDeleted;

        const purpose = SecretPurpose.fromWire(row[1] orelse "generic") orelse .generic;
        if (!consumerAllowsPurpose(input.consumer, purpose)) return error.PurposeForbidden;

        const ctext_hex = row[2] orelse return error.PersistenceFailed;
        const wrapped_hex = row[3] orelse return error.PersistenceFailed;
        const nonce_hex = row[4] orelse return error.PersistenceFailed;
        const tag_hex = row[5] orelse return error.PersistenceFailed;
        const aad_hex = row[6] orelse return error.PersistenceFailed;

        const ciphertext = try hexToBytesAlloc(allocator, ctext_hex);
        defer allocator.free(ciphertext);
        const wrapped = try hexToBytesAlloc(allocator, wrapped_hex);
        defer allocator.free(wrapped);
        const nonce = try hexToBytesAlloc(allocator, nonce_hex);
        defer allocator.free(nonce);
        const tag = try hexToBytesAlloc(allocator, tag_hex);
        defer allocator.free(tag);
        const aad = try hexToBytesAlloc(allocator, aad_hex);
        defer allocator.free(aad);

        var env = crypto.SecretEnvelope{
            .algorithm = .aes_256_gcm,
            .wrapped_key_algorithm = .aes_kw_256,
            .ciphertext = allocator.dupe(u8, ciphertext) catch return error.OutOfMemory,
            .wrapped_data_key = allocator.dupe(u8, wrapped) catch return error.OutOfMemory,
            .nonce = allocator.dupe(u8, nonce) catch return error.OutOfMemory,
            .auth_tag = allocator.dupe(u8, tag) catch return error.OutOfMemory,
            .aad = allocator.dupe(u8, aad) catch return error.OutOfMemory,
            .wrapping_key_ref = allocator.dupe(u8, row[7] orelse "") catch return error.OutOfMemory,
            .wrapping_key_version = allocator.dupe(u8, row[8] orelse "") catch return error.OutOfMemory,
        };
        defer env.deinit(allocator);

        const value = crypto.decrypt(allocator, env, self.master_key) catch return error.DecryptionFailed;
        const key_id = allocator.dupe(u8, row[0] orelse "") catch {
            allocator.free(value);
            return error.OutOfMemory;
        };

        return .{
            .value = value,
            .key_id = key_id,
            .purpose = purpose,
        };
    }

    pub fn disableSecretVersion(
        self: *Store,
        allocator: std.mem.Allocator,
        tenant_id: []const u8,
        namespace: []const u8,
        name: []const u8,
        key_id: []const u8,
        actor_id: []const u8,
    ) SecretError!void {
        _ = allocator;
        const conn = self.pool.acquire() catch |err| switch (err) {
            db.PoolError.ExhaustedPool => return error.PoolExhausted,
            else => return error.PersistenceFailed,
        };
        defer self.pool.release(conn);

        conn.exec(
            \\UPDATE secrets
            \\SET status = 'disabled', disabled_at = NOW(), created_by = $5
            \\WHERE tenant_id = $1 AND namespace = $2 AND name = $3 AND key_id = $4
        ,
            &.{ tenant_id, namespace, name, key_id, actor_id },
        ) catch return error.PersistenceFailed;
    }
};

fn consumerAllowsPurpose(consumer: Consumer, purpose: SecretPurpose) bool {
    return switch (consumer) {
        .webhook_dispatcher => purpose == .webhook_hmac or purpose == .generic,
        .effects_http => purpose == .http_bearer or purpose == .generic,
        .effects_email => purpose == .smtp_password or purpose == .generic,
        .identity_provider => purpose == .oidc_client_secret or purpose == .generic,
    };
}

fn hexToBytesAlloc(allocator: std.mem.Allocator, hex: []const u8) SecretError![]u8 {
    if (hex.len % 2 != 0) return error.PersistenceFailed;
    const out = allocator.alloc(u8, hex.len / 2) catch return error.OutOfMemory;
    _ = std.fmt.hexToBytes(out, hex) catch {
        allocator.free(out);
        return error.PersistenceFailed;
    };
    return out;
}

fn hexEncodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) SecretError![]u8 {
    const out = allocator.alloc(u8, bytes.len * 2) catch return error.OutOfMemory;
    errdefer allocator.free(out);

    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = alphabet[(b >> 4) & 0x0f];
        out[i * 2 + 1] = alphabet[b & 0x0f];
    }
    return out;
}
