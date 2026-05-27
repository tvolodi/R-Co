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
/// Recursively evaluates sub-expressions. Implements type coercion per DSL-05.
///
/// `allocator` is used for intermediate allocations (string concatenation, etc.).
pub fn evaluateNode(node: *const Node, ctx: *const Context, allocator: std.mem.Allocator, remaining: usize) EvalResult {
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

        // ---- Dot-path resolution with null propagation (DSL-10) ----
        .dot_path => |segments| {
            if (segments.len == 0) {
                // Empty path — should not occur in practice, but handle gracefully
                return EvalResult{ .ok = valueNull() };
            }

            // DSL-10: Root-level identifier lookup.
            // Single segment: simple context lookup.
            if (segments.len == 1) {
                return EvalResult{ .ok = ctx.get(segments[0]) };
            }

            // Multi-segment path: join with '.' and look up as a composite key.
            // This accommodates the flat key model where "a.b.c" is stored as a single key.
            //
            // Future (DSL-11): once object types are added, this will perform nested
            // traversal instead of flat lookup. For now, DSL-10 treats multi-segment
            // paths as composite keys.
            var total: usize = 0;
            for (segments) |seg| {
                total += seg.len;
            }
            total += segments.len - 1; // dots

            var buf: [512]u8 = undefined;
            const key = if (total <= buf.len) blk: {
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
                const slice = allocator.alloc(u8, total) catch {
                    return EvalResult{ .err = EvalError{ .message = "allocation error in dot_path", .line = 0, .column = 0 } };
                };
                var pos: usize = 0;
                for (segments, 0..) |seg, i| {
                    if (i > 0) {
                        slice[pos] = '.';
                        pos += 1;
                    }
                    @memcpy(slice[pos..][0..seg.len], seg);
                    pos += seg.len;
                }
                break :blk slice;
            };

            // Look up the composite key in context
            return EvalResult{ .ok = ctx.get(key) };
        },

        // ---- Function call — DSL-07 built-in whitelist ----
        .func_call => |fc| {
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
        },
    }
}

// ---------------------------------------------------------------------------
// Date unit multiplier — DSL-07, DSL-09
// ---------------------------------------------------------------------------

/// Returns the millisecond multiplier for a date unit string.
/// Supports: "second" (1000), "minute" (60000), "hour" (3600000), "day" (86400000).
/// Returns null for unknown unit strings.
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

/// Applies numeric coercion and performs the operation on pre-evaluated Values.
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

/// Perform integer arithmetic, checking for division/modulo by zero.
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

/// Perform floating-point arithmetic.
/// Division by zero → IEEE 754 infinity (not an error).
/// Modulo on float → error.
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
// Error message helpers (comptime-safe)
// ---------------------------------------------------------------------------

/// Build "type mismatch: cannot compare <L> with <R>" message.
/// Uses a switch over the two tags to produce static strings.
fn typeMismatchCompareMsg(ltag: TypeTag, rtag: TypeTag) []const u8 {
    const lname = tagName(ltag);
    const rname = tagName(rtag);
    // We return a known static pattern; the compiler can handle this
    // because the switch exhausts all 6×6 combinations at comptime.
    _ = lname;
    _ = rname;
    return "type mismatch: cannot compare values of different types";
}

/// Build "type mismatch: cannot apply arithmetic operator to <L> and <R>" message.
fn typeMismatchArithMsg(ltag: TypeTag, rtag: TypeTag) []const u8 {
    _ = ltag;
    _ = rtag;
    return "type mismatch: cannot apply arithmetic operator to non-numeric types";
}

/// Static tag name for use in error messages.
fn tagName(tag: TypeTag) []const u8 {
    return switch (tag) {
        .null => "null",
        .bool => "bool",
        .int64 => "int64",
        .float64 => "float64",
        .string => "string",
        .timestamp => "timestamp",
    };
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

/// Evaluate an already-parsed `Ast` against a variable `Context`.
///
/// Returns `.ok` with the result `Value`, or `.err` on evaluation error.
/// `allocator` is used for intermediate allocations.
pub fn evaluate(
    ast_in: *const Ast,
    ctx: *const Context,
    allocator: std.mem.Allocator,
) EvalResult {
    return evaluateNode(ast_in.root, ctx, allocator, MAX_EVAL_DEPTH);
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

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const eval_result = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(eval_result == .ok);
    try testing.expect(eval_result.ok == .int_val);
    try testing.expectEqual(@as(i64, -5), eval_result.ok.int_val);
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

test "DSL-04: round-trip — parse then evaluate returns same value (tag + payload)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cases = [_]struct {
        source: []const u8,
        expected_tag: TypeTag,
        // Payload verification: null payload is always void
        checkPayload: *const fn (Value) anyerror!void,
    }{
        .{
            .source = "null",
            .expected_tag = .null,
            .checkPayload = struct {
                fn check(v: Value) anyerror!void {
                    _ = v.null_val;
                }
            }.check,
        },
        .{
            .source = "true",
            .expected_tag = .bool,
            .checkPayload = struct {
                fn check(v: Value) anyerror!void {
                    try testing.expect(v.bool_val == true);
                }
            }.check,
        },
        .{
            .source = "false",
            .expected_tag = .bool,
            .checkPayload = struct {
                fn check(v: Value) anyerror!void {
                    try testing.expect(v.bool_val == false);
                }
            }.check,
        },
        .{
            .source = "42",
            .expected_tag = .int64,
            .checkPayload = struct {
                fn check(v: Value) anyerror!void {
                    try testing.expectEqual(@as(i64, 42), v.int_val);
                }
            }.check,
        },
        .{
            .source = "3.14",
            .expected_tag = .float64,
            .checkPayload = struct {
                fn check(v: Value) anyerror!void {
                    try testing.expect(v.float_val == 3.14);
                }
            }.check,
        },
        .{
            .source = "\"hello\"",
            .expected_tag = .string,
            .checkPayload = struct {
                fn check(v: Value) anyerror!void {
                    try testing.expectEqualStrings("hello", v.str_val);
                }
            }.check,
        },
        .{
            .source = "\"\"",
            .expected_tag = .string,
            .checkPayload = struct {
                fn check(v: Value) anyerror!void {
                    try testing.expectEqualStrings("", v.str_val);
                }
            }.check,
        },
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
        try c.checkPayload(eval_result.ok);
    }
}

