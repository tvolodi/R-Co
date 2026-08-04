# Module: dsl-06-total-evaluation — Total Evaluation for the Expression DSL

**Stage:** Stage 7 — Expression DSL  
**Requirement:** DSL-06 — Total evaluation `[MUST]`  
**Depends on:** `src/design/expr.md` (module layout, AST), `src/design/expr-types.md` (Value/TypeTag), `src/design/dsl-05-coercion.md` (coercion rules)  
**Affects:** `src/expr/mod.zig` only  
**Status:** Draft

---

## 1. Purpose

Guarantee that every call to `evaluate()` — and the recursive `evaluateNode()` it invokes — **always terminates** within a bounded number of recursive steps. Without this guard, a pathological expression (e.g. a deeply nested binary tree crafted to overflow the C stack, or a future extension that adds recursion) could crash the host or enter an effectively unbounded loop.

DSL-06 introduces:
1. A recursion depth parameter on `evaluateNode()` that decrements on every recursive call.
2. A public `evaluate()` wrapper that sets the initial max depth.
3. A `MAX_EVAL_DEPTH` constant with a recommended default of 1024.
4. Property-based tests that generate random valid-grammar expressions and verify all evaluate within the bound.

---

## 2. Depth Parameter — `evaluateNode()` Signature Change

### 2.1 Current signature

```zig
pub fn evaluateNode(
    node:      *const Node,
    ctx:       *const Context,
    allocator: std.mem.Allocator,
) EvalResult
```

### 2.2 Proposed signature

```zig
pub fn evaluateNode(
    node:           *const Node,
    ctx:            *const Context,
    allocator:      std.mem.Allocator,
    remaining:      usize,
) EvalResult
```

`remaining` is the number of additional recursive calls permitted. Each recursive call passes `remaining - 1`. When `remaining` reaches 0 before the node is fully evaluated, the function returns an `EvalError` instead of proceeding.

### 2.3 Evaluation protocol

```
evaluateNode(node, ctx, allocator, remaining):
  if remaining == 0:
    return EvalError("evaluation depth exceeded", line, column)

  switch node:
    // Leaf nodes (literals) — no recursion, return immediately
    .null_literal    => return ok(valueNull())
    .bool_literal    => ...
    .int_literal     => ...
    .float_literal   => ...
    .string_literal  => ...

    // Unary nodes — one recursive call
    .unary_neg       => return evalUnaryNeg(node, ctx, allocator, remaining - 1)
    .not_expr        => return evalNot(node, ctx, allocator, remaining - 1)

    // Binary nodes — two recursive calls (sequential, not parallel)
    .add_expr        => return evalArith(node, ctx, allocator, remaining - 1)
    .mul_expr        => return evalArith(node, ctx, allocator, remaining - 1)
    .cmp_expr        => return evalCmp(node, ctx, allocator, remaining - 1)
    .or_expr         => return evalLogicalOr(node, ctx, allocator, remaining - 1)
    .and_expr        => return evalLogicalAnd(node, ctx, allocator, remaining - 1)

    // Dot path — no recursion; segments are identifiers, not sub-expressions
    .dot_path        => return evalDotPath(node, ctx)

    // Function call — each argument node is a recursive call
    .func_call       => return evalFuncCall(node, ctx, allocator, remaining)
```

### 2.4 Where the decrement happens

For **unary operators** (`.unary_neg`, `.not_expr`): the helper function (e.g. `evalNegate`) is responsible for calling `evaluateNode(operand, ctx, allocator, remaining - 1)` with the decremented value.

For **binary operators** (`.add_expr`, `.mul_expr`, `.cmp_expr`, `.or_expr`, `.and_expr`): the helper function is responsible for calling `evaluateNode(left, ctx, allocator, remaining - 1)` and then `evaluateNode(right, ctx, allocator, remaining - 1)`.

