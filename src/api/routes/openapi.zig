const std = @import("std");
const response = @import("../response.zig");
const errors = @import("../errors.zig");
const openapi_builder = @import("../openapi/builder.zig");
const openapi_serialize = @import("../openapi/serialize.zig");
const version_source = @import("../openapi/version_source.zig");
const testing = std.testing;

pub const HandlerResult = response.HandlerResult;

pub fn handleGetOpenApi(allocator: std.mem.Allocator) HandlerResult {
    var doc = openapi_builder.buildOpenApiDocument(
        allocator,
        openapi_builder.defaultBuildInput(),
    ) catch {
        return response.problemResponse(
            allocator,
            errors.problemInternalError("failed to build OpenAPI document"),
        );
    };
    defer doc.deinit(allocator);

    const body = openapi_serialize.toJson(allocator, doc) catch {
        return response.problemResponse(
            allocator,
            errors.problemInternalError("failed to serialize OpenAPI document"),
        );
    };

    return response.ok(body);
}

test "TC-API-11-01: handleGetOpenApi returns 200 without auth context" {
    const result = handleGetOpenApi(testing.allocator);
    defer testing.allocator.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
}

test "TC-API-11-02: response body is valid JSON with openapi 3.1.x and matching info.version" {
    const result = handleGetOpenApi(testing.allocator);
    defer testing.allocator.free(result.body);
    try testing.expectEqual(@as(u16, 200), result.status_code);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        result.body,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try testing.expect(parsed.value == .object);

    const openapi_val = parsed.value.object.get("openapi") orelse return error.TestUnexpectedResult;
    try testing.expect(openapi_val == .string);
    try testing.expect(std.mem.startsWith(u8, openapi_val.string, "3.1."));

    const info_val = parsed.value.object.get("info") orelse return error.TestUnexpectedResult;
    try testing.expect(info_val == .object);

    const version_val = info_val.object.get("version") orelse return error.TestUnexpectedResult;
    try testing.expect(version_val == .string);

    const expected_version = try version_source.platformVersion(testing.allocator);
    defer testing.allocator.free(expected_version);
    try testing.expectEqualStrings(expected_version, version_val.string);
}

test "TC-API-11-03: generated document includes expected core paths and shared error schemas" {
    const result = handleGetOpenApi(testing.allocator);
    defer testing.allocator.free(result.body);
    try testing.expectEqual(@as(u16, 200), result.status_code);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        result.body,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    try testing.expect(parsed.value == .object);

    const paths_val = parsed.value.object.get("paths") orelse return error.TestUnexpectedResult;
    try testing.expect(paths_val == .object);
    try testing.expect(paths_val.object.get("/api/v1/definitions") != null);
    try testing.expect(paths_val.object.get("/api/v1/instances") != null);
    try testing.expect(paths_val.object.get("/api/v1/tasks") != null);
    try testing.expect(paths_val.object.get("/health/live") != null);
    try testing.expect(paths_val.object.get("/health/ready") != null);
    try testing.expect(paths_val.object.get("/openapi.json") != null);

    const components_val = parsed.value.object.get("components") orelse return error.TestUnexpectedResult;
    try testing.expect(components_val == .object);

    const schemas_val = components_val.object.get("schemas") orelse return error.TestUnexpectedResult;
    try testing.expect(schemas_val == .object);
    try testing.expect(schemas_val.object.get("ProblemDetails") != null);
    try testing.expect(schemas_val.object.get("ValidationProblem") != null);

    const responses_val = components_val.object.get("responses") orelse return error.TestUnexpectedResult;
    try testing.expect(responses_val == .object);
    try testing.expect(responses_val.object.get("Error400") != null);
    try testing.expect(responses_val.object.get("Error422") != null);
    try testing.expect(responses_val.object.get("Error500") != null);
}

test "TC-API-12-08: health paths are public in OpenAPI security metadata" {
    const result = handleGetOpenApi(testing.allocator);
    defer testing.allocator.free(result.body);
    try testing.expectEqual(@as(u16, 200), result.status_code);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        result.body,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const paths_val = parsed.value.object.get("paths") orelse return error.TestUnexpectedResult;
    const live_ops = paths_val.object.get("/health/live") orelse return error.TestUnexpectedResult;
    const ready_ops = paths_val.object.get("/health/ready") orelse return error.TestUnexpectedResult;
    const live_get = live_ops.object.get("get") orelse return error.TestUnexpectedResult;
    const ready_get = ready_ops.object.get("get") orelse return error.TestUnexpectedResult;

    const live_security = live_get.object.get("security") orelse return error.TestUnexpectedResult;
    const ready_security = ready_get.object.get("security") orelse return error.TestUnexpectedResult;

    try testing.expectEqual(@as(usize, 0), live_security.array.items.len);
    try testing.expectEqual(@as(usize, 0), ready_security.array.items.len);
}

test "TC-API-11-04: route response matches code-generated builder and serializer output" {
    var doc = try openapi_builder.buildOpenApiDocument(
        testing.allocator,
        openapi_builder.defaultBuildInput(),
    );
    defer doc.deinit(testing.allocator);

    const expected_json = try openapi_serialize.toJson(testing.allocator, doc);
    defer testing.allocator.free(expected_json);

    const result = handleGetOpenApi(testing.allocator);
    defer testing.allocator.free(result.body);

    try testing.expectEqual(@as(u16, 200), result.status_code);
    try testing.expectEqualStrings(expected_json, result.body);
}