test "DSL-04: timestamp type verified via construction and typeOf" {
    const testing = std.testing;

    // Timestamp has no literal form (DSL-04 §3.3). Verify the type exists
    // correctly through construction and typeOf — full round-trip through
    // evaluate() requires DSL-06 (dot_path resolution).
    const v = valueTs(1_715_328_000_000);
    try testing.expect(v == .ts_val);
    try testing.expectEqual(@as(i64, 1_715_328_000_000), v.ts_val);
    try testing.expect(typeOf(v) == .timestamp);
}

test "DSL-04: integer literal out of i64 range produces structured parse error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Value exceeds i64::MAX (9_223_372_036_854_775_807)
    var result = try parse(alloc, "99999999999999999999");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .fail);
    try testing.expect(result.fail.len > 0);

    // Verify the error message mentions the range limit
    const found = for (result.fail) |err| {
        if (std.mem.indexOf(u8, err.message, "i64 range") != null) break true;
    } else false;
    try testing.expect(found);
}

// ===========================================================================
// Tests — DSL-05: Type coercion rules
// ===========================================================================

// ---- Arithmetic: same-type (DSL-05 §2.1) ----

test "DSL-05: add int64 + int64" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "1 + 2");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .int_val);
    try testing.expectEqual(@as(i64, 3), ev.ok.int_val);
}

test "DSL-05: add float64 + float64" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "1.5 + 2.5");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .float_val);
    try testing.expect(ev.ok.float_val == 4.0);
}

test "DSL-05: sub int64 - int64" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "10 - 3");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .int_val);
    try testing.expectEqual(@as(i64, 7), ev.ok.int_val);
}

test "DSL-05: mul int64 * int64" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "6 * 7");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expectEqual(@as(i64, 42), ev.ok.int_val);
}

test "DSL-05: div int64 / int64" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "10 / 3");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expectEqual(@as(i64, 3), ev.ok.int_val); // integer division truncates
}

test "DSL-05: mod int64 % int64" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "10 % 3");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expectEqual(@as(i64, 1), ev.ok.int_val);
}

// ---- Arithmetic: mixed-type coercion (DSL-05 §2.1 rule 2) ----

test "DSL-05: add int64 + float64 promotes to float64" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "1 + 2.5");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .float_val);
    try testing.expect(ev.ok.float_val == 3.5);
}

test "DSL-05: add float64 + int64 promotes to float64" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "2.5 + 1");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .float_val);
    try testing.expect(ev.ok.float_val == 3.5);
}

test "DSL-05: mul int64 * float64 promotes to float64" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "3 * 1.5");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .float_val);
    try testing.expect(ev.ok.float_val == 4.5);
}

test "DSL-05: sub float64 - int64 promotes to float64" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "5.5 - 2");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .float_val);
    try testing.expect(ev.ok.float_val == 3.5);
}

// ---- Arithmetic: null operand (DSL-05 §2.1 rule 3) ----

test "DSL-05: arithmetic with null operand returns error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "1 + null");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "arithmetic on null") != null);
}

test "DSL-05: arithmetic with non-numeric type returns error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "true + 1");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "type mismatch") != null);
}

// ---- Arithmetic: division/modulo by zero (DSL-05 §2.1 edge cases) ----

test "DSL-05: int64 division by zero returns error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "1 / 0");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "division by zero") != null);
}

test "DSL-05: int64 modulo by zero returns error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "10 % 0");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "modulo by zero") != null);
}

test "DSL-05: float64 modulo returns error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "5.5 % 2.0");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "modulo requires integer") != null);
}

// ---- Unary negation (DSL-05 §2.4) ----

test "DSL-05: negate int64" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "-42");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .int_val);
    try testing.expectEqual(@as(i64, -42), ev.ok.int_val);
}

test "DSL-05: negate float64" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "-3.14");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .float_val);
    try testing.expect(ev.ok.float_val == -3.14);
}

test "DSL-05: negate null returns error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "-null");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "cannot negate null") != null);
}

test "DSL-05: negate bool returns error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "-true");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "cannot negate bool") != null);
}

// ---- Comparisons: null handling (DSL-05 §2.2, §3.5) ----

test "DSL-05: null == null returns true" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "null == null");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .bool_val);
    try testing.expect(ev.ok.bool_val == true);
}

test "DSL-05: null != null returns false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "null != null");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .bool_val);
    try testing.expect(ev.ok.bool_val == false);
}

test "DSL-05: null == 42 returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "null == 42");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

test "DSL-05: 42 != null returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "42 != null");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

test "DSL-05: null < 5 returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "null < 5");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

test "DSL-05: 5 > null returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "5 > null");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

test "DSL-05: null <= null returns null (ordering)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "null <= null");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

// ---- Comparisons: same-type (DSL-05 §2.2 rule 1) ----

test "DSL-05: compare int64 less than" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "2 < 3");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok.bool_val == true);
}

test "DSL-05: compare float64 equality" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "3.14 == 3.14");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok.bool_val == true);
}