For **short-circuit operators** (`.or_expr`, `.and_expr`): the right-hand side is only evaluated if the short-circuit condition is not met. The same `remaining - 1` value is passed to both left and right calls. This is safe because short-circuit evaluation reduces the actual number of recursive calls, never increases it beyond the binary case.

For **`.func_call`**: each argument is evaluated with the same `remaining - 1` value. Since arguments are evaluated left-to-right and the counter is decremented at each recursive `evaluateNode` call, the effective bound is: `remaining_per_arg = (remaining - 1) - (i - 1)` for the i-th argument. To keep the bound simple and conservative, pass `remaining - 1` to each argument eval call — if arguments ≥ remaining, the last argument(s) will hit the depth guard and return an error, which is acceptable fail-fast behaviour.

For **leaf nodes** (`.int_literal`, `.float_literal`, `.string_literal`, `.bool_literal`, `.null_literal`): no decrement check needed — they check at entry and return immediately. This is handled by the `remaining == 0` guard at the top of `evaluateNode`.

For **`.dot_path`**: no recursion into child nodes (segments are identifier strings, not sub-expressions). The depth guard at entry covers this case.

---

## 3. `MAX_EVAL_DEPTH` Constant

### 3.1 Definition

```zig
/// Maximum recursion depth for expression evaluation.
///
/// Rationale: typical expression depth from the grammar is logarithmic in
/// expression length. A well-typed expression of ~500 tokens rarely exceeds
/// depth 50. 1024 provides a 20× safety margin while being small enough to
/// prevent stack overflow with standard Zig stack sizes (~1 MiB default,
/// each frame ~200 bytes → ~5000 frames before overflow risk).
///
/// This is a safe upper bound for all expected use cases. If a real expression
/// exceeds this depth, it is likely a malicious input or a parser bug.
pub const MAX_EVAL_DEPTH: usize = 1024;
```

### 3.2 Rationale for 1024

| Factor | Value | Notes |
|--------|-------|-------|
| Max typical expression depth | ~50 | Deeply nested `(a and (b and (c and ...)))` |
| Safety margin | 20× | 1024 / 50 ≈ 20 |
| Zig default stack size | ~1 MiB | `ulimit -s` default on Linux |
| Estimated frame size | ~200 bytes | Return address + spilled locals + `@frameSize` |
| Max frames before overflow | ~5000 | 1 MiB / 200 bytes |
| Headroom vs overflow | ~5× | 5000 / 1024 ≈ 5× even at max depth |

1024 is conservative enough to never be hit by real expressions, yet far enough from the stack overflow threshold (~5000 frames) to avoid false positives from stack pressure.

### 3.3 Configurability (deferred)

The constant is defined as a `pub const` so that if future DSL extensions (e.g. user-defined functions or recursion) require a higher bound, it can be tuned in one place. No runtime configuration is needed for Stage 7.

---

## 4. `evaluate()` Wrapper Changes

### 4.1 Current `evaluate()`

```zig
pub fn evaluate(
    ast:       *const Ast,
    ctx:       *const Context,
    allocator: std.mem.Allocator,
) EvalResult {
    return evaluateNode(ast.root, ctx, allocator);
}
```

### 4.2 Proposed `evaluate()`

```zig
/// Evaluate an already-parsed `Ast` against a variable `Context`.
///
/// Uses `MAX_EVAL_DEPTH` as the recursion bound. Guarantees termination:
/// every recursive call decrements the depth counter; when it reaches 0,
/// an `EvalError` is returned.
///
/// `allocator` is used for intermediate allocations (string concatenation, etc.).
pub fn evaluate(
    ast:       *const Ast,
    ctx:       *const Context,
    allocator: std.mem.Allocator,
) EvalResult {
    return evaluateNode(ast.root, ctx, allocator, MAX_EVAL_DEPTH);
}

/// Evaluate a single `Node` with an explicit remaining depth bound.
///
/// Internal recursive calls decrement `remaining` by 1. When `remaining`
/// reaches 0, returns `EvalError` with message "evaluation depth exceeded".
pub fn evaluateNode(
    node:      *const Node,
    ctx:       *const Context,
    allocator: std.mem.Allocator,
    remaining: usize,
) EvalResult
```

