# ISS-0629 / GH-600 — TC-LUA-10-03 flake fix (test-only)

Type: E (novel, minimal) — a single-assertion test fix, no new module.
Issue: ISS-0629 (GH-600)

## Module purpose

`TC-LUA-10-03` (`src/lua/limiter_wiring_test.zig`, test starting L515) asserts
that the host-external watchdog thread (`src/lua/timeout.zig`) has fired by
the time a 200,000,000-iteration `lua_pcall` returns. The watchdog runs on a
separate `std.Thread` (`watchdogLoop`, `timeout.zig` L187-200) that polls
wall-clock time every `POLL_INTERVAL_NS` (10ms, L84) and only flips
`WatchdogState.fired` after its own poll observes `now >= deadline`.

The test currently reads `watchdog_state.hasFired()` on the line immediately
after `lua_pcall` returns (current L600), with no allowance for the
watchdog thread's own ~10ms poll latency plus ordinary OS scheduling delay
before it gets to run and observe the deadline. Under system load this
scheduling gap widens, producing the flake ISS-0629 documents (3 fail / 2
pass across 5 consecutive `zig build test-lua` runs, zero code changes
between runs). This is a race in the test's own assertion timing, not a
defect in `WatchdogState`/`WatchdogHandle`/`watchdogLoop` — see
`src/design/iss0169-lua08-09-10-limiter-wiring.md` §2.5 for the mechanism's
own design, which is unchanged by this fix.

The purpose of this change is to replace the single zero-tolerance assertion
with a bounded retry loop that gives the watchdog thread a fair window to
catch up to a deadline that has, by construction, already passed — without
weakening the test's actual guarantee (see "Confirms no guarantee is
weakened" below).

## Public interface

No public interface changes. This is a private test-body edit inside one
`test { ... }` block in `src/lua/limiter_wiring_test.zig`. No production
file is touched — `src/lua/timeout.zig` is unchanged, `WatchdogState` and
`WatchdogHandle`'s public surface (`init`, `start`, `stop`, `hasFired`) are
unchanged.

Replace current L600:

```zig
try std.testing.expect(watchdog_state.hasFired());
```

with:

```zig
const retry_deadline = milliTimestamp() + 1_000;
while (!watchdog_state.hasFired() and milliTimestamp() < retry_deadline) {
    std.Thread.yield() catch {};
}
try std.testing.expect(watchdog_state.hasFired());
```

### Chosen mechanism: yield-spin, not sleep-based polling

