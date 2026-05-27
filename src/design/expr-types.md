# Module: expr — Type System (DSL-04)

**Stage:** Stage 7 — Expression DSL  
**Requirement:** DSL-04 — Supported types  
**Design for:** `src/expr/` — type representation, literal syntax, integration with AST and evaluator  
**Depends on:** `src/design/expr.md` (module layout, AST, public API)

---

## 1. Purpose

Define the runtime type system for the Expression DSL. Exactly six value types are valid: `null`, `bool`, `int64`, `float64`, `string`, `timestamp`. The design covers their Zig representation, literal syntax in the grammar, parse-time rejection of unsupported types, and round-trip guarantees from parse through evaluation.

---

## 2. Type Representation — Zig `Value` Tagged Union

Defined in `src/expr/ast.zig` (already partially present; finalised here).

```zig
/// The six DSL runtime types per DSL-04.
/// No other variants are valid.
pub const Value = union(enum) {
    null_val: void,
    bool_val: bool,
    int_val: i64,
    float_val: f64,
    /// String value; slice owned by caller (arena or context).
    str_val: []const u8,
    /// Unix timestamp in milliseconds since epoch (UTC).
    ts_val: i64,
};
```

### 2.1 Tag aliases

For convenience in the evaluator, define a `TypeTag` enum that mirrors the active tags of `Value`:

```zig
pub const TypeTag = enum {
    null,
    bool,
    int64,
    float64,
    string,
    timestamp,
};
```

Plus a helper:

```zig
/// Returns the TypeTag for a given Value, without inspecting the payload.
pub fn typeOf(value: Value) TypeTag {
    return switch (value) {
        .null_val => .null,
        .bool_val => .bool,
        .int_val  => .int64,
        .float_val => .float64,
        .str_val  => .string,
        .ts_val   => .timestamp,
    };
}
```

This helper is used by the evaluator for coercion decisions (DSL-05) and by callers inspecting results.

### 2.2 Value construction helpers

To simplify evaluator code and reduce repetition:

```zig
pub fn valueNull() Value { return .{ .null_val = {} }; }
pub fn valueBool(b: bool) Value { return .{ .bool_val = b }; }
pub fn valueInt(n: i64) Value { return .{ .int_val = n }; }
pub fn valueFloat(f: f64) Value { return .{ .float_val = f }; }
pub fn valueStr(s: []const u8) Value { return .{ .str_val = s }; }
pub fn valueTs(ms: i64) Value { return .{ .ts_val = ms }; }
```

These are pure, inlineable wrappers. They belong in `ast.zig` alongside the `Value` type.

---

## 3. Literal Syntax

### 3.1 Grammar extensions

The existing `primary` production in the grammar (from `expr.md` §3) is already sufficient for 5 of the 6 types:

```
primary := number | string | bool | null
         | identifier ('.' identifier)*
         | '(' expr ')'
         | func_call
```

Where:
- `number` → `.int_literal` / `.float_literal` tokens → `int64` / `float64`
- `string` → `.string_literal` token → `string`
- `bool`  → `.true_kw` / `.false_kw` tokens → `bool`
- `null`  → `.null_kw` token → `null`

### 3.2 Literal forms by type

| Type      | Literal form | Token kind | Example source | AST node | Value variant |
|-----------|-------------|------------|----------------|----------|--------------|
| `null`    | `null`      | `.null_kw` | `null`         | `.null_literal` | `.null_val` |
| `bool`    | `true` / `false` | `.true_kw` / `.false_kw` | `true` | `.bool_literal` | `.bool_val` |
| `int64`   | Digit sequence, optional leading `-` (unary) | `.int_literal` | `42`, `-7` | `.int_literal` | `.int_val` |
| `float64` | Digit sequence with `.` | `.float_literal` | `3.14`, `-0.5` | `.float_literal` | `.float_val` |
| `string`  | `"..."` double-quoted with `\"` escape | `.string_literal` | `"hello"` | `.string_literal` | `.str_val` |
| `timestamp` | No direct literal form | — | — | — | `.ts_val` |

