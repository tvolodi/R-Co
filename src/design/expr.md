# Module: expr

**Stage:** Stage 7 — Expression DSL  
**Requirements:** DSL-01 through DSL-13  
**Normative grammar:** Architecture §5.1  
**Files produced:** `src/expr/lexer.zig`, `src/expr/parser.zig`, `src/expr/ast.zig`, `src/expr/error.zig`, `src/expr/mod.zig`

---

## 1. Module Layout

```
src/expr/
├── mod.zig       — public API; re-exports parse(), Ast, ParseError, Value, EvalResult
├── lexer.zig     — tokeniser: source []const u8 → []Token (single-pass)
├── parser.zig    — recursive-descent parser: []Token → Ast (or ParseError list)
├── ast.zig       — AST node tagged union, Token type, Ast wrapper
└── error.zig     — ParseError, EvalError, ExprError union
```

No existing source files are modified. `src/expr/` is a new module with no dependency on the persistence layer, the engine, or any other platform module. It has no I/O and no DB access.

---

## 2. Token Types

Defined in `ast.zig` as `TokenKind` (used by both lexer and error reporting):

```
// Literals
.int_literal          — e.g. 42, -1 (note: unary minus is a parser concern; lexer emits unsigned integer)
.float_literal        — e.g. 3.14
.string_literal       — e.g. "hello"
.true_kw              — keyword: true
.false_kw             — keyword: false
.null_kw              — keyword: null

// Keywords / operators
.and_kw               — keyword: and
.or_kw                — keyword: or
.not_kw               — keyword: not

// Comparison operators
.eq                   — ==
.neq                  — !=
.lt                   — <
.lte                  — <=
.gt                   — >
.gte                  — >=

// Arithmetic operators
.plus                 — +
.minus                — -
.star                 — *
.slash                — /
.percent              — %

// Structure
.lparen               — (
.rparen               — )
.comma                — ,
.dot                  — .

// Identifiers and built-ins
.identifier           — any name not matching a keyword; e.g. order, total, field
.builtin_func         — validated against the whitelist at lex time:
                        length, lower, upper, trim, contains,
                        startsWith, endsWith, coalesce, now,
                        date_add, date_diff

// Control
.eof                  — end of source
```

**Lexer whitelist check:** During tokenisation, an identifier token is reclassified as `.builtin_func` if it matches one of the 11 whitelisted names. Any identifier used in a call position (`identifier(`) that is neither reclassified as `.builtin_func` nor resolved as a variable path is a parse-time error (DSL-07: unknown function names are a parse-time error).

`Token` struct:

```
Token {
    kind:   TokenKind,
    lexeme: []const u8,   — slice into the original source (no copy)
    line:   u32,
    column: u32,
}
```

---

## 3. AST Node Tagged Union

Defined in `ast.zig`. All 9 grammar productions are represented.

```
Node = union(enum) {

    // expr := or_expr  (production 1 — passthrough, no wrapper node needed;
    //                   the root of the AST is simply the top-level Node)

    // or_expr := and_expr ('or' and_expr)*
    or_expr: struct {
        left:  *Node,
        right: *Node,
    },

    // and_expr := not_expr ('and' not_expr)*
    and_expr: struct {
        left:  *Node,
        right: *Node,
    },

    // not_expr := 'not'? cmp_expr
    not_expr: struct {
        operand: *Node,
    },

    // cmp_expr := add_expr (op add_expr)?
    cmp_expr: struct {
        op:    CmpOp,          // .eq | .neq | .lt | .lte | .gt | .gte
        left:  *Node,
        right: *Node,
    },

    // add_expr := mul_expr (('+' | '-') mul_expr)*
    add_expr: struct {
        op:    AddOp,          // .add | .sub
        left:  *Node,
        right: *Node,
    },

    // mul_expr := unary (('*' | '/' | '%') unary)*
    mul_expr: struct {
        op:    MulOp,          // .mul | .div | .mod
        left:  *Node,
        right: *Node,
    },

    // unary := '-'? primary
    unary_neg: struct {
        operand: *Node,
    },

    // primary := number | string | bool | null
    //          | identifier ('.' identifier)*
    //          | '(' expr ')'
    //          | func_call
    //
    // Grouped expressions ('(' expr ')') do not produce a node; the inner
    // node is returned directly.
    //
    // Literals:
    int_literal:    i64,
    float_literal:  f64,
    string_literal: []const u8,   // slice into source; no allocation
    bool_literal:   bool,
    null_literal:   void,

    // Dot-path: identifier or 'a.b.c' resolved at eval time against context
    // Stored as a slice of identifier strings, e.g. ["order", "total"]
    dot_path: [][]const u8,       // owned by the arena

    // func_call := identifier '(' (expr (',' expr)*)? ')'
    func_call: struct {
        name: []const u8,         // one of the 11 whitelisted names
        args: []*Node,            // 0..N argument nodes; owned by the arena
    },
}
```

