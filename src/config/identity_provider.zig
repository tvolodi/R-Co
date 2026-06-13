const std = @import("std");

pub const PROVIDER_TYPE_ENV = "BPM_IDP_PROVIDER_TYPE";
pub const BASE_URL_ENV = "BPM_IDP_BASE_URL";
pub const ADMIN_CREDENTIALS_REF_ENV = "BPM_IDP_ADMIN_CREDENTIALS_REF";
pub const DEFAULT_REALM_TENANT_ENV = "BPM_IDP_DEFAULT_REALM_OR_TENANT";
pub const ADMIN_REALM_ENV = "BPM_IDP_ADMIN_REALM";
pub const EXPECTED_AUDIENCE_ENV = "BPM_IDP_EXPECTED_AUDIENCE";
pub const EXPECTED_ISSUER_ENV = "BPM_IDP_EXPECTED_ISSUER";
pub const REQUEST_TIMEOUT_MS_ENV = "BPM_IDP_REQUEST_TIMEOUT_MS";
pub const CONNECT_TIMEOUT_MS_ENV = "BPM_IDP_CONNECT_TIMEOUT_MS";

pub const ProviderType = enum {
    keycloak,
    stub,
};

pub const IdentityProviderConfig = struct {
    provider_type: ProviderType,
    base_url: []const u8,
    admin_credentials_ref: []const u8,
    default_realm_or_tenant: []const u8,

    admin_realm: ?[]const u8,
    expected_audience: ?[]const u8,
    expected_issuer: ?[]const u8,
    request_timeout_ms: u32,
    connect_timeout_ms: u32,

    pub fn deinit(self: IdentityProviderConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.base_url);
        allocator.free(self.admin_credentials_ref);
        allocator.free(self.default_realm_or_tenant);
        if (self.admin_realm) |v| allocator.free(v);
        if (self.expected_audience) |v| allocator.free(v);
        if (self.expected_issuer) |v| allocator.free(v);
    }
};

pub const ConfigLoadError = error{
    MissingProviderType,
    UnsupportedProviderType,
    MissingBaseUrl,
    InvalidBaseUrl,
    MissingAdminCredentialsRef,
    InvalidAdminCredentialsRef,
    MissingDefaultRealmOrTenant,
    InvalidDefaultRealmOrTenant,
    InvalidRequestTimeoutMs,
    InvalidConnectTimeoutMs,
    OutOfMemory,
};

pub const EnvReader = struct {
    ctx: *anyopaque,
    getFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!?[]const u8,

    pub fn getAlloc(self: EnvReader, allocator: std.mem.Allocator, name: []const u8) anyerror!?[]const u8 {
        return self.getFn(self.ctx, allocator, name);
    }

    pub fn process() EnvReader {
        return .{ .ctx = undefined, .getFn = processGetAlloc };
    }
};

pub fn loadFromProcessEnv(allocator: std.mem.Allocator, env_name: []const u8) ConfigLoadError!IdentityProviderConfig {
    return loadIdentityProviderConfig(allocator, EnvReader.process(), env_name);
}

pub fn loadIdentityProviderConfig(
    allocator: std.mem.Allocator,
    env: EnvReader,
    env_name: []const u8,
) ConfigLoadError!IdentityProviderConfig {
    const provider_raw = (try getRequiredTrimmed(allocator, env, PROVIDER_TYPE_ENV, error.MissingProviderType));
    defer allocator.free(provider_raw);

    const provider_type = parseProviderType(provider_raw) orelse return error.UnsupportedProviderType;

    const base_url = try getRequiredTrimmed(allocator, env, BASE_URL_ENV, error.MissingBaseUrl);
    errdefer allocator.free(base_url);
    if (!isValidBaseUrl(base_url, env_name)) return error.InvalidBaseUrl;

    const admin_credentials_ref = try getRequiredTrimmed(allocator, env, ADMIN_CREDENTIALS_REF_ENV, error.MissingAdminCredentialsRef);
    errdefer allocator.free(admin_credentials_ref);
    if (!isValidSecretReference(admin_credentials_ref)) return error.InvalidAdminCredentialsRef;

    const default_realm_or_tenant = try getRequiredTrimmed(allocator, env, DEFAULT_REALM_TENANT_ENV, error.MissingDefaultRealmOrTenant);
    errdefer allocator.free(default_realm_or_tenant);
    if (!isValidRealmOrTenant(default_realm_or_tenant)) return error.InvalidDefaultRealmOrTenant;

    const admin_realm = try getOptionalTrimmed(allocator, env, ADMIN_REALM_ENV);
    errdefer if (admin_realm) |v| allocator.free(v);

    const expected_audience = try getOptionalTrimmed(allocator, env, EXPECTED_AUDIENCE_ENV);
    errdefer if (expected_audience) |v| allocator.free(v);

    const expected_issuer = try getOptionalTrimmed(allocator, env, EXPECTED_ISSUER_ENV);
    errdefer if (expected_issuer) |v| allocator.free(v);

    const request_timeout_ms = try parseTimeoutMs(allocator, env, REQUEST_TIMEOUT_MS_ENV, 5_000, 500, 60_000, error.InvalidRequestTimeoutMs);
    const connect_timeout_ms = try parseTimeoutMs(allocator, env, CONNECT_TIMEOUT_MS_ENV, 1_000, 100, 10_000, error.InvalidConnectTimeoutMs);

    return .{
        .provider_type = provider_type,
        .base_url = base_url,
        .admin_credentials_ref = admin_credentials_ref,
        .default_realm_or_tenant = default_realm_or_tenant,
        .admin_realm = admin_realm,
        .expected_audience = expected_audience,
        .expected_issuer = expected_issuer,
        .request_timeout_ms = request_timeout_ms,
        .connect_timeout_ms = connect_timeout_ms,
    };
}

