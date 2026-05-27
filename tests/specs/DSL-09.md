# Test Spec: DSL-09 — Date Built-ins

**Requirement:** DSL-09 — `now()` MUST return the platform's current time. `date_add(ts, n, unit)` and `date_diff(ts1, ts2, unit)` MUST support units: `second`, `minute`, `hour`, `day`. Time math MUST use UTC; no implicit timezone handling.

**Priority:** MUST
**Test layer:** unit

---

## Test Strategy

All date built-in functions are tested at the unit layer (pure Zig tests, no DB, no I/O). The functions `date_add` and `date_diff` are pure: given explicit inputs, they always produce the same result. They are tested with known fixed inputs and expected outputs for each supported unit.

The `now()` function is impure (reads OS system clock) and is tested only for correct return type (`ts_val`) and a plausible range (value > 1_000_000_000_000 ms since epoch, which corresponds to ~2001).

**Test environment:** Pure Zig unit tests, no DB required, no I/O. Tests run via `zig build test`.

**Key design invariants verified:**
- All time values are `i64` milliseconds since Unix epoch
- Day arithmetic is pure millisecond arithmetic (86400000 ms), not calendar-aware
- No timezone conversion is ever performed
- Null propagation occurs before type checking
- Overflow on `n * multiplier` returns `EvalError`; overflow on `ts ± delta` saturates to `maxInt`/`minInt`

---

## Coverage Matrix

| Category | Test Cases | Layer |
|---|---|---|
| `now()` type and range | TC-DSL-09-01 | unit |
| `date_add` — second | TC-DSL-09-02 | unit |
| `date_add` — minute | TC-DSL-09-03 | unit |
| `date_add` — hour | TC-DSL-09-04 | unit |
| `date_add` — day | TC-DSL-09-05 | unit |
| `date_diff` — second | TC-DSL-09-06 | unit |
| `date_diff` — minute | TC-DSL-09-07 | unit |
| `date_diff` — hour | TC-DSL-09-08 | unit |
| `date_diff` — day | TC-DSL-09-09 | unit |
| Null propagation — `date_add` ts arg | TC-DSL-09-10 | unit |
| Null propagation — `date_add` n arg | TC-DSL-09-11 | unit |
| Null propagation — `date_add` unit arg | TC-DSL-09-12 | unit |
| Null propagation — `date_diff` ts1 arg | TC-DSL-09-13 | unit |
| Null propagation — `date_diff` ts2 arg | TC-DSL-09-14 | unit |
| Null propagation — `date_diff` unit arg | TC-DSL-09-15 | unit |
| Unknown unit string | TC-DSL-09-16 | unit |
| Cross-DST boundary (UTC arithmetic) | TC-DSL-09-17 | unit |
| Negative n for `date_add` | TC-DSL-09-18 | unit |
| Negative diff for `date_diff` (ts1 < ts2) | TC-DSL-09-19 | unit |
| Wrong argument count — `now` with args | TC-DSL-09-20 | unit |
| Wrong argument count — `date_add` 2 args | TC-DSL-09-21 | unit |
| Wrong argument count — `date_add` 4 args | TC-DSL-09-22 | unit |
| Wrong argument count — `date_diff` 2 args | TC-DSL-09-23 | unit |
| Wrong argument count — `date_diff` 4 args | TC-DSL-09-24 | unit |
| Overflow — multiplier overflow | TC-DSL-09-25 | unit |
| Overflow — result clamp to maxInt | TC-DSL-09-26 | unit |
| Overflow — result clamp to minInt | TC-DSL-09-27 | unit |
| Overflow — `date_diff` diff overflow | TC-DSL-09-28 | unit |

**Total: 28 test cases covering all 10 categories**

---

## Test Cases

### Category 1: `now()` returns platform's current time

### TC-DSL-09-01: now() returns a timestamp in plausible range
**Given:** The expression `now()` is evaluated
**When:** The result is obtained as a `Value`
**Then:** The result type MUST be `.ts_val` and the i64 payload MUST be > 1_000_000_000_000 (corresponding to ~2001) and < 100_000_000_000_000 (corresponding to ~5138, a generous upper bound)
**Layer:** unit
**Acceptance criterion mapped:** `now()` returns platform's current time (positive, large ms-since-epoch value)

---

### Category 2: `date_add(ts, n, unit)` — each supported unit

### TC-DSL-09-02: date_add — second unit
**Given:** `date_add(0, 5, "second")`
**When:** Evaluated
**Then:** Returns `ts_val == 5000` (5 × 1000 ms)
**Layer:** unit
**Acceptance criterion mapped:** `date_add` supports `"second"` unit

### TC-DSL-09-03: date_add — minute unit
**Given:** `date_add(0, 3, "minute")`
**When:** Evaluated
**Then:** Returns `ts_val == 180000` (3 × 60 × 1000 ms)
**Layer:** unit
**Acceptance criterion mapped:** `date_add` supports `"minute"` unit

