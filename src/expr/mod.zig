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
pub const Context = ast_mod.Context;
pub const CmpOp = ast_mod.CmpOp;
pub const AddOp = ast_mod.AddOp;
pub const MulOp = ast_mod.MulOp;

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
// evaluate (stub — DSL-04/DSL-06 run)
// ---------------------------------------------------------------------------

/// Evaluate an already-parsed `Ast` against a variable `Context`.
///
/// This is a stub: the full evaluator is implemented in the DSL-04/DSL-06 run.
/// Returns `.err` with a placeholder message for now.
///
/// When implemented, returns `.ok` with the result `Value`, or `.err` on type error.
/// `allocator` will be used for intermediate allocations (not yet used by the stub).
pub fn evaluate(
    ast_in: *const Ast,
    ctx: *const Context,
    allocator: std.mem.Allocator,
) EvalResult {
    _ = ast_in;
    _ = ctx;
    _ = allocator;
    return EvalResult{ .err = EvalError{
        .message = "evaluator not yet implemented",
        .line = 0,
        .column = 0,
    } };
}
