# Test Spec: DSL-13 — Expression Evaluation Performance Benchmark

**Requirement:** DSL-13 — Performance target: typical expression (5–10 AST nodes) SHOULD evaluate in less than 10 microseconds. The benchmark validates that cached expression evaluation meets this latency target and detects performance regressions across all expression profiles.

**Priority:** MUST  
**Test layer:** integration  
**Build target:** `zig build bench`

---

## Test Strategy

DSL-13 testing is implemented as an integrated benchmark suite that measures end-to-end expression evaluation latency from cached, pre-parsed `ParsedExpr` objects. Unlike unit tests, this benchmark:

1. **Measures real performance** — not mocking or stubbing, but evaluating expressions against realistic context data
2. **Validates the 10 µs target** — ensures typical expressions (7–9 AST nodes) meet the performance requirement
3. **Detects regressions** — compares current results against baseline and flags performance degradation
4. **Collects detailed metrics** — captures distribution (p95, p99) and statistical measures (stddev)

**Test environment:** Integrated benchmark that runs via `zig build bench` in `ReleaseFast` mode. Requires:
- Zig build system
- Expression evaluation engine (`src/expr/`)
- Real parser and evaluator (no mocks)

**Key design invariants verified:**
- Warm-up strategy stabilizes CPU cache and branch prediction (1,000 iterations, untimed)
- Measurement window is precise: only `expr.evaluate()` call latency; parsing and allocator setup excluded
- Statistical rigor: 10,000 measured evaluations per profile enable confident p95/p99 reporting
- All 6 profiles are evaluated successfully without crashes
- Mean latencies stay within target (≤10.0 µs) for all profiles
- Profile 4 and 5 (typical expressions, 7–9 nodes) keep p99 latency ≤10.0 µs or flag as warning
- Throughput is calculated from mean latency (throughput = 1,000,000 µs / mean_us)

---

## Test Coverage

The benchmark validates 6 distinct expression profiles, each targeting a specific AST complexity and execution path:

| Profile | Name | Nodes | Example | Purpose |
|---------|------|-------|---------|---------|
| 1 | Trivial | 1 | `42` | Baseline: single literal, minimal overhead |
| 2 | Scalar lookup | 1 | `order_total` | Variable context lookup cost |
| 3 | Simple comparison | 3 | `order_total > 1000` | Binary operator + type coercion |
| 4 | Nested logic | 7 | `order_total > 1000 and customer_status == "VIP"` | Short-circuit AND/OR, multiple comparisons |
| 5 | Complex nested | 9 | `order.customer.address.country == "US" and order.total > 100` | Multi-segment dot-path + JSON parsing |
| 6 | Built-in function | 5 | `lower(category) == "electronics"` | Function dispatch + string operation |

**Typical expressions:** Profiles 4 and 5 (7–9 nodes) represent typical real-world expressions. These must meet the 10 µs target reliably (mean ≤10 µs, p99 ≤10 µs or flagged as warning).

---

## Test Profiles Detail

### Profile 1: Trivial (1 AST node)

**Name:** `trivial`

**Expression:** `42` (numeric literal)

**AST structure:** Single literal node (no operators, no context lookups)

**Purpose:** Measure baseline overhead — timer accuracy, function call overhead, return path.

**Expected latency target:** < 0.5 µs (literal evaluation is O(1))

**Context:** Empty (no variables needed)

---

### Profile 2: Scalar Variable Lookup (1 AST node)

**Name:** `scalar_lookup`

**Expression:** `order_total`

**AST structure:** Single-segment dot-path (identifier lookup in context map)

**Purpose:** Measure context hash-table lookup cost.

**Expected latency target:** < 1 µs (hash table lookup + value return)

**Context:**
```json
{
  "order_total": 1500,
  "customer_name": "Alice",
  "is_approved": true
}
```

---

### Profile 3: Simple Comparison (3 AST nodes)

**Name:** `simple_comparison`

**Expression:** `order_total > 1000`

**AST structure:** Binary comparison operator with two leaf nodes (dot-path + literal)

**Purpose:** Measure the cost of comparison operations and type coercion.

**Expected latency target:** < 2 µs (two lookups + comparison + coercion)

**Context:**
```json
{
  "order_total": 1500,
  "customer_age": 45,
  "is_approved": true,
  "amount": 250
}
```

---

### Profile 4: Nested Logic (7 AST nodes) — TYPICAL EXPRESSION