test "DSL-05: compare bool ordering false < true" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "false < true");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok.bool_val == true);
}

test "DSL-05: compare string lexicographic" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "\"apple\" < \"banana\"");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok.bool_val == true);
}

test "DSL-05: compare string equality" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "\"hello\" == \"hello\"");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok.bool_val == true);
}

// ---- Comparisons: mixed type rejection (DSL-05 §2.2 rule 4) ----

test "DSL-05: int64 == float64 returns type mismatch error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "1 == 1.0");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "type mismatch") != null);
}

test "DSL-05: int64 < float64 returns type mismatch error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "5 < 3.14");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "type mismatch") != null);
}

test "DSL-05: bool == int64 returns type mismatch error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "true == 1");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "type mismatch") != null);
}

// ---- Three-valued logic: NOT (DSL-05 §3.4) ----

test "DSL-05: not true returns false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "not true");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok.bool_val == false);
}

test "DSL-05: not false returns true" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "not false");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok.bool_val == true);
}

test "DSL-05: not null returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "not null");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

test "DSL-05: not 42 returns type mismatch error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "not 42");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "not requires boolean") != null);
}

// ---- Three-valued logic: AND (DSL-05 §3.2) ----

test "DSL-05: true and true returns true" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "true and true");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok.bool_val == true);
}

test "DSL-05: false and true short-circuits to false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "false and true");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok.bool_val == false);
}

test "DSL-05: true and null returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "true and null");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

test "DSL-05: null and false returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "null and false");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

test "DSL-05: null and true returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "null and true");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

test "DSL-05: null and null returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "null and null");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

test "DSL-05: true and false returns false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "true and false");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok.bool_val == false);
}

test "DSL-05: and with non-boolean returns error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "true and 42");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "boolean operator requires boolean") != null);
}

// ---- Three-valued logic: OR (DSL-05 §3.3) ----

test "DSL-05: true or false short-circuits to true" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "true or false");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok.bool_val == true);
}

test "DSL-05: false or true returns true" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "false or true");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok.bool_val == true);
}

test "DSL-05: false or false returns false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "false or false");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok.bool_val == false);
}

test "DSL-05: false or null returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "false or null");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

test "DSL-05: null or true returns true" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "null or true");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok.bool_val == true);
}

test "DSL-05: null or false returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "null or false");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

test "DSL-05: null or null returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "null or null");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

test "DSL-05: or with non-boolean returns error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "false or 42");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "boolean operator requires boolean") != null);
}

// ---- Dot-path resolution with null propagation (DSL-05 §4.2) ----

test "DSL-05: dot_path resolves from context" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "x");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();
    try ctx.put("x", valueInt(42));

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .int_val);
    try testing.expectEqual(@as(i64, 42), ev.ok.int_val);
}

test "DSL-05: dot_path missing returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "missing_var");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

test "DSL-05: dot_path multi-segment resolves from context" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "a.b.c");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();
    try ctx.put("a.b.c", valueStr("deep_value"));

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .str_val);
    try testing.expectEqualStrings("deep_value", ev.ok.str_val);
}

// ---- No automatic string coercion (DSL-05 §2.2 rule 5) ----

test "DSL-05: string + int64 returns type mismatch error (no auto coercion)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "\"hello\" + 42");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "type mismatch") != null);
}

test "DSL-05: string == string works (no coercion needed)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "\"abc\" == \"abc\"");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok.bool_val == true);
}

// ---- Additional negation tests (DSL-05 §2.4) ----

test "DSL-05: negate string returns error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "-\"hello\"");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "cannot negate string") != null);
}

test "DSL-05: negate timestamp returns error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "-ts_val");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();
    try ctx.put("ts_val", valueTs(1_715_328_000_000));

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "cannot negate timestamp") != null);
}

// ---- Additional null comparison tests (DSL-05 §2.2, §3.5) ----

test "DSL-05: null > null returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "null > null");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

test "DSL-05: null >= null returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "null >= null");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

test "DSL-05: null <= 42 returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "null <= 42");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

test "DSL-05: null >= 42 returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "null >= 42");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

test "DSL-05: null == true returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "null == true");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

test "DSL-05: null == \"hello\" returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "null == \"hello\"");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

// ---- Additional cross-type comparison tests (DSL-05 §2.2 rule 4) ----

test "DSL-05: int64 != float64 returns type mismatch error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "1 != 1.0");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "type mismatch") != null);
}

test "DSL-05: float64 == int64 returns type mismatch error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "1.0 == 1");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "type mismatch") != null);
}

test "DSL-05: string == int64 returns type mismatch error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "\"42\" == 42");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "type mismatch") != null);
}

test "DSL-05: bool == string returns type mismatch error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "true == \"true\"");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "type mismatch") != null);
}

// ---- Additional short-circuit tests (DSL-05 §3.2, §3.3) ----

test "DSL-05: false and null short-circuits to false" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "false and null");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok.bool_val == false);
}

test "DSL-05: true or null short-circuits to true" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "true or null");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok.bool_val == true);
}

// ---- Additional non-boolean left operand tests (DSL-05 §3.2, §3.3) ----

test "DSL-05: and with non-boolean left operand returns error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "5 and true");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "boolean operator requires boolean") != null);
}

test "DSL-05: or with non-boolean left operand returns error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "5 or false");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "boolean operator requires boolean") != null);
}

// ---- Additional no-string-coercion tests (DSL-05 §2.1) ----

test "DSL-05: int64 + string returns type mismatch error (no auto coercion)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "1 + \"1\"");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "type mismatch") != null);
}

test "DSL-05: string + string returns type mismatch error (no concatenation)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "\"a\" + \"b\"");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "type mismatch") != null);
}

