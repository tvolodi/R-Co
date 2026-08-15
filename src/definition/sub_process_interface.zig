//! SPC-01 / SPC-02 — SUB_PROCESS `interface` contract.
//!
//! Data model for the optional `interface` attribute on SUB_PROCESS nodes
//! (`inputs`/`outputs` of `{name, json_schema, required}`), plus:
//!   - SPC-02 definition-time parsing + schema well-formedness validation
//!     (invoked from `src/definition/graph.zig` `checkSubProcess`, PD-05).
//!   - SPC-01 runtime helpers invoked from the engine SUB_PROCESS
//!     activation / completion path (`src/engine/instance.zig`).
//!
//! A node that omits `interface` behaves exactly as EXT-05 (full variable map
//! copy-out / full map merge-back). The `interface` lives inside the node's
//! attributes JSONB — no schema migration is required.
//!
//! Pure module: no I/O, no DB, no logging, no clock reads.
//!
//! Design artefact: `src/design/spc-01-sub-process-interface-contract.md`
const std = @import("std");
const json_schema = @import("json_schema");

/// Maximum declared entries per direction (inputs/outputs). Bounds parse-time
/// allocations; far above any realistic interface.
pub const MAX_ENTRIES_PER_DIRECTION: usize = 256;

// ---------------------------------------------------------------------------
// Error set
// ---------------------------------------------------------------------------

/// All SPC-01/SPC-02 failure modes for the SUB_PROCESS `interface` contract.
/// The definition-time variants map to the HTTP 422 codes in the design; the
/// runtime variants map to the four EE-10 `EXECUTION_ERROR` reason codes.
pub const SubProcessInterfaceError = error{
    OutOfMemory,

    // SPC-02 — definition-time (HTTP 422)
    SubProcessInterfaceNotObject,
    SubProcessInterfaceInputsNotArray,
    SubProcessInterfaceOutputsNotArray,
    SubProcessInterfaceEntryInvalid,
    SubProcessInterfaceSchemaInvalid,
    SubProcessInterfaceDuplicateName,

    // SPC-01 — runtime (EE-10)
    SubProcessMissingRequiredInput,
    SubProcessInputSchemaViolation,
    SubProcessMissingRequiredOutput,
    SubProcessOutputSchemaViolation,
};

// ---------------------------------------------------------------------------
// Data model
// ---------------------------------------------------------------------------

/// One declared input or output.
pub const InterfaceEntry = struct {
    /// Variable key. Non-empty, unique within its direction.
    name: []const u8,
    /// Well-formed JSON Schema object (SPC-02). Constraints applied at
    /// runtime (SPC-01).
    json_schema: std.json.Value,
    /// Absent `required` is treated as false (PLC-03 OQ-3).
    required: bool,
};

/// The parsed `interface` object. Owns all memory below it (free with
/// `deinit`).
pub const SubProcessInterface = struct {
    inputs: []InterfaceEntry,
    outputs: []InterfaceEntry,

    pub fn deinit(self: SubProcessInterface, allocator: std.mem.Allocator) void {
        freeEntries(allocator, self.inputs);
        freeEntries(allocator, self.outputs);
    }
};

fn freeEntries(allocator: std.mem.Allocator, entries: []InterfaceEntry) void {
    for (entries) |e| {
        allocator.free(e.name);
        freeJsonValueSafe(allocator, e.json_schema);
    }
    allocator.free(entries);
}

// ---------------------------------------------------------------------------
// InterfaceViolation — SPC-02 structured detail (HTTP 422 lists ALL entries)
// ---------------------------------------------------------------------------

/// One definition-time interface violation. `code` and `direction` are static
/// string literals; `name`, `pointer`, and `message` are allocator-owned (free
/// the contents with `freeInterfaceViolations`).
pub const InterfaceViolation = struct {
    /// One of the SPC-02 HTTP 422 codes (static string).
    code: []const u8,
    /// "inputs" | "outputs" | "" (static string; "" when the violation is not
    /// entry-scoped, e.g. `interface` is not an object).
    direction: []const u8,
    /// Entry name, or "" when none applies (allocator-owned).
    name: []const u8,
    /// RFC 6901 pointer to the offending field within `interface`
    /// (allocator-owned).
    pointer: []const u8,
    /// Human-readable detail (allocator-owned).
    message: []const u8,
};

/// Free the contents of an `InterfaceViolation` slice. The slice itself is
/// owned by the caller's `std.ArrayList` and must be freed separately.
pub fn freeInterfaceViolations(allocator: std.mem.Allocator, items: []const InterfaceViolation) void {
    for (items) |iv| {
        allocator.free(iv.name);
        allocator.free(iv.pointer);
        allocator.free(iv.message);
    }
}

// ---------------------------------------------------------------------------
// SPC-02 — parse + validate
// ---------------------------------------------------------------------------

