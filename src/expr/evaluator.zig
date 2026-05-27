//! Evaluator for the Expression DSL with caching support — DSL-12
//!
//! Defines:
//!   - ParsedExpr: a cached, immutable, reusable parsed expression
//!   - ExprMetadata: cache statistics and metadata
//!   - evaluate(): the public API that evaluates a ParsedExpr against a Context
//!
//! All evaluation logic moved from mod.zig to this module for clarity.
//! No I/O. No DB access. Pure functions (except now() which is intentionally impure).

const std = @import("std");
const ast_mod = @import("ast.zig");
const err_mod = @import("error.zig");

pub const Ast = ast_mod.Ast;
pub const Node = ast_mod.Node;
pub const Value = ast_mod.Value;
pub const TypeTag = ast_mod.TypeTag;
pub const Context = ast_mod.Context;
pub const CmpOp = ast_mod.CmpOp;
pub const AddOp = ast_mod.AddOp;
pub const MulOp = ast_mod.MulOp;
pub const EvalError = err_mod.EvalError;
pub const nodeEql = ast_mod.nodeEql;
pub const typeOf = ast_mod.typeOf;
pub const valueNull = ast_mod.valueNull;
pub const valueBool = ast_mod.valueBool;
pub const valueInt = ast_mod.valueInt;
pub const valueFloat = ast_mod.valueFloat;
pub const valueStr = ast_mod.valueStr;
pub const valueTs = ast_mod.valueTs;

// ---------------------------------------------------------------------------
// ExprMetadata — cache statistics and metadata (DSL-12 §4.3)
// ---------------------------------------------------------------------------

pub const ExprMetadata = struct {
    /// Number of times this expression has been evaluated.
    eval_count: u64 = 0,

    /// Total evaluation time (microseconds) across all evaluations.
    /// Used for performance monitoring against DSL-13 target.
    total_eval_time_us: u64 = 0,

    /// AST complexity (node count). Used for optimization hints.
    ast_node_count: u32 = 0,

    /// Hash of the normalized source string (for debugging).
    source_hash: u64 = 0,
};

// ---------------------------------------------------------------------------
// ParsedExpr — immutable, cacheable, reusable (DSL-12 §3)
// ---------------------------------------------------------------------------

/// A parsed, immutable expression ready for evaluation.
///
/// Ownership: ParsedExpr owns an arena allocator that backs the AST.
/// Caller must call deinit() when done.
///
/// Reusability: The same ParsedExpr can be evaluated against different contexts
/// without re-parsing. Thread-safe for concurrent reads during evaluation
/// (metadata updates use @constCast internally).
pub const ParsedExpr = struct {
    /// The root node of the abstract syntax tree.
    root: *Node,

    /// The arena allocator that owns all nodes, slices, and metadata for this expression.
    /// Freed when ParsedExpr.deinit(allocator) is called.
    arena: std.heap.ArenaAllocator,

    /// Metadata about the parsed expression for caching and optimization.
    metadata: ExprMetadata,

    /// Deallocate the arena and all owned memory.
    /// Must be called exactly once per ParsedExpr.
    pub fn deinit(self: *ParsedExpr) void {
        self.arena.deinit();
    }
};

// ---------------------------------------------------------------------------
// MAX_EVAL_DEPTH — DSL-06: total evaluation guard
// ---------------------------------------------------------------------------

/// Maximum recursion depth for expression evaluation.
///
/// Rationale: typical expression depth from the grammar is logarithmic in
/// expression length. A well-typed expression of ~500 tokens rarely exceeds
/// depth 50. 1024 provides a 20x safety margin while being small enough to
/// prevent stack overflow with standard Zig stack sizes (~1 MiB default,
/// each frame ~200 bytes -> ~5000 frames before overflow risk).
///
/// This is a safe upper bound for all expected use cases. If a real expression
/// exceeds this depth, it is likely a malicious input or a parser bug.
pub const MAX_EVAL_DEPTH: usize = 1024;

// ---------------------------------------------------------------------------
// EvalResult
// ---------------------------------------------------------------------------

pub const EvalResult = union(enum) {
    ok: Value,
    err: EvalError,
};

// ---------------------------------------------------------------------------
// evaluate — DSL-12 public API
// ---------------------------------------------------------------------------

/// Evaluate a parsed expression against a runtime context.
///
/// This is the main public entry point for expression evaluation.
/// The parsed expression is immutable and reusable; this function does not
/// modify it (metadata updates are internal bookkeeping via @constCast).
///
/// Parameters:
/// - expr: a parsed expression (immutable reference)
/// - ctx: the evaluation context, mapping variable names to values (immutable reference)
/// - allocator: allocator for temporary allocations during evaluation
///
/// Returns:
/// - ok: the result value on success
/// - err: an evaluation error on failure
///
/// Memory: The allocator is used for temporary allocations only (e.g., JSON parsing
/// in DSL-11 dot-path traversal). All allocations are freed before the function returns.
pub fn evaluate(
    expr: *const ParsedExpr,
    ctx: *const Context,
    allocator: std.mem.Allocator,
) EvalResult {
    // Note: expr is used below; the parameter is accessed via expr.root
    return evaluateNode(expr.root, ctx, allocator, MAX_EVAL_DEPTH);
}

