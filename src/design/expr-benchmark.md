# Module: expr-benchmark — Benchmark Suite for Expression Evaluation Performance

**Stage:** Stage 7 — Expression DSL  
**Requirement:** DSL-13 — Performance target  
**Depends on:**
- `src/design/dsl-12-engine-api.md` (ParsedExpr API, caching, evaluation)
- `src/design/expr.md` (AST structure, module layout)
- `src/design/dsl-11-dot-path.md` (nested traversal, JSON parsing)

**Status:** Final

---

## 1. Purpose

Define the comprehensive benchmark suite that measures and validates the DSL-13 performance target:

> A typical expression (5–10 nodes in AST) SHOULD evaluate in under 10 microseconds on commodity hardware.

The benchmark suite will:
1. Measure end-to-end expression evaluation latency from a cached, pre-parsed `ParsedExpr`.
2. Define test expression profiles spanning simple to complex AST structures.
3. Collect detailed performance metrics (min, max, p50, p95, p99 latency, throughput).
4. Report against the 10-microsecond target per requirement.
5. Enable ongoing performance monitoring and regression detection.

---

## 2. Benchmark Methodology

### 2.1 Measurement approach

**Unit of measurement:** Wall-clock microseconds (µs) per evaluation.

**Measurement window:** A single call to `expr.evaluate(&parsed_expr, &context, allocator)`.

**What is included:**
- Evaluating the entire AST (all nodes from root to leaves).
- Evaluating built-in functions (e.g., `length()`, `lower()`, etc.).
- Dot-path traversal with JSON parsing (DSL-11).
- Context lookups and value conversions.

**What is excluded:**
- Parsing the expression source (`expr.parse()`) — this is a one-time cost, amortized across evaluations.
- Allocator initialization and teardown.
- I/O to display or persist results.

### 2.2 Warm-up and stabilization

**Before measurement:**
1. Construct the `ParsedExpr` once and cache it.
2. Construct a `Context` with typical variable bindings.
3. Perform 3–5 "warm-up" evaluations (not timed) to warm CPU caches and stabilize branch prediction.

**Rationale:**
- First evaluation may incur cache misses, TLB stalls, and branch misprediction penalties.
- Warm-up ensures measurements reflect steady-state performance, not initialization overhead.

### 2.3 Iteration count and statistical rigor

**Per expression profile:**
1. Perform 1,000 warm-up evaluations (amortized over the test).
2. Perform 10,000 measured evaluations.
3. Record every individual evaluation time in microseconds.

**Rationale:**
- 10,000 samples provide statistical confidence in percentile estimation (p99 at ≥100 samples, p95 at ≥400 samples).
- 1,000 warm-ups ensure CPU state stabilization without inflating measurement time.

### 2.4 Hardware baseline

**Target platform:** Commodity x86-64 or ARM64 hardware.

**Baseline spec (reference system):**
- CPU: Intel Core i5/i7 (6th gen or later) or AMD Ryzen 5/7, or Apple Silicon M1/M2 or later, or AWS Graviton2/3
- Frequency: 2.0–3.5 GHz base clock (typical laptop/server)
- Cores: ≥4 (minimal contention with a single benchmark thread)
- RAM: ≥8 GB (no memory pressure)
- CPU cache: ≥8 MB L3 (standard modern processors)

**Test isolation:**
- Run benchmark on a single dedicated CPU core (pin thread to core via `taskset` on Linux or `sched_setaffinity` on Windows).
- Minimize background processes and interrupts.
- No concurrent workloads during measurement.

### 2.5 Timing mechanism

**Timer:** `std.time.nanoTimestamp()` (nanosecond-precision wall-clock timer in Zig stdlib).

**Conversion:** Nanoseconds to microseconds via integer division: `elapsed_ns / 1000`.

**Overhead:** `std.time.nanoTimestamp()` overhead (~50–200 ns per call on modern systems) is negligible compared to the 10 µs target (0.5–2%).