### 3.3 Timestamp provenance

`timestamp` values have **no literal form** in the grammar. They are produced only through:

1. **Built-in function `now()`** — returns the current UTC time in milliseconds (DSL-09).
2. **Built-in functions `date_add` / `date_diff`** — operate on and return timestamp values (DSL-07).
3. **Context variables** — a variable bound to a `Value.ts_val` in the `Context` map, e.g. an `order.created_at` field.

This means the "literal form where applicable" acceptance criterion for DSL-04 is satisfied for 5 of 6 types; timestamp is explicitly **not applicable** for a direct literal. Tests must verify timestamp creation through the three sources above.

### 3.4 Integer literal range

The lexer (`lexer.zig`) already checks that `.int_literal` lexemes parse within `i64` range. Overflow produces a `ParseError` with message `"integer literal out of i64 range"`. The token is still emitted so the parser can continue error recovery (DSL-03).

### 3.5 Float literal precision

`.float_literal` values are parsed with `std.fmt.parseFloat(f64, lexeme)`. IEEE 754 double precision applies. Precision loss for very large or high-precision decimals is accepted behaviour — no special error is raised for float overflow (infinity is a valid `f64` value per IEEE 754).

---

## 4. Parse-Time Rejection of Unsupported Types

### 4.1 What constitutes an "unsupported type"

An unsupported type is any value type outside the six named in DSL-04. Examples:
- `bigint`, `decimal`, `byte`, `array`, `map`, `object`, `date` (without time), `json`
- Any keyword resembling a type name that is not `null`, `true`, `false`

### 4.2 Rejection mechanism

The DSL grammar has **no type annotation syntax** — type information is implicit in literal tokens and built-in function results. Therefore unsupported types cannot appear as declarations; they can only be attempted as:

| Attempt | Mechanism | Result |
|---------|-----------|--------|
| Typing an unknown keyword like `decimal(42)` | Lexer: `decimal` is an `.identifier`; parser sees `identifier(` → not a builtin → records `ParseError` | `"unknown function: decimal"` |
| Typing an unknown keyword like `array[1,2,3]` | Lexer: `array` is `.identifier`; parser expects operator or EOF after identifier → unexpected `[` → records `ParseError` | `"expected expression"` (or similar) |
| Using a nonexistent type as a unqualified word | Lexer: word not in keyword table → `.identifier`; parser treats as dot_path segment | Evaluator sees variable lookup; if not in context, returns `EvalError` at runtime |
| Attempting a hexadecimal literal like `0xFF` | Lexer: `0` starts numeric scan, `x` stops it → produces `.int_literal` `"0"` then `.identifier` `"xFF"`; parser sees unexpected identifier → `ParseError` | `"expected expression"` |

**Key design decision:** Since the DSL has no type declarations, "unsupported type" rejection is distributed across the lexer, parser, and evaluator:

1. **Lexer** — rejects unknown type-like keywords implicitly by not classifying them as type tokens. Only `null`, `true`, `false` are recognised as type-related keywords.
2. **Parser** — rejects built-in function calls to non-whitelisted names (DSL-07). A name like `decimal(...)` triggers `"unknown function"` error.
3. **Evaluator** (future DSL-06) — rejects values at runtime if a built-in function attempts to produce a non-DSL-04 variant. Since `Value` is a closed tagged union, this is a compile-time guarantee for the Zig implementation.

### 4.3 Error message format

When an unsupported type attempt is detected, the `ParseError` uses these messages:

| Scenario | `message` field |
|----------|----------------|
| Unknown function name in call position | `"unknown function: <name>"` |
| Unexpected token where expression expected | `"expected expression"` |
| Unsupported type keyword (if any future grammar extension adds one) | `"unsupported type: <name>"` |

These messages are static string literals (zero allocation).

---

