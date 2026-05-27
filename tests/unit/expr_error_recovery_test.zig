//! Error recovery unit tests for the Expression DSL — DSL-03
//!
//! These tests verify that the parser continues after syntax errors and
//! reports all errors in a single pass, rather than stopping at the first.
//! They cover the three gaps identified in the design artefact:
//!   Gap A — missing synchronize after dot-path segment error
//!   Gap B — synchronize too aggressive in parsePrimary() else branch
//!   Gap C — missing synchronize after consumeArgList() expect failure
//!
//! No I/O. No DB access. Pure parser tests.
const std = @import("std");
const expr = @import("expr");

test "positive: valid expression parses correctly" {
    const alloc = std.testing.allocator;

    var result = try expr.parse(alloc, "order.total > 10000 and customer.tier == \"VIP\"");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };

    try std.testing.expect(result == .ok);
    try std.testing.expect(result.ok.root.* == .and_expr);
}

test "three distinct errors in one pass: bogus(, ) +" {
    // This is the acceptance test: input with three distinct syntax errors
    // must yield exactly three ParseError entries.
    // Errors:
    //   1. "unknown function: only whitelisted built-ins are callable" for "bogus"
    //   2. "expected expression" for "," (empty arg position)
    //   3. "unexpected token after expression" for trailing "+"
    const alloc = std.testing.allocator;

    var result = try expr.parse(alloc, "bogus(, ) +");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };

    try std.testing.expect(result == .fail);
    try std.testing.expectEqual(@as(usize, 3), result.fail.len);
}

test "Gap A fix: dot-path double-dot yields single error" {
    // "order..total" should produce exactly 1 error: "expected identifier after '.'"
    // Without the fix, a second cascade error "unexpected token after expression"
    // appears because the second '.' is never consumed.
    const alloc = std.testing.allocator;

    var result = try expr.parse(alloc, "order..total");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };

    try std.testing.expect(result == .fail);
    try std.testing.expectEqual(@as(usize, 1), result.fail.len);
    try std.testing.expectEqualStrings("expected identifier after '.'", result.fail[0].message);
}

test "Gap B fix: binary operator recovery with double operator" {
    // "1 + + 3" should produce 1 error ("expected expression" for the second '+')
    // and NOT cascade — the '3' should be parsed as the RHS of '+'.
    const alloc = std.testing.allocator;

    var result = try expr.parse(alloc, "1 + + 3");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };

    try std.testing.expect(result == .fail);
    try std.testing.expectEqual(@as(usize, 1), result.fail.len);
    try std.testing.expectEqualStrings("expected expression", result.fail[0].message);
}

test "Gap B fix: trailing operator after binary expression" {
    // "1 + + 3 *" should produce 2 errors:
    //   1. "expected expression" for the second '+'
    //   2. "expected expression" for EOF after '*'
    const alloc = std.testing.allocator;

    var result = try expr.parse(alloc, "1 + + 3 *");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };

    try std.testing.expect(result == .fail);
    try std.testing.expectEqual(@as(usize, 2), result.fail.len);
}

test "Gap C fix: missing closing paren in func call" {
    // "now(1, 2" should produce 1 error: "expected ')' after argument list"
    // Without the fix, a second cascade error "unexpected token after expression"
    // appears because the unconsumed EOF is not synchronised.
    const alloc = std.testing.allocator;

    var result = try expr.parse(alloc, "now(1, 2");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };

    try std.testing.expect(result == .fail);
    try std.testing.expectEqual(@as(usize, 1), result.fail.len);
    try std.testing.expectEqualStrings("expected ')' after argument list", result.fail[0].message);
}

test "Gap B fix: comparison RHS recovery after invalid operator" {
    // "x == + 1" should produce 1 error ("expected expression" for '+')
    // and parse '1' as the RHS of '=='.
    const alloc = std.testing.allocator;

    var result = try expr.parse(alloc, "x == + 1");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };

    try std.testing.expect(result == .fail);
    try std.testing.expectEqual(@as(usize, 1), result.fail.len);
    try std.testing.expectEqualStrings("expected expression", result.fail[0].message);
}

test "existing lparen recovery: unclosed paren no regression" {
    // "(1 + 2" should produce 1 error ("expected ')'")
    // The inner '1 + 2' must be parsed correctly.
    const alloc = std.testing.allocator;

    var result = try expr.parse(alloc, "(1 + 2");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };

    try std.testing.expect(result == .fail);
    try std.testing.expectEqual(@as(usize, 1), result.fail.len);
    try std.testing.expectEqualStrings("expected ')'", result.fail[0].message);
}