**Alternative (if needed for extreme precision):**
- On x86-64: `RDTSC` instruction (cycle count) via `std.time.rdtsc()` if available.
- Pros: CPU-cycle precision (1–2 ns per cycle at 1–2 GHz).
- Cons: Affected by frequency scaling; requires conversion to wall-clock time; less portable.

For this benchmark, `std.time.nanoTimestamp()` is preferred — it is portable, low-overhead, and sufficient for the 10 µs target.

### 2.6 Allocator choice

**Allocation pattern during evaluation:**
- Dot-path traversal may allocate temporary buffers for JSON parsing.
- Built-in string functions may allocate intermediate strings.
- Most evaluation paths are allocation-free.

**Allocator type:**
- Use a fixed-buffer or arena allocator that is reset between iterations.
- Example: `std.heap.FixedBufferAllocator` with a 64 KB scratch buffer (typical evaluation allocations < 1 KB).
- If buffer overflows: fall back to `GeneralPurposeAllocator` (add a note to the benchmark that this indicates unexpectedly large allocations).

**Measurement:**
- Reset the allocator between iterations to avoid contention and realistic memory state.
- Do NOT measure allocator overhead — the allocator is reset outside the timing window.

---

## 3. Test Expression Profiles

The benchmark suite includes 5 expression profiles, ranging from simple to moderately complex. Each profile targets a specific AST node count and evaluation path.

### 3.1 Profile 1: Trivial (1–2 nodes)

**Name:** `trivial`

**Example expressions:**
```
42
"hello"
true
null
```

**AST structure:**
- Single literal node (int, float, string, bool, or null).
- No operators, no function calls, no context lookups.

**Node count:** 1

**Purpose:** Baseline measurement of minimal overhead (timer call, context lookup, value return).

**Expected latency target:** < 0.5 µs (literal evaluation is O(1)).

---

### 3.2 Profile 2: Scalar variable lookup (2–3 nodes)

**Name:** `scalar_lookup`

**Example expressions:**
```
order_total
customer_name
is_approved
```

**AST structure:**
- Single-segment dot-path node (identifier lookup in context).
- No traversal, no JSON parsing.

**Node count:** 1 (the dot_path is a leaf node with 1 segment)

**Context setup:**
```
{
  "order_total": 1500,
  "customer_name": "Alice",
  "is_approved": true
}
```

**Purpose:** Measure the cost of variable lookup in the context map (hash table).

**Expected latency target:** < 1 µs (hash table lookup + value return).

---

### 3.3 Profile 3: Simple comparison (5 nodes)

**Name:** `simple_comparison`

**Example expressions:**
```
order_total > 1000
customer_age < 65
is_approved == true
amount != 0
```

**AST structure:**
```
         cmp_expr (>)
        /          \
    dot_path      int_literal
    ["order_total"]   1000
```

**Node count:** 3 (cmp_expr + left dot_path + right int_literal)

**Context setup:**
```
{
  "order_total": 1500,
  "customer_age": 45,
  "is_approved": true,
  "amount": 250
}
```

**Purpose:** Measure the cost of binary comparison operations and type coercion (DSL-05).

**Expected latency target:** < 2 µs (two variable lookups + comparison + coercion).

---

### 3.4 Profile 4: Nested logic (8 nodes)

**Name:** `nested_logic`

**Example expressions:**
```
order_total > 1000 and customer_status == "VIP"
(amount < 100 or is_urgent) and approval_required
```

**AST structure (first example):**
```
            and_expr
           /        \
      cmp_expr      cmp_expr
      /    \        /      \
  dot_path  lit   dot_path  lit
  ["total"] 1000  ["status"] "VIP"
```

**Node count:** 7 (and_expr + 2×cmp_expr + 4×leaf nodes)

**Context setup:**
```
{
  "order_total": 1500,
  "customer_status": "VIP",
  "amount": 50,
  "is_urgent": false,
  "approval_required": true
}
```

