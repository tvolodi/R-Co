//! Entity definition validation — EXP-201
//!
//! Pure validation of entity definition JSON schemas. Checks all rules
//! specified in the design artefact: name format, field uniqueness,
//! queried+json exclusion, index coverage, FK coverage, enum/decimal
//! validation, and cardinality limits.
//!
//! ISS-0160 / GH #481 adds the second, previously-absent half: validation of
//! entity RECORDS (instances) against the definition that governs them, via
//! `validateRecordPayload`. Everything above `validateDefinition` concerns the
//! schema; everything under "Record payload validation" concerns the data.
//!
//! Design artefact: src/design/entities.md (Validation rules section)

const std = @import("std");
// NOTE: this file deliberately does NOT import mod.zig. It never used any
// declaration from it, and staying free of that import keeps validator.zig
// self-contained enough to serve as its own addTest root (build.zig
// `entities_validator_tests`) — mod.zig transitively reaches
// ../repository/canonicaliser.zig, which escapes the src/entities/ module
// path and cannot be a test root at all. See ISS-0160 / GH #481.
// ISS-0160 / GH #481: reuse the shared JSON Schema validator rather than
// growing a second one here. `json_schema` is a named module (build.zig) for
// exactly this reason — src/tools/json_schema.zig is outside the entities
// module path and cannot be reached by relative @import.
const json_schema = @import("json_schema");

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
            .errors = std.ArrayList(ValidationError).empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Validator) void {
        for (self.errors.items) |e| {
            self.allocator.free(e.field_path);
            self.allocator.free(e.constraint);
            self.allocator.free(e.message);
        }
        self.errors.deinit(self.allocator);
    }

    pub fn lastErrors(self: *const Validator) []const ValidationError {
        return self.errors.items;
    }

    fn addError(self: *Validator, field_path: []const u8, constraint: []const u8, message: []const u8) !void {
        const fp = try self.allocator.dupe(u8, field_path);
        const ct = try self.allocator.dupe(u8, constraint);
        const msg = try self.allocator.dupe(u8, message);
        try self.errors.append(self.allocator, .{
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
// Record payload validation — EXP-202 (ISS-0160 / GH #481)
//
// `validateDefinition` above validates a SCHEMA. This section validates a
// RECORD against that schema — the half `createRecord` carried as a literal
// `// TODO` while `EntityCommandError.InvalidPayload` sat declared and
// unreachable, so any payload was accepted and durably persisted into the
// event log.
//
// Implementation note: this deliberately does NOT hand-roll a second
// constraint engine. The entity definition's `fields` array is translated into
// an equivalent JSON Schema document, and `json_schema.validateCollect`
// (src/tools/json_schema.zig, extended under ISS-0155 / GH #473 with `type`,
// `required`, `properties`, `enum`, `minimum`, `maximum`, `minLength`,
// `maxLength`, and `additionalProperties: false`) does the actual checking —
// the same path `src/event_store/registry.zig::validatePayloadAgainstSchema`
// takes for ES-05.
// ---------------------------------------------------------------------------

/// One record-payload constraint violation, located by an RFC 6901 pointer
/// into the submitted `field_values` document.
///
/// `path` and `actual` are owned by the allocator passed to
/// `validateRecordPayload`; `constraint` is a static string literal.
/// Free a returned slice with `deinitRecordViolations`.
pub const RecordViolation = struct {
    /// RFC 6901 pointer to the failing location, e.g. "/f1". "/" is the root.
    path: []const u8,
    /// The constraint that failed: "required", "type", "enum", "maxLength",
    /// "minimum", "maximum", "additionalProperties", ...
    constraint: []const u8,
    /// The serialised actual value at `path`; "null" when the location is absent.
    actual: []const u8,
};

/// Free a slice returned by `validateRecordPayload`.
pub fn deinitRecordViolations(allocator: std.mem.Allocator, violations: []RecordViolation) void {
    for (violations) |v| {
        allocator.free(v.path);
        allocator.free(v.actual);
    }
    allocator.free(violations);
}

/// Validate an entity record's `field_values` against the entity definition
/// that governs it.
///
/// Returns an allocator-owned slice of violations — EMPTY when the payload
/// conforms. A non-conforming payload is never an error return; only a genuine
/// fault (unparseable definition, OOM) is. That mirrors
/// `registry.validatePayloadAgainstSchema`'s contract and lets the caller
/// report every failure at once rather than only the first.
///
/// Enforced, derived from the definition's `fields` array:
///   - presence   — every field with `"required": true` must be present
///   - type       — each field's declared `type` mapped to its JSON counterpart
///   - enum       — membership in `validation.values` for `type: "enum"`
///   - maxLength  — `validation.max_length` for string-valued fields
///   - minimum/maximum — `validation.min_value` / `max_value` for numerics
///   - unknown fields — any key absent from the definition is rejected
///
/// A definition with no `fields` array imposes no constraints (the payload is
/// only required to be a JSON object), matching how an empty schema behaves in
/// `validatePayloadAgainstSchema`.
pub fn validateRecordPayload(
    allocator: std.mem.Allocator,
    definition_json: []const u8,
    field_values: []const u8,
) EntityValidationError![]RecordViolation {
    // Everything built for the translated schema lives and dies in this arena;
    // only the returned violations are copied out to `allocator`.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const parsed_def = std.json.parseFromSlice(
        std.json.Value,
        aa,
        definition_json,
        .{ .allocate = .alloc_always },
    ) catch return EntityValidationError.OutOfMemory;

    const parsed_payload = std.json.parseFromSlice(
        std.json.Value,
        aa,
        field_values,
        .{ .allocate = .alloc_always },
    ) catch {
        // Unparseable field_values is a payload failure, not a definition
        // fault — report it as a root-level type violation so the caller
        // rejects it the same way it rejects any other bad payload.
        return singleViolation(allocator, "/", "type", field_values);
    };

    // A record's field_values must be a JSON object; anything else (array,
    // scalar, null) cannot carry named fields at all.
    if (parsed_payload.value != .object) {
        return singleViolation(allocator, "/", "type", field_values);
    }

    const schema = buildRecordSchema(aa, parsed_def.value) catch
        return EntityValidationError.OutOfMemory;

    const violations = json_schema.validateCollect(aa, parsed_payload.value, schema) catch
        return EntityValidationError.OutOfMemory;

    // Copy out of the arena into caller-owned memory.
    const out = allocator.alloc(RecordViolation, violations.len) catch
        return EntityValidationError.OutOfMemory;
    var filled: usize = 0;
    errdefer {
        deinitRecordViolations(allocator, out[0..filled]);
        allocator.free(out[filled..]);
    }
    for (violations, 0..) |v, i| {
        // json_schema renders the document root as ""; render it as "/" here
        // for consistency with ValidationError.field_path elsewhere in this file.
        const path_src = if (v.path.len == 0) "/" else v.path;
        const path = allocator.dupe(u8, path_src) catch return EntityValidationError.OutOfMemory;
        errdefer allocator.free(path);
        const actual = allocator.dupe(u8, v.actual) catch return EntityValidationError.OutOfMemory;
        out[i] = .{ .path = path, .constraint = v.constraint, .actual = actual };
        filled = i + 1;
    }
    return out;
}

/// Allocate a one-element violation slice (used for whole-document failures).
fn singleViolation(
    allocator: std.mem.Allocator,
    path: []const u8,
    constraint: []const u8,
    actual: []const u8,
) EntityValidationError![]RecordViolation {
    const out = allocator.alloc(RecordViolation, 1) catch return EntityValidationError.OutOfMemory;
    errdefer allocator.free(out);
    const p = allocator.dupe(u8, path) catch return EntityValidationError.OutOfMemory;
    errdefer allocator.free(p);
    const a = allocator.dupe(u8, actual) catch return EntityValidationError.OutOfMemory;
    out[0] = .{ .path = p, .constraint = constraint, .actual = a };
    return out;
}

/// Translate an entity definition document into the equivalent JSON Schema
/// object. Everything allocated belongs to `aa` (an arena in the caller).
fn buildRecordSchema(aa: std.mem.Allocator, def: std.json.Value) !std.json.Value {
    var schema = try std.json.ObjectMap.init(aa, &.{}, &.{});
    try schema.put(aa, "type", .{ .string = "object" });

    if (def != .object) return .{ .object = schema };
    const fields_val = def.object.get("fields") orelse return .{ .object = schema };
    if (fields_val != .array) return .{ .object = schema };

    var properties = try std.json.ObjectMap.init(aa, &.{}, &.{});
    // std.json.Array is the *Managed* ArrayList variant (it carries its own
    // allocator), unlike ObjectMap above — hence init(aa) / append(item).
    var required = std.json.Array.init(aa);

    for (fields_val.array.items) |field_val| {
        if (field_val != .object) continue;
        const field_obj = field_val.object;

        const name_val = field_obj.get("name") orelse continue;
        if (name_val != .string) continue;
        const fname = name_val.string;

        const type_val = field_obj.get("type") orelse continue;
        if (type_val != .string) continue;
        const ftype = parseFieldType(type_val.string) orelse continue;

        const sub = try buildFieldSchema(aa, ftype, field_obj);
        try properties.put(aa, fname, sub);

        if (field_obj.get("required")) |req| {
            if (req == .bool and req.bool) try required.append(.{ .string = fname });
        }
    }

    try schema.put(aa, "properties", .{ .object = properties });
    if (required.items.len > 0) try schema.put(aa, "required", .{ .array = required });
    // A field absent from the definition has no declared type, no storage
    // column, and no consumer contract — reject it rather than persisting it.
    try schema.put(aa, "additionalProperties", .{ .bool = false });

    return .{ .object = schema };
}

/// Build the JSON Schema subschema for one declared field.
fn buildFieldSchema(
    aa: std.mem.Allocator,
    ftype: FieldType,
    field_obj: std.json.ObjectMap,
) !std.json.Value {
    var sub = try std.json.ObjectMap.init(aa, &.{}, &.{});

    // `json` fields are free-form by definition — no `type` constraint at all,
    // so any JSON value is admitted there.
    switch (ftype) {
        .text, .date, .timestamp, .uuid => try sub.put(aa, "type", .{ .string = "string" }),
        .integer => try sub.put(aa, "type", .{ .string = "integer" }),
        .decimal => try sub.put(aa, "type", .{ .string = "number" }),
        .boolean => try sub.put(aa, "type", .{ .string = "boolean" }),
        // enum members are strings in every definition this subsystem accepts;
        // the `enum` keyword below narrows them to the declared set.
        .enum_type => try sub.put(aa, "type", .{ .string = "string" }),
        .json => {},
    }

    const validation_val = field_obj.get("validation") orelse return .{ .object = sub };
    if (validation_val != .object) return .{ .object = sub };
    const v = validation_val.object;

    if (ftype == .enum_type) {
        if (v.get("values")) |vals| {
            if (vals == .array and vals.array.items.len > 0) {
                var allowed = std.json.Array.init(aa);
                for (vals.array.items) |item| try allowed.append(item);
                try sub.put(aa, "enum", .{ .array = allowed });
            }
        }
    }

    if (v.get("max_length")) |ml| {
        if (ml == .integer) try sub.put(aa, "maxLength", ml);
    }
    if (v.get("min_value")) |mv| {
        if (mv == .integer or mv == .float) try sub.put(aa, "minimum", mv);
    }
    if (v.get("max_value")) |mv| {
        if (mv == .integer or mv == .float) try sub.put(aa, "maximum", mv);
    }

    return .{ .object = sub };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// ── Record payload validation (ISS-0160 / GH #481) ──────────────────────────

/// The definition used by the record-payload tests below: one required text
/// field, one optional integer, one constrained enum, one free-form json.
const RECORD_TEST_DEF =
    \\{
    \\  "name": "widget",
    \\  "display_name": "Widget",
    \\  "fields": [
    \\    {"name": "sku", "type": "text", "required": true, "validation": {"max_length": 8}},
    \\    {"name": "qty", "type": "integer", "validation": {"min_value": 0, "max_value": 100}},
    \\    {"name": "status", "type": "enum", "validation": {"values": ["new", "used"]}},
    \\    {"name": "extra", "type": "json"}
    \\  ]
    \\}
;

/// Assert a payload conforms (produces zero violations).
fn expectRecordAccepted(def: []const u8, payload: []const u8) !void {
    const v = try validateRecordPayload(std.testing.allocator, def, payload);
    defer deinitRecordViolations(std.testing.allocator, v);
    if (v.len != 0) {
        std.debug.print("expected acceptance, got {d} violation(s):\n", .{v.len});
        for (v) |x| std.debug.print("  {s} {s} {s}\n", .{ x.path, x.constraint, x.actual });
    }
    try std.testing.expectEqual(@as(usize, 0), v.len);
}

/// Assert a payload is rejected, and that `constraint` is among the reasons.
fn expectRecordRejected(def: []const u8, payload: []const u8, constraint: []const u8) !void {
    const v = try validateRecordPayload(std.testing.allocator, def, payload);
    defer deinitRecordViolations(std.testing.allocator, v);
    try std.testing.expect(v.len > 0);
    for (v) |x| {
        if (std.mem.eql(u8, x.constraint, constraint)) return;
    }
    std.debug.print("expected a '{s}' violation, got:\n", .{constraint});
    for (v) |x| std.debug.print("  {s} {s} {s}\n", .{ x.path, x.constraint, x.actual });
    return error.TestUnexpectedResult;
}

test "validateRecordPayload accepts a conforming payload" {
    try expectRecordAccepted(RECORD_TEST_DEF,
        \\{"sku": "ZIG-123", "qty": 5, "status": "new", "extra": {"a": [1, 2]}}
    );
}

test "validateRecordPayload accepts a payload omitting only optional fields" {
    // `sku` is the sole required field; everything else may be absent.
    try expectRecordAccepted(RECORD_TEST_DEF,
        \\{"sku": "OK"}
    );
}

test "validateRecordPayload rejects a missing required field" {
    // The exact case EXP-202's integration block asserts, and the case that
    // silently passed while createRecord carried the TODO.
    try expectRecordRejected(RECORD_TEST_DEF, "{}", "required");
}

test "validateRecordPayload rejects a wrong-typed field" {
    try expectRecordRejected(RECORD_TEST_DEF,
        \\{"sku": "OK", "qty": "not-a-number"}
    , "type");
}

test "validateRecordPayload rejects a value outside the declared enum set" {
    try expectRecordRejected(RECORD_TEST_DEF,
        \\{"sku": "OK", "status": "refurbished"}
    , "enum");
}

test "validateRecordPayload rejects a field absent from the definition" {
    try expectRecordRejected(RECORD_TEST_DEF,
        \\{"sku": "OK", "undeclared": 1}
    , "additionalProperties");
}

test "validateRecordPayload enforces validation.max_length and numeric bounds" {
    try expectRecordRejected(RECORD_TEST_DEF,
        \\{"sku": "WAY-TOO-LONG"}
    , "maxLength");
    try expectRecordRejected(RECORD_TEST_DEF,
        \\{"sku": "OK", "qty": 1000}
    , "maximum");
    try expectRecordRejected(RECORD_TEST_DEF,
        \\{"sku": "OK", "qty": -1}
    , "minimum");
}

test "validateRecordPayload rejects a payload that is not a JSON object" {
    try expectRecordRejected(RECORD_TEST_DEF, "[]", "type");
    try expectRecordRejected(RECORD_TEST_DEF, "\"scalar\"", "type");
    // Malformed JSON is a payload failure, not a definition fault.
    try expectRecordRejected(RECORD_TEST_DEF, "{not json", "type");
}

test "validateRecordPayload reports every violation, not just the first" {
    const v = try validateRecordPayload(std.testing.allocator, RECORD_TEST_DEF,
        \\{"qty": "bad", "nope": 1}
    );
    defer deinitRecordViolations(std.testing.allocator, v);
    // missing required `sku`, wrong-typed `qty`, undeclared `nope`.
    try std.testing.expect(v.len >= 3);
}

test "validateRecordPayload treats a definition with no fields as unconstrained" {
    try expectRecordAccepted(
        \\{"name": "freeform", "display_name": "Freeform"}
    ,
        \\{"anything": "goes"}
    );
}

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
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator,
        \\{"name":"big","display_name":"Big","version":1,"fields":[
    );
    for (0..65) |i| {
        if (i > 0) try buf.append(allocator, ',');
        const field_json = try std.fmt.allocPrint(allocator, "{{\"name\":\"f{d}\",\"display_name\":\"F{d}\",\"type\":\"text\"}}", .{ i, i });
        defer allocator.free(field_json);
        try buf.appendSlice(allocator, field_json);
    }
    try buf.appendSlice(allocator, "]}");

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
