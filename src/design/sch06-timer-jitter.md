# Module: sch06-timer-jitter

## Module purpose

Extend the existing scheduler polling mechanism (SCH-02) with a configurable random jitter applied to the poll cycle sleep duration. In clustered deployments, multiple scheduler nodes polling at identical intervals create a thundering-herd effect on the `timers` table — all nodes wake simultaneously and contend for the same `FOR UPDATE SKIP LOCKED` rows. Adding uniform-random jitter spread the wake-up times across the jitter window, drastically reducing contention.

This design does **not** introduce a new module. It modifies the existing `src/scheduler/scheduler.zig` and `src/config.zig` (or the env-var loading path). All changes stay within the established `src/scheduler/` boundary.

## Public interface

### New config field

```zig
// src/config.zig — SchedulerConfig extension (or top-level Config if scheduler
// config is embedded there; see Open questions §1)
pub const SchedulerConfig = struct {
    poll_interval_ms: u64 = 5000,
    jitter_ms: u64 = 0,        // NEW: 0 = disabled, >0 enables ±jitter_ms
};
```

**Environment variable:** `BPM_SCHEDULER_JITTER_MS`

| Attribute | Value |
|---|---|
| Type | Unsigned 64-bit integer |
| Default | `0` (jitter disabled) |
| Valid range | `0` to any positive value |
| Validation at startup | None beyond `u64` parse. Jitter > base interval is accepted per SCH-06 edge-case rule. |
| Unit | Milliseconds |

### New helper functions

```zig
// src/scheduler/scheduler.zig — additions

/// Compute the actual sleep delay for the next poll cycle.
/// Returns the base poll_interval_ms adjusted by a uniform-random jitter
/// in the range [-jitter_ms, +jitter_ms].
///
/// When jitter_ms == 0 (default), this is a trivial return of poll_interval_ms.
///
/// The result is guaranteed non-negative (clamped to 0).
pub fn computePollDelayMs(self: *const Scheduler, rng: *std.Random) u64;
```

```zig
// src/scheduler/scheduler.zig — new field on Scheduler

pub const Scheduler = struct {
    pool: *db.Pool,
    config: SchedulerConfig,
    is_startup_sweep: bool,
    prng: std.Random.DefaultPrng,   // NEW: thread-local PRNG state

    pub fn init(pool: *db.Pool, config: SchedulerConfig) Scheduler {
        // Seed from time + address to ensure per-process uniqueness
        const seed: u64 = @bitCast(std.time.nanoTimestamp());
        return .{
            .pool = pool,
            .config = config,
            .is_startup_sweep = true,
            .prng = std.Random.DefaultPrng.init(seed),
        };
    }
};
```

### No changes to

- `src/scheduler/store.zig` — persist layer unchanged; jitter is a runtime sleep adjustment, not a stored value.
- `src/engine/transition.zig` — remains pure; receives no jitter influence.
- `migrations/` — no schema changes.
- `src/scheduler/scheduler.zig` signature of `pollDueTimers` — unchanged.

## Data types

No new struct types. The jitter state lives entirely inside `Scheduler.prng` (a `std.Random.DefaultPrng`).

## Random number source

| Aspect | Decision |
|---|---|
| Algorithm | `std.Random.DefaultPrng` (Xoshiro256** on Zig 0.x, or the platform default) |
| Locality | **Thread-local** — each `Scheduler` instance owns its own `prng` field |
| Seed | Derived from `std.time.nanoTimestamp()` at `Scheduler.init()` time, bit-cast to `u64` |
| Shared seed | **No** — each process/node initialises independently; clock skew + init-time differences guarantee divergent streams |
| Entropy warning | `nanoTimestamp()` alone is not cryptographically strong but is sufficient for jitter purposes. No `/dev/urandom` dependency needed. |

## Jitter calculation

### Formula