**Purpose:** Measure the cost of short-circuit evaluation (DSL-05 logical AND/OR), multiple comparisons, and boolean coercion.

**Expected latency target:** < 4 µs (multiple lookups + comparisons + short-circuit logic).

---

### 3.5 Profile 5: Complex nested objects (10 nodes)

**Name:** `complex_nested`

**Example expressions:**
```
order.customer.address.country == "US" and order.total > 100
order.items[0].quantity + order.items[1].quantity > 5
customer.profile.age * 2 > 60
```

**AST structure (first example):**
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

**Node count:** 9 (and_expr + 2×cmp_expr + 2×complex dot_path + 2×literal)

**Context setup:**
```
{
  "order": "{\"customer\":{\"address\":{\"country\":\"US\"}},\"total\":1500,\"items\":[{\"quantity\":3},{\"quantity\":2}]}",
  "customer": "{\"profile\":{\"age\":35}}"
}
```

**Purpose:** Measure the cost of multi-segment dot-path traversal with JSON parsing (DSL-11). This is the primary cost driver in realistic expressions.

**Expected latency target:** < 10 µs (JSON parsing per segment + context lookups + comparisons + coercion).

---

### 3.6 Profile 6: Built-in function call (7 nodes)

**Name:** `builtin_function`

**Example expressions:**
```
length(product_name) > 0
lower(category) == "electronics"
contains(description, "warranty")
coalesce(nickname, full_name) != ""
```

**AST structure (second example):**
```
           cmp_expr (==)
          /              \
      func_call          lit
      name: "lower"      "electronics"
      args: [dot_path]
            ["category"]
```

**Node count:** 5 (cmp_expr + func_call + arg dot_path + 2× literal)

**Context setup:**
```
{
  "product_name": "Widget Pro",
  "category": "Electronics",
  "description": "High quality with warranty",
  "nickname": null,
  "full_name": "John Doe"
}
```

**Purpose:** Measure the cost of built-in function invocation (string operations, coalescing, etc.). Covers the 11 whitelisted functions from DSL-07.

**Expected latency target:** < 5 µs (function dispatch + string operation + comparison).

---

## 4. Metrics Collection

For each expression profile, the benchmark collects:

### 4.1 Latency metrics (per iteration)

| Metric | Definition | Unit |
|--------|-----------|------|
| **min_us** | Minimum evaluation latency across all iterations | µs |
| **max_us** | Maximum evaluation latency across all iterations | µs |
| **mean_us** | Arithmetic mean latency | µs |
| **median_us** | 50th percentile (p50) latency | µs |
| **p95_us** | 95th percentile latency | µs |
| **p99_us** | 99th percentile latency | µs |

### 4.2 Throughput metrics

| Metric | Definition | Unit |
|--------|-----------|------|
| **throughput_per_sec** | 1,000,000 µs / mean_us = evaluations per second | evals/sec |

### 4.3 Relative to target

| Metric | Definition |
|--------|-----------|
| **target_met** | Boolean: mean_us ≤ 10.0 |
| **p99_headroom_pct** | (10.0 - p99_us) / 10.0 × 100; negative indicates breach |

### 4.4 Per-profile summary table

```
Profile            | Nodes | Mean(µs) | p95(µs) | p99(µs) | Target | Status
-------------------|-------|----------|---------|---------|--------|--------
trivial            | 1     |   0.1    |  0.15   |  0.2    |  10.0  | PASS
scalar_lookup      | 1     |   0.5    |  0.8    |  1.0    |  10.0  | PASS
simple_comparison  | 3     |   1.5    |  2.0    |  2.5    |  10.0  | PASS
nested_logic       | 7     |   3.0    |  4.0    |  5.0    |  10.0  | PASS
complex_nested     | 9     |   8.5    |  9.5    |  10.2   |  10.0  | WARN
builtin_function   | 5     |   2.5    |  3.5    |  4.5    |  10.0  | PASS
```

