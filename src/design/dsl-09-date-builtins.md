# Module: Date Built-ins (DSL-09)

## Module Purpose

This module defines three date/time built-in functions available in the Expression DSL:
`now()`, `date_add(ts, n, unit)`, and `date_diff(ts1, ts2, unit)`. These functions
provide UTC-only millisecond-precision timestamp arithmetic for use in gateway
conditions, timer expressions, and process-level variable transformations.

All time values are represented as `i64` milliseconds since the Unix epoch
(1970-01-01T00:00:00Z). There is no calendar-aware date type; day arithmetic
is pure millisecond arithmetic.

---

## Public Interface

### `now()`

```zig
fn now() -> Value.ts_val(i64)
```

Returns the platform's current wall-clock time as UTC milliseconds since Unix
epoch. The value is obtained from the OS system clock (`RtlGetSystemTimePrecise`
on Windows, `clock_gettime(CLOCK_REALTIME)` on POSIX).

**Arity:** 0 arguments. Any call with arguments produces an `EvalError`.

**Impurity:** `now()` is the **only impure built-in** in the DSL. Its return
value depends on the wall-clock time at the moment of evaluation. This has two
practical consequences:
- Repeated calls within the same evaluation may return different values
  (wall-clock advances between calls — though typically imperceptible).
- In simulation/testing contexts, the platform **must** inject a fixed time
  rather than calling OS system time (see SCH-02, SIM-01).

**Return type:** Always `timestamp` (`.ts_val`). Never returns `null`.

---

### `date_add(ts, n, unit)`

```zig
fn date_add(ts: Value {timestamp | int64}, n: Value.int_val(i64), unit: Value.str_val(string))
  -> Value {ts_val(i64) | null_val | EvalError}
```

Adds `n` units to timestamp `ts` and returns the resulting timestamp.

**Arity:** Exactly 3 arguments. Any other count produces an `EvalError`.

**Return type:** `timestamp` (`.ts_val`) on success; `null` if any argument is
`null` (see §Null Propagation); `EvalError` on type mismatch or overflow.

**Pure:** Given explicit inputs, `date_add` is a pure function. The same
`(ts, n, unit)` triple always produces the same result.

**Overflow semantics (saturating):**
- If `n * multiplier` overflows `i64`, the function returns an `EvalError`.
- If the final addition `ts_ms + delta` overflows `i64`, the function **clamps**
  to `std.math.maxInt(i64)` for positive delta and `std.math.minInt(i64)` for
  negative delta — it does not propagate the error. This ensures that extremely
  large offsets produce a deterministic boundary value rather than a runtime
  panic.

---

### `date_diff(ts1, ts2, unit)`

```zig
fn date_diff(ts1: Value {timestamp | int64}, ts2: Value {timestamp | int64}, unit: Value.str_val(string))
  -> Value {int_val(i64) | null_val | EvalError}
```

Returns `(ts1 - ts2)` expressed in the given `unit`, truncated toward zero
(`@divTrunc` integer division).

**Arity:** Exactly 3 arguments. Any other count produces an `EvalError`.

**Return type:** `int64` (`.int_val`) on success; `null` if any argument is
`null` (see §Null Propagation); `EvalError` on type mismatch or overflow.

**Pure:** Yes. Given explicit inputs, `date_diff` is a pure function.

**Overflow semantics:**
- If `ts1_ms - ts2_ms` overflows `i64`, the function returns an `EvalError`.
  (This can only happen when the timestamps are of opposite sign and far apart,
  which is exceedingly rare for realistic dates.)
- Once the difference is computed, `@divTrunc(diff_ms, multiplier)` is used for
  unit conversion. This truncates toward zero, so a 3661000 ms difference with
  unit `"second"` yields `3661`, not `3662`.

---

## Unit Support

Four string unit identifiers are supported, each mapping to a fixed millisecond
multiplier:

