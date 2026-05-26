//! Recursive descent parser for the Expression DSL — DSL-01
//!
//! Consumes []Token produced by the lexer and produces an Ast.
//! On syntax errors, records ParseError entries and attempts recovery so that
//! multiple errors can be reported in a single pass (DSL-03).
//!
//! Grammar (from Architecture §5.1):
//!
//!   expr     := or_expr
//!   or_expr  := and_expr ('or' and_expr)*
//!   and_expr := not_expr ('and' not_expr)*
//!   not_expr := 'not'? cmp_expr
//!   cmp_expr := add_expr (('==' | '!=' | '<' | '<=' | '>' | '>=') add_expr)?
//!   add_expr := mul_expr (('+' | '-') mul_expr)*
//!   mul_expr := unary (('*' | '/' | '%') unary)*
//!   unary    := '-'? primary
//!   primary  := number | string | bool | null
//!             | identifier ('.' identifier)*
//!             | '(' expr ')'
//!             | func_call
//!   func_call := identifier '(' (expr (',' expr)*)? ')'
//!
//! No I/O. No DB access. Pure function.
const std = @import("std");
const ast_mod = @import("ast.zig");
const err_mod = @import("error.zig");
const lexer_mod = @import("lexer.zig");

pub const Token = ast_mod.Token;
pub const TokenKind = ast_mod.TokenKind;
pub const Node = ast_mod.Node;
pub const Ast = ast_mod.Ast;
pub const ParseError = err_mod.ParseError;

// ---------------------------------------------------------------------------
// ParseResult
// ---------------------------------------------------------------------------

pub const ParseResult = union(enum) {
    ok: Ast,
    fail: []ParseError,
};

// ---------------------------------------------------------------------------
// Parser state
// ---------------------------------------------------------------------------

