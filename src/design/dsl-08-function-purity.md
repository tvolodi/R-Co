# Module: Function Purity Contract — DSL-08

## Module purpose

Define and enforce the purity contract for all built-in functions in the Expression DSL. Every built-in function MUST be **pure** (deterministic, no side effects, no I/O), with a single explicit exemption for `now()`. This contract mirrors the Engine's pure transition function rule (EE-02): same inputs always produce identical outputs, regardless of how many times or in what order the function is called.

The purity contract lives at the evaluator layer (`src/expr/mod.zig`). It does not require new source files — it is a **behavioural contract** verified through tests and enforced by code review.

---

## Public interface

No new public functions are introduced. The purity contract constrains existing functions:

| Function | Signature | Purity |
|---|---|---|
| `length` | `length(str: string) → int` | **Pure** |
| `lower` | `lower(str: string) → string` | **Pure** |
| `upper` | `upper(str: string) → string` | **Pure** |
| `trim` | `trim(str: string) → string` | **Pure** |
| `contains` | `contains(haystack: string, needle: string) → bool` | **Pure** |
| `startsWith` | `startsWith(str: string, prefix: string) → bool` | **Pure** |
| `endsWith` | `endsWith(str: string, suffix: string) → bool` | **Pure** |
| `coalesce` | `coalesce(...values: any) → any` | **Pure** |
| `now` | `now() → timestamp` | **Impure** (exempted) |
| `date_add` | `date_add(ts: timestamp, n: int, unit: string) → timestamp` | **Pure** |
| `date_diff` | `date_diff(ts1: timestamp, ts2: timestamp, unit: string) → int` | **Pure** |

### Existing evaluator signatures (unchanged)

These are the functions on the critical purity path:

```zig
// In src/expr/mod.zig — evaluateNode handles .func_call dispatch
// Each built-in is dispatched inside the func_call case in evaluateNode().
// No signature changes are needed — the purity contract is a behavioural constraint.
```

---

## Data flow diagram

```mermaid
flowchart TD
    subgraph Caller["Caller (Engine / Test)"]
        ctx[Context\n{vars: StringHashMap(Value)}]
        expr[Parsed Ast]
    end

    subgraph Evaluator["evaluateNode()"]
        direction TB
        FCD[".func_call dispatch"]
        FCD --> length
        FCD --> lower
        FCD --> upper
        FCD --> trim
        FCD --> contains
        FCD --> startsWith
        FCD --> endsWith
        FCD --> coalesce
        FCD --> date_add
        FCD --> date_diff
        FCD --> now
    end

    subgraph Pure["Pure path — deterministic"]
        length -->|"arg.str_val.len"| int_val
        lower -->|"ascii.toLower()"| str_val
        upper -->|"ascii.toUpper()"| str_val
        trim -->|"whitespace strip"| str_val
        contains -->|"mem.indexOf()"| bool_val
        startsWith -->|"mem.startsWith()"| bool_val
        endsWith -->|"mem.endsWith()"| bool_val
        coalesce -->|"first non-null"| any_val
        date_add -->|"arithmetic + unit mult"| ts_val
        date_diff -->|"diff / unit mult"| int_val
    end

    subgraph Impure["Impure path — exempted"]
        now -->|"OS clock (RtlGetSystemTimePrecise / clock_gettime)"| ts_val
    end

    expr --> FCD
    ctx -.->|variable resolution| FCD

    int_val --> Value
    str_val --> Value
    bool_val --> Value
    any_val --> Value
    ts_val --> Value

    Value -->|"return to caller"| Result
```

**Key observation:** All pure functions receive their inputs as already-evaluated `Value` operands from `evaluateNode()`. The `Context` is only read for variable resolution (dot paths), which happens **before** the function is dispatched. The pure functions themselves never touch `Context`, I/O, or system state.

---

## Error taxonomy

| Error case | Produced by | Severity | Pure? |
|---|---|---|---|
| Wrong argument count (e.g. `length("a", "b")`) | evaluator | Error | Pure (deterministic per input) |
| Type mismatch (e.g. `length(42)`) | evaluator | Error | Pure |
| Null propagation (arg is null) | evaluator | Returns null | Pure |
| Arithmetic overflow in `date_add` | evaluator | Returns min/max i64 | Pure |
| Unknown unit in `date_add`/`date_diff` | evaluator | Error | Pure |
| Division by zero in arithmetic | evaluator | Error | Pure |
| Unknown function name | lexer (DSL-07 whitelist) | Parse-time error | N/A |

**No new error types are defined for DSL-08.** The purity contract does not introduce any new failure modes — it constrains behaviour that must not happen (side effects, I/O, non-determinism).

---

## Purity contract — detailed specification

### 1. Definition of pure (for this module)

A built-in function is **pure** if and only if all three hold:

