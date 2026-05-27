# Test Spec: DSL-10 — Context Resolution

**Requirement:** DSL-10 — Identifier expressions (e.g. `order.total`) MUST resolve against a provided context map. Unresolved identifiers MUST evaluate to typed `null`, not crash.

**Priority:** MUST  
**Test layer:** unit

---

## Test Strategy

All context resolution tests are executed at the unit layer (pure Zig tests, no database, no I/O). Context resolution is a pure operation: given an explicit context map and an identifier expression, evaluation always produces the same result. These tests verify both successful resolution and the null-return behavior for missing identifiers.

**Test environment:** Pure Zig unit tests, no database required, no I/O. Tests run via `zig build test`.

**Key design invariants verified:**
- Identifier names map directly to context keys (case-sensitive)
- Missing top-level identifiers return `null` (not an error)
- Resolved identifiers return values in their original types (bool, int64, float64, string, timestamp)
- Type preservation: if context stores `int64`, evaluation returns `int_val`; if `bool`, returns `bool_val`, etc.
- Null context (empty map) treats all identifiers as unresolved, returning `null`
- Identifier names are non-empty strings matching the grammar pattern `[a-zA-Z_][a-zA-Z0-9_]*`
- Invalid identifier syntax is caught at parse time, not at resolution time

---

## Coverage Matrix

| Category | Test Cases | Layer |
|---|---|---|
| Resolved identifier — string value | TC-DSL-10-01 | unit |
| Resolved identifier — int64 value | TC-DSL-10-02 | unit |
| Resolved identifier — float64 value | TC-DSL-10-03 | unit |
| Resolved identifier — bool value (true) | TC-DSL-10-04 | unit |
| Resolved identifier — bool value (false) | TC-DSL-10-05 | unit |
| Resolved identifier — timestamp value | TC-DSL-10-06 | unit |
| Resolved identifier — null value in context | TC-DSL-10-07 | unit |
| Unresolved identifier (missing from context) | TC-DSL-10-08 | unit |
| Unresolved identifier (empty context) | TC-DSL-10-09 | unit |
| Case sensitivity — uppercase identifier | TC-DSL-10-10 | unit |
| Case sensitivity — mixed case identifier | TC-DSL-10-11 | unit |
| Case sensitivity — wrong case returns null | TC-DSL-10-12 | unit |
| Multiple identifiers in same context | TC-DSL-10-13 | unit |
| Multiple context keys, only one resolved | TC-DSL-10-14 | unit |
| Identifier with underscore prefix | TC-DSL-10-15 | unit |
| Identifier with digits in name | TC-DSL-10-16 | unit |
| Numeric string in context key | TC-DSL-10-17 | unit |
| Whitespace in identifier name (invalid) | TC-DSL-10-18 | unit |
| Empty identifier string (invalid) | TC-DSL-10-19 | unit |
| Context contains both string and numeric keys | TC-DSL-10-20 | unit |
| Type preservation — resolved int stays int64 | TC-DSL-10-21 | unit |
| Type preservation — resolved float stays float64 | TC-DSL-10-22 | unit |
| Type preservation — resolved bool stays bool | TC-DSL-10-23 | unit |
| Type preservation — resolved timestamp stays timestamp | TC-DSL-10-24 | unit |

**Total: 24 test cases covering all 6 categories**

---

## Test Cases

### Category 1: Resolved identifiers return correct values and types

### TC-DSL-10-01: Resolved identifier with string value
**Given:** Context `{ "name": "Alice" }` and expression `name`  
**When:** Evaluated  
**Then:** Returns `str_val == "Alice"`  
**Layer:** unit  
**Acceptance criterion mapped:** Resolved identifiers return the value at the correct type (string)

### TC-DSL-10-02: Resolved identifier with int64 value
**Given:** Context `{ "count": 42 }` and expression `count`  
**When:** Evaluated  
**Then:** Returns `int_val == 42`  
**Layer:** unit  
**Acceptance criterion mapped:** Resolved identifiers return the value at the correct type (int64)