### TC-DSL-09-04: date_add — hour unit
**Given:** `date_add(1_000_000, 2, "hour")`
**When:** Evaluated
**Then:** Returns `ts_val == 1_000_000 + 7_200_000` (1_000_000 + 2 × 3_600_000 ms)
**Layer:** unit
**Acceptance criterion mapped:** `date_add` supports `"hour"` unit

### TC-DSL-09-05: date_add — day unit
**Given:** `date_add(0, 1, "day")`
**When:** Evaluated
**Then:** Returns `ts_val == 86_400_000` (1 × 24 × 60 × 60 × 1000 ms)
**Layer:** unit
**Acceptance criterion mapped:** `date_add` supports `"day"` unit

---

### Category 3: `date_diff(ts1, ts2, unit)` — each supported unit

### TC-DSL-09-06: date_diff — second unit
**Given:** `date_diff(5000, 1000, "second")`
**When:** Evaluated
**Then:** Returns `int_val == 4` ((5000 - 1000) / 1000 = 4)
**Layer:** unit
**Acceptance criterion mapped:** `date_diff` supports `"second"` unit with truncation toward zero

### TC-DSL-09-07: date_diff — minute unit
**Given:** `date_diff(300_000, 0, "minute")`
**When:** Evaluated
**Then:** Returns `int_val == 5` (300_000 / 60_000 = 5)
**Layer:** unit
**Acceptance criterion mapped:** `date_diff` supports `"minute"` unit

### TC-DSL-09-08: date_diff — hour unit
**Given:** `date_diff(14_400_000, 0, "hour")`
**When:** Evaluated
**Then:** Returns `int_val == 4` (14_400_000 / 3_600_000 = 4)
**Layer:** unit
**Acceptance criterion mapped:** `date_diff` supports `"hour"` unit

### TC-DSL-09-09: date_diff — day unit
**Given:** `date_diff(259_200_000, 0, "day")`
**When:** Evaluated
**Then:** Returns `int_val == 3` (259_200_000 / 86_400_000 = 3)
**Layer:** unit
**Acceptance criterion mapped:** `date_diff` supports `"day"` unit

---

### Category 4: Null propagation — any null argument returns null

### TC-DSL-09-10: date_add null propagation — ts argument
**Given:** `date_add(null, 1, "day")`
**When:** Evaluated
**Then:** Returns `null_val` without raising `EvalError`
**Layer:** unit
**Acceptance criterion mapped:** Null propagates through date_add first argument

### TC-DSL-09-11: date_add null propagation — n argument
**Given:** `date_add(0, null, "day")`
**When:** Evaluated
**Then:** Returns `null_val` without raising `EvalError`
**Layer:** unit
**Acceptance criterion mapped:** Null propagates through date_add second argument

### TC-DSL-09-12: date_add null propagation — unit argument
**Given:** `date_add(0, 1, null)`
**When:** Evaluated
**Then:** Returns `null_val` without raising `EvalError`
**Layer:** unit
**Acceptance criterion mapped:** Null propagates through date_add third argument

### TC-DSL-09-13: date_diff null propagation — ts1 argument
**Given:** `date_diff(null, 0, "second")`
**When:** Evaluated
**Then:** Returns `null_val` without raising `EvalError`
**Layer:** unit
**Acceptance criterion mapped:** Null propagates through date_diff first argument

### TC-DSL-09-14: date_diff null propagation — ts2 argument
**Given:** `date_diff(0, null, "second")`
**When:** Evaluated
**Then:** Returns `null_val` without raising `EvalError`
**Layer:** unit
**Acceptance criterion mapped:** Null propagates through date_diff second argument

### TC-DSL-09-15: date_diff null propagation — unit argument
**Given:** `date_diff(0, 0, null)`
**When:** Evaluated
**Then:** Returns `null_val` without raising `EvalError`
**Layer:** unit
**Acceptance criterion mapped:** Null propagates through date_diff third argument

---

### Category 5: Unknown unit returns evaluation error

### TC-DSL-09-16: unknown unit string returns EvalError
**Given:** `date_add(0, 1, "month")` or `date_diff(0, 0, "fortnight")`
**When:** Evaluated
**Then:** Returns an `EvalError` with a message indicating supported units (second, minute, hour, day)
**Layer:** unit
**Acceptance criterion mapped:** Unknown unit identifier produces evaluation error

---

### Category 6: Cross-DST boundary test

### TC-DSL-09-17: date_add across US DST spring-forward boundary — pure UTC arithmetic
**Given:** The timestamp `1772935140000` ms since epoch (2026-03-08T01:59:00Z — one minute before US DST spring-forward at 2026-03-08T02:00:00 local in US Eastern timezone)
**When:** `date_add(1772935140000, 1, "day")` is evaluated
**Then:** Returns `ts_val == 1773021540000` (1772935140000 + 86_400_000), which corresponds to 2026-03-09T01:59:00Z — exactly 86400000 ms later with no calendar adjustment
**Layer:** unit
**Acceptance criterion mapped:** Cross-DST boundary test confirms UTC-only arithmetic (day = exactly 86400000 ms regardless of DST transitions)