1. **Deterministic:** For identical `Value` argument tuples, the function always returns the same `Value` result. Two successive calls with the same arguments must compare equal via `Value` structural equality.
2. **No side effects:** The function does not mutate any shared state (global variables, `Context`, argument `Value` payloads, allocator state visible to callers).
3. **No I/O:** The function does not read from files, databases, network, system clock, random number generator, or environment variables.

### 2. What is NOT a violation

- **Heap allocation** via the provided allocator is permitted. The allocator is an explicit parameter, and the function body uses it purely as a workspace. The allocation itself does not affect the output value's content (e.g. `lower()` allocates a buffer but its content is deterministically derived from the input). Callers observe the same logical result regardless of allocator behaviour.
- **Returning sub-slices of string arguments** (e.g. `trim()` returns a slice of the input). This is deterministic and zero-copy; the slice length and content are fully determined by the input.
- **Wrapping arithmetic** (`+%`, `-%`) used for performance. The result is still deterministic per input.

### 3. now() exemption — detailed

`now()` is the sole impure built-in. Its impurity stems from:

```zig
// In evaluateNode, func_call case:
const now_ms: i64 = if (builtin.os.tag == .windows) blk: {
    const ft: i64 = windows.ntdll.RtlGetSystemTimePrecise();
    // ...
} else blk: {
    // clock_gettime(CLOCK_REALTIME, &ts)
};
```

This reads the **OS system clock** every time it is called. Two successive calls with identical `Context` and `Ast` will (almost certainly) return different values.

**Documentation rules for `now()`:**
- The `func_call` dispatch in `evaluateNode()` carries a comment: `// NOTE: now() is inherently impure; all other built-ins are pure.` (already present)
- Any future built-in that needs system state (random, UUID, ambient timestamp) MUST be reviewed for purity and documented as an exception.
- No other built-in may read system state.

### 4. Enforcement mechanisms

**Compile-time:** The Zig compiler provides strong guarantees:
- No `@import("std")).os` calls outside `now()` in the func_call dispatch — all non-`now()` branches are pure arithmetic/string logic.
- No mutable global state (`threadlocal`, `export` variables) that built-in functions could modify.
- No database handles or HTTP clients in `src/expr/` — the module doc comment already states: `No I/O. No DB access. Pure functions.`

**Review-time (self-review checklist for BACKEND-DEV):**
- [ ] Every non-`now()` built-in uses only its argument `Value`s and the provided allocator
- [ ] No non-`now()` built-in reads `std.time`, `std.os`, `std.rand`, or any system state
- [ ] `now()` is the only `func_call` branch that does not return a deterministic result for identical inputs
- [ ] All string-returning pure functions either allocate fresh buffers or return sub-slices of their input (never mutate the input)

---

## Determinism test strategy

### Principle

For each pure built-in function, the test evaluates the same expression **twice** with identical `Context` and compares the results using `Value` equality (structural equality — comparing payloads by value, not by pointer).

For string-returning functions (`lower`, `upper`, `trim`), the test must use `std.mem.eql()` or `testing.expectEqualStrings()` rather than pointer equality, because `lower()`/`upper()` may allocate a new buffer each time.

### Test helper

```zig
/// Evaluate `expr` twice with the same context and assert results are equal.
fn testDeterminism(alloc: std.mem.Allocator, source: []const u8) !void {
    var ctx = Context.init(alloc);
    defer ctx.deinit();

    // First parse — reuse same AST for both evaluations
    var result = try parse(alloc, source);
    defer switch (result) {
        .ok => |*a| a.deinit(),
        .fail => |e| alloc.free(e),
    };
    try testing.expect(result == .ok);

    // Evaluate twice
    const ev1 = evaluate(&result.ok, &ctx, alloc);
    const ev2 = evaluate(&result.ok, &ctx, alloc);

    // Both must succeed
    try testing.expect(ev1 == .ok);
    try testing.expect(ev2 == .ok);

    // Results must be structurally equal
    try expectValueEq(ev1.ok, ev2.ok);
}
```

### Value equality helper

```zig
/// Assert two Values are structurally equal.
fn expectValueEq(a: Value, b: Value) !void {
    const testing = std.testing;
    try testing.expectEqual(@as(TypeTag, typeOf(a)), typeOf(b));
    switch (a) {
        .null_val => {}  // both null — trivially equal
        .bool_val => try testing.expectEqual(a.bool_val, b.bool_val),
        .int_val  => try testing.expectEqual(a.int_val, b.int_val),
        .float_val => try testing.expectEqual(a.float_val, b.float_val),
        .str_val  => try testing.expectEqualStrings(a.str_val, b.str_val),
        .ts_val   => try testing.expectEqual(a.ts_val, b.ts_val),
    }
}
```

### Test matrix

