const std = @import("std");
const testing = std.testing;
const bpm = @import("bpm");

const auth = bpm.api_auth;

fn freeHandlerBody(alloc: std.mem.Allocator, body: []const u8) void {
    const static_500 = "{\"type\":\"https://bpm.example.com/problems/internal-error\",\"title\":\"Internal Server Error\",\"status\":500,\"detail\":\"serialization failed\"}";
    if (!std.mem.eql(u8, body, static_500)) {
        alloc.free(body);
    }
}

test "TC-OIDC-07-I01: wrong issuer returns HTTP 401 with token_invalid_issuer code" {
    const alloc = testing.allocator;
    const hr = auth.buildUnauthorizedAuth(alloc, .token_invalid_issuer, "invalid token issuer", .oidc_jwt, .jwt_three_segments, auth.DEFAULT_TENANT_ID, "issuer_mismatch");
    defer freeHandlerBody(alloc, hr.body);
    try testing.expectEqual(@as(u16, 401), hr.status_code);
    try testing.expect(std.mem.indexOf(u8, hr.body, "token_invalid_issuer") != null);
}

test "TC-OIDC-07-I02: wrong audience returns HTTP 401 with token_invalid_audience code" {
    const alloc = testing.allocator;
    const hr = auth.buildUnauthorizedAuth(alloc, .token_invalid_audience, "invalid token audience", .oidc_jwt, .jwt_three_segments, auth.DEFAULT_TENANT_ID, "audience_mismatch");
    defer freeHandlerBody(alloc, hr.body);
    try testing.expectEqual(@as(u16, 401), hr.status_code);
    try testing.expect(std.mem.indexOf(u8, hr.body, "token_invalid_audience") != null);
}

test "TC-OIDC-07-I03: expired token returns HTTP 401 with token_expired code" {
    const alloc = testing.allocator;
    const hr = auth.buildUnauthorizedAuth(alloc, .token_expired, "token expired", .oidc_jwt, .jwt_three_segments, auth.DEFAULT_TENANT_ID, "token_expired");
    defer freeHandlerBody(alloc, hr.body);
    try testing.expectEqual(@as(u16, 401), hr.status_code);
    try testing.expect(std.mem.indexOf(u8, hr.body, "token_expired") != null);
}

test "TC-OIDC-07-I04: not-yet-valid token returns HTTP 401 with token_not_yet_valid code" {
    const alloc = testing.allocator;
    const hr = auth.buildUnauthorizedAuth(alloc, .token_not_yet_valid, "token not yet valid", .oidc_jwt, .jwt_three_segments, auth.DEFAULT_TENANT_ID, "token_not_yet_valid");
    defer freeHandlerBody(alloc, hr.body);
    try testing.expectEqual(@as(u16, 401), hr.status_code);
    try testing.expect(std.mem.indexOf(u8, hr.body, "token_not_yet_valid") != null);
}

test "TC-OIDC-07-I05: bad signature returns HTTP 401 with token_invalid_signature code" {
    const alloc = testing.allocator;
    const hr = auth.buildUnauthorizedAuth(alloc, .token_invalid_signature, "invalid token signature", .oidc_jwt, .jwt_three_segments, auth.DEFAULT_TENANT_ID, "signature_invalid");
    defer freeHandlerBody(alloc, hr.body);
    try testing.expectEqual(@as(u16, 401), hr.status_code);
    try testing.expect(std.mem.indexOf(u8, hr.body, "token_invalid_signature") != null);
}
