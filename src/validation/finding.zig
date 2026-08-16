//! Finding — the diagnostic struct emitted by the VLD-01/02/03 validator.
//!
//! Requirement IDs: VLD-02 AC1/AC2/AC3, VLD-03 AC1..AC5
//! Design artefact:  src/design/vld-01-03-stage-16-validation.md §4.3, §6.3
//!
//! A `Finding` is one observation from a single validation pass. The validator
//! appends one Finding per discovered problem; the orchestrator (`mod.zig`)
//! collects every Finding into a single `ValidationFailure.findings` slice and
//! sorts by `(node_id, expression_path)` before the HTTP layer serialises it
//! (VLD-03 AC4).
//!
//! The 7-variant `ErrorKind` enum is closed: VLD-03 AC5 ("No error_kind value
//! outside the enumerated set is emitted"). The Zig type system enforces the
//! closure — every `switch` over ErrorKind is required to be exhaustive, so
//! adding a new variant forces a compile-time audit of every dispatch site.
//!
//! Levenshtein distance helper (`editDistance`) supports the VLD-03 AC3
//! edit-distance suggestion for `UnknownVariable` — the threshold of 4 is a
//! module-level constant; only suggestions at-or-below that distance are
//! included in the message.
//!
//! Pure module: no I/O, no DB, no logging, no clock reads.

const std = @import("std");

// ---------------------------------------------------------------------------
// ErrorKind — closed enumeration of diagnostic categories (VLD-03 AC5)
// ---------------------------------------------------------------------------

/// The 7 diagnostic categories the VLD-01/02/03 validator emits.
///
/// Wire strings match the YAML body of the requirement IDs exactly; the wire
/// mapping in `wire.zig` (`errorKindToWire`) is a `comptime` exhaustive
/// switch over this enum.
pub const ErrorKind = enum {
    /// VLD-02 AC2 — an identifier in the AST cannot be resolved in the site's
    /// visible TypedEnv (even after the per-site scope filter has been applied).
    UnknownVariable,
    /// VLD-02 AC1 — the AST root's computed TypeTag does not match the
    /// per-site expected type (e.g. gateway edge must yield bool, form
    /// visible_when must yield bool, etc.).
    TypeMismatch,
    /// VLD-02 AC3 — a binary operator's operand TypeTags are incompatible
    /// (e.g. `+` over string + number, `and` over non-bool).
    OperandTypeError,
    /// VLD-01 AC1 — `variable_schema` (or another declaration source)
    /// declares a type name that is not in the §8 mapping table.
    UnknownVariableType,
    /// VLD-01 AC2 — a SERVICE_TASK node references a catalog entry whose
    /// `response_schema` is null/empty.
    UndeclaredResultSchema,
    /// VLD-01 AC3 — a HUMAN_TASK form declares two fields with the same name
    /// but different types (within the same form scope).
    ConflictingFieldType,
    /// VLD-02 AC5 — an expression site carries an empty or whitespace-only
    /// source slice.
    EmptyExpression,
};

// ---------------------------------------------------------------------------
// Finding — single diagnostic record (VLD-03 AC2)
// ---------------------------------------------------------------------------

/// One diagnostic emitted by `validateDefinition`. Five mandatory fields per
/// VLD-03 AC2; the wire serialiser writes every field, so the JSON shape is
/// identical regardless of `error_kind`.
///
/// All string slices are allocator-owned. The caller (`mod.zig`) takes
/// ownership of every Finding's slices at the end of the validation pass and
/// must call `freeFinding` for each (and `freeFindings` for the slice itself).
pub const Finding = struct {
    /// The graph node id where the finding lives. Never empty (root-level
    /// findings use the literal `"<definition>"`).
    node_id: []const u8,
    /// JSON-Pointer-like path inside the node attribute. Never empty;
    /// `expression_path == "/"` is rejected by the site walker.
    expression_path: []const u8,
    /// Literal CEL source slice that produced the finding. For `EmptyExpression`
    /// the verbatim empty/whitespace source is preserved (e.g. `"   "`) per
    /// VLD-03 AC2 — the finding carries the exact source, never a normalised `""`.
    source: []const u8,
    /// Closed enum — see `ErrorKind` docstring.
    error_kind: ErrorKind,
    /// Human-readable message. Format per the §9 error-taxonomy rules in the
    /// design; for `UnknownVariable` the suggestion (when present) is appended
    /// as `"did you mean '<nearest>'?"`.
    message: []const u8,
};