Two options were available (per ISSUE-FIXER's diagnosis in the handoff):

1. **Yield-spin** against `milliTimestamp()` — the test file's own existing
   helper, already used at L584/L586 (and again at L621 in the mutation-check
   test immediately below this one) — combined with `std.Thread.yield()`.
2. **Sleep-based polling** at a fixed interval (e.g. 20ms) using a sleep
   primitive.

**Decision: yield-spin.** Rationale:

- `timeout.zig`'s own doc comment (L93-126, CDV-0169-5) documents that this
  repo's Zig 0.16.0 target required a hand-rolled `sleepNanos` because
  `std.Thread.sleep` does not exist, `std.time.sleep` was removed, and
  `std.c.nanosleep` does not work on Windows (`time_t` resolves to `void`
  there). That helper is `fn sleepNanos(nanos: u64) void` — private to
  `timeout.zig`, not exported.
- Reusing it from the test would require either making it `pub` (a
  production-file change, which the handoff's REQUIRED FIX SHAPE explicitly
  forbids) or re-deriving the same Windows/POSIX branch in the test file
  (needless duplication of a problem `timeout.zig` already solved once).
  Reusing `std.Thread.yield()` sidesteps this entirely: it is confirmed
  available directly on `std.Thread` per that same doc comment
  (`spawn`/`join`/`detach`/`yield`/`getName`/`setName`), and the test file
  already calls it at L623 in the very next test.
- `milliTimestamp()` is already imported and used in this exact test (L584,
  L586) and in the adjacent mutation-check test (L621), so the yield-spin
  form introduces no new helper, no new import, and no new cross-platform
  question — it is the path of least new surface area.
- A yield-spin here is not busy-waiting in the pejorative sense: the retry
  window is bounded to 1000ms total (see below) and `std.Thread.yield()`
  voluntarily relinquishes the timeslice each iteration rather than spinning
  on a tight CPU-bound loop, matching the pattern the mutation-check test
  immediately below already establishes as acceptable in this file.

## Retry bound

- **Total budget: 1000ms.** Justification: 100x the watchdog's own 10ms
  `POLL_INTERVAL_NS` (`timeout.zig` L84), so it comfortably absorbs the OS
  scheduling jitter that produced the observed 3/5 flake rate under load,
  while remaining negligible against the test's existing 30s upper bound on
  `elapsed_ms` (current L591) — worst-case added runtime is ~0.003% of that
  budget, and only in the (should-not-happen) retry-exhausted failure path.
- No separate poll interval is chosen: the yield-spin form has no discrete
  interval, it re-checks `hasFired()` and the deadline on every yielded
  timeslice.

## Confirms no guarantee is weakened

The retry loop only ever starts **after** `lua_pcall` has already returned,
which is only after the 200,000,000-iteration script has already run to
completion — and that loop is sized (per the existing comment at current
L567-574) to reliably take far longer than the watchdog's 1s deadline. So by
the time the retry loop's first check runs, the deadline has already been in
the past for the entire duration of the (much longer) script execution. The
loop is not waiting for the deadline to arrive; it is waiting only for the
watchdog thread's own poll cycle to catch up to a fact that is already true.

If `hasFired()` is still false after a further full 1000ms past an
already-expired 1s deadline, the watchdog is not exhibiting scheduling
jitter — it is genuinely not firing — and the final
`try std.testing.expect(watchdog_state.hasFired());` after the loop exits
still fails the test in that case, exactly as the original single-shot
assertion did. No failure mode that the original assertion caught is masked
by this change.

## Error taxonomy

No new error paths. The only failure mode this test body can produce is
unchanged: `std.testing.expect` returning `error.TestUnexpectedResult` if
`hasFired()` is still `false` when the retry loop's bound is reached — the
same failure the original single-shot assertion produced, just observed
after a bounded fair-scheduling window instead of immediately. No new error
set, no new `catch`, no new production error variant.

## Scope confirmation — no other test needs this fix

- **TC-LUA-10-01** (L219): does not call `hasFired()` at all — it asserts on
  the in-VM count-hook's own timeout error path, which is unrelated to the
  watchdog thread. No race exists here.
- **TC-LUA-10-02** (L347): does call into the watchdog via
  `platformCallService` → `host_context.zig activeWatchdogFired()` →
  `wd.hasFired()`, but that read happens synchronously inline within the
  same blocking host-call chain the test's own assertions (`result.success`
  / `error_message`, L430-432) already key off of — not as an independent
  post-hoc read racing an unrelated poll thread's own schedule. Its
  `elapsed_ms >= 1_400` lower bound (L426) already proves the check ran well
  past the mock's 1500ms delay and the 1s deadline. No race exists here.
- **TC-LUA-10-03 mutation check** (L603, `never_started.hasFired()` at
  L632): asserts `false` against a `WatchdogState` for which no watchdog
  thread was ever spawned. Nothing can ever flip `fired` for `never_started`,
  so there is no race window to close — an unstarted watchdog can only ever
  read as not-fired, immediately or after any amount of waiting.

No other file under `src/` contains a comparable post-hoc read of an atomic
set by an independently-scheduled polling thread.

## Dependencies

None beyond what the test file already imports (`std`, `milliTimestamp()`
already declared/used in this file, `timeout_ctx.WatchdogState` already
imported as `timeout_ctx`). No new import required. No production file
(`src/lua/timeout.zig` or otherwise) is modified.

## Acceptance criteria mapping

| Handoff acceptance criterion | How this design satisfies it |
|---|---|
| Targets exactly `src/lua/limiter_wiring_test.zig`, test-only | Confirmed above — no production file touched |
| L600 single assertion replaced by bounded retry loop | Shown in "Public interface" above |
| One mechanism chosen, not left ambiguous | Yield-spin chosen and justified above |
| 1000ms total budget, justified | Justified above (100x poll interval, negligible vs. 30s bound) |
| Retry loop cannot mask a genuine failure | "Confirms no guarantee is weakened" above |
| No other test needs the same fix | "Scope confirmation" above, one line per test |
| Artefact weight appropriate to a ~6-line change | This is a short Type E prose note, no Type A-D YAML |