**Name:** `nested_logic`

**Expression:** `order_total > 1000 and customer_status == "VIP"`

**AST structure:**
```
            and_expr
           /        \
      cmp_expr      cmp_expr
      /    \        /      \
  dot_path  lit   dot_path  lit
  ["total"] 1000  ["status"] "VIP"
```

**Purpose:** Measure short-circuit evaluation (DSL-05 logical AND/OR), multiple comparisons, boolean coercion.

**Expected latency target:** < 4 µs (multiple lookups + comparisons + short-circuit logic)

**Context:**
```json
{
  "order_total": 1500,
  "customer_status": "VIP",
  "amount": 50,
  "is_urgent": false,
  "approval_required": true
}
```

**MUST Acceptance Criterion:** Mean latency ≤ 10.0 µs; ideally p99 ≤ 10.0 µs (warning if exceeded)

---

### Profile 5: Complex Nested (9 AST nodes) — TYPICAL EXPRESSION

**Name:** `complex_nested`

**Expression:** `order.customer.address.country == "US" and order.total > 100`

**AST structure:**
```
                    and_expr
                   /        \
              cmp_expr      cmp_expr
              /    \        /      \
        dot_path   lit   dot_path   lit
        ["order"   "US"  ["order"   100
         "customer"        "total"]
         "address"
         "country"]
```

**Purpose:** Measure multi-segment dot-path traversal with JSON parsing (DSL-11). This is the primary cost driver in realistic expressions.

**Expected latency target:** < 10 µs (JSON parsing per segment + context lookups + comparisons + coercion)

**Context:**
```json
{
  "order": "{\"customer\":{\"address\":{\"country\":\"US\"}},\"total\":1500,\"items\":[{\"quantity\":3},{\"quantity\":2}]}",
  "customer": "{\"profile\":{\"age\":35}}"
}
```

**MUST Acceptance Criterion:** Mean latency ≤ 10.0 µs; if p99 exceeds 10.0 µs, flag as warning (JSON parsing overhead is expected)

---

### Profile 6: Built-in Function (5 AST nodes)

**Name:** `builtin_function`

**Expression:** `lower(category) == "electronics"`

**AST structure:**
```
           cmp_expr (==)
          /              \
      func_call          lit
      name: "lower"      "electronics"
      args: [dot_path]
            ["category"]
```

**Purpose:** Measure built-in function invocation cost (string operations, coalescing, etc.).

**Expected latency target:** < 5 µs (function dispatch + string operation + comparison)

**Context:**
```json
{
  "product_name": "Widget Pro",
  "category": "Electronics",
  "description": "High quality with warranty",
  "nickname": null,
  "full_name": "John Doe"
}
```

---

## Test Execution Methodology

### Warm-up Phase

Before measurement begins, the benchmark runs 1,000 untimed warm-up iterations per profile:

**Purpose:**
- Warm CPU instruction cache and data cache
- Stabilize branch prediction
- Allow JIT compiler (if any) to optimize hot paths
- Achieve steady-state memory access patterns

**Execution:**
1. For each of the 1,000 warm-up iterations:
   - Invoke `expr.evaluate(parsed_expr, &context, allocator)`
   - Do NOT measure time
   - Do NOT collect latency values
2. After warm-up, CPU cache and predictor state is stabilized for measurement

---

### Measurement Phase

After warm-up, the benchmark performs 10,000 timed evaluations per profile:

**Execution per iteration:**
1. Capture start time: `start_ns = std.time.nanoTimestamp()`
2. Invoke `expr.evaluate(parsed_expr, &context, allocator)`
3. Capture end time: `end_ns = std.time.nanoTimestamp()`
4. Compute elapsed nanoseconds: `elapsed_ns = end_ns - start_ns`
5. Convert to microseconds: `elapsed_us = elapsed_ns / 1000`
6. Append to latencies array: `latencies.push(elapsed_us)`

**Timing precision:**
- Use `std.time.nanoTimestamp()` for nanosecond-precision wall-clock timing
- Timer overhead (~50–200 ns on modern systems) is <1% of 10 µs target; negligible impact
- Convert to microseconds via integer division to preserve precision

**Allocation handling:**
- Reset scratch allocator between iterations (64 KB fixed buffer per iteration)
- Allocator reset is performed OUTSIDE the timing window
- This ensures allocator overhead does not inflate latency measurements

---

### Metrics Collection and Computation