**Pass criteria:**
- Mean latency ≤ 10.0 µs: PASS
- Mean latency 8–10 µs: WARN (within target but approaching limit)
- Mean latency > 10 µs: FAIL

---

## 5. Output Reporting

### 5.1 Report format

The benchmark produces a structured report (`benchmark_results.json`) in the following format:

```json
{
  "metadata": {
    "timestamp": "2026-05-28T10:30:45Z",
    "platform": "Linux x86_64",
    "cpu": "Intel(R) Core(TM) i7-8700K CPU @ 3.70GHz",
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
      "name": "complex_nested",
      "description": "Multi-segment dot-path with JSON parsing",
      "ast_node_count": 9,
      "example_expressions": ["order.customer.address.country == \"US\""],
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
        "headroom_pct": -2.0,
        "warning": "p99 latency exceeds 10 µs target; consider optimization"
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

### 5.2 Human-readable summary

The benchmark prints a text summary to stdout:

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
scalar_lookup     1      0.50      0.80     1.00   PASS    90.0%
simple_comparison 3      1.50      2.00     2.50   PASS    75.0%
nested_logic      7      3.00      4.00     5.00   PASS    50.0%
complex_nested    9      8.50      9.80    10.20   WARN    -2.0%
builtin_function  5      2.50      3.50     4.50   PASS    55.0%
───────────────────────────────────────────────────────────────────

OVERALL RESULT: PASS (5 passed, 1 warned, 0 failed)

All mean latencies meet the 10 µs target.
Complex nested expressions approach the limit; monitor for regressions.

Detailed results: benchmark_results.json
```

### 5.3 CI/CD integration

The benchmark is integrated into the build system:

```bash
zig build bench
```

**Exit codes:**
- 0: All profiles passed (mean ≤ 10 µs).
- 1: Any profile failed (mean > 10 µs).
- 2: Benchmark execution error (e.g., invalid arguments).

**Regression detection:**
- Compare current `p99_us` against baseline.
- If any profile's p99 increases by >15% from baseline: flag as potential regression.
- Baseline stored in `docs/metrics/bench_baseline.json` (created on first successful run).

---

## 6. Implementation Roadmap for BACKEND-DEV

This section outlines the implementation tasks BACKEND-DEV will complete to realize the benchmark suite.

### 6.1 File structure

```
src/expr/
├── evaluator.zig         (existing — contains evaluate())
└── benchmark.zig         (new — benchmark suite implementation)

docs/metrics/
├── bench_baseline.json   (created on first run)
└── retrospectives/       (for future runs — see DSL-13 §5.3)

build.zig                 (modify to add `zig build bench` target)
```

### 6.2 Task breakdown

#### Task 1: Create `src/expr/benchmark.zig`

**Responsibility:** BACKEND-DEV

**Deliverables:**
1. Struct `ExpressionProfile` with fields:
   - `name: []const u8` — identifier (e.g. "trivial", "complex_nested")
   - `description: []const u8` — human-readable description
   - `example_expressions: [][]const u8` — example source strings
   - `parsed_expr: *ParsedExpr` — cached parsed expression
   - `context: *Context` — evaluation context with sample data
   
2. Function `fn benchmarkProfile(profile: ExpressionProfile, allocator: std.mem.Allocator) !BenchmarkResults`
   - Performs 1,000 warm-up evaluations (silent, untimed).
   - Performs 10,000 measured evaluations, timing each via `std.time.nanoTimestamp()`.
   - Collects all 10,000 latencies into an array.
   - Computes statistics: min, max, mean, median, p95, p99, stddev.
   - Returns `BenchmarkResults` struct with all metrics.

3. Function `fn initializeProfiles(allocator: std.mem.Allocator) ![6]ExpressionProfile`
   - Parses source for each of the 6 profiles.
   - Caches each as a `ParsedExpr`.
   - Initializes `Context` with sample data per §3.
   - Returns an array of 6 `ExpressionProfile` structs.

