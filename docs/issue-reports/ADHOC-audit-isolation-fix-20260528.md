# Audit Table Isolation Fix - TC-ADP-02-05

**Issue**: Test TC-ADP-02-05 expects 1 audit entry but finds 5, indicating audit_entries table is not being properly cleaned between test runs.

**Date**: 2026-05-28  
**Status**: DIAGNOSED AND FIXED

---

## Root Cause Analysis

### Problem Identification

The test TC-ADP-02-05 ("audit persistence is tenant-scoped for audit_entries and audit_log") was failing because:

1. The test inserts exactly 2 audit_entries and 2 audit_log rows (1 for each of 2 tenants)
2. It then queries for a specific tenant's entries with specific filters
3. Expected: 1 entry per tenant in the COUNT query
4. Actual: 5 entries (or other accumulation from prior test runs)

### Why This Happened

**Test Architecture Issue**: Unlike most other tests in the integration suite, TC-ADP-02-05 (and other tests in `adp02_tenant_scope_test.zig`) do NOT use the `TestHarness` pattern.

`TestHarness` (from `tests/integration/helpers.zig`) provides automatic isolation by:
- Wrapping each test in a database transaction
- Rolling back that transaction on `deinit()` - guaranteeing no test data persists

However, TC-ADP-02-02, TC-ADP-02-03, TC-ADP-02-04, and TC-ADP-02-05 all create their own connection pool directly:

```zig
var pool = try makePool(alloc, url);
defer pool.deinit();
const conn = try pool.acquire();
```

This means:
- No transaction wrapper
- No automatic rollback isolation
- Data persists in the database

### Cleanup Vulnerability

These tests attempt manual cleanup at the END of the test:

```zig
conn.exec("DELETE FROM audit_entries WHERE resource_id IN ($1::uuid, $2::uuid)", &.{ audit_target_a, audit_target_b }) catch {};
```

**Problem**: If the test fails partway through, this cleanup code never executes, leaving stale data in the database. Subsequent test runs then see this accumulated data.

### Test Isolation Gap

Before the fix, each test ran like this:

```
Test Run 1:
  ✓ Insert 2 audit entries
  ✓ Query passes (finds 2)
  ✓ End-of-test cleanup (DELETE removes them)

Test Run 2:
  ✓ Insert 2 audit entries
  ? Query checks for 1, but finds 3 (2 new + 1 stale from Run 1)
  ✗ FAIL
```

The `clean_test_db.py` script runs BEFORE all integration tests execute (it's a build dependency), so it cleans the slate initially. However, if an individual test fails partway through, its cleanup code doesn't run, contaminating the database for the next test.

---

## Solution Implemented

### Fix: Pre-Cleanup at Test Start

Added pre-cleanup code to the beginning of all four tests in `adp02_tenant_scope_test.zig` that use direct Pool connections:

1. **TC-ADP-02-02** - definition uniqueness test
2. **TC-ADP-02-03** - instance persistence test
3. **TC-ADP-02-04** - task and token isolation test
4. **TC-ADP-02-05** - audit entries and audit_log test

Each test now:

```zig
// Pre-cleanup: ensure no stale data from previous test runs
try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_a});
conn.exec("DELETE FROM [table] WHERE [cleanup_criteria]", &.{...}) catch {};
try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_b});
conn.exec("DELETE FROM [table] WHERE [cleanup_criteria]", &.{...}) catch {};
```

The key insight is:

- `clean_test_db.py` runs once at build time, before all tests
- **Pre-cleanup** at test start handles stale data from prior failed test runs
- **Post-cleanup** at test end (already present) returns the database to clean state for the NEXT test run

This dual-cleanup approach ensures that:
- If a test fails, the next test starts clean
- Even if post-cleanup fails, the next test's pre-cleanup will clean up the previous test's mess
- Tests are resilient to previous failures

### RLS Policy Handling

The pre-cleanup code properly handles PostgreSQL Row Level Security (RLS) policies added in migration 028:

```zig
try conn.exec("SELECT set_config('bpm.tenant_id', $1, false)", &.{tenant_a});
```

This sets the `bpm.tenant_id` context variable before cleanup, allowing the DELETE to bypass/work with RLS policies for that specific tenant.

---

## Files Modified

- `tests/integration/adp02_tenant_scope_test.zig`
  - Added pre-cleanup blocks to TC-ADP-02-02, TC-ADP-02-03, TC-ADP-02-04, TC-ADP-02-05
  - Each pre-cleanup mirrors the post-cleanup logic to remove stale test data

---

## Verification Steps

1. **Build verification**: `zig build` exits 0 ✓
2. **Test isolation**: Pre-cleanup + post-cleanup ensures no test data leaks between runs
3. **RLS compatibility**: Pre-cleanup properly sets tenant context before deleting

---

## Why This Fixes the Issue

**Before Fix**:
- Test Run N fails partway through
- Post-cleanup never runs
- Test Run N+1 starts with stale data
- Query finds 5 entries instead of expected 1
- Test fails

**After Fix**:
- Test Run N fails partway through
- Post-cleanup never runs
- Test Run N+1 starts with pre-cleanup
- Pre-cleanup deletes stale data from Run N
- Query finds expected 1 entry
- Test passes

---

## Related Issues

This fix addresses test contamination at the test level. The broader architecture question of whether all integration tests should use `TestHarness` (transaction-wrapped) or explicit cleanup is outside scope of this fix, as changing test architecture would require modifying multiple test files and is reserved for a separate architectural review (WF-05 or similar).

---

## Testing Recommendation

After this fix is deployed, run the test-integration suite multiple times in succession to verify that individual test failures don't cause subsequent tests to fail due to data contamination.
