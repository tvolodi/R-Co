//! API-07 unit tests: input validation module.
//!
//! Covers all test cases in tests/specs/API-07.md.
//! All tests are pure — no DB, no HTTP server, no network.
//!
//! Modules under test:
//!   src/api/validation.zig         (named import: "api.validation")
//!   src/api/middleware/validate.zig (named import: "api.validate_middleware")

const std = @import("std");
const testing = std.testing;
const api = @import("api");
const validation = api.validation;
const validate_mw = api.validate_middleware;

// ── Test helper types ────────────────────────────────────────────────────────

/// Simple struct used for validate() parsing tests.
const TestBody = struct {
    name: []const u8,
    age: ?i64 = null,
    email: []const u8,
};

// ── TC-API-07-01: Missing required field → FieldError ────────────────────────

test "TC-API-07-01: validateField returns FieldError for missing required field" {
    const constraint = validation.FieldConstraint{
        .name = "title",
        .required = true,
    };

    const result = validation.validateField(constraint, null);
    try testing.expect(result != null);
    try testing.expectEqualStrings("title", result.?.field);
    try testing.expectEqualStrings("required", result.?.constraint);
    try testing.expectEqualStrings("field is required", result.?.message);
    try testing.expect(result.?.received == null);
}

// ── TC-API-07-02: Wrong type field → FieldError ──────────────────────────────

test "TC-API-07-02: validateField returns FieldError for wrong type (string expected, got integer)" {
    const constraint = validation.FieldConstraint{
        .name = "count",
        .expected_type = validation.JsonType.integer,
    };

    const json_value = std.json.Value{ .string = "not-a-number" };
    const result = validation.validateField(constraint, json_value);
    try testing.expect(result != null);
    try testing.expectEqualStrings("count", result.?.field);
    try testing.expectEqualStrings("type.integer", result.?.constraint);
    try testing.expectEqualStrings("expected integer", result.?.message);
}

test "TC-API-07-02b: validateField returns FieldError for wrong type (string expected, got boolean)" {
    const constraint = validation.FieldConstraint{
        .name = "name",
        .expected_type = validation.JsonType.string,
    };

    const json_value = std.json.Value{ .bool = true };
    const result = validation.validateField(constraint, json_value);
    try testing.expect(result != null);
    try testing.expectEqualStrings("type.string", result.?.constraint);
    try testing.expectEqualStrings("expected string", result.?.message);
}

test "TC-API-07-02c: validateField returns FieldError for wrong type (boolean expected, got null)" {
    const constraint = validation.FieldConstraint{
        .name = "flag",
        .required = true,
        .expected_type = validation.JsonType.boolean,
    };

    // null with required=true: the required check runs first and catches it
    const json_value = std.json.Value{ .null = {} };
    const result = validation.validateField(constraint, json_value);
    try testing.expect(result != null);
    try testing.expectEqualStrings("required", result.?.constraint);
}

// ── TC-API-07-03: Multiple errors → all listed ───────────────────────────────

test "TC-API-07-03: validate collects all errors, not just the first" {
    const allocator = testing.allocator;

    const schema = validation.Schema(TestBody){
        .fields = &[_]validation.FieldConstraint{
            .{ .name = "name", .required = true, .expected_type = validation.JsonType.string },
            .{ .name = "age", .expected_type = validation.JsonType.integer },
            .{ .name = "email", .required = true, .expected_type = validation.JsonType.string },
        },
        .custom_validator = null,
    };

    // JSON: {"age": "not-an-integer"} — missing name and email, age has wrong type
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"age\":\"not-an-integer\"}", .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const result = try validation.validate(TestBody, allocator, schema, parsed.value);

    switch (result) {
        .ok => return error.TestExpectedValidationErrors,
        .errors => |errs| {
            // All 3 errors should be present: name(missing), email(missing), age(type)
            try testing.expectEqual(@as(usize, 3), errs.len);

            var found_name = false;
            var found_email = false;
            var found_age = false;

            for (errs) |err| {
                if (std.mem.eql(u8, err.field, "name")) {
                    try testing.expectEqualStrings("required", err.constraint);
                    found_name = true;
                } else if (std.mem.eql(u8, err.field, "email")) {
                    try testing.expectEqualStrings("required", err.constraint);
                    found_email = true;
                } else if (std.mem.eql(u8, err.field, "age")) {
                    try testing.expectEqualStrings("type.integer", err.constraint);
                    found_age = true;
                }
            }

            try testing.expect(found_name);
            try testing.expect(found_email);
            try testing.expect(found_age);

            // Free the allocated errors
            for (errs) |err| {
                allocator.free(err.field);
                allocator.free(err.constraint);
                allocator.free(err.message);
                if (err.received) |r| allocator.free(r);
            }
            allocator.free(errs);
        },
    }
}

