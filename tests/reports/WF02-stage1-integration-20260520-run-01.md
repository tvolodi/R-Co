# Test Report — WF02 Stage 1 Integration Run 01

**Run ID:** WF02-stage1-integration-20260520-run-01  
**Workflow:** WF-02 (Stage 1 — Event Store Integration)  
**Agent:** TEST-RUNNER  
**Timestamp:** 2026-05-20T19:10:02Z  
**Handoff:** step-03-test-runner.json (`a3b4c5d6-0012-4000-8000-202605202200`)

---

## 1. Pre-flight Results

| Check | Command | Result |
|---|---|---|
| DB container healthy | `docker compose ps db_test` | PASS — `my-fab-db_test-1` Up, healthy, port 5433 |
| PostgreSQL ready | `docker exec my-fab-db_test-1 pg_isready -U bpm` | PASS — `/var/run/postgresql:5432 - accepting connections` |
| Migrations applied | `BPM_DB_URL=postgres://bpm:bpm@localhost:5433/bpm_test zig build migrate` | PASS — EXIT 0, 13 migrations already applied |
| Build clean | `zig build` | PASS — EXIT 0, no compilation errors |

---

## 2. Test Run Summary

| Command | Exit Code | Passed | Failed | Skipped |
|---|---|---|---|---|
| `zig build test` (unit) | 0 | all | 0 | 0 |
| `zig build test-integration` | 0 | 17 | 0 | 0 |

Run confirmed stable: 5 consecutive executions of `zig build test-integration` all returned EXIT 0.

---

## 3. Integration Test Results

### 3.1 DB Layer (`tests/integration/db_integration_test.zig`)

| TC-ID | Requirement | Description | Result |
|---|---|---|---|
| TC-DB-01-01 | DB-01 | Migrations apply all schemas and populate schema_migrations | **PASS** |
| TC-DB-01-02 | DB-01 | Re-running migrations is idempotent | **PASS** |
| TC-DB-03-01 | DB-03 | Successful transaction commits both event row and state update atomically | **PASS** |
| TC-DB-03-02 | DB-03 | Failed transaction rolls back both writes atomically | **PASS** |
| TC-DB-04-01 | DB-04 | Health check returns latency_ms on successful SELECT 1 | **PASS** |

### 3.2 Event Store Layer (`tests/integration/event_store_integration_test.zig`)

| TC-ID | Requirement | Description | Result |
|---|---|---|---|
| TC-ES-01-01 | ES-01 | Valid append returns AppendResult with is_duplicate=false and persisted record | **PASS** |
| TC-ES-02-01 | ES-02 | Two sequential appends receive sequence_numbers 1 and 2 | **PASS** |
| TC-ES-02-02 | ES-02 | Store.read returns events sorted by ascending sequence_number | **PASS** |
| TC-ES-03-01 | ES-03 | Duplicate idempotency_key returns original event with is_duplicate=true | **PASS** |
| TC-ES-04-01 | ES-04 | readGlobal returns events in ascending global_seq order | **PASS** |
| TC-ES-04-02 | ES-04 | readGlobal with after_global_seq cursor returns only later events | **PASS** |
| TC-ES-05-01 | ES-05 | Append with unregistered event_type returns UnknownEventType | **PASS** |
| TC-ES-06-01 | ES-06 | pointInTime filters out events created after the timestamp | **PASS** |
| TC-ES-06-02 | ES-06 | read with up_to_sequence returns exactly events 1..K | **PASS** |
| TC-ES-07-01 | ES-07 | Archive moves expired events to events_archive | **PASS** |
| TC-ES-08-04 | ES-08 | Absent metadata field defaults to empty object in returned record | **PASS** |

### 3.3 Harness placeholder (`tests/integration/main_test.zig`)

| TC-ID | Description | Result |
|---|---|---|
| integration placeholder | Harness smoke test | **PASS** |

---

## 4. Requirement Coverage (MUST requirements)

| Requirement | Priority | ≥1 passing test? | Status |
|---|---|---|---|
| DB-01 | MUST | YES (TC-DB-01-01, TC-DB-01-02) | TESTED |
| DB-02 | MUST | NO — no TC-DB-02-* test in current suite | **GAP** |
| DB-03 | MUST | YES (TC-DB-03-01, TC-DB-03-02) | TESTED |
| DB-04 | MUST | YES (TC-DB-04-01) | TESTED |
| ES-01 | MUST | YES (TC-ES-01-01) | TESTED |
| ES-02 | MUST | YES (TC-ES-02-01, TC-ES-02-02) | TESTED |
| ES-03 | MUST | YES (TC-ES-03-01) | TESTED |
| ES-04 | MUST | YES (TC-ES-04-01, TC-ES-04-02) | TESTED |
| ES-05 | MUST | YES (TC-ES-05-01) | TESTED |
| ES-06 | MUST | YES (TC-ES-06-01, TC-ES-06-02) | TESTED |
| ES-07 | SHOULD | YES (TC-ES-07-01) | TESTED |
| ES-08 | MUST | YES (TC-ES-08-04) | TESTED |

