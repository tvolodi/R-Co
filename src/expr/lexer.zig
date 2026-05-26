//! Lexer for the Expression DSL — DSL-01
//!
//! Single-pass character scan producing []Token.
//! All lexemes are slices into the original source — no allocation for token content.
//! Tokens themselves are stored in a caller-supplied ArrayList.
//!
//! No I/O. No DB access. Pure function.
const std = @import("std");
const ast = @import("ast.zig");
const err = @import("error.zig");

pub const TokenKind = ast.TokenKind;
pub const Token = ast.Token;
pub const ParseError = err.ParseError;

// ---------------------------------------------------------------------------
// Builtin whitelist (11 entries — DSL-07)
// ---------------------------------------------------------------------------

const builtin_names = [_][]const u8{
    "length",
    "lower",
    "upper",
    "trim",
    "contains",
    "startsWith",
    "endsWith",
    "coalesce",
    "now",
    "date_add",
    "date_diff",
};

fn isBuiltin(name: []const u8) bool {
    for (builtin_names) |b| {
        if (std.mem.eql(u8, name, b)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Keyword table
// ---------------------------------------------------------------------------

fn keywordKind(word: []const u8) ?TokenKind {
    if (std.mem.eql(u8, word, "and")) return .and_kw;
    if (std.mem.eql(u8, word, "or")) return .or_kw;
    if (std.mem.eql(u8, word, "not")) return .not_kw;
    if (std.mem.eql(u8, word, "true")) return .true_kw;
    if (std.mem.eql(u8, word, "false")) return .false_kw;
    if (std.mem.eql(u8, word, "null")) return .null_kw;
    return null;
}

// ---------------------------------------------------------------------------
// LexResult
// ---------------------------------------------------------------------------

pub const LexResult = struct {
    tokens: []Token,
    errors: []ParseError,
};

// ---------------------------------------------------------------------------
// tokenize — entry point
// ---------------------------------------------------------------------------

/// Tokenise `source`.  Both the token slice and the error slice are allocated
/// from `allocator` and must be freed by the caller.
pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error!LexResult {
    var tokens: std.ArrayList(Token) = .empty;
    var errors: std.ArrayList(ParseError) = .empty;

    var pos: usize = 0;
    var line: u32 = 1;
    var line_start: usize = 0; // byte offset of the start of the current line

    while (pos < source.len) {
        const start = pos;
        const ch = source[pos];

        // Skip whitespace, track newlines
        if (ch == '\n') {
            pos += 1;
            line += 1;
            line_start = pos;
            continue;
        }
        if (ch == ' ' or ch == '\t' or ch == '\r') {
            pos += 1;
            continue;
        }

        const col: u32 = @intCast(pos - line_start + 1);

        // Two-character operators that need lookahead
        if (ch == '=' and pos + 1 < source.len and source[pos + 1] == '=') {
            try tokens.append(allocator, .{ .kind = .eq, .lexeme = source[pos .. pos + 2], .line = line, .column = col });
            pos += 2;
            continue;
        }
        if (ch == '!' and pos + 1 < source.len and source[pos + 1] == '=') {
            try tokens.append(allocator, .{ .kind = .neq, .lexeme = source[pos .. pos + 2], .line = line, .column = col });
            pos += 2;
            continue;
        }
        if (ch == '<' and pos + 1 < source.len and source[pos + 1] == '=') {
            try tokens.append(allocator, .{ .kind = .lte, .lexeme = source[pos .. pos + 2], .line = line, .column = col });
            pos += 2;
            continue;
        }
        if (ch == '>' and pos + 1 < source.len and source[pos + 1] == '=') {
            try tokens.append(allocator, .{ .kind = .gte, .lexeme = source[pos .. pos + 2], .line = line, .column = col });
            pos += 2;
            continue;
        }

        // Single-character tokens
        switch (ch) {
            '<' => {
                try tokens.append(allocator, .{ .kind = .lt, .lexeme = source[pos .. pos + 1], .line = line, .column = col });
                pos += 1;
                continue;
            },
            '>' => {
                try tokens.append(allocator, .{ .kind = .gt, .lexeme = source[pos .. pos + 1], .line = line, .column = col });
                pos += 1;
                continue;
            },
            '+' => {
                try tokens.append(allocator, .{ .kind = .plus, .lexeme = source[pos .. pos + 1], .line = line, .column = col });
                pos += 1;
                continue;
            },
            '-' => {
                try tokens.append(allocator, .{ .kind = .minus, .lexeme = source[pos .. pos + 1], .line = line, .column = col });
                pos += 1;
                continue;
            },
            '*' => {
                try tokens.append(allocator, .{ .kind = .star, .lexeme = source[pos .. pos + 1], .line = line, .column = col });
                pos += 1;
                continue;
            },
            '/' => {
                try tokens.append(allocator, .{ .kind = .slash, .lexeme = source[pos .. pos + 1], .line = line, .column = col });
                pos += 1;
                continue;
            },
            '%' => {
                try tokens.append(allocator, .{ .kind = .percent, .lexeme = source[pos .. pos + 1], .line = line, .column = col });
                pos += 1;
                continue;
            },
            '(' => {
                try tokens.append(allocator, .{ .kind = .lparen, .lexeme = source[pos .. pos + 1], .line = line, .column = col });
                pos += 1;
                continue;
            },
            ')' => {
                try tokens.append(allocator, .{ .kind = .rparen, .lexeme = source[pos .. pos + 1], .line = line, .column = col });
                pos += 1;
                continue;
            },
            ',' => {
                try tokens.append(allocator, .{ .kind = .comma, .lexeme = source[pos .. pos + 1], .line = line, .column = col });
                pos += 1;
                continue;
            },
            '.' => {
                try tokens.append(allocator, .{ .kind = .dot, .lexeme = source[pos .. pos + 1], .line = line, .column = col });
                pos += 1;
                continue;
            },
            else => {},
        }

        // String literals: "..."
        if (ch == '"') {
            pos += 1; // skip opening quote
            var terminated = false;
            while (pos < source.len) {
                if (source[pos] == '\\' and pos + 1 < source.len and source[pos + 1] == '"') {
                    pos += 2; // escaped quote
                } else if (source[pos] == '"') {
                    pos += 1; // closing quote
                    terminated = true;
                    break;
                } else if (source[pos] == '\n') {
                    // Unterminated string literal — stop at newline
                    break;
                } else {
                    pos += 1;
                }
            }
            if (!terminated) {
                try errors.append(allocator, .{
                    .line = line,
                    .column = col,
                    .token = source[start..pos],
                    .message = "unterminated string literal",
                });
            }
            try tokens.append(allocator, .{ .kind = .string_literal, .lexeme = source[start..pos], .line = line, .column = col });
            continue;
        }

        // Numeric literals: integer or float
        if (ch >= '0' and ch <= '9') {
            var is_float = false;
            pos += 1;
            while (pos < source.len and (source[pos] >= '0' and source[pos] <= '9')) {
                pos += 1;
            }
            if (pos < source.len and source[pos] == '.' and pos + 1 < source.len and source[pos + 1] >= '0' and source[pos + 1] <= '9') {
                is_float = true;
                pos += 1; // consume '.'
                while (pos < source.len and source[pos] >= '0' and source[pos] <= '9') {
                    pos += 1;
                }
            }
            const kind: TokenKind = if (is_float) .float_literal else .int_literal;

            // Range check for integer literals
            if (!is_float) {
                const int_str = source[start..pos];
                _ = std.fmt.parseInt(i64, int_str, 10) catch {
                    try errors.append(allocator, .{
                        .line = line,
                        .column = col,
                        .token = int_str,
                        .message = "integer literal out of i64 range",
                    });
                    // Still emit the token so the parser can continue
                };
            }

            try tokens.append(allocator, .{ .kind = kind, .lexeme = source[start..pos], .line = line, .column = col });
            continue;
        }

        // Identifiers and keywords: [a-zA-Z_][a-zA-Z0-9_]*
        if (isIdentStart(ch)) {
            pos += 1;
            while (pos < source.len and isIdentContinue(source[pos])) {
                pos += 1;
            }
            const word = source[start..pos];

            const token_kind: TokenKind = if (keywordKind(word)) |kw|
                kw
            else if (isBuiltin(word))
                .builtin_func
            else
                .identifier;

            try tokens.append(allocator, .{ .kind = token_kind, .lexeme = word, .line = line, .column = col });
            continue;
        }

        // Unknown character — emit as identifier + record lex error (never panic)
        pos += 1;
        try errors.append(allocator, .{
            .line = line,
            .column = col,
            .token = source[start..pos],
            .message = "unexpected character",
        });
        try tokens.append(allocator, .{ .kind = .identifier, .lexeme = source[start..pos], .line = line, .column = col });
    }

    // Always append EOF
    const eof_col: u32 = if (pos >= line_start) @intCast(pos - line_start + 1) else 1;
    try tokens.append(allocator, .{ .kind = .eof, .lexeme = "", .line = line, .column = eof_col });

    return LexResult{
        .tokens = try tokens.toOwnedSlice(allocator),
        .errors = try errors.toOwnedSlice(allocator),
    };
}

// ---------------------------------------------------------------------------
// Character classification helpers
// ---------------------------------------------------------------------------

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}