After all 10,000 measured iterations, compute statistics from the latencies array:

#### Latency Metrics (unit: microseconds)

| Metric | Definition | Computation |
|--------|-----------|-------------|
| **min_us** | Minimum latency | `min(latencies)` |
| **max_us** | Maximum latency | `max(latencies)` |
| **mean_us** | Arithmetic mean | `sum(latencies) / count` |
| **median_us** | 50th percentile (p50) | Sort and take middle value(s) |
| **p95_us** | 95th percentile | 95th percentile of sorted latencies |
| **p99_us** | 99th percentile | 99th percentile of sorted latencies |
| **stddev_us** | Standard deviation | `sqrt(sum((x - mean)^2) / count)` |
| **throughput_per_sec** | Evaluations per second | `1,000,000 / mean_us` |

#### Target Validation

For each profile:

1. **Mean target:** `mean_us ≤ 10.0`
   - PASS if true
   - FAIL if false

2. **P99 target (Profiles 4–5 only):** `p99_us ≤ 10.0`
   - PASS if true
   - WARN if false (typical expressions exceeding p99 limit is a warning, not failure)
   - FAIL if mean > 10.0 µs (supersedes p99 warning)

3. **Headroom calculation:**
   ```
   headroom_pct = (10.0 - mean_us) / 10.0 × 100
   ```
   - Positive: percentage of buffer remaining to target
   - Negative: percentage over target (FAIL condition)

---

## Success Criteria (Acceptance)

The benchmark is considered PASS if and only if:

1. **All profiles evaluate successfully** — no crashes, panics, assertion failures, or hung processes

2. **Mean latency target met:**
   - All 6 profiles: `mean_us ≤ 10.0 µs` (MUST)

3. **P99 target for typical expressions:**
   - Profiles 4 and 5 (7–9 nodes): `p99_us ≤ 10.0 µs` is ideal
   - If Profile 4 or 5 exceeds p99 ≤ 10 µs: Flag as WARN (not FAIL), document in report
   - JSON parsing overhead on Profile 5 may cause p99 to approach or slightly exceed 10 µs; this is acceptable if mean ≤ 10 µs

4. **Benchmark execution constraints:**
   - Warm-up iterations: 1,000 per profile (completes within 1–2 seconds per profile)
   - Measurement iterations: 10,000 per profile (completes within 5–10 seconds per profile)
   - Total benchmark time: All 6 profiles complete within 30 seconds (wall clock)
   - Exit code: 0 (success) or 1 (any profile failed)

5. **Statistical rigor:**
   - 10,000 samples per profile provide ≥99.7% confidence in percentile estimates
   - Results are reproducible: running benchmark twice on same hardware yields ±5% variance

---

## Expected Output Format

### JSON Report

The benchmark writes a JSON report to `docs/metrics/benchmark_results.json` with the following structure:

