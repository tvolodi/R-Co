# Test Spec: DSL-08 — Function Purity

**Requirement:** DSL-08 — Every built-in function MUST be pure: same inputs yield same outputs, no side effects, no I/O.
**Priority:** MUST
**Test layer:** unit

---

## Test Strategy

All pure built-in functions are verified using a **double-call determinism test**: the same expression is parsed once, then evaluated twice with identical `Context`. The two results are compared using structural equality (`expectValueEq` — compares payloads by value, not by pointer). If the results are equal, the function is deterministic for that input. String results are compared by content (`std.mem.eql` / `testing.expectEqualStrings`) to avoid false failures from fresh allocations.

**Exemption:** `now()` is exempted from determinism testing because it reads the OS system clock. Instead, it is verified only for correct type (`ts_val`) and plausible range (between 2020-01-01 and year 3000).

**Test environment:** Pure Zig unit tests, no DB required, no I/O. Tests run via `zig build test`.

**Test helper:** `testDeterminism(alloc, source)` — parses `source`, evaluates twice, asserts structural equality.

---

## Coverage Matrix

| Pure built-in | Determinism tests | now() exemption test |
|---|---|---|
| `length` | 2 (TC-01, TC-02) | — |
| `lower` | 3 (TC-03, TC-04, TC-05) | — |
| `upper` | 1 (TC-06) | — |
| `trim` | 3 (TC-07, TC-08, TC-09) | — |
| `contains` | 3 (TC-10, TC-11, TC-12) | — |
| `startsWith` | 2 (TC-13, TC-14) | — |
| `endsWith` | 2 (TC-15, TC-16) | — |
| `coalesce` | 3 (TC-17, TC-18, TC-19) | — |
| `date_add` | 3 (TC-20, TC-21, TC-22) | — |
| `date_diff` | 2 (TC-23, TC-24) | — |
| `now` | — | 1 (TC-25) |

**Total: 24 determinism tests + 1 now() type/range test = 25 test cases**

---

## Test Cases

### TC-DSL-08-01: length determinism — normal string
**Given:** Source expression `length("hello")`
**When:** Parsed and evaluated twice with identical context
**Then:** Both evaluations return `int_val == 5` and are structurally equal
**Layer:** unit
**Acceptance criterion mapped:** Built-in `length` is pure (deterministic per input)

### TC-DSL-08-02: length determinism — null propagation
**Given:** Source expression `length(null)`
**When:** Parsed and evaluated twice with identical context
**Then:** Both evaluations return `null_val` and are structurally equal
**Layer:** unit
**Acceptance criterion mapped:** Built-in `length` is pure (null propagation is deterministic)

### TC-DSL-08-03: lower determinism — uppercase input
**Given:** Source expression `lower("HELLO")`
**When:** Parsed and evaluated twice with identical context
**Then:** Both evaluations return `str_val == "hello"` (content-equal, not pointer-equal) and are structurally equal
**Layer:** unit
**Acceptance criterion mapped:** Built-in `lower` is pure (deterministic per input; allocates new buffer each time)

### TC-DSL-08-04: lower determinism — empty string
**Given:** Source expression `lower("")`
**When:** Parsed and evaluated twice with identical context
**Then:** Both evaluations return `str_val == ""` and are structurally equal
**Layer:** unit
**Acceptance criterion mapped:** Built-in `lower` is pure (edge case: empty string)

### TC-DSL-08-05: lower determinism — null propagation
**Given:** Source expression `lower(null)`
**When:** Parsed and evaluated twice with identical context
**Then:** Both evaluations return `null_val` and are structurally equal
**Layer:** unit
**Acceptance criterion mapped:** Built-in `lower` is pure (null propagation is deterministic)

### TC-DSL-08-06: upper determinism — lowercase input
**Given:** Source expression `upper("hello")`
**When:** Parsed and evaluated twice with identical context
**Then:** Both evaluations return `str_val == "HELLO"` (content-equal) and are structurally equal
**Layer:** unit
**Acceptance criterion mapped:** Built-in `upper` is pure (deterministic per input)

### TC-DSL-08-07: trim determinism — surrounding whitespace
**Given:** Source expression `trim("  hello  ")`
**When:** Parsed and evaluated twice with identical context
**Then:** Both evaluations return `str_val == "hello"` and are structurally equal
**Layer:** unit
**Acceptance criterion mapped:** Built-in `trim` is pure (deterministic per input)

