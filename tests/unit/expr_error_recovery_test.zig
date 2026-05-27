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