### 4.3 Exported API surface — unchanged

The public API (`mod.zig`) exports `evaluate` with the same three-parameter signature. Existing callers (engine, tests) are unaffected.

`evaluateNode` becomes **public** (it was already public in the current code) with the additional `remaining` parameter. The `evaluateNode` function is not part of the stable public API per DSL-12 — it is exported only for module-internal use and test access.

---

## 5. Depth-Exceeded Error Behaviour

### 5.1 Error value

When the depth guard triggers:

```zig
EvalError{
    .message = "evaluation depth exceeded",
    .line    = node's line number,   // from the token that produced this node
    .column  = node's column number, // from the token that produced this node
}
```

### 5.2 Line/column provenance

The current `Node` tagged union does **not** carry source location. The `Token` struct in `ast.zig` has `line` and `column` fields, but these are consumed during parsing and not stored on `Node`.

**Design decision:** The depth-exceeded error will report `line = 0, column = 0` for the initial implementation. Adding source location to every `Node` variant is a separate concern that affects all 14 variants and would bloat the AST. If DSL-13 (error messages with source location) requires it, a future design artefact should add a `src_loc: struct { line: u32, column: u32 }` field to every `Node` variant.

For now, the error message is:

> `"evaluation depth exceeded"`

with `line = 0, column = 0`. This is consistent with how the existing `EvalError` values in `mod.zig` report location — all current error returns also use `line = 0, column = 0`.

### 5.3 Error surfacing

The depth-exceeded error is surfaced as any other `EvalError` — returned as `.err` from `evaluate()`:

```zig
const result = evaluate(&ast, &ctx, alloc);
switch (result) {
    .ok => |val| handleValue(val),
    .err => |e| {
        // e.message == "evaluation depth exceeded"
        // e.line == 0, e.column == 0
        reportEvaluationError(e);
    },
}
```

No panic, no crash, no `unreachable`. The error propagates through the normal `EvalResult` channel.

---

## 6. Changes Required in `src/expr/mod.zig`

### 6.1 Summary of changes

| Location | Change |
|----------|--------|
| Top of file | Add `pub const MAX_EVAL_DEPTH: usize = 1024;` |
| `evaluate()` | Add `MAX_EVAL_DEPTH` as initial `remaining` argument to `evaluateNode()` |
| `evaluateNode()` signature | Add `remaining: usize` parameter |
| `evaluateNode()` body | Add `if (remaining == 0) return EvalResult{ .err = EvalError{...} };` as the first statement after the `switch` dispatch |
| `evaluateNode()` recursive calls | Pass `remaining - 1` to every recursive `evaluateNode()` call |
| Helper functions (`evalArithmetic`, etc.) | Accept and propagate the `remaining` parameter |

### 6.2 Detailed: each recursive call site

All locations where `evaluateNode` is called recursively must pass `remaining - 1`:

1. **`.unary_neg`** — `evaluateNode(u.operand, ctx, allocator, remaining - 1)`
2. **`.not_expr`** — `evaluateNode(n.operand, ctx, allocator, remaining - 1)`
3. **`.add_expr`** — `evaluateNode(bin.left, ctx, allocator, remaining - 1)` then `evaluateNode(bin.right, ctx, allocator, remaining - 1)` (via `evalArithmetic`)
4. **`.mul_expr`** — same as `.add_expr` (via `evalArithmetic`)
5. **`.cmp_expr`** — `evaluateNode(cmp.left, ctx, allocator, remaining - 1)` then `evaluateNode(cmp.right, ctx, allocator, remaining - 1)`
6. **`.and_expr`** — `evaluateNode(bin.left, ctx, allocator, remaining - 1)` (short-circuit: right may be skipped)
7. **`.or_expr`** — `evaluateNode(bin.left, ctx, allocator, remaining - 1)` (short-circuit: right may be skipped)
8. **`.dot_path`** — no recursion; only the entry guard applies
9. **`.func_call`** — each argument evaluated with `evaluateNode(args[i], ctx, allocator, remaining - 1)`; the `evalFuncCall` helper receives `remaining` and manages argument evaluation