| Unit       | Milliseconds | Definition                    |
|------------|--------------|-------------------------------|
| `"second"` | 1,000        | 1000 ms                       |
| `"minute"` | 60,000       | 60 × 1000                     |
| `"hour"`   | 3,600,000    | 60 × 60 × 1000                |
| `"day"`    | 86,400,000   | 24 × 60 × 60 × 1000           |

The multiplier is computed as integer multiplication at compile time in Zig;
no runtime conversion cost.

Any string value that does not exactly match one of these four identifiers
produces an `EvalError` with message indicating the supported values.

---

## UTC-Only Constraint

All timestamp arithmetic operates exclusively in UTC milliseconds since the
Unix epoch. This imposes the following design invariants:

1. **No timezone conversion.** There is no timezone-aware date type, no
   `tz` parameter, no implicit conversion from local time. The platform
   never consults the IANA timezone database.

2. **Input format.** Callers are responsible for converting wall-clock
   timestamps to UTC milliseconds before passing them to any DSL built-in.
   The platform's event store timestamps (`created_at`) are already UTC;
   variables populated from events are therefore UTC by construction.

3. **Output format.** Returned timestamps from `now()` and `date_add()` are
   UTC milliseconds. Callers who need a human-readable representation or a
   different timezone must convert externally.

4. **No calendar awareness.** The platform does not know about months, years,
   leap years, or leap seconds. All date arithmetic is linear millisecond
   arithmetic (see §Cross-DST Boundary Semantics).

---

## Null Propagation Rules

All three date built-ins follow the same null propagation rule:

> If any evaluated argument is `null_val`, the function immediately returns
> `null_val` without performing any computation or raising an error.

This applies uniformly:

```
now()                     → NEVER returns null (no arguments to be null)
date_add(null, 1, "day")  → null
date_add(ts, null, "day") → null
date_add(ts, 1, null)     → null
date_diff(null, ts, "h")  → null
date_diff(ts, null, "h")  → null
date_diff(ts1, ts2, null) → null
```

Null propagation occurs **before** type checking: if an argument is null, its
type is not validated. This is consistent with DSL-05 null-coercion rules
elsewhere in the evaluator.

---

## Type Coercions

### Timestamp arguments (first arg of `date_add`, first two args of `date_diff`)

Accept either:
- `Value.ts_val(i64)` — a typed timestamp value.
- `Value.int_val(i64)` — a raw integer; treated as UTC milliseconds.

If any timestamp-position argument is of any other type (`.bool_val`,
`.float_val`, `.str_val`), the function returns an `EvalError`.

Rationale: `int_val` is accepted so that arithmetic results and variable lookups
that resolve to integers can be used directly as timestamps without an explicit
cast.

### `n` argument (`date_add` second argument)

Must be `Value.int_val(i64)`. Any other type (including `.float_val`) produces
an `EvalError`.

### `unit` argument (third argument of both functions)

Must be `Value.str_val([]const u8)`. Any other type produces an `EvalError`.

The string value must be one of the four supported unit identifiers (case-
sensitive, lowercase). An unknown unit string produces an `EvalError`.

---

## Error Taxonomy

All errors are returned as `EvalError` with a descriptive `message` string.

| Error Condition                    | Function(s)        | Message Pattern                                          |
|------------------------------------|--------------------|----------------------------------------------------------|
| Wrong argument count               | `now()`, `date_add`, `date_diff` | `"now() takes 0 arguments"` / `"date_add() takes 3 arguments"` / `"date_diff() takes 3 arguments"` |
| Timestamp arg wrong type           | `date_add`, `date_diff` | `"date_add(): first argument must be timestamp or integer"` |
| `n` arg wrong type                 | `date_add`         | `"date_add(): second argument must be integer"`          |
| First two args wrong type          | `date_diff`        | `"date_diff(): first two arguments must be timestamps or integers"` |
| Unit arg wrong type                | `date_add`, `date_diff` | `"date_add(): third argument must be string (unit)"` / `"date_diff(): third argument must be string (unit)"` |
| Unknown unit string                | `date_add`, `date_diff` | `"date_add(): unknown unit, use: second, minute, hour, day"` |
| Multiplicative overflow (`n * multiplier`) | `date_add` | `"date_add(): arithmetic overflow"`                     |
| Subtractive overflow (`ts1 - ts2`) | `date_diff`        | `"date_diff(): arithmetic overflow"`                     |