```
Given:
  base_ms   = SchedulerConfig.poll_interval_ms   (u64)
  jitter_ms = SchedulerConfig.jitter_ms           (u64)
  rng       = thread-local Xoshiro256** instance

When jitter_ms == 0:
  actual_delay_ms = base_ms

When jitter_ms > 0:
  // Generate a uniform random offset in [-jitter_ms, +jitter_ms]
  offset = rng.int53() % (2 * jitter_ms + 1) - jitter_ms   // i64 ∈ [-jitter_ms, +jitter_ms]
  actual_delay_ms = max(0, base_ms + offset)                // clamped to ≥0

Return actual_delay_ms as u64.
```

### Derivation

- `rng.int53()` produces a non-negative 53-bit integer (safe for exact i64).
- `% (2 * jitter_ms + 1)` maps it to the range `[0, 2 * jitter_ms]` inclusive.
- Subtracting `jitter_ms` shifts to `[-jitter_ms, +jitter_ms]`.
- `@max(0, base_ms + offset)` clamps the result: if `base_ms < jitter_ms` and the offset is negative, the delay floor is 0 (no negative sleep).

### Distribution properties

| Property | Value |
|---|---|
| Distribution | Uniform over `[base_ms - jitter_ms, base_ms + jitter_ms]` |
| Mean | `base_ms` |
| Variance | `jitter_ms² / 3` |
| Range width | `2 × jitter_ms` |
| Clamp boundary | Delay is clamped to ≥0 (SCH-06 edge case) |

### Pseudocode

```
fn computePollDelayMs(jitter_ms: u64, base_ms: u64, rng: *std.Random) -> u64:
    if jitter_ms == 0:
        return base_ms
    offset: i64 = @intCast(rng.int53() % (2 * jitter_ms + 1))
    offset -= @as(i64, @intCast(jitter_ms))
    result: i64 = @as(i64, @intCast(base_ms)) + offset
    if result < 0:
        return 0
    return @as(u64, @intCast(result))
```

## Application point

The jitter is applied to the **sleep between poll cycles**, not to any timer's `fire_at` value. This is the central invariant of SCH-06.

```
┌─────────────────────────────────────────────────────────┐
│                    Scheduler Poll Loop                    │
│                                                         │
│  while (running) {                                       │
│      summary = scheduler.pollDueTimers(allocator)        │
│      delay_ms = scheduler.computePollDelayMs(&rng)      │
│      std.time.sleep(delay_ms * std.time.ns_per_ms)      │
│  }                                                       │
│                                                         │
│  Jitter affects ONLY the sleep duration between cycles. │
│  Timer fire_at values are NEVER modified.                │
└─────────────────────────────────────────────────────────┘
```

**Current state (as of SCH-05):** The sleep between `pollDueTimers` calls is managed by the caller (likely `src/main.zig` or a dedicated scheduler runner thread). The caller reads `config.poll_interval_ms` directly.

**SCH-06 change:** Replace the direct `config.poll_interval_ms` with a call to `scheduler.computePollDelayMs()`. The caller does not compute jitter itself — the scheduler struct owns that logic.

### Data flow diagram

```mermaid
flowchart TD
    A[Scheduler.init] --> B[Seed prng from nanoTimestamp]
    B --> C[Enter poll loop]

    C --> D[pollDueTimers: process all due timers]
    D --> E[computePollDelayMs: get delay with jitter]

    E --> F{jitter_ms > 0?}
    F -->|No| G[delay = poll_interval_ms]
    F -->|Yes| H[offset = random(-jitter_ms, +jitter_ms)]
    H --> I[delay = max(0, poll_interval_ms + offset)]

    G --> J[sleep(delay)]
    I --> J

    J --> C
```

### Invariant enforcement

