# Test Spec: DSL-05 — Type Coercion Rules

**Requirement:** DSL-05 — The DSL MUST implement type coercion between the six runtime types (`null`, `bool`, `int64`, `float64`, `string`, `timestamp`) across all operator categories, with three-valued null logic and no silent cross-type coercion in comparisons.  
**Priority:** MUST  
**Test layer:** unit

---

## Coercion Matrix Summary

| Category | null | bool | int64 | float64 | string | timestamp |
|----------|------|------|-------|---------|--------|-----------|
| **Arithmetic** | `∅→ERR` | `ERR` | `— int64` / `↑ float64` | `— float64` / `↑ int64→f64` | `ERR` | `ERR` |
| **Comparison** | `∅→null` / `null→bool` | `— bool` / `ERR cross` | `— bool` / `ERR cross` | `— bool` / `ERR cross` | `— bool` / `ERR cross` | `— bool` / `ERR cross` |
| **Boolean** | `→ null/bool` | `— bool` | `ERR` | `ERR` | `ERR` | `ERR` |
| **Unary neg** | `ERR` | `ERR` | `→ int64` | `→ float64` | `ERR` | `ERR` |
| **Unary not** | `→ null` | `→ bool` | `ERR` | `ERR` | `ERR` | `ERR` |

---

## Test Cases

### Arithmetic — Same-type

#### TC-DSL-05-A01: add int64 + int64 → int64
**Given:** Expression `1 + 2`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `int_val == 3`  
**Layer:** unit  
**Acceptance criterion mapped:** Arithmetic on same-type int64 produces int64

#### TC-DSL-05-A02: add float64 + float64 → float64
**Given:** Expression `1.5 + 2.5`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `float_val == 4.0`  
**Layer:** unit  
**Acceptance criterion mapped:** Arithmetic on same-type float64 produces float64

#### TC-DSL-05-A03: sub int64 - int64 → int64
**Given:** Expression `10 - 3`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `int_val == 7`  
**Layer:** unit  
**Acceptance criterion mapped:** Arithmetic on same-type int64 produces int64

#### TC-DSL-05-A04: mul int64 * int64 → int64
**Given:** Expression `6 * 7`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `int_val == 42`  
**Layer:** unit  
**Acceptance criterion mapped:** Arithmetic on same-type int64 produces int64

#### TC-DSL-05-A05: div int64 / int64 → int64 (truncation)
**Given:** Expression `10 / 3`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `int_val == 3` (integer division truncates)  
**Layer:** unit  
**Acceptance criterion mapped:** Arithmetic on same-type int64 produces int64

#### TC-DSL-05-A06: mod int64 % int64 → int64
**Given:** Expression `10 % 3`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `int_val == 1`  
**Layer:** unit  
**Acceptance criterion mapped:** Arithmetic on same-type int64 produces int64

---

### Arithmetic — Mixed-type Coercion

#### TC-DSL-05-A07: add int64 + float64 promotes to float64
**Given:** Expression `1 + 2.5`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `float_val == 3.5`  
**Layer:** unit  
**Acceptance criterion mapped:** int64 promoted to float64 when mixed with float64

#### TC-DSL-05-A08: add float64 + int64 promotes to float64
**Given:** Expression `2.5 + 1`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `float_val == 3.5`  
**Layer:** unit  
**Acceptance criterion mapped:** int64 promoted to float64 when mixed with float64

#### TC-DSL-05-A09: mul int64 * float64 promotes to float64
**Given:** Expression `3 * 1.5`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `float_val == 4.5`  
**Layer:** unit  
**Acceptance criterion mapped:** int64 promoted to float64 when mixed with float64

#### TC-DSL-05-A10: sub float64 - int64 promotes to float64
**Given:** Expression `5.5 - 2`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `float_val == 3.5`  
**Layer:** unit  
**Acceptance criterion mapped:** int64 promoted to float64 when mixed with float64

---

### Arithmetic — Error Cases

#### TC-DSL-05-A11: null in arithmetic returns error
**Given:** Expression `1 + null`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"arithmetic on null"`  
**Layer:** unit  
**Acceptance criterion mapped:** Null in arithmetic produces EvalError

#### TC-DSL-05-A12: non-numeric type in arithmetic returns error
**Given:** Expression `true + 1`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"type mismatch"`  
**Layer:** unit  
**Acceptance criterion mapped:** Non-numeric types in arithmetic produce EvalError