/// Parse + validate the `interface` attribute value (SPC-02). Returns the
/// parsed interface, or the FIRST definition-time error. Use
/// `collectInterfaceViolations` when every offending entry must be reported
/// (HTTP 422 lists all of them).
///
/// The returned `SubProcessInterface` owns its memory; free with `deinit`.
pub fn parseInterface(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
) SubProcessInterfaceError!SubProcessInterface {
    var violations: std.ArrayList(InterfaceViolation) = .empty;
    defer {
        freeInterfaceViolations(allocator, violations.items);
        violations.deinit(allocator);
    }
    try collectInterfaceViolations(allocator, raw, &violations);
    if (violations.items.len > 0) {
        return codeToError(violations.items[0].code);
    }
    return buildInterface(allocator, raw);
}

/// Collect EVERY SPC-02 definition-time violation for the `interface` value.
/// On success (no violations) `out` stays empty.
pub fn collectInterfaceViolations(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
    out: *std.ArrayList(InterfaceViolation),
) error{OutOfMemory}!void {
    if (raw != .object) {
        try pushViolation(
            allocator,
            out,
            "SUB_PROCESS_INTERFACE_NOT_OBJECT",
            "",
            "",
            "/interface",
            "interface attribute must be a JSON object",
            .{},
        );
        return;
    }
    const obj = raw.object;

    // Missing `inputs`/`outputs` keys are treated as empty lists (absent
    // inputs → empty child map; absent outputs → no-op merge), matching the
    // design's `SUB_PROCESS_INTERFACE_*_NOT_ARRAY` wording which names only
    // the "present but not an array" case as a violation.
    if (obj.get("inputs")) |inputs_val| {
        if (inputs_val != .array) {
            try pushViolation(
                allocator,
                out,
                "SUB_PROCESS_INTERFACE_INPUTS_NOT_ARRAY",
                "inputs",
                "",
                "/interface/inputs",
                "interface.inputs must be an array",
                .{},
            );
        } else {
            try collectDirection(allocator, out, "inputs", inputs_val.array, "/interface/inputs");
        }
    }

    if (obj.get("outputs")) |outputs_val| {
        if (outputs_val != .array) {
            try pushViolation(
                allocator,
                out,
                "SUB_PROCESS_INTERFACE_OUTPUTS_NOT_ARRAY",
                "outputs",
                "",
                "/interface/outputs",
                "interface.outputs must be an array",
                .{},
            );
        } else {
            try collectDirection(allocator, out, "outputs", outputs_val.array, "/interface/outputs");
        }
    }
}

/// Validate one direction's entries: shape, name, required, json_schema
/// well-formedness (SPC-02), and duplicate names.
fn collectDirection(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(InterfaceViolation),
    direction: []const u8,
    items: std.json.Array,
    base_pointer: []const u8,
) error{OutOfMemory}!void {
    if (items.items.len > MAX_ENTRIES_PER_DIRECTION) {
        try pushViolation(
            allocator,
            out,
            "SUB_PROCESS_INTERFACE_ENTRY_INVALID",
            direction,
            "",
            base_pointer,
            "too many entries (max {d})",
            .{MAX_ENTRIES_PER_DIRECTION},
        );
        return;
    }

    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (items.items, 0..) |entry, i| {
        const pointer = std.fmt.allocPrint(allocator, "{s}/{d}", .{ base_pointer, i }) catch
            return error.OutOfMemory;
        defer allocator.free(pointer);

        if (entry != .object) {
            try pushViolation(
                allocator,
                out,
                "SUB_PROCESS_INTERFACE_ENTRY_INVALID",
                direction,
                "",
                pointer,
                "entry must be a JSON object",
                .{},
            );
            continue;
        }
        const eobj = entry.object;

        const name_val = eobj.get("name");
        const name_ok = if (name_val) |nv| (nv == .string and nv.string.len > 0) else false;
        if (!name_ok) {
            try pushViolation(
                allocator,
                out,
                "SUB_PROCESS_INTERFACE_ENTRY_INVALID",
                direction,
                "",
                pointer,
                "entry 'name' must be a non-empty string",
                .{},
            );
            continue;
        }
        const name = name_val.?.string;

        if (seen.contains(name)) {
            try pushViolation(
                allocator,
                out,
                "SUB_PROCESS_INTERFACE_DUPLICATE_NAME",
                direction,
                name,
                pointer,
                "duplicate name '{s}' within {s}",
                .{ name, direction },
            );
            continue;
        }
        try seen.put(name, {});

        if (eobj.get("required")) |req_val| {
            if (req_val != .bool) {
                try pushViolation(
                    allocator,
                    out,
                    "SUB_PROCESS_INTERFACE_ENTRY_INVALID",
                    direction,
                    name,
                    pointer,
                    "'required' must be a boolean",
                    .{},
                );
                continue;
            }
        }

        const schema_val = eobj.get("json_schema");
        if (schema_val == null) {
            try pushViolation(
                allocator,
                out,
                "SUB_PROCESS_INTERFACE_ENTRY_INVALID",
                direction,
                name,
                pointer,
                "entry is missing 'json_schema'",
                .{},
            );
            continue;
        }
        json_schema.validateSchemaShape(allocator, schema_val.?, 0) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MalformedSchema, error.SchemaTooDeep => {
                try pushViolation(
                    allocator,
                    out,
                    "SUB_PROCESS_INTERFACE_SCHEMA_INVALID",
                    direction,
                    name,
                    pointer,
                    "json_schema is not a well-formed JSON Schema object",
                    .{},
                );
                continue;
            },
        };
    }
}