fn processGetAlloc(_: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!?[]const u8 {
    const environ: std.process.Environ = .{ .block = .global };
    return environ.getAlloc(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidWtf8 => unreachable,
    };
}

fn getRequiredTrimmed(
    allocator: std.mem.Allocator,
    env: EnvReader,
    name: []const u8,
    comptime missing_err: ConfigLoadError,
) ConfigLoadError![]u8 {
    const raw = env.getAlloc(allocator, name) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => missing_err,
    };
    if (raw == null) return missing_err;
    defer allocator.free(raw.?);

    const trimmed = std.mem.trim(u8, raw.?, " \t\r\n");
    if (trimmed.len == 0) return missing_err;
    return allocator.dupe(u8, trimmed) catch return error.OutOfMemory;
}

fn getOptionalTrimmed(allocator: std.mem.Allocator, env: EnvReader, name: []const u8) ConfigLoadError!?[]u8 {
    const raw = env.getAlloc(allocator, name) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
    if (raw == null) return null;
    defer allocator.free(raw.?);

    const trimmed = std.mem.trim(u8, raw.?, " \t\r\n");
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch return error.OutOfMemory;
}

fn parseProviderType(raw: []const u8) ?ProviderType {
    if (std.ascii.eqlIgnoreCase(raw, "keycloak")) return .keycloak;
    if (std.ascii.eqlIgnoreCase(raw, "stub")) return .stub;
    return null;
}

fn isValidBaseUrl(url: []const u8, env_name: []const u8) bool {
    if (std.mem.indexOfScalar(u8, url, '?') != null) return false;
    if (std.mem.indexOfScalar(u8, url, '#') != null) return false;
    if (std.mem.indexOf(u8, url, "://") == null) return false;

    if (std.mem.startsWith(u8, url, "https://")) return true;

    if (std.mem.startsWith(u8, url, "http://")) {
        return std.ascii.eqlIgnoreCase(env_name, "development");
    }

    return false;
}

fn isValidSecretReference(value: []const u8) bool {
    if (std.mem.startsWith(u8, value, "env:")) {
        const key = value[4..];
        return key.len > 0 and isAlphaNumUnderscore(key);
    }

    if (std.mem.startsWith(u8, value, "vault:")) {
        const remainder = value[6..];
        const hash_index = std.mem.indexOfScalar(u8, remainder, '#') orelse return false;
        const path = remainder[0..hash_index];
        const key = remainder[hash_index + 1 ..];
        return path.len > 0 and key.len > 0;
    }

    if (std.mem.startsWith(u8, value, "sec://tenant/")) {
        return isValidSecTenantRef(value);
    }

    return false;
}

fn isAlphaNumUnderscore(value: []const u8) bool {
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') continue;
        return false;
    }
    return true;
}

fn isValidSecTenantRef(value: []const u8) bool {
    const prefix = "sec://tenant/";
    if (!std.mem.startsWith(u8, value, prefix)) return false;

    const body = value[prefix.len..];
    const slash1 = std.mem.indexOfScalar(u8, body, '/') orelse return false;
    const tenant_id = body[0..slash1];
    if (!isRefSegment(tenant_id)) return false;

    const rest = body[slash1 + 1 ..];
    const slash2 = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
    const namespace = rest[0..slash2];
    if (!isRefSegment(namespace)) return false;

    const tail = rest[slash2 + 1 ..];
    if (tail.len == 0) return false;

    const hash_idx = std.mem.indexOfScalar(u8, tail, '#');
    const name = if (hash_idx) |idx| tail[0..idx] else tail;
    if (!isRefSegment(name)) return false;

    if (hash_idx) |idx| {
        const key_id = tail[idx + 1 ..];
        if (key_id.len == 0) return false;
        if (!isRefKeyId(key_id)) return false;
    }

    return true;
}

