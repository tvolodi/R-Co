# WF-04 Step 3 — Integration Test Report

**Run ID:** WF04-full-20260523  
**Step:** 3 — Integration Tests  
**Agent:** TEST-RUNNER  
**Timestamp:** 2026-05-23T06:23:29Z  
**Database:** postgres://bpm:bpm@localhost:5433/bpm_test (PostgreSQL 15 Alpine)  
**Environment:** Windows, Zig 0.16.0  

---

## Summary

| Metric | Count |
|---|---|
| Total tests | 146 |
| Passed | 125 |
| Failed | 21 |
| Memory leaks | 2 |

**Overall verdict: FAIL** — 21 failures include BLOCKER (MUST requirements) and MAJOR (SHOULD requirements).

---

## Pre-flight

- `docker-compose ps`: db_test container **healthy**, running on port 5433
- `zig build migrate`: All 14 migrations already applied (skipped)
- `zig build test-integration` **compile error** initially: `SnapshotStore` missing `init()` — fixed by adding `pub fn init(pool: *Pool) SnapshotStore` to `src/definition/snapshot.zig`

---

## Failure Analysis

### Root Cause Clusters

#### Cluster A: DuplicateNameVersion on DefinitionStore.create() — 14 tests

Every PD-08 snapshot test and many EE-09/EE-10 tests fail at `src/definition/store.zig:264`:
```
if (insert_rows.rows.len == 0) return DefinitionError.DuplicateNameVersion;
```
This indicates the definition `(name, version)` pair already exists in the database. Likely causes:
1. Test cleanup between tests is not properly executed (cleanupDefinition uses name+version but tests may use same names)
2. Pool.acquire() may silently fail, causing cleanup to be skipped
3. Transaction rollback not properly isolating test data

**Affected tests:**
- TC-PD-08-01, TC-PD-08-02, TC-PD-08-03, TC-PD-08-06, TC-PD-08-07 (5 tests, PD-08 MUST)
- TC-EE-09-01, TC-EE-09-02, TC-EE-09-04, TC-EE-09-05 (4 tests, EE-09 MUST)
- TC-EE-10-04, TC-EE-10-05, TC-EE-10-06 (3 tests, EE-10 MUST)

#### Cluster B: GraphValidationFailed on DefinitionStore.create() — 3 tests

EE-10 error tests fail at `src/definition/store.zig:208`:
```
return DefinitionError.GraphValidationFailed;
```
The test-provided graphs for error-testing scenarios are being rejected by the graph validator. This may be due to stricter validation rules that don't permit the intentionally-broken graphs used in these tests.

**Affected tests:**
- TC-EE-10-01, TC-EE-10-02, TC-EE-10-03 (3 tests, EE-10 MUST)

#### Cluster C: PostgreSQL ServerError during cancelInstance() — 3 tests

API-03 instance read tests fail with `PgError.ServerError` during `cancelInstance()`:
```
C:\Users\tvolo\dev\ai-dala\My-Fab\vendor\pg\pg.zig:306:36: readUntilReady
    if (got_error) return PgError.ServerError;
```
**Affected tests:**
- TC-API-03-05, TC-API-03-15, TC-API-03-18 (3 tests, API-03 SHOULD)

#### Cluster D: Individual failures

- **TC-EE-01-06**: `ADDRESS_ALREADY_EXISTS` (NTSTATUS=0xc000020a) during pool connection — pool exhaustion or Windows socket error. (EE-01 MUST)
- **TC-API-02-29**: `AlreadyActive` not returned — activate() returns success instead of error when definition is already ACTIVE. Also leaks 2 memory allocations. (API-02 SHOULD)
- **TC-API-03-01**: `tasks.len >= 1` assertion failed — getById did not return expected task count. (API-03 SHOULD)

---

## Detailed Failure List

