const std = @import("std");
const openapi = @import("openapi");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var doc = try openapi.builder.buildOpenApiDocument(allocator, openapi.builder.defaultBuildInput());
    defer doc.deinit(allocator);

    const json = try openapi.serialize.toJson(allocator, doc);
    defer allocator.free(json);
    std.debug.print("{s}\n", .{json});
}