// ── TC-API-07-04: Empty required string treated as missing ───────────────────

test "TC-API-07-04: empty required string with reject_empty_string treated as missing" {
    const constraint = validation.FieldConstraint{
        .name = "title",
        .required = true,
        .reject_empty_string = true,
        .expected_type = validation.JsonType.string,
    };

    const json_value = std.json.Value{ .string = "" };
    const result = validation.validateField(constraint, json_value);

    try testing.expect(result != null);
    try testing.expectEqualStrings("title", result.?.field);
    try testing.expectEqualStrings("required", result.?.constraint);
    try testing.expectEqualStrings("field is required", result.?.message);
}

test "TC-API-07-04b: empty required string without reject_empty_string passes type check" {
    const constraint = validation.FieldConstraint{
        .name = "title",
        .required = true,
        .reject_empty_string = false,
        .expected_type = validation.JsonType.string,
    };

    const json_value = std.json.Value{ .string = "" };
    const result = validation.validateField(constraint, json_value);
    try testing.expect(result == null);
}

// ── TC-API-07-05: Non-object JSON → validation error ─────────────────────────

test "TC-API-07-05: validate with non-object JSON returns type.object error" {
    const allocator = testing.allocator;

    const schema = validation.Schema(TestBody){
        .fields = &[_]validation.FieldConstraint{
            .{ .name = "name", .required = true },
        },
        .custom_validator = null,
    };

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "[1, 2, 3]", .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const result = try validation.validate(TestBody, allocator, schema, parsed.value);

    switch (result) {
        .ok => return error.TestExpectedValidationErrors,
        .errors => |errs| {
            try testing.expectEqual(@as(usize, 1), errs.len);
            try testing.expectEqualStrings("(root)", errs[0].field);
            try testing.expectEqualStrings("type.object", errs[0].constraint);
            try testing.expectEqualStrings("request body must be a JSON object", errs[0].message);

            allocator.free(errs[0].field);
            allocator.free(errs[0].constraint);
            allocator.free(errs[0].message);
            if (errs[0].received) |r| allocator.free(r);
            allocator.free(errs);
        },
    }
}

// ── TC-API-07-06: Valid payload passes ───────────────────────────────────────

test "TC-API-07-06: valid payload returns .ok with parsed value" {
    const allocator = testing.allocator;

    const schema = validation.Schema(TestBody){
        .fields = &[_]validation.FieldConstraint{
            .{ .name = "name", .required = true, .expected_type = validation.JsonType.string },
            .{ .name = "age", .expected_type = validation.JsonType.integer },
            .{ .name = "email", .required = true, .expected_type = validation.JsonType.string },
        },
        .custom_validator = null,
    };

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"name\":\"Alice\",\"age\":30,\"email\":\"alice@example.com\"}", .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const result = try validation.validate(TestBody, allocator, schema, parsed.value);

    switch (result) {
        .ok => |body| {
            try testing.expectEqualStrings("Alice", body.name);
            try testing.expect(body.age != null);
            try testing.expectEqual(@as(i64, 30), body.age.?);
            try testing.expectEqualStrings("alice@example.com", body.email);
            // Strings are now caller-owned (dupeValue copies to allocator).
            allocator.free(body.name);
            allocator.free(body.email);
        },
        .errors => |errs| {
            for (errs) |err| {
                allocator.free(err.field);
                allocator.free(err.constraint);
                allocator.free(err.message);
                if (err.received) |r| allocator.free(r);
            }
            allocator.free(errs);
            return error.TestUnexpectedValidationErrors;
        },
    }
}

// ── TC-API-07-07: Validation before business logic ───────────────────────────