#### TC-DSL-05-A13: int64 + string returns type mismatch error
**Given:** Expression `1 + "1"`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"type mismatch"`  
**Layer:** unit  
**Acceptance criterion mapped:** String + int64 in arithmetic produces EvalError (no automatic string coercion)

#### TC-DSL-05-A14: string + string returns type mismatch error
**Given:** Expression `"a" + "b"`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"type mismatch"`  
**Layer:** unit  
**Acceptance criterion mapped:** String concatenation via + is not automatic; produces EvalError

---

### Arithmetic — Edge Cases

#### TC-DSL-05-A15: int64 division by zero returns error
**Given:** Expression `1 / 0`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"division by zero"`  
**Layer:** unit  
**Acceptance criterion mapped:** Division by zero in int64 arithmetic produces EvalError

#### TC-DSL-05-A16: int64 modulo by zero returns error
**Given:** Expression `10 % 0`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"modulo by zero"`  
**Layer:** unit  
**Acceptance criterion mapped:** Modulo by zero in int64 arithmetic produces EvalError

#### TC-DSL-05-A17: float64 modulo returns error
**Given:** Expression `5.5 % 2.0`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"modulo requires integer"`  
**Layer:** unit  
**Acceptance criterion mapped:** Modulo on float64 produces EvalError

#### TC-DSL-05-A18: float64 / 0.0 returns infinity (IEEE 754)
**Given:** Expression `5.0 / 0.0`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `float_val` being ±inf (not an error)  
**Layer:** unit  
**Acceptance criterion mapped:** Float division by zero follows IEEE 754 (infinity, not error)

---

### Unary Negation

#### TC-DSL-05-N01: negate int64
**Given:** Expression `-42`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `int_val == -42`  
**Layer:** unit  
**Acceptance criterion mapped:** int64 negation produces negated int64

#### TC-DSL-05-N02: negate float64
**Given:** Expression `-3.14`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `float_val == -3.14`  
**Layer:** unit  
**Acceptance criterion mapped:** float64 negation produces negated float64

#### TC-DSL-05-N03: negate null returns error
**Given:** Expression `-null`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"cannot negate null"`  
**Layer:** unit  
**Acceptance criterion mapped:** null negation produces EvalError

#### TC-DSL-05-N04: negate bool returns error
**Given:** Expression `-true`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"cannot negate bool"`  
**Layer:** unit  
**Acceptance criterion mapped:** bool negation produces EvalError

#### TC-DSL-05-N05: negate string returns error
**Given:** Expression `-"hello"`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"cannot negate string"`  
**Layer:** unit  
**Acceptance criterion mapped:** string negation produces EvalError

#### TC-DSL-05-N06: negate timestamp returns error
**Given:** Expression `-(ts_val)` where ts_val is a timestamp context variable  
**When:** Evaluated against context containing a timestamp  
**Then:** Result is `.err` with message containing `"cannot negate timestamp"`  
**Layer:** unit  
**Acceptance criterion mapped:** timestamp negation produces EvalError

---

### Comparison — Null Three-Valued Logic

#### TC-DSL-05-C01: null == null → true
**Given:** Expression `null == null`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `bool_val == true`  
**Layer:** unit  
**Acceptance criterion mapped:** null == null is true (null identity)

#### TC-DSL-05-C02: null != null → false
**Given:** Expression `null != null`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `bool_val == false`  
**Layer:** unit  
**Acceptance criterion mapped:** null != null is false

#### TC-DSL-05-C03: null <oper> null (ordering) → null
**Given:** Expressions `null < null`, `null <= null`, `null > null`, `null >= null`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `.null_val` for all ordering operators  
**Layer:** unit  
**Acceptance criterion mapped:** Ordering comparisons between two nulls return null

#### TC-DSL-05-C04: null == 42 → null
**Given:** Expression `null == 42`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `.null_val`  
**Layer:** unit  
**Acceptance criterion mapped:** null vs non-null comparison returns null

#### TC-DSL-05-C05: 42 != null → null
**Given:** Expression `42 != null`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `.null_val`  
**Layer:** unit  
**Acceptance criterion mapped:** non-null vs null comparison returns null