fn isRefSegment(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |ch| {
        if (std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_' or ch == '-') continue;
        return false;
    }
    return true;
}

fn isRefKeyId(value: []const u8) bool {
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~') continue;
        return false;
    }
    return true;
}

fn isValidRealmOrTenant(value: []const u8) bool {
    if (value.len < 2 or value.len > 63) return false;

    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > 63) return false;
    var lowered_buf: [63]u8 = undefined;
    for (trimmed, 0..) |c, idx| lowered_buf[idx] = std.ascii.toLower(c);
    const lowered = lowered_buf[0..trimmed.len];
    if (std.mem.eql(u8, lowered, "null") or std.mem.eql(u8, lowered, "undefined") or std.mem.eql(u8, lowered, "default")) {
        return false;
    }

    if (!std.ascii.isAlphanumeric(value[0])) return false;
    for (value[1..]) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-') continue;
        return false;
    }

    return true;
}

fn parseTimeoutMs(
    allocator: std.mem.Allocator,
    env: EnvReader,
    name: []const u8,
    default_value: u32,
    min_value: u32,
    max_value: u32,
    comptime invalid_err: ConfigLoadError,
) ConfigLoadError!u32 {
    const raw = try getOptionalTrimmed(allocator, env, name);
    defer if (raw) |v| allocator.free(v);

    if (raw == null) return default_value;

    const parsed = std.fmt.parseInt(u32, raw.?, 10) catch return invalid_err;
    if (parsed < min_value or parsed > max_value) return invalid_err;
    return parsed;
}

test "TC-OIDC-03-01: config loader validates required fields and timeout bounds" {
    const testing = std.testing;

    const rows = [_]EnvPair{
        .{ .name = PROVIDER_TYPE_ENV, .value = "keycloak" },
        .{ .name = BASE_URL_ENV, .value = "https://kc.example.com" },
        .{ .name = ADMIN_CREDENTIALS_REF_ENV, .value = "env:BPM_KEYCLOAK_SECRET" },
        .{ .name = DEFAULT_REALM_TENANT_ENV, .value = "bpm-default" },
        .{ .name = REQUEST_TIMEOUT_MS_ENV, .value = "600" },
        .{ .name = CONNECT_TIMEOUT_MS_ENV, .value = "200" },
    };
    var env = FakeEnv{ .pairs = rows[0..] };

    const cfg = try loadIdentityProviderConfig(testing.allocator, env.reader(), "production");
    defer cfg.deinit(testing.allocator);

    try testing.expectEqual(ProviderType.keycloak, cfg.provider_type);
    try testing.expectEqualStrings("https://kc.example.com", cfg.base_url);
    try testing.expectEqual(@as(u32, 600), cfg.request_timeout_ms);
    try testing.expectEqual(@as(u32, 200), cfg.connect_timeout_ms);
}

test "TC-OIDC-03-02: config loader rejects invalid field values with explicit errors" {
    const testing = std.testing;

    const base_rows = [_]EnvPair{
        .{ .name = PROVIDER_TYPE_ENV, .value = "keycloak" },
        .{ .name = BASE_URL_ENV, .value = "https://kc.example.com" },
        .{ .name = ADMIN_CREDENTIALS_REF_ENV, .value = "env:BPM_SECRET" },
        .{ .name = DEFAULT_REALM_TENANT_ENV, .value = "tenant-01" },
    };

    {
        var env = FakeEnv{ .pairs = (&[_]EnvPair{
            .{ .name = PROVIDER_TYPE_ENV, .value = "unknown" },
            base_rows[1],
            base_rows[2],
            base_rows[3],
        })[0..] };
        try testing.expectError(error.UnsupportedProviderType, loadIdentityProviderConfig(testing.allocator, env.reader(), "production"));
    }

    {
        var env = FakeEnv{ .pairs = (&[_]EnvPair{
            base_rows[0],
            .{ .name = BASE_URL_ENV, .value = "http://kc.example.com" },
            base_rows[2],
            base_rows[3],
        })[0..] };
        try testing.expectError(error.InvalidBaseUrl, loadIdentityProviderConfig(testing.allocator, env.reader(), "production"));
    }

    {
        var env = FakeEnv{ .pairs = (&[_]EnvPair{
            base_rows[0],
            base_rows[1],
            .{ .name = ADMIN_CREDENTIALS_REF_ENV, .value = "plaintext-secret" },
            base_rows[3],
        })[0..] };
        try testing.expectError(error.InvalidAdminCredentialsRef, loadIdentityProviderConfig(testing.allocator, env.reader(), "production"));
    }

    {
        var env = FakeEnv{ .pairs = (&[_]EnvPair{
            base_rows[0],
            base_rows[1],
            base_rows[2],
            .{ .name = DEFAULT_REALM_TENANT_ENV, .value = " default " },
        })[0..] };
        try testing.expectError(error.InvalidDefaultRealmOrTenant, loadIdentityProviderConfig(testing.allocator, env.reader(), "production"));
    }
}

