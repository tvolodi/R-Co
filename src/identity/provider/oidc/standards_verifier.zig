const std = @import("std");
const provider_errors = @import("../errors.zig");

pub const DiscoveryDocument = struct {
    issuer: []const u8,
    jwks_uri: []const u8,

    pub fn deinit(self: DiscoveryDocument, allocator: std.mem.Allocator) void {
        allocator.free(self.issuer);
        allocator.free(self.jwks_uri);
    }
};

pub const DiscoveryResolver = struct {
    ctx: *anyopaque,
    resolveFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, discovery_url: []const u8) provider_errors.ProviderError!DiscoveryDocument,

    pub fn resolve(self: DiscoveryResolver, allocator: std.mem.Allocator, discovery_url: []const u8) provider_errors.ProviderError!DiscoveryDocument {
        return self.resolveFn(self.ctx, allocator, discovery_url);
    }
};

pub const JwksResolver = struct {
    ctx: *anyopaque,
    containsKidFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, jwks_uri: []const u8, kid: []const u8) provider_errors.ProviderError!bool,

    pub fn containsKid(self: JwksResolver, allocator: std.mem.Allocator, jwks_uri: []const u8, kid: []const u8) provider_errors.ProviderError!bool {
        return self.containsKidFn(self.ctx, allocator, jwks_uri, kid);
    }
};

pub const VerifierDeps = struct {
    discovery_resolver: DiscoveryResolver,
    jwks_resolver: JwksResolver,
};

pub const VerifyInput = struct {
    discovery_url: []const u8,
    raw_token: []const u8,
    expected_audience: []const u8,
    expected_issuer: ?[]const u8,
    now_unix_seconds: i64,
    allowed_clock_skew_seconds: u32 = 30,
};

pub const VerifiedToken = struct {
    header: std.json.Parsed(std.json.Value),
    payload: std.json.Parsed(std.json.Value),
    issuer: []const u8,
    subject: []const u8,
    issued_at: i64,
    not_before: ?i64,
    expires_at: i64,
    token_id: ?[]const u8,

    pub fn deinit(self: *VerifiedToken) void {
        self.header.deinit();
        self.payload.deinit();
    }
};

pub fn verify(allocator: std.mem.Allocator, deps: VerifierDeps, input: VerifyInput) provider_errors.ProviderError!VerifiedToken {
    var header = try parseJwtSegment(allocator, input.raw_token, 0);
    errdefer header.deinit();
    var payload = try parseJwtSegment(allocator, input.raw_token, 1);
    errdefer payload.deinit();

    const header_obj = requireObject(header.value) orelse return error.InvalidToken;
    const payload_obj = requireObject(payload.value) orelse return error.InvalidToken;

    const kid = valueString(header_obj, "kid") orelse return error.SignatureVerificationFailed;
    if (kid.len == 0) return error.SignatureVerificationFailed;

    const issuer_claim = valueString(payload_obj, "iss") orelse return error.ClaimValidationFailed;
    if (issuer_claim.len == 0) return error.ClaimValidationFailed;

    const subject = valueString(payload_obj, "sub") orelse return error.ClaimValidationFailed;
    if (subject.len == 0) return error.ClaimValidationFailed;

    const exp = valueInteger(payload_obj.get("exp") orelse return error.ClaimValidationFailed) orelse return error.ClaimValidationFailed;
    const nbf = if (payload_obj.get("nbf")) |nbf_value|
        valueInteger(nbf_value) orelse return error.ClaimValidationFailed
    else
        null;
    const iat = valueInteger(payload_obj.get("iat") orelse return error.ClaimValidationFailed) orelse return error.ClaimValidationFailed;

    if (input.now_unix_seconds <= 0) return error.ClaimValidationFailed;
    const skew: i64 = @intCast(input.allowed_clock_skew_seconds);

    if (exp < input.now_unix_seconds - skew) return error.TokenExpired;
    if (nbf) |not_before| {
        if (not_before > input.now_unix_seconds + skew) return error.TokenNotYetValid;
    }
    if (iat > input.now_unix_seconds + skew) return error.ClaimValidationFailed;

    const discovery_doc = try deps.discovery_resolver.resolve(allocator, input.discovery_url);
    defer discovery_doc.deinit(allocator);

    if (discovery_doc.issuer.len == 0 or discovery_doc.jwks_uri.len == 0) return error.UpstreamProtocolError;

    const effective_expected_issuer = input.expected_issuer orelse discovery_doc.issuer;
    if (!std.mem.eql(u8, issuer_claim, effective_expected_issuer)) return error.TokenIssuerMismatch;

    try ensureAudience(payload_obj, input.expected_audience);

    const has_kid = try deps.jwks_resolver.containsKid(allocator, discovery_doc.jwks_uri, kid);
    if (!has_kid) return error.SignatureVerificationFailed;

    return .{
        .header = header,
        .payload = payload,
        .issuer = issuer_claim,
        .subject = subject,
        .issued_at = iat,
        .not_before = nbf,
        .expires_at = exp,
        .token_id = valueString(payload_obj, "jti"),
    };
}

fn parseJwtSegment(allocator: std.mem.Allocator, raw_token: []const u8, segment_index: usize) provider_errors.ProviderError!std.json.Parsed(std.json.Value) {
    var start: usize = 0;
    var index: usize = 0;
    while (index < segment_index) : (index += 1) {
        const dot = std.mem.indexOfScalarPos(u8, raw_token, start, '.') orelse return error.InvalidToken;
        start = dot + 1;
    }
    const end = std.mem.indexOfScalarPos(u8, raw_token, start, '.') orelse raw_token.len;
    const encoded = raw_token[start..end];
    if (encoded.len == 0) return error.InvalidToken;

    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = decoder.calcSizeForSlice(encoded) catch return error.InvalidToken;
    const decoded = allocator.alloc(u8, decoded_len) catch return error.OutOfMemory;
    defer allocator.free(decoded);
    decoder.decode(decoded, encoded) catch return error.InvalidToken;

    return std.json.parseFromSlice(std.json.Value, allocator, decoded, .{ .allocate = .alloc_always }) catch return error.InvalidToken;
}

fn requireObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |obj| obj,
        else => null,
    };
}

fn ensureAudience(payload_obj: std.json.ObjectMap, expected_audience: []const u8) provider_errors.ProviderError!void {
    const aud = payload_obj.get("aud") orelse return error.TokenAudienceMismatch;
    switch (aud) {
        .string => |value| {
            if (!std.mem.eql(u8, value, expected_audience)) return error.TokenAudienceMismatch;
        },
        .array => |items| {
            for (items.items) |item| {
                if (item == .string and std.mem.eql(u8, item.string, expected_audience)) return;
            }
            return error.TokenAudienceMismatch;
        },
        else => return error.TokenAudienceMismatch,
    }
}

fn valueString(obj: std.json.ObjectMap, field_name: []const u8) ?[]const u8 {
    const value = obj.get(field_name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn valueInteger(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |number| number,
        .float => |number| @intFromFloat(number),
        .number_string => |number| std.fmt.parseInt(i64, number, 10) catch null,
        else => null,
    };
}