/// Build the parsed interface from a value that already passed
/// `collectInterfaceViolations` (so every entry is well-formed).
fn buildInterface(
    allocator: std.mem.Allocator,
    raw: std.json.Value,
) SubProcessInterfaceError!SubProcessInterface {
    var inputs: std.ArrayList(InterfaceEntry) = .empty;
    errdefer {
        freeEntries(allocator, inputs.items);
        inputs.deinit(allocator);
    }
    var outputs: std.ArrayList(InterfaceEntry) = .empty;
    errdefer {
        freeEntries(allocator, outputs.items);
        outputs.deinit(allocator);
    }

    if (raw != .object) return error.SubProcessInterfaceNotObject;
    const obj = raw.object;

    if (obj.get("inputs")) |v| {
        if (v == .array) try collectEntries(allocator, &inputs, v.array);
    }
    if (obj.get("outputs")) |v| {
        if (v == .array) try collectEntries(allocator, &outputs, v.array);
    }

    return .{
        .inputs = try inputs.toOwnedSlice(allocator),
        .outputs = try outputs.toOwnedSlice(allocator),
    };
}

fn collectEntries(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(InterfaceEntry),
    items: std.json.Array,
) SubProcessInterfaceError!void {
    for (items.items) |entry| {
        if (entry != .object) return error.SubProcessInterfaceEntryInvalid;
        const eobj = entry.object;
        const name = eobj.get("name") orelse return error.SubProcessInterfaceEntryInvalid;
        if (name != .string or name.string.len == 0) return error.SubProcessInterfaceEntryInvalid;
        const schema = eobj.get("json_schema") orelse return error.SubProcessInterfaceEntryInvalid;
        const required = if (eobj.get("required")) |r| (r == .bool and r.bool) else false;

        const name_dup = try allocator.dupe(u8, name.string);
        errdefer allocator.free(name_dup);
        const schema_clone = try cloneJsonValueSafe(allocator, schema);
        errdefer freeJsonValueSafe(allocator, schema_clone);
        try list.append(allocator, .{
            .name = name_dup,
            .json_schema = schema_clone,
            .required = required,
        });
    }
}

/// SPC-02 — schema-of-schemas well-formedness check. Thin wrapper over
/// `src/tools/json_schema.zig`'s `validateSchemaShape` that maps the
/// JSON-Schema module's errors into the SUB_PROCESS interface error set.
pub fn validateSchemaShape(
    allocator: std.mem.Allocator,
    schema: std.json.Value,
    depth: usize,
) SubProcessInterfaceError!void {
    json_schema.validateSchemaShape(allocator, schema, depth) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.MalformedSchema, error.SchemaTooDeep => return error.SubProcessInterfaceSchemaInvalid,
    };
}

fn codeToError(code: []const u8) SubProcessInterfaceError {
    if (std.mem.eql(u8, code, "SUB_PROCESS_INTERFACE_NOT_OBJECT")) return error.SubProcessInterfaceNotObject;
    if (std.mem.eql(u8, code, "SUB_PROCESS_INTERFACE_INPUTS_NOT_ARRAY")) return error.SubProcessInterfaceInputsNotArray;
    if (std.mem.eql(u8, code, "SUB_PROCESS_INTERFACE_OUTPUTS_NOT_ARRAY")) return error.SubProcessInterfaceOutputsNotArray;
    if (std.mem.eql(u8, code, "SUB_PROCESS_INTERFACE_ENTRY_INVALID")) return error.SubProcessInterfaceEntryInvalid;
    if (std.mem.eql(u8, code, "SUB_PROCESS_INTERFACE_SCHEMA_INVALID")) return error.SubProcessInterfaceSchemaInvalid;
    if (std.mem.eql(u8, code, "SUB_PROCESS_INTERFACE_DUPLICATE_NAME")) return error.SubProcessInterfaceDuplicateName;
    return error.SubProcessInterfaceEntryInvalid;
}

/// Append one violation. `code`/`direction` are static literals; `name`,
/// `pointer`, and the formatted `message` are duped into allocator-owned
/// memory (freed by `freeInterfaceViolations`).
fn pushViolation(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(InterfaceViolation),
    code: []const u8,
    direction: []const u8,
    name: []const u8,
    pointer: []const u8,
    comptime fmt_str: []const u8,
    args: anytype,
) error{OutOfMemory}!void {
    const msg = try std.fmt.allocPrint(allocator, fmt_str, args);
    errdefer allocator.free(msg);
    const name_dup = try allocator.dupe(u8, name);
    errdefer allocator.free(name_dup);
    const ptr_dup = try allocator.dupe(u8, pointer);
    errdefer allocator.free(ptr_dup);
    try out.append(allocator, .{
        .code = code,
        .direction = direction,
        .name = name_dup,
        .pointer = ptr_dup,
        .message = msg,
    });
}

// ---------------------------------------------------------------------------
// SPC-01 — runtime helpers
// ---------------------------------------------------------------------------