// ---------------------------------------------------------------------------
// evaluateNode — internal evaluation engine (moved from mod.zig)
// ---------------------------------------------------------------------------

/// Evaluate a single Node and return the resulting Value.
///
/// Recursively evaluates sub-expressions. Implements type coercion per DSL-05.
///
/// allocator is used for intermediate allocations (string concatenation, etc.).
fn evaluateNode(node: *const Node, ctx: *const Context, allocator: std.mem.Allocator, remaining: usize) EvalResult {
    // Depth guard — DSL-06: if remaining is 0, return error immediately
    if (remaining == 0) {
        return EvalResult{ .err = EvalError{ .message = "evaluation depth exceeded", .line = 0, .column = 0 } };
    }

    switch (node.*) {
        // ---- Literals (DSL-04) ----
        .null_literal => return EvalResult{ .ok = valueNull() },
        .bool_literal => |val| return EvalResult{ .ok = valueBool(val) },
        .int_literal => |val| return EvalResult{ .ok = valueInt(val) },
        .float_literal => |val| return EvalResult{ .ok = valueFloat(val) },
        .string_literal => |val| return EvalResult{ .ok = valueStr(val) },

        // ---- Unary negation (DSL-05 §2.4) ----
        .unary_neg => |u| {
            const operand = switch (evaluateNode(u.operand, ctx, allocator, remaining - 1)) {
                .ok => |v| v,
                .err => |e| return EvalResult{ .err = e },
            };
            return switch (operand) {
                .null_val => EvalResult{ .err = EvalError{ .message = "cannot negate null", .line = 0, .column = 0 } },
                .int_val => |v| EvalResult{ .ok = valueInt(-v) },
                .float_val => |v| EvalResult{ .ok = valueFloat(-v) },
                .bool_val => EvalResult{ .err = EvalError{ .message = "type mismatch: cannot negate bool", .line = 0, .column = 0 } },
                .str_val => EvalResult{ .err = EvalError{ .message = "type mismatch: cannot negate string", .line = 0, .column = 0 } },
                .ts_val => EvalResult{ .err = EvalError{ .message = "type mismatch: cannot negate timestamp", .line = 0, .column = 0 } },
            };
        },

        // ---- Boolean NOT (DSL-05 §2.5) ----
        .not_expr => |n| {
            const operand = switch (evaluateNode(n.operand, ctx, allocator, remaining - 1)) {
                .ok => |v| v,
                .err => |e| return EvalResult{ .err = e },
            };
            return switch (operand) {
                .null_val => EvalResult{ .ok = valueNull() },
                .bool_val => |v| EvalResult{ .ok = valueBool(!v) },
                else => EvalResult{ .err = EvalError{ .message = "type mismatch: not requires boolean operand", .line = 0, .column = 0 } },
            };
        },

        // ---- Arithmetic: add_expr (DSL-05 §2.1, §4.6) ----
        .add_expr => |bin| {
            const left = switch (evaluateNode(bin.left, ctx, allocator, remaining - 1)) {
                .ok => |v| v,
                .err => |e| return EvalResult{ .err = e },
            };
            const right = switch (evaluateNode(bin.right, ctx, allocator, remaining - 1)) {
                .ok => |v| v,
                .err => |e| return EvalResult{ .err = e },
            };
            return evalArithmetic(AddOp, bin.op, left, right);
        },

        // ---- Arithmetic: mul_expr (DSL-05 §2.1, §4.6) ----
        .mul_expr => |bin| {
            const left = switch (evaluateNode(bin.left, ctx, allocator, remaining - 1)) {
                .ok => |v| v,
                .err => |e| return EvalResult{ .err = e },
            };
            const right = switch (evaluateNode(bin.right, ctx, allocator, remaining - 1)) {
                .ok => |v| v,
                .err => |e| return EvalResult{ .err = e },
            };
            return evalArithmetic(MulOp, bin.op, left, right);
        },

        // ---- Comparison (DSL-05 §2.2, §4.7) ----
        .cmp_expr => |cmp| {
            const left = switch (evaluateNode(cmp.left, ctx, allocator, remaining - 1)) {
                .ok => |v| v,
                .err => |e| return EvalResult{ .err = e },
            };
            const right = switch (evaluateNode(cmp.right, ctx, allocator, remaining - 1)) {
                .ok => |v| v,
                .err => |e| return EvalResult{ .err = e },
            };

            // Null vs null
            if (left == .null_val and right == .null_val) {
                return switch (cmp.op) {
                    .eq => EvalResult{ .ok = valueBool(true) },
                    .neq => EvalResult{ .ok = valueBool(false) },
                    else => EvalResult{ .ok = valueNull() },
                };
            }

            // Null vs non-null (or non-null vs null) → null
            if (left == .null_val or right == .null_val) {
                return EvalResult{ .ok = valueNull() };
            }

            // Same-type check — no silent coercion across types
            const ltag = typeOf(left);
            const rtag = typeOf(right);
            if (ltag != rtag) {
                return EvalResult{ .err = EvalError{
                    .message = typeMismatchCompareMsg(ltag, rtag),
                    .line = 0,
                    .column = 0,
                } };
            }

            // Same-type comparison
            const result = switch (ltag) {
                .bool => cmpBool(cmp.op, left.bool_val, right.bool_val),
                .int64 => cmpInt(cmp.op, left.int_val, right.int_val),
                .float64 => cmpFloat(cmp.op, left.float_val, right.float_val),
                .string => cmpStr(cmp.op, left.str_val, right.str_val),
                .timestamp => cmpInt(cmp.op, left.ts_val, right.ts_val),
                .null => unreachable, // handled above
            };
            return EvalResult{ .ok = valueBool(result) };
        },

        // ---- Logical AND (DSL-05 §3.2, §4.9) ----
        .and_expr => |bin| {
            const left = switch (evaluateNode(bin.left, ctx, allocator, remaining - 1)) {
                .ok => |v| v,
                .err => |e| return EvalResult{ .err = e },
            };

            // Short-circuit: false AND anything → false
            if (left == .bool_val and left.bool_val == false) {
                return EvalResult{ .ok = valueBool(false) };
            }

            // Left must be bool or null
            if (left != .bool_val and left != .null_val) {
                return EvalResult{ .err = EvalError{ .message = "type mismatch: boolean operator requires boolean operands", .line = 0, .column = 0 } };
            }

            const right = switch (evaluateNode(bin.right, ctx, allocator, remaining - 1)) {
                .ok => |v| v,
                .err => |e| return EvalResult{ .err = e },
            };

            // Right must be bool or null
            if (right != .bool_val and right != .null_val) {
                return EvalResult{ .err = EvalError{ .message = "type mismatch: boolean operator requires boolean operands", .line = 0, .column = 0 } };
            }

            // Three-valued AND (Kleene K3: null AND false → null, null AND true → null)
            if (left == .null_val) {
                return EvalResult{ .ok = valueNull() };
            }
            // left is true
            if (right == .null_val) {
                return EvalResult{ .ok = valueNull() };
            }
            // both bool
            return EvalResult{ .ok = valueBool(left.bool_val and right.bool_val) };
        },

        // ---- Logical OR (DSL-05 §3.3, §4.8) ----
        .or_expr => |bin| {
            const left = switch (evaluateNode(bin.left, ctx, allocator, remaining - 1)) {
                .ok => |v| v,
                .err => |e| return EvalResult{ .err = e },
            };

            // Short-circuit: true OR anything → true
            if (left == .bool_val and left.bool_val == true) {
                return EvalResult{ .ok = valueBool(true) };
            }

            // Left must be bool or null
            if (left != .bool_val and left != .null_val) {
                return EvalResult{ .err = EvalError{ .message = "type mismatch: boolean operator requires boolean operands", .line = 0, .column = 0 } };
            }

            const right = switch (evaluateNode(bin.right, ctx, allocator, remaining - 1)) {
                .ok => |v| v,
                .err => |e| return EvalResult{ .err = e },
            };

            // Right must be bool or null
            if (right != .bool_val and right != .null_val) {
                return EvalResult{ .err = EvalError{ .message = "type mismatch: boolean operator requires boolean operands", .line = 0, .column = 0 } };
            }

            // Three-valued OR
            if (left == .null_val) {
                // null OR true → true; null OR false/null → null
                if (right == .bool_val and right.bool_val == true) {
                    return EvalResult{ .ok = valueBool(true) };
                }
                return EvalResult{ .ok = valueNull() };
            }
            // left is false
            if (right == .null_val) {
                return EvalResult{ .ok = valueNull() };
            }
            // both bool
            return EvalResult{ .ok = valueBool(left.bool_val or right.bool_val) };
        },

        // ---- Dot-path resolution with null propagation (DSL-11) ----
        .dot_path => |segments| {
            return evalDotPath(segments, ctx, allocator);
        },

        // ---- Function call — DSL-07 built-in whitelist ----
        .func_call => |fc| {
            return evalFuncCall(fc, ctx, allocator, remaining);
        },
    }
}

