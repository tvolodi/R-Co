//! AST types for the Expression DSL — DSL-01
//!
//! Defines: TokenKind, Token, CmpOp, AddOp, MulOp, Node, Ast, Value, Context.
//!
//! No I/O. No DB access. All allocation goes through the arena embedded in Ast.
const std = @import("std");

// ---------------------------------------------------------------------------
// TokenKind
// ---------------------------------------------------------------------------

pub const TokenKind = enum {
    // Literals
    int_literal,
    float_literal,
    string_literal,
    true_kw,
    false_kw,
    null_kw,

    // Boolean keywords
    and_kw,
    or_kw,
    not_kw,

    // Comparison operators
    eq, // ==
    neq, // !=
    lt, // <
    lte, // <=
    gt, // >
    gte, // >=

    // Arithmetic operators
    plus, // +
    minus, // -
    star, // *
    slash, // /
    percent, // %

    // Structure
    lparen, // (
    rparen, // )
    comma, // ,
    dot, // .

    // Identifiers and built-ins
    /// Any name not matching a keyword.
    identifier,
    /// Identifier validated against the 11-entry builtin whitelist at lex time.
    builtin_func,

    // Control
    eof,
};

// ---------------------------------------------------------------------------
// Token
// ---------------------------------------------------------------------------

pub const Token = struct {
    kind: TokenKind,
    /// Slice into the original source — no copy.
    lexeme: []const u8,
    /// 1-based line number.
    line: u32,
    /// 1-based column number.
    column: u32,
};

// ---------------------------------------------------------------------------
// Operator enums
// ---------------------------------------------------------------------------

pub const CmpOp = enum { eq, neq, lt, lte, gt, gte };
pub const AddOp = enum { add, sub };
pub const MulOp = enum { mul, div, mod };

// ---------------------------------------------------------------------------
// Node — tagged union over all grammar productions
// ---------------------------------------------------------------------------

pub const Node = union(enum) {
    // ---- Binary boolean ----
    or_expr: struct {
        left: *Node,
        right: *Node,
    },
    and_expr: struct {
        left: *Node,
        right: *Node,
    },

    // ---- Unary boolean ----
    not_expr: struct {
        operand: *Node,
    },

    // ---- Comparison (at most one operator per expression) ----
    cmp_expr: struct {
        op: CmpOp,
        left: *Node,
        right: *Node,
    },

    // ---- Arithmetic ----
    add_expr: struct {
        op: AddOp,
        left: *Node,
        right: *Node,
    },
    mul_expr: struct {
        op: MulOp,
        left: *Node,
        right: *Node,
    },

    // ---- Unary negation ----
    unary_neg: struct {
        operand: *Node,
    },

    // ---- Literals ----
    int_literal: i64,
    float_literal: f64,
    /// Slice into source — zero copy.
    string_literal: []const u8,
    bool_literal: bool,
    null_literal: void,

    // ---- Variable path  e.g. order.total ----
    /// Slice of identifier strings owned by the arena.
    dot_path: [][]const u8,

    // ---- Function call ----
    func_call: struct {
        /// One of the 11 whitelisted names (slice into source).
        name: []const u8,
        /// 0..N argument nodes owned by the arena.
        args: []*Node,
    },
};

// ---------------------------------------------------------------------------
// Ast wrapper
// ---------------------------------------------------------------------------

/// Owns the arena that backs all Node allocations.
/// Call `deinit()` to free the entire tree.
pub const Ast = struct {
    root: *Node,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Ast) void {
        self.arena.deinit();
    }
};

// ---------------------------------------------------------------------------
// nodeEql — DSL-02: structural equality over the AST
// ---------------------------------------------------------------------------