/// Structured SPC-01 contract violation for the EE-10 `EXECUTION_ERROR`
/// reason. `code` and `constraint` are static literals; `key` and `pointer`
/// are allocator-owned (free with `freeContractViolation`).
pub const ContractViolation = struct {
    /// One of the four SPC-01 runtime codes (static string).
    code: []const u8,
    /// The offending variable key (allocator-owned).
    key: []const u8,
    /// Failing JSON Schema keyword (static; null for missing-key cases).
    constraint: ?[]const u8 = null,
    /// RFC 6901 pointer of the failing location within the value
    /// (allocator-owned; null for missing-key cases).
    pointer: ?[]const u8 = null,
};

pub fn freeContractViolation(allocator: std.mem.Allocator, v: ContractViolation) void {
    allocator.free(v.key);
    if (v.pointer) |p| allocator.free(p);
}

/// SPC-01 activation gate: build the child's initial variable map as the
/// filtered subset of `parent_vars` named in `iface.inputs`.
///
/// - A present input is validated against its `json_schema`; on failure
///   returns `error.SubProcessInputSchemaViolation` (required and optional
///   alike — an optional input the caller supplied must still honour its
///   declared schema). The child MUST NOT be created.
/// - An absent required input returns `error.SubProcessMissingRequiredInput`.
/// - An absent optional input is skipped (not passed to the child).
/// - `iface.inputs == []` yields an empty map, regardless of parent state.
///
/// On success returns an allocator-owned (deep) `ObjectMap`. On error the map
/// is undefined and `violation_out` (if non-null) is populated with the
/// structured reason.
pub fn buildChildInitialMap(
    allocator: std.mem.Allocator,
    parent_vars: std.json.ObjectMap,
    iface: SubProcessInterface,
    violation_out: *?ContractViolation,
) SubProcessInterfaceError!std.json.ObjectMap {
    var result = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        var it = result.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            freeJsonValueSafe(allocator, entry.value_ptr.*);
        }
        result.deinit(allocator);
    }

    for (iface.inputs) |entry| {
        const value = parent_vars.get(entry.name) orelse {
            if (entry.required) {
                violation_out.* = .{
                    .code = "SUB_PROCESS_MISSING_REQUIRED_INPUT",
                    .key = try allocator.dupe(u8, entry.name),
                };
                return error.SubProcessMissingRequiredInput;
            }
            continue;
        };

        const violations = json_schema.validateCollect(allocator, value, entry.json_schema) catch
            return error.OutOfMemory;
        defer json_schema.deinitViolations(allocator, violations);
        if (violations.len > 0) {
            violation_out.* = .{
                .code = "SUB_PROCESS_INPUT_SCHEMA_VIOLATION",
                .key = try allocator.dupe(u8, entry.name),
                .constraint = violations[0].constraint,
                .pointer = try allocator.dupe(u8, violations[0].path),
            };
            return error.SubProcessInputSchemaViolation;
        }

        const key_dup = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(key_dup);
        const val_clone = try cloneJsonValueSafe(allocator, value);
        errdefer freeJsonValueSafe(allocator, val_clone);
        try result.put(allocator, key_dup, val_clone);
    }

    return result;
}

/// SPC-01 — validate a single input value against its declared schema.
/// Returns `error.SubProcessInputSchemaViolation` on the first violation.
pub fn validateInputValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    schema: std.json.Value,
) SubProcessInterfaceError!void {
    const violations = json_schema.validateCollect(allocator, value, schema) catch
        return error.OutOfMemory;
    defer json_schema.deinitViolations(allocator, violations);
    if (violations.len > 0) return error.SubProcessInputSchemaViolation;
}

/// SPC-01 completion gate: build the filtered child-output map as the subset
/// of `child_vars` named in `iface.outputs`.
///
/// - A present output is validated against its `json_schema` BEFORE merge; on
///   failure returns `error.SubProcessOutputSchemaViolation` and the merge is
///   NOT applied (no partial merge).
/// - An absent required output returns `error.SubProcessMissingRequiredOutput`.
/// - An absent optional output is skipped.
/// - `iface.outputs == []` yields an empty map (a no-op merge; the parent
///   still advances).
///
/// On success returns an allocator-owned (deep) `ObjectMap`. On error the map
/// is undefined and `violation_out` (if non-null) is populated.
pub fn selectAndValidateOutputs(
    allocator: std.mem.Allocator,
    child_vars: std.json.ObjectMap,
    iface: SubProcessInterface,
    violation_out: *?ContractViolation,
) SubProcessInterfaceError!std.json.ObjectMap {
    var result = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        var it = result.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            freeJsonValueSafe(allocator, entry.value_ptr.*);
        }
        result.deinit(allocator);
    }

    for (iface.outputs) |entry| {
        const value = child_vars.get(entry.name) orelse {
            if (entry.required) {
                violation_out.* = .{
                    .code = "SUB_PROCESS_MISSING_REQUIRED_OUTPUT",
                    .key = try allocator.dupe(u8, entry.name),
                };
                return error.SubProcessMissingRequiredOutput;
            }
            continue;
        };

        const violations = json_schema.validateCollect(allocator, value, entry.json_schema) catch
            return error.OutOfMemory;
        defer json_schema.deinitViolations(allocator, violations);
        if (violations.len > 0) {
            violation_out.* = .{
                .code = "SUB_PROCESS_OUTPUT_SCHEMA_VIOLATION",
                .key = try allocator.dupe(u8, entry.name),
                .constraint = violations[0].constraint,
                .pointer = try allocator.dupe(u8, violations[0].path),
            };
            return error.SubProcessOutputSchemaViolation;
        }

        const key_dup = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(key_dup);
        const val_clone = try cloneJsonValueSafe(allocator, value);
        errdefer freeJsonValueSafe(allocator, val_clone);
        try result.put(allocator, key_dup, val_clone);
    }

    return result;
}