```json
{
  "metadata": {
    "timestamp": "2026-05-28T10:30:45Z",
    "platform": "Linux x86_64" or "Windows x86_64" or "macOS arm64",
    "cpu": "CPU model (if available)",
    "compiler": "zig 0.12.0",
    "build_mode": "ReleaseFast",
    "iterations_per_profile": 10000,
    "warmup_iterations": 1000
  },
  "profiles": [
    {
      "name": "trivial",
      "description": "Single literal node",
      "ast_node_count": 1,
      "example_expressions": ["42", "\"hello\"", "true"],
      "statistics": {
        "min_us": 0.05,
        "max_us": 0.5,
        "mean_us": 0.12,
        "median_us": 0.11,
        "p95_us": 0.18,
        "p99_us": 0.22,
        "stddev_us": 0.08,
        "throughput_per_sec": 8333333
      },
      "target": {
        "threshold_us": 10.0,
        "mean_meets_target": true,
        "p99_meets_target": true,
        "headroom_pct": 97.8
      }
    },
    {
      "name": "scalar_lookup",
      "description": "Single context variable reference",
      "ast_node_count": 1,
      "example_expressions": ["order_total", "customer_name"],
      "statistics": {
        "min_us": 0.3,
        "max_us": 1.2,
        "mean_us": 0.5,
        "median_us": 0.48,
        "p95_us": 0.8,
        "p99_us": 1.0,
        "stddev_us": 0.12,
        "throughput_per_sec": 2000000
      },
      "target": {
        "threshold_us": 10.0,
        "mean_meets_target": true,
        "p99_meets_target": true,
        "headroom_pct": 95.0
      }
    },
    {
      "name": "simple_comparison",
      "description": "Binary comparison operator",
      "ast_node_count": 3,
      "example_expressions": ["order_total > 1000", "customer_age < 65"],
      "statistics": {
        "min_us": 1.0,
        "max_us": 2.8,
        "mean_us": 1.5,
        "median_us": 1.48,
        "p95_us": 2.0,
        "p99_us": 2.5,
        "stddev_us": 0.25,
        "throughput_per_sec": 666667
      },
      "target": {
        "threshold_us": 10.0,
        "mean_meets_target": true,
        "p99_meets_target": true,
        "headroom_pct": 85.0
      }
    },
    {
      "name": "nested_logic",
      "description": "Multiple comparisons with AND/OR logic (7 nodes)",
      "ast_node_count": 7,
      "example_expressions": ["order_total > 1000 and customer_status == \"VIP\""],
      "statistics": {
        "min_us": 2.5,
        "max_us": 5.5,
        "mean_us": 3.0,
        "median_us": 2.95,
        "p95_us": 4.0,
        "p99_us": 5.0,
        "stddev_us": 0.35,
        "throughput_per_sec": 333333
      },
      "target": {
        "threshold_us": 10.0,
        "mean_meets_target": true,
        "p99_meets_target": true,
        "headroom_pct": 70.0
      }
    },
    {
      "name": "complex_nested",
      "description": "Multi-segment dot-path with JSON parsing (9 nodes)",
      "ast_node_count": 9,
      "example_expressions": ["order.customer.address.country == \"US\" and order.total > 100"],
      "statistics": {
        "min_us": 7.2,
        "max_us": 12.5,
        "mean_us": 8.5,
        "median_us": 8.3,
        "p95_us": 9.8,
        "p99_us": 10.2,
        "stddev_us": 0.9,
        "throughput_per_sec": 117647
      },
      "target": {
        "threshold_us": 10.0,
        "mean_meets_target": true,
        "p99_meets_target": false,
        "p99_headroom_pct": -2.0,
        "warning": "p99 latency (10.2 µs) slightly exceeds 10 µs target; within acceptable tolerance for JSON parsing workload"
      }
    },
    {
      "name": "builtin_function",
      "description": "Function call with string operation",
      "ast_node_count": 5,
      "example_expressions": ["lower(category) == \"electronics\"", "length(name) > 0"],
      "statistics": {
        "min_us": 2.0,
        "max_us": 5.0,
        "mean_us": 2.5,
        "median_us": 2.45,
        "p95_us": 3.5,
        "p99_us": 4.5,
        "stddev_us": 0.3,
        "throughput_per_sec": 400000
      },
      "target": {
        "threshold_us": 10.0,
        "mean_meets_target": true,
        "p99_meets_target": true,
        "headroom_pct": 75.0
      }
    }
  ],
  "summary": {
    "profiles_passed": 5,
    "profiles_warned": 1,
    "profiles_failed": 0,
    "all_profiles_meet_mean_target": true,
    "overall_status": "PASS"
  }
}
```

### Human-Readable Summary

The benchmark prints a text summary to stdout in the following format:

```
DSL-13 Expression Evaluation Benchmark Report
=============================================

Timestamp: 2026-05-28 10:30:45 UTC
Platform: Linux x86_64 (Intel Core i7-8700K @ 3.7 GHz)
Build: zig build ReleaseFast
Iterations: 10,000 per profile (1,000 warm-up)

PROFILE RESULTS
───────────────────────────────────────────────────────────────────
Profile         Nodes  Mean(µs)  p95(µs)  p99(µs)  Status  Headroom
───────────────────────────────────────────────────────────────────
trivial           1      0.12      0.18     0.22   PASS    97.8%
scalar_lookup     1      0.50      0.80     1.00   PASS    95.0%
simple_comparison 3      1.50      2.00     2.50   PASS    85.0%
nested_logic      7      3.00      4.00     5.00   PASS    70.0%
complex_nested    9      8.50      9.80    10.20   WARN   -2.0%
builtin_function  5      2.50      3.50     4.50   PASS    75.0%
───────────────────────────────────────────────────────────────────

OVERALL RESULT: PASS (5 passed, 1 warned, 0 failed)

All mean latencies meet the 10 µs target.
Complex nested expressions approach the limit; monitor for regressions.

Detailed results: docs/metrics/benchmark_results.json
```