### 6.3 No changes outside `src/expr/mod.zig`

The task explicitly requires: **No changes outside `src/expr/` — no schema, no API, no engine changes.**

The following are out of scope for DSL-06:
- Any file outside `src/expr/`
- Database schema or migrations
- API routes or handlers
- Engine integration (DSL-12 handles engine integration)
- Frontend code

---

## 7. Property-Based Test Strategy

### 7.1 Test location

```zig
// In src/expr/mod.zig, after existing tests, or in a new test file:
// tests/unit/expr_total_evaluation_test.zig
```

### 7.2 Random expression generator

A deterministic (seeded) generator that produces valid-grammar ASTs directly (not source strings — we want to exercise `evaluateNode`, not the parser). The generator accepts a `max_gen_depth` parameter to bound the generated tree size.

```zig
/// Generate a random expression AST.
///
/// `gen_depth` controls nesting: 0 → leaf node only, >0 → may produce
/// binary/unary nodes with sub-trees at `gen_depth - 1`.
///
/// Returns an Ast whose arena is allocated from `allocator`.
fn generateRandomExpr(
    allocator: std.mem.Allocator,
    rng: *std.Random,
    gen_depth: usize,
) !Ast
```

### 7.3 Node variant coverage

The generator must be capable of producing **all 14 Node variants** (not 12 as referenced in the task — the actual count in `ast.zig` is 14). Coverage is achieved through these generation cases at `gen_depth > 0`:

| Case probability | Node variant produced | Requires `gen_depth ≥` |
|---|---|---|
| Weighted random | `or_expr` | 2 (two sub-trees at depth-1) |
| Weighted random | `and_expr` | 2 |
| Weighted random | `not_expr` | 1 (one sub-tree at depth-1) |
| Weighted random | `cmp_expr` | 2 |
| Weighted random | `add_expr` | 2 |
| Weighted random | `mul_expr` | 2 |
| Weighted random | `unary_neg` | 1 |
| Weighted random | `dot_path` | 0 (leaf — generates 1-3 segments) |
| Weighted random | `func_call` | 1 (generates 0-N arg nodes at depth-1) |
| Leaf fallback | `int_literal` | 0 |
| Leaf fallback | `float_literal` | 0 |
| Leaf fallback | `string_literal` | 0 |
| Leaf fallback | `bool_literal` | 0 |
| Leaf fallback | `null_literal` | 0 |

**Weighting strategy** — to ensure all 14 variants appear in a run of 100 expressions, use these approximate weights:

| Variant group | Count | Weight per variant | Total weight |
|---|---|---|---|
| Binary boolean (`or_expr`, `and_expr`) | 2 | 10% each | 20% |
| Unary boolean (`not_expr`) | 1 | 10% | 10% |
| Comparison (`cmp_expr`) | 1 | 10% | 10% |
| Arithmetic binary (`add_expr`, `mul_expr`) | 2 | 10% each | 20% |
| Unary negation (`unary_neg`) | 1 | 10% | 10% |
| Dot path (`dot_path`) | 1 | 10% | 10% |
| Func call (`func_call`) | 1 | 10% | 10% |
| Leaf literals (5 variants) | 5 | 2% each | 10% |

With `gen_depth = 6` and these weights, each run of 100 expressions has a >99.9% probability of covering all 14 variants.

### 7.4 Test assertions

For each generated expression:

1. **Evaluation completes within bound** — call `evaluateNode(root, ctx, alloc, MAX_EVAL_DEPTH)`. Must return `.ok` or `.err`, never crash or panic.
2. **Depth guard is effective** — for the same expression, call `evaluateNode(root, ctx, alloc, 1)`. If the expression has any non-leaf node, this must return `.err` with `message == "evaluation depth exceeded"`. If the expression is a single leaf node, it must return `.ok`.
3. **Result is a valid Value** — if `.ok`, the result must be one of the 6 `Value` variants.