| # | Test ID | Severity | Requirement | Error Type | Description |
|---|---|---|---|---|---|
| 1 | TC-PD-08-01 | BLOCKER | PD-08 | DuplicateNameVersion | SnapshotStore.create happy path fails — definition already exists |
| 2 | TC-PD-08-02 | BLOCKER | PD-08 | DuplicateNameVersion | SnapshotStore.getByInstanceId after definition update fails |
| 3 | TC-PD-08-03 | BLOCKER | PD-08 | DuplicateNameVersion | SnapshotStore.create duplicate instance_id test fails |
| 4 | TC-PD-08-06 | BLOCKER | PD-08 | DuplicateNameVersion | SnapshotStore round-trip node types test fails |
| 5 | TC-PD-08-07 | BLOCKER | PD-08 | DuplicateNameVersion | Two snapshot independence test fails |
| 6 | TC-EE-01-06 | BLOCKER | EE-01 | Pool/Connection | ADDRESS_ALREADY_EXISTS — pool exhaustion or socket error |
| 7 | TC-EE-09-01 | BLOCKER | EE-09 | DuplicateNameVersion | Variable merge — new key insert fails |
| 8 | TC-EE-09-02 | BLOCKER | EE-09 | DuplicateNameVersion | Variable merge — overwrite test fails |
| 9 | TC-EE-09-04 | BLOCKER | EE-09 | DuplicateNameVersion | Variable merge — schema violation test fails |
| 10 | TC-EE-09-05 | BLOCKER | EE-09 | DuplicateNameVersion | Variable merge — empty output_variables test fails |
| 11 | TC-EE-10-01 | BLOCKER | EE-10 | GraphValidationFailed | Gateway no-match ERROR transition test fails |
| 12 | TC-EE-10-02 | BLOCKER | EE-10 | GraphValidationFailed | Schema violation ERROR transition test fails |
| 13 | TC-EE-10-03 | BLOCKER | EE-10 | GraphValidationFailed | ERROR instance reject task completion test fails |
| 14 | TC-EE-10-04 | BLOCKER | EE-10 | DuplicateNameVersion | ERROR transition atomicity test fails |
| 15 | TC-EE-10-05 | BLOCKER | EE-10 | DuplicateNameVersion | Concurrent ERROR race test fails |
| 16 | TC-EE-10-06 | BLOCKER | EE-10 | DuplicateNameVersion | EXECUTION_ERROR payload test fails |
| 17 | TC-API-02-29 | MAJOR | API-02 | AlreadyActive | activate() on already-ACTIVE definition returns success (plus 2 leaks) |
| 18 | TC-API-03-01 | MAJOR | API-03 | Assertion | getById ACTIVE — tasks.len >= 1 assertion failed |
| 19 | TC-API-03-05 | MAJOR | API-03 | ServerError | getById CANCELLED — cancelInstance() triggers PgError |
| 20 | TC-API-03-15 | MAJOR | API-03 | ServerError | listInstances status=ACTIVE — cancelInstance() triggers PgError |
| 21 | TC-API-03-18 | MAJOR | API-03 | ServerError | listInstances combined filters — cancelInstance() triggers PgError |

---

## Memory Leaks

| # | Address | Alloc Site | Description |
|---|---|---|---|
| 1 | 0x2d647f20010 | store.zig:1206 (rowToDefinition, name dupe) | Leaked in TC-API-02-29 activate() error path |
| 2 | 0x2d647f10020 | store.zig:1205 (rowToDefinition, version dupe) | Same test — both name and version leaked on AlreadyActive error path |

---

## Special Focus Areas

### Idempotency Tests (ES-03)
✅ All idempotency tests PASSED (125 passing tests include ES-03 idempotency coverage).

### Transaction Atomicity (DB-03)
⚠️ Cluster A (DuplicateNameVersion) may indicate transactional issues — tests are not properly isolated. However, the atomicity tests specifically (TC-EE-10-04) failed due to DuplicateNameVersion, not atomicity violation.

### Concurrency Tests (EE-12, scheduler)
⚠️ TC-EE-01-06 failed with ADDRESS_ALREADY_EXISTS — a pool connection/concurrency issue. TC-EE-10-05 (concurrent ERROR race) failed due to DuplicateNameVersion, preventing assessment of actual concurrency behavior.

---

## Next Action

Route to **ISSUE-FIXER** (WF-03) with priority on the root causes:
1. **DefinitionStore.create() DuplicateNameVersion** — 14 tests share this root cause; likely test data isolation issue
2. **GraphValidationFailed** — 3 tests; validator may reject intentionally-invalid graphs used in error tests
3. **Pool exhaustion / connection** — TC-EE-01-06 ADDRESS_ALREADY_EXISTS
4. **AlreadyActive error path** — API-02-29 not returning correct error + memory leak
5. **cancelInstance() ServerError** — 3 API-03 tests

The 2 memory leaks in store.zig rowToDefinition should be fixed alongside the AlreadyActive issue.
