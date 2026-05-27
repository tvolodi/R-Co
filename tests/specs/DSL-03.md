# Test Spec: DSL-03 — Error Recovery

**Requirement:** DSL-03 — On parse error, the parser SHOULD report all errors in a single pass where possible, not stop at the first error.  
**Priority:** SHOULD  
**Test layer:** unit

---

## Overview

This spec covers five error-recovery scenarios:

1. **Acceptance test** — An input with three distinct syntax errors yields a report with three `ParseError` entries.
2. **Multiple grammar productions** — Errors across different grammar levels (primary, binary operator, grouping, function call).
3. **Regression** — Valid expressions still parse to `.ok`.
4. **Mixed lexer + parser errors** — Lexer-produced errors (unexpected character, integer overflow, unterminated string) combined with parser syntax errors.
5. **Error after recovery** — Parser continues past an error and finds a subsequent distinct error.

All tests are backend unit tests executed via `zig build test`.  
No database, no I/O. Test file: `tests/unit/expr_error_recovery_test.zig`.  
Entry point: `src/expr/mod.zig::parse(allocator, source)` returning `ParseResult` (`.ok` / `.fail`).

---

## Test Cases

### Section 1: Acceptance Test

#### TC-DSL03-001: Three distinct syntax errors yield three ParseError entries

**Given:** allocator is initialised  
**When:** `parse(alloc, "bogus(, ) +")` is called  
**Then:**
- Result is `.fail`
- `result.fail.len` equals 3
- Errors cover: unknown function `bogus`, expected expression for empty arg, unexpected trailing token

**Layer:** unit  
**Acceptance criterion mapped:** DSL-03 — three distinct errors produce three entries

---

### Section 2: Multiple Grammar Production Errors

#### TC-DSL03-002: Dot-path double-dot yields single non-cascading error

**Given:** allocator is initialised  
**When:** `parse(alloc, "order..total")` is called  
**Then:**
- Result is `.fail`
- `result.fail.len` equals 1
- Error message is `"expected identifier after '.'"`

**Layer:** unit  
**Acceptance criterion mapped:** DSL-03 — no cascading error after dot-path segment recovery

#### TC-DSL03-003: Binary operator double-operator recovers correctly

**Given:** allocator is initialised  
**When:** `parse(alloc, "1 + + 3")` is called  
**Then:**
- Result is `.fail`
- `result.fail.len` equals 1
- Error message is `"expected expression"` (for the second `+`)
- The `3` is parsed as the RHS of `+` (no cascade)

**Layer:** unit  
**Acceptance criterion mapped:** DSL-03 — binary operator error recovery, no cascading errors

#### TC-DSL03-004: Trailing operator after recovery produces second error

**Given:** allocator is initialised  
**When:** `parse(alloc, "1 + + 3 *")` is called  
**Then:**
- Result is `.fail`
- `result.fail.len` equals 2
- First error: `"expected expression"` for the second `+`
- Second error: `"expected expression"` for EOF after `*`

**Layer:** unit  
**Acceptance criterion mapped:** DSL-03 — error after recovery in binary operator chain

#### TC-DSL03-005: Missing closing paren after function call argument list

**Given:** allocator is initialised  
**When:** `parse(alloc, "now(1, 2")` is called  
**Then:**
- Result is `.fail`
- `result.fail.len` equals 1
- Error message is `"expected ')' after argument list"`

**Layer:** unit  
**Acceptance criterion mapped:** DSL-03 — no cascading error after `consumeArgList()` recovery

#### TC-DSL03-006: Comparison operator RHS with invalid operator token

**Given:** allocator is initialised  
**When:** `parse(alloc, "x == + 1")` is called  
**Then:**
- Result is `.fail`
- `result.fail.len` equals 1
- Error message is `"expected expression"` for `+`
- The `1` is parsed as the RHS of `==` (no cascade)

**Layer:** unit  
**Acceptance criterion mapped:** DSL-03 — comparison RHS recovery

#### TC-DSL03-007: Keyword where expression expected recovers to outer production

**Given:** allocator is initialised  
**When:** `parse(alloc, "true or and false")` is called  
**Then:**
- Result is `.fail`
- `result.fail.len` equals 1
- Error message is `"expected expression"` for `and` keyword

**Layer:** unit  
**Acceptance criterion mapped:** DSL-03 — `or_expr` recovers past invalid keyword in RHS position

#### TC-DSL03-008: Unclosed grouped expression with synchronize

