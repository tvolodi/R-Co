// cel.zig — CEL (Common Expression Language) subset evaluator for EXCLUSIVE_GATEWAY.
//
// Supported grammar:
//   expr       → orExpr
//   orExpr     → andExpr ('||' andExpr)*
//   andExpr    → notExpr ('&&' notExpr)*
//   notExpr    → '!' notExpr | cmpExpr
//   cmpExpr    → primary (('=='|'!='|'<'|'>'|'<='|'>=') primary)?
//   primary    → 'true' | 'false' | integer | string | 'variables' '.' ident | '(' expr ')'
//
// Only top-level boolean results are accepted; numeric/string primaries are only valid
// as operands of comparison operators.

const std = @import("std");

pub const CelError = error{
    ParseError,
    EvalError,
    OutOfMemory,
};

// ---------------------------------------------------------------------------
// Internal value type
// ---------------------------------------------------------------------------
const Value = union(enum) {
    boolean: bool,
    numeric: f64,
    str: []const u8,
};

// ---------------------------------------------------------------------------
// Tokenizer
// ---------------------------------------------------------------------------
const TokKind = enum {
    kw_true,
    kw_false,
    kw_variables,
    ident,
    integer,
    string,
    op_eq,
    op_neq,
    op_lt,
    op_gt,
    op_leq,
    op_geq,
    op_and,
    op_or,
    op_not,
    lparen,
    rparen,
    dot,
    eof,
};

const Token = struct {
    kind: TokKind,
    num: f64 = 0,
    text: []const u8 = "",
};

fn tokenize(alloc: std.mem.Allocator, expr: []const u8) CelError!std.ArrayList(Token) {
    var toks = std.ArrayList(Token).empty;
    var i: usize = 0;
    while (i < expr.len) {
        // Skip whitespace
        switch (expr[i]) {
            ' ', '\t', '\n', '\r' => {
                i += 1;
                continue;
            },
            else => {},
        }
        // String literal
        if (expr[i] == '"') {
            i += 1;
            const start = i;
            while (i < expr.len and expr[i] != '"') : (i += 1) {}
            if (i >= expr.len) return CelError.ParseError;
            const text = expr[start..i];
            i += 1;
            try toks.append(alloc, .{ .kind = .string, .text = text });
            continue;
        }
        // Two-character operators (must check before single-char)
        if (i + 1 < expr.len) {
            const two = expr[i .. i + 2];
            if (std.mem.eql(u8, two, "==")) {
                try toks.append(alloc, .{ .kind = .op_eq });
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, two, "!=")) {
                try toks.append(alloc, .{ .kind = .op_neq });
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, two, "<=")) {
                try toks.append(alloc, .{ .kind = .op_leq });
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, two, ">=")) {
                try toks.append(alloc, .{ .kind = .op_geq });
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, two, "&&")) {
                try toks.append(alloc, .{ .kind = .op_and });
                i += 2;
                continue;
            }
            if (std.mem.eql(u8, two, "||")) {
                try toks.append(alloc, .{ .kind = .op_or });
                i += 2;
                continue;
            }
        }
        // Single-character operators and delimiters
        switch (expr[i]) {
            '<' => {
                try toks.append(alloc, .{ .kind = .op_lt });
                i += 1;
                continue;
            },
            '>' => {
                try toks.append(alloc, .{ .kind = .op_gt });
                i += 1;
                continue;
            },
            '!' => {
                try toks.append(alloc, .{ .kind = .op_not });
                i += 1;
                continue;
            },
            '(' => {
                try toks.append(alloc, .{ .kind = .lparen });
                i += 1;
                continue;
            },
            ')' => {
                try toks.append(alloc, .{ .kind = .rparen });
                i += 1;
                continue;
            },
            '.' => {
                try toks.append(alloc, .{ .kind = .dot });
                i += 1;
                continue;
            },
            else => {},
        }
        // Numeric literal (possibly negative: '-' followed immediately by a digit)
        if (std.ascii.isDigit(expr[i]) or
            (expr[i] == '-' and i + 1 < expr.len and std.ascii.isDigit(expr[i + 1])))
        {
            const start = i;
            if (expr[i] == '-') i += 1;
            while (i < expr.len and (std.ascii.isDigit(expr[i]) or expr[i] == '.')) : (i += 1) {}
            const num_str = expr[start..i];
            const num = std.fmt.parseFloat(f64, num_str) catch return CelError.ParseError;
            try toks.append(alloc, .{ .kind = .integer, .num = num });
            continue;
        }
        // Identifier or keyword
        if (std.ascii.isAlphabetic(expr[i]) or expr[i] == '_') {
            const start = i;
            while (i < expr.len and (std.ascii.isAlphanumeric(expr[i]) or expr[i] == '_')) : (i += 1) {}
            const word = expr[start..i];
            const kind: TokKind = if (std.mem.eql(u8, word, "true"))
                .kw_true
            else if (std.mem.eql(u8, word, "false"))
                .kw_false
            else if (std.mem.eql(u8, word, "variables"))
                .kw_variables
            else
                .ident;
            try toks.append(alloc, .{ .kind = kind, .text = word });
            continue;
        }
        return CelError.ParseError;
    }
    try toks.append(alloc, .{ .kind = .eof });
    return toks;
}