Supporting enums (all in `ast.zig`):

```
CmpOp = enum { eq, neq, lt, lte, gt, gte };
AddOp = enum { add, sub };
MulOp = enum { mul, div, mod };
```

`Ast` wrapper struct:

```
Ast {
    root:  *Node,
    arena: std.heap.ArenaAllocator,   // all nodes and slices allocated here
}
```

The `Ast` struct owns its arena. Calling `ast.deinit()` frees the entire tree.

---

## 4. Error Types

Defined in `error.zig`.

### ParseError

Returned (as a list) when the parser encounters invalid syntax.

```
ParseError {
    line:    u32,            // 1-based line number of the offending token
    column:  u32,            // 1-based column number
    token:   []const u8,     // lexeme of the offending token (slice into source)
    message: []const u8,     // human-readable description; statically allocated
}
```

For DSL-03 (multi-error recovery), `parse()` returns `ParseError` as follows: the parser uses a synchronisation strategy — on encountering a syntax error it records the error, then attempts to advance to a synchronisation point (next comma, closing paren, or EOF) and continues parsing. This allows multiple errors to be collected in a single pass.

### EvalError

Returned when evaluation fails due to type errors or unsupported operations. Used by the evaluator (future DSL-04/DSL-06 run).

```
EvalError {
    message: []const u8,
    // Optional: location into the original source (populated when practical)
    line:    u32,
    column:  u32,
}
```

### ExprError

Top-level error set for the public API:

```
ExprError = error{
    ParseFailed,       // one or more ParseErrors accumulated; caller reads the list
    EvalFailed,        // EvalError produced during evaluation
    OutOfMemory,       // arena allocation failed
}
```

---

## 5. Public API (`mod.zig`)

`mod.zig` re-exports all public symbols and provides the two entry points required by DSL-12.

### 5.1 parse

```
pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseResult
```

`ParseResult` is a tagged union:

```
ParseResult = union(enum) {
    ok:   Ast,
    fail: []ParseError,     // slice owned by the caller-provided allocator
}
```

**Behaviour:**
- Tokenises `source` via the lexer (single pass, no allocation — tokens slice into `source`).
- Runs the recursive-descent parser, collecting errors.
- On success: returns `.ok` with an `Ast` whose arena was initialised from `allocator`. Caller owns the returned `Ast` and MUST call `ast.deinit()` when done.
- On failure: returns `.fail` with a slice of `ParseError`. Caller frees with `allocator.free(errors)`.
- Token slices inside `ParseError.token` point into `source`; `source` must remain valid while the error list is in use.

**Memory contract:**
- Recommended: pass an `ArenaAllocator` wrapping a page allocator. The `Ast` struct wraps its own internal arena — the passed allocator is used only to initialise that arena.
- The lexer produces `[]Token` allocated from a temporary arena that is freed before `parse()` returns.
- `ParseError` slices are allocated from the caller's `allocator`.

### 5.2 evaluate (stub — full design in DSL-04/DSL-06 run)

```
pub fn evaluate(
    ast:       *const Ast,
    ctx:       *const Context,
    allocator: std.mem.Allocator,
) EvalResult
```

`Context` maps string keys to `Value`:

```
Context = struct {
    vars: std.StringHashMap(Value),
}
```

`Value` is a tagged union over the six DSL types (DSL-04):

```
Value = union(enum) {
    null_val:  void,
    bool_val:  bool,
    int_val:   i64,
    float_val: f64,
    str_val:   []const u8,
    ts_val:    i64,      // unix timestamp in milliseconds (UTC)
}
```

`EvalResult`:

```
EvalResult = union(enum) {
    ok:   Value,
    err:  EvalError,
}
```

`evaluate()` is declared in `mod.zig` but implemented in a future step (DSL-04/DSL-06 run). The stub signature is established here so that `mod.zig` can be compiled (returning `.err` with a placeholder message) and callers can depend on the module boundary without waiting for the evaluator.

**Cacheability (DSL-12):** A parsed `Ast` is immutable after construction and safe to evaluate against multiple `Context` values without re-parsing. Callers may cache `Ast` values.

---

## 6. Lexer Design (`lexer.zig`)

**Single-pass character scan:**
1. Maintain a cursor position (byte index), current line, current column.
2. Skip whitespace and `//` line comments (if comments are desired — not in grammar, so skip only whitespace).
3. On each non-whitespace character, identify and emit one token.
4. String literals: scan until closing `"`, handle `\"` escape, emit `.string_literal` with lexeme including quotes.
5. Numeric literals: scan digits, optional `.` for float, classify as `.int_literal` or `.float_literal`.
6. Identifiers: scan `[a-zA-Z_][a-zA-Z0-9_]*`, then check against keyword table and builtin whitelist.

**Keyword table** (in order of lookup priority):
```
"and"   → .and_kw
"or"    → .or_kw
"not"   → .not_kw
"true"  → .true_kw
"false" → .false_kw
"null"  → .null_kw
```

**Builtin whitelist** (checked after keyword table):
```
"length", "lower", "upper", "trim", "contains",
"startsWith", "endsWith", "coalesce", "now",
"date_add", "date_diff"
```

**Two-character operators:** `==`, `!=`, `<=`, `>=` require one-character lookahead.

**Output:** `[]Token` stored in a caller-provided slice (or arena-allocated). The lexer does not allocate string copies — all lexemes are slices into the original `source` buffer.

**Unknown character:** emits a `.identifier` token with the raw byte and records a `ParseError`. The lexer never panics.

---

## 7. Parser Design (`parser.zig`)

**Recursive descent**, one function per grammar production:

```
parseExpr()    → calls parseOrExpr()
parseOrExpr()  → parseAndExpr() ('or' parseAndExpr())*
parseAndExpr() → parseNotExpr() ('and' parseNotExpr())*
parseNotExpr() → 'not'? parseCmpExpr()
parseCmpExpr() → parseAddExpr() (cmp_op parseAddExpr())?
parseAddExpr() → parseMulExpr() (('+' | '-') parseMulExpr())*
parseMulExpr() → parseUnary()   (('*' | '/' | '%') parseUnary())*
parseUnary()   → '-'? parsePrimary()
parsePrimary() → literal | dot_path | grouped | func_call
```

**Left-associativity:** `or`, `and`, `+`, `-`, `*`, `/`, `%` are left-associative. Implemented by folding in the `*`-loops: each iteration wraps the accumulated left node plus the new right node into a new binary node.

**Comparison:** `cmp_expr` has at most one operator (grammar: `(op add_expr)?` — non-repeating). The parser enforces this: after seeing one comparison, it does not loop.

**Dot-path vs. func_call disambiguation:** After consuming an identifier, peek at the next token:
- If `.` follows: continue consuming `.identifier` segments, build `dot_path`.
- If `(` follows and the identifier is a `.builtin_func`: consume `(`, parse comma-separated args, consume `)`, build `func_call`.
- If `(` follows and the identifier is NOT a `.builtin_func`: record a ParseError ("unknown function: <name>"), attempt recovery by consuming to matching `)`.
- Otherwise: single-segment `dot_path`.

**Error recovery (DSL-03):** On encountering an unexpected token:
1. Record a `ParseError` (line, column, token, message).
2. Advance tokens until a synchronisation point: `)`, `,`, or `eof`.
3. Return a sentinel node (`null_literal`) to allow the caller to continue parsing.
4. Accumulate all errors; after `parseExpr()` completes, if the error list is non-empty, the result is a failure.

---

## 8. Memory Model