test "TC-API-07-07: enforceValidation returns .reject for invalid payload" {
    const allocator = testing.allocator;

    const schema = validation.Schema(TestBody){
        .fields = &[_]validation.FieldConstraint{
            .{ .name = "name", .required = true },
        },
        .custom_validator = null,
    };

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "[1, 2, 3]", .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const result = try validate_mw.enforceValidation(TestBody, allocator, schema, parsed.value);

    switch (result) {
        .ok => return error.TestExpectedRejection,
        .reject => |hr| {
            try testing.expectEqual(@as(u16, 422), hr.status_code);
            try testing.expect(std.mem.indexOf(u8, hr.body, "\"status\":422") != null);
            try testing.expect(std.mem.indexOf(u8, hr.body, "\"errors\":[") != null);
            allocator.free(hr.body);
        },
    }
}

test "TC-API-07-07b: enforceValidation returns .ok for valid payload" {
    const allocator = testing.allocator;

    const schema = validation.Schema(TestBody){
        .fields = &[_]validation.FieldConstraint{
            .{ .name = "name", .required = true, .expected_type = validation.JsonType.string },
            .{ .name = "email", .required = true, .expected_type = validation.JsonType.string },
        },
        .custom_validator = null,
    };

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"name\":\"Alice\",\"email\":\"alice@example.com\"}", .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const result = try validate_mw.enforceValidation(TestBody, allocator, schema, parsed.value);

    switch (result) {
        .ok => |body| {
            try testing.expectEqualStrings("Alice", body.name);
            try testing.expectEqualStrings("alice@example.com", body.email);
            // Strings are now caller-owned (dupeValue copies to allocator).
            allocator.free(body.name);
            allocator.free(body.email);
        },
        .reject => |hr| {
            allocator.free(hr.body);
            return error.TestUnexpectedRejection;
        },
    }
}

// ── TC-API-07-08: Optional field absent → no error ───────────────────────────

test "TC-API-07-08: optional field absent returns null (no error)" {
    const constraint = validation.FieldConstraint{
        .name = "description",
        .required = false,
    };
    try testing.expect(validation.validateField(constraint, null) == null);
}

// ── TC-API-07-09: Optional field present with correct type → no error ────────

test "TC-API-07-09: optional field with correct type returns null (no error)" {
    const constraint = validation.FieldConstraint{
        .name = "description",
        .required = false,
        .expected_type = validation.JsonType.string,
    };
    const json_value = std.json.Value{ .string = "optional description" };
    try testing.expect(validation.validateField(constraint, json_value) == null);
}

// ── TC-API-07-10: String field exceeds max_length ────────────────────────────

test "TC-API-07-10: string exceeding max_length returns FieldError" {
    const constraint = validation.FieldConstraint{
        .name = "name",
        .required = true,
        .expected_type = validation.JsonType.string,
        .max_length = 5,
    };
    const json_value = std.json.Value{ .string = "too-long" };
    const result = validation.validateField(constraint, json_value);
    try testing.expect(result != null);
    try testing.expectEqualStrings("max_length", result.?.constraint);
}

// ── TC-API-07-11: String field below min_length ──────────────────────────────

test "TC-API-07-11: string below min_length returns FieldError" {
    const constraint = validation.FieldConstraint{
        .name = "name",
        .required = true,
        .expected_type = validation.JsonType.string,
        .min_length = 5,
    };
    const json_value = std.json.Value{ .string = "ab" };
    const result = validation.validateField(constraint, json_value);
    try testing.expect(result != null);
    try testing.expectEqualStrings("min_length", result.?.constraint);
}

// ── TC-API-07-12: Non-required empty string with reject_empty_string ─────────

test "TC-API-07-12: non-required empty string with reject_empty_string returns not_empty error" {
    const constraint = validation.FieldConstraint{
        .name = "description",
        .required = false,
        .reject_empty_string = true,
        .expected_type = validation.JsonType.string,
    };
    const json_value = std.json.Value{ .string = "" };
    const result = validation.validateField(constraint, json_value);
    try testing.expect(result != null);
    try testing.expectEqualStrings("not_empty", result.?.constraint);
}

// ── TC-API-07-13: JSON null value with required=true ─────────────────────────

test "TC-API-07-13: null value with required=true returns FieldError" {
    const constraint = validation.FieldConstraint{ .name = "title", .required = true };
    const json_value = std.json.Value{ .null = {} };
    const result = validation.validateField(constraint, json_value);
    try testing.expect(result != null);
    try testing.expectEqualStrings("required", result.?.constraint);
}