1. **`pollDueTimers` is unaffected.** The function processes all due timers identically regardless of jitter config. It receives no jitter parameter.
2. **`processNextDueTimer` is unaffected.** The per-timer firing logic has no jitter awareness.
3. **`isFiredLate` is unaffected.** The overdue-detection threshold uses the raw `poll_interval_ms`, not the jittered delay. This is correct because `isFiredLate` measures material lateness of individual timers relative to their `fire_at`, not the poll cycle timing.
4. **`fire_at` is never read or written by jitter code.** The jitter affects only the caller's sleep call.

## Key invariants

1. **Jitter affects only the sleep between poll cycles.** Timer `fire_at` values are never modified. This is the hard boundary of SCH-06.
2. **Default is 0 (disabled).** Jitter is opt-in. Existing single-node deployments are unaffected.
3. **Every node independently randomises.** No shared seed, no coordination protocol. Each `Scheduler` instance seeds its own `prng` at init time.
4. **Minimum effective delay is 0.** When `jitter_ms > poll_interval_ms`, negative offsets are clamped to 0. The poll loop never sleeps less than 0 ms.
5. **No DB writes.** Jitter configuration and state are purely in-memory.
6. **Deterministic for same seed.** For reproducibility in tests, `SchedulerConfig` could expose an optional `test_seed` field, but this is not required by SCH-06.

## Edge case analysis

### Jitter larger than base interval

```
Scenario:   poll_interval_ms = 1000, jitter_ms = 2000
Offsets:    [-2000, +2000]
Raw delays: [-1000, +3000]
Clamped:    [0, +3000]

Probability of 0 delay: ~33% (offset ≤ -1000 out of 4001 possible values)
```

Per SCH-06 acceptance criteria: the platform does not validate this. The `max(0, ...)` clamp ensures safety. A delay of 0 means the next poll starts immediately — this is acceptable behaviour (the node effectively "busy-polls" but is throttled by `FOR UPDATE SKIP LOCKED` contention from the other nodes).

**Recommendation:** Log a WARN-level message at startup if `jitter_ms > poll_interval_ms` so operators can detect misconfiguration.

### Jitter = 0 (default)

`computePollDelayMs` returns `poll_interval_ms` directly, bypassing the PRNG entirely. Zero overhead compared to the current behaviour.

### Single-node deployment

Jitter is harmless on a single node — it introduces random variation in the sleep that has no effect on correctness. Operators simply leave `BPM_SCHEDULER_JITTER_MS=0` (default).

### Clock rollback / time jump

The PRNG seed is set once at `init()` time and never re-reads wall clock. A clock jump after init does not affect jitter behaviour. The `nanoTimestamp` seed is used only for initial entropy; runtime timing uses `std.time.sleep` which is monotonic on all supported platforms.

## Error taxonomy

No new error variants. The jitter calculation is infallible:

| Condition | Behaviour |
|---|---|
| `jitter_ms = 0` | Returns `base_ms` directly; no PRNG call |
| `jitter_ms > 0` | `int53()` is infallible; `%` and `+`/`-` are infallible; `@max(0, ...)` is infallible |
| `jitter_ms > base_ms` | Clamp to 0; no error |
| PRNG seed collision (astronomically unlikely) | Nodes still behave correctly, just with correlated jitter; no correctness issue |

## External dependencies

| Dependency | Type | Usage |
|---|---|---|
| `src/scheduler/scheduler.zig` | Modified | Adds `prng` field, `computePollDelayMs` method |
| `src/config.zig` or scheduler config path | Modified | Reads `BPM_SCHEDULER_JITTER_MS` |
| `std.Random.DefaultPrng` | Standard library | Thread-local PRNG; already available |
| `std.time.nanoTimestamp` | Standard library | Seed source for PRNG |
| `src/db/pool.zig` | Unchanged | No DB interaction |
| `src/engine/transition.zig` | Unchanged | Pure; receives no jitter |
| Caller (e.g. `src/main.zig`) | Updated | Calls `computePollDelayMs` instead of reading `poll_interval_ms` directly |

