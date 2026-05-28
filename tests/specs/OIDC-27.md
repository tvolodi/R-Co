# Test Spec: OIDC-27 — Token verification performance

**Requirement:** OIDC-27 — P95 token verification latency SHOULD be under 2 ms with warm JWKS cache, and under 100 ms for cold-cache verification.

**Priority:** SHOULD
**Test layer:** unit, integration

## Test Cases

### TC-OIDC-27-01: Warm-cache benchmark meets p95 target
**Given:** JWKS cache is primed and benchmark input uses warm_cache scenario
**When:** Verification benchmark runs with fixed sample_count and deterministic verifier fixture
**Then:** Reported p95_us is less than or equal to target_p95_us (2000 us)
**Layer:** unit
**Acceptance criterion mapped:** Benchmark suite measures and reports warm-cache target

### TC-OIDC-27-02: Cold-cache benchmark meets p95 target and remains separately measured
**Given:** JWKS cache is cleared between samples and benchmark input uses cold_cache scenario
**When:** Verification benchmark runs for cold-cache scenario
**Then:** Reported p95_us is less than or equal to target_p95_us (100000 us) and result.scenario is cold_cache
**Layer:** unit
**Acceptance criterion mapped:** Warm-cache and cold-cache scenarios are tested separately

### TC-OIDC-27-03: SLO evaluation keeps warm and cold pass decisions independent
**Given:** Warm and cold benchmark stats with independent percentile values
**When:** SLO evaluation is computed
**Then:** warm_cache_pass and cold_cache_pass are derived independently using their own targets
**Layer:** unit
**Acceptance criterion mapped:** Separate reporting and evaluation for warm and cold paths

## Planned test source and execution
- tests/unit/test_oidc27_verification_benchmark.zig
- Command: zig build test