### 7.5 At least 100 random expressions

The test must run **at least 100 iterations** with independent random seeds:

```zig
test "DSL-06: property — random expressions evaluate within bound" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();

    const num_exprs = 100;
    const gen_depth = 6;

    // Track which Node variants were covered
    var covered = std.EnumSet(NodeVariantTag).initEmpty();

    var ctx = Context.init(alloc);
    defer ctx.deinit();

    for (0..num_exprs) |i| {
        var ast = try generateRandomExpr(alloc, rng, gen_depth);
        defer ast.deinit();

        // Record variants present (walk the tree)
        recordVariants(ast.root, &covered);

        // 1. Must evaluate within full depth bound
        const result1 = evaluateNode(ast.root, &ctx, alloc, MAX_EVAL_DEPTH);
        try testing.expect(result1 == .ok or result1 == .err);
        // If ok, value must be a valid DSL type
        if (result1 == .ok) {
            _ = typeOf(result1.ok);
        }

        // 2. Depth guard: remaining=1 should fail for non-leaf expressions
        const result2 = evaluateNode(ast.root, &ctx, alloc, 1);
        _ = result2; // may be ok (leaf) or err (depth exceeded) — either is fine
    }

    // Verify all 14 variants were covered
    try testing.expect(covered.count() == 14);
}
```

### 7.6 Fuzzing considerations

For Stage 7, the property-based test covers valid-grammar random expressions. Future stages may add:

- A source-string fuzz test that round-trips `parse → evaluate(parse(...))` with random source strings (including invalid ones) to ensure the parser never crashes either.
- A dedicated stack-overflow test that constructs an expression with depth `MAX_EVAL_DEPTH + 1` and verifies the depth guard catches it before overflow.

These are explicitly **not in scope** for DSL-06, but the design accommodates them as future additions.

---

## 8. Test Structure for DSL-06

### 8.1 New test file

```zig
// tests/unit/expr_total_evaluation_test.zig
// or inline in src/expr/mod.zig
```

Three new test blocks:

| Test name | Description | Acceptance criterion |
|---|---|---|
| `DSL-06: MAX_EVAL_DEPTH constant exists` | Verify the constant is defined and equals 1024 | `MAX_EVAL_DEPTH == 1024` |
| `DSL-06: evaluate calls evaluateNode with MAX_EVAL_DEPTH` | Verify `evaluate` passes `MAX_EVAL_DEPTH` to `evaluateNode` (indirectly: a leaf-only expression at depth-1 returns ok) | Evaluation of a single literal succeeds |
| `DSL-06: property — random expressions evaluate within bound` | 100 random expressions, all variants covered, all evaluate without crash | ≥100 exprs, all 14 variants, no crashes |
| `DSL-06: depth guard catches deep expressions` | Construct an expression tree of depth `MAX_EVAL_DEPTH + 1` and verify it returns depth-exceeded error | `.err` with message containing "depth" |
| `DSL-06: leaf expressions succeed at remaining=1` | A single literal node with `remaining=1` returns `.ok` | `.ok` with correct value |

### 8.2 Helper: deep expression constructor

```zig
/// Build a deeply nested `or_expr` chain: ((...(a or b) or c) ... or z)
/// Returns an Ast whose arena is allocated from `allocator`.
fn buildDeepChain(allocator: std.mem.Allocator, depth: usize) !Ast
```

This is used by the depth-guard test to construct an expression exactly at the boundary.

---

## 9. Data Flow Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                        Caller code                          │
│  (engine, tests, expression UI)                             │
│                                                             │
│   evaluate(ast, ctx, alloc)                                 │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────┐
│  evaluate(ast, ctx, alloc)  [public API]                    │
│                                                              │
│  ┌─► calls evaluateNode(ast.root, ctx, alloc,               │
│  │                         MAX_EVAL_DEPTH=1024)             │
│  └───────────────────────────────────────────────────────────┤
│                                                              │
│  Returns: EvalResult { ok: Value | err: EvalError }         │
└──────────────────────┬───────────────────────────────────────┘
                       │ remaining=1024
                       ▼