/// SPC-01 — validate a single output value against its declared schema.
/// Returns `error.SubProcessOutputSchemaViolation` on the first violation.
pub fn validateOutputValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    schema: std.json.Value,
) SubProcessInterfaceError!void {
    const violations = json_schema.validateCollect(allocator, value, schema) catch
        return error.OutOfMemory;
    defer json_schema.deinitViolations(allocator, violations);
    if (violations.len > 0) return error.SubProcessOutputSchemaViolation;
}

// ---------------------------------------------------------------------------
// JSON ownership helpers (mirror src/engine/transition.zig)
// ---------------------------------------------------------------------------

/// Deep-clone a JSON value: duplicates strings and recursively clones
/// arrays/objects (including their keys) so the result shares no memory with
/// the source. Mirrors `transition.zig`'s `cloneJsonValueSafe` (ISS-0601:
/// `std.json.ObjectMap.clone()` is a SHALLOW clone).
fn cloneJsonValueSafe(allocator: std.mem.Allocator, value: std.json.Value) error{OutOfMemory}!std.json.Value {
    return switch (value) {
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var new_arr = std.json.Array.init(allocator);
            errdefer {
                for (new_arr.items) |item| freeJsonValueSafe(allocator, item);
                new_arr.deinit();
            }
            try new_arr.ensureTotalCapacity(arr.items.len);
            for (arr.items) |item| {
                const cloned = try cloneJsonValueSafe(allocator, item);
                new_arr.appendAssumeCapacity(cloned);
            }
            break :blk .{ .array = new_arr };
        },
        .object => |obj| blk: {
            var new_obj = try std.json.ObjectMap.init(allocator, &.{}, &.{});
            errdefer {
                var it = new_obj.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    freeJsonValueSafe(allocator, entry.value_ptr.*);
                }
                new_obj.deinit(allocator);
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key_copy);
                const cloned_value = try cloneJsonValueSafe(allocator, entry.value_ptr.*);
                errdefer freeJsonValueSafe(allocator, cloned_value);
                try new_obj.put(allocator, key_copy, cloned_value);
            }
            break :blk .{ .object = new_obj };
        },
        else => value,
    };
}

/// Free a JSON value that was deep-cloned (or otherwise allocator-owned).
fn freeJsonValueSafe(allocator: std.mem.Allocator, value: std.json.Value) void {
    var mutable_value = value;
    switch (mutable_value) {
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        .array => |*arr| {
            for (arr.items) |item| freeJsonValueSafe(allocator, item);
            arr.deinit();
        },
        .object => |*obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValueSafe(allocator, entry.value_ptr.*);
            }
            obj.deinit(allocator);
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Unit tests — SPC-01 / SPC-02
// ---------------------------------------------------------------------------

const talloc = std.testing.allocator;

/// Parse `text` into a JSON value (caller owns via `deinit`).
fn parseValue(text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, talloc, text, .{ .allocate = .alloc_always });
}

/// Parse an interface JSON document and run `parseInterface`.
fn parseIface(text: []const u8) !SubProcessInterface {
    var parsed = try parseValue(text);
    defer parsed.deinit();
    return parseInterface(talloc, parsed.value);
}

/// Parse an interface document and run `collectInterfaceViolations`,
/// returning the codes in order (caller frees each code's list).
fn collectCodes(text: []const u8) ![]const []const u8 {
    var parsed = try parseValue(text);
    defer parsed.deinit();
    var out: std.ArrayList(InterfaceViolation) = .empty;
    defer {
        freeInterfaceViolations(talloc, out.items);
        out.deinit(talloc);
    }
    try collectInterfaceViolations(talloc, parsed.value, &out);
    const codes = try talloc.alloc([]const u8, out.items.len);
    for (out.items, 0..) |iv, i| {
        codes[i] = iv.code;
    }
    return codes;
}

test "SPC-02: well-formed interface parses" {
    const iface = try parseIface(
        \\{"inputs":[{"name":"customer_id","json_schema":{"type":"string"},"required":true}],"outputs":[{"name":"order_id","json_schema":{"type":"string"},"required":true}]}
    );
    defer iface.deinit(talloc);
    try std.testing.expectEqual(@as(usize, 1), iface.inputs.len);
    try std.testing.expectEqual(@as(usize, 1), iface.outputs.len);
    try std.testing.expectEqualStrings("customer_id", iface.inputs[0].name);
    try std.testing.expect(iface.inputs[0].required);
    try std.testing.expectEqualStrings("order_id", iface.outputs[0].name);
    try std.testing.expect(iface.outputs[0].required);
}

