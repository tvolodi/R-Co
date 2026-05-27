//! Public API for the Expression DSL — DSL-01, DSL-12
//!
//! Entry points (DSL-12):
//!   parse()    — tokenise + parse source into a ParsedExpr (immutable, cacheable)
//!   evaluate() — evaluate a ParsedExpr against a Context
//!
//! Re-exports all public types so callers import only this module.
//!
//! No I/O. No DB access. Pure functions (except now() which is intentionally impure).
const std = @import("std");
const parser_mod = @import("parser.zig");
const ast_mod = @import("ast.zig");
const err_mod = @import("error.zig");
const evaluator_mod = @import("evaluator.zig");

// ---------------------------------------------------------------------------
// Re-exports: AST and types
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

// ---------------------------------------------------------------------------
// Re-exports: Error types
// ---------------------------------------------------------------------------

pub const ParseError = err_mod.ParseError;
pub const EvalError = err_mod.EvalError;
pub const ExprError = err_mod.ExprError;

// ---------------------------------------------------------------------------
// Re-exports: Parser (old API, for backward compatibility)
// ---------------------------------------------------------------------------

pub const ParseResult = parser_mod.ParseResult;

// ---------------------------------------------------------------------------
// Re-exports: DSL-12 API (new public API)
// ---------------------------------------------------------------------------

pub const ParsedExpr = evaluator_mod.ParsedExpr;
pub const ExprMetadata = evaluator_mod.ExprMetadata;
pub const evaluate = evaluator_mod.evaluate;
pub const EvalResult = evaluator_mod.EvalResult;

// ---------------------------------------------------------------------------
// parse (DSL-12: returns ParsedExpr instead of Ast)
// ---------------------------------------------------------------------------

/// Parse an expression source string into an immutable ParsedExpr.
///
/// This is the main public API per DSL-12. The returned ParsedExpr owns an
/// arena allocator that backs the AST. Caller must call parseResult.deinit(allocator)
/// when done with the expression.
///
/// Parameters:
/// - allocator: memory allocator for the ParsedExpr arena
/// - source: the expression source code (e.g., "order.total > 100")
///
/// Returns:
/// - ok: a ParsedExpr ready for evaluation (caller must deinit)
/// - err: a slice of ParseError on syntax error (caller must free)
///
/// The returned ParsedExpr is:
/// - Immutable after construction
/// - Safe to cache and reuse indefinitely
/// - Safe to evaluate concurrently against different contexts
pub fn parse(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error!ParseExprResult {
    // Step 1: Use the parser to get an Ast
    const parse_result = try parser_mod.parse(allocator, source);

    return switch (parse_result) {
        .fail => |errs| ParseExprResult{ .fail = errs },
        .ok => |ast| blk: {
            // Step 2: Wrap the Ast in a ParsedExpr
            const parsed_expr: ParsedExpr = .{
                .root = ast.root,
                .arena = ast.arena,
                .metadata = .{
                    .eval_count = 0,
                    .total_eval_time_us = 0,
                    .ast_node_count = countNodes(ast.root),
                    .source_hash = hashSourceString(source),
                },
            };
            break :blk ParseExprResult{ .ok = parsed_expr };
        },
    };
}

/// Parse result: ParsedExpr on success, error list on failure
pub const ParseExprResult = union(enum) {
    ok: ParsedExpr,
    fail: []ParseError,
};

/// Count the total number of nodes in an AST (for metadata).
fn countNodes(node: *const Node) u32 {
    var count: u32 = 1;
    switch (node.*) {
        .null_literal, .bool_literal, .int_literal, .float_literal, .string_literal => {},
        .dot_path => {},
        .unary_neg => |u| count += countNodes(u.operand),
        .not_expr => |n| count += countNodes(n.operand),
        .and_expr => |bin| {
            count += countNodes(bin.left);
            count += countNodes(bin.right);
        },
        .or_expr => |bin| {
            count += countNodes(bin.left);
            count += countNodes(bin.right);
        },
        .cmp_expr => |cmp| {
            count += countNodes(cmp.left);
            count += countNodes(cmp.right);
        },
        .add_expr => |bin| {
            count += countNodes(bin.left);
            count += countNodes(bin.right);
        },
        .mul_expr => |bin| {
            count += countNodes(bin.left);
            count += countNodes(bin.right);
        },
        .func_call => |fc| {
            for (fc.args) |arg| {
                count += countNodes(arg);
            }
        },
    }
    return count;
}

/// Simple hash of a source string for metadata (debugging only).
fn hashSourceString(source: []const u8) u64 {
    var hash: u64 = 0;
    for (source) |ch| {
        const shift: u6 = @intCast(hash % 64);
        hash = hash ^ (@as(u64, @intCast(ch)) << shift);
        hash = hash ^ std.math.rotl(u64, hash, 7);
    }
    return hash;
}