const Parser = struct {
    tokens: []const Token,
    pos: usize,
    arena: *std.heap.ArenaAllocator,
    /// Allocator for the error list (separate from the arena so errors survive
    /// when the arena is freed on failure).
    error_alloc: std.mem.Allocator,
    errors: std.ArrayList(ParseError),

    fn init(tokens: []const Token, arena: *std.heap.ArenaAllocator, error_alloc: std.mem.Allocator) Parser {
        return Parser{
            .tokens = tokens,
            .pos = 0,
            .arena = arena,
            .error_alloc = error_alloc,
            .errors = .empty,
        };
    }

    // ---- Token access ----

    fn peek(self: *Parser) Token {
        if (self.pos < self.tokens.len) return self.tokens[self.pos];
        // Defensive: return last token (always eof if lexer is correct)
        return self.tokens[self.tokens.len - 1];
    }

    fn advance(self: *Parser) Token {
        const tok = self.peek();
        if (self.pos < self.tokens.len) self.pos += 1;
        return tok;
    }

    fn check(self: *Parser, kind: TokenKind) bool {
        return self.peek().kind == kind;
    }

    fn match(self: *Parser, kind: TokenKind) ?Token {
        if (self.check(kind)) return self.advance();
        return null;
    }

    fn expect(self: *Parser, kind: TokenKind, msg: []const u8) ?Token {
        if (self.check(kind)) return self.advance();
        const t = self.peek();
        self.recordError(t, msg);
        return null;
    }

    // ---- Error recording ----

    fn recordError(self: *Parser, tok: Token, msg: []const u8) void {
        self.errors.append(self.error_alloc, .{
            .line = tok.line,
            .column = tok.column,
            .token = tok.lexeme,
            .message = msg,
        }) catch {}; // OOM: silently drop — we already have a parser state
    }

    // ---- Error recovery: advance to next synchronisation point ----
    // Sync points: .rparen, .comma, .eof

    fn synchronize(self: *Parser) void {
        while (true) {
            const kind = self.peek().kind;
            if (kind == .eof or kind == .rparen or kind == .comma) return;
            _ = self.advance();
        }
    }

    // ---- Node allocation ----

    fn allocNode(self: *Parser, value: Node) std.mem.Allocator.Error!*Node {
        const alloc = self.arena.allocator();
        const ptr = try alloc.create(Node);
        ptr.* = value;
        return ptr;
    }

    // Sentinel: returned when a syntax error is encountered but we want to
    // continue parsing (error recovery).
    fn sentinel(self: *Parser) std.mem.Allocator.Error!*Node {
        return self.allocNode(Node{ .null_literal = {} });
    }

    // ---- Grammar productions ----

    pub fn parseExpr(self: *Parser) std.mem.Allocator.Error!*Node {
        return self.parseOrExpr();
    }

    fn parseOrExpr(self: *Parser) std.mem.Allocator.Error!*Node {
        var left = try self.parseAndExpr();
        while (self.match(.or_kw) != null) {
            const right = try self.parseAndExpr();
            left = try self.allocNode(Node{ .or_expr = .{ .left = left, .right = right } });
        }
        return left;
    }

    fn parseAndExpr(self: *Parser) std.mem.Allocator.Error!*Node {
        var left = try self.parseNotExpr();
        while (self.match(.and_kw) != null) {
            const right = try self.parseNotExpr();
            left = try self.allocNode(Node{ .and_expr = .{ .left = left, .right = right } });
        }
        return left;
    }

    fn parseNotExpr(self: *Parser) std.mem.Allocator.Error!*Node {
        if (self.match(.not_kw) != null) {
            const operand = try self.parseCmpExpr();
            return self.allocNode(Node{ .not_expr = .{ .operand = operand } });
        }
        return self.parseCmpExpr();
    }

    fn parseCmpExpr(self: *Parser) std.mem.Allocator.Error!*Node {
        const left = try self.parseAddExpr();
        const op: ast_mod.CmpOp = switch (self.peek().kind) {
            .eq => .eq,
            .neq => .neq,
            .lt => .lt,
            .lte => .lte,
            .gt => .gt,
            .gte => .gte,
            else => return left,
        };
        _ = self.advance(); // consume operator token
        const right = try self.parseAddExpr();
        return self.allocNode(Node{ .cmp_expr = .{ .op = op, .left = left, .right = right } });
    }

    fn parseAddExpr(self: *Parser) std.mem.Allocator.Error!*Node {
        var left = try self.parseMulExpr();
        while (true) {
            const op: ast_mod.AddOp = switch (self.peek().kind) {
                .plus => .add,
                .minus => .sub,
                else => break,
            };
            _ = self.advance();
            const right = try self.parseMulExpr();
            left = try self.allocNode(Node{ .add_expr = .{ .op = op, .left = left, .right = right } });
        }
        return left;
    }

    fn parseMulExpr(self: *Parser) std.mem.Allocator.Error!*Node {
        var left = try self.parseUnary();
        while (true) {
            const op: ast_mod.MulOp = switch (self.peek().kind) {
                .star => .mul,
                .slash => .div,
                .percent => .mod,
                else => break,
            };
            _ = self.advance();
            const right = try self.parseUnary();
            left = try self.allocNode(Node{ .mul_expr = .{ .op = op, .left = left, .right = right } });
        }
        return left;
    }

    fn parseUnary(self: *Parser) std.mem.Allocator.Error!*Node {
        if (self.match(.minus) != null) {
            const operand = try self.parsePrimary();
            return self.allocNode(Node{ .unary_neg = .{ .operand = operand } });
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) std.mem.Allocator.Error!*Node {
        const tok = self.peek();

        switch (tok.kind) {
            // Integer literal
            .int_literal => {
                _ = self.advance();
                const val = std.fmt.parseInt(i64, tok.lexeme, 10) catch blk: {
                    // Already recorded as lex error; use 0 as sentinel value
                    break :blk @as(i64, 0);
                };
                return self.allocNode(Node{ .int_literal = val });
            },

            // Float literal
            .float_literal => {
                _ = self.advance();
                const val = std.fmt.parseFloat(f64, tok.lexeme) catch 0.0;
                return self.allocNode(Node{ .float_literal = val });
            },

            // String literal
            .string_literal => {
                _ = self.advance();
                // Strip surrounding quotes; the lexeme includes them
                const inner = if (tok.lexeme.len >= 2) tok.lexeme[1 .. tok.lexeme.len - 1] else tok.lexeme;
                return self.allocNode(Node{ .string_literal = inner });
            },

            // Boolean true
            .true_kw => {
                _ = self.advance();
                return self.allocNode(Node{ .bool_literal = true });
            },

            // Boolean false
            .false_kw => {
                _ = self.advance();
                return self.allocNode(Node{ .bool_literal = false });
            },

            // Null
            .null_kw => {
                _ = self.advance();
                return self.allocNode(Node{ .null_literal = {} });
            },

            // Grouped expression: '(' expr ')'
            .lparen => {
                _ = self.advance();
                const inner = try self.parseExpr();
                if (self.expect(.rparen, "expected ')'") == null) {
                    self.synchronize();
                }
                return inner;
            },

            // Identifier or builtin_func: dot_path or func_call
            .identifier, .builtin_func => {
                return self.parseIdentOrCall();
            },

            // Error: unexpected token
            else => {
                self.recordError(tok, "expected expression");
                self.synchronize();
                return self.sentinel();
            },
        }
    }

    /// Parse `identifier ('.' identifier)*` or `builtin_func '(' args ')'`.
    /// After consuming the first identifier/builtin token, we peek at the next:
    ///   - '(' and identifier token: error (unknown function)
    ///   - '(' and builtin_func token: func_call
    ///   - '.' : dot_path continuation
    ///   - otherwise: single-segment dot_path
    fn parseIdentOrCall(self: *Parser) std.mem.Allocator.Error!*Node {
        const first = self.advance();
        const alloc = self.arena.allocator();

        // Check for function call: identifier followed by '('
        if (self.check(.lparen)) {
            if (first.kind == .identifier) {
                // Unknown function — DSL-07: parse error
                self.recordError(first, "unknown function: only whitelisted built-ins are callable");
                _ = self.advance(); // consume '('
                // consume arguments for recovery
                _ = try self.consumeArgList();
                return self.sentinel();
            }
            // builtin_func '(' args ')'
            _ = self.advance(); // consume '('
            const args = try self.consumeArgList();
            return self.allocNode(Node{ .func_call = .{ .name = first.lexeme, .args = args } });
        }

        // Dot-path: collect segments
        var segments: std.ArrayList([]const u8) = .empty;
        try segments.append(alloc, first.lexeme);

        while (self.check(.dot)) {
            _ = self.advance(); // consume '.'
            const seg_tok = self.peek();
            if (seg_tok.kind == .identifier or seg_tok.kind == .builtin_func) {
                _ = self.advance();
                try segments.append(alloc, seg_tok.lexeme);
            } else {
                self.recordError(seg_tok, "expected identifier after '.'");
                break;
            }
        }

        const path = try segments.toOwnedSlice(alloc);
        return self.allocNode(Node{ .dot_path = path });
    }

    /// Parse a comma-separated argument list up to the closing ')'.
    /// Consumes the closing ')'.  Returns a slice of argument nodes.
    fn consumeArgList(self: *Parser) std.mem.Allocator.Error![]*Node {
        const alloc = self.arena.allocator();
        var args: std.ArrayList(*Node) = .empty;

        if (!self.check(.rparen)) {
            const first_arg = try self.parseExpr();
            try args.append(alloc, first_arg);

            while (self.match(.comma) != null) {
                if (self.check(.rparen)) break; // trailing comma allowed
                const arg = try self.parseExpr();
                try args.append(alloc, arg);
            }
        }

        _ = self.expect(.rparen, "expected ')' after argument list");
        return args.toOwnedSlice(alloc);
    }
};

// ---------------------------------------------------------------------------
// parse — public entry point
// ---------------------------------------------------------------------------

/// Parse `source` into an `Ast`.
/// On success: returns `.ok` with an `Ast` whose arena is owned by the caller.
///   Call `ast.deinit()` when done.
/// On failure: returns `.fail` with a slice of `ParseError` allocated from
///   `allocator`.  Call `allocator.free(errors)` when done.
/// Lex errors are merged into the parse error list.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error!ParseResult {
    // Tokenise into a temporary arena so we can free it when done.
    var lex_arena = std.heap.ArenaAllocator.init(allocator);
    defer lex_arena.deinit();
    const lex_alloc = lex_arena.allocator();

    const lex_result = try lexer_mod.tokenize(lex_alloc, source);

    // Create the AST arena (transferred to the Ast on success).
    var ast_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer ast_arena.deinit();

    // Error list uses the caller allocator so it survives if we return .fail.
    var p = Parser.init(lex_result.tokens, &ast_arena, allocator);

    // Merge any lex errors first.
    for (lex_result.errors) |le| {
        p.errors.append(allocator, le) catch {};
    }

    // Run the parser.
    const root = try p.parseExpr();

    // Check that we consumed all input (except eof).
    if (!p.check(.eof)) {
        const tok = p.peek();
        p.recordError(tok, "unexpected token after expression");
    }

    // If there are any errors, return failure.
    if (p.errors.items.len > 0) {
        const errs = try p.errors.toOwnedSlice(allocator);
        ast_arena.deinit(); // free the arena since we won't return it
        return ParseResult{ .fail = errs };
    }

    p.errors.deinit(allocator);

    return ParseResult{ .ok = Ast{
        .root = root,
        .arena = ast_arena,
    } };
}

