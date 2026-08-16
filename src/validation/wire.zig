//! Wire serialiser — RFC 9457 Problem Details for VLD-01/02/03 findings.
//!
//! Requirement IDs: VLD-03 AC1..AC5
//! Design artefact:  src/design/vld-01-03-stage-16-validation.md §5, §7.2, §7.4
//!
//! `wire.zig` is the only module that knows the on-the-wire JSON shape. The
//! `error_kind` enum maps to a closed set of strings via `errorKindToWire`
//! (VLD-03 AC5: "No error_kind value outside the enumerated set is emitted");
//! the function is a `comptime` exhaustive switch so adding a new variant
//! is a Zig compile error.
//!
//! `serialiseValidationFailure` produces the 422 body described in the
//! design's §5.2 example. The successful body (200 + `"status":
//! "semantically_valid"`) is produced by `serialiseSuccess`.
//!
//! Pure module: no I/O, no DB, no logging, no clock reads.

const std = @import("std");
const finding_mod = @import("finding.zig");
const env_mod = @import("env.zig");
const pd06_mod = @import("pd06.zig");

pub const ErrorKind = finding_mod.ErrorKind;
pub const Finding = finding_mod.Finding;
pub const Pd06Diagnostic = pd06_mod.Pd06Diagnostic;
pub const Provenance = env_mod.Provenance;
pub const TypeTag = env_mod.TypeTag;

// ---------------------------------------------------------------------------
// errorKindToWire — VLD-03 AC5 closed-enum mapping
// ---------------------------------------------------------------------------

/// Map an `ErrorKind` to the canonical wire string from the requirement IDs.
/// Comptime exhaustive switch — adding a new variant without a wire string
/// is a compile error.
pub fn errorKindToWire(kind: ErrorKind) []const u8 {
    return switch (kind) {
        .UnknownVariable => "UnknownVariable",
        .TypeMismatch => "TypeMismatch",
        .OperandTypeError => "OperandTypeError",
        .UnknownVariableType => "UnknownVariableType",
        .UndeclaredResultSchema => "UndeclaredResultSchema",
        .ConflictingFieldType => "ConflictingFieldType",
        .EmptyExpression => "EmptyExpression",
    };
}

// ---------------------------------------------------------------------------
// ValidationFailure — wire aggregate (VLD-03 §4.4, §5)
// ---------------------------------------------------------------------------

/// Aggregated wire payload. `findings` is VLD-03 AC1 ("collect ALL findings
/// in a single HTTP 422 response"). When the PD-06 syntax gate fired
/// (VLD-02 AC4), `findings` is empty and `pd06_diagnostics` carries the
/// verbatim PD-06 violations.
pub const ValidationFailure = struct {
    findings: []Finding,
    pd06_diagnostics: ?[]Pd06Diagnostic = null,
    validated_at: []const u8,
    compiler_version: []const u8,

    pub fn deinit(self: ValidationFailure, allocator: std.mem.Allocator) void {
        finding_mod.freeFindings(allocator, self.findings);
        if (self.pd06_diagnostics) |diags| {
            pd06_mod.freePd06Diagnostics(allocator, diags);
        }
        allocator.free(self.validated_at);
        allocator.free(self.compiler_version);
    }
};

// ---------------------------------------------------------------------------
// JSON escaping helpers (RFC 9457 body uses embedded source/message)
// ---------------------------------------------------------------------------

/// JSON-escape `s` into `buf`. Returns the slice appended (caller writes
/// into an ArrayList(u8)).
fn appendJsonString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) std.mem.Allocator.Error!void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x08 => try buf.appendSlice(allocator, "\\b"),
            0x0c => try buf.appendSlice(allocator, "\\f"),
            else => {
                if (c < 0x20) {
                    try buf.appendSlice(allocator, "\\u");
                    const hex = "0123456789abcdef";
                    const v: u16 = c;
                    try buf.append(allocator, hex[(v >> 12) & 0xf]);
                    try buf.append(allocator, hex[(v >> 8) & 0xf]);
                    try buf.append(allocator, hex[(v >> 4) & 0xf]);
                    try buf.append(allocator, hex[v & 0xf]);
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
    try buf.append(allocator, '"');
}

// ---------------------------------------------------------------------------
// serialiseValidationFailure — RFC 9457 422 body
// ---------------------------------------------------------------------------

/// Build the JSON body for a 422 response. The body contains:
///
///   {
///     "type": "https://platform/validation/semantic",
///     "title": "Definition failed semantic validation",
///     "status": 422,
///     "findings": [ {...}, ... ],
///     "pd06_diagnostics": [ { code, message, node_id?, expression_path? }, ... ],
///     "validated_at": "...",
///     "compiler_version": "..."
///   }
///
/// `pd06_diagnostics` is included only when non-null (VLD-02 AC4 case).
pub fn serialiseValidationFailure(
    allocator: std.mem.Allocator,
    failure: ValidationFailure,
) std.mem.Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\{"type":"https://platform/validation/semantic",
        \\"title":"Definition failed semantic validation",
        \\"status":422,
        \\"findings":[
    );

    for (failure.findings, 0..) |f, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '{');
        try buf.appendSlice(allocator, "\"node_id\":");
        try appendJsonString(allocator, &buf, f.node_id);
        try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "\"expression_path\":");
        try appendJsonString(allocator, &buf, f.expression_path);
        try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "\"source\":");
        try appendJsonString(allocator, &buf, f.source);
        try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "\"error_kind\":");
        try appendJsonString(allocator, &buf, errorKindToWire(f.error_kind));
        try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "\"message\":");
        try appendJsonString(allocator, &buf, f.message);
        try buf.append(allocator, '}');
    }

    try buf.appendSlice(allocator, "]");

    if (failure.pd06_diagnostics) |diags| {
        try buf.appendSlice(allocator, ",\"pd06_diagnostics\":[");
        for (diags, 0..) |d, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.append(allocator, '{');
            try buf.appendSlice(allocator, "\"code\":");
            try appendJsonString(allocator, &buf, d.code);
            try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "\"message\":");
            try appendJsonString(allocator, &buf, d.message);
            if (d.node_id) |nid| {
                try buf.append(allocator, ',');
                try buf.appendSlice(allocator, "\"node_id\":");
                try appendJsonString(allocator, &buf, nid);
            }
            if (d.expression_path) |p| {
                try buf.append(allocator, ',');
                try buf.appendSlice(allocator, "\"expression_path\":");
                try appendJsonString(allocator, &buf, p);
            }
            try buf.append(allocator, '}');
        }
        try buf.append(allocator, ']');
    }

    try buf.appendSlice(allocator, ",\"validated_at\":");
    try appendJsonString(allocator, &buf, failure.validated_at);
    try buf.append(allocator, ',');
    try buf.appendSlice(allocator, "\"compiler_version\":");
    try appendJsonString(allocator, &buf, failure.compiler_version);
    try buf.append(allocator, '}');

    return try buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// serialiseSuccess — 200 OK body