4. Struct `BenchmarkResults` with fields matching §4 (all metrics).

5. Function `fn reportResults(results: [6]BenchmarkResults, allocator: std.mem.Allocator) !void`
   - Prints human-readable summary to stdout (as per §5.2).
   - Writes JSON report to `docs/metrics/benchmark_results.json`.
   - Exits with code 0 (all passed) or 1 (any failed).

#### Task 2: Modify `build.zig`

**Responsibility:** BACKEND-DEV

**Deliverables:**
1. Add a new build step `zig build bench`:
   - Compiles `src/expr/benchmark.zig` and the expression DSL module.
   - Links with the Zig standard library.
   - Runs the compiled benchmark binary.
   - Captures exit code and JSON output.

2. Ensure `ReleaseFast` build mode is used (or `ReleaseSafe` for safety):
   ```zig
   const bench_exe = b.addExecutable(.{
       .name = "bench",
       .root_source_file = b.path("src/expr/benchmark.zig"),
       .optimize = .ReleaseFast,
       .target = b.standardTargetOptions(.{}),
   });
   ```

#### Task 3: Setup CI/CD Integration (future)

**Responsibility:** Part of a separate CI/CD workflow task (out of scope for this design, but mentioned for context).

**Deliverables (sketch):**
1. Add GitHub Actions workflow (`.github/workflows/bench.yml`) that:
   - Runs `zig build bench` on every commit to `main` and PRs to `main`.
   - Compares p99 metrics against baseline.
   - Posts comment to PR if regression detected (p99 increase >15%).
   - Stores baseline results in `docs/metrics/bench_baseline.json`.

2. Baseline creation:
   - On first successful run, save results as baseline.
   - On subsequent runs, compare against baseline.

---

## 7. Allocation and Memory Considerations

### 7.1 Benchmark allocator management

```zig
// Pseudo-code for benchmarkProfile()
fn benchmarkProfile(profile: ExpressionProfile, allocator: std.mem.Allocator) !BenchmarkResults {
    var latencies = std.ArrayList(u64).init(allocator);
    defer latencies.deinit();

    // Warm-up: 1,000 evaluations (untimed)
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var scratch = std.heap.FixedBufferAllocator.init(&scratch_buf);
        const _ = try expr.evaluate(profile.parsed_expr, profile.context, scratch.allocator());
        // scratch is reset implicitly when scope ends
    }

    // Measured iterations: 10,000 evaluations (timed)
    i = 0;
    while (i < 10000) : (i += 1) {
        var scratch = std.heap.FixedBufferAllocator.init(&scratch_buf);
        
        const start_ns = std.time.nanoTimestamp();
        const result = try expr.evaluate(profile.parsed_expr, profile.context, scratch.allocator());
        const end_ns = std.time.nanoTimestamp();
        
        const elapsed_us = @as(u64, @intCast((end_ns - start_ns) / 1000));
        try latencies.append(elapsed_us);
    }

    // Compute statistics from latencies array
    return computeStatistics(latencies.items);
}
```

### 7.2 Scratch buffer size

- Scratch buffer: 64 KB fixed allocation per iteration.
- Rationale: Typical evaluation allocations are < 1 KB (JSON parsing buffers, intermediate strings).
- If buffer overflows: BACKEND-DEV should investigate and document the surprising allocation pattern.

### 7.3 No memory leaks

- All allocations are freed before the next iteration.
- No persistent allocations except the parsed expressions and contexts (owned by the profiles).
- Profiles are deinitialized after all benchmarks complete.

---

## 8. Platform-Specific Considerations

### 8.1 Timer accuracy