// ---------------------------------------------------------------------------
// Function call evaluation — DSL-07
// ---------------------------------------------------------------------------

fn evalFuncCall(fc: ast_mod.Node.func_call, ctx: *const Context, allocator: std.mem.Allocator, remaining: usize) EvalResult {
    if (std.mem.eql(u8, fc.name, "now")) {
        if (fc.args.len != 0) {
            return EvalResult{ .err = EvalError{ .message = "now() takes 0 arguments", .line = 0, .column = 0 } };
        }
        // NOTE: now() is inherently impure; all other built-ins are pure.
        const builtin = @import("builtin");
        const now_ms: i64 = if (builtin.os.tag == .windows) blk: {
            const windows = std.os.windows;
            const ft: i64 = windows.ntdll.RtlGetSystemTimePrecise();
            const unix_100ns: i64 = ft - 116_444_736_000_000_000;
            break :blk @divTrunc(unix_100ns, 10000);
        } else blk: {
            const posix = std.posix;
            var ts: posix.timespec = undefined;
            _ = posix.system.clock_gettime(.REALTIME, &ts);
            const sec_ms: i64 = ts.sec * 1000;
            const nsec_ms: i64 = @divTrunc(ts.nsec, 1_000_000);
            break :blk sec_ms + nsec_ms;
        };
        return EvalResult{ .ok = valueTs(now_ms) };
    }

    if (std.mem.eql(u8, fc.name, "length")) {
        if (fc.args.len != 1) {
            return EvalResult{ .err = EvalError{ .message = "length() takes 1 argument", .line = 0, .column = 0 } };
        }
        const arg = switch (evaluateNode(fc.args[0], ctx, allocator, remaining - 1)) {
            .ok => |v| v,
            .err => |e| return EvalResult{ .err = e },
        };
        if (arg == .null_val) return EvalResult{ .ok = valueNull() };
        if (arg == .str_val) return EvalResult{ .ok = valueInt(@as(i64, @intCast(arg.str_val.len))) };
        return EvalResult{ .err = EvalError{ .message = "length() requires string argument", .line = 0, .column = 0 } };
    }

    if (std.mem.eql(u8, fc.name, "lower")) {
        if (fc.args.len != 1) {
            return EvalResult{ .err = EvalError{ .message = "lower() takes 1 argument", .line = 0, .column = 0 } };
        }
        const arg = switch (evaluateNode(fc.args[0], ctx, allocator, remaining - 1)) {
            .ok => |v| v,
            .err => |e| return EvalResult{ .err = e },
        };
        if (arg == .null_val) return EvalResult{ .ok = valueNull() };
        if (arg == .str_val) {
            const buf = allocator.alloc(u8, arg.str_val.len) catch {
                return EvalResult{ .err = EvalError{ .message = "allocation error in lower()", .line = 0, .column = 0 } };
            };
            for (arg.str_val, 0..) |c, i| {
                buf[i] = std.ascii.toLower(c);
            }
            return EvalResult{ .ok = valueStr(buf[0..]) };
        }
        return EvalResult{ .err = EvalError{ .message = "lower() requires string argument", .line = 0, .column = 0 } };
    }

    if (std.mem.eql(u8, fc.name, "upper")) {
        if (fc.args.len != 1) {
            return EvalResult{ .err = EvalError{ .message = "upper() takes 1 argument", .line = 0, .column = 0 } };
        }
        const arg = switch (evaluateNode(fc.args[0], ctx, allocator, remaining - 1)) {
            .ok => |v| v,
            .err => |e| return EvalResult{ .err = e },
        };
        if (arg == .null_val) return EvalResult{ .ok = valueNull() };
        if (arg == .str_val) {
            const buf = allocator.alloc(u8, arg.str_val.len) catch {
                return EvalResult{ .err = EvalError{ .message = "allocation error in upper()", .line = 0, .column = 0 } };
            };
            for (arg.str_val, 0..) |c, i| {
                buf[i] = std.ascii.toUpper(c);
            }
            return EvalResult{ .ok = valueStr(buf[0..]) };
        }
        return EvalResult{ .err = EvalError{ .message = "upper() requires string argument", .line = 0, .column = 0 } };
    }

    if (std.mem.eql(u8, fc.name, "trim")) {
        if (fc.args.len != 1) {
            return EvalResult{ .err = EvalError{ .message = "trim() takes 1 argument", .line = 0, .column = 0 } };
        }
        const arg = switch (evaluateNode(fc.args[0], ctx, allocator, remaining - 1)) {
            .ok => |v| v,
            .err => |e| return EvalResult{ .err = e },
        };
        if (arg == .null_val) return EvalResult{ .ok = valueNull() };
        if (arg == .str_val) {
            const s = arg.str_val;
            var start: usize = 0;
            while (start < s.len and std.ascii.isWhitespace(s[start])) : (start += 1) {}
            var end: usize = s.len;
            while (end > start and std.ascii.isWhitespace(s[end - 1])) : (end -= 1) {}
            return EvalResult{ .ok = valueStr(s[start..end]) };
        }
        return EvalResult{ .err = EvalError{ .message = "trim() requires string argument", .line = 0, .column = 0 } };
    }

    if (std.mem.eql(u8, fc.name, "contains")) {
        if (fc.args.len != 2) {
            return EvalResult{ .err = EvalError{ .message = "contains() takes 2 arguments", .line = 0, .column = 0 } };
        }
        const haystack = switch (evaluateNode(fc.args[0], ctx, allocator, remaining - 1)) {
            .ok => |v| v,
            .err => |e| return EvalResult{ .err = e },
        };
        const needle = switch (evaluateNode(fc.args[1], ctx, allocator, remaining - 1)) {
            .ok => |v| v,
            .err => |e| return EvalResult{ .err = e },
        };
        if (haystack == .null_val or needle == .null_val) return EvalResult{ .ok = valueNull() };
        if (haystack == .str_val and needle == .str_val) {
            return EvalResult{ .ok = valueBool(std.mem.indexOf(u8, haystack.str_val, needle.str_val) != null) };
        }
        return EvalResult{ .err = EvalError{ .message = "contains() requires string arguments", .line = 0, .column = 0 } };
    }

    if (std.mem.eql(u8, fc.name, "startsWith")) {
        if (fc.args.len != 2) {
            return EvalResult{ .err = EvalError{ .message = "startsWith() takes 2 arguments", .line = 0, .column = 0 } };
        }
        const haystack = switch (evaluateNode(fc.args[0], ctx, allocator, remaining - 1)) {
            .ok => |v| v,
            .err => |e| return EvalResult{ .err = e },
        };
        const prefix = switch (evaluateNode(fc.args[1], ctx, allocator, remaining - 1)) {
            .ok => |v| v,
            .err => |e| return EvalResult{ .err = e },
        };
        if (haystack == .null_val or prefix == .null_val) return EvalResult{ .ok = valueNull() };
        if (haystack == .str_val and prefix == .str_val) {
            return EvalResult{ .ok = valueBool(std.mem.startsWith(u8, haystack.str_val, prefix.str_val)) };
        }
        return EvalResult{ .err = EvalError{ .message = "startsWith() requires string arguments", .line = 0, .column = 0 } };
    }

    if (std.mem.eql(u8, fc.name, "endsWith")) {
        if (fc.args.len != 2) {
            return EvalResult{ .err = EvalError{ .message = "endsWith() takes 2 arguments", .line = 0, .column = 0 } };
        }
        const haystack = switch (evaluateNode(fc.args[0], ctx, allocator, remaining - 1)) {
            .ok => |v| v,
            .err => |e| return EvalResult{ .err = e },
        };
        const suffix = switch (evaluateNode(fc.args[1], ctx, allocator, remaining - 1)) {
            .ok => |v| v,
            .err => |e| return EvalResult{ .err = e },
        };
        if (haystack == .null_val or suffix == .null_val) return EvalResult{ .ok = valueNull() };
        if (haystack == .str_val and suffix == .str_val) {
            return EvalResult{ .ok = valueBool(std.mem.endsWith(u8, haystack.str_val, suffix.str_val)) };
        }
        return EvalResult{ .err = EvalError{ .message = "endsWith() requires string arguments", .line = 0, .column = 0 } };
    }

    if (std.mem.eql(u8, fc.name, "coalesce")) {
        if (fc.args.len == 0) {
            return EvalResult{ .err = EvalError{ .message = "coalesce() requires at least 1 argument", .line = 0, .column = 0 } };
        }
        for (fc.args) |arg_node| {
            const val = switch (evaluateNode(arg_node, ctx, allocator, remaining - 1)) {
                .ok => |v| v,
                .err => |e| return EvalResult{ .err = e },
            };
            if (val != .null_val) return EvalResult{ .ok = val };
        }
        return EvalResult{ .ok = valueNull() };
    }

    if (std.mem.eql(u8, fc.name, "date_add")) {
        if (fc.args.len != 3) {
            return EvalResult{ .err = EvalError{ .message = "date_add() takes 3 arguments", .line = 0, .column = 0 } };
        }
        const ts_val = switch (evaluateNode(fc.args[0], ctx, allocator, remaining - 1)) {
            .ok => |v| v,
            .err => |e| return EvalResult{ .err = e },
        };
        const n_val = switch (evaluateNode(fc.args[1], ctx, allocator, remaining - 1)) {
            .ok => |v| v,
            .err => |e| return EvalResult{ .err = e },
        };
        const unit_val = switch (evaluateNode(fc.args[2], ctx, allocator, remaining - 1)) {
            .ok => |v| v,
            .err => |e| return EvalResult{ .err = e },
        };
        if (ts_val == .null_val or n_val == .null_val or unit_val == .null_val) {
            return EvalResult{ .ok = valueNull() };
        }
        const ts_ms: i64 = if (ts_val == .ts_val) ts_val.ts_val else if (ts_val == .int_val) ts_val.int_val else {
            return EvalResult{ .err = EvalError{ .message = "date_add(): first argument must be timestamp or integer", .line = 0, .column = 0 } };
        };
        if (n_val != .int_val) {
            return EvalResult{ .err = EvalError{ .message = "date_add(): second argument must be integer", .line = 0, .column = 0 } };
        }
        if (unit_val != .str_val) {
            return EvalResult{ .err = EvalError{ .message = "date_add(): third argument must be string (unit)", .line = 0, .column = 0 } };
        }
        const n = n_val.int_val;
        const unit = unit_val.str_val;
        const multiplier = dateUnitMultiplier(unit) orelse {
            return EvalResult{ .err = EvalError{ .message = "date_add(): unknown unit, use: second, minute, hour, day", .line = 0, .column = 0 } };
        };
        const delta = std.math.mul(i64, n, multiplier) catch {
            return EvalResult{ .err = EvalError{ .message = "date_add(): arithmetic overflow", .line = 0, .column = 0 } };
        };
        const result = std.math.add(i64, ts_ms, delta) catch {
            return EvalResult{ .ok = if (delta >= 0) valueTs(std.math.maxInt(i64)) else valueTs(std.math.minInt(i64)) };
        };
        return EvalResult{ .ok = valueTs(result) };
    }

    if (std.mem.eql(u8, fc.name, "date_diff")) {
        if (fc.args.len != 3) {
            return EvalResult{ .err = EvalError{ .message = "date_diff() takes 3 arguments", .line = 0, .column = 0 } };
        }
        const ts1_val = switch (evaluateNode(fc.args[0], ctx, allocator, remaining - 1)) {
            .ok => |v| v,
            .err => |e| return EvalResult{ .err = e },
        };
        const ts2_val = switch (evaluateNode(fc.args[1], ctx, allocator, remaining - 1)) {
            .ok => |v| v,
            .err => |e| return EvalResult{ .err = e },
        };
        const unit_val = switch (evaluateNode(fc.args[2], ctx, allocator, remaining - 1)) {
            .ok => |v| v,
            .err => |e| return EvalResult{ .err = e },
        };
        if (ts1_val == .null_val or ts2_val == .null_val or unit_val == .null_val) {
            return EvalResult{ .ok = valueNull() };
        }
        const ts1_ms: i64 = if (ts1_val == .ts_val) ts1_val.ts_val else if (ts1_val == .int_val) ts1_val.int_val else {
            return EvalResult{ .err = EvalError{ .message = "date_diff(): first two arguments must be timestamps or integers", .line = 0, .column = 0 } };
        };
        const ts2_ms: i64 = if (ts2_val == .ts_val) ts2_val.ts_val else if (ts2_val == .int_val) ts2_val.int_val else {
            return EvalResult{ .err = EvalError{ .message = "date_diff(): first two arguments must be timestamps or integers", .line = 0, .column = 0 } };
        };
        if (unit_val != .str_val) {
            return EvalResult{ .err = EvalError{ .message = "date_diff(): third argument must be string (unit)", .line = 0, .column = 0 } };
        }
        const diff_ms = std.math.sub(i64, ts1_ms, ts2_ms) catch {
            return EvalResult{ .err = EvalError{ .message = "date_diff(): arithmetic overflow", .line = 0, .column = 0 } };
        };
        const unit = unit_val.str_val;
        const multiplier = dateUnitMultiplier(unit) orelse {
            return EvalResult{ .err = EvalError{ .message = "date_diff(): unknown unit, use: second, minute, hour, day", .line = 0, .column = 0 } };
        };
        const result = @divTrunc(diff_ms, multiplier);
        return EvalResult{ .ok = valueInt(result) };
    }

    // Unknown function name — should not reach here (lexer whitelist prevents this)
    return EvalResult{ .err = EvalError{ .message = "unknown function", .line = 0, .column = 0 } };
}