test "TC-OIDC-03-04: config loader negative matrix covers missing required fields and timeout bounds" {
    const testing = std.testing;

    {
        var env = FakeEnv{ .pairs = (&[_]EnvPair{
            .{ .name = BASE_URL_ENV, .value = "https://kc.example.com" },
            .{ .name = ADMIN_CREDENTIALS_REF_ENV, .value = "env:BPM_SECRET" },
            .{ .name = DEFAULT_REALM_TENANT_ENV, .value = "tenant-01" },
        })[0..] };
        try testing.expectError(error.MissingProviderType, loadIdentityProviderConfig(testing.allocator, env.reader(), "production"));
    }

    {
        var env = FakeEnv{ .pairs = (&[_]EnvPair{
            .{ .name = PROVIDER_TYPE_ENV, .value = "keycloak" },
            .{ .name = ADMIN_CREDENTIALS_REF_ENV, .value = "env:BPM_SECRET" },
            .{ .name = DEFAULT_REALM_TENANT_ENV, .value = "tenant-01" },
        })[0..] };
        try testing.expectError(error.MissingBaseUrl, loadIdentityProviderConfig(testing.allocator, env.reader(), "production"));
    }

    {
        var env = FakeEnv{ .pairs = (&[_]EnvPair{
            .{ .name = PROVIDER_TYPE_ENV, .value = "keycloak" },
            .{ .name = BASE_URL_ENV, .value = "https://kc.example.com" },
            .{ .name = DEFAULT_REALM_TENANT_ENV, .value = "tenant-01" },
        })[0..] };
        try testing.expectError(error.MissingAdminCredentialsRef, loadIdentityProviderConfig(testing.allocator, env.reader(), "production"));
    }

    {
        var env = FakeEnv{ .pairs = (&[_]EnvPair{
            .{ .name = PROVIDER_TYPE_ENV, .value = "keycloak" },
            .{ .name = BASE_URL_ENV, .value = "https://kc.example.com" },
            .{ .name = ADMIN_CREDENTIALS_REF_ENV, .value = "env:BPM_SECRET" },
        })[0..] };
        try testing.expectError(error.MissingDefaultRealmOrTenant, loadIdentityProviderConfig(testing.allocator, env.reader(), "production"));
    }

    {
        var env = FakeEnv{ .pairs = (&[_]EnvPair{
            .{ .name = PROVIDER_TYPE_ENV, .value = "keycloak" },
            .{ .name = BASE_URL_ENV, .value = "https://kc.example.com" },
            .{ .name = ADMIN_CREDENTIALS_REF_ENV, .value = "env:BPM_SECRET" },
            .{ .name = DEFAULT_REALM_TENANT_ENV, .value = "tenant-01" },
            .{ .name = REQUEST_TIMEOUT_MS_ENV, .value = "499" },
        })[0..] };
        try testing.expectError(error.InvalidRequestTimeoutMs, loadIdentityProviderConfig(testing.allocator, env.reader(), "production"));
    }

    {
        var env = FakeEnv{ .pairs = (&[_]EnvPair{
            .{ .name = PROVIDER_TYPE_ENV, .value = "keycloak" },
            .{ .name = BASE_URL_ENV, .value = "https://kc.example.com" },
            .{ .name = ADMIN_CREDENTIALS_REF_ENV, .value = "env:BPM_SECRET" },
            .{ .name = DEFAULT_REALM_TENANT_ENV, .value = "tenant-01" },
            .{ .name = CONNECT_TIMEOUT_MS_ENV, .value = "10001" },
        })[0..] };
        try testing.expectError(error.InvalidConnectTimeoutMs, loadIdentityProviderConfig(testing.allocator, env.reader(), "production"));
    }
}

const EnvPair = struct {
    name: []const u8,
    value: []const u8,
};

const FakeEnv = struct {
    pairs: []const EnvPair,

    fn reader(self: *FakeEnv) EnvReader {
        return .{ .ctx = self, .getFn = getAlloc };
    }

    fn getAlloc(raw_ctx: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!?[]const u8 {
        const self: *FakeEnv = @ptrCast(@alignCast(raw_ctx));
        for (self.pairs) |pair| {
            if (std.mem.eql(u8, pair.name, name)) {
                const duplicated = try allocator.dupe(u8, pair.value);
                return @as(?[]const u8, duplicated);
            }
        }
        return null;
    }
};
