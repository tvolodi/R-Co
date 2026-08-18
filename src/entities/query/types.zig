//! QRY-01..04 — Entity query DSL types.
//!
//! Defines the closed FilterOp and SortDir enums, filter/sort node structs,
//! and the request/response envelope for POST /api/v1/entities/{key}/query.
//!
//! Security: FilterOp values are never passed as SQL text; the compiler maps
//! each tag to a SQL operator string (Layer 1 SQL-injection defence).

const std = @import("std");

// ── Filter operator enum (closed) ─────────────────────────────────────────────

/// Closed set of allowed comparison operators.
/// The compiler maps these to SQL operator literals — client text never reaches SQL.
pub const FilterOp = enum {
    eq,
    neq,
    lt,
    lte,
    gt,
    gte,
    in,
    contains,
};

/// Parse a FilterOp from its JSON wire representation.
/// Returns null for any unrecognised string.
pub fn filterOpFromString(s: []const u8) ?FilterOp {
    const map = std.StaticStringMap(FilterOp).initComptime(.{
        .{ "eq", .eq },
        .{ "neq", .neq },
        .{ "lt", .lt },
        .{ "lte", .lte },
        .{ "gt", .gt },
        .{ "gte", .gte },
        .{ "in", .in },
        .{ "contains", .contains },
    });
    return map.get(s);
}

// ── Sort direction enum (closed) ───────────────────────────────────────────────

/// Closed set of sort directions.
pub const SortDir = enum {
    asc,
    desc,
};

/// Parse a SortDir from its JSON wire representation.
/// Returns null for any unrecognised string.
pub fn sortDirFromString(s: []const u8) ?SortDir {
    const map = std.StaticStringMap(SortDir).initComptime(.{
        .{ "asc", .asc },
        .{ "desc", .desc },
    });
    return map.get(s);
}

// ── Filter and sort nodes ──────────────────────────────────────────────────────

/// A single filter predicate from the query DSL.
/// `field` is used only as an allowlist lookup key, never interpolated into SQL.
/// `value` is always bound as a positional $N parameter.
pub const FilterNode = struct {
    field: []const u8,
    op: FilterOp,
    value: []const u8,
};

/// A single sort directive from the query DSL.
/// `field` is resolved against the allowlist before emission.
pub const SortNode = struct {
    field: []const u8,
    dir: SortDir,
};

// ── Request / response envelopes ──────────────────────────────────────────────

/// Parsed body for POST /api/v1/entities/{entity_key}/query.
/// All fields are optional at the wire level and carry defaults:
///   filters   → [] (no filtering)
///   sort      → [] (default order: record_id ASC)
///   page_size → 50 (DEFAULT_PAGE_SIZE)
///   cursor    → null (first page)
pub const EntityQueryRequest = struct {
    filters: []FilterNode,
    sort: []SortNode,
    page_size: ?u16,
    cursor: ?[]const u8,
};

/// Response envelope for POST /api/v1/entities/{entity_key}/query.
/// `page_size` echoes the effective value used (default 50 when omitted from request).
pub const EntityQueryResponse = struct {
    items: []std.json.Value,
    next_cursor: ?[]const u8,
    page_size: u16,
};