/// Returns true if the trees rooted at `a` and `b` are structurally identical.
///
/// - Pure function: no allocation, no I/O.
/// - Recursive: child nodes are compared depth-first.
/// - Exhaustive switch: if a new Node variant is added, the compiler will
///   emit an error here, forcing the implementor to handle it.
pub fn nodeEql(a: *const Node, b: *const Node) bool {
    // Fast-path: if the active tags differ, the trees cannot be equal.
    const a_tag = std.meta.activeTag(a.*);
    const b_tag = std.meta.activeTag(b.*);
    if (a_tag != b_tag) return false;

    switch (a.*) {
        // ---- Binary boolean ----
        .or_expr => |av| return nodeEql(av.left, b.or_expr.left) and
            nodeEql(av.right, b.or_expr.right),
        .and_expr => |av| return nodeEql(av.left, b.and_expr.left) and
            nodeEql(av.right, b.and_expr.right),

        // ---- Unary boolean ----
        .not_expr => |av| return nodeEql(av.operand, b.not_expr.operand),

        // ---- Comparison ----
        .cmp_expr => |av| return av.op == b.cmp_expr.op and
            nodeEql(av.left, b.cmp_expr.left) and
            nodeEql(av.right, b.cmp_expr.right),

        // ---- Arithmetic binary ----
        .add_expr => |av| return av.op == b.add_expr.op and
            nodeEql(av.left, b.add_expr.left) and
            nodeEql(av.right, b.add_expr.right),
        .mul_expr => |av| return av.op == b.mul_expr.op and
            nodeEql(av.left, b.mul_expr.left) and
            nodeEql(av.right, b.mul_expr.right),

        // ---- Unary negation ----
        .unary_neg => |av| return nodeEql(av.operand, b.unary_neg.operand),

        // ---- Scalar literals (leaf nodes) ----
        .int_literal => |av| return av == b.int_literal,
        .float_literal => |av| return av == b.float_literal,
        .bool_literal => |av| return av == b.bool_literal,
        .null_literal => return true,

        // ---- String literal — slice comparison ----
        .string_literal => |av| return std.mem.eql(u8, av, b.string_literal),

        // ---- Dot path — segment-by-segment comparison ----
        .dot_path => |av| {
            const bv = b.dot_path;
            if (av.len != bv.len) return false;
            for (av, 0..) |seg, i| {
                if (!std.mem.eql(u8, seg, bv[i])) return false;
            }
            return true;
        },

        // ---- Function call — name + recursive argument comparison ----
        .func_call => |av| {
            const bv = b.func_call;
            if (!std.mem.eql(u8, av.name, bv.name)) return false;
            if (av.args.len != bv.args.len) return false;
            for (av.args, 0..) |arg, i| {
                if (!nodeEql(arg, bv.args[i])) return false;
            }
            return true;
        },
    }
}

// ---------------------------------------------------------------------------
// Tests — DSL-02: AST stability
// ---------------------------------------------------------------------------

test "DSL-02: same expression parses to equal AST" {
    const parser_mod = @import("parser.zig");
    const testing = std.testing;
    const allocator = testing.allocator;

    const inputs = [_][]const u8{
        "1 + 2",
        "a.b.c == null",
        "not (x > 0 and y < 100)",
        "true or false",
        "42",
    };

    for (inputs) |src| {
        var result1 = try parser_mod.parse(allocator, src);
        switch (result1) {
            .fail => |errs| {
                allocator.free(errs);
                try testing.expect(false); // unexpected parse failure
            },
            .ok => |*ast1| {
                defer ast1.deinit();
                var result2 = try parser_mod.parse(allocator, src);
                switch (result2) {
                    .fail => |errs| {
                        allocator.free(errs);
                        try testing.expect(false);
                    },
                    .ok => |*ast2| {
                        defer ast2.deinit();
                        try testing.expect(nodeEql(ast1.root, ast2.root));
                    },
                }
            },
        }
    }
}