#### TC-DSL-05-C06: null < 5 → null
**Given:** Expression `null < 5`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `.null_val`  
**Layer:** unit  
**Acceptance criterion mapped:** null vs non-null ordering comparison returns null

#### TC-DSL-05-C07: 5 > null → null
**Given:** Expression `5 > null`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `.null_val`  
**Layer:** unit  
**Acceptance criterion mapped:** non-null vs null ordering comparison returns null

#### TC-DSL-05-C08: null <= 42 → null
**Given:** Expression `null <= 42`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `.null_val`  
**Layer:** unit  
**Acceptance criterion mapped:** null vs non-null lte comparison returns null

#### TC-DSL-05-C09: null >= 42 → null
**Given:** Expression `null >= 42`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `.null_val`  
**Layer:** unit  
**Acceptance criterion mapped:** null vs non-null gte comparison returns null

#### TC-DSL-05-C10: null == true → null
**Given:** Expression `null == true`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `.null_val`  
**Layer:** unit  
**Acceptance criterion mapped:** null vs bool comparison returns null

#### TC-DSL-05-C11: null == "hello" → null
**Given:** Expression `null == "hello"`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `.null_val`  
**Layer:** unit  
**Acceptance criterion mapped:** null vs string comparison returns null

---

### Comparison — Same-type

#### TC-DSL-05-C12: int64 less than
**Given:** Expression `2 < 3`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `bool_val == true`  
**Layer:** unit  
**Acceptance criterion mapped:** Same-type int64 comparison works

#### TC-DSL-05-C13: float64 equality
**Given:** Expression `3.14 == 3.14`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `bool_val == true`  
**Layer:** unit  
**Acceptance criterion mapped:** Same-type float64 comparison works

#### TC-DSL-05-C14: bool ordering false < true
**Given:** Expression `false < true`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `bool_val == true`  
**Layer:** unit  
**Acceptance criterion mapped:** Same-type bool ordering works

#### TC-DSL-05-C15: string lexicographic
**Given:** Expression `"apple" < "banana"`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `bool_val == true`  
**Layer:** unit  
**Acceptance criterion mapped:** Same-type string ordering works

#### TC-DSL-05-C16: string equality
**Given:** Expression `"hello" == "hello"`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `bool_val == true`  
**Layer:** unit  
**Acceptance criterion mapped:** Same-type string equality works

---

### Comparison — No Silent Coercion (Cross-type → EvalError)

#### TC-DSL-05-C17: int64 == float64 returns type mismatch error
**Given:** Expression `1 == 1.0`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"type mismatch"`  
**Layer:** unit  
**Acceptance criterion mapped:** No silent coercion between int64 and float64 in comparisons

#### TC-DSL-05-C18: int64 != float64 returns type mismatch error
**Given:** Expression `1 != 1.0`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"type mismatch"`  
**Layer:** unit  
**Acceptance criterion mapped:** No silent coercion between int64 and float64 in comparisons

#### TC-DSL-05-C19: float64 == int64 returns type mismatch error
**Given:** Expression `1.0 == 1`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"type mismatch"`  
**Layer:** unit  
**Acceptance criterion mapped:** No silent coercion between float64 and int64 in comparisons

#### TC-DSL-05-C20: int64 < float64 returns type mismatch error
**Given:** Expression `5 < 3.14`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"type mismatch"`  
**Layer:** unit  
**Acceptance criterion mapped:** No silent coercion between int64 and float64 in comparisons

#### TC-DSL-05-C21: bool == int64 returns type mismatch error
**Given:** Expression `true == 1`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"type mismatch"`  
**Layer:** unit  
**Acceptance criterion mapped:** No silent coercion between bool and int64 in comparisons

#### TC-DSL-05-C22: string == int64 returns type mismatch error
**Given:** Expression `"42" == 42`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"type mismatch"`  
**Layer:** unit  
**Acceptance criterion mapped:** No silent coercion between string and int64 in comparisons

