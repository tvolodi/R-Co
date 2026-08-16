//! TypedEnv — typed-environment builder for VLD-01/02/03.
//!
//! Requirement IDs: VLD-01 AC1..AC5
//! Design artefact:  src/design/vld-01-03-stage-16-validation.md §4.1, §6.1, §8
//!
//! The env is a static, declaration-grounded name → `TypeTag` map. It is built
//! from four sources (in this order):
//!   1. `variable_schema` (sibling of the graph in the definition JSON).
//!   2. Service catalog `response_schema` top-level property names (VLD-01 AC2).
//!   3. Process module `interface_schema.outputs` (PLC-01).
//!   4. Human-task form fields (PD-05 HUMAN_TASK `forms[].fields[]`).
//!
//! The env is **declaration-only**: no instance values contribute. The EE-05
//! runtime variable map is a separate concept living behind `expr.evaluate()`
//! (VLD-01 AC4).
//!
//! The type-mapping table (§8 of the design) is the single source of truth:
//! `mapDeclaredTypeName(name)` returns `null` for any string outside the
//! lowercase set — VLD-01 AC1 fires `UnknownVariableType` on that exact
//! boundary. Capitalisation variants like `"String"` or `"INTEGER"` are
//! rejected (deliberate: the convention is lowercase).
//!
//! Pure module: no I/O, no DB, no logging, no clock reads.

const std = @import("std");

// ---------------------------------------------------------------------------
// TypeTag — the env's notion of "declared type"
// ---------------------------------------------------------------------------

/// Type taxonomy used inside TypedEnv. Mirrors `expr.types.TypeTag` plus the
/// `list`, `map`, and `dyn` extensions required by VLD-01's mapping table.
///
/// `list` carries an `element_tag` (see `Entry`). `dyn` is the "deferred"
/// type used for service result schemas that don't declare a JSON Schema
/// `type` keyword — the env accepts the entry but defers type checking to
/// the AST walk site.
///
/// The two enums are kept intentionally separate so the validation module
/// does not depend on the runtime evaluator's exact tag set — adding a new
/// runtime tag (e.g. `bytes`) does not silently widen the validation
/// taxonomy. Cross-walk happens only at the `expr.typeOf` boundary in
/// `typecheck.zig`.
pub const TypeTag = enum {
    string,
    number,
    bool,
    timestamp,
    list,
    map,
    dyn,
};

/// Wire-friendly name for `TypeTag` (used by `errorKindToWire` siblings; the
/// `TypeMismatch` message embeds the tag name verbatim per §9.2).
pub fn typeTagName(t: TypeTag) []const u8 {
    return switch (t) {
        .string => "string",
        .number => "number",
        .bool => "bool",
        .timestamp => "timestamp",
        .list => "list",
        .map => "map",
        .dyn => "dyn",
    };
}

// ---------------------------------------------------------------------------
// Provenance — where an env entry came from (VLD-01 §4.1)
// ---------------------------------------------------------------------------

/// Identifies the declaration source for an Entry. Used by the env builder
/// to disambiguate duplicate-name conflicts across scopes (e.g. a variable
/// schema entry and a SERVICE_TASK output both declaring `customer_id`) and
/// by the wire formatter to prefix certain error messages.
pub const Provenance = enum {
    /// `variable_schema` row on the parent definition.
    variable_schema,
    /// SERVICE_TASK `response_schema` top-level property (VLD-01 AC2).
    service_result,
    /// SUB_PROCESS `interface_schema.outputs[i].name` (PLC-01).
    module_output,
    /// HUMAN_TASK form field (PD-05 `forms[i].fields[j]`).
    form_field,
};

// ---------------------------------------------------------------------------
// Entry — single name → TypeTag binding
// ---------------------------------------------------------------------------