test "DSL-02: different expressions parse to non-equal AST" {
    const parser_mod = @import("parser.zig");
    const testing = std.testing;
    const allocator = testing.allocator;

    const pairs = [_][2][]const u8{
        .{ "1 + 2", "1 + 3" },
        .{ "true", "false" },
        .{ "a.b", "a.c" },
        .{ "1", "2" },
        .{ "x and y", "x or y" },
    };

    for (pairs) |pair| {
        var r1 = try parser_mod.parse(allocator, pair[0]);
        var r2 = try parser_mod.parse(allocator, pair[1]);
        switch (r1) {
            .fail => |errs| {
                allocator.free(errs);
                try testing.expect(false);
            },
            .ok => |*ast1| {
                defer ast1.deinit();
                switch (r2) {
                    .fail => |errs| {
                        allocator.free(errs);
                        try testing.expect(false);
                    },
                    .ok => |*ast2| {
                        defer ast2.deinit();
                        try testing.expect(!nodeEql(ast1.root, ast2.root));
                    },
                }
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Value — the six DSL runtime types (DSL-04)
// ---------------------------------------------------------------------------

pub const Value = union(enum) {
    null_val: void,
    bool_val: bool,
    int_val: i64,
    float_val: f64,
    /// String value; slice owned by caller.
    str_val: []const u8,
    /// Unix timestamp in milliseconds (UTC).
    ts_val: i64,
};

// ---------------------------------------------------------------------------
// TypeTag — mirrors the active tags of Value
// ---------------------------------------------------------------------------

/// Mirrors the six DSL runtime types for dispatch and coercion decisions.
pub const TypeTag = enum {
    null,
    bool,
    int64,
    float64,
    string,
    timestamp,
};

// ---------------------------------------------------------------------------
// typeOf — tag dispatch helper
// ---------------------------------------------------------------------------

/// Returns the TypeTag for a given Value, without inspecting the payload.
pub fn typeOf(value: Value) TypeTag {
    return switch (value) {
        .null_val => .null,
        .bool_val => .bool,
        .int_val => .int64,
        .float_val => .float64,
        .str_val => .string,
        .ts_val => .timestamp,
    };
}

// ---------------------------------------------------------------------------
// Value construction helpers
// ---------------------------------------------------------------------------

pub fn valueNull() Value {
    return .{ .null_val = {} };
}

pub fn valueBool(b: bool) Value {
    return .{ .bool_val = b };
}

pub fn valueInt(n: i64) Value {
    return .{ .int_val = n };
}

pub fn valueFloat(f: f64) Value {
    return .{ .float_val = f };
}

pub fn valueStr(s: []const u8) Value {
    return .{ .str_val = s };
}

pub fn valueTs(ms: i64) Value {
    return .{ .ts_val = ms };
}

// ---------------------------------------------------------------------------
// Context — variable map for evaluation
// ---------------------------------------------------------------------------

pub const Context = struct {
    vars: std.StringHashMap(Value),

    pub fn init(allocator: std.mem.Allocator) Context {
        return Context{
            .vars = std.StringHashMap(Value).init(allocator),
        };
    }

    pub fn deinit(self: *Context) void {
        self.vars.deinit();
    }
};

// ---------------------------------------------------------------------------
// Tests — DSL-04: Value type, TypeTag, and construction helpers
// ---------------------------------------------------------------------------

test "DSL-04: Value tagged union has exactly 6 variants" {
    const testing = std.testing;

    // Compile-time check: Value must have exactly 6 fields.
    const field_count = @typeInfo(Value).@"union".fields.len;
    try testing.expectEqual(@as(usize, 6), field_count);
}

test "DSL-04: TypeTag enum mirrors the 6 types" {
    const testing = std.testing;

    const tag_count = @typeInfo(TypeTag).@"enum".fields.len;
    try testing.expectEqual(@as(usize, 6), tag_count);
}

test "DSL-04: typeOf returns correct tag for each variant" {
    const testing = std.testing;

    try testing.expect(typeOf(valueNull()) == .null);
    try testing.expect(typeOf(valueBool(true)) == .bool);
    try testing.expect(typeOf(valueInt(42)) == .int64);
    try testing.expect(typeOf(valueFloat(3.14)) == .float64);
    try testing.expect(typeOf(valueStr("hello")) == .string);
    try testing.expect(typeOf(valueTs(1_234_567_890)) == .timestamp);
}

test "DSL-04: value construction helpers produce correct payloads" {
    const testing = std.testing;

    try testing.expect(valueNull().null_val == {});
    try testing.expect(valueBool(true).bool_val == true);
    try testing.expect(valueBool(false).bool_val == false);
    try testing.expectEqual(@as(i64, 42), valueInt(42).int_val);
    try testing.expectEqual(@as(i64, -7), valueInt(-7).int_val);
    try testing.expect(valueFloat(3.14).float_val == 3.14);
    try testing.expectEqualStrings("hello", valueStr("hello").str_val);
    try testing.expectEqualStrings("", valueStr("").str_val);
    try testing.expectEqual(@as(i64, 1_234_567_890), valueTs(1_234_567_890).ts_val);
}