#### TC-DSL-05-C23: bool == string returns type mismatch error
**Given:** Expression `true == "true"`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"type mismatch"`  
**Layer:** unit  
**Acceptance criterion mapped:** No silent coercion between bool and string in comparisons

---

### Three-Valued Boolean Logic — AND

#### TC-DSL-05-B01: true and true → true
**Given:** Expression `true and true`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `bool_val == true`  
**Layer:** unit  
**Acceptance criterion mapped:** Standard AND

#### TC-DSL-05-B02: true and false → false
**Given:** Expression `true and false`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `bool_val == false`  
**Layer:** unit  
**Acceptance criterion mapped:** Standard AND

#### TC-DSL-05-B03: false and true short-circuits to false
**Given:** Expression `false and true`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `bool_val == false`  
**Layer:** unit  
**Acceptance criterion mapped:** Short-circuit: false AND anything → false

#### TC-DSL-05-B04: false and null short-circuits to false
**Given:** Expression `false and null`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `bool_val == false`  
**Layer:** unit  
**Acceptance criterion mapped:** Short-circuit: false AND anything → false

#### TC-DSL-05-B05: true and null → null
**Given:** Expression `true and null`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `.null_val`  
**Layer:** unit  
**Acceptance criterion mapped:** Three-valued AND: true AND null → null

#### TC-DSL-05-B06: null and true → null
**Given:** Expression `null and true`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `.null_val`  
**Layer:** unit  
**Acceptance criterion mapped:** Three-valued AND: null AND true → null

#### TC-DSL-05-B07: null and false → null
**Given:** Expression `null and false`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `.null_val`  
**Layer:** unit  
**Acceptance criterion mapped:** Three-valued AND: null AND false → null

#### TC-DSL-05-B08: null and null → null
**Given:** Expression `null and null`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `.null_val`  
**Layer:** unit  
**Acceptance criterion mapped:** Three-valued AND: null AND null → null

#### TC-DSL-05-B09: and with non-boolean right operand returns error
**Given:** Expression `true and 42`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"boolean operator requires boolean"`  
**Layer:** unit  
**Acceptance criterion mapped:** Non-boolean in boolean AND produces error

#### TC-DSL-05-B10: and with non-boolean left operand returns error
**Given:** Expression `5 and true`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"boolean operator requires boolean"`  
**Layer:** unit  
**Acceptance criterion mapped:** Non-boolean in boolean AND produces error

---

### Three-Valued Boolean Logic — OR

#### TC-DSL-05-B11: true or false short-circuits to true
**Given:** Expression `true or false`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `bool_val == true`  
**Layer:** unit  
**Acceptance criterion mapped:** Short-circuit: true OR anything → true

#### TC-DSL-05-B12: false or true → true
**Given:** Expression `false or true`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `bool_val == true`  
**Layer:** unit  
**Acceptance criterion mapped:** Standard OR

#### TC-DSL-05-B13: false or false → false
**Given:** Expression `false or false`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `bool_val == false`  
**Layer:** unit  
**Acceptance criterion mapped:** Standard OR

#### TC-DSL-05-B14: false or null → null
**Given:** Expression `false or null`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `.null_val`  
**Layer:** unit  
**Acceptance criterion mapped:** Three-valued OR: false OR null → null

#### TC-DSL-05-B15: null or true → true
**Given:** Expression `null or true`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `bool_val == true`  
**Layer:** unit  
**Acceptance criterion mapped:** Three-valued OR: null OR true → true

#### TC-DSL-05-B16: null or false → null
**Given:** Expression `null or false`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `.null_val`  
**Layer:** unit  
**Acceptance criterion mapped:** Three-valued OR: null OR false → null

#### TC-DSL-05-B17: null or null → null
**Given:** Expression `null or null`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `.null_val`  
**Layer:** unit  
**Acceptance criterion mapped:** Three-valued OR: null OR null → null

#### TC-DSL-05-B18: true or null short-circuits to true
**Given:** Expression `true or null`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `bool_val == true`  
**Layer:** unit  
**Acceptance criterion mapped:** Short-circuit: true OR anything → true

#### TC-DSL-05-B19: or with non-boolean right operand returns error
**Given:** Expression `false or 42`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"boolean operator requires boolean"`  
**Layer:** unit  
**Acceptance criterion mapped:** Non-boolean in boolean OR produces error