// ── TC-API-07-14: JSON null value with required=false → no error ─────────────

test "TC-API-07-14: null value with required=false returns null (no error)" {
    const constraint = validation.FieldConstraint{ .name = "description", .required = false };
    const json_value = std.json.Value{ .null = {} };
    try testing.expect(validation.validateField(constraint, json_value) == null);
}

// ── TC-API-07-15: Number field below min_value ───────────────────────────────

test "TC-API-07-15: integer below min_value returns FieldError" {
    const constraint = validation.FieldConstraint{
        .name = "count",
        .required = true,
        .expected_type = validation.JsonType.integer,
        .min_value = 10,
    };
    const json_value = std.json.Value{ .integer = 5 };
    const result = validation.validateField(constraint, json_value);
    try testing.expect(result != null);
    try testing.expectEqualStrings("min_value", result.?.constraint);
}

// ── TC-API-07-16: Number field above max_value ───────────────────────────────

test "TC-API-07-16: integer above max_value returns FieldError" {
    const constraint = validation.FieldConstraint{
        .name = "count",
        .required = true,
        .expected_type = validation.JsonType.integer,
        .max_value = 100,
    };
    const json_value = std.json.Value{ .integer = 150 };
    const result = validation.validateField(constraint, json_value);
    try testing.expect(result != null);
    try testing.expectEqualStrings("max_value", result.?.constraint);
}

// ── TC-API-07-17: Array field below min_items ────────────────────────────────

test "TC-API-07-17: array below min_items returns FieldError" {
    const allocator = testing.allocator;
    const constraint = validation.FieldConstraint{
        .name = "tags",
        .required = true,
        .expected_type = validation.JsonType.array,
        .min_items = 2,
    };
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "[\"only-one\"]", .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const result = validation.validateField(constraint, parsed.value);
    try testing.expect(result != null);
    try testing.expectEqualStrings("min_items", result.?.constraint);
}

// ── TC-API-07-18: Array field above max_items ────────────────────────────────

test "TC-API-07-18: array above max_items returns FieldError" {
    const allocator = testing.allocator;
    const constraint = validation.FieldConstraint{
        .name = "tags",
        .required = true,
        .expected_type = validation.JsonType.array,
        .max_items = 2,
    };
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "[\"a\",\"b\",\"c\"]", .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const result = validation.validateField(constraint, parsed.value);
    try testing.expect(result != null);
    try testing.expectEqualStrings("max_items", result.?.constraint);
}

// ── TC-API-07-19: serialiseValidationErrors with single error ────────────────

test "TC-API-07-19: serialiseValidationErrors produces valid JSON with expected fields" {
    const allocator = testing.allocator;
    const errors = [_]validation.FieldError{
        .{ .field = "name", .constraint = "required", .message = "field is required", .received = null },
    };
    const json = try validation.serialiseValidationErrors(allocator, &errors);
    defer allocator.free(json);

    try testing.expect(json.len > 0);
    try testing.expectEqual('{', json[0]);
    try testing.expectEqual('}', json[json.len - 1]);
    try testing.expect(std.mem.indexOf(u8, json, "\"type\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"status\":422") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"errors\":[") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"field\":\"name\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"constraint\":\"required\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"received\":null") != null);
}

// ── TC-API-07-20: serialiseValidationErrors with multiple errors ─────────────

test "TC-API-07-20: multiple FieldErrors serialised as comma-separated array" {
    const allocator = testing.allocator;
    const errors = [_]validation.FieldError{
        .{ .field = "name", .constraint = "required", .message = "field is required", .received = null },
        .{ .field = "age", .constraint = "type.integer", .message = "expected integer", .received = null },
    };
    const json = try validation.serialiseValidationErrors(allocator, &errors);
    defer allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"errors\":[") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"field\":\"name\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"field\":\"age\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"constraint\":\"type.integer\"") != null);
}

// ── TC-API-07-21: serialiseValidationErrors with received value ──────────────

test "TC-API-07-21: FieldError with received value serialises the fragment" {
    const allocator = testing.allocator;
    const errors = [_]validation.FieldError{
        .{ .field = "count", .constraint = "type.integer", .message = "expected integer", .received = "\"not-a-number\"" },
    };
    const json = try validation.serialiseValidationErrors(allocator, &errors);
    defer allocator.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\"received\":") != null);
    try testing.expect(std.mem.indexOf(u8, json, "not-a-number") != null);
}

