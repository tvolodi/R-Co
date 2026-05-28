const std = @import("std");

pub const Environment = enum {
    development,
    testing,
    production,
};

pub const TestGrantType = enum {
    password,
    client_credentials,
};

pub const TestTokenRequest = struct {
    realm_id: []const u8,
    grant_type: TestGrantType,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    client_id: []const u8,
    client_secret: ?[]const u8 = null,
    requested_scopes: []const []const u8,
};

pub const TestTokenResponse = struct {
    access_token: []const u8,
    token_type: []const u8,
    expires_in_seconds: u32,
    scope: []const u8,

    pub fn deinit(self: TestTokenResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.access_token);
        allocator.free(self.token_type);
        allocator.free(self.scope);
    }
};

pub const TestTokenHelperError = error{
    HelperDisabledInProduction,
    UnsupportedGrantType,
    MissingCredentials,
    InvalidRealm,
    TokenUnavailable,
    OutOfMemory,
};

pub fn assertTestTokenHelperAllowed(env: Environment) TestTokenHelperError!void {
    if (env == .production) return error.HelperDisabledInProduction;
}

pub fn issueTestOidcToken(
    allocator: std.mem.Allocator,
    request: TestTokenRequest,
    env: Environment,
) TestTokenHelperError!TestTokenResponse {
    try assertTestTokenHelperAllowed(env);

    if (request.realm_id.len == 0) return error.InvalidRealm;

    switch (request.grant_type) {
        .password => {
            if (request.username == null or request.password == null) return error.MissingCredentials;
        },
        .client_credentials => {
            if (request.client_secret == null) return error.MissingCredentials;
        },
    }

    // Zig 0.16 standard library in this workspace does not expose a stable
    // cross-platform env map API without libc linkage in test roots, so the
    // helper uses an explicit unavailable result when no injected token path is wired.
    _ = allocator;
    _ = request.requested_scopes;
    return error.TokenUnavailable;
}