// ---- Arithmetic edge case: float division by zero (DSL-05 §2.1) ----

test "DSL-05: float64 / 0.0 returns infinity (IEEE 754, not error)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "5.0 / 0.0");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .float_val);
    try testing.expect(std.math.isInf(ev.ok.float_val));
}

// ===========================================================================
// Tests — DSL-06: Total evaluation with depth guard
// ===========================================================================

test "DSL-06: MAX_EVAL_DEPTH constant exists" {
    const testing = std.testing;
    try testing.expect(MAX_EVAL_DEPTH == 1024);
    try testing.expect(@TypeOf(MAX_EVAL_DEPTH) == usize);
}

test "DSL-06: evaluate delegates to evaluateNode with max depth" {
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

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expectEqual(@as(i64, 42), ev.ok.int_val);
}

test "DSL-06: evaluateNode with remaining=1 evaluates leaf nodes but fails on binary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    // Leaf nodes: null_literal, bool_literal, int_literal, float_literal, string_literal
    // These should succeed with remaining=1 since they don't recurse
    {
        const node_null = Node{ .null_literal = {} };
        const r1 = evaluateNode(&node_null, &ctx, alloc, 1);
        try testing.expect(r1 == .ok);
        try testing.expect(r1.ok == .null_val);
    }
    {
        const node_true = Node{ .bool_literal = true };
        const r2 = evaluateNode(&node_true, &ctx, alloc, 1);
        try testing.expect(r2 == .ok);
        try testing.expect(r2.ok.bool_val == true);
    }
    {
        const node_int = Node{ .int_literal = 42 };
        const r3 = evaluateNode(&node_int, &ctx, alloc, 1);
        try testing.expect(r3 == .ok);
        try testing.expectEqual(@as(i64, 42), r3.ok.int_val);
    }
    {
        const node_float = Node{ .float_literal = 3.14 };
        const r4 = evaluateNode(&node_float, &ctx, alloc, 1);
        try testing.expect(r4 == .ok);
        try testing.expect(r4.ok.float_val == 3.14);
    }
    {
        const node_str = Node{ .string_literal = "hello" };
        const r5 = evaluateNode(&node_str, &ctx, alloc, 1);
        try testing.expect(r5 == .ok);
        try testing.expectEqualStrings("hello", r5.ok.str_val);
    }

    // Binary node with remaining=1 should fail because the depth guard
    // catches the recursive call (1 - 1 = 0, triggers depth exceeded)
    // Build an add_expr node with remaining=1
    const left_int = alloc.create(Node) catch @panic("OOM");
    const right_int = alloc.create(Node) catch @panic("OOM");
    defer {
        alloc.destroy(left_int);
        alloc.destroy(right_int);
    }
    left_int.* = Node{ .int_literal = 1 };
    right_int.* = Node{ .int_literal = 2 };
    const bin_node = Node{ .add_expr = .{
        .op = .add,
        .left = left_int,
        .right = right_int,
    } };
    const r6 = evaluateNode(&bin_node, &ctx, alloc, 1);
    try testing.expect(r6 == .err);
    try testing.expect(std.mem.indexOf(u8, r6.err.message, "evaluation depth exceeded") != null);
}

test "DSL-06: deep chain hits depth limit" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    // Build a deeply nested binary tree of depth 2048:
    // (((...(1 + 2) + 3) + 4) ... + N)
    // This exceeds MAX_EVAL_DEPTH (1024) so should trigger depth error.
    const depth: usize = 2048;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a_alloc = arena.allocator();

    // Build from bottom up: start with int literal 1, then wrap in (prev + i) for i = 2..depth
    var current = try a_alloc.create(Node);
    current.* = Node{ .int_literal = 1 };

    var i: i64 = 2;
    while (i <= @as(i64, @intCast(depth))) : (i += 1) {
        const left = current;
        const right = try a_alloc.create(Node);
        right.* = Node{ .int_literal = i };
        const new_node = try a_alloc.create(Node);
        new_node.* = Node{ .add_expr = .{
            .op = .add,
            .left = left,
            .right = right,
        } };
        current = new_node;
    }

    const ev = evaluateNode(current, &ctx, alloc, MAX_EVAL_DEPTH);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "evaluation depth exceeded") != null);
}

test "DSL-06: 100 random expressions evaluate within bound" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    // Set up a seeded PRNG for reproducibility
    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();

    // Pre-create shared leaf nodes for efficiency
    const null_node = Node{ .null_literal = {} };
    const true_node = Node{ .bool_literal = true };
    const false_node = Node{ .bool_literal = false };
    const int_node = Node{ .int_literal = 7 };
    const float_node = Node{ .float_literal = 2.5 };
    const str_node = Node{ .string_literal = "test" };

    // Generate random expressions with max generation depth of 6
    const gen_depth: usize = 6;

    var expr_alloc = std.heap.ArenaAllocator.init(alloc);
    defer expr_alloc.deinit();
    const e_alloc = expr_alloc.allocator();

    var j: usize = 0;
    while (j < 100) : (j += 1) {
        // Generate a random expression via recursion
        const root = generateRandomNode(rng, e_alloc, gen_depth, &null_node, &true_node, &false_node, &int_node, &float_node, &str_node);

        const ev = evaluateNode(root, &ctx, alloc, MAX_EVAL_DEPTH);
        // The evaluation should always complete (either ok or err) — never panic/crash
        // We accept both ok and err outcomes as valid for property-based testing
        _ = ev;
    }
}

