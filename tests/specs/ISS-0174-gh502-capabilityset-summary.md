# Test Spec: ISS-0174 / GH-502 — `CapabilitySet.summary()` regression lock

**Issue:** [GitHub #502 — `src/lua/capabilities.zig` carries a stale `std.ArrayList(u8).init(allocator)` call that is invisible to `zig build test-lua` because `src/lua_test_root.zig` pins the file with a bare type reference](https://github.com/tvolodi/R-Co/issues/502)
**Severity:** MAJOR (production source does not compile under Zig 0.16; test target reports green; latent regression class)
**Component:** `src/lua/capabilities.zig` (`CapabilitySet.summary`) + `src/lua_test_root.zig` (new test block per `src/design/iss0174-gh502-capabilityset-summary-migration.md` §4)
**Test layer:** unit (Zig test block; reached by `zig build test-lua` via `src/lua_test_root.zig`)
**Spec author:** CODE-DESIGNER (WF03-GH502-20260808 Step 2)

---

## Purpose

The migration of `CapabilitySet.summary()` from Zig 0.15 managed `ArrayList` to Zig 0.16 unmanaged `ArrayList` (per `src/design/iss0174-gh502-capabilityset-summary-migration.md` §5) is invisible to the build until something actually invokes the function. `src/lua_test_root.zig:95` previously pinned the file with a bare type reference (`_ = lua.capabilities.CapabilitySet;`), which forces neither field-type resolution nor function-body analysis — the exact failure mode ISS-0172 / GH #500 documented.

These five test cases lock in both the **public contract** of `summary()` (what callers can rely on) and the **build-wiring** invariant (the body is genuinely analysed by `zig build test-lua`):

| Test case | Invariant |
|---|---|
| **TC-CS-01** | Empty grants → literal `"(none)"`. |
| **TC-CS-02** | Single grant → grant string verbatim. |
| **TC-CS-03** | Multiple grants → lexicographically sorted, comma-separated. |
| **TC-CS-04** | Allocator is honoured: `std.testing.allocator` is invoked; the leak detector on `zig build test-lua` returns zero leaks. |
| **TC-CS-05** | Ownership is on the caller: the returned slice is heap-allocated and MUST be `free`d. |

Together, TC-CS-01 through TC-CS-05 close the GH-502 acceptance criterion _"`src/lua/capabilities.zig` compiles under Zig 0.16 with function bodies genuinely analysed"_ AND the criterion _"A build target CALLS `CapabilitySet.summary()` and asserts on its output"_.

---

## Requirements covered

| Test case | Acceptance criterion (from diagnosis YAML) |
|---|---|
| TC-CS-01 | #3 (empty branch renders correctly) |
| TC-CS-02 | #3 (single-grant branch renders correctly) |
| TC-CS-03 | #3 (multi-grant branch renders deterministically) |
| TC-CS-04 | #3 + build-wiring (the call runs against `std.testing.allocator`, so the body is genuinely analysed) |
| TC-CS-05 | #3 (ownership contract preserved) |

The deliberate-mutation verification (criterion #4) is documented in the design §6; it is a one-shot BACKEND-DEV procedure in Step 3, not a permanent test case.

---

## Test Cases

### TC-CS-01: Empty grants → `(none)`

**Given** an empty `CapabilitySet` (no grants added),
**When** `summary(allocator)` is called,
**Then** the returned slice equals the literal `"(none)"`, has length 6, and `allocator.free(slice)` is a no-op.

```zig
{
    var caps = lua.capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();

    const slice = try caps.summary(std.testing.allocator);
    defer std.testing.allocator.free(slice);

    try std.testing.expectEqualStrings("(none)", slice);
    try std.testing.expectEqual(@as(usize, 6), slice.len);
}
```

**Fails if** the migration replaces `return allocator.dupe(u8, "(none)");` with a different short-circuit (e.g. an empty string), or if the body returns an `error.OutOfMemory` because the empty branch is dropped.

---

### TC-CS-02: Single grant → grant verbatim

**Given** a `CapabilitySet` with exactly one grant `"service:call:payment"`,
**When** `summary(allocator)` is called,
**Then** the returned slice equals `"service:call:payment"`, has length 21, and contains no `, ` separator.

```zig
{
    var caps = lua.capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    try caps.add("service:call:payment");

    const slice = try caps.summary(std.testing.allocator);
    defer std.testing.allocator.free(slice);

    try std.testing.expectEqualStrings("service:call:payment", slice);
    try std.testing.expectEqual(@as(usize, 21), slice.len);
    try std.testing.expect(std.mem.indexOf(u8, slice, ",") == null);
}
```

**Fails if** the migration introduces a trailing separator, or wraps the single grant in `[]`, or returns the grant joined with itself.

---

### TC-CS-03: Multiple grants → sorted, comma-separated

**Given** a `CapabilitySet` with three grants added in this order: `"variable:write"`, `"service:call:payment"`, `"audit:log"`,
**When** `summary(allocator)` is called,
**Then** the returned slice equals `"audit:log, service:call:payment, variable:write"` (sorted lexicographically, joined by `", "`).

```zig
{
    var caps = lua.capabilities.CapabilitySet.init(std.testing.allocator);
    defer caps.deinit();
    try caps.add("variable:write");
    try caps.add("service:call:payment");
    try caps.add("audit:log");

    const slice = try caps.summary(std.testing.allocator);
    defer std.testing.allocator.free(slice);

    try std.testing.expectEqualStrings(
        "audit:log, service:call:payment, variable:write",
        slice,
    );
}
```

**Fails if** the body iterates `std.StringHashMap` directly without sorting (the assertion expects lexicographic order, not HashMap iteration order). Also fails if the join separator is anything other than `", "` (e.g. `";"`, `",, "`, missing separator).

**Determinism note (from design §3a):** `std.StringHashMap` iteration order is undefined across Zig versions and allocator instances. The migration MUST sort the keys before joining. The TC-CS-03 assertion pins the sorted order; without the sort, this assertion is non-deterministic and the test would either flake or fail outright.

---

### TC-CS-04: Allocator honoured

**Given** the `std.testing.allocator` is the allocator passed to `summary()`,
**When** the four previous test cases complete,
**Then** `zig build test-lua`'s leak detector reports **zero leaks**.

This test case is **implicit**: there is no explicit `try std.testing.expect(...)` for it. The proof is structural — every `try caps.summary(std.testing.allocator); defer std.testing.allocator.free(slice);` pair in TC-CS-01 through TC-CS-03 only succeeds if `std.testing.allocator` actually owns the returned slice. If `summary()` were returning a stack-allocated buffer, the `defer free` would corrupt the heap; if it were returning a borrowed slice, the `defer free` would corrupt the lender.

**Fails if** any TC-CS-01..03 leaks its slice. The Zig test runner's leak detector prints a per-test summary and the run exits non-zero on a leak.

---

### TC-CS-05: Caller owns the returned slice

**Given** a `CapabilitySet` with two grants,
**When** `summary(allocator)` is called and the slice is `free`d before the test scope exits,
**Then** the `free` succeeds without error and no leak is reported.

This is also **implicit** (same structural proof as TC-CS-04). The contract is documented in the new doc comment on `summary()` (see design §1, lines 46–54): _"Caller owns the returned memory."_ A future maintainer who changed `summary()` to return a stack-allocated slice (no `free` needed) would silently break this contract — TC-CS-05 catches it by requiring the explicit `free` in TC-CS-01..03.

**Fails if** `summary()` is changed to return a borrowed / stack-allocated slice. The `defer std.testing.allocator.free(slice)` would then either free memory the test does not own (catastrophic corruption caught by the test runner immediately) or double-free (also caught immediately). Either outcome is a test failure.

---

## Implementation

- `src/lua_test_root.zig` — new `test "ISS-0174 / GH-502: CapabilitySet.summary() compiles, runs, and renders both branches"` block, appended after the existing `ISS-0153` block (per design §4).
- The test block calls `lua.capabilities.CapabilitySet.init`, `CapabilitySet.add`, `CapabilitySet.summary`, and `CapabilitySet.deinit` against `std.testing.allocator` (real allocator; no mocks, no stubs — per the project's TESTING DIRECTIVE T-1).
- Wired into `zig build test-lua` (and therefore `zig build test`) via the existing import in `src/lua_test_root.zig`. No `build.zig` change is needed.

**ISS-0172 / GH #500 caveat, honoured deliberately.** This block calls `summary()` for real, not via `refAllDecls` (which is shallow over containers). The deliberate-mutation procedure in design §6 verifies the body is genuinely analysed: inject `const _bad: u32 = "definitely not a u32";` into the body of `summary()`, run `zig build test-lua`, confirm the target exits non-zero with a type error citing the injected statement, revert the mutation, confirm green.

---

## Traceability

- GH-502 acceptance criterion #1 (compiles under Zig 0.16 with body analysed): TC-CS-01..05 + deliberate-mutation procedure in design §6.
- GH-502 acceptance criterion #2 (migrated to unmanaged API): design §5 (S1–S5 substitution rules); verified by `zig build test-lua` exiting 0.
- GH-502 acceptance criterion #3 (real call asserts on output): TC-CS-01..03.
- GH-502 acceptance criterion #4 (deliberate-mutation goes red): design §6; BACKEND-DEV Step 3 procedure.
- GH-502 acceptance criterion #5 (decision recorded): diagnosis YAML `fix_plan.decision` (RETAIN); design header ("decision: RETAIN").
- GH-502 acceptance criterion #6 (function-level census): deferred to follow-up run; this spec delivers the `summary()` data point.