---

## Regression Detection Strategy

### Baseline Establishment

1. **First run:** After the first successful benchmark run, save results as baseline in `docs/metrics/bench_baseline.json`
2. **Baseline format:** Identical structure to JSON report, capturing mean, p99 for each profile

### Regression Detection

For each subsequent run:

1. **Compare current metrics against baseline:**
   - For each profile, compute regression indicators:
     - Mean increase: `(current_mean - baseline_mean) / baseline_mean × 100`
     - P99 increase: `(current_p99 - baseline_p99) / baseline_p99 × 100`

2. **Regression thresholds:**
   - Mean increase > 5%: Flag as potential regression (WARN)
   - Mean increase > 10%: Flag as definite regression (FAIL)
   - P99 increase > 15%: Flag as outlier spread increase (WARN)
   - Any profile crosses from PASS to FAIL: Definite regression (FAIL)

3. **Reporting:**
   - Append regression analysis to JSON report
   - Example:
     ```json
     "regression_analysis": {
       "baseline_file": "docs/metrics/bench_baseline.json",
       "baseline_timestamp": "2026-05-25T14:22:00Z",
       "regressions": [
         {
           "profile": "complex_nested",
           "baseline_mean_us": 7.8,
           "current_mean_us": 8.5,
           "regression_pct": 9.0,
           "status": "WARN"
         }
       ]
     }
     ```

---

## Edge Cases and Robustness

### Warm-up Behavior Validation

**Test:** Verify that warm-up iterations converge to steady-state latency

**Validation:**
- Compare latency of final warm-up iteration against first 10 measurement iterations
- Mean of final warm-up should be within ±10% of mean of first 10 measurements
- If divergence > 10%: Likely insufficient warm-up; investigate CPU state or system interference

### Type Coercion at Boundaries

**Test:** Simple comparison profile uses mixed numeric types

**Validation:**
- Expression `order_total > 1000` compares int64 against numeric literal
- Type coercion (DSL-05) is transparently applied during evaluation
- Confirm coercion overhead is within expected <2 µs for Profile 3

### Expressions with Nested Null/Undefined Values

**Test:** Complex nested profile context includes valid and invalid JSON paths

**Validation:**
- Null values in intermediate paths are handled gracefully (DSL-11)
- Evaluation does not crash or hang on malformed JSON
- Latency remains consistent regardless of null/missing fields

### System Interference Detection

**Monitors:**
- Max latency spikes (max_us > mean_us × 10): Indicates system interference (page faults, interrupts)
- Stddev > mean × 0.3: High variance suggests unstable CPU state or background load
- P99 > mean × 5: Outlier tail suggests occasional system contention

**Actions if detected:**
- Document in report metadata
- Recommend re-running on idle system
- Do not fail benchmark; note as environmental condition

---

## Test Failure Conditions

The benchmark FAILS if any of the following occur:

1. **Crash or panic:** Any profile evaluation panics, crashes, or hangs
   - Example: Segmentation fault, assertion failure, deadlock, timeout > 30 seconds

2. **Mean latency exceeds 10 µs:** Any profile's mean_us > 10.0
   - This is a hard failure; indicates evaluator performance is below target

3. **All profiles did not execute:** Fewer than 6 profiles completed benchmarking
   - Example: Benchmark loop exits early due to memory exhaustion or error

4. **Invalid statistics:** Any metric is NaN, Inf, or negative (logic error in computation)

5. **Exit code non-zero:** `zig build bench` returns exit code 1

### Acceptable Warnings (Not Failures)

1. **P99 exceeds 10 µs (Profiles 4–5 only):** If mean ≤ 10 µs, p99 slightly over (e.g., 10.2 µs) is acceptable
   - Flagged as WARN in report
   - Root cause: JSON parsing overhead on Profile 5
   - Acceptable because mean target is met; p99 overage is tail behavior

2. **High variance (stddev > mean × 0.3):** Indicates noisy environment but not a logic error
   - Flagged in report metadata
   - Recommend re-running on isolated system
   - Not a benchmark failure

3. **System interference detected (max > mean × 10):** Page faults or interrupts inflated latency tail
   - Noted in metadata
   - Not a benchmark failure (re-run on idle system)

---

## Test Execution (for TEST-RUNNER)

### Build and Execution