### TC-DSL-10-03: Resolved identifier with float64 value
**Given:** Context `{ "price": 19.99 }` and expression `price`  
**When:** Evaluated  
**Then:** Returns `float_val == 19.99`  
**Layer:** unit  
**Acceptance criterion mapped:** Resolved identifiers return the value at the correct type (float64)

### TC-DSL-10-04: Resolved identifier with bool value (true)
**Given:** Context `{ "active": true }` and expression `active`  
**When:** Evaluated  
**Then:** Returns `bool_val == true`  
**Layer:** unit  
**Acceptance criterion mapped:** Resolved identifiers return the value at the correct type (bool)

### TC-DSL-10-05: Resolved identifier with bool value (false)
**Given:** Context `{ "enabled": false }` and expression `enabled`  
**When:** Evaluated  
**Then:** Returns `bool_val == false`  
**Layer:** unit  
**Acceptance criterion mapped:** Resolved identifiers return the value at the correct type (bool)

### TC-DSL-10-06: Resolved identifier with timestamp value
**Given:** Context `{ "created": 1672531200000 }` (2023-01-01 00:00:00 UTC in ms) and expression `created`  
**When:** Evaluated  
**Then:** Returns `ts_val == 1672531200000`  
**Layer:** unit  
**Acceptance criterion mapped:** Resolved identifiers return the value at the correct type (timestamp)

### TC-DSL-10-07: Resolved identifier with null value stored in context
**Given:** Context `{ "optional": null }` and expression `optional`  
**When:** Evaluated  
**Then:** Returns `null_val`  
**Layer:** unit  
**Acceptance criterion mapped:** Identifier exists in context but value is null; returns null (not error)

---

### Category 2: Unresolved identifiers return null without error

### TC-DSL-10-08: Unresolved identifier (missing from non-empty context)
**Given:** Context `{ "name": "Alice", "age": 30 }` and expression `address`  
**When:** Evaluated  
**Then:** Returns `null_val` without raising `EvalError`  
**Layer:** unit  
**Acceptance criterion mapped:** Evaluating an expression against a context with missing fields returns `null` without error

### TC-DSL-10-09: Unresolved identifier (empty context)
**Given:** Context `{}` (empty map) and expression `anything`  
**When:** Evaluated  
**Then:** Returns `null_val` without raising `EvalError`  
**Layer:** unit  
**Acceptance criterion mapped:** Evaluating an expression against an empty context returns `null` without error

---

### Category 3: Case sensitivity

### TC-DSL-10-10: Case sensitivity — uppercase identifier matches uppercase key
**Given:** Context `{ "NAME": "BOB" }` and expression `NAME`  
**When:** Evaluated  
**Then:** Returns `str_val == "BOB"`  
**Layer:** unit  
**Acceptance criterion mapped:** Identifier resolution is case-sensitive

### TC-DSL-10-11: Case sensitivity — mixed case identifier matches exactly
**Given:** Context `{ "firstName": "Charlie" }` and expression `firstName`  
**When:** Evaluated  
**Then:** Returns `str_val == "Charlie"`  
**Layer:** unit  
**Acceptance criterion mapped:** Identifier resolution is case-sensitive; mixed case matching works

### TC-DSL-10-12: Case sensitivity — wrong case returns null
**Given:** Context `{ "firstName": "Dave" }` and expression `firstname` (lowercase)  
**When:** Evaluated  
**Then:** Returns `null_val` (key `firstname` does not exist in context)  
**Layer:** unit  
**Acceptance criterion mapped:** Identifier resolution is case-sensitive; mismatched case returns null, not error

---

### Category 4: Multiple identifiers in context

### TC-DSL-10-13: Single identifier resolved from multi-key context
**Given:** Context `{ "a": 1, "b": 2, "c": 3 }` and expression `b`  
**When:** Evaluated  
**Then:** Returns `int_val == 2`  
**Layer:** unit  
**Acceptance criterion mapped:** Correct identifier is resolved from a context with multiple keys