// ===========================================================================
// Unit tests — at least one positive + one negative case per grammar production
// ===========================================================================

test "or_expr positive: a or b" {
    const alloc = std.testing.allocator;

    var result = try parse(alloc, "true or false");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try std.testing.expect(result == .ok);
    try std.testing.expect(result.ok.root.* == .or_expr);
}

test "or_expr negative: trailing or" {
    const alloc = std.testing.allocator;

    var result = try parse(alloc, "true or");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try std.testing.expect(result == .fail);
    const errors = result.fail;
    try std.testing.expect(errors.len > 0);
    try std.testing.expect(errors[0].line > 0);
    try std.testing.expect(errors[0].column > 0);
}

test "and_expr positive: a and b" {
    const alloc = std.testing.allocator;

    var result = try parse(alloc, "true and false");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try std.testing.expect(result == .ok);
    try std.testing.expect(result.ok.root.* == .and_expr);
}

test "and_expr negative: trailing and" {
    const alloc = std.testing.allocator;

    var result = try parse(alloc, "true and");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try std.testing.expect(result == .fail);
}

test "not_expr positive: not true" {
    const alloc = std.testing.allocator;

    var result = try parse(alloc, "not true");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try std.testing.expect(result == .ok);
    try std.testing.expect(result.ok.root.* == .not_expr);
}

