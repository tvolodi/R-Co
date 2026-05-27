//! Public API for the Expression DSL — DSL-01, DSL-12
//!
//! Entry points:
//!   parse()    — tokenise + parse source into an Ast (or error list)
//!   evaluate() — stub; returns EvalError until DSL-04/DSL-06 run
//!
//! Re-exports all public types so callers import only this module.
//!
//! No I/O. No DB access. Pure functions.
const std = @import("std");
const parser_mod = @import("parser.zig");
const ast_mod = @import("ast.zig");
const err_mod = @import("error.zig");

// ---------------------------------------------------------------------------
// Re-exports
// ---------------------------------------------------------------------------

pub const Ast = ast_mod.Ast;
pub const Node = ast_mod.Node;
pub const Value = ast_mod.Value;
pub const TypeTag = ast_mod.TypeTag;
pub const Context = ast_mod.Context;
pub const CmpOp = ast_mod.CmpOp;
pub const AddOp = ast_mod.AddOp;
pub const MulOp = ast_mod.MulOp;

pub const typeOf = ast_mod.typeOf;
pub const valueNull = ast_mod.valueNull;
pub const valueBool = ast_mod.valueBool;
pub const valueInt = ast_mod.valueInt;
pub const valueFloat = ast_mod.valueFloat;
pub const valueStr = ast_mod.valueStr;
pub const valueTs = ast_mod.valueTs;

pub const ParseError = err_mod.ParseError;
pub const EvalError = err_mod.EvalError;
pub const ExprError = err_mod.ExprError;

pub const ParseResult = parser_mod.ParseResult;

// ---------------------------------------------------------------------------
// EvalResult
// ---------------------------------------------------------------------------

pub const EvalResult = union(enum) {
    ok: Value,
    err: EvalError,
};

// ---------------------------------------------------------------------------
// parse
// ---------------------------------------------------------------------------

/// Tokenise and parse `source`.
///
/// Returns `.ok` with an `Ast` (caller must call `ast.deinit()`) or
/// `.fail` with a slice of `ParseError` (caller must call `allocator.free(errors)`).
pub fn parse(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error!ParseResult {
    return parser_mod.parse(allocator, source);
}

// ---------------------------------------------------------------------------
// evaluate — DSL-04/DSL-06 run
// ---------------------------------------------------------------------------

/// Evaluate a single `Node` and return the resulting `Value`.
///
/// Recursively evaluates sub-expressions. Currently handles only literal nodes.
/// Non-literal nodes return a NotImplemented error.
///
/// `allocator` is used for intermediate allocations (string concatenation, etc.).
pub fn evaluateNode(node: *const Node, ctx: *const Context, allocator: std.mem.Allocator) EvalResult {
    _ = ctx;
    _ = allocator;

    switch (node.*) {
        // ---- Literals (DSL-04) ----
        .null_literal => return EvalResult{ .ok = valueNull() },
        .bool_literal => |val| return EvalResult{ .ok = valueBool(val) },
        .int_literal => |val| return EvalResult{ .ok = valueInt(val) },
        .float_literal => |val| return EvalResult{ .ok = valueFloat(val) },
        .string_literal => |val| return EvalResult{ .ok = valueStr(val) },

        // ---- Non-literal nodes (future DSL-06) ----
        else => return EvalResult{ .err = EvalError{
            .message = "evaluator: node type not yet implemented",
            .line = 0,
            .column = 0,
        } },
    }
}

/// Evaluate an already-parsed `Ast` against a variable `Context`.
///
/// Returns `.ok` with the result `Value`, or `.err` on evaluation error.
/// `allocator` is used for intermediate allocations.
pub fn evaluate(
    ast_in: *const Ast,
    ctx: *const Context,
    allocator: std.mem.Allocator,
) EvalResult {
    return evaluateNode(ast_in.root, ctx, allocator);
}

// ===========================================================================
// Tests — DSL-04: literal evaluation and round-trip
// ===========================================================================

test "DSL-04: evaluate null literal" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "null");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const eval_result = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(eval_result == .ok);
    try testing.expect(eval_result.ok == .null_val);
}

test "DSL-04: evaluate bool literal true" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "true");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const eval_result = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(eval_result == .ok);
    try testing.expect(eval_result.ok.bool_val == true);
}

test "DSL-04: evaluate bool literal false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "false");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const eval_result = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(eval_result == .ok);
    try testing.expect(eval_result.ok.bool_val == false);
}

test "DSL-04: evaluate int literal 42" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "42");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const eval_result = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(eval_result == .ok);
    try testing.expectEqual(@as(i64, 42), eval_result.ok.int_val);
}

test "DSL-04: evaluate float literal 3.14" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "3.14");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const eval_result = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(eval_result == .ok);
    try testing.expect(eval_result.ok.float_val == 3.14);
}

test "DSL-04: evaluate string literal hello" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "\"hello\"");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const eval_result = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(eval_result == .ok);
    try testing.expectEqualStrings("hello", eval_result.ok.str_val);
}

test "DSL-04: evaluate empty string literal" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "\"\"");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const eval_result = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(eval_result == .ok);
    try testing.expectEqualStrings("", eval_result.ok.str_val);
}

test "DSL-04: negative integer via unary evaluates correctly" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "-5");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);
    try testing.expect(result.ok.root.* == .unary_neg);

    // Unary negation is not yet evaluated (DSL-06), so this tests
    // that the parser produces the correct AST for -5.
    // The evaluate will return NotImplemented.
    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const eval_result = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(eval_result == .err);
    // A non-literal node returns NotImplemented error
    try testing.expect(eval_result.err.line == 0);
}

test "DSL-04: unsupported function call produces parse error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // "decimal" is not a built-in function. Parser rejects it.
    var result = try parse(alloc, "decimal(42)");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .fail);
    try testing.expect(result.fail.len > 0);
}

test "DSL-04: hex literal produces parse error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // "0xFF" — lexer emits .int_literal "0" then .identifier "xFF"
    var result = try parse(alloc, "0xFF");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .fail);
}

test "DSL-04: round-trip — parse then evaluate returns same value" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cases = [_]struct {
        source: []const u8,
        expected_tag: TypeTag,
    }{
        .{ .source = "null", .expected_tag = .null },
        .{ .source = "true", .expected_tag = .bool },
        .{ .source = "false", .expected_tag = .bool },
        .{ .source = "42", .expected_tag = .int64 },
        .{ .source = "3.14", .expected_tag = .float64 },
        .{ .source = "\"hello\"", .expected_tag = .string },
        .{ .source = "\"\"", .expected_tag = .string },
    };

    for (cases) |c| {
        var parse_result = try parse(alloc, c.source);
        defer switch (parse_result) {
            .ok => |*a| a.deinit(),
            .fail => |e| alloc.free(e),
        };
        try testing.expect(parse_result == .ok);

        var ctx = Context.init(alloc);
        defer ctx.deinit();

        const eval_result = evaluate(&parse_result.ok, &ctx, alloc);
        try testing.expect(eval_result == .ok);
        try testing.expect(typeOf(eval_result.ok) == c.expected_tag);
    }
}
