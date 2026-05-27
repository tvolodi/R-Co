# Design Artefact — DSL-03: Error Recovery

**Requirement:** DSL-03 (SHOULD)  
**Stage:** Stage 7 — Expression DSL  
**Author:** CODE-DESIGNER  
**Run ID:** WF02-dsl03-20260527  
**Status:** DESIGN

---

## 1. Module Purpose

Extend the existing error-recovery infrastructure in `src/expr/parser.zig` so that the parser reports **all** syntax errors in a single pass instead of stopping at the first error. The current implementation has `recordError()`, `synchronize()`, `sentinel()`, and `expect()` primitives, but several production paths either skip `synchronize()` after recording an error or use a synchronize strategy that is too coarse-grained, causing valid sub-expressions to be skipped and their errors to be missed.

The goal: a test input with three distinct syntax errors yields exactly three `ParseError` entries.

---

## 2. Current Infrastructure Audit

### 2.1 Existing primitives (all in `parser.zig`)

| Primitive | Location | Purpose |
|---|---|---|
| `errors: std.ArrayList(ParseError)` | `Parser` struct | Accumulates all errors during a single parse |
| `recordError(tok, msg)` | `Parser` fn | Appends a `ParseError` entry; OOM-safe (silent drop) |
| `synchronize()` | `Parser` fn | Advances past tokens until `.rparen`, `.comma`, or `.eof` |
| `sentinel()` | `Parser` fn | Returns a `null_literal` node so callers can continue building the tree |
| `expect(kind, msg)` | `Parser` fn | Checks the next token; records error + returns `null` on mismatch |

### 2.2 Existing call sites of `synchronize()`

| Location | After what error | Sync points |
|---|---|---|
| `parsePrimary()` `.lparen` branch | `expect(.rparen)` failed | `.rparen`, `.comma`, `.eof` |
| `parsePrimary()` `else` branch | Unexpected token (not a valid expression start) | `.rparen`, `.comma`, `.eof` |

### 2.3 Lexer error merging

The public `parse()` entry point already merges all lexer errors before starting the parser:

```zig
for (lex_result.errors) |le| {
    p.errors.append(allocator, le) catch {};
}
```

**Verdict: No gaps.** The lexer in `lexer.zig` records every error it encounters (unexpected character, unterminated string, integer overflow) and never halts early. All lexical errors are faithfully propagated to the parse error list.

### 2.4 `ParseError` type

```zig
pub const ParseError = struct {
    line: u32,
    column: u32,
    token: []const u8,
    message: []const u8,
};
```

**Verdict: Sufficient.** Four fields cover the acceptance criterion (line, column, token text, human-readable message). No additional fields needed.

---

## 3. Gap Analysis

### Gap A — Missing synchronize after dot-path segment error

**Location:** `parseIdentOrCall()` at the dot-path segment loop.

```zig
} else {
    self.recordError(seg_tok, "expected identifier after '.'");
    break;   // ← no synchronize() call
}
```

