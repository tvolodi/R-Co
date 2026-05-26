const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const manager_mod = @import("manager.zig");
const idp_config = if (@hasDecl(root, "idp_config"))
    root.idp_config
else if (builtin.is_test)
    struct {
        pub const PROVIDER_TYPE_ENV = "BPM_IDP_PROVIDER_TYPE";
        pub const BASE_URL_ENV = "BPM_IDP_BASE_URL";
        pub const ADMIN_CREDENTIALS_REF_ENV = "BPM_IDP_ADMIN_CREDENTIALS_REF";
        pub const DEFAULT_REALM_TENANT_ENV = "BPM_IDP_DEFAULT_REALM_OR_TENANT";
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

        pub fn loadFromProcessEnv(_: std.mem.Allocator, _: []const u8) ConfigLoadError!IdentityProviderConfig {
            return error.MissingProviderType;
        }
    }
else
    @import("idp_config");
const keycloak = @import("adapters/keycloak/provider.zig");
const stub = @import("adapters/stub/provider.zig");

pub const ProviderBootstrapError = error{
    UnsupportedProviderType,
    AdapterBootstrapFailed,
    OutOfMemory,
};

pub const BootstrapFromEnvError = idp_config.ConfigLoadError || ProviderBootstrapError;

pub const ConfigErrorDetail = struct {
    error_code: []const u8,
    field: []const u8,
};

pub const ActiveProviderWithMetadata = struct {
    active: ActiveProvider,
    provider_type: idp_config.ProviderType,
};

pub const ActiveProvider = struct {
    allocator: std.mem.Allocator,
    manager: manager_mod.Manager,
    runtime: Runtime,

    pub fn deinit(self: *ActiveProvider) void {
        switch (self.runtime) {
            .keycloak => |*adapter| adapter.deinit(),
            .stub => |*runtime| runtime.deinit(self.allocator),
        }
    }
};

const Runtime = union(enum) {
    keycloak: keycloak.Adapter,
    stub: StubRuntime,
};

const StubRuntime = struct {
    ctx: stub.StubContext,
    expected_audience: []u8,
    expected_issuer: ?[]u8,

    fn deinit(self: *StubRuntime, allocator: std.mem.Allocator) void {
        allocator.free(self.expected_audience);
        if (self.expected_issuer) |v| allocator.free(v);
    }
};

pub fn initializeActiveProviderFromEnv(
    allocator: std.mem.Allocator,
    env_name: []const u8,
) BootstrapFromEnvError!ActiveProviderWithMetadata {
    var cfg = try idp_config.loadFromProcessEnv(allocator, env_name);
    defer cfg.deinit(allocator);

    const provider_type = cfg.provider_type;
    const active = try initializeActiveProvider(allocator, cfg);
    return .{ .active = active, .provider_type = provider_type };
}

pub fn describeConfigError(err: anyerror) ?ConfigErrorDetail {
    return switch (err) {
        error.MissingProviderType => .{ .error_code = "missing_required_field", .field = idp_config.PROVIDER_TYPE_ENV },
        error.UnsupportedProviderType => .{ .error_code = "unsupported_provider_type", .field = idp_config.PROVIDER_TYPE_ENV },
        error.MissingBaseUrl => .{ .error_code = "missing_required_field", .field = idp_config.BASE_URL_ENV },
        error.InvalidBaseUrl => .{ .error_code = "invalid_field_value", .field = idp_config.BASE_URL_ENV },
        error.MissingAdminCredentialsRef => .{ .error_code = "missing_required_field", .field = idp_config.ADMIN_CREDENTIALS_REF_ENV },
        error.InvalidAdminCredentialsRef => .{ .error_code = "secret_reference_invalid", .field = idp_config.ADMIN_CREDENTIALS_REF_ENV },
        error.MissingDefaultRealmOrTenant => .{ .error_code = "missing_required_field", .field = idp_config.DEFAULT_REALM_TENANT_ENV },
        error.InvalidDefaultRealmOrTenant => .{ .error_code = "invalid_field_value", .field = idp_config.DEFAULT_REALM_TENANT_ENV },
        error.InvalidRequestTimeoutMs => .{ .error_code = "invalid_field_value", .field = idp_config.REQUEST_TIMEOUT_MS_ENV },
        error.InvalidConnectTimeoutMs => .{ .error_code = "invalid_field_value", .field = idp_config.CONNECT_TIMEOUT_MS_ENV },
        else => null,
    };
}

