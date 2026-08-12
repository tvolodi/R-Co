# Fix Design — ISS-0691 / GH-753

**Issue:** [ISS-0691](https://github.com/tvolodi/R-Co/issues/753) — TC-SIM-01-01 leaks one
heap allocation per run via discarded `AppendResult` (and one via discarded
`appendSimulationEvent` return value).

**Severity:** MINOR (test-only; no production code path affected)

**Workflow:** WF-03 Issue Resolving, Step 02 (CODE-DESIGNER)

---

## 1. Root cause (verified)

`tests/integration/sim01_04_simulation_mode_test.zig` TC-SIM-01-01, in the test
body, makes two heap-allocating calls whose returned records' `.metadata` fields
are then discarded:

| Line | Call site | Returned type | Heap-allocating field |
|---|---|---|---|
| 254 (was) | `simulation.appendSimulationEvent(alloc, &store, &ctx, .{...})` | `event_store.EventRecord` | `.metadata` |
| 264 (was) | `store.append(alloc, AppendParams{...})` | `event_store.AppendResult` | `.record.metadata` |

`AppendResult.record.metadata` is heap-allocated by
`src/event_store/store.zig:duplicateFromParams()` (line 1368) via
`allocator.dupe(u8, metadata) catch ""`. The test discarded both records
(`_ = ...`), so the dupe was never freed. DebugAllocator reports
`tests/integration/sim01_04_simulation_mode_test.zig:254` and `...:264` as
leaked allocations.

**Pre-fix evidence** (`zig build test-integration-stage11-sim-xc04`):
```
+- run test 14 pass (14 total); 2 leaks
sim01_04_simulation_mode_test.zig:254:45: ... leaked
sim01_04_simulation_mode_test.zig:264:25: ... leaked
```

## 2. Fix scope (this design)

**ONE file changed:** `tests/integration/sim01_04_simulation_mode_test.zig`.
**Production source: untouched.** (No change to `src/event_store/store.zig`,
`src/simulation/tenant_store.zig`, or any other production module.)

### 2.1 Capture pattern

```zig
// Before:
_ = try simulation.appendSimulationEvent(alloc, &store, &ctx, .{...});
_ = try store.append(alloc, AppendParams{...});

// After:
const sim_appended_record = try simulation.appendSimulationEvent(alloc, &store, &ctx, .{...});
defer if (sim_appended_record.metadata.len > 0) alloc.free(sim_appended_record.metadata);

const real_appended = try store.append(alloc, AppendParams{...});
defer if (real_appended.record.metadata.len > 0) alloc.free(real_appended.record.metadata);
```

### 2.2 Why `len > 0` guard

`duplicateFromParams()` falls back to a string literal `""` on allocation
failure:

```zig
const owned_metadata = allocator.dupe(u8, metadata) catch "";
```

Calling `allocator.free` on a literal returned by the `catch` branch would
crash. The `.metadata.len > 0` guard skips the `free` only when `dupe` truly
returned an empty literal.

In the realistic case where `dupe` succeeds, `metadata` is `"{}"`
(two-byte heap allocation), which the guard correctly passes through.

### 2.3 Why both sites must be fixed in this design

GH-753's title points to line 264, but Step 00 scope expansion confirmed line
254 (`simulation.appendSimulationEvent`) leaks the same way: it returns
`result.record` directly (an `EventRecord`), and the test discards that
record entirely. Because the file, the heap path, and the allocation
ownership are all the same shape, fixing both lines in one test file is the
minimal correct change.

The other two adjacent leaks (in `adp06_pipeline_run_correlation_test.zig:271`
and `api03_instance_read_test.zig:988`) are filed separately as ISS-0694/GH-754
and ISS-0695/GH-755, respectively, and will be fixed in their own WF-03 runs
per core-directive "one issue, one run".

## 3. Signatures — before / after

Unchanged. `Store.append` and `simulation.appendSimulationEvent` keep their
existing signatures; the fix is purely in the call site.

## 4. Error taxonomy

No error variants added or changed.

## 5. Migration plan

None — no schema change.

## 6. Test plan

- `zig build test-integration-stage11-sim-xc04` must report `14/14 tests
  passed` AND `0 leaks` (DebugAllocator quiet) under `std.testing.allocator`.
- Full unit suite must remain green: `zig build test --summary all` exits 0
  with no new failures.
- `tools/lint_test_isolation.baseline.json` MUST NOT be modified. The 4
  pre-existing T030 entries for this file at lines 364/372/384/397 will
  shift by exactly +7 (the number of lines the fix adds above TC-SIM-03-01)
  to 371/379/391/404 — pure line-number drift, no new violations.

## 7. Files changed

```
M  tests/integration/sim01_04_simulation_mode_test.zig   # test-only fix
```

No production file is changed.

## 8. Risks

- None identified. The fix is a single-test capture-and-free that mirrors an
  existing pattern (`freeEventRecords` for `real_events`) already used in the
  same file, just for two more locals.