// ── Additional edge case tests ───────────────────────────────────────────────

test "TC-API-07-22: field without expected_type accepts any JSON type" {
    const constraint = validation.FieldConstraint{ .name = "data", .required = true, .expected_type = null };
    try testing.expect(validation.validateField(constraint, std.json.Value{ .string = "anything" }) == null);
    try testing.expect(validation.validateField(constraint, std.json.Value{ .integer = 42 }) == null);
    try testing.expect(validation.validateField(constraint, std.json.Value{ .bool = false }) == null);
}

test "TC-API-07-23: integer field with correct integer type passes" {
    const constraint = validation.FieldConstraint{ .name = "count", .required = true, .expected_type = validation.JsonType.integer };
    try testing.expect(validation.validateField(constraint, std.json.Value{ .integer = 42 }) == null);
}

test "TC-API-07-24: number type accepts both integer and float JSON values" {
    const constraint = validation.FieldConstraint{ .name = "weight", .required = true, .expected_type = validation.JsonType.number };
    try testing.expect(validation.validateField(constraint, std.json.Value{ .integer = 42 }) == null);
    try testing.expect(validation.validateField(constraint, std.json.Value{ .float = 3.14 }) == null);
}

test "TC-API-07-25: type check runs before string length constraints" {
    const constraint = validation.FieldConstraint{
        .name = "name",
        .required = true,
        .expected_type = validation.JsonType.string,
        .min_length = 3,
    };
    const json_value = std.json.Value{ .integer = 42 };
    const result = validation.validateField(constraint, json_value);
    try testing.expect(result != null);
    try testing.expectEqualStrings("type.string", result.?.constraint);
}

test "TC-API-07-26: string at exactly max_length boundary passes" {
    const constraint = validation.FieldConstraint{
        .name = "code",
        .required = true,
        .expected_type = validation.JsonType.string,
        .max_length = 3,
    };
    try testing.expect(validation.validateField(constraint, std.json.Value{ .string = "abc" }) == null);
}

test "TC-API-07-27: string at exactly min_length boundary passes" {
    const constraint = validation.FieldConstraint{
        .name = "code",
        .required = true,
        .expected_type = validation.JsonType.string,
        .min_length = 3,
    };
    try testing.expect(validation.validateField(constraint, std.json.Value{ .string = "abc" }) == null);
}

test "TC-API-07-28: integer at exactly min_value boundary passes" {
    const constraint = validation.FieldConstraint{
        .name = "count",
        .required = true,
        .expected_type = validation.JsonType.integer,
        .min_value = 10,
    };
    try testing.expect(validation.validateField(constraint, std.json.Value{ .integer = 10 }) == null);
}

test "TC-API-07-29: integer at exactly max_value boundary passes" {
    const constraint = validation.FieldConstraint{
        .name = "count",
        .required = true,
        .expected_type = validation.JsonType.integer,
        .max_value = 100,
    };
    try testing.expect(validation.validateField(constraint, std.json.Value{ .integer = 100 }) == null);
}

test "TC-API-07-30: array at exactly min_items boundary passes" {
    const allocator = testing.allocator;
    const constraint = validation.FieldConstraint{
        .name = "tags",
        .required = true,
        .expected_type = validation.JsonType.array,
        .min_items = 2,
    };
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "[\"a\",\"b\"]", .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try testing.expect(validation.validateField(constraint, parsed.value) == null);
}

test "TC-API-07-31: array at exactly max_items boundary passes" {
    const allocator = testing.allocator;
    const constraint = validation.FieldConstraint{
        .name = "tags",
        .required = true,
        .expected_type = validation.JsonType.array,
        .max_items = 2,
    };
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "[\"a\",\"b\"]", .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try testing.expect(validation.validateField(constraint, parsed.value) == null);
}

test "TC-API-07-32: validateField respects reject_empty_string before type check" {
    const constraint = validation.FieldConstraint{
        .name = "title",
        .required = true,
        .reject_empty_string = true,
        .expected_type = validation.JsonType.string,
    };
    const json_value = std.json.Value{ .string = "" };
    const result = validation.validateField(constraint, json_value);
    try testing.expect(result != null);
    try testing.expectEqualStrings("required", result.?.constraint);
}