**Note:** Additive overflow in `date_add` (`ts_ms + delta`) is **not** an error;
it saturates silently (see §Public Interface above).

---

## Cross-DST Boundary Semantics

Because all time arithmetic is pure UTC millisecond arithmetic, crossing a DST
transition has no effect on the computed result. Specifically:

```
# March 14, 2027 00:00:00 UTC → 1771027200000 ms
# Adding 1 "day" always adds exactly 86,400,000 ms:
date_add(1771027200000, 1, "day") → 1771113600000
# March 15, 2027 00:00:00 UTC — guaranteed.
```

This holds regardless of whether any timezone observes DST on that night, and
regardless of whether the caller's local clock springs forward or falls back.

**Day = 86,400,000 ms, invariant.** There is no concept of "calendar day,"
"business day," or "DST-adjusted day." Cross-DST boundary tests must use UTC
timestamps from opposite sides of a known DST transition date and verify that
the millisecond delta is exactly 86,400,000 per day.

---

## Impurity Note

```
now()       ← IMPURE: depends on OS wall clock at call time
date_add()  ← PURE: deterministic given (ts, n, unit)
date_diff() ← PURE: deterministic given (ts1, ts2, unit)
```

`now()` is the only impure function among the three date built-ins and, in fact,
the only impure function in the entire built-in whitelist (DSL-07). All other
built-ins (string functions, coalesce, date_add, date_diff) are pure functions
of their explicit arguments.

**Practical implications:**

1. **Caching safe for date_add/date_diff.** The evaluator may cache results of
   `date_add` and `date_diff` calls if the same `(ts, n, unit)` triple is
   encountered in multiple places within the same expression.

2. **`now()` must be re-evaluated each call.** The evaluator must not cache or
   hoist `now()` calls. Each invocation reads the system clock afresh.

3. **Simulation override.** When the platform runs in simulation mode (SCH-02),
   `now()` must return the injected simulation time rather than OS wall clock
   time. `date_add` and `date_diff` are unaffected — they work on whatever
   timestamps they receive, real or simulated.

4. **Testability.** `now()` is the only date built-in that requires mocking
   (via simulation time injection). `date_add` and `date_diff` are trivially
   testable with hardcoded `i64` inputs.

---

## Dependencies

### Calls / depends on
- **`builtin` module** (Zig compiler builtin) — for OS detection (`builtin.os.tag`).
- **`std.os.windows.ntdll.RtlGetSystemTimePrecise`** — Windows system time source.
- **`std.posix.system.clock_gettime`** — POSIX system time source.
- **`std.math.mul`** — checked multiplication for `n * multiplier`.
- **`std.math.add`** — checked addition for `ts_ms + delta`.
- **`std.math.sub`** — checked subtraction for `ts1_ms - ts2_ms`.
- **`std.math.maxInt` / `std.math.minInt`** — saturation boundaries.

### Must not depend on
- **IANA timezone database** — no `local time`, no `chrono`, no tz lookups.
- **Calendar libraries** — no month/year/leap-year calculations.
- **Database** — no `pg.zig` dependency; all functions are pure (or in the case
  of `now()`, OS-syscall-only).
- **Allocator** (except transitively through expression evaluation) — date
  built-ins operate on `i64` scalars only, no heap allocations.

---

## Open Questions

None. DSL-09 is fully specified in the requirements document and the
implementation already exists in `src/expr/mod.zig`.
