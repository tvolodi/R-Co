const std = @import("std");
const types = @import("types.zig");

pub const ServiceMockCatalog = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap(types.MockResponse),

    pub fn init(allocator: std.mem.Allocator) ServiceMockCatalog {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(types.MockResponse).init(allocator),
        };
    }

    pub fn deinit(self: *ServiceMockCatalog) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.map.deinit();
    }

    pub fn put(
        self: *ServiceMockCatalog,
        service_key: []const u8,
        request_fingerprint: []const u8,
        response: types.MockResponse,
    ) types.SimulationError!void {
        const k = makeLookupKey(self.allocator, service_key, request_fingerprint) catch return error.OutOfMemory;
        errdefer self.allocator.free(k);

        const cloned = response.clone(self.allocator) catch return error.OutOfMemory;
        errdefer cloned.deinit(self.allocator);

        const entry = self.map.getEntry(k);
        if (entry) |e| {
            e.value_ptr.deinit(self.allocator);
            self.allocator.free(e.key_ptr.*);
            e.key_ptr.* = k;
            e.value_ptr.* = cloned;
            return;
        }

        self.map.put(k, cloned) catch return error.OutOfMemory;
    }

    pub fn resolve(
        self: *const ServiceMockCatalog,
        service_key: []const u8,
        request_fingerprint: []const u8,
    ) types.SimulationError!types.MockResponse {
        const k = makeLookupKey(self.allocator, service_key, request_fingerprint) catch return error.OutOfMemory;
        defer self.allocator.free(k);

        const r = self.map.get(k) orelse return error.MockResponseNotFound;
        return r.clone(self.allocator) catch return error.OutOfMemory;
    }
};

fn makeLookupKey(allocator: std.mem.Allocator, service_key: []const u8, request_fingerprint: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}|{s}", .{ service_key, request_fingerprint });
}

test "ServiceMockCatalog: stores and resolves by key+fingerprint" {
    var catalog = ServiceMockCatalog.init(std.testing.allocator);
    defer catalog.deinit();

    try catalog.put("svc.billing", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .{
        .status_code = 200,
        .headers_json = "{}",
        .body = "{\"ok\":true}",
    });

    const resolved = try catalog.resolve("svc.billing", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    defer resolved.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), resolved.status_code);
}