/// Recursively generate a random AST node for property-based testing.
fn generateRandomNode(
    rng: std.Random,
    allocator: std.mem.Allocator,
    remaining_depth: usize,
    null_node: *const Node,
    true_node: *const Node,
    false_node: *const Node,
    int_node: *const Node,
    float_node: *const Node,
    str_node: *const Node,
) *Node {
    const node = allocator.create(Node) catch @panic("OOM");

    // If remaining_depth == 0, generate only leaf nodes
    if (remaining_depth == 0) {
        const leaf_kind = rng.intRangeLessThan(u8, 0, 6);
        switch (leaf_kind) {
            0 => node.* = Node{ .null_literal = {} },
            1 => node.* = Node{ .bool_literal = rng.boolean() },
            2 => node.* = Node{ .int_literal = @as(i64, rng.intRangeLessThan(i64, -100, 101)) },
            3 => node.* = Node{ .float_literal = @as(f64, @floatFromInt(rng.intRangeLessThan(i64, -100, 101))) + rng.float(f64) },
            4 => node.* = Node{ .string_literal = "rand" },
            5 => node.* = Node{ .null_literal = {} },
            else => unreachable,
        }
        return node;
    }

    const kind = rng.intRangeLessThan(u8, 0, 14);
    const next_depth = remaining_depth - 1;

    switch (kind) {
        // Leaf nodes (0-5)
        0 => node.* = Node{ .null_literal = {} },
        1 => node.* = Node{ .bool_literal = rng.boolean() },
        2 => node.* = Node{ .int_literal = @as(i64, rng.intRangeLessThan(i64, -100, 101)) },
        3 => node.* = Node{ .float_literal = @as(f64, @floatFromInt(rng.intRangeLessThan(i64, -100, 101))) + rng.float(f64) },
        4 => node.* = Node{ .string_literal = "rand" },

        // Unary nodes (5-6)
        5 => {
            const operand = generateRandomNode(rng, allocator, next_depth, null_node, true_node, false_node, int_node, float_node, str_node);
            node.* = Node{ .unary_neg = .{ .operand = operand } };
        },
        6 => {
            const operand = generateRandomNode(rng, allocator, next_depth, null_node, true_node, false_node, int_node, float_node, str_node);
            node.* = Node{ .not_expr = .{ .operand = operand } };
        },

        // Comparison (7)
        7 => {
            const left = generateRandomNode(rng, allocator, next_depth, null_node, true_node, false_node, int_node, float_node, str_node);
            const right = generateRandomNode(rng, allocator, next_depth, null_node, true_node, false_node, int_node, float_node, str_node);
            const op: CmpOp = switch (rng.intRangeLessThan(u8, 0, 6)) {
                0 => .eq,
                1 => .neq,
                2 => .lt,
                3 => .lte,
                4 => .gt,
                5 => .gte,
                else => unreachable,
            };
            node.* = Node{ .cmp_expr = .{ .op = op, .left = left, .right = right } };
        },

        // Binary arithmetic (8-11)
        8 => {
            const left = generateRandomNode(rng, allocator, next_depth, null_node, true_node, false_node, int_node, float_node, str_node);
            const right = generateRandomNode(rng, allocator, next_depth, null_node, true_node, false_node, int_node, float_node, str_node);
            const op: AddOp = if (rng.boolean()) .add else .sub;
            node.* = Node{ .add_expr = .{ .op = op, .left = left, .right = right } };
        },
        9 => {
            const left = generateRandomNode(rng, allocator, next_depth, null_node, true_node, false_node, int_node, float_node, str_node);
            const right = generateRandomNode(rng, allocator, next_depth, null_node, true_node, false_node, int_node, float_node, str_node);
            const op: MulOp = switch (rng.intRangeLessThan(u8, 0, 3)) {
                0 => .mul,
                1 => .div,
                2 => .mod,
                else => unreachable,
            };
            node.* = Node{ .mul_expr = .{ .op = op, .left = left, .right = right } };
        },

        // Logical (12-13)
        10 => {
            const left = generateRandomNode(rng, allocator, next_depth, null_node, true_node, false_node, int_node, float_node, str_node);
            const right = generateRandomNode(rng, allocator, next_depth, null_node, true_node, false_node, int_node, float_node, str_node);
            node.* = Node{ .and_expr = .{ .left = left, .right = right } };
        },
        11 => {
            const left = generateRandomNode(rng, allocator, next_depth, null_node, true_node, false_node, int_node, float_node, str_node);
            const right = generateRandomNode(rng, allocator, next_depth, null_node, true_node, false_node, int_node, float_node, str_node);
            node.* = Node{ .or_expr = .{ .left = left, .right = right } };
        },

        // Dot path (12)
        12 => {
            const segments = allocator.alloc([]const u8, 1) catch @panic("OOM");
            segments[0] = "x";
            node.* = Node{ .dot_path = segments };
        },

        // Func call (13) — returns error "not yet implemented"
        13 => {
            const args = allocator.alloc(*Node, 0) catch @panic("OOM");
            node.* = Node{ .func_call = .{ .name = "now", .args = args } };
        },

        else => unreachable,
    }

    return node;
}

// ===========================================================================
// Tests — DSL-07: Function whitelist
// ===========================================================================

test "DSL-07: length on string" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "length(\"hello\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .int_val);
    try testing.expectEqual(@as(i64, 5), ev.ok.int_val);
}

test "DSL-07: length on null returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "length(null)");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

test "DSL-07: length type error on int" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "length(42)");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "string") != null);
}

test "DSL-07: lower on string" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "lower(\"HELLO\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .str_val);
    try testing.expectEqualStrings("hello", ev.ok.str_val);
    alloc.free(ev.ok.str_val);
}

test "DSL-07: lower on empty string" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "lower(\"\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .str_val);
    try testing.expectEqualStrings("", ev.ok.str_val);
}