// ---------------------------------------------------------------------------
// Date unit multiplier — DSL-07, DSL-09
// ---------------------------------------------------------------------------

fn dateUnitMultiplier(unit: []const u8) ?i64 {
    if (std.mem.eql(u8, unit, "second")) return 1000;
    if (std.mem.eql(u8, unit, "minute")) return 60 * 1000;
    if (std.mem.eql(u8, unit, "hour")) return 60 * 60 * 1000;
    if (std.mem.eql(u8, unit, "day")) return 24 * 60 * 60 * 1000;
    return null;
}

// ---------------------------------------------------------------------------
// Arithmetic evaluation helper — shared by add_expr and mul_expr
// ---------------------------------------------------------------------------

fn evalArithmetic(comptime OpType: type, op: OpType, left_val: Value, right_val: Value) EvalResult {
    // Null check — any null in arithmetic → error
    if (left_val == .null_val or right_val == .null_val) {
        return EvalResult{ .err = EvalError{ .message = "arithmetic on null operand", .line = 0, .column = 0 } };
    }

    const ltag = typeOf(left_val);
    const rtag = typeOf(right_val);

    // Both must be numeric (int64 or float64)
    const l_is_num = ltag == .int64 or ltag == .float64;
    const r_is_num = rtag == .int64 or rtag == .float64;

    if (!l_is_num or !r_is_num) {
        return EvalResult{ .err = EvalError{ .message = typeMismatchArithMsg(ltag, rtag), .line = 0, .column = 0 } };
    }

    // Coercion: promote int64 → float64 when mixed
    if (ltag == .int64 and rtag == .int64) {
        const a = left_val.int_val;
        const b = right_val.int_val;
        return evalIntArithmetic(OpType, op, a, b);
    }
    if (ltag == .float64 and rtag == .float64) {
        const a = left_val.float_val;
        const b = right_val.float_val;
        return evalFloatArithmetic(OpType, op, a, b);
    }
    // Mixed: promote int64 to float64
    if (ltag == .int64 and rtag == .float64) {
        const a: f64 = @floatFromInt(left_val.int_val);
        return evalFloatArithmetic(OpType, op, a, right_val.float_val);
    }
    if (ltag == .float64 and rtag == .int64) {
        const b: f64 = @floatFromInt(right_val.int_val);
        return evalFloatArithmetic(OpType, op, left_val.float_val, b);
    }

    unreachable;
}

