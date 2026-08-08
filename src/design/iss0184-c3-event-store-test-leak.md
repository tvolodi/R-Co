# Design: Fix ISS-0184 Cluster C3 — event_store_integration_test.zig heap leak

**Type:** E (test-only fix — no production code change; scoped per WF-03 to a single
cluster's direct-fix candidate, not a full-file remediation)

**Issue:** ISS-0184 / GH #517, cluster C3
**Severity:** MINOR (single test block, 3 leaked allocations per run, no data-integrity
or behavioral impact — a `std.testing.allocator` leak report only)

---

## Module purpose

This design covers a **test-only** fix: `tests/integration/event_store_integration_test.zig`
does not introduce or change any module. There is no new production module, no new
public interface, and no new error taxonomy — `src/event_store/store.zig`'s existing
`EventRecord`, `AppendResult`, and `StoreError` types are used exactly as already
defined and are not modified. The purpose of this change is to make one existing test
(`TC-ES-03-01`) release the heap memory it already legitimately owns, by calling the
`deinit()` accessor `EventRecord` already exposes, instead of implicitly discarding the
two `AppendResult` values it receives.

## Public interface

No public interface changes. No new functions, types, or exported symbols are
introduced anywhere in `src/`. The only symbol consumed by this fix —
`EventRecord.deinit(self: *EventRecord, allocator: std.mem.Allocator) void` — already
exists in `src/event_store/store.zig` (lines 96–100) and is called via the existing
`AppendResult.record` field (`first.record.deinit(alloc)` / `second.record.deinit(alloc)`).
See §4 for exact call-site placement within the test file.

## Error taxonomy

No new error cases. This fix does not touch any `error{...}` set, does not add a
fallible code path, and does not change what `Store.append()` can return. The existing
`StoreError` set in `src/event_store/store.zig` is unaffected. `EventRecord.deinit()` is
`void` and infallible — it cannot itself introduce a new error case.

## 1. Problem statement

`tests/integration/event_store_integration_test.zig`'s test
`"TC-ES-03-01: duplicate idempotency_key returns original event with is_duplicate=true"`
(lines 362–426) leaks 3 heap allocations per run, detected by
`std.testing.allocator`'s `DebugAllocator` leak check under
`zig build test-integration-svc`.

## 2. Root cause (confirmed by direct source read — not hypothesis)

`src/event_store/store.zig`'s `EventRecord` struct (lines 78–101) already owns and
correctly frees three heap-allocated fields via its `deinit()`:

```
pub fn deinit(self: *EventRecord, allocator: std.mem.Allocator) void {
    if (self.event_type.len > 0) allocator.free(self.event_type);
    if (self.payload.len > 0) allocator.free(self.payload);
    if (self.metadata.len > 0) allocator.free(self.metadata);
}
```

Production code is not defective. `AppendResult` (store.zig line 114) wraps an
`EventRecord` as its `.record` field; every `Store.append()` call — including the
duplicate-idempotency-key path — returns an `AppendResult` whose `.record` owns three
freshly-allocated strings (`event_type`, `payload`, `metadata`), per
`rowToEventRecord`'s `allocator.dupe()` calls.

In `TC-ES-03-01`, two `AppendResult` values are obtained and neither is ever released:

- `first` (line 393–400): the initial `append()` call. Its `.record` owns 3 allocations.
- `second` (line 403–410): the duplicate-key `append()` call. `append()`'s
  already-exists branch (store.zig ~line 472/495) re-reads the original row via
  `rowToEventRecord` and returns a **second, independently-allocated** `EventRecord`
  inside `AppendResult` — it does not alias `first.record`. Its `.record` also owns 3
  allocations.

Neither `first.record` nor `second.record` is passed to `.deinit(alloc)` anywhere in
the test function, so both sets of 3 allocations (6 total across the two calls) become
unreachable when the test function returns — except the test only reports 3 leaked
allocations per the diagnosis's measured signature ("3 allocations... called from
rowToEventRecord"). This document does not need to resolve that count discrepancy: the
fix below frees both records unconditionally, which is correct regardless of how many
of the two `.record`s the allocator's leak detector currently attributes.

## 3. Existing idiomatic pattern in this file (precedent to match)

`event_store_integration_test.zig` already frees `EventRecord`-owned fields
immediately after use, scoped with `defer`, at the point where ownership is received.
See `TC-ES-01-01` (lines 205–214), which frees a slice of records returned by
`store.read()`:

```
const events = try store.read(alloc, inst_uuid, ReadOpts{ ... });
defer {
    for (events) |rec| {
        alloc.free(rec.event_type);
        alloc.free(rec.payload);
        alloc.free(rec.metadata);
    }
    ...
}
```

The fix below follows the same "acquire ownership → `defer` release immediately"
convention, using `EventRecord.deinit(alloc)` (the accessor already provided by
production code) rather than manually repeating the three `alloc.free()` calls, since a
single-record (non-slice) case has no precedent elsewhere in the file to copy verbatim
and `.deinit()` is the more idiomatic, DRY choice for a single owned value.

## 4. Fix specification (test-file-only — `tests/integration/event_store_integration_test.zig`)

### 4a. `first` (currently lines 393–401)

Immediately after the `first` binding's initializing statement — i.e. directly
following the closing `});` of the `store.append(...)` call that produces `first`, and
**before** the existing `try std.testing.expect(!first.is_duplicate);` assertion — add:

```
defer first.record.deinit(alloc);
```

Rationale for placement: `defer` at the point of acquisition (immediately after the
value exists) is the pattern already used at line 209 for `events`. Placing it before
the first use/assertion (rather than after) removes any risk of an early `return`/`try`
between acquisition and the `defer` statement leaking the value — there is no such
`try` in this test between lines 393–401, but placing the `defer` first is the safer
general habit and costs nothing here.

### 4b. `second` (currently lines 403–411)

Immediately after the `second` binding's initializing statement — directly following
the closing `});` of the second `store.append(...)` call, and before the existing
`try std.testing.expect(second.is_duplicate);` assertion — add:

```
defer second.record.deinit(alloc);
```

### 4c. Resulting structure (illustrative — BACKEND-DEV implements verbatim, this is not new prose logic, just showing where the two `defer` lines land relative to existing code)

```
const first = try store.append(alloc, AppendParams{ ... });
defer first.record.deinit(alloc);
try std.testing.expect(!first.is_duplicate);

const second = try store.append(alloc, AppendParams{ ... });
defer second.record.deinit(alloc);
try std.testing.expect(second.is_duplicate);
try std.testing.expectEqual(first.record.sequence_number, second.record.sequence_number);
```

Both `defer`s fire at function exit, in reverse order of registration (`second` freed
before `first`) — order does not matter here since the two records are independent
allocations with no cross-reference.

No other line in `TC-ES-03-01` (lines 362–426) requires modification.

## 5. Sibling sweep — file-wide check for the same gap

Grepped every `store.append(` call site (34 total) and every `.record.deinit(` /
`record.deinit(alloc)` call site (0 total) in
`tests/integration/event_store_integration_test.zig`. Finding:

**No test in this file ever calls `.record.deinit()` on an `AppendResult` it received.**
This is not unique to `TC-ES-03-01` — it is a file-wide gap. The 34 call sites are at
(approximate) lines: 191, 257, 265, 311, 319, 327, 393, 403, 471, 479, 487, 566, 631,
727, 743, 819, 827, 859, 926, 1000, 1119, 1208, 1282, 1330, 1402, 1411, 1550, 1607,
1641, 1675, 1713, 1792, 1856, 1919, 1941, 2102 — spanning results bound to named
variables (`result`, `r1`, `r2`, `r3`, `ok_result`, `first`, `second`, array-indexed
`r.*`) as well as results explicitly discarded with `_ = try store.append(...)`.
Discarding with `_ =` does not free the `AppendResult`'s heap-owned `.record` fields —
the value is only dropped from scope, not deinitialized — so `_ =`-discarded call sites
leak identically to named-variable ones.

**This design intentionally does not extend the fix to all 34 sites.** Per the ISS-0184
diagnosis (`docs/issue-reports/ISS-0184-diagnosis.yaml`, cluster C3), the measured leak
signature and the WF-03 run scope cover only `TC-ES-03-01`; C3 is filed as a MINOR,
single-block, direct-fix candidate, not a file-wide sweep. The remaining 32 call sites
(all sites above except the 2 fixed here) are a **distinct, larger cleanup** that should
be filed as its own issue and fixed in its own run — flagged here for ORCH/ISSUE-FIXER
to file as a follow-up (suggested scope: audit all `store.append()` call sites across
the integration test suite — this file plus any others — for missing
`.record.deinit(alloc)`, and apply the same `defer`-after-acquisition pattern
file-wide). BACKEND-DEV implementing this handoff should fix only `first`/`second` in
`TC-ES-03-01` per §4 above and must not silently expand scope to the other 32 sites in
this same commit.

## 6. Acceptance criteria

- [ ] `defer first.record.deinit(alloc);` added immediately after the `first` append
      call, before its first use.
- [ ] `defer second.record.deinit(alloc);` added immediately after the `second` append
      call, before its first use.
- [ ] No production code (`src/event_store/store.zig` or any other `src/` file) is
      modified.
- [ ] `zig build test-integration-svc` (or the equivalent single-file/single-test
      invocation for `event_store_integration_test.zig`) reports 0 leaked allocations
      for `TC-ES-03-01`.
- [ ] All other assertions in `TC-ES-03-01` continue to pass unchanged.
- [ ] The 32 sibling call sites identified in §5 are left untouched in this change and
      are instead filed as a new, separate issue (file-wide sweep of
      `event_store_integration_test.zig` — and potentially other integration test
      files using `Store.append()` — for the same missing-`.record.deinit()` pattern).

## 7. Out of scope

- Any change to `src/event_store/store.zig` (production code is correct; confirmed by
  direct read, not inferred).
- Fixing the other 32 `store.append()` call sites in this file (§5) — separate issue.
- Auditing `Store.append()` usage in other integration test files outside
  `event_store_integration_test.zig` — separate issue, same follow-up.