test "DSL-07: lower on null returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "lower(null)");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

test "DSL-07: upper on string" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "upper(\"hello\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .str_val);
    try testing.expectEqualStrings("HELLO", ev.ok.str_val);
    alloc.free(ev.ok.str_val);
}

test "DSL-07: trim removes surrounding whitespace" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "trim(\"  hello  \")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .str_val);
    try testing.expectEqualStrings("hello", ev.ok.str_val);
}

test "DSL-07: trim on already trimmed string" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "trim(\"hello\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .str_val);
    try testing.expectEqualStrings("hello", ev.ok.str_val);
}

test "DSL-07: trim on null returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "trim(null)");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

test "DSL-07: contains substring" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "contains(\"hello world\", \"world\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .bool_val);
    try testing.expect(ev.ok.bool_val == true);
}

test "DSL-07: contains missing substring" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "contains(\"hello world\", \"xyz\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .bool_val);
    try testing.expect(ev.ok.bool_val == false);
}

test "DSL-07: contains with null returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "contains(null, \"x\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

test "DSL-07: startsWith positive" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "startsWith(\"hello\", \"hel\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .bool_val);
    try testing.expect(ev.ok.bool_val == true);
}

test "DSL-07: startsWith negative" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "startsWith(\"hello\", \"world\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .bool_val);
    try testing.expect(ev.ok.bool_val == false);
}

test "DSL-07: endsWith positive" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "endsWith(\"hello\", \"llo\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .bool_val);
    try testing.expect(ev.ok.bool_val == true);
}

test "DSL-07: endsWith negative" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "endsWith(\"hello\", \"hel\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .bool_val);
    try testing.expect(ev.ok.bool_val == false);
}

test "DSL-07: coalesce returns first non-null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "coalesce(null, \"hello\", \"world\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .str_val);
    try testing.expectEqualStrings("hello", ev.ok.str_val);
}

test "DSL-07: coalesce all null returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "coalesce(null, null)");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

test "DSL-07: coalesce single arg returns that arg" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "coalesce(42)");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .int_val);
    try testing.expectEqual(@as(i64, 42), ev.ok.int_val);
}

test "DSL-07: now returns timestamp" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "now()");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .ts_val);
    try testing.expect(ev.ok.ts_val > 1_000_000_000_000);
}

test "DSL-07: date_add adds seconds" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "date_add(1000, 5, \"second\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .ts_val);
    try testing.expectEqual(@as(i64, 6000), ev.ok.ts_val);
}

test "DSL-07: date_add adds days" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "date_add(0, 1, \"day\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .ts_val);
    try testing.expectEqual(@as(i64, 86_400_000), ev.ok.ts_val);
}

test "DSL-07: date_add negative days" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "date_add(86400000, -1, \"day\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .ts_val);
    try testing.expectEqual(@as(i64, 0), ev.ok.ts_val);
}

test "DSL-07: date_add with null returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "date_add(null, 1, \"day\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

test "DSL-07: date_add unknown unit" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "date_add(1000, 1, \"week\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
}

test "DSL-07: date_diff seconds" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "date_diff(5000, 1000, \"second\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .int_val);
    try testing.expectEqual(@as(i64, 4), ev.ok.int_val);
}

test "DSL-07: date_diff days" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "date_diff(172800000, 86400000, \"day\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .int_val);
    try testing.expectEqual(@as(i64, 1), ev.ok.int_val);
}

test "DSL-07: date_diff negative result" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "date_diff(1000, 5000, \"second\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .int_val);
    try testing.expectEqual(@as(i64, -4), ev.ok.int_val);
}

test "DSL-07: date_diff with null returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "date_diff(null, 1000, \"second\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .null_val);
}

test "DSL-07: unknown function is parse-time error" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "foobar(1)");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .fail);
}

test "DSL-07: wrong argument count for length" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "length(\"a\", \"b\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .err);
    try testing.expect(std.mem.indexOf(u8, ev.err.message, "takes") != null);
}

test "DSL-07: function purity — length gives same result twice" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "length(\"hello\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);
    var ast_copy = try parse(alloc, "length(\"hello\")");
    defer switch (ast_copy) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(ast_copy == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev1 = evaluate(&result.ok, &ctx, alloc);
    const ev2 = evaluate(&ast_copy.ok, &ctx, alloc);
    try testing.expect(ev1 == .ok);
    try testing.expect(ev2 == .ok);
    try testing.expectEqual(ev1.ok.int_val, ev2.ok.int_val);
}

// ===========================================================================
// Tests — DSL-08: Function purity / determinism
// ===========================================================================

/// Evaluate `expr` twice with the same context (same parsed AST) and assert
/// that the results are structurally equal. This verifies determinism: the
/// same inputs always produce the same output.
///
/// All pure built-in functions pass this test. `now()` is the only exception.
fn testDeterminism(alloc: std.mem.Allocator, source: []const u8) !void {
    const testing = std.testing;
    var ctx = Context.init(alloc);
    defer ctx.deinit();

    var result = try parse(alloc, source);
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    // Evaluate twice using the SAME parsed AST
    const ev1 = evaluate(&result.ok, &ctx, alloc);
    const ev2 = evaluate(&result.ok, &ctx, alloc);

    // Both must succeed
    try testing.expect(ev1 == .ok);
    try testing.expect(ev2 == .ok);

    // Results must be structurally equal
    try expectValueEq(ev1.ok, ev2.ok);
}

