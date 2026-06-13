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

    /// Must be called once, after the ActiveProvider is at its final stable
    /// memory location (i.e. after assignment to the caller's `var`). It
    /// re-establishes the manager.provider ctx pointer to the in-place adapter
    /// so that the pointer is never dangling.
    pub fn finalizeLinks(self: *ActiveProvider) void {
        switch (self.runtime) {
            .keycloak => |*adapter| {
                self.manager.provider = adapter.asIdentityProvider();
            },
            .stub => |*runtime| {
                self.manager.provider = stub.asIdentityProvider(&runtime.ctx);
            },
        }
    }

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

    const active = ActiveProvider{
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
    return active;
}

fn buildKeycloakProvider(
    allocator: std.mem.Allocator,
    cfg: idp_config.IdentityProviderConfig,
) ProviderBootstrapError!ActiveProvider {
    var secret_resolver = EnvSecretResolver{ .allocator = allocator };
    var clock = SystemClock{};

    const adapter = keycloak.Adapter.init(allocator, .{
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
        .jwks_ttl_seconds = keycloak.Config.defaults.jwks_ttl_seconds,
        .jwks_min_refresh_seconds = keycloak.Config.defaults.jwks_min_refresh_seconds,
    }, .{
        .transport = .{ .ctx = undefined, .sendFn = realHttpSend },
        .clock = .{ .ctx = &clock, .nowUnixSecondsFn = SystemClock.nowUnixSeconds },
        .secret_resolver = .{ .ctx = &secret_resolver, .resolveFn = EnvSecretResolver.resolve },
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.AdapterBootstrapFailed,
    };

    return .{
        .allocator = allocator,
        .manager = .{
            .provider = null,
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
    allocator: std.mem.Allocator,

    fn resolve(raw_ctx: *anyopaque, allocator: std.mem.Allocator, secret_ref: []const u8) anyerror![]const u8 {
        const self: *EnvSecretResolver = @ptrCast(@alignCast(raw_ctx));

        if (std.mem.startsWith(u8, secret_ref, "env:")) {
            const env_name = secret_ref[4..];
            if (env_name.len == 0) return error.UnsupportedSecretReference;

            const environ: std.process.Environ = .{ .block = .global };
            return environ.getAlloc(allocator, env_name) catch |err| switch (err) {
                error.EnvironmentVariableMissing => error.SecretNotFound,
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidWtf8 => unreachable,
            };
        }

        if (std.mem.startsWith(u8, secret_ref, "sec://tenant/")) {
            _ = self;
            if (!isValidSecTenantRef(secret_ref)) return error.UnsupportedSecretReference;
            return error.UnsupportedSecretReference;
        }

        return error.UnsupportedSecretReference;
    }
};

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

/// KcHttpCallState carries all state needed for a single outgoing KC HTTP call
/// that runs on a dedicated OS thread. Running in a fresh thread avoids the
/// Windows AFD/APC alertable-wait interference that occurs when the same call
/// is made from the server's main thread (which has accumulated unrelated APC
/// callbacks from client-connection I/O).
const KcHttpCallState = struct {
    allocator: std.mem.Allocator,
    request: keycloak.HttpRequest,
    result: keycloak.HttpResponse = undefined,
    result_err: anyerror = undefined,
    success: bool = false,

    fn threadFn(self: *KcHttpCallState) void {
        self.result = doFetch(self.allocator, self.request) catch |e| {
            self.result_err = e;
            return;
        };
        self.success = true;
    }

    fn doFetch(allocator: std.mem.Allocator, request: keycloak.HttpRequest) anyerror!keycloak.HttpResponse {
        // Create a fresh Io.Threaded for this isolated thread. The fresh instance
        // has no accumulated APC state from server connection I/O, so the
        // AFD/APC alertable-wait mechanism fires correctly.
        // Use smp_allocator so the Threaded internals do not depend on the
        // request-scoped arena (which is released after thread.join() returns).
        var io_t = std.Io.Threaded.init(std.heap.smp_allocator, .{});
        defer io_t.deinit();

        var client: std.http.Client = .{
            .allocator = allocator,
            .io = io_t.io(),
        };
        defer client.deinit();

        const method = switch (request.method) {
            .GET => std.http.Method.GET,
            .POST => std.http.Method.POST,
            .PUT => std.http.Method.PUT,
            .DELETE => std.http.Method.DELETE,
        };

        var extra_headers: std.ArrayList(std.http.Header) = .empty;
        defer extra_headers.deinit(allocator);

        var auth_header_buf: ?[]u8 = null;
        defer if (auth_header_buf) |v| allocator.free(v);

        if (request.bearer_token) |tok| {
            auth_header_buf = try std.fmt.allocPrint(allocator, "Bearer {s}", .{tok});
            try extra_headers.append(allocator, .{ .name = "Authorization", .value = auth_header_buf.? });
        }
        if (request.content_type) |ct| {
            try extra_headers.append(allocator, .{ .name = "Content-Type", .value = ct });
        }

        // On Windows, Zig resolves "localhost" to ::1 (IPv6) first. Docker on
        // Windows does not expose container services on IPv6, so the AFD TCP
        // connect to ::1:PORT hangs for ~83 s (system TCP timeout) before
        // failing. Rewriting to 127.0.0.1 forces IPv4 and avoids the hang.
        const effective_url = try rewriteLocalhostToIpv4(allocator, request.url);
        defer if (effective_url.ptr != request.url.ptr) allocator.free(effective_url);

        const uri = try std.Uri.parse(effective_url);

        var req = try client.request(method, uri, .{
            .extra_headers = extra_headers.items,
        });
        defer req.deinit();

        // Send request body or a bodiless head (GET/DELETE)
        if (request.body) |payload| {
            req.transfer_encoding = .{ .content_length = payload.len };
            var body_writer = try req.sendBodyUnflushed(&.{});
            try body_writer.writer.writeAll(payload);
            try body_writer.end();
            try req.connection.?.flush();
        } else {
            try req.sendBodiless();
        }
        // Receive the response status line + headers
        var redirect_buf: [4 * 1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buf);

        // Copy response headers into owned slices BEFORE calling readerDecompressing,
        // which internally calls response.head.invalidateStrings() and makes the
        // raw header bytes unreadable via iterateHeaders.
        var headers_list: std.ArrayList(keycloak.Header) = .empty;
        var hdr_iter = response.head.iterateHeaders();
        while (hdr_iter.next()) |hdr| {
            const name = try allocator.dupe(u8, hdr.name);
            const value = try allocator.dupe(u8, hdr.value);
            try headers_list.append(allocator, .{ .name = name, .value = value });
        }
        const headers_owned = try headers_list.toOwnedSlice(allocator);

        // Read response body
        var response_body: std.ArrayList(u8) = .empty;
        var response_writer = std.Io.Writer.Allocating.fromArrayList(allocator, &response_body);
        defer response_writer.deinit();

        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .zstd => try allocator.alloc(u8, std.compress.zstd.default_window_len),
            .deflate, .gzip => try allocator.alloc(u8, std.compress.flate.max_window_len),
            .compress => return error.UnsupportedCompressionMethod,
        };
        defer if (decompress_buffer.len > 0) allocator.free(decompress_buffer);

        var transfer_buf: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buffer);
        _ = reader.streamRemaining(&response_writer.writer) catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr() orelse error.UnexpectedBodyReadError,
            else => |e| return e,
        };

        const status: u16 = @intCast(@intFromEnum(response.head.status));
        var body_list = response_writer.toArrayList();
        const body_owned = try body_list.toOwnedSlice(allocator);
        return keycloak.HttpResponse{ .status = status, .body = body_owned, .headers = headers_owned };
    }

    /// Rewrite `://localhost:` to `://127.0.0.1:` in a URL to force IPv4.
    /// Returns the original slice unchanged (same pointer) when no rewrite is
    /// needed so the caller can skip the free.
    fn rewriteLocalhostToIpv4(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
        const needle = "://localhost:";
        const replacement = "://127.0.0.1:";
        const idx = std.mem.indexOf(u8, url, needle) orelse return url;
        const new_len = url.len - needle.len + replacement.len;
        const buf = try allocator.alloc(u8, new_len);
        @memcpy(buf[0..idx], url[0..idx]);
        @memcpy(buf[idx..][0..replacement.len], replacement);
        @memcpy(buf[idx + replacement.len ..], url[idx + needle.len ..]);
        return buf;
    }
};

fn realHttpSend(_: *anyopaque, allocator: std.mem.Allocator, request: keycloak.HttpRequest) anyerror!keycloak.HttpResponse {
    var state = KcHttpCallState{ .allocator = allocator, .request = request };
    const thread = try std.Thread.spawn(.{}, KcHttpCallState.threadFn, .{&state});
    thread.join();
    if (!state.success) return state.result_err;
    return state.result;
}

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
    active.finalizeLinks();

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
    active.finalizeLinks();

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