/// Free one Finding's allocator-owned strings. The Finding struct itself lives
/// inside a slice the caller frees separately.
pub fn freeFinding(allocator: std.mem.Allocator, f: Finding) void {
    allocator.free(f.node_id);
    allocator.free(f.expression_path);
    allocator.free(f.source);
    allocator.free(f.message);
}

/// Free every Finding in a slice plus the slice itself.
pub fn freeFindings(allocator: std.mem.Allocator, items: []Finding) void {
    for (items) |f| freeFinding(allocator, f);
    allocator.free(items);
}

// ---------------------------------------------------------------------------
// sortByLocation — VLD-03 AC4 deterministic ordering
// ---------------------------------------------------------------------------

/// Sort the slice in place by `(node_id, expression_path)` using byte-wise lex
/// order on the two strings. Stable, in-place, allocation-free. Two runs of
/// `validateDefinition` on the same definition produce byte-identical ordering
/// (the test in tests/unit/validation_test.zig asserts this).
pub fn sortByLocation(items: []Finding) void {
    std.sort.block(Finding, items, {}, lessThan);
}

fn lessThan(_: void, a: Finding, b: Finding) bool {
    if (!std.mem.eql(u8, a.node_id, b.node_id)) {
        return std.mem.lessThan(u8, a.node_id, b.node_id);
    }
    return std.mem.lessThan(u8, a.expression_path, b.expression_path);
}

// ---------------------------------------------------------------------------
// Edit distance — Levenshtein, byte-wise, VLD-03 AC3 threshold helper
// ---------------------------------------------------------------------------

/// Maximum Levenshtein distance considered when picking the nearest-by-distance
/// identifier for an `UnknownVariable` message. Above this threshold the
/// "did you mean '<x>'?" suffix is omitted and the message degrades to the
/// no-match form.
pub const SUGGESTION_THRESHOLD: usize = 4;

/// Levenshtein distance over UTF-8 byte slices. Treats the two strings as
/// opaque byte sequences — substitutions are single edits; multi-byte UTF-8
/// characters are not atomic. For the VLD-03 AC3 use-case (CEL identifiers
/// are always ASCII), this byte-wise behaviour matches the CEL grammar's
/// notion of "identifier".
///
/// O(M*N) time, O(min(M,N)) space — `minDim` selects the shorter string as
/// the column dimension to keep memory bounded.
pub fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;

    const min_dim: usize = if (a.len < b.len) a.len else b.len;
    const max_dim: usize = if (a.len >= b.len) a.len else b.len;

    // Two-row rolling buffer; row[i] holds the edit distance from the first i
    // bytes of `b` to the current prefix of `a`.
    var prev: [256]usize = undefined; // sized for the typical identifier length
    var curr: [256]usize = undefined;
    // Stack-allocate for short identifiers; for longer inputs spill to the heap.
    var prev_heap: ?[]usize = null;
    var curr_heap: ?[]usize = null;
    defer {
        if (prev_heap) |p| std.heap.page_allocator.free(p);
        if (curr_heap) |c| std.heap.page_allocator.free(c);
    }

    const alloc_prev: []usize = if (min_dim + 1 <= 256)
        prev[0 .. min_dim + 1]
    else blk: {
        const slice = std.heap.page_allocator.alloc(usize, min_dim + 1) catch return max_dim;
        prev_heap = slice;
        break :blk slice;
    };
    const alloc_curr: []usize = if (min_dim + 1 <= 256)
        curr[0 .. min_dim + 1]
    else blk: {
        const slice = std.heap.page_allocator.alloc(usize, min_dim + 1) catch return max_dim;
        curr_heap = slice;
        break :blk slice;
    };

    // Determine the short string (length min_dim) and long string (length max_dim).
    const short_str: []const u8 = if (a.len <= b.len) a else b;
    const long_str: []const u8 = if (a.len <= b.len) b else a;

    for (alloc_prev[0 .. min_dim + 1], 0..) |*cell, i| cell.* = i;

    for (long_str, 1..) |lc, i| {
        alloc_curr[0] = i;
        var row_min: usize = i;
        for (short_str, 1..) |sc, j| {
            const cost: usize = if (lc == sc) 0 else 1;
            const del = alloc_prev[j] + 1;
            const ins = alloc_curr[j - 1] + 1;
            const sub = alloc_prev[j - 1] + cost;
            const best = if (del < ins) (if (sub < del) sub else del) else (if (sub < ins) sub else ins);
            alloc_curr[j] = best;
            if (best < row_min) row_min = best;
        }
        // Pruning: if row_min already exceeds SUGGESTION_THRESHOLD we can stop
        // and return that bound — VLD-03 AC3 callers only care about
        // "at-or-below threshold" so an early exit is safe.
        if (row_min > SUGGESTION_THRESHOLD) return row_min;
        const tmp = alloc_prev;
        const tmp2 = alloc_curr;
        // Swap the row pointers.
        @memcpy(tmp[0 .. min_dim + 1], tmp2[0 .. min_dim + 1]);
    }

    return alloc_prev[min_dim];
}