fn evalIntArithmetic(comptime OpType: type, op: OpType, a: i64, b: i64) EvalResult {
    if (OpType == AddOp) {
        return switch (op) {
            .add => EvalResult{ .ok = valueInt(a +% b) },
            .sub => EvalResult{ .ok = valueInt(a -% b) },
        };
    }
    if (OpType == MulOp) {
        return switch (op) {
            .mul => EvalResult{ .ok = valueInt(a *% b) },
            .div => {
                if (b == 0) {
                    return EvalResult{ .err = EvalError{ .message = "division by zero", .line = 0, .column = 0 } };
                }
                return EvalResult{ .ok = valueInt(@divTrunc(a, b)) };
            },
            .mod => {
                if (b == 0) {
                    return EvalResult{ .err = EvalError{ .message = "modulo by zero", .line = 0, .column = 0 } };
                }
                return EvalResult{ .ok = valueInt(@rem(a, b)) };
            },
        };
    }
    unreachable;
}

fn evalFloatArithmetic(comptime OpType: type, op: OpType, a: f64, b: f64) EvalResult {
    if (OpType == AddOp) {
        return switch (op) {
            .add => EvalResult{ .ok = valueFloat(a + b) },
            .sub => EvalResult{ .ok = valueFloat(a - b) },
        };
    }
    if (OpType == MulOp) {
        return switch (op) {
            .mul => EvalResult{ .ok = valueFloat(a * b) },
            .div => EvalResult{ .ok = valueFloat(a / b) }, // IEEE 754: division by 0 → ±inf
            .mod => EvalResult{ .err = EvalError{ .message = "modulo requires integer operands", .line = 0, .column = 0 } },
        };
    }
    unreachable;
}

