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

/// Computes the canonical SHA-256 digest of a PromotionPlan.
/// Returns lowercase hexadecimal string (64 characters). The returned slice
/// is allocated with the caller-provided allocator and is owned by the caller.
/// Canonical form: keys sorted lexicographically, no insignificant whitespace.
pub fn computePlanDigest(allocator: std.mem.Allocator, plan: plan_mod.PromotionPlan) []const u8 {
    // Build a canonical JSON representation of the plan entries.
    // Each entry is serialized as:
    // {"after":null,"before":null,"change_kind":"added","id":"node-1","type":"graph_node"}
    // with keys sorted lexicographically: after, before, change_kind, id, type.

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    buf.appendSlice(allocator, "[") catch return "";
    for (plan.entries, 0..) |entry, i| {
        if (i > 0) buf.append(allocator, ',') catch return "";

        // Build sorted-entry canonical JSON manually.
        // Keys in lexicographic order: after, before, change_kind, id, type.
        const type_str = planEntryTypeStr(entry.type);
        const change_kind_str = changeKindStr(entry.change_kind);

        // "after" value
        if (entry.after) |af| {
            // String value — JSON-escaped
            const escaped = jsonEscape(allocator, af);
            defer allocator.free(escaped);
            buf.appendSlice(allocator, "{\"after\":") catch return "";
            buf.appendSlice(allocator, escaped) catch return "";
        } else {
            buf.appendSlice(allocator, "{\"after\":null") catch return "";
        }

        // "before" value
        if (entry.before) |bf| {
            const escaped = jsonEscape(allocator, bf);
            defer allocator.free(escaped);
            buf.appendSlice(allocator, ",\"before\":") catch return "";
            buf.appendSlice(allocator, escaped) catch return "";
        } else {
            buf.appendSlice(allocator, ",\"before\":null") catch return "";
        }

        // "change_kind"
        buf.appendSlice(allocator, ",\"change_kind\":\"") catch return "";
        buf.appendSlice(allocator, change_kind_str) catch return "";
        buf.appendSlice(allocator, "\"") catch return "";

        // "id"
        buf.appendSlice(allocator, ",\"id\":") catch return "";
        const id_escaped = jsonEscape(allocator, entry.id);
        defer allocator.free(id_escaped);
        buf.appendSlice(allocator, id_escaped) catch return "";

        // "type"
        buf.appendSlice(allocator, ",\"type\":") catch return "";
        const type_escaped = jsonEscape(allocator, type_str);
        defer allocator.free(type_escaped);
        buf.appendSlice(allocator, type_escaped) catch return "";

        buf.append(allocator, '}') catch return "";
    }

    buf.append(allocator, ']') catch return "";

    // Compute SHA-256 of the canonical bytes.
    var digest: [32]u8 = undefined;
    sha2.Sha256.hash(buf.items, &digest);

    // Convert to lowercase hex string.
    const hex = std.fmt.allocPrint(allocator, "{s}", .{
        std.fmt.fmtSliceHexLower(&digest),
    }) catch return "";
    return hex;
}

/// Verifies that a request-body digest matches the stored digest.
/// Returns true if equal, false otherwise.
/// Uses constant-time comparison to avoid timing attacks on the digest value.
pub fn verifyDigest(stored: []const u8, provided: []const u8) bool {
    if (stored.len != 64 or provided.len != 64) return false;
    return std.crypto.utils.constantTimeCompare(u8, stored, provided) == .eq;
}

// ── Internal helpers ────────────────────────────────────────────────────────────

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
fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) []const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    buf.append(allocator, '"') catch return "";
    for (s) |c| {
        switch (c) {
            '"' => buf.appendSlice(allocator, "\\\"") catch return "",
            '\\' => buf.appendSlice(allocator, "\\\\") catch return "",
            '\n' => buf.appendSlice(allocator, "\\n") catch return "",
            '\r' => buf.appendSlice(allocator, "\\r") catch return "",
            '\t' => buf.appendSlice(allocator, "\\t") catch return "",
            else => buf.append(allocator, c) catch return "",
        }
    }
    buf.append(allocator, '"') catch return "";
    return buf.toOwnedSlice(allocator) catch return "";
}