// ---------------------------------------------------------------------------
// Tests — VLD-03 AC3 (Levenshtein) + VLD-03 AC4 (deterministic ordering)
// ---------------------------------------------------------------------------

test "editDistance: identical strings return 0" {
    try std.testing.expectEqual(@as(usize, 0), editDistance("amount", "amount"));
}

test "editDistance: single substitution returns 1" {
    try std.testing.expectEqual(@as(usize, 1), editDistance("amont", "amount"));
}

test "editDistance: single insertion returns 1" {
    try std.testing.expectEqual(@as(usize, 1), editDistance("amount", "amounts")); // single char appended
    try std.testing.expectEqual(@as(usize, 1), editDistance("a", "ab"));
    try std.testing.expectEqual(@as(usize, 1), editDistance("ab", "abc"));
}

test "editDistance: classic example 'kitten' vs 'sitting' returns 3" {
    try std.testing.expectEqual(@as(usize, 3), editDistance("kitten", "sitting"));
}

test "editDistance: empty vs non-empty returns the non-empty length" {
    try std.testing.expectEqual(@as(usize, 5), editDistance("", "abcde"));
    try std.testing.expectEqual(@as(usize, 5), editDistance("abcde", ""));
}

test "sortByLocation: orders by node_id then expression_path byte-wise lex" {
    const alloc = std.testing.allocator;
    const items = try alloc.alloc(Finding, 3);
    items[0] = Finding{
        .node_id = try alloc.dupe(u8, "task_collect"),
        .expression_path = try alloc.dupe(u8, "/forms/0/fields/3/visible_when"),
        .source = try alloc.dupe(u8, ""),
        .error_kind = .EmptyExpression,
        .message = try alloc.dupe(u8, "msg"),
    };
    items[1] = Finding{
        .node_id = try alloc.dupe(u8, "gw_approve"),
        .expression_path = try alloc.dupe(u8, "/edges/0/condition"),
        .source = try alloc.dupe(u8, "x"),
        .error_kind = .UnknownVariable,
        .message = try alloc.dupe(u8, "msg"),
    };
    items[2] = Finding{
        .node_id = try alloc.dupe(u8, "task_collect"),
        .expression_path = try alloc.dupe(u8, "/forms/0/fields/2/visible_when"),
        .source = try alloc.dupe(u8, ""),
        .error_kind = .EmptyExpression,
        .message = try alloc.dupe(u8, "msg"),
    };

    sortByLocation(items);
    defer {
        for (items) |f| freeFinding(alloc, f);
        alloc.free(items);
    }

    // Expected order:
    //   gw_approve < task_collect < task_collect (alphabetical node_id first)
    //   /forms/0/fields/2 < /forms/0/fields/3 (lex on expression_path)
    try std.testing.expect(std.mem.eql(u8, items[0].node_id, "gw_approve"));
    try std.testing.expect(std.mem.eql(u8, items[1].node_id, "task_collect"));
    try std.testing.expect(std.mem.eql(u8, items[1].expression_path, "/forms/0/fields/2/visible_when"));
    try std.testing.expect(std.mem.eql(u8, items[2].node_id, "task_collect"));
    try std.testing.expect(std.mem.eql(u8, items[2].expression_path, "/forms/0/fields/3/visible_when"));
}

test "ErrorKind is closed: 7 variants total" {
    const count = std.meta.fields(ErrorKind).len;
    try std.testing.expectEqual(@as(usize, 7), count);
}