### TC-DSL-08-08: trim determinism — already trimmed
**Given:** Source expression `trim("hello")`
**When:** Parsed and evaluated twice with identical context
**Then:** Both evaluations return `str_val == "hello"` and are structurally equal
**Layer:** unit
**Acceptance criterion mapped:** Built-in `trim` is pure (edge case: no whitespace to strip)

### TC-DSL-08-09: trim determinism — null propagation
**Given:** Source expression `trim(null)`
**When:** Parsed and evaluated twice with identical context
**Then:** Both evaluations return `null_val` and are structurally equal
**Layer:** unit
**Acceptance criterion mapped:** Built-in `trim` is pure (null propagation is deterministic)

### TC-DSL-08-10: contains determinism — substring found
**Given:** Source expression `contains("hello world", "world")`
**When:** Parsed and evaluated twice with identical context
**Then:** Both evaluations return `bool_val == true` and are structurally equal
**Layer:** unit
**Acceptance criterion mapped:** Built-in `contains` is pure (deterministic per input)

### TC-DSL-08-11: contains determinism — substring not found
**Given:** Source expression `contains("hello world", "xyz")`
**When:** Parsed and evaluated twice with identical context
**Then:** Both evaluations return `bool_val == false` and are structurally equal
**Layer:** unit
**Acceptance criterion mapped:** Built-in `contains` is pure (deterministic per input; false result)

### TC-DSL-08-12: contains determinism — null propagation
**Given:** Source expression `contains(null, "x")`
**When:** Parsed and evaluated twice with identical context
**Then:** Both evaluations return `null_val` and are structurally equal
**Layer:** unit
**Acceptance criterion mapped:** Built-in `contains` is pure (null propagation is deterministic)

### TC-DSL-08-13: startsWith determinism — true
**Given:** Source expression `startsWith("hello", "hel")`
**When:** Parsed and evaluated twice with identical context
**Then:** Both evaluations return `bool_val == true` and are structurally equal
**Layer:** unit
**Acceptance criterion mapped:** Built-in `startsWith` is pure (deterministic per input)

### TC-DSL-08-14: startsWith determinism — false
**Given:** Source expression `startsWith("hello", "world")`
**When:** Parsed and evaluated twice with identical context
**Then:** Both evaluations return `bool_val == false` and are structurally equal
**Layer:** unit
**Acceptance criterion mapped:** Built-in `startsWith` is pure (deterministic per input; false result)

### TC-DSL-08-15: endsWith determinism — true
**Given:** Source expression `endsWith("hello", "llo")`
**When:** Parsed and evaluated twice with identical context
**Then:** Both evaluations return `bool_val == true` and are structurally equal
**Layer:** unit
**Acceptance criterion mapped:** Built-in `endsWith` is pure (deterministic per input)

### TC-DSL-08-16: endsWith determinism — false
**Given:** Source expression `endsWith("hello", "hel")`
**When:** Parsed and evaluated twice with identical context
**Then:** Both evaluations return `bool_val == false` and are structurally equal
**Layer:** unit
**Acceptance criterion mapped:** Built-in `endsWith` is pure (deterministic per input; false result)

### TC-DSL-08-17: coalesce determinism — first non-null
**Given:** Source expression `coalesce(null, "hello", "world")`
**When:** Parsed and evaluated twice with identical context
**Then:** Both evaluations return `str_val == "hello"` and are structurally equal
**Layer:** unit
**Acceptance criterion mapped:** Built-in `coalesce` is pure (deterministic per input)

### TC-DSL-08-18: coalesce determinism — all null
**Given:** Source expression `coalesce(null, null)`
**When:** Parsed and evaluated twice with identical context
**Then:** Both evaluations return `null_val` and are structurally equal
**Layer:** unit
**Acceptance criterion mapped:** Built-in `coalesce` is pure (deterministic per input; all-null case)

### TC-DSL-08-19: coalesce determinism — single arg
**Given:** Source expression `coalesce(42)`
**When:** Parsed and evaluated twice with identical context
**Then:** Both evaluations return `int_val == 42` and are structurally equal
**Layer:** unit
**Acceptance criterion mapped:** Built-in `coalesce` is pure (deterministic per input; single argument)

### TC-DSL-08-20: date_add determinism — seconds
**Given:** Source expression `date_add(1000, 5, "second")`
**When:** Parsed and evaluated twice with identical context
**Then:** Both evaluations return `ts_val == 1005` and are structurally equal
**Layer:** unit
**Acceptance criterion mapped:** Built-in `date_add` is pure (deterministic per input)