| # | Expression | Pure? | Tests determinism? | Notes |
|---|---|---|---|---|
| 1 | `length("hello")` | Pure | Yes | int result |
| 2 | `length(null)` | Pure | Yes | null propagation |
| 3 | `lower("HELLO")` | Pure | Yes | allocates new string |
| 4 | `lower("")` | Pure | Yes | edge: empty string |
| 5 | `lower(null)` | Pure | Yes | null propagation |
| 6 | `upper("hello")` | Pure | Yes | allocates new string |
| 7 | `trim("  hello  ")` | Pure | Yes | returns sub-slice |
| 8 | `trim("hello")` | Pure | Yes | already trimmed |
| 9 | `trim(null)` | Pure | Yes | null propagation |
| 10 | `contains("hello world", "world")` | Pure | Yes | bool result |
| 11 | `contains("hello world", "xyz")` | Pure | Yes | false result |
| 12 | `contains(null, "x")` | Pure | Yes | null propagation |
| 13 | `startsWith("hello", "hel")` | Pure | Yes | true |
| 14 | `startsWith("hello", "world")` | Pure | Yes | false |
| 15 | `endsWith("hello", "llo")` | Pure | Yes | true |
| 16 | `endsWith("hello", "hel")` | Pure | Yes | false |
| 17 | `coalesce(null, "hello", "world")` | Pure | Yes | first non-null |
| 18 | `coalesce(null, null)` | Pure | Yes | all null |
| 19 | `coalesce(42)` | Pure | Yes | single arg |
| 20 | `date_add(1000, 5, "second")` | Pure | Yes | timestamp arithmetic |
| 21 | `date_add(0, 1, "day")` | Pure | Yes | day unit |
| 22 | `date_add(1000, -3, "hour")` | Pure | Yes | negative offset |
| 23 | `date_diff(5000, 1000, "second")` | Pure | Yes | integer result |
| 24 | `date_diff(1000, 5000, "second")` | Pure | Yes | negative difference |
| 25 | `now()` | **Impure** | **No** | exempted; test only validates type and range |

**Total: 24 determinism tests** (pure functions only; row 25 is exempted).

### now() test — impurity documented, not tested for determinism

The existing test `DSL-07: now returns timestamp` verifies only that `now()` returns a `ts_val` with a plausible value. A determinism test for `now()` would **fail** by design. The test file should contain a comment explaining this:

```zig
// NOTE: now() is impure per DSL-08. A determinism test (call twice, compare)
// would fail because each call reads the system clock. Only type and range are
// verified. No other built-in has this exemption.
```

---

## State transitions

Not applicable. The purity contract does not define state machines. It is a **constraint** on existing function behaviour, not a new stateful system. The closest analogue is the engine's pure transition function (EE-02), which also:

- Accepts all inputs as parameters (no ambient state)
- Returns a value derived solely from those inputs
- Has no I/O
- Is verified by calling twice and comparing

---

## Dependencies

| Module | Dependency type | Notes |
|---|---|---|
| `src/expr/ast.zig` | Types consumed | `Value`, `TypeTag`, `Context`, `typeOf()`, value constructors |
| `src/expr/error.zig` | Types consumed | `EvalError` for type/arity errors |
| `src/expr/parser.zig` | Used by evaluator | `parse()` produces the `Ast` that contains `func_call` nodes |
| `src/expr/lexer.zig` | Used by parser | Lexer whitelists built-in function names (DSL-07) |
| `src/engine/transition.zig` | Design parallel | EE-02 purity rule — same principle, different module |
| `std.heap.ArenaAllocator` | Allocator | Used by `Ast` arena; pure functions receive caller allocator |
| `std.ascii` | Library | `toLower`, `toUpper`, `isWhitespace` |
| `std.mem` | Library | `indexOf`, `startsWith`, `endsWith`, `eql` |

### What it MUST NOT depend on

- `std.time` — any built-in (except `now()`) that reads the system clock
- `std.os` / `std.posix` — any system call
- `std.rand` — any randomness source
- Database modules (`src/db/`, `src/event_store/`) — no database access
- `src/engine/` — no coupling to engine internals
- Scheduler, timers, webhooks — no coupling to async subsystems

---

## Open questions

None. The DSL-08 requirement is unambiguous: every built-in except `now()` must be pure, and the test strategy (call twice, compare) is well-defined for all 10 pure functions. The implementation is already behaviourally correct — the task is to codify the contract and add determinism tests.

---

## Design decisions log

| Decision | Rationale | Date |
|---|---|---|
| No new Zig source files | The purity contract is behavioural + test-only; `src/expr/mod.zig` already has all the logic | 2026-05-27 |
| Determinism tests reuse the same parsed `Ast` | Re-parsing would test the parser's determinism (already covered by DSL-02), not the function's | 2026-05-27 |
| String equality by content, not pointer | `lower()`/`upper()` allocate new buffers each time; pointer equality would produce false failures | 2026-05-27 |
| `now()` exempted in documentation + tests | Requirement DSL-08 explicitly grants the exemption; the test file must comment it to prevent future confusion | 2026-05-27 |
| Pure functions must not read `Context` | Functions that resolved variables via `Context` would violate determinism if the context changed between calls. Currently no built-in reads `Context` — all inputs arrive as pre-evaluated `Value` args | 2026-05-27 |