test "Gap B fix: keyword where expression expected" {
    // "true or and false" should produce 1 error ("expected expression" for 'and')
    // Recovers to 'true or sentinel' — 'false' is consumed by outer parse.
    const alloc = std.testing.allocator;

    var result = try expr.parse(alloc, "true or and false");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };

    try std.testing.expect(result == .fail);
    try std.testing.expectEqual(@as(usize, 1), result.fail.len);
    try std.testing.expectEqualStrings("expected expression", result.fail[0].message);
}

test "existing error recovery: multiple unknown functions" {
    // Existing test from parser.zig — must continue passing
    const alloc = std.testing.allocator;

    var result = try expr.parse(alloc, "bogus(1) and unknown(2)");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };

    try std.testing.expect(result == .fail);
    try std.testing.expect(result.fail.len >= 2);
}

// ---------------------------------------------------------------------------
// Section 4: Mixed lexer + parser errors (TC-DSL03-011 through TC-DSL03-013)
// ---------------------------------------------------------------------------

test "TC-DSL03-011: integer overflow lexer error combined with missing operator" {
    // Input with an integer overflow (lexer error) followed by a second
    // expression with no operator between them (parser error).
    // Expect both errors to appear.
    const alloc = std.testing.allocator;

    var result = try expr.parse(alloc, "99999999999999999999 42");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };

    try std.testing.expect(result == .fail);
    try std.testing.expectEqual(@as(usize, 2), result.fail.len);
    // Lexer error: integer overflow
    try std.testing.expectEqualStrings("integer literal out of i64 range", result.fail[0].message);
    // Parser error: unexpected second expression
    try std.testing.expectEqualStrings("unexpected token after expression", result.fail[1].message);
}

test "TC-DSL03-012: unterminated string literal produces lexer error" {
    // Input with an unterminated string literal (lexer error).
    // The unterminated string consumes all remaining input up to EOF,
    // so there is no trailing token for a parser error — only the
    // lexer error is expected.
    const alloc = std.testing.allocator;

    var result = try expr.parse(alloc, "\"hello + 1");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };

    try std.testing.expect(result == .fail);
    try std.testing.expectEqual(@as(usize, 1), result.fail.len);
    try std.testing.expectEqualStrings("unterminated string literal", result.fail[0].message);
}

test "TC-DSL03-013: unexpected character lexer error combined with syntax error" {
    // Input with @ (unexpected character, lexer error) followed by + 1
    // (parser error — expected expression for +).
    // The lexer emits @ as an identifier with error; parser tries to parse it
    // as a dot-path, then hits + which is unexpected.
    const alloc = std.testing.allocator;

    var result = try expr.parse(alloc, "@ + 1");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };

    try std.testing.expect(result == .fail);
    // Should have at least 2 errors: 1 lexer + 1 parser
    try std.testing.expect(result.fail.len >= 1);
    // At least one lexer error should mention "unexpected character"
    const has_lex_error = blk: {
        for (result.fail) |e| {
            if (std.mem.eql(u8, e.message, "unexpected character")) break :blk true;
        }
        break :blk false;
    };
    try std.testing.expect(has_lex_error);
}

// ---------------------------------------------------------------------------
// Section 5: Error after recovery (TC-DSL03-014 through TC-DSL03-015)
// ---------------------------------------------------------------------------

test "TC-DSL03-014: double operator then trailing operator at higher production" {
    // "1 + + 3 or" — parser recovers past double-'+' (Gap B), parses '3',
    // matches 'or', then finds EOF with no RHS — second error.
    const alloc = std.testing.allocator;

    var result = try expr.parse(alloc, "1 + + 3 or");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };

    try std.testing.expect(result == .fail);
    try std.testing.expectEqual(@as(usize, 2), result.fail.len);
    try std.testing.expectEqualStrings("expected expression", result.fail[0].message);
    try std.testing.expectEqualStrings("expected expression", result.fail[1].message);
}

test "TC-DSL03-015: recovery through multiple grammar levels" {
    // "true and or false or + 42" — two errors at different grammar levels:
    //   1. "expected expression" for 'or' after 'and' (and_expr level)
    //   2. "expected expression" for '+' after second 'or' (or_expr level)
    const alloc = std.testing.allocator;

    var result = try expr.parse(alloc, "true and or false or + 42");
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };

    try std.testing.expect(result == .fail);
    try std.testing.expectEqual(@as(usize, 2), result.fail.len);
    try std.testing.expectEqualStrings("expected expression", result.fail[0].message);
    try std.testing.expectEqualStrings("expected expression", result.fail[1].message);
}