## 5. Integration with Existing AST and `evaluate()` Signature

### 5.1 AST node mapping

Every `Node` tag that represents a value already maps directly to a `Value` variant:

| Node tag | Produces Value |
|----------|---------------|
| `.int_literal` | `.int_val` |
| `.float_literal` | `.float_val` |
| `.string_literal` | `.str_val` |
| `.bool_literal` | `.bool_val` |
| `.null_literal` | `.null_val` |
| `.dot_path` | Resolved from `Context` (any variant) |
| `.func_call` | Return value of the built-in (any variant) |
| `.unary_neg` | `.int_val` or `.float_val` (negation of numeric) |
| `.add_expr` / `.mul_expr` | `.int_val` or `.float_val` (arithmetic) |
| `.cmp_expr` | `.bool_val` or `.null_val` (three-valued logic) |
| `.or_expr` / `.and_expr` / `.not_expr` | `.bool_val` or `.null_val` |

No new `Node` variants are needed for DSL-04. The existing 12-variant `Node` union covers all six value types.

### 5.2 Evaluator interface (unchanged from expr.md)

```zig
pub fn evaluate(
    ast:       *const Ast,
    ctx:       *const Context,
    allocator: std.mem.Allocator,
) EvalResult

// EvalResult = union(enum) { ok: Value, err: EvalError };
// EvalError  = struct { message: []const u8, line: u32, column: u32 };
```

The `Value` type is the output of every successful evaluation. The evaluator walks the AST recursively, computing a `Value` at each node. Leaf nodes (literals) produce their corresponding `Value` variant directly. Operator nodes inspect the operand `Value` tags to determine applicable coercion rules (DSL-05).

### 5.3 Evaluator stub update

The current stub in `mod.zig` returns "evaluator not yet implemented". When the evaluator is implemented (DSL-04/DSL-06 run), the body of `evaluate()` will be a recursive `switch` over `ast.root`:

```
evaluate(ast, ctx, allocator):
  switch ast.root:
    .int_literal    => ok(Value.int_val)
    .float_literal  => ok(Value.float_val)
    .string_literal => ok(Value.str_val)
    .bool_literal   => ok(Value.bool_val)
    .null_literal   => ok(Value.null_val)
    .dot_path       => ctx.vars.get(...) or EvalError
    .func_call      => dispatch_to_builtin(name, args)
    .unary_neg      => eval_negate(operand)
    .add_expr       => eval_binary_arith(op, left, right)
    .mul_expr       => eval_binary_arith(op, left, right)
    .cmp_expr       => eval_compare(op, left, right)
    .or_expr        => eval_logical_or(left, right)
    .and_expr       => eval_logical_and(left, right)
    .not_expr       => eval_logical_not(operand)
```

### 5.4 Context variable binding

The `Context` struct (already defined in `ast.zig`) maps variable names to `Value`:

```zig
pub const Context = struct {
    vars: std.StringHashMap(Value),
    // Optional: clock source for now() determinism (DSL-09)
    platform_time_ms: ?i64 = null,
};
```

When a `.dot_path` node is evaluated, the evaluator looks up each path segment in `ctx.vars`. A missing variable produces `EvalError` with message `"undefined variable: <name>"`.

The optional `platform_time_ms` field allows tests to inject a fixed "current time" for deterministic evaluation of `now()`. When `null`, the evaluator should use `std.time.milliTimestamp()` at the point of evaluation (though this breaks pure-function semantics — test injection is the recommended path per DSL-09).

---

## 6. Round-Trip Guarantee

### 6.1 Definition

> For any literal expression `E`, `evaluate(parse(E))` produces a `Value` whose tag matches the expected type and whose payload equals the original literal value.

### 6.2 Round-trip table