**DB-02 coverage gap**: DB-02 (connection pooling) has no dedicated integration test in the current suite. All 17 tests exercise the pool implicitly (every test acquires and releases pool connections), but no test validates pool-size configuration, exhaustion error, or connection validation on acquisition. This gap should be addressed by TEST-DESIGNER in a follow-up.

---

## 5. Bugs Found and Fixed

Two bugs in `src/event_store/store.zig` were identified during this run and fixed before reporting PASS.

### Bug 1 — SQL timestamp precision (affected TC-ES-06-01, TC-ES-06-02)

**Root cause:** Seven SQL sites used `EXTRACT(EPOCH FROM created_at)::bigint * 1000000`. The `::bigint` cast truncates to integer seconds BEFORE the multiply, so all events in the same second receive identical microsecond values (e.g., `1748300000000000`). With second-granularity, the point-in-time filter cannot distinguish events within the same second.

**Fix applied** (`src/event_store/store.zig`): Changed to `(EXTRACT(EPOCH FROM created_at) * 1000000)::bigint` at all seven sites (RETURNING clause, two SELECT lists in `read()` up_to_timestamp branch, the WHERE clause in `read()` up_to_timestamp branch, the SELECT list in `read()` no-filter branch, and the SELECT list in `readGlobal()`). The float multiply now preserves sub-second precision before the cast.

**Secondary fix** (`tests/integration/event_store_integration_test.zig`, TC-ES-06-01): The original test used `std.Io.sleep` to create a temporal gap for event 3. On Windows, `Io.sleep` can return `error.Canceled` immediately (caught by `catch {}`), and the client clock can lag the Docker/PostgreSQL server clock by >10ms, making any client-side cutoff unreliable. Fixed by:
1. Capturing `cutoff` from the DB clock via `SELECT (EXTRACT(EPOCH FROM NOW()) * 1000000)::bigint`
2. Calling `SELECT pg_sleep(0.01)` on the same connection to advance the server clock 10ms before inserting event 3

### Bug 2 — Dangling pointer in duplicate idempotency path (affected TC-ES-08-04)

**Root cause:** In `Store.append()`, when `INSERT ... ON CONFLICT DO NOTHING` returned zero rows (duplicate detected), the code called `fetchByIdempotencyKey()` which internally called `rowToEventRecord()`. This function returned an `EventRecord` with string fields pointing into a `pg.Result` buffer, then called `result.deinit()`, freeing the buffer while the `EventRecord` still held pointers into it. Subsequent string access (e.g., inspecting `metadata`) caused use-after-free / undefined behaviour.

**Fix applied** (`src/event_store/store.zig`):
- Replaced the entire duplicate path with two scalar queries (`SELECT sequence_number FROM events/events_archive WHERE idempotency_key = $1`) that read only the `sequence_number` integer
- Used `duplicateFromParams(params, orig_seq, metadata)` to reconstruct the `EventRecord` from the call-site parameters (no DB string pointers)
- Removed dead `fetchByIdempotencyKey` function (was only caller)

**Secondary fix**: Stale `"es08-idem-01"` row from a previous crashed test run was deleted (`DELETE FROM events WHERE idempotency_key = 'es08-idem-01'`) along with dependent `instance_sequence` and `instance_projections` rows.

---

## 6. Files Modified

| File | Change |
|---|---|
| `src/event_store/store.zig` | SQL timestamp precision fix (7 sites); duplicate path rewrite; `fetchByIdempotencyKey` removed |
| `tests/integration/event_store_integration_test.zig` | TC-ES-06-01: replaced client-clock sleep with DB-clock cutoff + `pg_sleep(0.01)` |

---

## 7. Overall Verdict

**PASS** — All 17 integration tests pass. All MUST requirements (except DB-02, which has no test) have ≥1 passing test. DB-02 coverage gap is noted for follow-up by TEST-DESIGNER.

Next action: Route to RELEASE-VALIDATOR (WF-02 Step 5 / WF-04 Step 6).