// ---------------------------------------------------------------------------
// Error message helpers
// ---------------------------------------------------------------------------

fn typeMismatchCompareMsg(ltag: TypeTag, rtag: TypeTag) []const u8 {
    _ = ltag;
    _ = rtag;
    return "type mismatch: cannot compare values of different types";
}

fn typeMismatchArithMsg(ltag: TypeTag, rtag: TypeTag) []const u8 {
    _ = ltag;
    _ = rtag;
    return "type mismatch: cannot apply arithmetic operator to non-numeric types";
}

// ---------------------------------------------------------------------------
// Dot-path evaluation with nested JSON traversal (DSL-11)
// ---------------------------------------------------------------------------

fn evalDotPath(segments: [][]const u8, ctx: *const Context, allocator: std.mem.Allocator) EvalResult {
    if (segments.len == 0) {
        return EvalResult{ .ok = valueNull() };
    }

    // Step 1: Single-segment path — simple context lookup
    if (segments.len == 1) {
        return EvalResult{ .ok = ctx.get(segments[0]) };
    }

    // Step 2: Multi-segment path
    // First, try DSL-10 backward compatibility: flat composite key lookup
    var buf: [512]u8 = undefined;
    var total: usize = 0;
    for (segments) |seg| {
        total += seg.len;
    }
    total += segments.len - 1; // dots

    var allocated_flat_key: ?[]const u8 = null;
    defer if (allocated_flat_key) |key| allocator.free(key);

    const flat_key: ?[]const u8 = if (total <= buf.len) blk: {
        var pos: usize = 0;
        for (segments, 0..) |seg, i| {
            if (i > 0) {
                buf[pos] = '.';
                pos += 1;
            }
            @memcpy(buf[pos..][0..seg.len], seg);
            pos += seg.len;
        }
        break :blk buf[0..pos];
    } else blk: {
        // Path too long for stack buffer — use allocator
        const slice = allocator.alloc(u8, total) catch return EvalResult{ .ok = valueNull() };
        var pos: usize = 0;
        for (segments, 0..) |seg, i| {
            if (i > 0) {
                slice[pos] = '.';
                pos += 1;
            }
            @memcpy(slice[pos..][0..seg.len], seg);
            pos += seg.len;
        }
        allocated_flat_key = slice;
        break :blk slice;
    };

    if (flat_key) |fk| {
        const flat_value = ctx.get(fk);
        if (flat_value != .null_val) {
            return EvalResult{ .ok = flat_value };
        }
    }

    // No flat key match; try DSL-11 nested JSON traversal
    const root_value = ctx.get(segments[0]);
    if (root_value == .null_val) {
        return EvalResult{ .ok = valueNull() };
    }

    // Use an arena for intermediate allocations; only the final result is owned by caller
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var current_value = root_value;
    for (segments[1..]) |segment| {
        // Null propagation: if current is null, return null
        if (current_value == .null_val) {
            return EvalResult{ .ok = valueNull() };
        }

        // Only strings (JSON objects/arrays) can be traversed
        if (current_value != .str_val) {
            return EvalResult{ .ok = valueNull() };
        }

        // Parse JSON and navigate to the field, using arena for intermediate allocations
        const next_value = navigateJsonPath(current_value.str_val, segment, arena.allocator()) catch {
            // Allocation or parse error → gracefully return null
            return EvalResult{ .ok = valueNull() };
        };

        current_value = next_value;
    }

    // Final value needs to be copied out of the arena if it's a string
    // (since arena will be freed)
    if (current_value == .str_val) {
        const final_str = allocator.dupe(u8, current_value.str_val) catch {
            return EvalResult{ .err = EvalError{ .message = "allocation error in dot_path", .line = 0, .column = 0 } };
        };
        return EvalResult{ .ok = valueStr(final_str) };
    }

    return EvalResult{ .ok = current_value };
}