| Platform | Timer | Granularity | Overhead |
|----------|-------|-------------|----------|
| Linux/Unix | `std.time.nanoTimestamp()` → `clock_gettime(CLOCK_MONOTONIC)` | 1 ns (nominal) | ~50–100 ns |
| Windows | `std.time.nanoTimestamp()` → `QueryPerformanceCounter()` | 0.1 µs (typical) | ~100–200 ns |
| macOS | `std.time.nanoTimestamp()` → `mach_absolute_time()` | 1 ns (nominal) | ~50–100 ns |

**Conclusion:** `std.time.nanoTimestamp()` overhead is < 1% of the 10 µs target across all major platforms.

### 8.2 CPU frequency scaling

**Issue:** If CPU frequency scaling is active (e.g., dynamic frequency scaling on laptops), actual latency may vary between runs.

**Mitigation (documented but not enforced):**
- Disable CPU frequency scaling on the test machine (if possible).
- Examples:
  - Linux: `echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor`
  - Windows: High Performance power plan in Control Panel.
- Report the power setting in the benchmark metadata.

### 8.3 NUMA and CPU affinity

**Issue:** On NUMA systems (multi-socket servers), memory access latency varies depending on which CPU socket the allocator is on.

**Mitigation (documented but not enforced):**
- Pin the benchmark process to a single CPU core and socket.
- Examples:
  - Linux: `taskset -c 0 zig build bench` (pin to core 0)
  - Windows: Set CPU affinity via Task Manager or `start /affinity 1 zig build bench`.

---

## 9. Success Criteria

The benchmark suite is considered complete and successful when:

1. **All profiles evaluate successfully** — no crashes, no panics, no assertion failures.

2. **Performance targets met:**
   - All 6 profiles have mean latency ≤ 10.0 µs.
   - Ideally, p99 latency ≤ 10.0 µs for profiles 1–5.
   - Profile 6 (complex_nested) may approach or slightly exceed 10 µs p99; document any overage.

3. **Metrics are stable** — running the benchmark twice on the same machine produces consistent results within ±5% variance.

4. **Report is automated** — `zig build bench` produces a JSON report and human-readable summary automatically.

5. **CI/CD integration is ready** — benchmark can be triggered in a CI pipeline; exit code indicates pass/fail.

6. **Documentation is clear** — this design document fully explains the methodology, profiles, and interpretation of results.

---

## 10. Interpretation and Troubleshooting

### 10.1 If p99 exceeds 10 µs on profile 5 (complex_nested)

**Likely causes:**
1. JSON parsing overhead — multi-segment dot-path traversal incurs JSON parsing per segment. This is expected.
2. Hash table collisions in context lookup — unlikely but possible if the context map is poorly balanced.
3. System interference — background processes, interrupts, page faults. Re-run on an idle system.

**Next steps:**
- Profile the `evaluate()` call with a CPU profiler (e.g., `perf` on Linux) to identify the hotspot.
- Consider optimizing JSON parsing (e.g., caching parsed objects within an evaluation).
- Document as a known limitation and monitor for regressions.

### 10.2 If mean latency exceeds 10 µs on any profile

**Likely causes:**
1. Suboptimal evaluator implementation (e.g., unnecessary allocations, string copies, inefficient algorithms).
2. Incorrect build mode (e.g., `Debug` instead of `ReleaseFast`).
3. System interference.

**Next steps:**
- Verify build mode is `ReleaseFast` (or `ReleaseSafe`).
- Run on an isolated system with minimal background processes.
- Use a CPU profiler to identify performance bottlenecks.
- Create an issue-fixer handoff if optimization is needed.

### 10.3 If latency is below 1 µs on all profiles

**Likely causes:**
1. Benchmark loop is being optimized away by the compiler (dead code elimination).
2. Results are cached or predefined by the compiler.

**Next steps:**
- Ensure the benchmark result is used (e.g., printed or returned) to prevent dead code elimination.
- Verify the parsed expressions and contexts are truly being evaluated (not skipped).
- Inspect the generated assembly to confirm the benchmark loop is present.

---

## 11. Key Invariants