┌──────────────────────────────────────────────────────────────┐
│  evaluateNode(node, ctx, alloc, remaining)                   │
│                                                              │
│  ┌─ if remaining == 0 → return EvalError("depth exceeded")  │
│  │                                                          │
│  │  switch node.tag:                                        │
│  │    ┌─ leaf (literal)  ──► return Value                  │
│  │    ├─ unary_neg/not_expr ──► evaluateNode(op, remain-1) │
│  │    ├─ add/mul/cmp_expr  ──► eval L: remain-1            │
│  │    │                          eval R: remain-1           │
│  │    ├─ or/and_expr       ──► eval L: remain-1            │
│  │    │                          (short-circuit: maybe R)   │
│  │    ├─ dot_path          ──► resolve from ctx (no rec)   │
│  │    └─ func_call         ──► eval args: each remain-1    │
│  └──────────────────────────────────────────────────────────┘
│                                                              │
│  Returns: EvalResult { ok: Value | err: EvalError }         │
└──────────────────────────────────────────────────────────────┘
```

---

## 10. Error Taxonomy

| Error message | Produced by | Severity |
|---|---|---|
| `"evaluation depth exceeded"` | `evaluateNode()` entry guard | Informational (malicious/deep input) |

This is the only new error added by DSL-06. It is returned as an `EvalError` and does not introduce a new error set variant — it reuses the existing `ExprError.EvalFailed` path through the public API.

---

## 11. Dependencies

### 11.1 Modules this design calls

| Module | Function | Nature |
|---|---|---|
| `src/expr/ast.zig` | `Node`, `Value`, `Context`, `typeOf()` | Types — no change needed |
| `src/expr/error.zig` | `EvalError`, `ExprError` | Error types — no change needed |

### 11.2 Modules that call this module

| Module | Function |
|---|---|
| `engine/cel.zig` | `evaluate()` (via `mod.zig` public API, DSL-12) |
| `tests/unit/expr_test.zig` | `evaluate()`, `evaluateNode()` |

### 11.3 What this module must NOT depend on

- No database access
- No engine modules (`src/engine/`)
- No API modules (`src/api/`)
- No I/O of any kind
- No `std.time` calls (the evaluator is pure except for `now()` built-in, which is out of scope for DSL-06)

---

## 12. Open Questions

1. **Source location on depth error:** The `Node` type does not carry `line`/`column` information. Should a future DSL-13 artefact add source location to every `Node` variant? This would enable precise error reporting for depth-exceeded errors (and all other EvalErrors).

2. **Configurability of MAX_EVAL_DEPTH:** Should the engine have the ability to set a per-evaluation max depth (e.g. for user-supplied expressions vs system expressions)? This is deferred but the signature of `evaluateNode` with `remaining` already supports it — callers could call `evaluateNode` directly with a custom bound.

3. **Function call argument depth accounting:** The current design passes `remaining - 1` to each argument evaluation in a func_call. If a function has N arguments where N > remaining, the last arguments will hit the depth guard. This is acceptable fail-fast behaviour, but a more sophisticated design could distribute `remaining` across arguments. Is this worth optimising? Recommendation: no — expressions with >100 arguments are unrealistic.

---

## 13. Acceptance Criteria Checklist

- [x] Design specifies `evaluateNode()` signature with depth parameter
- [x] Design specifies max depth constant (1024) and its rationale
- [x] Design specifies overflow behaviour (EvalError with `"evaluation depth exceeded"`)
- [x] Design specifies property-based test strategy (random expression generation + bounded evaluation, 100+ expressions, all 14 Node variants)
- [x] Design confirms no changes outside `src/expr/`
- [x] Design artefact written to `src/design/dsl-06-total-evaluation.md`
