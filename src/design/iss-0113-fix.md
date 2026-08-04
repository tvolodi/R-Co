# ISS-0113 Fix Design — Event-store idempotency fixtures contaminate shared integration state

**Issue ID:** ISS-0113  
**GitHub Issue:** [#376](https://github.com/tvolodi/R-Co/issues/376)  
**WF-03 Run:** WF03-gh376-20260804  
**Design Created:** 2026-08-04  
**Designer:** CODE-DESIGNER

---

## Module Purpose

Fix the integration test fixture contamination issue where deterministic `event_id` and `idempotency_key` values collide across test binaries sharing the same PostgreSQL test database (via `BPM_TEST_DB_URL`), producing PostgreSQL 23505 (unique_violation) on the `uq_event_idempotency` constraint and causing test failures.

This is a test-code-only fix (CATEGORY_D). No production source files are modified. No schema changes or migrations are required.

---

## Public Interface

### Existing Helper (tests/integration/helpers.zig)

```zig
/// Generate a fresh UUID v4 using CSPRNG for per-test isolation.
/// Replacement for deterministic generateTestUuid(seed) pattern.
/// Returns: [16]u8 UUID bytes
pub fn newUuid(self: *TestHarness) [16]u8
```

**Usage pattern:**
```zig
const event_id = harness.newUuid();
const idempotency_key_uuid = harness.newUuid();
const idempotency_key = try std.fmt.allocPrint(
    allocator,
    "test-idempotency-{s}",
    .{std.fmt.fmtSliceHexLower(&idempotency_key_uuid)},
);
defer allocator.free(idempotency_key);
```

**Note:** Each call to `newUuid()` returns a distinct value sourced from `std.crypto.random.bytes()`.

### Proposed Helper (Optional — tests/integration/helpers.zig)

```zig
/// Delete all event-store-related rows for one instance in FK dependency order.
/// ISS-0113 / ISS-0125: ensures cleanup completes without constraint violations.
/// All SQL errors are propagated (not swallowed).
/// Parameters:
///   - pool: *Pool — PostgreSQL connection pool
///   - instance_id_hex: []const u8 — UUID as hex string (e.g., "123e4567-...")
/// Returns: !void (propagates SQL errors)
pub fn cleanupInstance(pool: *Pool, instance_id_hex: []const u8) !void
```

**Cleanup ordering (canonical):**
1. `timers` (leaf)
2. `tasks` (leaf)
3. `events` (leaf)
4. `instance_definition_snapshots` (leaf)
5. `instance_projections` (parent)

**Note:** This helper is optional. If only one or two test files require cleanup, inline implementation is acceptable. The helper is provided for cases where multiple test files share identical cleanup logic.

---

## Root Cause Summary

Integration tests use a local helper `generateTestUuid(seed: u64)` with hardcoded seeds (1, 2, 3, etc.) to produce "per-test" UUIDs. However:

1. The same seed values appear across multiple test files that compile into separate binaries.
2. Multiple test binaries running concurrently (or sequentially without proper cleanup) insert events with identical `event_id` values.
3. PostgreSQL's `uq_event_idempotency` UNIQUE constraint rejects the duplicate, causing error 23505.
4. Cleanup logic may be incomplete or fail due to FK ordering violations (deleting parent rows before child rows).

This is the event-store-specific manifestation of the same deterministic-UUID contamination pattern that ISS-0121 (GitHub #387) addressed for general test fixtures.

---

## Resolution Strategy

**Three-part fix:**

1. **Migrate deterministic UUID generation to per-test randomness**  
   Replace all `generateTestUuid(seed)` calls with `TestHarness.newUuid()` in affected test files.

2. **Harden cleanup ordering**  
   Verify and fix cleanup logic to delete child rows before parent rows in FK dependency order.

3. **Enforce per-test UUID policy via lint**  
   Add T011 lint rule to flag deterministic-seed UUID generation patterns and prevent regression.

---

## Affected Files

| File | Test Cases | Current Pattern |
|---|---|---|
| `tests/integration/iss203_idempotency_keys_test.zig` | TC-ISS-203-01 through TC-ISS-203-05 | `generateTestUuid(seed)` with seeds 0x203_01_... through 0x203_05_... |
| `tests/integration/event_store_integration_test.zig` | TC-ES-03-01 | Likely similar deterministic seeds |
| `tests/integration/instance_error_test.zig` | TC-EE-08-04, TC-EE-10-04/05/06 | Likely similar deterministic seeds |
| `tests/integration/iss202_merge_atomicity_test.zig` | TC-ISS-202-01 | Likely similar deterministic seeds |
| `tests/integration/ext01_service_task_test.zig` | TC-EXT-01-INT-07 | Likely similar deterministic seeds |
| `tests/integration/helpers.zig` | (helper functions) | May need cleanup improvements (see Part 2) |

---

## Part 1: Migrate Deterministic UUID Generation to Per-Test Randomness

### 1.1 Remove Local `generateTestUuid` Functions

Every affected test file has its own local helper function similar to:

```zig
/// Generate a per-test UUID from a seed so tests are isolated.
fn generateTestUuid(seed: u64) [16]u8 {
    var uuid: [16]u8 = undefined;
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(std.mem.asBytes(&seed));
    const h = hasher.final();
    // ... (hash expansion + version/variant bits)
    return uuid;
}
```

**Action:** Delete this function from each affected file.

**Rationale:** The function's design is fundamentally incompatible with concurrent test execution in a shared database. Hashing a seed produces deterministic output — by definition, the same seed always yields the same UUID. Even when seeds differ across cases within one file, different files can use overlapping seeds, causing collisions.

---

### 1.2 Replace All Call Sites with `TestHarness.newUuid()`

For each call site that currently uses `generateTestUuid(seed)`:

**Before:**
```zig
const event_id = generateTestUuid(0x203_01_CAFE_BABE);
const idempotency_key = "test-idempotency-" ++ @intToHex(seed);
```

**After:**
```zig
const event_id = harness.newUuid();
const idempotency_key_uuid = harness.newUuid();
const idempotency_key = try std.fmt.allocPrint(
    allocator,
    "test-idempotency-{s}",
    .{std.fmt.fmtSliceHexLower(&idempotency_key_uuid)},
);
defer allocator.free(idempotency_key);
```

**Notes:**
- `harness` is the `*TestHarness` variable created via `var harness = try TestHarness.init(allocator); defer harness.deinit();` at test block scope.
- `TestHarness.newUuid()` returns a fresh `[16]u8` (UUID v4) sourced from `std.crypto.random.bytes()`. Each call yields a distinct value.
- The idempotency key is also randomized to avoid collisions on that field (though the primary constraint is on `event_id`).
- If the idempotency key needs to be reused within the same test case for verification, store it in a local variable instead of regenerating it.

**Pattern for hex string conversion (if needed for SQL parameters):**
```zig
var event_id_hex_buf: [36]u8 = undefined;
const event_id_hex = try std.fmt.bufPrint(&event_id_hex_buf, "{}", .{std.fmt.fmtSliceHexLower(&event_id)});
```

---

### 1.3 Per-File Migration Checklist

For each of the 5 affected test files:

1. Search for all occurrences of `generateTestUuid(`
2. Replace with `harness.newUuid()` per the pattern above
3. Delete the local `generateTestUuid` function definition
4. For any test case that verifies idempotency by re-using the same key:
   - Generate the UUID once at the start of the test
   - Store in a variable
   - Pass the same variable to both INSERT attempts (don't call `harness.newUuid()` twice)
5. If the test currently uses a seed as part of debug output (e.g., `std.debug.print("Using seed {x}\n", .{seed});`):
   - Replace with `std.debug.print("Using event_id {}\n", .{std.fmt.fmtSliceHexLower(&event_id)});`

**Expected change volume per file:** ~5-15 lines modified (1 function delete + N call sites updated).

---

## Part 2: Harden Cleanup Ordering

### 2.1 FK Dependency Order (Canonical)

The event-store schema has the following FK dependencies:

```
timers             → instance_projections (FK: instance_id)
tasks              → instance_projections (FK: instance_id)
events             → instance_projections (FK: instance_id)
                     (also has uq_event_idempotency UNIQUE constraint)
instance_definition_snapshots → instance_projections (FK: instance_id)
instance_projections (parent)
```

**Cleanup must delete in reverse dependency order:**
1. `timers` (leaf)
2. `tasks` (leaf)
3. `events` (leaf)
4. `instance_definition_snapshots` (leaf)
5. `instance_projections` (parent)

**Current implementation in `tests/integration/iss203_idempotency_keys_test.zig`:**
```zig
fn cleanupInstance(pool: *Pool, instance_id_hex: []const u8) !void {
    const conn = pool.acquire() catch |err| return err;
    defer pool.release(conn);
    try conn.exec("DELETE FROM timers WHERE instance_id = $1::uuid", &.{instance_id_hex});
    try conn.exec("DELETE FROM tasks WHERE instance_id = $1::uuid", &.{instance_id_hex});
    try conn.exec("DELETE FROM events WHERE instance_id = $1::uuid", &.{instance_id_hex});
    try conn.exec(
        "DELETE FROM instance_definition_snapshots WHERE instance_id = $1::uuid",
        &.{instance_id_hex},
    );
    try conn.exec(
        "DELETE FROM instance_projections WHERE instance_id = $1::uuid",
        &.{instance_id_hex},
    );
}
```

**Action:** Verify this ordering is present in all affected files. If any file has cleanup that deletes `instance_projections` before child tables, reorder it to match the canonical pattern above.

**ISS-0125 requirement:** All `try conn.exec(...)` calls must propagate errors (do NOT swallow with `catch |_|` or `catch |err| { log.warn(...); }`). Cleanup failures must surface visibly.

---

### 2.2 Per-File Cleanup Audit

For each of the 5 affected test files:

1. Locate cleanup logic (usually in a `cleanupInstance` or `cleanupFixture` function, or in test-block `defer` statements).
2. Verify FK ordering matches §2.1 canonical order.
3. If cleanup is inline (not factored into a helper):
   - **Option A:** Refactor to call a shared helper (e.g., add `helpers.cleanupInstance` to `tests/integration/helpers.zig` and call it from all tests).
   - **Option B:** Keep inline but add a comment referencing ISS-0113 and the canonical order.
4. Verify error propagation: every DELETE must use `try`, not `catch`.

**Expected change volume:** 0-5 lines per file (most files already have correct ordering per ISS-0125).

---

### 2.3 Optional: Promote Cleanup Helper to `tests/integration/helpers.zig`

If multiple test files duplicate the `cleanupInstance` pattern, consider adding a shared helper to `tests/integration/helpers.zig`:

**Proposed signature:**
```zig
/// Delete all event-store-related rows for one instance in FK dependency order.
/// ISS-0113 / ISS-0125: ensures cleanup completes without constraint violations.
/// All SQL errors are propagated (not swallowed).
pub fn cleanupInstance(pool: *Pool, instance_id_hex: []const u8) !void {
    const conn = pool.acquire() catch |err| return err;
    defer pool.release(conn);
    try conn.exec("DELETE FROM timers WHERE instance_id = $1::uuid", &.{instance_id_hex});
    try conn.exec("DELETE FROM tasks WHERE instance_id = $1::uuid", &.{instance_id_hex});
    try conn.exec("DELETE FROM events WHERE instance_id = $1::uuid", &.{instance_id_hex});
    try conn.exec(
        "DELETE FROM instance_definition_snapshots WHERE instance_id = $1::uuid",
        &.{instance_id_hex},
    );
    try conn.exec(
        "DELETE FROM instance_projections WHERE instance_id = $1::uuid",
        &.{instance_id_hex},
    );
}
```

Then replace all local `cleanupInstance` functions with calls to `helpers.cleanupInstance`.

**Note:** This is optional. If only one or two files have cleanup logic, inline is acceptable.

---

## Part 3: Enforce Per-Test UUID Policy via Lint

### 3.1 Add T011 Rule to `tools/lint_test_isolation.py`

**Purpose:** Flag local `generateTestUuid(seed)` functions or any UUID generation pattern that uses a hardcoded seed parameter.

**Rule specification:**

| Property | Value |
|---|---|
| **Code** | T011 |
| **Severity** | BLOCKER (same as T010) |
| **Description** | "Deterministic-seed UUID generation (via local `generateTestUuid` or similar) is forbidden. Use `TestHarness.newUuid()` for all per-test identifiers." |
| **Detection pattern** | Search for function definitions matching: <br> `fn generateTestUuid(seed: u64)` <br> or <br> `fn makeFixtureUuid(seed: u64)` <br> or any function with `seed` parameter that returns `[16]u8` |
| **Baseline exclusions** | None (all existing violations must be fixed before merging ISS-0113) |
| **Applies to** | `tests/integration/*.zig` |

**Pseudocode for detection:**
```python
# T011: deterministic-seed UUID generation
SEED_UUID_FUNC = re.compile(
    r'fn\s+(generateTestUuid|makeFixtureUuid|[A-Za-z_][A-Za-z0-9_]*)\s*\(\s*seed\s*:\s*u64\s*\)\s*\[\s*16\s*\]\s*u8'
)

for match in SEED_UUID_FUNC.finditer(content):
    func_name = match.group(1)
    line = find_line(content, match.start())
    issues.append(Issue(
        "BLOCKER", "T011", relative_path, line,
        f"Deterministic-seed UUID generation via '{func_name}(seed: u64)' is forbidden. "
        f"Use TestHarness.newUuid() instead."
    ))
```

**Verification:** After implementing the fix, `python tools/lint_test_isolation.py tests/integration` must report zero T011 findings.

---

### 3.2 Update Baseline (if needed)

If the lint baseline file (`tools/lint_test_isolation.baseline.json`) currently allowlists any T011 violations, remove those entries after the fix is implemented. T011 must have zero baseline exceptions.

---

## Verification Approach

### 4.1 Unit-Level Verification (Per Test File)

For each affected test file, run the test binary individually:

```bash
zig build test-integration-<module>  # e.g., test-integration-iss203
```

**Success criteria:**
- All test cases (TC-ISS-203-01 through TC-ISS-203-05, TC-ES-03-01, etc.) PASS individually.
- No PostgreSQL 23505 errors in output.
- No cleanup failures (C23503 "still referenced by" errors).

---

### 4.2 Aggregate Verification (Full Integration Suite)

Run the entire integration test suite:

```bash
zig build test-integration
```

**Success criteria:**
- All 14 affected test cases PASS.
- No 23505 errors anywhere in the output.
- Total test count increases by 0 (no new tests added, only fixes).

---

### 4.3 Database State Verification (Leak Detection)

After the full integration run completes, verify no event rows remain leaked:

```sql
SELECT count(*) FROM events
WHERE instance_id NOT IN (SELECT instance_id FROM instance_projections);
```

**Expected result:** 0 rows.

If this query returns >0, cleanup is still incomplete. Investigate which test case(s) did not clean up properly.

---

### 4.4 Lint Verification

Run the lint tool against all affected files:

```bash
python tools/lint_test_isolation.py tests/integration
```

**Success criteria:**
- Zero T010 findings (hardcoded UUID literals).
- Zero T011 findings (deterministic-seed UUID generation).
- Total BLOCKER count = 0.

---

## Open Questions

None. The resolution strategy is fully determined from the Step 1 diagnosis.

---

## Dependencies

### Upstream Dependencies (Code This Fix Calls)

- `tests/integration/helpers.zig` — `TestHarness.newUuid()` helper (already exists per ISS-0121).
- `bpm.uuid.generateUuidV4BytesInto()` — underlying CSPRNG (already exists).
- PostgreSQL connection pool (`bpm.pool.Pool`) — no changes.

### Downstream Dependencies (Code That Calls This Fix)

None. This is a test-code-only fix. No production callers.

---

## State Transitions

Not applicable. This fix does not modify any state machines or workflow logic.

---

## Error Taxonomy

### New Errors This Fix Handles

None (this is not a feature; it fixes existing test failures).

### Existing Errors Eliminated by This Fix

- PostgreSQL 23505 (unique_violation) on `uq_event_idempotency` — eliminated by removing deterministic UUID generation.
- PostgreSQL 23503 (foreign_key_violation) during cleanup — eliminated by enforcing FK-ordered deletes.

---

## Change Summary

| Category | Count | Notes |
|---|---|---|
| Test files modified | 5 | `iss203_*.zig`, `event_store_*.zig`, `instance_error_*.zig`, `iss202_*.zig`, `ext01_*.zig` |
| Helper file modified | 1 | `tests/integration/helpers.zig` (optional cleanup helper promotion) |
| Lint rule added | 1 | T011 in `tools/lint_test_isolation.py` |
| Lines changed | ~100-150 | ~20-30 lines per test file + lint rule (~50 lines) |
| Schema changes | 0 | Test-code-only fix |
| Migrations | 0 | No schema changes |

---

## Related Issues

- **ISS-0121** (GitHub #387) — Hardcoded UUID violations (T010) across 100+ integration test files. Resolution: `TestHarness.newUuid()` helper added. ISS-0113 is the event-store-specific residual.
- **ISS-0125** (GitHub #391) — Cleanup FK error propagation required for diagnosis. Ensures cleanup failures surface visibly.
- **ISS-0100** (GitHub #357) — Integration test fixtures leak production-typed tenants. Similar shared-DB contamination pattern.

---

## Acceptance Criteria (from Handoff)

1. ✅ Design artefact created at `src/design/iss-0113-fix.md`
2. ✅ All affected files from diagnosis have fix specification
3. ✅ Helper function signature specified (`TestHarness.newUuid()` — already exists)
4. ✅ Lint rule T011 specification included
5. ✅ No implementation code in the design (only function signatures, patterns, pseudocode)

---

## Next Action

Route to CODE-DESIGN-VALIDATOR (Step 2b) for validation before implementation.
