const std = @import("std");
const types = @import("types.zig");
const mock_catalog_mod = @import("mock_catalog.zig");

pub const ServiceMockCatalog = mock_catalog_mod.ServiceMockCatalog;

pub fn executeMockedServiceCall(
    allocator: std.mem.Allocator,
    ctx: *const types.SimulationContext,
    catalog: *const ServiceMockCatalog,
    service_key: []const u8,
    request: types.ServiceRequest,
) types.SimulationError!types.MockResponse {
    _ = allocator;
    if (ctx.seed.uuid_seed == 0) return error.InvalidSimulationContext;
    if (!isValidServiceKey(service_key)) return error.InvalidServiceKey;
    if (!isValidFingerprint(request.request_fingerprint)) return error.InvalidRequestFingerprint;

    return catalog.resolve(service_key, request.request_fingerprint);
}

fn isValidServiceKey(s: []const u8) bool {
    if (s.len == 0 or s.len > 128) return false;
    if (!(std.ascii.isLower(s[0]) or std.ascii.isDigit(s[0]))) return false;

    for (s) |c| {
        if (std.ascii.isLower(c) or std.ascii.isDigit(c)) continue;
        if (c == '.' or c == '_' or c == '-') continue;
        return false;
    }
    return true;
}

fn isValidFingerprint(s: []const u8) bool {
    if (s.len != 64) return false;
    for (s) |c| {
        const is_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!is_hex) return false;
    }
    return true;
}