/// One row in TypedEnv. The slice is ordered by insertion (VLD-01 AC3 key
/// uniqueness is enforced at insertion; duplicate names from different
/// sources do NOT conflict when the types agree — `addEntry` returns
/// `Conflict` for any duplicate with a different `tag`).
pub const Entry = struct {
    name: []const u8,
    tag: TypeTag,
    /// Populated only when `tag == .list`; carries the element type so the
    /// AST walker can validate `list.length` / `list.size` accessors. Null
    /// for every other tag.
    element_tag: ?TypeTag = null,
    /// Where the declaration came from.
    provenance: Provenance,
    /// For service_result/module_output/form_field entries, the graph node id
    /// the entry is scoped to. Null for `variable_schema` entries (global).
    source_node_id: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// TypedEnv — per-site, name → TypeTag map (VLD-01 AC5)
// ---------------------------------------------------------------------------

/// One env slice. The orchestrator builds one global env, then `scope.zig`
/// filters entries per site to enforce node-output reachability and
/// form-field containment.
pub const TypedEnv = struct {
    entries: []Entry,
    /// Soft warnings (e.g. an unused `variable_schema` row); emitted as
    /// structured logs only — NOT findings.
    warnings: []Warning = &.{},

    pub fn deinit(self: TypedEnv, allocator: std.mem.Allocator) void {
        for (self.entries) |e| {
            allocator.free(e.name);
            if (e.source_node_id) |nid| allocator.free(nid);
        }
        for (self.warnings) |w| {
            allocator.free(w.name);
            allocator.free(w.message);
        }
        // The backing slices themselves are owned by TypedEnv — they were
        // transferred in via `toOwnedSlice()` or constructed by
        // `envForSite` / `buildEnv` in this module. Free them now.
        if (self.entries.len > 0) allocator.free(self.entries);
        if (self.warnings.len > 0) allocator.free(self.warnings);
    }

    /// Look up an entry by name. O(N) — env is small (tens of entries in
    /// realistic definitions).
    pub fn lookup(self: TypedEnv, name: []const u8) ?Entry {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }
};

/// A non-fatal observation about the env. `name` is the offending variable;
/// `message` describes the warning.
pub const Warning = struct {
    name: []const u8,
    message: []const u8,
};

// ---------------------------------------------------------------------------
// EnvBuilder — incremental construction with duplicate-name detection
// ---------------------------------------------------------------------------

pub const EnvError = error{ OutOfMemory, Conflict };

/// Add an entry to the builder. Returns `EnvError.Conflict` when an entry
/// with the same `name` and a different `tag` already exists; when the
/// `tag` and `element_tag` agree the existing entry is left untouched (idempotent).
pub fn addEntry(
    builder: *std.ArrayList(Entry),
    allocator: std.mem.Allocator,
    name: []const u8,
    tag: TypeTag,
    element_tag: ?TypeTag,
    provenance: Provenance,
    source_node_id: ?[]const u8,
) EnvError!void {
    for (builder.items) |*e| {
        if (std.mem.eql(u8, e.name, name)) {
            if (e.tag != tag) return EnvError.Conflict;
            return;
        }
    }
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_src: ?[]const u8 = if (source_node_id) |nid| try allocator.dupe(u8, nid) else null;
    errdefer if (owned_src) |s| allocator.free(s);
    try builder.append(allocator, .{
        .name = owned_name,
        .tag = tag,
        .element_tag = element_tag,
        .provenance = provenance,
        .source_node_id = owned_src,
    });
}

// ---------------------------------------------------------------------------
// Type mapping — VLD-01 AC1 (§8 of the design)
// ---------------------------------------------------------------------------

/// Map a declared type-name (lowercase per the platform convention) to the
/// env's `TypeTag`. Returns `null` when the name is outside the table — the
/// caller emits a VLD-01 AC1 `UnknownVariableType` finding.
///
/// `list<T>` is parsed: `<T>` is recursively mapped (e.g. `list<integer>`
/// yields `.list` with `element_tag = .number`). When `<T>` is empty or
/// un-mappable the result is `.list` with `element_tag = .dyn` — the env
/// records the shape but the AST walker can only check structural accessors
/// on a `list<dyn>` entry.
///
/// The mapping is case-sensitive: `"String"`, `"INTEGER"`, etc. all return
/// `null`. This is deliberate (per the design §8 footnote).
///
/// Natural CEL synonyms are accepted alongside the design §8 names
/// (ISS-0709 R3): `number` (same TypeTag as `integer`/`decimal`/`money`),
/// `bool` (same as `boolean`), and `timestamp` (same as `date`/`datetime`).
/// Deliberately NOT added: `duration` (no `TypeTag` exists — mapping it to
/// `.timestamp` would be a semantic lie, and adding a `duration` variant is a
/// taxonomy change with VLD-03 AC5 implications), bare `list` (a type
/// constructor without an element type; `list<T>` is accepted), and bare
/// `map` (`object` already maps to `.map`). This decision must not be
/// reverted without a CODE-DESIGNER + VLD-03 AC5 review.
pub fn mapDeclaredTypeName(name: []const u8) ?TypeTag {
    if (std.mem.eql(u8, name, "string")) return .string;
    if (std.mem.eql(u8, name, "text")) return .string;
    if (std.mem.eql(u8, name, "enum")) return .string;
    if (std.mem.eql(u8, name, "integer")) return .number;
    if (std.mem.eql(u8, name, "decimal")) return .number;
    if (std.mem.eql(u8, name, "money")) return .number;
    if (std.mem.eql(u8, name, "number")) return .number; // natural CEL name (ISS-0709 R3)
    if (std.mem.eql(u8, name, "boolean")) return .bool;
    if (std.mem.eql(u8, name, "bool")) return .bool; // natural CEL synonym of boolean (ISS-0709 R3)
    if (std.mem.eql(u8, name, "date")) return .timestamp;
    if (std.mem.eql(u8, name, "datetime")) return .timestamp;
    if (std.mem.eql(u8, name, "timestamp")) return .timestamp; // natural CEL synonym of date/datetime (ISS-0709 R3)
    if (std.mem.eql(u8, name, "object")) return .map;
    if (std.mem.startsWith(u8, name, "list<")) {
        // Element type is informational only at this point — the env records
        // `list` and lets the AST walker handle element-level checks. Return
        // `.list` directly; the element tag is resolved inside `addEntry`
        // when the caller has parsed the inner type.
        return .list;
    }
    return null;
}

/// Parse the element type of `list<...>` into a `TypeTag`. Returns `.dyn` for
/// any inner type the table doesn't recognise (VLD-01 §8 fallback).
pub fn mapListElementName(inner: []const u8) TypeTag {
    return mapDeclaredTypeName(inner) orelse .dyn;
}

// ---------------------------------------------------------------------------
// Tests — VLD-01 mapping table + EnvBuilder conflict detection
// ---------------------------------------------------------------------------

test "mapDeclaredTypeName: every declared name maps to its design tag" {
    try std.testing.expectEqual(@as(?TypeTag, .string), mapDeclaredTypeName("string"));
    try std.testing.expectEqual(@as(?TypeTag, .string), mapDeclaredTypeName("text"));
    try std.testing.expectEqual(@as(?TypeTag, .string), mapDeclaredTypeName("enum"));
    try std.testing.expectEqual(@as(?TypeTag, .number), mapDeclaredTypeName("integer"));
    try std.testing.expectEqual(@as(?TypeTag, .number), mapDeclaredTypeName("decimal"));
    try std.testing.expectEqual(@as(?TypeTag, .number), mapDeclaredTypeName("money"));
    try std.testing.expectEqual(@as(?TypeTag, .bool), mapDeclaredTypeName("boolean"));
    try std.testing.expectEqual(@as(?TypeTag, .timestamp), mapDeclaredTypeName("date"));
    try std.testing.expectEqual(@as(?TypeTag, .timestamp), mapDeclaredTypeName("datetime"));
    try std.testing.expectEqual(@as(?TypeTag, .map), mapDeclaredTypeName("object"));
    try std.testing.expectEqual(@as(?TypeTag, .list), mapDeclaredTypeName("list<integer>"));
}

test "mapDeclaredTypeName: case-sensitive — capitalised names return null" {
    try std.testing.expectEqual(@as(?TypeTag, null), mapDeclaredTypeName("String"));
    try std.testing.expectEqual(@as(?TypeTag, null), mapDeclaredTypeName("INTEGER"));
    try std.testing.expectEqual(@as(?TypeTag, null), mapDeclaredTypeName("Boolean"));
}

test "mapDeclaredTypeName: unknown name returns null (VLD-01 AC1 trigger)" {
    try std.testing.expectEqual(@as(?TypeTag, null), mapDeclaredTypeName("uuid"));
    try std.testing.expectEqual(@as(?TypeTag, null), mapDeclaredTypeName(""));
    try std.testing.expectEqual(@as(?TypeTag, null), mapDeclaredTypeName("anything-else"));
}

test "EnvBuilder: addEntry inserts and rejects conflicting re-declaration" {
    const alloc = std.testing.allocator;
    var builder: std.ArrayList(Entry) = .empty;
    defer {
        for (builder.items) |e| alloc.free(e.name);
        builder.deinit(alloc);
    }

    try addEntry(&builder, alloc, "amount", .number, null, .variable_schema, null);
    try std.testing.expectEqual(@as(usize, 1), builder.items.len);

    // Same name + same tag = idempotent.
    try addEntry(&builder, alloc, "amount", .number, null, .variable_schema, null);
    try std.testing.expectEqual(@as(usize, 1), builder.items.len);

    // Same name + different tag = Conflict.
    const conflict = addEntry(&builder, alloc, "amount", .string, null, .variable_schema, null);
    try std.testing.expectError(EnvError.Conflict, conflict);
}

test "EnvBuilder: list entries carry element_tag" {
    const alloc = std.testing.allocator;
    var builder: std.ArrayList(Entry) = .empty;
    defer {
        for (builder.items) |e| alloc.free(e.name);
        builder.deinit(alloc);
    }
    try addEntry(&builder, alloc, "items", .list, .number, .variable_schema, null);
    try std.testing.expectEqual(@as(usize, 1), builder.items.len);
    try std.testing.expectEqual(@as(?TypeTag, .number), builder.items[0].element_tag.?);
}