### TC-DSL-08-21: date_add determinism — days
**Given:** Source expression `date_add(0, 1, "day")`
**When:** Parsed and evaluated twice with identical context
**Then:** Both evaluations return `ts_val == 86400000` (1 day in ms) and are structurally equal
**Layer:** unit
**Acceptance criterion mapped:** Built-in `date_add` is pure (deterministic per input; day unit)

### TC-DSL-08-22: date_add determinism — negative offset
**Given:** Source expression `date_add(1000, -3, "hour")`
**When:** Parsed and evaluated twice with identical context
**Then:** Both evaluations return a `ts_val` 3 hours before 1000 and are structurally equal
**Layer:** unit
**Acceptance criterion mapped:** Built-in `date_add` is pure (deterministic per input; negative offset)

### TC-DSL-08-23: date_diff determinism — positive difference
**Given:** Source expression `date_diff(5000, 1000, "second")`
**When:** Parsed and evaluated twice with identical context
**Then:** Both evaluations return `int_val == 4` and are structurally equal
**Layer:** unit
**Acceptance criterion mapped:** Built-in `date_diff` is pure (deterministic per input)

### TC-DSL-08-24: date_diff determinism — negative difference
**Given:** Source expression `date_diff(1000, 5000, "second")`
**When:** Parsed and evaluated twice with identical context
**Then:** Both evaluations return `int_val == -4` and are structurally equal
**Layer:** unit
**Acceptance criterion mapped:** Built-in `date_diff` is pure (deterministic per input; negative result)

### TC-DSL-08-25: now returns timestamp in reasonable range (impure — exempted)
**Given:** Source expression `now()`
**When:** Parsed and evaluated
**Then:** The result is `.ok` with `ts_val` that is > 1_577_836_800_000 (2020-01-01) and < 32_506_752_000_000 (year 3000)
**Layer:** unit
**Acceptance criterion mapped:** `now()` returns a timestamp (type verified); determinism NOT tested per DSL-08 exemption

> **Note:** `now()` is impure per DSL-08. A determinism test (call twice, compare) would fail because each call reads the system clock. Only type and range are verified. No other built-in has this exemption.

---

## Purity Classification Summary

| # | Expression | Pure? | Tests determinism? | Notes |
|---|---|---|---|---|
| 1 | `length("hello")` | Pure | Yes (TC-01) | int result |
| 2 | `length(null)` | Pure | Yes (TC-02) | null propagation |
| 3 | `lower("HELLO")` | Pure | Yes (TC-03) | allocates new string |
| 4 | `lower("")` | Pure | Yes (TC-04) | edge: empty string |
| 5 | `lower(null)` | Pure | Yes (TC-05) | null propagation |
| 6 | `upper("hello")` | Pure | Yes (TC-06) | allocates new string |
| 7 | `trim("  hello  ")` | Pure | Yes (TC-07) | returns sub-slice |
| 8 | `trim("hello")` | Pure | Yes (TC-08) | already trimmed |
| 9 | `trim(null)` | Pure | Yes (TC-09) | null propagation |
| 10 | `contains("hello world", "world")` | Pure | Yes (TC-10) | bool result |
| 11 | `contains("hello world", "xyz")` | Pure | Yes (TC-11) | false result |
| 12 | `contains(null, "x")` | Pure | Yes (TC-12) | null propagation |
| 13 | `startsWith("hello", "hel")` | Pure | Yes (TC-13) | true |
| 14 | `startsWith("hello", "world")` | Pure | Yes (TC-14) | false |
| 15 | `endsWith("hello", "llo")` | Pure | Yes (TC-15) | true |
| 16 | `endsWith("hello", "hel")` | Pure | Yes (TC-16) | false |
| 17 | `coalesce(null, "hello", "world")` | Pure | Yes (TC-17) | first non-null |
| 18 | `coalesce(null, null)` | Pure | Yes (TC-18) | all null |
| 19 | `coalesce(42)` | Pure | Yes (TC-19) | single arg |
| 20 | `date_add(1000, 5, "second")` | Pure | Yes (TC-20) | timestamp arithmetic |
| 21 | `date_add(0, 1, "day")` | Pure | Yes (TC-21) | day unit |
| 22 | `date_add(1000, -3, "hour")` | Pure | Yes (TC-22) | negative offset |
| 23 | `date_diff(5000, 1000, "second")` | Pure | Yes (TC-23) | integer result |
| 24 | `date_diff(1000, 5000, "second")` | Pure | Yes (TC-24) | negative difference |
| 25 | `now()` | **Impure** | **No** (TC-25) | exempted; test only validates type and range |