| Source `E` | Parsed `Node` | Evaluated `Value` | Equality check |
|---|---|---|---|
| `42` | `.int_literal = 42` | `.int_val = 42` | `value.int_val == 42` |
| `3.14` | `.float_literal = 3.14` | `.float_val = 3.14` | `value.float_val == 3.14` |
| `"hello"` | `.string_literal = "hello"` | `.str_val = "hello"` | `std.mem.eql(u8, value.str_val, "hello")` |
| `true` | `.bool_literal = true` | `.bool_val = true` | `value.bool_val == true` |
| `false` | `.bool_literal = false` | `.bool_val = false` | `value.bool_val == false` |
| `null` | `.null_literal = {}` | `.null_val = {}` | `value == .null_val` |
| `timestamp` | — | — | No literal form; round-trip test via `now()` or context binding |

### 6.3 Implementation of round-trip test

```zig
test "DSL-04: literal round-trip" {
    const cases = .{
        .{ "42",    Value.int_val,  @as(i64, 42) },
        .{ "3.14",  Value.float_val, @as(f64, 3.14) },
        .{ "\"hello\"", Value.str_val, @as([]const u8, "hello") },
        .{ "true",  Value.bool_val, @as(bool, true) },
        .{ "false", Value.bool_val, @as(bool, false) },
        .{ "null",  Value.null_val, @as(void, {}) },
    };
    // For each case: parse(source), evaluate(ast), compare payload
}
```

For timestamp: use `now()` as a functional round-trip (no literal source, but calling `now()` twice in the same context returns the same value), or verify that a context-bound timestamp value round-trips through a dot_path node.

### 6.4 Invariant enforcement

The round-trip property relies on these invariants:

1. **Lexer fidelity** — numeric lexemes are parsed with the same radix (decimal) at lex time (range check) and at eval time (no re-parsing needed — the value is stored in the `Node`).
2. **String content** — the parser strips surrounding quotes from `.string_literal` lexemes; the evaluator outputs the same inner slice. No escape interpretation beyond `\"` at the lexer level.
3. **Null identity** — `.null_literal` and `.null_val` are both `void` singletons; any null is equal to any other null.
4. **No implicit conversion** — literal nodes produce exactly one `Value` variant. `42` is always `.int_val`, never `.float_val`, until an arithmetic operator combines it with a float (DSL-05 coercion).

---

## 7. Data Flow Diagram

```mermaid
flowchart LR
    subgraph Source["Source Expression"]
        S["`42` / `true` / `\"hello\"` / `null`"]
    end

    subgraph Lexer["Lexer (lexer.zig)"]
        L["char scan → TokenKind\n.int_literal / .true_kw / etc."]
    end

    subgraph Parser["Parser (parser.zig)"]
        P["Token stream → Ast\nNode.int_literal / .bool_literal / etc."]
    end

    subgraph Evaluator["Evaluator (DSL-04/06)"]
        E["Ast → Value\n.int_val / .bool_val / .str_val / .null_val"]
    end

    subgraph Consumer["Consumer"]
        C["Engine / Gateway / Test"]
    end

    S --> L
    L --> P
    P --> E
    E --> C

    style Source fill:#e1f5fe
    style Lexer fill:#f3e5f5
    style Parser fill:#f3e5f5
    style Evaluator fill:#fff3e0
    style Consumer fill:#e8f5e9
```

---

## 8. Error Taxonomy

### 8.1 Errors specific to type system

| Error | Category | When raised | Message |
|-------|----------|-------------|---------|
| Integer out of range | Lex-time `ParseError` | `int_literal` exceeds `i64` range | `"integer literal out of i64 range"` |
| Float parse failure | Parse-time (recovered) | `float_literal` unparseable | `"invalid float literal"` |
| Unterminated string | Lex-time `ParseError` | String literal reaches newline or EOF without `"` | `"unterminated string literal"` |
| Unknown built-in in call position | Parse-time `ParseError` | `identifier(` where name is not whitelisted | `"unknown function: <name>"` |
| Undefined variable | Eval-time `EvalError` | `.dot_path` segment not in `Context` | `"undefined variable: <name>"` |
| Type mismatch in operator | Eval-time `EvalError` | Operator applied to incompatible operand types | `"type mismatch: cannot <op> <type> and <type>"` |