**Given:** allocator is initialised  
**When:** `parse(alloc, "(1 + 2")` is called  
**Then:**
- Result is `.fail`
- `result.fail.len` equals 1
- Error message is `"expected ')'"`

**Layer:** unit  
**Acceptance criterion mapped:** DSL-03 — unclosed paren recovery (existing `lparen` branch synchronize)

#### TC-DSL03-009: Multiple unknown functions across `and` production

**Given:** allocator is initialised  
**When:** `parse(alloc, "bogus(1) and unknown(2)")` is called  
**Then:**
- Result is `.fail`
- `result.fail.len` is at least 2
- Both `bogus` and `unknown` produce "unknown function" errors

**Layer:** unit  
**Acceptance criterion mapped:** DSL-03 — multiple errors across different grammar positions

---

### Section 3: Regression — Valid Expressions

#### TC-DSL03-010: Complex valid expression parses to .ok

**Given:** allocator is initialised  
**When:** `parse(alloc, "order.total > 10000 and customer.tier == \"VIP\"")` is called  
**Then:**
- Result is `.ok`
- `result.ok.root.*` is `.and_expr`

**Layer:** unit  
**Acceptance criterion mapped:** DSL-03 — error recovery does not break valid parsing

---

### Section 4: Mixed Lexer + Parser Errors

#### TC-DSL03-011: Integer overflow lexer error combined with missing operator

**Given:** allocator is initialised  
**When:** `parse(alloc, "99999999999999999999 42")` is called  
**Then:**
- Result is `.fail`
- `result.fail.len` equals 2
- First error is from lexer: `"integer literal out of i64 range"`
- Second error is from parser: `"unexpected token after expression"` (two expressions with no operator)

**Layer:** unit  
**Acceptance criterion mapped:** DSL-03 — lexer error is merged into parse error list; parser continues and finds a second error

#### TC-DSL03-012: Unterminated string literal produces lexer error

**Given:** allocator is initialised  
**When:** `parse(alloc, "\"hello + 1")` is called  
**Then:**
- Result is `.fail`
- `result.fail.len` equals 1
- Error: `"unterminated string literal"` from lexer
- The unterminated string consumes all remaining input including `+ 1` up to EOF, so no parser error follows

**Layer:** unit  
**Acceptance criterion mapped:** DSL-03 — lexer unterminated string error is recorded; no cascading parser error from consumed remainder

#### TC-DSL03-013: Unexpected character lexer error combined with syntax error

**Given:** allocator is initialised  
**When:** `parse(alloc, "@ + 1")` is called  
**Then:**
- Result is `.fail`
- `result.fail.len` equals 2
- First error is from lexer: `"unexpected character"` for `@`
- Second error is from parser: `"expected expression"` for `+` (the `@` emitted as identifier is consumed, then `+` is unexpected)

**Note:** The lexer emits `@` as an identifier token with an `"unexpected character"` error. The parser consumes that identifier as a dot-path, then the `+` starts a new production. Depending on exact parsing flow, count may vary; the key assertion is that **both** the lexer error and at least one parser error appear in the result.

**Layer:** unit  
**Acceptance criterion mapped:** DSL-03 — lexer and parser errors are both reported in a single pass

---

### Section 5: Error After Recovery (Parser Continues Past First Error)

#### TC-DSL03-014: Double operator then trailing operator after recovery

**Given:** allocator is initialised  
**When:** `parse(alloc, "1 + + 3 or")` is called  
**Then:**
- Result is `.fail`
- `result.fail.len` equals 2
- First error: `"expected expression"` for the second `+`
- Second error: `"expected expression"` for EOF after `or`
- The parser successfully recovers, parses `3`, processes `or`, then finds the trailing `or`

**Layer:** unit  
**Acceptance criterion mapped:** DSL-03 — parser continues past first error and finds a subsequent error in a different production (`or_expr`)

#### TC-DSL03-015: Recovery through multiple levels of grammar

**Given:** allocator is initialised  
**When:** `parse(alloc, "true and or false or + 42")` is called  
**Then:**
- Result is `.fail`
- `result.fail.len` equals 2
- First error: `"expected expression"` for `or` after `and`
- Second error: `"expected expression"` for `+` after second `or`
- Parser recovers through `and_expr`, then through `or_expr`, finding errors at both levels

**Layer:** unit  
**Acceptance criterion mapped:** DSL-03 — error recovery spans multiple grammar levels and productions