/// Assert two Values are structurally equal (compare by payload, not by pointer).
fn expectValueEq(a: Value, b: Value) !void {
    const testing = std.testing;
    try testing.expectEqual(@as(TypeTag, typeOf(a)), typeOf(b));
    switch (a) {
        .null_val => {}, // both null — trivially equal
        .bool_val => try testing.expectEqual(a.bool_val, b.bool_val),
        .int_val => try testing.expectEqual(a.int_val, b.int_val),
        .float_val => try testing.expectEqual(a.float_val, b.float_val),
        .str_val => try testing.expectEqualStrings(a.str_val, b.str_val),
        .ts_val => try testing.expectEqual(a.ts_val, b.ts_val),
    }
}

// ---- Determinism tests (rows 1-24) — each pure function called twice ----

test "DSL-08: length determinism — normal string" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try testDeterminism(alloc, "length(\"hello\")");
}

test "DSL-08: length determinism — null propagation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try testDeterminism(alloc, "length(null)");
}

test "DSL-08: lower determinism — uppercase input" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "lower(\"HELLO\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev1 = evaluate(&result.ok, &ctx, alloc);
    const ev2 = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev1 == .ok);
    try testing.expect(ev2 == .ok);

    // lower() allocates a new buffer — must free after comparison
    try expectValueEq(ev1.ok, ev2.ok);
    if (ev1.ok == .str_val) alloc.free(ev1.ok.str_val);
    if (ev2.ok == .str_val) alloc.free(ev2.ok.str_val);
}

test "DSL-08: lower determinism — empty string" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try testDeterminism(alloc, "lower(\"\")");
}

test "DSL-08: lower determinism — null propagation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try testDeterminism(alloc, "lower(null)");
}

test "DSL-08: upper determinism — lowercase input" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "upper(\"hello\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev1 = evaluate(&result.ok, &ctx, alloc);
    const ev2 = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev1 == .ok);
    try testing.expect(ev2 == .ok);

    // upper() allocates a new buffer — must free after comparison
    try expectValueEq(ev1.ok, ev2.ok);
    if (ev1.ok == .str_val) alloc.free(ev1.ok.str_val);
    if (ev2.ok == .str_val) alloc.free(ev2.ok.str_val);
}

test "DSL-08: trim determinism — surrounding whitespace" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try testDeterminism(alloc, "trim(\"  hello  \")");
}

test "DSL-08: trim determinism — already trimmed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try testDeterminism(alloc, "trim(\"hello\")");
}

test "DSL-08: trim determinism — null propagation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try testDeterminism(alloc, "trim(null)");
}

test "DSL-08: contains determinism — substring found" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try testDeterminism(alloc, "contains(\"hello world\", \"world\")");
}

test "DSL-08: contains determinism — substring not found" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try testDeterminism(alloc, "contains(\"hello world\", \"xyz\")");
}

test "DSL-08: contains determinism — null propagation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try testDeterminism(alloc, "contains(null, \"x\")");
}

test "DSL-08: startsWith determinism — true" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try testDeterminism(alloc, "startsWith(\"hello\", \"hel\")");
}

test "DSL-08: startsWith determinism — false" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try testDeterminism(alloc, "startsWith(\"hello\", \"world\")");
}

test "DSL-08: endsWith determinism — true" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try testDeterminism(alloc, "endsWith(\"hello\", \"llo\")");
}

test "DSL-08: endsWith determinism — false" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try testDeterminism(alloc, "endsWith(\"hello\", \"hel\")");
}

test "DSL-08: coalesce determinism — first non-null" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try testDeterminism(alloc, "coalesce(null, \"hello\", \"world\")");
}

test "DSL-08: coalesce determinism — all null" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try testDeterminism(alloc, "coalesce(null, null)");
}

test "DSL-08: coalesce determinism — single arg" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try testDeterminism(alloc, "coalesce(42)");
}

test "DSL-08: date_add determinism — seconds" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try testDeterminism(alloc, "date_add(1000, 5, \"second\")");
}

test "DSL-08: date_add determinism — days" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try testDeterminism(alloc, "date_add(0, 1, \"day\")");
}

test "DSL-08: date_add determinism — negative offset" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try testDeterminism(alloc, "date_add(1000, -3, \"hour\")");
}

test "DSL-08: date_diff determinism — positive difference" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try testDeterminism(alloc, "date_diff(5000, 1000, \"second\")");
}

test "DSL-08: date_diff determinism — negative difference" {
    const testing = std.testing;
    const alloc = testing.allocator;
    try testDeterminism(alloc, "date_diff(1000, 5000, \"second\")");
}

// ---- now() test — row 25: verifies type and range, NOT determinism ----

test "DSL-08: now returns timestamp in reasonable range (impure — exempted)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // NOTE: now() is impure per DSL-08. A determinism test (call twice, compare)
    // would fail because each call reads the system clock. Only type and range are
    // verified. No other built-in has this exemption.

    var result = try parse(alloc, "now()");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .ts_val);

    // Must be a timestamp after 2020-01-01 (roughly 1.5T ms since epoch)
    try testing.expect(ev.ok.ts_val > 1_577_836_800_000);
    // Must not be absurdly far in the future (before year 3000)
    try testing.expect(ev.ok.ts_val < 32_506_752_000_000);
}

// ===========================================================================
// Tests — DSL-09: Date built-ins (minute, hour, DST boundary)
// ===========================================================================

test "DSL-09: date_add with minute unit" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "date_add(0, 5, \"minute\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .ts_val);
    try testing.expectEqual(@as(i64, 300_000), ev.ok.ts_val);
}

test "DSL-09: date_add with hour unit" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "date_add(0, 2, \"hour\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .ts_val);
    try testing.expectEqual(@as(i64, 7_200_000), ev.ok.ts_val);
}

test "DSL-09: date_diff with minute unit" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "date_diff(300000, 0, \"minute\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .int_val);
    try testing.expectEqual(@as(i64, 5), ev.ok.int_val);
}