test "SPC-02: absent required defaults to false (PLC-03 OQ-3)" {
    const iface = try parseIface(
        \\{"inputs":[{"name":"amount","json_schema":{"type":"number"}}]}
    );
    defer iface.deinit(talloc);
    try std.testing.expectEqual(@as(usize, 1), iface.inputs.len);
    try std.testing.expect(!iface.inputs[0].required);
}

test "SPC-02: absent inputs/outputs keys are treated as empty lists" {
    const iface = try parseIface("{\"inputs\":[]}");
    defer iface.deinit(talloc);
    try std.testing.expectEqual(@as(usize, 0), iface.inputs.len);
    try std.testing.expectEqual(@as(usize, 0), iface.outputs.len);
}

test "SPC-02: interface that is not an object → NOT_OBJECT" {
    var parsed = try parseValue("\"nope\"");
    defer parsed.deinit();
    try std.testing.expectError(
        error.SubProcessInterfaceNotObject,
        parseInterface(talloc, parsed.value),
    );
}

test "SPC-02: inputs not an array → INPUTS_NOT_ARRAY; outputs not an array → OUTPUTS_NOT_ARRAY" {
    var parsed = try parseValue("{\"inputs\":{},\"outputs\":42}");
    defer parsed.deinit();
    try std.testing.expectError(
        error.SubProcessInterfaceInputsNotArray,
        parseInterface(talloc, parsed.value),
    );

    var parsed2 = try parseValue("{\"inputs\":[],\"outputs\":42}");
    defer parsed2.deinit();
    try std.testing.expectError(
        error.SubProcessInterfaceOutputsNotArray,
        parseInterface(talloc, parsed2.value),
    );
}

test "SPC-02: entry shape violations → ENTRY_INVALID" {
    // entry not an object
    var p1 = try parseValue("{\"inputs\":[\"not-object\"]}");
    defer p1.deinit();
    try std.testing.expectError(error.SubProcessInterfaceEntryInvalid, parseInterface(talloc, p1.value));

    // empty name
    var p2 = try parseValue("{\"inputs\":[{\"name\":\"\",\"json_schema\":{}}]}");
    defer p2.deinit();
    try std.testing.expectError(error.SubProcessInterfaceEntryInvalid, parseInterface(talloc, p2.value));

    // missing name
    var p3 = try parseValue("{\"inputs\":[{\"json_schema\":{}}]}");
    defer p3.deinit();
    try std.testing.expectError(error.SubProcessInterfaceEntryInvalid, parseInterface(talloc, p3.value));

    // required not a boolean
    var p4 = try parseValue("{\"inputs\":[{\"name\":\"a\",\"json_schema\":{},\"required\":\"yes\"}]}");
    defer p4.deinit();
    try std.testing.expectError(error.SubProcessInterfaceEntryInvalid, parseInterface(talloc, p4.value));

    // missing json_schema
    var p5 = try parseValue("{\"inputs\":[{\"name\":\"a\"}]}");
    defer p5.deinit();
    try std.testing.expectError(error.SubProcessInterfaceEntryInvalid, parseInterface(talloc, p5.value));
}

test "SPC-02: malformed json_schema → SCHEMA_INVALID" {
    var p = try parseValue("{\"inputs\":[{\"name\":\"a\",\"json_schema\":{\"type\":42}}]}");
    defer p.deinit();
    try std.testing.expectError(error.SubProcessInterfaceSchemaInvalid, parseInterface(talloc, p.value));
}

test "SPC-02: duplicate names within a direction → DUPLICATE_NAME" {
    var p = try parseValue(
        \\{"inputs":[{"name":"a","json_schema":{}},{"name":"a","json_schema":{}}]}
    );
    defer p.deinit();
    try std.testing.expectError(error.SubProcessInterfaceDuplicateName, parseInterface(talloc, p.value));
}

test "SPC-02: unknown schema keywords are accepted (permitted and inert)" {
    const iface = try parseIface(
        \\{"inputs":[{"name":"a","json_schema":{"$ref":"#/x","pattern":"^a","format":"uuid"}}]}
    );
    defer iface.deinit(talloc);
    try std.testing.expectEqual(@as(usize, 1), iface.inputs.len);
}

test "SPC-02: collectInterfaceViolations lists ALL offending entries" {
    const codes = try collectCodes(
        \\{"inputs":[{"name":"a","json_schema":{"type":42}},{"name":"a","json_schema":{"minimum":"low"}}],"outputs":42}
    );
    defer talloc.free(codes);
    try std.testing.expectEqual(@as(usize, 3), codes.len);
    try std.testing.expectEqualStrings("SUB_PROCESS_INTERFACE_SCHEMA_INVALID", codes[0]);
    try std.testing.expectEqualStrings("SUB_PROCESS_INTERFACE_DUPLICATE_NAME", codes[1]);
    try std.testing.expectEqualStrings("SUB_PROCESS_INTERFACE_OUTPUTS_NOT_ARRAY", codes[2]);
}