// ---------------------------------------------------------------------------

/// 200 OK body for a clean definition. Per §5.2.
pub fn serialiseSuccess(
    allocator: std.mem.Allocator,
    validated_at: []const u8,
    compiler_version: []const u8,
) std.mem.Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"status\":\"semantically_valid\",\"findings\":[],\"validated_at\":");
    try appendJsonString(allocator, &buf, validated_at);
    try buf.append(allocator, ',');
    try buf.appendSlice(allocator, "\"compiler_version\":");
    try appendJsonString(allocator, &buf, compiler_version);
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "errorKindToWire: every variant has a wire string" {
    try std.testing.expectEqualStrings("UnknownVariable", errorKindToWire(.UnknownVariable));
    try std.testing.expectEqualStrings("TypeMismatch", errorKindToWire(.TypeMismatch));
    try std.testing.expectEqualStrings("OperandTypeError", errorKindToWire(.OperandTypeError));
    try std.testing.expectEqualStrings("UnknownVariableType", errorKindToWire(.UnknownVariableType));
    try std.testing.expectEqualStrings("UndeclaredResultSchema", errorKindToWire(.UndeclaredResultSchema));
    try std.testing.expectEqualStrings("ConflictingFieldType", errorKindToWire(.ConflictingFieldType));
    try std.testing.expectEqualStrings("EmptyExpression", errorKindToWire(.EmptyExpression));
}

test "serialiseSuccess: includes status, validated_at, compiler_version" {
    const alloc = std.testing.allocator;
    const body = try serialiseSuccess(alloc, "2026-08-16T12:00:00Z", "vld-01-03-WF02");
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"status\":\"semantically_valid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"validated_at\":\"2026-08-16T12:00:00Z\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"compiler_version\":\"vld-01-03-WF02\"") != null);
}

test "serialiseValidationFailure: empty findings + null pd06 -> minimal body" {
    const alloc = std.testing.allocator;
    const failure = ValidationFailure{
        .findings = &[_]Finding{},
        .pd06_diagnostics = null,
        .validated_at = try alloc.dupe(u8, "2026-08-16T12:00:00Z"),
        .compiler_version = try alloc.dupe(u8, "v"),
    };
    const body = try serialiseValidationFailure(alloc, failure);
    defer {
        alloc.free(body);
        alloc.free(failure.validated_at);
        alloc.free(failure.compiler_version);
    }
    try std.testing.expect(std.mem.indexOf(u8, body, "\"status\":422") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"findings\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"pd06_diagnostics\":") == null);
}

test "serialiseValidationFailure: escapes embedded quotes / newlines" {
    const alloc = std.testing.allocator;
    const node_id = try alloc.dupe(u8, "n1");
    const path = try alloc.dupe(u8, "/p");
    const source = try alloc.dupe(u8, "a\"b\nc");
    const message = try alloc.dupe(u8, "hello\tworld");
    defer {
        alloc.free(node_id);
        alloc.free(path);
        alloc.free(source);
        alloc.free(message);
    }
    var findings_arr = try alloc.alloc(Finding, 1);
    defer alloc.free(findings_arr);
    findings_arr[0] = Finding{
        .node_id = node_id,
        .expression_path = path,
        .source = source,
        .error_kind = .UnknownVariable,
        .message = message,
    };
    const failure = ValidationFailure{
        .findings = findings_arr,
        .pd06_diagnostics = null,
        .validated_at = try alloc.dupe(u8, "now"),
        .compiler_version = try alloc.dupe(u8, "v"),
    };
    const body = try serialiseValidationFailure(alloc, failure);
    defer {
        alloc.free(body);
        alloc.free(failure.validated_at);
        alloc.free(failure.compiler_version);
    }
    try std.testing.expect(std.mem.indexOf(u8, body, "a\\\"b\\nc") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "hello\\tworld") != null);
}