test "not_expr negative: not alone" {
    const alloc = std.testing.allocator;

    var result = try parse(alloc, "not");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    // "not" followed by eof triggers "expected expression" in parsePrimary
    try std.testing.expect(result == .fail);
}

test "cmp_expr positive: a == b" {
    const alloc = std.testing.allocator;

    var result = try parse(alloc, "42 == 42");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try std.testing.expect(result == .ok);
    try std.testing.expect(result.ok.root.* == .cmp_expr);
    try std.testing.expect(result.ok.root.cmp_expr.op == .eq);
}

test "cmp_expr negative: == with no right-hand side" {
    const alloc = std.testing.allocator;

    var result = try parse(alloc, "42 ==");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try std.testing.expect(result == .fail);
}

test "add_expr positive: 1 + 2" {
    const alloc = std.testing.allocator;

    var result = try parse(alloc, "1 + 2");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try std.testing.expect(result == .ok);
    try std.testing.expect(result.ok.root.* == .add_expr);
    try std.testing.expect(result.ok.root.add_expr.op == .add);
}

test "add_expr negative: trailing +" {
    const alloc = std.testing.allocator;

    var result = try parse(alloc, "1 +");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try std.testing.expect(result == .fail);
}

test "mul_expr positive: 2 * 3" {
    const alloc = std.testing.allocator;

    var result = try parse(alloc, "2 * 3");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try std.testing.expect(result == .ok);
    try std.testing.expect(result.ok.root.* == .mul_expr);
    try std.testing.expect(result.ok.root.mul_expr.op == .mul);
}

test "mul_expr negative: trailing *" {
    const alloc = std.testing.allocator;

    var result = try parse(alloc, "2 *");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try std.testing.expect(result == .fail);
}

test "unary positive: -5" {
    const alloc = std.testing.allocator;

    var result = try parse(alloc, "-5");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try std.testing.expect(result == .ok);
    try std.testing.expect(result.ok.root.* == .unary_neg);
}

test "unary negative: lone minus" {
    const alloc = std.testing.allocator;

    var result = try parse(alloc, "-");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try std.testing.expect(result == .fail);
}

test "primary literals positive: int, float, string, bool, null" {
    const alloc = std.testing.allocator;

    {
        var r = try parse(alloc, "42");
        defer switch (r) {
            .ok => |*a| a.deinit(),
            .fail => |e| alloc.free(e),
        };
        try std.testing.expect(r == .ok);
        try std.testing.expect(r.ok.root.* == .int_literal);
        try std.testing.expectEqual(@as(i64, 42), r.ok.root.int_literal);
    }
    {
        var r = try parse(alloc, "3.14");
        defer switch (r) {
            .ok => |*a| a.deinit(),
            .fail => |e| alloc.free(e),
        };
        try std.testing.expect(r == .ok);
        try std.testing.expect(r.ok.root.* == .float_literal);
    }
    {
        var r = try parse(alloc, "\"hello\"");
        defer switch (r) {
            .ok => |*a| a.deinit(),
            .fail => |e| alloc.free(e),
        };
        try std.testing.expect(r == .ok);
        try std.testing.expect(r.ok.root.* == .string_literal);
        try std.testing.expectEqualStrings("hello", r.ok.root.string_literal);
    }
    {
        var r = try parse(alloc, "true");
        defer switch (r) {
            .ok => |*a| a.deinit(),
            .fail => |e| alloc.free(e),
        };
        try std.testing.expect(r == .ok);
        try std.testing.expect(r.ok.root.* == .bool_literal);
        try std.testing.expect(r.ok.root.bool_literal == true);
    }
    {
        var r = try parse(alloc, "null");
        defer switch (r) {
            .ok => |*a| a.deinit(),
            .fail => |e| alloc.free(e),
        };
        try std.testing.expect(r == .ok);
        try std.testing.expect(r.ok.root.* == .null_literal);
    }
}