1. **Measurement window:** Only `expr.evaluate()` time is measured; parsing and allocator setup are excluded.
2. **Statistical rigor:** 10,000 samples per profile enable confident p95/p99 reporting.
3. **Warm-up:** 1,000 silent iterations stabilize CPU state before measurement begins.
4. **Platform awareness:** Benchmark accommodates multiple platforms (Linux, Windows, macOS) and CPU architectures (x86-64, ARM64).
5. **Target per-expression:** The 10 µs target is a per-evaluation latency, not total throughput. A system that evaluates 100,000 expressions/sec is within target.
6. **Caching validated:** The benchmark measures the cost of cached expression evaluation (DSL-12), not parsing.

---

## 12. Integration with DSL-12 (Engine API)

The benchmark validates that the DSL-12 caching strategy delivers expected performance benefits:

- **Parse time:** Cached outside measurement (one-time cost, ~100 µs per expression).
- **Evaluation time:** Measured and expected to be ~10 µs per cached evaluation.
- **Amortization:** For an expression evaluated 100 times, total time ≈ 100 µs + 100 × 10 µs = 1,100 µs, or ~11 µs per evaluation amortized.

The benchmark confirms that the evaluator (DSL-12's `evaluate()` function) delivers the performance promised by the caching API.

---

## 13. Future Extensions (Out of Scope)

1. **Profile 7: Variable transformer expressions** — expressions used in EXT-04 (variable transformers).
2. **Profile 8: Gateway condition expressions** — expressions used in EE-05 (engine condition evaluation).
3. **Dynamic threshold adjustment** — allow 10 µs target to be configurable per deployment.
4. **Allocation profiling** — track peak heap usage and allocations per expression.
5. **Energy/power metrics** — measure power consumption during evaluation (advanced).

---

## 14. Open Questions

1. **Should the benchmark include lock contention tests?** If expressions are evaluated concurrently, thread-safe metadata updates (DSL-12 §4.3) may introduce contention. Out of scope for Stage 7; addressed in Stage 9+ if concurrency is added.

2. **Should baseline results be committed to git?** Recommend storing `docs/metrics/bench_baseline.json` in the repository so CI/CD regression detection is consistent across machines. Decision deferred to release-validator / orchestrator.

3. **What is the acceptance criteria for p99?** This design states "ideally ≤ 10.0 µs" but allows up to slight overage on profile 5 (complex_nested). Exact threshold should be confirmed with stakeholders before Stage 7 release.

---

## 15. Summary

DSL-13 defines a comprehensive benchmark suite that:

- **Measures** the latency of cached expression evaluation via 10,000 iterations per profile.
- **Profiles** 6 expression types spanning trivial to moderately complex (up to 10 AST nodes).
- **Collects** detailed statistics (min, max, mean, p50, p95, p99) per profile.
- **Reports** human-readable summaries and machine-parseable JSON.
- **Validates** compliance with the 10 µs performance target.
- **Enables** ongoing regression detection and performance monitoring.

The implementation is straightforward: a standalone benchmark program in `src/expr/benchmark.zig` that parses 6 expression profiles, caches them, and measures evaluation latency. BACKEND-DEV will implement it as a standard build target (`zig build bench`).

---

## 16. Acceptance Criteria Checklist

- [x] Benchmark methodology clearly specified (warm-up, iterations, hardware baseline).
- [x] 6 expression profiles defined with AST node counts and expected latencies.
- [x] Performance target (10 µs mean, ideally p99 ≤ 10 µs) clearly stated.
- [x] Metrics collection strategy documented (min, max, mean, p50, p95, p99, throughput).
- [x] Output reporting format (JSON and human-readable text) defined.
- [x] Implementation roadmap for BACKEND-DEV provided (tasks, file structure, functions).
- [x] Platform-specific considerations addressed (timers, frequency scaling, NUMA).
- [x] Troubleshooting guidance provided for common failure modes.
- [x] Design artefact written to `src/design/expr-benchmark.md`.