## Acceptance-criteria traceability matrix

| SCH-06 criterion | Design coverage |
|---|---|
| Configurable jitter via `BPM_SCHEDULER_JITTER_MS` | New config field `jitter_ms` on `SchedulerConfig`; env var `BPM_SCHEDULER_JITTER_MS` |
| Default 0 (disabled) | `jitter_ms: u64 = 0` |
| `actual_delay = base_interval ± random(0, jitter_ms)` | `computePollDelayMs` formula: uniform offset in `[-jitter_ms, +jitter_ms]` added to `base_ms` |
| Per-node independent randomisation | `Scheduler.prng` seeded from `nanoTimestamp()` at init; no shared seed |
| Jitter NOT applied to timer `fire_at` | Invariant §1: jitter affects only sleep between poll cycles |
| Jitter > base interval: minimum = 0 | `@max(0, base_ms + offset)` clamp; no validation |
| No DB schema changes | No migration file; no new columns or tables |

## Open questions

1. **Config ownership:** Should `SchedulerConfig` remain a standalone struct initialised by the caller, or should scheduler config fields be embedded in the global `Config` struct and parsed from env vars there? **Recommendation (non-binding):** Keep `SchedulerConfig` as a standalone struct for testability; have the caller (`src/main.zig`) parse `BPM_SCHEDULER_JITTER_MS` from env and pass it in. This avoids coupling the scheduler to the global config loader.

2. **Seed source robustness:** `std.time.nanoTimestamp()` is fast and low-entropy but sufficient for jitter. If the platform ever needs crypto-grade randomness (unlikely for a sleep jitter), the seed could be mixed with OS entropy (`std.crypto.random.int(u64)`). Recommend keeping `nanoTimestamp()` for now — it is deterministic, fast, and trivially diverge per process.

3. **PRNG algorithm choice:** `std.Random.DefaultPrng` is platform-defined. On Zig 0.x this is typically Xoshiro256**. If a future Zig version changes the default, the jitter distribution is unaffected (still uniform, just a different generator). If reproducibility across Zig versions is needed, pin to `std.Random.Xoshiro256`. **Recommendation:** Use `DefaultPrng` for simplicity; the jitter is non-cryptographic.

4. **Logging at startup:** Should the scheduler log `"jitter enabled: ±{jitter_ms}ms"` at INFO level on init? **Recommendation:** Yes — this helps operators verify cluster configuration.

5. **Testability seed exposure:** For deterministic tests, should `SchedulerConfig` expose a `test_seed: ?u64` field that overrides the `nanoTimestamp()` seed? **Recommendation:** Yes — add `test_seed: ?u64 = null` to `SchedulerConfig`. When `test_seed != null`, use it instead of `nanoTimestamp()` in `init`. This allows unit tests to assert exact jitter values.

## Handoff notes for BACKEND-DEV

1. Add `jitter_ms: u64 = 0` to `SchedulerConfig` in `src/scheduler/scheduler.zig`.
2. Add `prng: std.Random.DefaultPrng` field to `Scheduler` struct, seeded from `nanoTimestamp()`.
3. Add optional `test_seed: ?u64 = null` to `SchedulerConfig` for test determinism.
4. Implement `computePollDelayMs` method — infallible, returns `u64`.
5. Update the caller (e.g. `src/main.zig` scheduler runner thread) to call `computePollDelayMs` instead of reading `poll_interval_ms` directly.
6. Parse `BPM_SCHEDULER_JITTER_MS` from environment in the caller (or in `config.zig` if config is centralised).
7. No changes to `store.zig`, `transition.zig`, `migrations/`.
8. Add unit tests for `computePollDelayMs` with known seeds via `test_seed` to verify distribution bounds.
9. Add `@max(0, ...)` clamp for the jitter > base-interval edge case.
10. Optionally log a WARN at startup if `jitter_ms > poll_interval_ms`.