// ---------------------------------------------------------------------------
// SPC-01 runtime helpers
// ---------------------------------------------------------------------------

/// Build a parent/child variable map from a JSON object document (deep).
fn parseObjectMap(text: []const u8) !std.json.ObjectMap {
    var parsed = try parseValue(text);
    defer parsed.deinit();
    return (try cloneJsonValueSafe(talloc, parsed.value)).object;
}

test "SPC-01: buildChildInitialMap copies ONLY named+present+valid inputs (AC1)" {
    const parent = try parseObjectMap("{\"customer_id\":\"c1\",\"amount\":42,\"secret\":\"hidden\"}");
    defer freeJsonValueSafe(talloc, std.json.Value{ .object = parent });

    const iface = try parseIface(
        \\{"inputs":[{"name":"customer_id","json_schema":{"type":"string"},"required":true},{"name":"amount","json_schema":{"type":"number"},"required":false}]}
    );
    defer iface.deinit(talloc);

    var violation: ?ContractViolation = null;
    defer if (violation) |v| freeContractViolation(talloc, v);
    const child_map = try buildChildInitialMap(talloc, parent, iface, &violation);
    defer freeJsonValueSafe(talloc, std.json.Value{ .object = child_map });

    try std.testing.expectEqual(@as(usize, 2), child_map.count());
    // `secret` must NOT be visible to the child.
    try std.testing.expect(child_map.get("customer_id") != null);
    try std.testing.expect(child_map.get("amount") != null);
    try std.testing.expect(child_map.get("secret") == null);
    try std.testing.expect(violation == null);
}

test "SPC-01: missing required input → MissingRequiredInput, no map" {
    const parent = try parseObjectMap("{\"other\":1}");
    defer freeJsonValueSafe(talloc, std.json.Value{ .object = parent });

    const iface = try parseIface(
        \\{"inputs":[{"name":"customer_id","json_schema":{"type":"string"},"required":true}]}
    );
    defer iface.deinit(talloc);

    var violation: ?ContractViolation = null;
    defer if (violation) |v| freeContractViolation(talloc, v);
    try std.testing.expectError(
        error.SubProcessMissingRequiredInput,
        buildChildInitialMap(talloc, parent, iface, &violation),
    );
    try std.testing.expect(violation != null);
    try std.testing.expectEqualStrings("SUB_PROCESS_MISSING_REQUIRED_INPUT", violation.?.code);
    try std.testing.expectEqualStrings("customer_id", violation.?.key);
}

test "SPC-01: absent optional input is skipped" {
    const parent = try parseObjectMap("{\"other\":1}");
    defer freeJsonValueSafe(talloc, std.json.Value{ .object = parent });

    const iface = try parseIface(
        \\{"inputs":[{"name":"optional_x","json_schema":{"type":"string"},"required":false}]}
    );
    defer iface.deinit(talloc);

    var violation: ?ContractViolation = null;
    defer if (violation) |v| freeContractViolation(talloc, v);
    const child_map = try buildChildInitialMap(talloc, parent, iface, &violation);
    defer freeJsonValueSafe(talloc, std.json.Value{ .object = child_map });
    try std.testing.expectEqual(@as(usize, 0), child_map.count());
}

test "SPC-01: input schema violation → InputSchemaViolation (required AND optional inputs alike)" {
    const parent = try parseObjectMap("{\"amount\":\"not-a-number\"}");
    defer freeJsonValueSafe(talloc, std.json.Value{ .object = parent });

    // required input present but failing its schema
    const iface = try parseIface(
        \\{"inputs":[{"name":"amount","json_schema":{"type":"number"},"required":true}]}
    );
    defer iface.deinit(talloc);

    var violation: ?ContractViolation = null;
    defer if (violation) |v| freeContractViolation(talloc, v);
    try std.testing.expectError(
        error.SubProcessInputSchemaViolation,
        buildChildInitialMap(talloc, parent, iface, &violation),
    );
    try std.testing.expectEqualStrings("SUB_PROCESS_INPUT_SCHEMA_VIOLATION", violation.?.code);
    try std.testing.expectEqualStrings("amount", violation.?.key);
    try std.testing.expectEqualStrings("type", violation.?.constraint.?);

    // optional input present but failing its schema must ALSO be rejected
    const iface2 = try parseIface(
        \\{"inputs":[{"name":"amount","json_schema":{"type":"number"},"required":false}]}
    );
    defer iface2.deinit(talloc);
    var violation2: ?ContractViolation = null;
    defer if (violation2) |v| freeContractViolation(talloc, v);
    try std.testing.expectError(
        error.SubProcessInputSchemaViolation,
        buildChildInitialMap(talloc, parent, iface2, &violation2),
    );
}

test "SPC-01: empty inputs list yields an empty child map (edge case)" {
    const parent = try parseObjectMap("{\"a\":1,\"b\":2}");
    defer freeJsonValueSafe(talloc, std.json.Value{ .object = parent });

    const iface = try parseIface("{\"inputs\":[]}");
    defer iface.deinit(talloc);

    var violation: ?ContractViolation = null;
    defer if (violation) |v| freeContractViolation(talloc, v);
    const child_map = try buildChildInitialMap(talloc, parent, iface, &violation);
    defer freeJsonValueSafe(talloc, std.json.Value{ .object = child_map });
    try std.testing.expectEqual(@as(usize, 0), child_map.count());
}

