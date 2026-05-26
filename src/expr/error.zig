//! Error types for the Expression DSL module — DSL-01
//!
//! ParseError: structured error from lexer/parser, carrying location and message.
//! EvalError:  structured error from evaluator (future DSL-04/DSL-06 run).
//! ExprError:  top-level error set for the public API.
//!
//! No I/O. No DB access. Pure data types only.
const std = @import("std");

// ---------------------------------------------------------------------------
// ParseError
// ---------------------------------------------------------------------------

/// A single syntax error recorded during lexing or parsing.
/// `token` and `message` are slices that must remain valid as long as the
/// error list is in use (they point into the original source buffer and into
/// static string literals respectively).
pub const ParseError = struct {
    /// 1-based line number of the offending token.
    line: u32,
    /// 1-based column number of the offending token.
    column: u32,
    /// Lexeme of the offending token (slice into original source — zero copy).
    token: []const u8,
    /// Human-readable description; always a static string literal.
    message: []const u8,
};

// ---------------------------------------------------------------------------
// EvalError
// ---------------------------------------------------------------------------

/// A runtime error produced during evaluation (type error, arity mismatch, etc.).
/// Used by the evaluator stub and the full evaluator (DSL-04/DSL-06 run).
pub const EvalError = struct {
    /// Human-readable description; may be static or arena-allocated.
    message: []const u8,
    /// Optional source location (populated when a specific node can be blamed).
    line: u32,
    column: u32,
};

// ---------------------------------------------------------------------------
// ExprError — top-level error set for the public API
// ---------------------------------------------------------------------------

pub const ExprError = error{
    /// One or more ParseErrors were accumulated; caller reads the list.
    ParseFailed,
    /// EvalError produced during evaluation.
    EvalFailed,
    /// Arena allocation failed.
    OutOfMemory,
    /// Evaluator is not yet implemented (stub returns this).
    NotImplemented,
};