- `Ast` embeds an `std.heap.ArenaAllocator` initialised from the allocator passed to `parse()`.
- All `Node` structs, `[][]const u8` path slices, and `[]*Node` argument slices are allocated into this arena.
- String literal and lexeme values are slices into `source` — zero-copy from the input.
- When the caller is done with the `Ast`, calling `ast.deinit()` frees the entire tree in a single deallocation.
- **Recommended usage pattern:**
  ```
  var ast = switch (expr.parse(allocator, source)) {
      .ok  => |a| a,
      .fail => |errs| { ... handle errors ...; allocator.free(errs); return; },
  };
  defer ast.deinit();
  // evaluate, cache, or inspect ast.root
  ```
- The `[]ParseError` slice (on failure) is allocated from the caller's `allocator` and must be freed by the caller.
- `ParseError.token` slices point into `source`; do not free them independently.

---

## 9. Evaluator Interface (Stub)

Full evaluator design is deferred to the DSL-04/DSL-06 run. `mod.zig` declares the interface now so:
1. BACKEND-DEV can compile the module.
2. `engine/cel.zig` (or its DSL replacement) can call `expr.parse()` and `expr.evaluate()` against the established API boundary.
3. TEST-DESIGNER can write parse-only tests immediately.

The evaluator stub in `mod.zig`:
- Compiles cleanly.
- `evaluate()` returns `.err` with `message = "evaluator not yet implemented"`.
- `Context` and `Value` types are fully defined so downstream modules can declare their call sites.

**Engine integration (DSL-12):**
- The engine calls `expr.parse(allocator, source)` once per expression string when a definition is loaded or first evaluated.
- The resulting `Ast` is cached on the instance or definition snapshot.
- On gateway evaluation: `expr.evaluate(&cached_ast, &context, arena_allocator)` is called; the context is populated from the current instance variable map.
- The evaluator result is a `Value`. The engine expects `.bool_val` for gateway conditions; a non-bool result is treated as an evaluation error and the transition is blocked.

---

## 10. Key Invariants

1. `parse()` is deterministic: same `source` input always produces structurally identical `Ast` (DSL-02).
2. No I/O anywhere in `src/expr/`. Zero database calls, zero logging calls, zero OS calls.
3. `parse()` never panics. All error paths return structured `ParseError` values.
4. `evaluate()` (when implemented) never panics. All type errors return `EvalError`. (DSL-06 total evaluation guarantee.)
5. `Ast` is immutable after construction. `evaluate()` takes `*const Ast`.
6. All allocations use the arena embedded in `Ast`. No global allocator.
7. Lexeme slices point into the original `source`. The caller must keep `source` alive for the lifetime of any `ParseError` list derived from it.
8. Only the 11 whitelisted built-in functions are callable. Unknown function names produce a parse-time error (DSL-07).

---

## 11. External Dependencies

| Dependency | Kind | Notes |
|---|---|---|
| `std.mem.Allocator` | Zig stdlib | Arena wrapper for all node allocation |
| `std.heap.ArenaAllocator` | Zig stdlib | Embedded in `Ast`; freed on `deinit()` |
| `std.StringHashMap` | Zig stdlib | Used in `Context` for variable lookup |
| None (platform modules) | — | `src/expr/` has zero imports from `src/engine/`, `src/db/`, etc. |

---

## 12. Open Questions

1. **Comment syntax in DSL:** Architecture §5.1 does not specify comments. The lexer currently skips no comment syntax. If comments become needed (e.g. for debug annotation in gateway definitions), a `//` line-comment rule can be added without changing any other grammar production.

2. **Integer literal range:** The grammar says `number`. Should integer literals exceeding `i64` range be a lex error or silently overflow? Recommended: lex-time range check, emit `ParseError` if value overflows `i64`.

3. **String escape sequences:** The grammar does not enumerate allowed escapes inside string literals. Current design handles `\"` only. `\\`, `\n`, `\t` are common additions. Decision should be made before TEST-DESIGNER writes negative-case tests.

4. **`evaluate()` `now()` source:** DSL-09 requires `now()` to return the platform's current time. The evaluator will need a clock source injected via `Context` (e.g. a `platform_time_ms: i64` field) rather than calling `std.time.milliTimestamp()` directly — the latter would break the pure-function contract for test determinism.

5. **Comparison chain:** The grammar allows `cmp_expr := add_expr (op add_expr)?` — at most one comparison per expression. This means `a < b < c` is a parse error, not a chained comparison. This is intentional (avoids ambiguous semantics) but should be confirmed against the requirements.