---

### Category 7: Negative n values for date_add

### TC-DSL-09-18: date_add with negative offset
**Given:** `date_add(5000, -3, "hour")`
**When:** Evaluated
**Then:** Returns `ts_val == 5000 - 10_800_000` (5_000 + (-3 × 3_600_000)) = `-10_795_000`
**Layer:** unit
**Acceptance criterion mapped:** `date_add` accepts negative `n` values

---

### Category 8: Negative diff for date_diff (ts1 < ts2)

### TC-DSL-09-19: date_diff with ts1 < ts2 returns negative value
**Given:** `date_diff(1000, 5000, "second")`
**When:** Evaluated
**Then:** Returns `int_val == -4` ((1000 - 5000) / 1000 = -4, truncated toward zero)
**Layer:** unit
**Acceptance criterion mapped:** `date_diff` returns negative result when ts1 < ts2

---

### Category 9: Wrong argument count returns evaluation error

### TC-DSL-09-20: now() with arguments returns EvalError
**Given:** `now(1)` or any call to `now()` with arguments
**When:** Evaluated
**Then:** Returns an `EvalError` with message indicating `now()` takes 0 arguments
**Layer:** unit
**Acceptance criterion mapped:** Wrong argument count for `now()` produces error

### TC-DSL-09-21: date_add with 2 arguments returns EvalError
**Given:** `date_add(0, 1)` (missing unit argument)
**When:** Evaluated
**Then:** Returns an `EvalError` with message indicating `date_add()` takes 3 arguments
**Layer:** unit
**Acceptance criterion mapped:** Wrong argument count for `date_add()` (too few) produces error

### TC-DSL-09-22: date_add with 4 arguments returns EvalError
**Given:** `date_add(0, 1, "day", 2)` (extra argument)
**When:** Evaluated
**Then:** Returns an `EvalError` with message indicating `date_add()` takes 3 arguments
**Layer:** unit
**Acceptance criterion mapped:** Wrong argument count for `date_add()` (too many) produces error

### TC-DSL-09-23: date_diff with 2 arguments returns EvalError
**Given:** `date_diff(0, 1)` (missing unit argument)
**When:** Evaluated
**Then:** Returns an `EvalError` with message indicating `date_diff()` takes 3 arguments
**Layer:** unit
**Acceptance criterion mapped:** Wrong argument count for `date_diff()` (too few) produces error

### TC-DSL-09-24: date_diff with 4 arguments returns EvalError
**Given:** `date_diff(0, 1, "day", 2)` (extra argument)
**When:** Evaluated
**Then:** Returns an `EvalError` with message indicating `date_diff()` takes 3 arguments
**Layer:** unit
**Acceptance criterion mapped:** Wrong argument count for `date_diff()` (too many) produces error

---

### Category 10: Arithmetic overflow handling (extreme values)

### TC-DSL-09-25: date_add multiplier overflow returns EvalError
**Given:** `date_add(0, std.math.maxInt(i64), "day")` — where `n * day_multiplier` overflows `i64`
**When:** Evaluated
**Then:** Returns an `EvalError` because the multiplication `n * unit_multiplier` overflows
**Layer:** unit
**Acceptance criterion mapped:** Overflow in `n * multiplier` produces `EvalError` (not a silent wrap)

### TC-DSL-09-26: date_add result saturates to maxInt for positive overflow
**Given:** `date_add(std.math.maxInt(i64) - 1, 2, "day")` — where `ts + delta` overflows `i64` in the positive direction
**When:** Evaluated
**Then:** Returns `ts_val == std.math.maxInt(i64)` (clamped, not error)
**Layer:** unit
**Acceptance criterion mapped:** Positive arithmetic overflow clamps to `maxInt(i64)`

### TC-DSL-09-27: date_add result saturates to minInt for negative overflow
**Given:** `date_add(std.math.minInt(i64) + 1, -2, "day")` — where `ts + delta` overflows `i64` in the negative direction
**When:** Evaluated
**Then:** Returns `ts_val == std.math.minInt(i64)` (clamped, not error)
**Layer:** unit
**Acceptance criterion mapped:** Negative arithmetic overflow clamps to `minInt(i64)`

### TC-DSL-09-28: date_diff diff overflow returns EvalError
**Given:** `date_diff(std.math.maxInt(i64), std.math.minInt(i64), "second")` — where `ts1 - ts2` overflows `i64`
**When:** Evaluated
**Then:** Returns an `EvalError` because the difference computation overflows
**Layer:** unit
**Acceptance criterion mapped:** Overflow in `date_diff` subtraction produces `EvalError`