test "primary literals negative: empty source" {
    const alloc = std.testing.allocator;

    var result = try parse(alloc, "");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try std.testing.expect(result == .fail);
}

test "dot_path positive: order.total" {
    const alloc = std.testing.allocator;

    var result = try parse(alloc, "order.total");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try std.testing.expect(result == .ok);
    try std.testing.expect(result.ok.root.* == .dot_path);
    try std.testing.expectEqual(@as(usize, 2), result.ok.root.dot_path.len);
    try std.testing.expectEqualStrings("order", result.ok.root.dot_path[0]);
    try std.testing.expectEqualStrings("total", result.ok.root.dot_path[1]);
}

test "dot_path negative: trailing dot" {
    const alloc = std.testing.allocator;

    var result = try parse(alloc, "order.");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try std.testing.expect(result == .fail);
}

test "func_call positive: length(name)" {
    const alloc = std.testing.allocator;

    var result = try parse(alloc, "length(name)");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try std.testing.expect(result == .ok);
    try std.testing.expect(result.ok.root.* == .func_call);
    try std.testing.expectEqualStrings("length", result.ok.root.func_call.name);
    try std.testing.expectEqual(@as(usize, 1), result.ok.root.func_call.args.len);
}

test "func_call negative: unknown function" {
    const alloc = std.testing.allocator;

    var result = try parse(alloc, "bogus(42)");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try std.testing.expect(result == .fail);
    try std.testing.expect(result.fail[0].line > 0);
    try std.testing.expect(result.fail[0].column > 0);
}

test "grouped expression positive: (1 + 2) * 3" {
    const alloc = std.testing.allocator;

    var result = try parse(alloc, "(1 + 2) * 3");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try std.testing.expect(result == .ok);
    // Root should be mul_expr; left should be add_expr
    try std.testing.expect(result.ok.root.* == .mul_expr);
    try std.testing.expect(result.ok.root.mul_expr.left.* == .add_expr);
}

test "grouped expression negative: unclosed paren" {
    const alloc = std.testing.allocator;

    var result = try parse(alloc, "(1 + 2");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try std.testing.expect(result == .fail);
}

test "error recovery: multiple errors in one pass" {
    const alloc = std.testing.allocator;

    // "bogus(1) and unknown(2)" — two unknown function calls
    var result = try parse(alloc, "bogus(1) and unknown(2)");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try std.testing.expect(result == .fail);
    try std.testing.expect(result.fail.len >= 2);
}

test "complex expression positive: order.total > 10000 and customer.tier == \"VIP\"" {
    const alloc = std.testing.allocator;

    var result = try parse(alloc, "order.total > 10000 and customer.tier == \"VIP\"");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try std.testing.expect(result == .ok);
    try std.testing.expect(result.ok.root.* == .and_expr);
}

test "func_call with no args positive: now()" {
    const alloc = std.testing.allocator;

    var result = try parse(alloc, "now()");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try std.testing.expect(result == .ok);
    try std.testing.expect(result.ok.root.* == .func_call);
    try std.testing.expectEqualStrings("now", result.ok.root.func_call.name);
    try std.testing.expectEqual(@as(usize, 0), result.ok.root.func_call.args.len);
}

test "func_call with multiple args positive: date_add(ts, 7)" {
    const alloc = std.testing.allocator;

    var result = try parse(alloc, "date_add(ts, 7)");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try std.testing.expect(result == .ok);
    try std.testing.expect(result.ok.root.* == .func_call);
    try std.testing.expectEqual(@as(usize, 2), result.ok.root.func_call.args.len);
}

test "cmp_expr all comparison operators" {
    const alloc = std.testing.allocator;

    const cases = [_]struct { src: []const u8, op: ast_mod.CmpOp }{
        .{ .src = "1 != 2", .op = .neq },
        .{ .src = "1 < 2", .op = .lt },
        .{ .src = "1 <= 2", .op = .lte },
        .{ .src = "1 > 2", .op = .gt },
        .{ .src = "1 >= 2", .op = .gte },
    };
    for (cases) |c| {
        var r = try parse(alloc, c.src);
        defer switch (r) {
            .ok => |*a| a.deinit(),
            .fail => |e| alloc.free(e),
        };
        try std.testing.expect(r == .ok);
        try std.testing.expectEqual(c.op, r.ok.root.cmp_expr.op);
    }
}