// ---------------------------------------------------------------------------
// Parser / evaluator (recursive descent)
// ---------------------------------------------------------------------------
const Parser = struct {
    toks: []const Token,
    pos: usize,
    vars: std.json.ObjectMap,

    fn peek(self: *const Parser) Token {
        return self.toks[self.pos];
    }

    fn consume(self: *Parser) Token {
        const t = self.toks[self.pos];
        self.pos += 1;
        return t;
    }

    fn expect(self: *Parser, kind: TokKind) CelError!Token {
        if (self.peek().kind != kind) return CelError.ParseError;
        return self.consume();
    }

    // expr → orExpr
    fn parseExpr(self: *Parser) CelError!Value {
        return self.parseOrExpr();
    }

    // orExpr → andExpr ('||' andExpr)*
    fn parseOrExpr(self: *Parser) CelError!Value {
        var left = try self.parseAndExpr();
        while (self.peek().kind == .op_or) {
            _ = self.consume();
            const right = try self.parseAndExpr();
            const lb = switch (left) {
                .boolean => |b| b,
                else => return CelError.EvalError,
            };
            const rb = switch (right) {
                .boolean => |b| b,
                else => return CelError.EvalError,
            };
            left = Value{ .boolean = lb or rb };
        }
        return left;
    }

    // andExpr → notExpr ('&&' notExpr)*
    fn parseAndExpr(self: *Parser) CelError!Value {
        var left = try self.parseNotExpr();
        while (self.peek().kind == .op_and) {
            _ = self.consume();
            const right = try self.parseNotExpr();
            const lb = switch (left) {
                .boolean => |b| b,
                else => return CelError.EvalError,
            };
            const rb = switch (right) {
                .boolean => |b| b,
                else => return CelError.EvalError,
            };
            left = Value{ .boolean = lb and rb };
        }
        return left;
    }

    // notExpr → '!' notExpr | cmpExpr
    fn parseNotExpr(self: *Parser) CelError!Value {
        if (self.peek().kind == .op_not) {
            _ = self.consume();
            const val = try self.parseNotExpr();
            const b = switch (val) {
                .boolean => |bv| bv,
                else => return CelError.EvalError,
            };
            return Value{ .boolean = !b };
        }
        return self.parseCmpExpr();
    }

    // cmpExpr → primary (cmpOp primary)?
    fn parseCmpExpr(self: *Parser) CelError!Value {
        const left = try self.parsePrimary();
        const pk = self.peek().kind;
        switch (pk) {
            .op_eq, .op_neq, .op_lt, .op_gt, .op_leq, .op_geq => {
                const op_tok = self.consume();
                const right = try self.parsePrimary();
                return applyCmp(left, op_tok.kind, right);
            },
            else => return left,
        }
    }

    // primary → 'true' | 'false' | integer | string | 'variables' '.' ident | '(' expr ')'
    fn parsePrimary(self: *Parser) CelError!Value {
        const t = self.peek();
        switch (t.kind) {
            .kw_true => {
                _ = self.consume();
                return Value{ .boolean = true };
            },
            .kw_false => {
                _ = self.consume();
                return Value{ .boolean = false };
            },
            .integer => {
                _ = self.consume();
                return Value{ .numeric = t.num };
            },
            .string => {
                _ = self.consume();
                return Value{ .str = t.text };
            },
            .kw_variables => {
                _ = self.consume();
                _ = try self.expect(.dot);
                const field_tok = try self.expect(.ident);
                const json_val = self.vars.get(field_tok.text) orelse return CelError.EvalError;
                return jsonToValue(json_val) orelse CelError.EvalError;
            },
            .lparen => {
                _ = self.consume();
                const val = try self.parseExpr();
                _ = try self.expect(.rparen);
                return val;
            },
            else => return CelError.ParseError,
        }
    }
};

