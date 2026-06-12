//! Entity definition validation — EXP-201
//!
//! Pure validation of entity definition JSON schemas. Checks all rules
//! specified in the design artefact: name format, field uniqueness,
//! queried+json exclusion, index coverage, FK coverage, enum/decimal
//! validation, and cardinality limits.
//!
//! Design artefact: src/design/entities.md (Validation rules section)

const std = @import("std");
const entities_mod = @import("mod.zig");

// ---------------------------------------------------------------------------
// Public error set
// ---------------------------------------------------------------------------

pub const EntityValidationError = error{
    InvalidNameFormat,
    FieldNameConflict,
    FieldQueriedAndJson,
    IndexFieldNotQueried,
    FKFieldNotQueried,
    FKTargetNotFound,
    MissingEnumValues,
    InvalidDecimalSpec,
    TooManyFields,
    TooManyIndexes,
    TooManyForeignKeys,
    SelfReferentialFK,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

pub const FieldType = enum {
    text,
    integer,
    decimal,
    boolean,
    date,
    timestamp,
    uuid,
    enum_type,
    json,
};

pub const ValidationSpec = struct {
    max_length: ?i64 = null,
    min_value: ?f64 = null,
    max_value: ?f64 = null,
    precision: ?i64 = null,
    scale: ?i64 = null,
    pattern: ?[]const u8 = null,
    values: ?[][]const u8 = null,
};

pub const FieldDef = struct {
    name: []const u8,
    display_name: []const u8,
    type: FieldType,
    required: bool = false,
    unique: bool = false,
    queried: bool = false,
    default_value: ?std.json.Value = null,
    validation: ?ValidationSpec = null,
    description: ?[]const u8 = null,
};

pub const IndexDef = struct {
    name: []const u8,
    fields: [][]const u8,
    unique: bool = false,
    method: []const u8 = "btree",
};

pub const FKDef = struct {
    name: []const u8,
    fields: [][]const u8,
    target_entity: []const u8,
    target_fields: [][]const u8,
    on_delete: []const u8 = "restrict",
};

pub const ConstraintDef = struct {
    name: []const u8,
    type: []const u8,
    definition: []const u8,
};

pub const ValidationError = struct {
    field_path: []const u8,
    constraint: []const u8,
    message: []const u8,
};

// ---------------------------------------------------------------------------
// Validation constants
// ---------------------------------------------------------------------------

const MAX_FIELDS = 64;
const MAX_INDEXES = 32;
const MAX_FOREIGN_KEYS = 16;
const MAX_NAME_LEN = 128;

// ---------------------------------------------------------------------------
// Validator
// ---------------------------------------------------------------------------

pub const Validator = struct {
    errors: std.ArrayList(ValidationError),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Validator {
        return Validator{
            .errors = std.ArrayList(ValidationError).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Validator) void {
        for (self.errors.items) |e| {
            self.allocator.free(e.field_path);
            self.allocator.free(e.constraint);
            self.allocator.free(e.message);
        }
        self.errors.deinit();
    }

    pub fn lastErrors(self: *const Validator) []const ValidationError {
        return self.errors.items;
    }

    fn addError(self: *Validator, field_path: []const u8, constraint: []const u8, message: []const u8) !void {
        const fp = try self.allocator.dupe(u8, field_path);
        const ct = try self.allocator.dupe(u8, constraint);
        const msg = try self.allocator.dupe(u8, message);
        try self.errors.append(.{
            .field_path = fp,
            .constraint = ct,
            .message = msg,
        });
    }

    /// Validate an entity definition parsed from JSON.
    /// Returns void on success, or the first validation error on failure.
    /// After a failed validation, call lastErrors() to retrieve all errors.
    pub fn validateDefinition(self: *Validator, def_json: []const u8) EntityValidationError!void {
        var parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            def_json,
            .{ .allocate = .alloc_always },
        ) catch return EntityValidationError.OutOfMemory;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            try self.addError("/", "invalid_root", "Definition must be a JSON object");
            return EntityValidationError.InvalidNameFormat;
        }

        // 1. Validate entity name
        const name_val = root.object.get("name") orelse {
            try self.addError("/name", "required", "Entity name is required");
            return EntityValidationError.InvalidNameFormat;
        };
        const entity_name = switch (name_val) {
            .string => |s| s,
            else => {
                try self.addError("/name", "type_mismatch", "Entity name must be a string");
                return EntityValidationError.InvalidNameFormat;
            },
        };
        if (!isValidName(entity_name)) {
            try self.addError("/name", "invalid_name_format", "Entity name must match [a-z][a-z0-9_]* and be 1-128 chars");
            return EntityValidationError.InvalidNameFormat;
        }

        // 2. Parse and validate fields
        const fields_val = root.object.get("fields") orelse {
            try self.addError("/fields", "required", "Fields array is required");
            return EntityValidationError.InvalidNameFormat;
        };
        if (fields_val != .array) {
            try self.addError("/fields", "type_mismatch", "Fields must be an array");
            return EntityValidationError.InvalidNameFormat;
        }
        const fields = fields_val.array.items;

        // 8. Max fields check
        if (fields.len > MAX_FIELDS) {
            try self.addError("/fields", "too_many_fields", "Maximum 64 fields allowed per definition");
            return EntityValidationError.TooManyFields;
        }

        // Track field names for uniqueness
        var field_names = std.StringHashMap(void).init(self.allocator);
        defer {
            var it = field_names.keyIterator();
            while (it.next()) |key| self.allocator.free(key.*);
            field_names.deinit();
        }

        for (fields, 0..) |field_val, i| {
            if (field_val != .object) {
                const path = try std.fmt.allocPrint(self.allocator, "/fields/{d}", .{i});
                defer self.allocator.free(path);
                try self.addError(path, "type_mismatch", "Each field must be a JSON object");
                continue;
            }
            const field_obj = field_val.object;

            // Field name
            const fname_val = field_obj.get("name") orelse {
                const path = try std.fmt.allocPrint(self.allocator, "/fields/{d}/name", .{i});
                defer self.allocator.free(path);
                try self.addError(path, "required", "Field name is required");
                continue;
            };
            const fname = switch (fname_val) {
                .string => |s| s,
                else => {
                    const path = try std.fmt.allocPrint(self.allocator, "/fields/{d}/name", .{i});
                    defer self.allocator.free(path);
                    try self.addError(path, "type_mismatch", "Field name must be a string");
                    continue;
                },
            };

            // Name format
            if (!isValidName(fname)) {
                const path = try std.fmt.allocPrint(self.allocator, "/fields/{d}/name", .{i});
                defer self.allocator.free(path);
                try self.addError(path, "invalid_name_format", "Field name must match [a-z][a-z0-9_]* and be 1-128 chars");
                return EntityValidationError.InvalidNameFormat;
            }

            // 2. Field name uniqueness
            if (field_names.contains(fname)) {
                const path = try std.fmt.allocPrint(self.allocator, "/fields/{d}/name", .{i});
                defer self.allocator.free(path);
                try self.addError(path, "field_name_conflict", "Duplicate field name");
                return EntityValidationError.FieldNameConflict;
            }
            const name_copy = try self.allocator.dupe(u8, fname);
            try field_names.put(name_copy, {});

            // Parse field type
            const ftype_str = switch (field_obj.get("type") orelse {
                const path = try std.fmt.allocPrint(self.allocator, "/fields/{d}/type", .{i});
                defer self.allocator.free(path);
                try self.addError(path, "required", "Field type is required");
                continue;
            }) {
                .string => |s| s,
                else => {
                    const path = try std.fmt.allocPrint(self.allocator, "/fields/{d}/type", .{i});
                    defer self.allocator.free(path);
                    try self.addError(path, "type_mismatch", "Field type must be a string");
                    continue;
                },
            };

            const ftype = parseFieldType(ftype_str) orelse {
                const path = try std.fmt.allocPrint(self.allocator, "/fields/{d}/type", .{i});
                defer self.allocator.free(path);
                try self.addError(path, "invalid_field_type", "Unknown field type");
                continue;
            };

            // Queried flag
            const queried = switch (field_obj.get("queried") orelse std.json.Value{ .bool = false }) {
                .bool => |b| b,
                else => false,
            };

            // 3. Queried + json exclusion (EXP-201 acceptance)
            if (queried and ftype == .json) {
                const path = try std.fmt.allocPrint(self.allocator, "/fields/{d}", .{i});
                defer self.allocator.free(path);
                const msg = try std.fmt.allocPrint(self.allocator, "Field '{s}' is marked queried=true but type is json. Queried fields become typed projection columns and cannot be free-form JSON.", .{fname});
                defer self.allocator.free(msg);
                try self.addError(path, "queried_and_json_exclusion", msg);
                return EntityValidationError.FieldQueriedAndJson;
            }

            // 6. Enum validation
            if (ftype == .enum_type) {
                const validation_val = field_obj.get("validation");
                var has_values = false;
                if (validation_val) |vv| {
                    if (vv == .object) {
                        if (vv.object.get("values")) |values_val| {
                            if (values_val == .array and values_val.array.items.len > 0) {
                                has_values = true;
                            }
                        }
                    }
                }
                if (!has_values) {
                    const path = try std.fmt.allocPrint(self.allocator, "/fields/{d}/validation/values", .{i});
                    defer self.allocator.free(path);
                    try self.addError(path, "missing_enum_values", "Enum field must have non-empty validation.values");
                    return EntityValidationError.MissingEnumValues;
                }
            }

            // 7. Decimal validation
            if (ftype == .decimal) {
                const validation_val = field_obj.get("validation");
                var has_precision = false;
                var has_scale = false;
                var precision_val: i64 = 0;
                var scale_val: i64 = 0;
                if (validation_val) |vv| {
                    if (vv == .object) {
                        if (vv.object.get("precision")) |p| {
                            switch (p) {
                                .integer => |v| {
                                    has_precision = true;
                                    precision_val = v;
                                },
                                else => {},
                            }
                        }
                        if (vv.object.get("scale")) |s| {
                            switch (s) {
                                .integer => |v| {
                                    has_scale = true;
                                    scale_val = v;
                                },
                                else => {},
                            }
                        }
                    }
                }
                if (!has_precision or !has_scale) {
                    const path = try std.fmt.allocPrint(self.allocator, "/fields/{d}/validation", .{i});
                    defer self.allocator.free(path);
                    try self.addError(path, "invalid_decimal_spec", "Decimal field must have validation.precision and validation.scale");
                    return EntityValidationError.InvalidDecimalSpec;
                }
                if (scale_val > precision_val or precision_val < 1 or precision_val > 38) {
                    const path = try std.fmt.allocPrint(self.allocator, "/fields/{d}/validation", .{i});
                    defer self.allocator.free(path);
                    try self.addError(path, "invalid_decimal_spec", "Decimal precision must be 1..38 and scale <= precision");
                    return EntityValidationError.InvalidDecimalSpec;
                }
            }
        }

        // 4. Index field coverage
        const indexes_val = root.object.get("indexes");
        if (indexes_val) |iv| {
            if (iv == .array) {
                // 9. Max indexes
                if (iv.array.items.len > MAX_INDEXES) {
                    try self.addError("/indexes", "too_many_indexes", "Maximum 32 indexes allowed per definition");
                    return EntityValidationError.TooManyIndexes;
                }
                for (iv.array.items, 0..) |idx_val, idx_i| {
                    if (idx_val != .object) continue;
                    const idx_fields = idx_val.object.get("fields") orelse continue;
                    if (idx_fields != .array) continue;
                    for (idx_fields.array.items) |ifv| {
                        const if_name = switch (ifv) {
                            .string => |s| s,
                            else => continue,
                        };
                        if (!field_names.contains(if_name)) {
                            const path = try std.fmt.allocPrint(self.allocator, "/indexes/{d}/fields", .{idx_i});
                            defer self.allocator.free(path);
                            const msg = try std.fmt.allocPrint(self.allocator, "Index references field '{s}' which does not exist", .{if_name});
                            defer self.allocator.free(msg);
                            try self.addError(path, "index_field_not_queried", msg);
                            return EntityValidationError.IndexFieldNotQueried;
                        }
                        // Verify the field has queried: true
                        // (checked by looking for the field in the fields array)
                        if (!isFieldQueried(fields, if_name)) {
                            const path = try std.fmt.allocPrint(self.allocator, "/indexes/{d}/fields", .{idx_i});
                            defer self.allocator.free(path);
                            const msg = try std.fmt.allocPrint(self.allocator, "Index references field '{s}' which is not queried", .{if_name});
                            defer self.allocator.free(msg);
                            try self.addError(path, "index_field_not_queried", msg);
                            return EntityValidationError.IndexFieldNotQueried;
                        }
                    }
                }
            }
        }

        // 5. FK field coverage
        const fks_val = root.object.get("foreign_keys");
        if (fks_val) |fv| {
            if (fv == .array) {
                // 10. Max foreign keys
                if (fv.array.items.len > MAX_FOREIGN_KEYS) {
                    try self.addError("/foreign_keys", "too_many_foreign_keys", "Maximum 16 foreign keys allowed per definition");
                    return EntityValidationError.TooManyForeignKeys;
                }
                for (fv.array.items, 0..) |fk_val, fk_i| {
                    if (fk_val != .object) continue;
                    const fk_fields = fk_val.object.get("fields") orelse continue;
                    if (fk_fields != .array) continue;
                    for (fk_fields.array.items) |ffv| {
                        const ff_name = switch (ffv) {
                            .string => |s| s,
                            else => continue,
                        };
                        if (!field_names.contains(ff_name)) {
                            const path = try std.fmt.allocPrint(self.allocator, "/foreign_keys/{d}/fields", .{fk_i});
                            defer self.allocator.free(path);
                            const msg = try std.fmt.allocPrint(self.allocator, "FK references field '{s}' which does not exist", .{ff_name});
                            defer self.allocator.free(msg);
                            try self.addError(path, "fk_field_not_queried", msg);
                            return EntityValidationError.FKFieldNotQueried;
                        }
                        if (!isFieldQueried(fields, ff_name)) {
                            const path = try std.fmt.allocPrint(self.allocator, "/foreign_keys/{d}/fields", .{fk_i});
                            defer self.allocator.free(path);
                            const msg = try std.fmt.allocPrint(self.allocator, "FK references field '{s}' which is not queried", .{ff_name});
                            defer self.allocator.free(msg);
                            try self.addError(path, "fk_field_not_queried", msg);
                            return EntityValidationError.FKFieldNotQueried;
                        }
                    }
                    // 11. Self-referential FK check
                    const target = fk_val.object.get("target_entity") orelse continue;
                    const target_name = switch (target) {
                        .string => |s| s,
                        else => continue,
                    };
                    if (std.mem.eql(u8, target_name, entity_name)) {
                        const path = try std.fmt.allocPrint(self.allocator, "/foreign_keys/{d}/target_entity", .{fk_i});
                        defer self.allocator.free(path);
                        try self.addError(path, "self_referential_fk", "Self-referential FK is not supported in Phase 1");
                        return EntityValidationError.SelfReferentialFK;
                    }
                }
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_NAME_LEN) return false;
    // First character must be lowercase a-z
    if (name[0] < 'a' or name[0] > 'z') return false;
    // Remaining characters: lowercase a-z, digits, underscore
    for (name[1..]) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
        if (!ok) return false;
    }
    return true;
}

fn parseFieldType(str: []const u8) ?FieldType {
    if (std.mem.eql(u8, str, "text")) return .text;
    if (std.mem.eql(u8, str, "integer")) return .integer;
    if (std.mem.eql(u8, str, "decimal")) return .decimal;
    if (std.mem.eql(u8, str, "boolean")) return .boolean;
    if (std.mem.eql(u8, str, "date")) return .date;
    if (std.mem.eql(u8, str, "timestamp")) return .timestamp;
    if (std.mem.eql(u8, str, "uuid")) return .uuid;
    if (std.mem.eql(u8, str, "enum")) return .enum_type;
    if (std.mem.eql(u8, str, "json")) return .json;
    return null;
}

fn isFieldQueried(fields: []const std.json.Value, field_name: []const u8) bool {
    for (fields) |f| {
        if (f != .object) continue;
        const name_val = f.object.get("name") orelse continue;
        const name = switch (name_val) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, name, field_name)) {
            const queried = f.object.get("queried") orelse continue;
            return switch (queried) {
                .bool => |b| b,
                else => false,
            };
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "isValidName accepts valid names" {
    try std.testing.expect(isValidName("customer"));
    try std.testing.expect(isValidName("order_item"));
    try std.testing.expect(isValidName("x1"));
    try std.testing.expect(isValidName("a"));
}

test "isValidName rejects invalid names" {
    try std.testing.expect(!isValidName(""));
    try std.testing.expect(!isValidName("Customer")); // uppercase
    try std.testing.expect(!isValidName("1abc")); // starts with digit
    try std.testing.expect(!isValidName("my-field")); // hyphen
    try std.testing.expect(!isValidName("_leading")); // starts with underscore
}

test "validateDefinition accepts a valid definition" {
    const json =
        \\{
        \\  "name": "customer",
        \\  "display_name": "Customer",
        \\  "version": 1,
        \\  "fields": [
        \\    {"name": "email", "display_name": "Email", "type": "text", "required": true, "queried": true},
        \\    {"name": "age", "display_name": "Age", "type": "integer", "queried": true},
        \\    {"name": "notes", "display_name": "Notes", "type": "json"}
        \\  ]
        \\}
    ;
    var v = Validator.init(std.testing.allocator);
    defer v.deinit();
    try v.validateDefinition(json);
    try std.testing.expectEqual(@as(usize, 0), v.lastErrors().len);
}

test "validateDefinition rejects queried+json field" {
    const json =
        \\{
        \\  "name": "bad_entity",
        \\  "display_name": "Bad",
        \\  "version": 1,
        \\  "fields": [
        \\    {"name": "data", "display_name": "Data", "type": "json", "queried": true}
        \\  ]
        \\}
    ;
    var v = Validator.init(std.testing.allocator);
    defer v.deinit();
    const result = v.validateDefinition(json);
    try std.testing.expect(result == EntityValidationError.FieldQueriedAndJson);
    try std.testing.expectEqual(@as(usize, 1), v.lastErrors().len);
    try std.testing.expectEqualStrings("queried_and_json_exclusion", v.lastErrors()[0].constraint);
}

test "validateDefinition rejects duplicate field names" {
    const json =
        \\{
        \\  "name": "dup_fields",
        \\  "display_name": "Dup",
        \\  "version": 1,
        \\  "fields": [
        \\    {"name": "email", "display_name": "Email", "type": "text"},
        \\    {"name": "email", "display_name": "Email 2", "type": "text"}
        \\  ]
        \\}
    ;
    var v = Validator.init(std.testing.allocator);
    defer v.deinit();
    const result = v.validateDefinition(json);
    try std.testing.expect(result == EntityValidationError.FieldNameConflict);
}

test "validateDefinition rejects missing enum values" {
    const json =
        \\{
        \\  "name": "with_enum",
        \\  "display_name": "Enum",
        \\  "version": 1,
        \\  "fields": [
        \\    {"name": "status", "display_name": "Status", "type": "enum"}
        \\  ]
        \\}
    ;
    var v = Validator.init(std.testing.allocator);
    defer v.deinit();
    const result = v.validateDefinition(json);
    try std.testing.expect(result == EntityValidationError.MissingEnumValues);
}

test "validateDefinition rejects invalid decimal spec" {
    const json =
        \\{
        \\  "name": "with_decimal",
        \\  "display_name": "Decimal",
        \\  "version": 1,
        \\  "fields": [
        \\    {"name": "price", "display_name": "Price", "type": "decimal", "validation": {"precision": 10}}
        \\  ]
        \\}
    ;
    var v = Validator.init(std.testing.allocator);
    defer v.deinit();
    const result = v.validateDefinition(json);
    try std.testing.expect(result == EntityValidationError.InvalidDecimalSpec);
}

test "validateDefinition rejects too many fields" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try buf.appendSlice(
        \\{"name":"big","display_name":"Big","version":1,"fields":[
    );
    for (0..65) |i| {
        if (i > 0) try buf.append(',');
        try std.fmt.format(buf.writer(), "{{\"name\":\"f{d}\",\"display_name\":\"F{d}\",\"type\":\"text\"}}", .{ i, i });
    }
    try buf.appendSlice("]}");

    var v = Validator.init(std.testing.allocator);
    defer v.deinit();
    const result = v.validateDefinition(buf.items);
    try std.testing.expect(result == EntityValidationError.TooManyFields);
}

test "validateDefinition rejects invalid entity name" {
    const json =
        \\{
        \\  "name": "My Entity!",
        \\  "display_name": "Bad Name",
        \\  "version": 1,
        \\  "fields": [
        \\    {"name": "x", "display_name": "X", "type": "text"}
        \\  ]
        \\}
    ;
    var v = Validator.init(std.testing.allocator);
    defer v.deinit();
    const result = v.validateDefinition(json);
    try std.testing.expect(result == EntityValidationError.InvalidNameFormat);
}