pub fn initializeActiveProvider(
    allocator: std.mem.Allocator,
    cfg: idp_config.IdentityProviderConfig,
) ProviderBootstrapError!ActiveProvider {
    return switch (cfg.provider_type) {
        .stub => buildStubProvider(allocator, cfg),
        .keycloak => buildKeycloakProvider(allocator, cfg),
    };
}

fn buildStubProvider(
    allocator: std.mem.Allocator,
    cfg: idp_config.IdentityProviderConfig,
) ProviderBootstrapError!ActiveProvider {
    const expected_audience = allocator.dupe(u8, cfg.expected_audience orelse "bpm-api") catch return error.OutOfMemory;
    errdefer allocator.free(expected_audience);

    const expected_issuer = if (cfg.expected_issuer) |v|
        allocator.dupe(u8, v) catch return error.OutOfMemory
    else
        null;
    errdefer if (expected_issuer) |v| allocator.free(v);

    var active = ActiveProvider{
        .allocator = allocator,
        .manager = .{
            .provider = null,
            .auth_mode = .dual_accept,
            .expected_audience = expected_audience,
            .expected_issuer = expected_issuer,
        },
        .runtime = .{ .stub = .{
            .ctx = .{},
            .expected_audience = expected_audience,
            .expected_issuer = expected_issuer,
        } },
    };
    active.manager.provider = stub.asIdentityProvider(&active.runtime.stub.ctx);
    return active;
}