### 8.2 Error sets

```zig
// In error.zig — the TypeError set captures type-specific failures.
// These are wrapped inside EvalError at runtime.
pub const TypeError = error{
    TypeMismatch,
    UndefinedVariable,
    DivisionByZero,
};
```

For parse-time type errors, the existing `ParseError` struct is sufficient — no new error variant is needed.

---

## 9. Dependencies

| Module | Dependency direction | What it provides |
|--------|---------------------|------------------|
| `src/expr/ast.zig` | Self | `Value`, `TypeTag`, `typeOf()`, value helpers |
| `src/expr/error.zig` | Self | `ParseError`, `EvalError`, `ExprError` |
| `src/expr/lexer.zig` | Uses `ast.zig` | Tokenises source; validates int range |
| `src/expr/parser.zig` | Uses `ast.zig`, `error.zig` | Produces `Ast` with literal `Node` values |
| `src/expr/mod.zig` | Re-exports all | Public API: `parse()`, `evaluate()` |
| `src/engine/cel.zig` | → `mod.zig` (future) | Calls `parse()` and `evaluate()` on gateway expressions |
| `std.StringHashMap` | External | Variable context map |
| `std.fmt.parseInt / parseFloat` | External | String-to-number conversion |

### What this module MUST NOT depend on

- `src/engine/` — no engine types
- `src/db/` — no database types
- `src/obs/` — no logging or metrics
- Any allocator beyond what's passed in

---

## 10. Key Invariants

1. **`Value` is a closed union.** No variant outside the six DSL-04 types can be constructed at compile time.
2. **No silent type conversion.** Literal `42` is always `.int_val`. Conversion to `.float_val` only occurs in arithmetic per DSL-05.
3. **Timestamp always UTC.** All `.ts_val` values are Unix milliseconds since epoch in UTC. Timezone conversion is never performed inside `src/expr/`.
4. **Parse then evaluate is safe.** `parse()` returns a valid `Ast` or error list. `evaluate()` on a valid `Ast` always returns a `Value` or `EvalError` — never panics (DSL-06).
5. **Round-trip for all literal types.** For any literal expression, `evaluate(parse(E))` reproduces the original value.
6. **String slices point into source or arena.** `Value.str_val` slices must outlive the eval result. The caller owns the lifetime.

---

## 11. Open Questions

1. **Timestamp literal syntax.** Should a future version of the DSL support a direct timestamp literal (e.g. `2026-05-27T12:00:00Z` or a prefix form like `ts"2026-05-27T12:00:00Z"`)? Currently timestamps come only from built-ins and context. This is acceptable per DSL-04 ("where applicable") but a direct form would improve ergonomics for gateway expression authors.

2. **Negative float notation.** The grammar allows `unary := '-'? primary`. For `-3.14`, the AST becomes `unary_neg(float_literal(3.14))`. The evaluator must negate the `f64` value. This is consistent with integer negation. Confirm this matches the expected evaluator semantics.

3. **String escape completeness.** The lexer handles `\"` only. Should `\\`, `\n`, `\t`, `\r`, `\0`, and `\uXXXX` be supported? This affects string literal round-trip (a string containing a backslash currently must be represented as `"\\"` in DSL source — which the lexer does not handle, so it would parse `"\\"` literally as two characters `\` and `\`). **Recommendation: add `\\` escape before TEST-DESIGNER writes negative tests.** See also expr.md §12 Open Question 3.

4. **`now()` determinism in tests.** The `platform_time_ms` field on `Context` is the recommended approach. However, if `Context` is constructed by engine code that does not set this field, `now()` falls back to `std.time.milliTimestamp()`, breaking determinism. Should the fallback be removed (making `platform_time_ms` required) to enforce pure-function semantics? That would shift the clock-reading responsibility to the engine, which is architecturally cleaner.
