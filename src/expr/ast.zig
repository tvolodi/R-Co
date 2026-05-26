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