fn buildKeycloakProvider(
    allocator: std.mem.Allocator,
    cfg: idp_config.IdentityProviderConfig,
) ProviderBootstrapError!ActiveProvider {
    var secret_resolver = EnvSecretResolver{};
    var clock = SystemClock{};

    var adapter = keycloak.Adapter.init(allocator, .{
        .base_url = cfg.base_url,
        .admin_base_url = null,
        .admin_realm = cfg.admin_realm orelse "master",
        .bootstrap_realm = cfg.default_realm_or_tenant,
        .admin_client_id = "bpm-admin",
        .admin_client_secret_ref = cfg.admin_credentials_ref,
        .expected_audience = cfg.expected_audience orelse "bpm-api",
        .expected_issuer = cfg.expected_issuer,
        .connect_timeout_ms = cfg.connect_timeout_ms,
        .request_timeout_ms = cfg.request_timeout_ms,
    }, .{
        .transport = .{ .ctx = undefined, .sendFn = noOpTransportSend },
        .clock = .{ .ctx = &clock, .nowUnixSecondsFn = SystemClock.nowUnixSeconds },
        .secret_resolver = .{ .ctx = &secret_resolver, .resolveFn = EnvSecretResolver.resolve },
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.AdapterBootstrapFailed,
    };

    return .{
        .allocator = allocator,
        .manager = .{
            .provider = adapter.asIdentityProvider(),
            .auth_mode = .dual_accept,
            .expected_audience = adapter.config.expected_audience,
            .expected_issuer = adapter.config.expected_issuer,
        },
        .runtime = .{ .keycloak = adapter },
    };
}

const SystemClock = struct {
    fn nowUnixSeconds(_: *anyopaque) i64 {
        if (builtin.os.tag == .windows) {
            const ft: i64 = std.os.windows.ntdll.RtlGetSystemTimePrecise();
            const unix_100ns: i64 = ft - 116_444_736_000_000_000;
            return @divTrunc(unix_100ns, 10_000_000);
        }

        var ts: std.posix.timespec = undefined;
        _ = std.posix.system.clock_gettime(.REALTIME, &ts);
        return ts.sec;
    }
};

const EnvSecretResolver = struct {
    fn resolve(_: *anyopaque, allocator: std.mem.Allocator, secret_ref: []const u8) anyerror![]const u8 {
        if (!std.mem.startsWith(u8, secret_ref, "env:")) return error.UnsupportedSecretReference;
        const env_name = secret_ref[4..];
        if (env_name.len == 0) return error.UnsupportedSecretReference;

        const environ: std.process.Environ = .{ .block = .global };
        return environ.getAlloc(allocator, env_name) catch |err| switch (err) {
            error.EnvironmentVariableMissing => error.SecretNotFound,
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidWtf8 => unreachable,
        };
    }
};

fn noOpTransportSend(_: *anyopaque, _: std.mem.Allocator, _: keycloak.HttpRequest) anyerror!keycloak.HttpResponse {
    return error.NoTransportConfigured;
}

test "TC-OIDC-03-03: provider bootstrap selects stub manager path" {
    const testing = std.testing;

    var cfg = idp_config.IdentityProviderConfig{
        .provider_type = .stub,
        .base_url = try testing.allocator.dupe(u8, "https://stub.local"),
        .admin_credentials_ref = try testing.allocator.dupe(u8, "env:BPM_IDP_SECRET"),
        .default_realm_or_tenant = try testing.allocator.dupe(u8, "bpm-default"),
        .admin_realm = null,
        .expected_audience = null,
        .expected_issuer = null,
        .request_timeout_ms = 5_000,
        .connect_timeout_ms = 1_000,
    };
    defer cfg.deinit(testing.allocator);

    var active = try initializeActiveProvider(testing.allocator, cfg);
    defer active.deinit();

    try testing.expect(active.manager.provider != null);
    try testing.expectEqual(manager_mod.AuthMode.dual_accept, active.manager.auth_mode);
}

test "TC-OIDC-03-05: provider bootstrap selects keycloak adapter path" {
    const testing = std.testing;

    var cfg = idp_config.IdentityProviderConfig{
        .provider_type = .keycloak,
        .base_url = try testing.allocator.dupe(u8, "https://keycloak.example.com"),
        .admin_credentials_ref = try testing.allocator.dupe(u8, "env:PATH"),
        .default_realm_or_tenant = try testing.allocator.dupe(u8, "bpm-default"),
        .admin_realm = null,
        .expected_audience = null,
        .expected_issuer = null,
        .request_timeout_ms = 5_000,
        .connect_timeout_ms = 1_000,
    };
    defer cfg.deinit(testing.allocator);

    var active = try initializeActiveProvider(testing.allocator, cfg);
    defer active.deinit();

    try testing.expect(active.manager.provider != null);
    switch (active.runtime) {
        .keycloak => {},
        else => return error.TestUnexpectedResult,
    }
}

test "TC-OIDC-03-06: startup config errors include stable code and field attribution" {
    const testing = std.testing;

    {
        const detail = describeConfigError(error.MissingProviderType) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("missing_required_field", detail.error_code);
        try testing.expectEqualStrings(idp_config.PROVIDER_TYPE_ENV, detail.field);
    }

    {
        const detail = describeConfigError(error.InvalidBaseUrl) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("invalid_field_value", detail.error_code);
        try testing.expectEqualStrings(idp_config.BASE_URL_ENV, detail.field);
    }

    {
        const detail = describeConfigError(error.InvalidAdminCredentialsRef) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("secret_reference_invalid", detail.error_code);
        try testing.expectEqualStrings(idp_config.ADMIN_CREDENTIALS_REF_ENV, detail.field);
    }

    {
        const detail = describeConfigError(error.MissingDefaultRealmOrTenant) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("missing_required_field", detail.error_code);
        try testing.expectEqualStrings(idp_config.DEFAULT_REALM_TENANT_ENV, detail.field);
    }

    {
        const detail = describeConfigError(error.InvalidRequestTimeoutMs) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("invalid_field_value", detail.error_code);
        try testing.expectEqualStrings(idp_config.REQUEST_TIMEOUT_MS_ENV, detail.field);
    }

    {
        const detail = describeConfigError(error.InvalidConnectTimeoutMs) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("invalid_field_value", detail.error_code);
        try testing.expectEqualStrings(idp_config.CONNECT_TIMEOUT_MS_ENV, detail.field);
    }

    try testing.expect(describeConfigError(error.AdapterBootstrapFailed) == null);
}
