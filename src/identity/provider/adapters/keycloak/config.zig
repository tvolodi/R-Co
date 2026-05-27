const std = @import("std");

pub const Config = struct {
    base_url: []const u8,
    admin_base_url: ?[]const u8,
    admin_realm: []const u8,
    bootstrap_realm: []const u8,
    admin_client_id: []const u8,
    admin_client_secret_ref: []const u8,
    expected_audience: []const u8,
    expected_issuer: ?[]const u8,
    connect_timeout_ms: u32,
    request_timeout_ms: u32,
    jwks_ttl_seconds: u32,
    jwks_min_refresh_seconds: u32,

    pub const defaults = struct {
        pub const jwks_ttl_seconds: u32 = 600;
        pub const jwks_min_refresh_seconds: u32 = 10;
    };

    pub fn clone(allocator: std.mem.Allocator, input: Config) !Config {
        const base_url = try dupeTrimmedUrl(allocator, input.base_url);
        errdefer allocator.free(base_url);

        const admin_base_url = if (input.admin_base_url) |value|
            try dupeTrimmedUrl(allocator, value)
        else
            null;
        errdefer if (admin_base_url) |value| allocator.free(value);

        const admin_realm = try allocator.dupe(u8, input.admin_realm);
        errdefer allocator.free(admin_realm);
        const bootstrap_realm = try allocator.dupe(u8, input.bootstrap_realm);
        errdefer allocator.free(bootstrap_realm);
        const admin_client_id = try allocator.dupe(u8, input.admin_client_id);
        errdefer allocator.free(admin_client_id);
        const admin_client_secret_ref = try allocator.dupe(u8, input.admin_client_secret_ref);
        errdefer allocator.free(admin_client_secret_ref);
        const expected_audience = try allocator.dupe(u8, input.expected_audience);
        errdefer allocator.free(expected_audience);
        const expected_issuer = if (input.expected_issuer) |value|
            try allocator.dupe(u8, value)
        else
            null;
        errdefer if (expected_issuer) |value| allocator.free(value);

        var cloned = Config{
            .base_url = base_url,
            .admin_base_url = admin_base_url,
            .admin_realm = admin_realm,
            .bootstrap_realm = bootstrap_realm,
            .admin_client_id = admin_client_id,
            .admin_client_secret_ref = admin_client_secret_ref,
            .expected_audience = expected_audience,
            .expected_issuer = expected_issuer,
            .connect_timeout_ms = input.connect_timeout_ms,
            .request_timeout_ms = input.request_timeout_ms,
            .jwks_ttl_seconds = input.jwks_ttl_seconds,
            .jwks_min_refresh_seconds = input.jwks_min_refresh_seconds,
        };
        try cloned.validate();
        return cloned;
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.base_url);
        if (self.admin_base_url) |value| allocator.free(value);
        allocator.free(self.admin_realm);
        allocator.free(self.bootstrap_realm);
        allocator.free(self.admin_client_id);
        allocator.free(self.admin_client_secret_ref);
        allocator.free(self.expected_audience);
        if (self.expected_issuer) |value| allocator.free(value);
    }

    pub fn adminBase(self: Config) []const u8 {
        return self.admin_base_url orelse self.base_url;
    }

    pub fn validate(self: Config) error{InvalidConfig}!void {
        if (self.base_url.len == 0) return error.InvalidConfig;
        if (self.admin_realm.len == 0) return error.InvalidConfig;
        if (self.bootstrap_realm.len == 0) return error.InvalidConfig;
        if (self.admin_client_id.len == 0) return error.InvalidConfig;
        if (self.admin_client_secret_ref.len == 0) return error.InvalidConfig;
        if (self.expected_audience.len == 0) return error.InvalidConfig;
        if (self.connect_timeout_ms == 0) return error.InvalidConfig;
        if (self.request_timeout_ms == 0) return error.InvalidConfig;
        if (self.jwks_ttl_seconds == 0) return error.InvalidConfig;
        if (self.jwks_min_refresh_seconds == 0) return error.InvalidConfig;
    }
};

fn dupeTrimmedUrl(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const trimmed = trimRightSlash(input);
    if (trimmed.len == 0) return error.InvalidConfig;
    return allocator.dupe(u8, trimmed);
}

fn trimRightSlash(input: []const u8) []const u8 {
    var end = input.len;
    while (end > 0 and input[end - 1] == '/') : (end -= 1) {}
    return input[0..end];
}