test "SPC-01: selectAndValidateOutputs merges ONLY named+present+valid outputs (AC4)" {
    const child = try parseObjectMap("{\"order_id\":\"o1\",\"internal\":\"discard-me\"}");
    defer freeJsonValueSafe(talloc, std.json.Value{ .object = child });

    const iface = try parseIface(
        \\{"outputs":[{"name":"order_id","json_schema":{"type":"string"},"required":true}]}
    );
    defer iface.deinit(talloc);

    var violation: ?ContractViolation = null;
    defer if (violation) |v| freeContractViolation(talloc, v);
    const out_map = try selectAndValidateOutputs(talloc, child, iface, &violation);
    defer freeJsonValueSafe(talloc, std.json.Value{ .object = out_map });

    try std.testing.expectEqual(@as(usize, 1), out_map.count());
    // `internal` is discarded — never merged into the parent.
    try std.testing.expect(out_map.get("order_id") != null);
    try std.testing.expect(out_map.get("internal") == null);
}

test "SPC-01: missing required output → MissingRequiredOutput, no merge" {
    const child = try parseObjectMap("{\"something_else\":1}");
    defer freeJsonValueSafe(talloc, std.json.Value{ .object = child });

    const iface = try parseIface(
        \\{"outputs":[{"name":"order_id","json_schema":{"type":"string"},"required":true}]}
    );
    defer iface.deinit(talloc);

    var violation: ?ContractViolation = null;
    defer if (violation) |v| freeContractViolation(talloc, v);
    try std.testing.expectError(
        error.SubProcessMissingRequiredOutput,
        selectAndValidateOutputs(talloc, child, iface, &violation),
    );
    try std.testing.expectEqualStrings("SUB_PROCESS_MISSING_REQUIRED_OUTPUT", violation.?.code);
    try std.testing.expectEqualStrings("order_id", violation.?.key);
}

test "SPC-01: output schema violation → OutputSchemaViolation, no partial merge" {
    const child = try parseObjectMap("{\"order_id\":12345}");
    defer freeJsonValueSafe(talloc, std.json.Value{ .object = child });

    const iface = try parseIface(
        \\{"outputs":[{"name":"order_id","json_schema":{"type":"string"},"required":true}]}
    );
    defer iface.deinit(talloc);

    var violation: ?ContractViolation = null;
    defer if (violation) |v| freeContractViolation(talloc, v);
    try std.testing.expectError(
        error.SubProcessOutputSchemaViolation,
        selectAndValidateOutputs(talloc, child, iface, &violation),
    );
    try std.testing.expectEqualStrings("SUB_PROCESS_OUTPUT_SCHEMA_VIOLATION", violation.?.code);
    try std.testing.expectEqualStrings("order_id", violation.?.key);
    try std.testing.expectEqualStrings("type", violation.?.constraint.?);
}

test "SPC-01: absent optional output is skipped" {
    const child = try parseObjectMap("{\"other\":1}");
    defer freeJsonValueSafe(talloc, std.json.Value{ .object = child });

    const iface = try parseIface(
        \\{"outputs":[{"name":"optional_y","json_schema":{"type":"string"},"required":false}]}
    );
    defer iface.deinit(talloc);

    var violation: ?ContractViolation = null;
    defer if (violation) |v| freeContractViolation(talloc, v);
    const out_map = try selectAndValidateOutputs(talloc, child, iface, &violation);
    defer freeJsonValueSafe(talloc, std.json.Value{ .object = out_map });
    try std.testing.expectEqual(@as(usize, 0), out_map.count());
}

test "SPC-01: empty outputs list yields an empty map (no-op merge; parent advances)" {
    const child = try parseObjectMap("{\"a\":1}");
    defer freeJsonValueSafe(talloc, std.json.Value{ .object = child });

    const iface = try parseIface("{\"outputs\":[]}");
    defer iface.deinit(talloc);

    var violation: ?ContractViolation = null;
    defer if (violation) |v| freeContractViolation(talloc, v);
    const out_map = try selectAndValidateOutputs(talloc, child, iface, &violation);
    defer freeJsonValueSafe(talloc, std.json.Value{ .object = out_map });
    try std.testing.expectEqual(@as(usize, 0), out_map.count());
}

test "SPC-01: validateInputValue / validateOutputValue enforce the declared schema" {
    var schema = try parseValue("{\"type\":\"number\"}");
    defer schema.deinit();
    try validateInputValue(talloc, std.json.Value{ .integer = 7 }, schema.value);
    try std.testing.expectError(
        error.SubProcessInputSchemaViolation,
        validateInputValue(talloc, std.json.Value{ .string = "x" }, schema.value),
    );
    try validateOutputValue(talloc, std.json.Value{ .integer = 7 }, schema.value);
    try std.testing.expectError(
        error.SubProcessOutputSchemaViolation,
        validateOutputValue(talloc, std.json.Value{ .bool = true }, schema.value),
    );
}