**Problem:** When a `.` is followed by an invalid token (operator, keyword, EOF, etc.), the error is recorded but the invalid token remains unconsumed. The parent production (`parsePrimary`'s caller) will see this token next and likely produce another error or misinterpret it.

**Example input:** `order..total`

1. `order` consumed as first segment
2. `.` consumed as dot
3. Next `.` is peeked — not an identifier/builtin → error recorded → **break** without synchronize
4. `parseIdentOrCall()` returns `dot_path(["order"])` (a 1-segment path)
5. Back in `parsePrimary()`: returns the `dot_path` node
6. Back in `parseUnary()`: returns the `dot_path`
7. Back in `parseMulExpr()`: while loop peeks `.` (still unconsumed!) → `.` is not `*`, `/`, `%` → break
8. Back in `parseAddExpr()`: while loop peeks `.` → not `+`, `-` → break
9. Back in `parseCmpExpr()`: peeks `.` → not a comparison op → returns `dot_path`
10. Continues up to `parseOrExpr()` → returns
11. At `parse()` final check: `p.check(.eof)` → false (`.` still unconsumed) → records "unexpected token after expression"

**Result:** 2 errors (expected identifier after '.' + unexpected token after expression) where there should be 1. The second error is a cascading artefact.

**Fix:** Add `self.synchronize()` after `self.recordError(...)` before `break`.

### Gap B — Synchronize too aggressive in `parsePrimary()` `else` branch

**Location:** `parsePrimary()` `else` branch.

```zig
else => {
    self.recordError(tok, "expected expression");
    self.synchronize();
    return self.sentinel();
}
```

**Problem:** `synchronize()` only stops at `.rparen`, `.comma`, `.eof`. When an unexpected token appears in a context where binary operators (`and`, `or`, `+`, `-`, `*`, `/`, `%`) or comparison operators follow, `synchronize()` skips past valid tokens that outer productions could have consumed.

**Example input:** `1 + + 3`

1. `parseAddExpr()`: left = `1`
2. Matches `+`, advances
3. RHS = `parseMulExpr()` → `parseUnary()` → `parsePrimary()`
4. `parsePrimary()` peeks `+` → `else` branch: records "expected expression" **→ synchronize()**
5. `synchronize()` skips `+`, then `3`, then `*` — none are sync points → reaches `.eof` → returns
6. `parsePrimary()` returns sentinel
7. `parseMulExpr()` returns sentinel (left), while loop: peek is `.eof` → break
8. `parseAddExpr()` gets sentinel as RHS, builds `add_expr(1, sentinel)`
9. Only **1 error** recorded (expected expression). The valid `3` was skipped entirely.

**Desired behaviour:** 2 errors:
- "expected expression" for the second `+`
- Then resume after the `+`, parse `3` successfully, then the outer while loop finds no more operators → done

**Fix:** Replace the monolithic `synchronize()` in `parsePrimary()`'s `else` branch with a single-token advance (skip just the offending token) plus a check for whether we've hit a meaningful recovery boundary. Alternatively, narrow `synchronize()` to skip only one token instead of all tokens up to the next sync point.

**Note:** The `.lparen` branch's `synchronize()` after a missing `)` is correct as-is — when a closing paren is missing, skipping to the next `.rparen` (or `,` or `.eof`) is the right recovery strategy.

### Gap C — Missing synchronize after `consumeArgList()` expect failure

**Location:** `consumeArgList()` final line.

```zig
_ = self.expect(.rparen, "expected ')' after argument list");
```

**Problem:** If the closing `)` is missing, `expect()` records the error but does not call `synchronize()`. The unconsumed tokens (whatever follows the arg list) will confuse the caller.

**Example input:** `now(1, 2 x`

1. `now` → builtin_func, `(` consumed
2. `consumeArgList()`: parse `1`, match `,`, parse `2`, peek is `x` (not `,` or `)`)
3. Wait — actually, `consumeArgList()` checks `self.match(.comma)` which returns null (next is `x`, not `,`). So it falls out of the while loop.
4. Then `self.expect(.rparen, ...)` — peek is `x` (identifier), not `.rparen` → records error, returns null
5. Returns `args = [1, 2]` — but `)` was missing
6. Back in `parseIdentOrCall()`: returns `func_call("now", [1, 2])`
7. Back up the chain, `parse()` final check: peeks `x` (not `.eof`) → records another error

**Result:** 2 errors where the ideal recovery would produce 1 (the missing `)`).

**Fix:** Add `self.synchronize()` after the `expect()` call in `consumeArgList()`:

```zig
if (self.expect(.rparen, "expected ')' after argument list") == null) {
    self.synchronize();
}
```

### Gap D — No local recovery in binary operator productions

**Locations:** `parseAddExpr()`, `parseMulExpr()`, `parseOrExpr()`, `parseAndExpr()`.

**Problem:** When a binary operator is consumed but the RHS parse fails, recovery happens deep inside `parsePrimary()`. Any tokens between the error and the next sync point are consumed by `synchronize()` in `parsePrimary()`'s `else` branch. The outer production's while-loop then finds no more operators and returns.

This is acceptable only if the deep recovery is correct. As shown in Gap B, the `else` branch synchronize is too aggressive.

**Impact of fixing Gap B:** If Gap B is fixed by narrowing the `else` branch to a single-token skip, the binary operator productions naturally recover correctly: the RHS parse either succeeds (producing a valid or sentinel node), or if it fails multiple times, each failure records an error and advances one token.

**Example:** `1 + + 3 *`
With Gap B fixed:
1. `parseAddExpr()`: left = `1`
2. Match `+`, advance
3. RHS: `parseMulExpr()` → `parseUnary()` → `parsePrimary()`: peek `+` → error, advance one token
4. RHS continues: `parsePrimary()` peeks `3` → returns `int_literal(3)` ✓
5. `parseMulExpr()` while loop: peeks `*` → match, advance
6. RHS: `parseUnary()` → `parsePrimary()`: peek `.eof` → error, advance (no-op at EOF)
7. `parseMulExpr()` builds `mul_expr(3, sentinel)`
8. `parseAddExpr()` builds `add_expr(1, mul_expr(3, sentinel))`
9. **2 errors** recorded (expected expression for `+`, expected expression for EOF)

**Result:** Both errors are captured. This passes the 3-error test when combined with another error elsewhere.

**Recommendation:** Do NOT add separate synchronize calls inside each binary production. Instead, fix the single synchronize call in `parsePrimary()`'s `else` branch (Gap B), which makes all binary productions recover correctly.

### Gap E — No local recovery in `parseCmpExpr()` RHS

**Location:** `parseCmpExpr()`.

```zig
const right = try self.parseAddExpr();
```

**Problem:** If a comparison operator is consumed (e.g., `==`) but the RHS `parseAddExpr()` encounters an error, recovery goes through the chain down to `parsePrimary()`. Same as Gap B/D — the synchronize in `parsePrimary()` may be too aggressive.

**Example input:** `x == + 1`

1. `parseCmpExpr()`: left = `dot_path(["x"])`
2. Peek `==` → advance
3. RHS: `parseAddExpr()` → ... → `parsePrimary()`: peek `+` → error + synchronize
4. With current code: synchronize skips `+`, then `1` (not sync points) → reaches `.eof`
5. Returns sentinel → `cmp_expr(dot_path, sentinel)`
6. **1 error** (expected expression). The valid `1` was skipped.

**Desired:** 1 error (expected expression for `+`), then parse `1` successfully.

**This is the same root cause as Gap B.** Fix Gap B and `parseCmpExpr()` recovers correctly.

---

## 4. Recovery Strategy Summary

| Production | Error scenario | Current behaviour | Proposed behaviour |
|---|---|---|---|
| `parsePrimary()` `else` | Unexpected token where expression expected | `synchronize()` skips all tokens to next sync point (`.rparen`, `,`, `.eof`) | Advance one token, then retry (see §5.2) |
| `parsePrimary()` `.lparen` | Missing `)` after grouped expression | `synchronize()` to next sync point | **Keep as-is** — correct for grouped context |
| `parseIdentOrCall()` dot-path | `expected identifier after '.'` | Record error, break, **no synchronize** | Record error, `synchronize()`, break |
| `consumeArgList()` | Missing `)` after argument list | Record error, **no synchronize** | Record error, `synchronize()`, return |
| `parseAddExpr()` | Operator consumed, RHS invalid | Deep recovery via `parsePrimary()` | **No change needed** — fixed by Gap B fix |
| `parseMulExpr()` | Operator consumed, RHS invalid | Deep recovery via `parsePrimary()` | **No change needed** — fixed by Gap B fix |
| `parseCmpExpr()` | Operator consumed, RHS invalid | Deep recovery via `parsePrimary()` | **No change needed** — fixed by Gap B fix |
| `parseOrExpr()` | Operator consumed, RHS invalid | Deep recovery via `parsePrimary()` | **No change needed** — fixed by Gap B fix |
| `parseAndExpr()` | Operator consumed, RHS invalid | Deep recovery via `parsePrimary()` | **No change needed** — fixed by Gap B fix |
| `parse()` final check | Trailing tokens after full expression | Record error, return `fail` | **Keep as-is** — correct |

### Sync point table

| Context | Sync points | Sentinel |
|---|---|---|
| `parsePrimary()` `else` (after fix) | Single-token advance, then re-check | `null_literal` |
| `parsePrimary()` `.lparen` | `.rparen`, `.comma`, `.eof` | Inner expression result (not sentinel) |
| `parseIdentOrCall()` dot-path | `.rparen`, `.comma`, `.eof` | Partial `dot_path` (collected segments) |
| `consumeArgList()` | `.rparen`, `.comma`, `.eof` | Partial `args` slice |

---

## 5. Proposed Changes to `parser.zig`

### 5.1 Gap A — Add synchronize after dot-path error

**File:** `src/expr/parser.zig`, function `parseIdentOrCall()`

```zig
// Before (current):
} else {
    self.recordError(seg_tok, "expected identifier after '.'");
    break;
}

// After:
} else {
    self.recordError(seg_tok, "expected identifier after '.'");
    self.synchronize();
    break;
}
```

**Rationale:** Consume all tokens up to the next sync point (`.rparen`, `,`, `.eof`) so the parent parser does not see the invalid token.

**LOC impact:** +1 line.

### 5.2 Gap B — Replace `synchronize()` in `parsePrimary()` `else` with single-token skip

**File:** `src/expr/parser.zig`, function `parsePrimary()`

```zig
// Before (current):
else => {
    self.recordError(tok, "expected expression");
    self.synchronize();
    return self.sentinel();
}

// After:
else => {
    self.recordError(tok, "expected expression");
    // Advance one token so we don't re-report the same error.
    // The caller's while-loop (binary ops) will check whether the
    // next token is an operator it can consume. If not, it stops
    // and returns the sentinel upward.
    if (self.peek().kind != .eof) {
        _ = self.advance();
    }
    return self.sentinel();
}
```

**Rationale:** A single-token skip allows the caller's binary-operator while-loop to re-enter `parsePrimary()` with the next token. If that token is valid (e.g., `3` in `1 + + 3`), it is parsed successfully and the binary operator consumes it. If it is also invalid (e.g., consecutive garbage), each garbage token is reported as a separate error.

**Trade-off:** Inside a grouped expression `(...)` or function-call argument list, this may cause more individual "expected expression" errors for consecutive garbage tokens rather than a single "skipped block" error. For the DSL-03 acceptance criterion (three distinct errors reported), this is the correct behaviour.

**LOC impact:** Replace ~3 lines with ~5 lines.

### 5.3 Gap C — Add synchronize after `consumeArgList()` expect failure

**File:** `src/expr/parser.zig`, function `consumeArgList()`

```zig
// Before (current):
_ = self.expect(.rparen, "expected ')' after argument list");

// After:
if (self.expect(.rparen, "expected ')' after argument list") == null) {
    self.synchronize();
}
```

**LOC impact:** +2 lines.

### 5.4 No changes needed

The following are **not changed** (verified correct):

- **`parsePrimary()` `.lparen` branch** — `synchronize()` after missing `)` is appropriate for grouped expressions
- **`parseAddExpr()`, `parseMulExpr()`, `parseOrExpr()`, `parseAndExpr()`, `parseCmpExpr()`** — rely on deep recovery; Gap B fix makes them correct
- **`parseNotExpr()`** — no binary operator, no synchronize needed
- **`parseUnary()`** — no binary operator, no synchronize needed
- **`lexer.zig`** — already collects all errors, no gaps
- **`error.zig`** — `ParseError` type is sufficient, no changes needed

---

## 6. Data Flow Diagram (Error Recovery Path)

```mermaid
flowchart TD
    A[parse source] --> B[tokenize - lexer.zig]
    B --> C{lex errors?}
    C -->|yes| D[merge into parser errors list]
    C -->|no| E[run parser productions]
    D --> E
    
    E --> F{parsePrimary else?}
    F -->|yes| G[recordError + advance one token + return sentinel]
    G --> H[caller binary-op loop re-checks]
    
    F -->|no| I{parseIdentOrCall dot-path error?}
    I -->|yes| J[recordError + synchronize + return partial dot_path]
    
    I -->|no| K{consumeArgList missing )?}
    K -->|yes| L[recordError + synchronize + return partial args]
    
    K -->|no| M[other productions - existing recovery suffices]
    
    H --> N{more operators?}
    N -->|yes| E
    N -->|no| O[return built node]
    
    J --> O
    L --> O
    M --> O
    
    O --> P{more tokens?}
    P -->|yes & not eof| Q[recordError unexpected token]
    P -->|no| R{errors list empty?}
    Q --> R
    R -->|yes| S[return .ok Ast]
    R -->|no| T[return .fail with all errors]
```

---

## 7. Error Taxonomy

| Error message | Source | Gap | Proposed change |
|---|---|---|---|
| `"expected expression"` | `parsePrimary()` `else` | B (too aggressive sync) | Replace `synchronize()` with single-token advance |
| `"expected identifier after '.'"` | `parseIdentOrCall()` | A (no sync) | Add `synchronize()` before `break` |
| `"expected ')' after argument list"` | `consumeArgList()` | C (no sync) | Add `synchronize()` after failed `expect()` |
| `"unexpected token after expression"` | `parse()` final check | None | Keep as-is |
| `"unknown function: only whitelisted built-ins are callable"` | `parseIdentOrCall()` | None | Already recovers via `consumeArgList()` |
| `"expected ')'"` | `parsePrimary()` `.lparen` | None | Already has `synchronize()` |
| All lexer errors | `lexer.zig` | None | Already merged in `parse()` |

---

## 8. Dependencies

### Calls
- `parser.zig` → `lexer.zig` (calls `tokenize()`)
- `parser.zig` → `ast.zig` (uses `Node`, `Token`, `Ast`)
- `parser.zig` → `error.zig` (uses `ParseError`)

### Must not depend on
- Any I/O module (I/O-free constraint)
- Database access
- The evaluator (DSL-04/DSL-06 comes later)
- `src/engine/` modules

---

## 9. Test Strategy

### 9.1 Existing test (must continue passing)
- `"error recovery: multiple errors in one pass"` — tests `"bogus(1) and unknown(2)"` expects ≥2 errors

### 9.2 New tests required

| Test input | Expected errors | What it verifies |
|---|---|---|
| `"1 + + 3 *"` | 2 errors: "expected expression" for `+`, "expected expression" for EOF after `*` | Gap B fix: binary-op recovery with single-token advance |
| `"order..total"` | 1 error: "expected identifier after '.'" (no cascade) | Gap A fix: synchronize after dot-path error |
| `"now(1, 2"` | 1 error: "expected ')' after argument list" (no cascade) | Gap C fix: synchronize after missing `)` |
| `"bogus(, ) +"` | 3 errors: unknown function, expected expression for `,`, unexpected token after expression for `+` | Full acceptance criterion: 3 distinct errors in one pass |
| `"x == + 1"` | 1 error: "expected expression" for `+`; `1` parsed correctly | Gap B fix: comparison-op RHS recovery |
| `"(1 + 2"` | 1 error: "expected ')'"; inner `1+2` parsed OK | Existing lparen recovery correct; no regression |
| `"true or and false"` | 1 error: "expected expression" for `and`; recovers to `true or sentinel`; `false` is consumed by outer parse | Gap B fix: `and` is single-skipped, not consuming `false` |

### 9.3 LOC estimate

| Change | Lines |
|---|---|
| Gap A: add `self.synchronize()` in `parseIdentOrCall()` | +1 |
| Gap B: replace `synchronize()` with single-token skip in `parsePrimary()` `else` | ~+2 net |
| Gap C: wrap `expect()` with null-check + `synchronize()` in `consumeArgList()` | +2 |
| Test file additions (new test functions) | ~+45 |
| **Total** | **~50 LOC** |

---

## 10. Open Questions

None. The requirement (DSL-03) is unambiguous, the gaps are well-localised, and the design changes are conservative (<50 LOC). No REQ-ANALYST clarification needed.