#### TC-DSL-05-B20: or with non-boolean left operand returns error
**Given:** Expression `5 or false`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"boolean operator requires boolean"`  
**Layer:** unit  
**Acceptance criterion mapped:** Non-boolean in boolean OR produces error

---

### Three-Valued Boolean Logic — NOT

#### TC-DSL-05-B21: not true → false
**Given:** Expression `not true`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `bool_val == false`  
**Layer:** unit  
**Acceptance criterion mapped:** Standard NOT

#### TC-DSL-05-B22: not false → true
**Given:** Expression `not false`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `bool_val == true`  
**Layer:** unit  
**Acceptance criterion mapped:** Standard NOT

#### TC-DSL-05-B23: not null → null
**Given:** Expression `not null`  
**When:** Parsed and evaluated  
**Then:** Result is `.ok` with `.null_val`  
**Layer:** unit  
**Acceptance criterion mapped:** Three-valued NOT: NOT null → null

#### TC-DSL-05-B24: not 42 returns type mismatch error
**Given:** Expression `not 42`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"not requires boolean"`  
**Layer:** unit  
**Acceptance criterion mapped:** Non-boolean NOT produces error

---

### Dot-Path Null Propagation

#### TC-DSL-05-D01: dot_path resolves single segment from context
**Given:** Expression `x` evaluated with `x = 42` in context  
**When:** Evaluated  
**Then:** Result is `.ok` with `int_val == 42`  
**Layer:** unit  
**Acceptance criterion mapped:** Dot path resolves from variables

#### TC-DSL-05-D02: dot_path missing returns null
**Given:** Expression `missing_var` evaluated with empty context  
**When:** Evaluated  
**Then:** Result is `.ok` with `.null_val`  
**Layer:** unit  
**Acceptance criterion mapped:** Missing path returns null

#### TC-DSL-05-D03: dot_path multi-segment resolves
**Given:** Expression `a.b.c` evaluated with `"a.b.c" = "deep_value"` in context  
**When:** Evaluated  
**Then:** Result is `.ok` with `str_val == "deep_value"`  
**Layer:** unit  
**Acceptance criterion mapped:** Multi-segment dot path resolves

---

### No Automatic String Coercion

#### TC-DSL-05-S01: string + int64 returns type mismatch error
**Given:** Expression `"hello" + 42`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"type mismatch"`  
**Layer:** unit  
**Acceptance criterion mapped:** No automatic string-to-number coercion in arithmetic

#### TC-DSL-05-S02: int64 + string returns type mismatch error
**Given:** Expression `1 + "1"`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"type mismatch"`  
**Layer:** unit  
**Acceptance criterion mapped:** No automatic string-to-number coercion in arithmetic

#### TC-DSL-05-S03: string + string returns type mismatch error
**Given:** Expression `"a" + "b"`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"type mismatch"`  
**Layer:** unit  
**Acceptance criterion mapped:** No automatic string concatenation via arithmetic

#### TC-DSL-05-S04: string == int64 returns type mismatch error
**Given:** Expression `"42" == 42`  
**When:** Parsed and evaluated  
**Then:** Result is `.err` with message containing `"type mismatch"`  
**Layer:** unit  
**Acceptance criterion mapped:** No silent string-to-number coercion in comparisons

---

## Coverage Summary

| Category | Total cases | Covered by |
|----------|-------------|------------|
| Arithmetic same-type | 6 | TC-DSL-05-A01 through TC-DSL-05-A06 |
| Arithmetic mixed-type | 4 | TC-DSL-05-A07 through TC-DSL-05-A10 |
| Arithmetic error cases | 4 | TC-DSL-05-A11 through TC-DSL-05-A14 |
| Arithmetic edge cases | 4 | TC-DSL-05-A15 through TC-DSL-05-A18 |
| Unary negation | 6 | TC-DSL-05-N01 through TC-DSL-05-N06 |
| Null comparison (3-valued) | 11 | TC-DSL-05-C01 through TC-DSL-05-C11 |
| Same-type comparison | 5 | TC-DSL-05-C12 through TC-DSL-05-C16 |
| Cross-type comparison (errors) | 7 | TC-DSL-05-C17 through TC-DSL-05-C23 |
| Boolean AND (3-valued) | 10 | TC-DSL-05-B01 through TC-DSL-05-B10 |
| Boolean OR (3-valued) | 10 | TC-DSL-05-B11 through TC-DSL-05-B20 |
| Boolean NOT (3-valued) | 4 | TC-DSL-05-B21 through TC-DSL-05-B24 |
| Dot-path propagation | 3 | TC-DSL-05-D01 through TC-DSL-05-D03 |
| No string coercion | 4 | TC-DSL-05-S01 through TC-DSL-05-S04 |
| **Total** | **78** | |