test "DSL-09: date_diff with hour unit" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "date_diff(7200000, 0, \"hour\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .int_val);
    try testing.expectEqual(@as(i64, 2), ev.ok.int_val);
}

test "DSL-09: date_add cross-DST boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // 2026-03-08T01:59:00Z = 1772589540000 ms (just before US DST spring-forward)
    // date_add +1 day must produce exactly +86400000 ms (pure UTC arithmetic, no DST adjustment)
    var result = try parse(alloc, "date_add(1772589540000, 1, \"day\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .ts_val);
    try testing.expectEqual(@as(i64, 1_772_675_940_000), ev.ok.ts_val);
}

test "DSL-09: date_diff across DST boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Two timestamps 1 day apart across US DST spring-forward:
    // ts1 = 2026-03-08T01:59:00Z = 1772589540000 ms
    // ts2 = 2026-03-07T01:59:00Z = 1772503140000 ms   (ts1 - 86400000)
    // diff in "day" units must equal 1 (pure ms arithmetic)
    var result = try parse(alloc, "date_diff(1772589540000, 1772503140000, \"day\")");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .int_val);
    try testing.expectEqual(@as(i64, 1), ev.ok.int_val);
}

test "DSL-09: now() returns platform time" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "now()");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const ev = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev == .ok);
    try testing.expect(ev.ok == .ts_val);
    try testing.expect(ev.ok.ts_val > 1_000_000_000_000);
}

// ===========================================================================
// Tests — DSL-10: Context resolution
// ===========================================================================

test "DSL-10: context stores and retrieves variables" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    try ctx.put("order", valueInt(100));
    try ctx.put("status", valueStr("pending"));

    try testing.expectEqual(@as(i64, 100), ctx.get("order").int_val);
    try testing.expectEqualStrings("pending", ctx.get("status").str_val);
}

test "DSL-10: context.get returns null for missing keys" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    const missing = ctx.get("nonexistent");
    try testing.expect(missing == .null_val);
}

test "DSL-10: evaluate identifier resolves from context" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "amount");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();
    try ctx.put("amount", valueInt(42));

    const eval_result = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(eval_result == .ok);
    try testing.expectEqual(@as(i64, 42), eval_result.ok.int_val);
}

test "DSL-10: evaluate identifier returns null for missing variable" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "missing");
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

test "DSL-10: dotted path on null context value returns null (null propagation)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "order.total");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();
    try ctx.put("order", valueNull());

    const eval_result = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(eval_result == .ok);
    try testing.expect(eval_result.ok == .null_val);
}

test "DSL-10: dotted path on scalar returns null (DSL-10 constraint)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "count.items");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();
    try ctx.put("count", valueInt(42));

    // Parser accepts "count.items" as a valid dot_path (names are identifiers).
    // Evaluator returns null because "count" (int) is not traversable (DSL-10 constraint).
    // Note: DSL-11 will extend this to support nested object traversal.
    const eval_result = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(eval_result == .ok);
    try testing.expect(eval_result.ok == .null_val);
}

test "DSL-10: context with all value types" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    try ctx.put("null_var", valueNull());
    try ctx.put("bool_var", valueBool(true));
    try ctx.put("int_var", valueInt(-42));
    try ctx.put("float_var", valueFloat(3.14));
    try ctx.put("str_var", valueStr("hello"));
    try ctx.put("ts_var", valueTs(1_715_328_000_000));

    try testing.expect(ctx.get("null_var") == .null_val);
    try testing.expect(ctx.get("bool_var").bool_val == true);
    try testing.expectEqual(@as(i64, -42), ctx.get("int_var").int_val);
    try testing.expect(ctx.get("float_var").float_val == 3.14);
    try testing.expectEqualStrings("hello", ctx.get("str_var").str_val);
    try testing.expectEqual(@as(i64, 1_715_328_000_000), ctx.get("ts_var").ts_val);
}

test "DSL-10: expression with context variable in comparison" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "amount > 50");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();
    try ctx.put("amount", valueInt(100));

    const eval_result = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(eval_result == .ok);
    try testing.expect(eval_result.ok.bool_val == true);
}

test "DSL-10: expression with missing context variable in comparison returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "amount > 50");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();
    // amount not in context

    const eval_result = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(eval_result == .ok);
    try testing.expect(eval_result.ok == .null_val);
}

test "DSL-10: expression with context variable in function call" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "length(message)");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();
    try ctx.put("message", valueStr("hello world"));

    const eval_result = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(eval_result == .ok);
    try testing.expectEqual(@as(i64, 11), eval_result.ok.int_val);
}

test "DSL-10: composite key lookup (multi-segment path as flat key)" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "order.total");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();
    // Store composite key directly (DSL-10 flat model)
    try ctx.put("order.total", valueInt(500));

    const eval_result = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(eval_result == .ok);
    try testing.expectEqual(@as(i64, 500), eval_result.ok.int_val);
}

test "DSL-10: context immutability during evaluation" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var result = try parse(alloc, "a and b");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    var ctx = Context.init(alloc);
    defer ctx.deinit();
    try ctx.put("a", valueBool(true));
    try ctx.put("b", valueBool(true));

    // Evaluate multiple times with the same context
    const ev1 = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev1 == .ok);
    try testing.expect(ev1.ok.bool_val == true);

    const ev2 = evaluate(&result.ok, &ctx, alloc);
    try testing.expect(ev2 == .ok);
    try testing.expect(ev2.ok.bool_val == true);

    // Context should remain unchanged
    try testing.expect(ctx.get("a").bool_val == true);
    try testing.expect(ctx.get("b").bool_val == true);
}