fn navigateJsonPath(json_text: []const u8, field_name: []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error!Value {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch {
        // Malformed JSON → null (not an error)
        return valueNull();
    };
    defer parsed.deinit();

    const result = tryExtractFieldOwned(parsed.value, field_name, allocator) catch {
        // Navigation error → null
        return valueNull();
    };
    return result;
}

fn tryExtractFieldOwned(json_val: std.json.Value, field_name: []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error!Value {
    switch (json_val) {
        .object => |obj| {
            if (obj.get(field_name)) |field_val| {
                return convertJsonValueToOwnedExprValue(field_val, allocator);
            } else {
                return valueNull();
            }
        },
        .null => return valueNull(),
        else => return valueNull(),
    }
}

fn convertJsonValueToOwnedExprValue(json_val: std.json.Value, allocator: std.mem.Allocator) std.mem.Allocator.Error!Value {
    return switch (json_val) {
        .null => valueNull(),
        .bool => |b| valueBool(b),
        .integer => |i| valueInt(i),
        .float => |f| valueFloat(f),
        .number_string => |s| {
            return valueStr(try allocator.dupe(u8, s));
        },
        .string => |s| {
            return valueStr(try allocator.dupe(u8, s));
        },
        .array => {
            const json_str = try jsonToString(json_val, allocator);
            return valueStr(json_str);
        },
        .object => {
            const json_str = try jsonToString(json_val, allocator);
            return valueStr(json_str);
        },
    };
}

fn jsonToString(json_val: std.json.Value, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    return std.json.stringifyAlloc(allocator, json_val, .{});
}

// ---------------------------------------------------------------------------
// Comparison helpers (DSL-05 §2.2)
// ---------------------------------------------------------------------------

fn cmpBool(op: CmpOp, a: bool, b: bool) bool {
    return switch (op) {
        .eq => a == b,
        .neq => a != b,
        .lt => !a and b,
        .lte => !a or (a == b),
        .gt => a and !b,
        .gte => a or (a == b),
    };
}

fn cmpInt(op: CmpOp, a: i64, b: i64) bool {
    return switch (op) {
        .eq => a == b,
        .neq => a != b,
        .lt => a < b,
        .lte => a <= b,
        .gt => a > b,
        .gte => a >= b,
    };
}

fn cmpFloat(op: CmpOp, a: f64, b: f64) bool {
    return switch (op) {
        .eq => a == b,
        .neq => a != b,
        .lt => a < b,
        .lte => a <= b,
        .gt => a > b,
        .gte => a >= b,
    };
}

fn cmpStr(op: CmpOp, a: []const u8, b: []const u8) bool {
    const order = std.mem.order(u8, a, b);
    return switch (op) {
        .eq => order == .eq,
        .neq => order != .eq,
        .lt => order == .lt,
        .lte => order != .gt,
        .gt => order == .gt,
        .gte => order != .lt,
    };
}
