//! PRM-03: Plan digest — SHA-256 canonical JSON digest of a PromotionPlan
//!
//! Computes a deterministic SHA-256 digest over the canonical JSON serialisation
//! of a PromotionPlan. The digest is stored on the promotion_reviews row at submit
//! time and verified (not recomputed) at approve/apply time.
//!
//! Canonical JSON rules:
//!   1. Object keys sorted lexicographically (ascending, by Unicode code point).
//!   2. No insignificant whitespace (no spaces after `:`, no spaces after `,`).
//!   3. UTF-8 encoded.
//!   4. null values are included as the literal `null`.
//!
//! Design artefact: src/design/prm-03-plan-digest.md

const std = @import("std");
const sha2 = std.crypto.hash.sha2;
const plan_mod = @import("promotion_plan.zig");

// ── Public API ─────────────────────────────────────────────────────────────────

/// Canonical JSON serialisation of a PromotionPlan.
///
/// Canonical form (requirement PRM-03 entry shape `{type, id, changes}`):
/// a compact JSON array of plan-entry objects, one per entry, each with keys
/// sorted lexicographically by Unicode code point (`changes`, `id`, `type`):
///
///   {"changes":{"after":...,"before":...,"change_kind":"added"},"id":"node-1","type":"graph_node"}
///
/// where `changes` is itself a compact object with keys sorted
/// lexicographically (`after`, `before`, `change_kind`). No insignificant
/// whitespace anywhere; UTF-8 encoded; `null` values are emitted as the
/// literal `null`, never omitted. `before`/`after` carry the JSON-serialised
/// prior/new state as a JSON string (`null` for `added` / `removed`
/// respectively).
///
/// The returned slice is allocated with the caller-provided allocator and is
/// owned by the caller.
pub fn serialisePlanCanonical(
    allocator: std.mem.Allocator,
    plan: plan_mod.PromotionPlan,
) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.append(allocator, '[');
    for (plan.entries, 0..) |entry, i| {
        if (i > 0) try buf.append(allocator, ',');
        try serialiseEntryCanonical(allocator, &buf, entry);
    }
    try buf.append(allocator, ']');
    return buf.toOwnedSlice(allocator);
}

/// Computes the canonical SHA-256 digest of a PromotionPlan.
/// Returns lowercase hexadecimal string (64 characters). The returned slice
/// is allocated with the caller-provided allocator and is owned by the caller.
/// Canonical form: keys sorted lexicographically, no insignificant whitespace,
/// over the requirement entry shape `{type, id, changes}`.
pub fn computePlanDigest(allocator: std.mem.Allocator, plan: plan_mod.PromotionPlan) []const u8 {
    const canonical = serialisePlanCanonical(allocator, plan) catch return "";

    // Compute SHA-256 of the canonical bytes.
    var digest: [32]u8 = undefined;
    sha2.Sha256.hash(canonical, &digest, .{});
    allocator.free(canonical);

    // Convert to lowercase hex string (no std.fmt.fmtSliceHexLower in this Zig).
    const hex_chars = "0123456789abcdef";
    const out = allocator.alloc(u8, 64) catch return "";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0xf];
    }
    return out;
}

/// Verifies that a request-body digest matches the stored digest.
/// Returns true if equal, false otherwise.
/// Uses constant-time comparison (std.crypto.timing_safe.compare) to avoid
/// timing attacks on the digest value.
pub fn verifyDigest(stored: []const u8, provided: []const u8) bool {
    if (stored.len != 64 or provided.len != 64) return false;
    return std.crypto.timing_safe.compare(u8, stored, provided, .little) == .eq;
}

// ── Internal helpers ────────────────────────────────────────────────────────────

/// Emits one plan entry in canonical form:
///   {"changes":{"after":...,"before":...,"change_kind":"..."},"id":...,"type":...}
/// with entry keys sorted lexicographically (`changes` < `id` < `type`) and the
/// `changes` sub-object keys sorted lexicographically (`after` < `before` <
/// `change_kind`).
fn serialiseEntryCanonical(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    entry: plan_mod.PlanEntry,
) !void {
    try buf.appendSlice(allocator, "{\"changes\":{\"after\":");
    if (entry.after) |af| {
        const escaped = try jsonEscape(allocator, af);
        defer allocator.free(escaped);
        try buf.appendSlice(allocator, escaped);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",\"before\":");
    if (entry.before) |bf| {
        const escaped = try jsonEscape(allocator, bf);
        defer allocator.free(escaped);
        try buf.appendSlice(allocator, escaped);
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",\"change_kind\":\"");
    try buf.appendSlice(allocator, changeKindStr(entry.change_kind));
    try buf.appendSlice(allocator, "\"},\"id\":");
    const id_escaped = try jsonEscape(allocator, entry.id);
    defer allocator.free(id_escaped);
    try buf.appendSlice(allocator, id_escaped);
    try buf.appendSlice(allocator, ",\"type\":");
    const type_escaped = try jsonEscape(allocator, planEntryTypeStr(entry.type));
    defer allocator.free(type_escaped);
    try buf.appendSlice(allocator, type_escaped);
    try buf.append(allocator, '}');
}

fn planEntryTypeStr(t: plan_mod.PlanEntryType) []const u8 {
    return switch (t) {
        .graph_node => "graph_node",
        .graph_edge => "graph_edge",
        .variable_schema => "variable_schema",
        .service_binding => "service_binding",
        .module_ref => "module_ref",
        .permission_rule => "permission_rule",
    };
}

fn changeKindStr(k: plan_mod.ChangeKind) []const u8 {
    return switch (k) {
        .added => "added",
        .modified => "modified",
        .removed => "removed",
    };
}

/// Escapes a string for JSON. Returns an allocated string owned by the caller.
fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
    return buf.toOwnedSlice(allocator);
}