fn jsonToValue(jv: std.json.Value) ?Value {
    return switch (jv) {
        .bool => |b| Value{ .boolean = b },
        .integer => |n| Value{ .numeric = @floatFromInt(n) },
        .float => |f| Value{ .numeric = f },
        .number_string => |s| blk: {
            const f = std.fmt.parseFloat(f64, s) catch return null;
            break :blk Value{ .numeric = f };
        },
        .string => |s| Value{ .str = s },
        else => null,
    };
}

fn applyCmp(left: Value, op: TokKind, right: Value) CelError!Value {
    switch (op) {
        .op_eq => return Value{ .boolean = try valEq(left, right) },
        .op_neq => return Value{ .boolean = !(try valEq(left, right)) },
        .op_lt, .op_gt, .op_leq, .op_geq => {
            const ln = switch (left) {
                .numeric => |n| n,
                else => return CelError.EvalError,
            };
            const rn = switch (right) {
                .numeric => |n| n,
                else => return CelError.EvalError,
            };
            const result = switch (op) {
                .op_lt => ln < rn,
                .op_gt => ln > rn,
                .op_leq => ln <= rn,
                .op_geq => ln >= rn,
                else => unreachable,
            };
            return Value{ .boolean = result };
        },
        else => return CelError.ParseError,
    }
}

fn valEq(a: Value, b: Value) CelError!bool {
    return switch (a) {
        .boolean => |av| switch (b) {
            .boolean => |bv| av == bv,
            else => CelError.EvalError,
        },
        .numeric => |an| switch (b) {
            .numeric => |bn| an == bn,
            else => CelError.EvalError,
        },
        .str => |as_| switch (b) {
            .str => |bs| std.mem.eql(u8, as_, bs),
            else => CelError.EvalError,
        },
    };
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Evaluate a CEL expression against the provided variables map.
/// Returns true if the expression evaluates to boolean true.
/// Returns CelError.EvalError if a variable is missing or types are incompatible.
/// Returns CelError.ParseError if the expression is syntactically invalid.
pub fn evaluate(
    allocator: std.mem.Allocator,
    expression: []const u8,
    variables: std.json.ObjectMap,
) CelError!bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const toks = try tokenize(arena_alloc, expression);
    var parser = Parser{
        .toks = toks.items,
        .pos = 0,
        .vars = variables,
    };
    const val = try parser.parseExpr();
    if (parser.peek().kind != .eof) return CelError.ParseError;
    return switch (val) {
        .boolean => |b| b,
        else => CelError.EvalError,
    };
}