```bash
# Step 1: Build the benchmark
zig build bench

# Step 2: Capture exit code and output
BENCHMARK_EXIT_CODE=$?

# Step 3: Parse JSON results
jq '.summary' docs/metrics/benchmark_results.json

# Step 4: Report verdict
if [ $BENCHMARK_EXIT_CODE -eq 0 ] && [ "$(jq '.summary.overall_status' docs/metrics/benchmark_results.json)" = '"PASS"' ]; then
  echo "DSL-13 PASS"
  exit 0
else
  echo "DSL-13 FAIL"
  exit 1
fi
```

### Metrics Verification

After benchmark completes, TEST-RUNNER validates:

1. **File existence:** `docs/metrics/benchmark_results.json` exists and is valid JSON
2. **All 6 profiles present:** `profiles[]` array contains exactly 6 entries
3. **All metrics populated:** No missing fields in statistics
4. **Mean targets met:**
   ```
   For each profile:
     assert profile.statistics.mean_us <= 10.0
   ```
5. **Exit code:** `zig build bench` exits with 0

---

## Baseline Management

### Initial Baseline Creation

1. **First successful run:** Results automatically become baseline
2. **Location:** `docs/metrics/bench_baseline.json`
3. **Content:** Full JSON report snapshot for future regression comparisons

### Baseline Updates

- **Do NOT update baseline automatically** — manual review required
- **When to update:**
  - After performance optimization is committed and verified
  - After target machine change (e.g., CI runner upgrade)
  - After Zig compiler upgrade with known performance impact
  - As part of release validation (RELEASE-VALIDATOR decision)

- **Update procedure:**
  1. Review latest `docs/metrics/benchmark_results.json`
  2. Verify improvement/change is intentional and documented
  3. Copy results as new baseline: `cp docs/metrics/benchmark_results.json docs/metrics/bench_baseline.json`
  4. Commit baseline update with explanation in commit message

---

## Coverage Summary

| Profile | Type | Nodes | Measurement Focus |
|---------|------|-------|-------------------|
| Trivial | Baseline | 1 | Timer overhead + function call cost |
| Scalar lookup | Simple | 1 | Context map lookup cost |
| Simple comparison | Simple | 3 | Binary operator + coercion cost |
| Nested logic | Typical | 7 | Short-circuit logic + multiple comparisons |
| Complex nested | Typical | 9 | JSON parsing + dot-path traversal |
| Builtin function | Simple | 5 | Function dispatch + string operation |

**Total profiles:** 6  
**Total measurement iterations:** 60,000 (6 profiles × 10,000 iterations)  
**Total warm-up iterations:** 6,000 (6 profiles × 1,000 iterations)  
**Total expressions evaluated:** 66,000

---

## Key Test Assertions

All assertions below are automatically checked by the benchmark and reported:

1. ✓ Warm-up phase completes without error (1,000 iterations per profile)
2. ✓ Measurement phase collects 10,000 valid latency samples per profile
3. ✓ All latencies are positive and < 1 second (sanity check)
4. ✓ Mean latency ≤ 10.0 µs for all profiles (MUST)
5. ✓ P99 latency ≤ 10.0 µs for Profiles 4–5 or flagged WARN (MUST)
6. ✓ Standard deviation > 0 and < mean × 2 (sanity check)
7. ✓ Median between min and max (sanity check)
8. ✓ p95 and p99 are monotonically increasing (percentile ordering)
9. ✓ Throughput calculation is correct: 1,000,000 / mean_us (sanity check)
10. ✓ JSON report is well-formed and complete
11. ✓ Overall status is PASS (exit code 0) if no profiles failed
12. ✓ Overall status is FAIL (exit code 1) if any profile failed

---

## Summary

DSL-13 test spec defines a comprehensive performance benchmark that:

- **Measures** real expression evaluation latency via 10,000 iterations per profile
- **Profiles** 6 expression types spanning trivial (1 node) to complex (9 nodes)
- **Validates** compliance with 10 µs target for all profiles
- **Detects** performance regressions against baseline (mean increase >5%, p99 increase >15%)
- **Reports** results in both machine-parseable JSON and human-readable formats
- **Runs** under 30 seconds total (warm-up + measurement for all 6 profiles)
- **Enables** ongoing performance monitoring and optimization tracking

The benchmark is executed via `zig build bench` (ReleaseFast build mode) and validates that cached expression evaluation meets DSL-13 performance requirements across all typical and edge-case expression patterns.