### TC-DSL-10-14: Multiple unrelated keys in context, requested key missing
**Given:** Context `{ "x": 100, "y": 200 }` and expression `z`  
**When:** Evaluated  
**Then:** Returns `null_val`  
**Layer:** unit  
**Acceptance criterion mapped:** Missing identifier in multi-key context returns null

---

### Category 5: Identifier naming rules

### TC-DSL-10-15: Identifier with underscore prefix
**Given:** Context `{ "_private": "secret" }` and expression `_private`  
**When:** Evaluated  
**Then:** Returns `str_val == "secret"`  
**Layer:** unit  
**Acceptance criterion mapped:** Identifiers with leading underscores are valid

### TC-DSL-10-16: Identifier with digits in name
**Given:** Context `{ "var123": "value" }` and expression `var123`  
**When:** Evaluated  
**Then:** Returns `str_val == "value"`  
**Layer:** unit  
**Acceptance criterion mapped:** Identifiers with digits are valid

### TC-DSL-10-17: Numeric string as a context key (parsed as identifier)
**Given:** Context `{ "42": "answer" }` and expression `id_42` (identifier, not numeric literal)  
**When:** Evaluated  
**Then:** Returns `null_val` (key "id_42" does not exist; key "42" exists but is not referenced)  
**Layer:** unit  
**Acceptance criterion mapped:** Context keys can be numeric strings; identifier resolution is lexical

---

### Category 6: Invalid identifier syntax (parse-time errors)

### TC-DSL-10-18: Identifier with whitespace in name (invalid)
**Given:** Expression `var name` (whitespace between identifier parts)  
**When:** Parsed  
**Then:** Parsing fails with a structured parse error (invalid syntax)  
**Layer:** unit  
**Acceptance criterion mapped:** Invalid identifier syntax is caught at parse time, not resolution time

### TC-DSL-10-19: Empty identifier string (invalid)
**Given:** Expression with an empty identifier (e.g. `""` or syntax attempting to use no identifier)  
**When:** Parsed  
**Then:** Parsing fails with a structured parse error  
**Layer:** unit  
**Acceptance criterion mapped:** Empty identifier strings are invalid at parse time

---

### Category 7: Type preservation through resolution

### TC-DSL-10-20: Context contains keys of different types
**Given:** Context `{ "str": "hello", "num": 123, "flag": true }` and expression `num`  
**When:** Evaluated  
**Then:** Returns `int_val == 123` (type preserved)  
**Layer:** unit  
**Acceptance criterion mapped:** Resolved identifier returns correct type even when context has other types

### TC-DSL-10-21: Resolved int64 maintains int type (not coerced to float)
**Given:** Context `{ "quantity": 10 }` (stored as int64) and expression `quantity`  
**When:** Evaluated  
**Then:** Returns `int_val == 10` (not `float_val == 10.0`)  
**Layer:** unit  
**Acceptance criterion mapped:** Type preservation: resolved int64 stays int64

### TC-DSL-10-22: Resolved float64 maintains float type
**Given:** Context `{ "rate": 1.5 }` (stored as float64) and expression `rate`  
**When:** Evaluated  
**Then:** Returns `float_val == 1.5` (not `int_val == 1`)  
**Layer:** unit  
**Acceptance criterion mapped:** Type preservation: resolved float64 stays float64

### TC-DSL-10-23: Resolved bool maintains bool type
**Given:** Context `{ "success": true }` (stored as bool) and expression `success`  
**When:** Evaluated  
**Then:** Returns `bool_val == true` (not `int_val == 1`)  
**Layer:** unit  
**Acceptance criterion mapped:** Type preservation: resolved bool stays bool

### TC-DSL-10-24: Resolved timestamp maintains timestamp type
**Given:** Context `{ "ts": 1700000000000 }` (stored as timestamp) and expression `ts`  
**When:** Evaluated  
**Then:** Returns `ts_val == 1700000000000` (correct type preserved)  
**Layer:** unit  
**Acceptance criterion mapped:** Type preservation: resolved timestamp stays timestamp
