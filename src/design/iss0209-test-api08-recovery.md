# ISS-0209 Fix Design: tenant_default destructive-recovery race in test_api08_auth.zig

**Issue:** [GH-533](https://github.com/tvolodi/R-Co/issues/533) / **ISS-0209**
**Classification:** **Type E** (novel / cross-cutting change to test-harness synchronization and shared-schema provisioning semantics)
**Step:** WF-03 Step 2 — CODE-DESIGNER fix design
**Upstream artefact:** [diagnosis report](../../docs/issue-reports/ISS-0209-diagnosis.yaml)
**Implementer:** BACKEND-DEV (Step 3), after the CODE-DESIGN-VALIDATOR gate

## Classification rationale

Applying the selection rules in [`templates/lego-catalog.md`](../../templates/lego-catalog.md) in order:

1. **Type C?** No. No table/column is added, altered, or removed; no migration file is created.
2. **Type A?** No. No HTTP route is added.
3. **Type D?** No. No React Flow node.
4. **Type B?** No. No admin/list page.
5. **Type E — yes.** The change is cross-cutting test-harness synchronization logic spanning two test files (`tests/unit/test_api08_auth.zig`, `tests/unit/definition_retrieval_test.zig`), the canonical provisioning path (`src/db/provisioning.zig`), and the build-graph topology (`build.zig`). The catalog reserves "cross-module orchestration" and shared-infrastructure concerns for Type E, and there is no Lego piece for test-harness race protection.

## Module purpose

Close the shared-schema destructive-recovery race in `test_api08_auth.zig::ensureTenantDefaultSchema()` so that two concurrent `zig build test` binaries — `test_api08_auth` and the DB-backed PD-07 tests in `definition_retrieval_test.zig` — can run against the same `tenant_default` schema without one binary erasing tables while sibling binaries are mid-flight.

The fix has three layers, applied in order of precedence:

1. **Remove the destructive fallback.** The `error.MigrationFailed` branch in `ensureTenantDefaultSchema()` must no longer `DROP SCHEMA CASCADE` and retry. A generic `MigrationFailed` is *never* a license to drop a schema that sibling binaries are using.
2. **Distinguish transient contention from genuine drift** before any destructive action. On transient contention, retry the provisioning call inside the same lock; on genuinely unrecoverable drift, escalate to a typed error and require an operator to investigate.
3. **Hold the tenant advisory lock across the full recovery sequence.** If a destructive path is retained as defence-in-depth, the lock must cover the entire check-then-decide-then-act-then-verify critical section, not only the initial provisioning call.

Out of scope: `src/db/provisioning.zig` (its internal `pg_advisory_lock` is correct), `tests/unit/definition_retrieval_test.zig` (the PD-07 tests are victims, not causes), and the `build.zig` test topology (the design tolerates concurrent binaries; that is a property we must preserve, not an obstacle to bypass).

## 1. Problem statement

`tests/unit/test_api08_auth.zig::ensureTenantDefaultSchema()` provisions `tenant_default` by calling `provisioning_mod.provisionTenantSchema(...)`. If that call returns `error.MigrationFailed` for any reason — transient lock contention, sibling-binary DDL in flight, momentary network jitter — the helper treats the error as proof that the schema is corrupt. It then acquires a *separate* connection from the pool and executes:

```sql
DROP SCHEMA IF EXISTS tenant_default CASCADE
DELETE FROM public.tenant_schemas WHERE tenant_id = $1::uuid
DELETE FROM public.schema_migrations WHERE schema_name = 'tenant_default'
```

followed by a second `provisionTenantSchema()` call. The first `provisionTenantSchema()` releases its session-scoped advisory lock before returning; the recovery path acquires a fresh, unrelated pool connection and never takes that lock.

`provisionTenantSchema()` (`src/db/provisioning.zig:73-181`) protects only its own sequence — idempotency check, `bpm_provision_tenant_schema()`, `runForSchema()`, registry update, public.tenant promotion — with a session-scoped `pg_advisory_lock(hashtext('bpm.provisioning.provisionTenantSchema:<tenant_id>'))`. The fallback DROP runs *after* that lock has been released.

Consequence: while `test_api08_auth` is between `DROP SCHEMA CASCADE` and completion of reprovisioning, a sibling binary provisioning `tenant_default` or running a query against `process_definitions`/`users`/`api_tokens`/`user_roles` hits C42P01. The diagnosis reproduces this deterministically across three runs (918/1003 passing, the same 21 failures).

| Concurrent run | Failures | Signature |
|---|---|---|
| 1 | 21 | `C42P01 relation "process_definitions" does not exist` × 16 (TC-PD-07-*), `C42P01 on users/api_tokens/user_roles in tenant_default` × 5 (TC-IDN-01-06, TC-IDN-04-04a/b, TC-IDN-04-05a/b) |
| 2 | 21 | identical |
| 3 | 21 | identical |

### 1.1 Explicit non-cause

- **A missing migration in the canonical migrator** is ruled out by the diagnosis: `bpm.migrations.runForSchema()` is correct; the failure surfaces only because `tenant_default` is gone mid-flight.
- **A fixture-name collision** is ruled out: the failed queries are against `process_definitions`, `users`, `api_tokens`, `user_roles` — none are test-created fixtures.
- **`continue-on-error` masking in CI** is unrelated; this is a Zig build-graph failure, not a CI step.

### 1.2 Approaches explicitly rejected

Carried forward from the diagnosis; the implementer must not reach for any of these:

- **Build-level serialization of every test binary.** Masks unsafe test behaviour rather than protecting the shared resource, and reopens ISS-0162-style cross-binary ordering bugs by making serialization implicit.
- **Retrying the DROP on C42P01.** This is the failure mode we are fixing — adding retries around it would multiply the race window.
- **Re-running the migration as a separate transaction that does not own the lock.** This is the current design's defect.
- **Weakening, skipping, or deleting TC-PD-07-01 … TC-PD-07-20 or TC-IDN-01-06 / TC-IDN-04-04a / TC-IDN-04-04b / TC-IDN-04-05a / TC-IDN-04-05b.** Forbidden by CLAUDE.md; the tests are detectors, not the fault.
- **Treating "an incident was open" as grounds to dismiss the red step.** `zig build test --summary all` is the gate; we judge by its exit code, not by the presence of strings in the output.

## 2. Synchronization mechanism (chosen)

The design uses **the existing tenant-keyed advisory lock** (`pg_advisory_lock(hashtext('bpm.provisioning.provisionTenantSchema:<tenant_id>'))::bigint`) already held inside `provisionTenantSchema()`. The fix moves the recovery decision **inside** that lock's lifetime rather than introducing a second key.

Why a single key, not two:

- A distinct key (`bpm.provisioning.recovery:<tenant_id>`) would reopen the same race in reverse — `provisionTenantSchema()` and the recovery path would each be self-consistent but never mutually exclusive across each other.
- `src/design/iss0148_clean_test_db_ordering_and_lock.md` and `src/design/fix-ISS-0107.md` established this lesson in earlier runs: two advisory-lock keys give mutual exclusion only within each key's own critical section, never across them.

Why session-scoped, not transaction-scoped:

- The lock must outlive the single `bpm_provision_tenant_schema()` SQL call so it also covers the destructive recovery path (if retained), the metadata repair, and the second `provisionTenantSchema()` call. The lock is `defer`-released from the same connection before the connection returns to the pool, matching the ISS-0131 pattern already in `provisionTenantSchema()` (lines 89-118).
- A `pg_advisory_xact_lock` would auto-release at the end of the first transaction, leaving the destructive recovery outside the critical section — the very defect we are fixing.

Why inside `ensureTenantDefaultSchema()` (and not pushed down into `provisionTenantSchema()`):

- `provisionTenantSchema()` is the canonical server-side path; changing its semantics for one caller's benefit is the wrong layer.
- `ensureTenantDefaultSchema()` is a test-only helper. It can wrap the lock around a *single* call to the canonical path, retry the canonical path inside the lock on transient contention, and refuse to act on a generic `MigrationFailed` without a corroborating signal.

## 3. Affected files — complete verified enumeration

All paths are relative to the repo root. Line ranges were produced by parsing the source files directly, not by estimation.

### 3.1 Files to modify

| File | Lines | Reason |
|---|---|---|
| `tests/unit/test_api08_auth.zig` | 57-96 (`ensureTenantDefaultSchema`) | Remove the `DROP SCHEMA CASCADE` recovery branch; wrap the canonical `provisionTenantSchema()` call in the same tenant-keyed advisory lock used inside `provisionTenantSchema()`; on `error.MigrationFailed`, retry the canonical call inside the lock with bounded backoff before escalating to a typed error. |
| `tests/unit/test_api08_auth.zig` | 277-603 (the five DB-backed TC-IDN-* tests) | No source changes; the helper change is sufficient. Each test already calls `ensureTenantDefaultSchema()` once per test, so a single shared lock guard per call eliminates the race. |
| `src/db/provisioning.zig` | 73-118 (existing advisory lock) | No semantic change; the lock key string is exposed via a public constant so test helpers can derive the same key without duplicating the format. **Defence in depth, not a behaviour change.** |
| `build.zig` | 339-1370 (test topology) | No source changes required. The fix is test-harness-internal; the build graph's permission for concurrent binaries is a property we preserve. |

### 3.2 Files explicitly NOT to modify

| File | Lines | Reason |
|---|---|---|
| `tests/unit/definition_retrieval_test.zig` | 45-80, 159-565, 650-900 (`makePool`) | The PD-07 tests are victims. `makePool()` already calls `provisionTenantSchema()`; the lock added inside `provisionTenantSchema()` is sufficient to serialize them against `ensureTenantDefaultSchema()` once the latter holds the same key. Modifying `makePool()` would be redundant. |
| `tests/integration/helpers.zig` | 104-241 (`runMigrationsForSchema`) | Integration TestHarness already serializes same-schema provisioning with a hashtext-keyed advisory lock (line `runMigrationsForSchema` lock acquire). The unit-test layer's race is independent of the integration layer's race and is fixed by the change in `ensureTenantDefaultSchema()` alone. |
| `migrations/` | n/a | No schema changes. |

## 4. Public interface

The change in `tests/unit/test_api08_auth.zig` is internal to the test file; no public API changes. The change in `src/db/provisioning.zig` adds one public constant and (optionally) one helper function:

### 4.1 New public constant in `src/db/provisioning.zig`

```zig
/// Canonical advisory-lock key used to serialize same-tenant provisioning
/// passes (idempotency check, schema creation, migration, registry update,
/// destructive recovery). Must be used by every caller that performs a
/// check-then-act operation against a single tenant schema.
///
/// Format: "bpm.provisioning.provisionTenantSchema:<tenant_id>".
/// `tests/unit/test_api08_auth.zig::ensureTenantDefaultSchema()` and any
/// future test-only recovery path must derive the same key from the same
/// format string — see src/design/iss0209-test-api08-recovery.md.
pub const advisoryLockKeyPrefix = "bpm.provisioning.provisionTenantSchema:";
```

### 4.2 New public helper in `src/db/provisioning.zig` (preferred)

```zig
/// Acquire the canonical tenant advisory lock on the given pooled
/// connection. The caller MUST pair this with `releaseAdvisoryLock` on
/// the same connection (typically via `defer`) before returning the
/// connection to the pool. Session-scoped lock — survives across
/// transactions on the same session until released.
///
/// ISS-0209: this helper exists so test harnesses can wrap a recovery
/// decision in the same lock the canonical path uses. Production code
/// should keep using `provisionTenantSchema()` directly.
pub fn acquireAdvisoryLock(
    conn: *pg.Conn,
    tenant_id_str: []const u8,
) ProvisionError!void;

/// Release the canonical tenant advisory lock previously acquired with
/// `acquireAdvisoryLock`. Always `catch {}`-guarded in defer blocks —
/// an unlock failure must not block the caller from releasing the
/// connection back to the pool.
pub fn releaseAdvisoryLock(
    conn: *pg.Conn,
    tenant_id_str: []const u8,
) ProvisionError!void;
```

These two functions wrap the existing `pg_advisory_lock(hashtext($1)::bigint)` / `pg_advisory_unlock(hashtext($1)::bigint)` calls already inlined at `src/db/provisioning.zig:109` and `src/db/provisioning.zig:113`. **No behaviour change for existing callers.**

### 4.3 Replacement signature for `ensureTenantDefaultSchema()`

```zig
/// Ensure the tenant_default schema exists and has been migrated.
/// Idempotent: if the schema is already provisioned, returns immediately.
/// Holds the canonical tenant advisory lock for the full critical section
/// so that no concurrent binary can race a destructive recovery against
/// in-flight sibling queries.
///
/// ISS-0209: a generic `error.MigrationFailed` no longer triggers a
/// destructive `DROP SCHEMA CASCADE`. On transient contention, retries the
/// canonical `provisionTenantSchema()` call up to `max_recovery_attempts`
/// times with bounded exponential backoff. On persistent failure, returns
/// `error.RecoveryFailed` — the operator must investigate.
fn ensureTenantDefaultSchema(
    allocator: std.mem.Allocator,
    db_pool: *pool.Pool,
    max_recovery_attempts: u8,
) !void
```

The signature gains `max_recovery_attempts: u8` so each call site can dial the budget (the five TC-IDN-* tests call once each; the helper itself owns the lock lifetime).

## 5. Data flow

```
1. ensureTenantDefaultSchema() acquires a connection from the pool
   │
   ├─ [NEW] acquires the canonical tenant advisory lock on that connection
   │   (acquireAdvisoryLock(conn, "00000000-…-000000000000"))
   │   │
   │   │  Blocked here (lock_timeout = 90s, same as ISS-0151 bracket
   │   │  in tests/integration/helpers.zig) if a sibling binary holds
   │   │  the lock. Bounded wait, not unbounded.
   │   │
   │   ├─ [EXISTING, unchanged] provisionTenantSchema() idempotency check
   │   │
   │   ├─ [EXISTING, unchanged] provisionTenantSchema() body
   │   │
   │   └─ If provisionTenantSchema() returns MigrationFailed:
   │       │
   │       ├─ [NEW] Distinguish transient contention from genuine drift:
   │       │   • If the failure is a 55P03 (lock_timeout) or 40P01
   │       │     (deadlock_detected) → transient. Retry the canonical
   │       │     call after `min(2^attempt * 100ms, 2s)` backoff, up to
   │       │     `max_recovery_attempts` times.
   │       │   • Otherwise → genuine drift. Emit a typed
   │       │     `error.RecoveryFailed` carrying the underlying
   │       │     MigrationError variant. NO destructive action.
   │       │
   │       └─ [REMOVED] The `DROP SCHEMA CASCADE` + metadata delete
   │           branch is deleted entirely. The schema stays as it is,
   │           the binary that triggered the recovery fails fast with
   │           RecoveryFailed, and the operator investigates.
   │
   ├─ [NEW, defer] release the canonical tenant advisory lock
   │   (releaseAdvisoryLock(conn, "00000000-…-000000000000"))
   │
   └─ Returns the connection to the pool (lock already released)
```

### 5.1 Why retry-on-transient, escalate-on-persistent, never-destroy

The diagnosis establishes three facts:

1. A generic `MigrationFailed` is overwhelmingly caused by **transient sibling contention**, not schema corruption. Three consecutive concurrent reproductions produced the same 21 failures, all of which vanish if no recovery DROP fires.
2. PostgreSQL surfaces transient contention as 55P03 (`lock_timeout`) or 40P01 (`deadlock_detected`) — distinct SQLSTATEs that map cleanly onto a "retry" branch.
3. Even one DROP SCHEMA CASCADE in the wrong window tears down unrelated binaries' state. There is no safe width for this window under the build graph's concurrent execution.

Therefore: **retry-on-transient-contention**, **escalate-on-everything-else**, **never-DROP**. The diagnostic principle (from `docs/agents/AGENT_SYSTEM.md` and the 2026-08-05 pipeline audit): a recovery that destroys state is not a recovery — it is a different, larger failure.

### 5.2 What happens if the lock is held by a sibling for >90s?

The bracket uses `SET lock_timeout = '90s'` on the lock acquire connection (matching the ISS-0151 pattern at `tests/integration/helpers.zig:runMigrationsForSchema`). If the sibling holds longer than that, the acquire raises 55P03, which is a transient-contention signal and is retried. After `max_recovery_attempts` exhausted attempts, the helper returns `error.RecoveryFailed`. The lock connection is `defer`-released, the connection returns to the pool, and the test fails with a deterministic, typed error — never with a destructive action.

## 6. Error taxonomy

### 6.1 New error variants in `provisioning_mod` (test-only path)

The new variants live in a **test-harness-only error set** declared at the top of `tests/unit/test_api08_auth.zig`, not in `src/db/provisioning.zig` (which is the production-side module and must keep its public surface unchanged):

```zig
/// ISS-0209: errors emitted by the recovery loop in ensureTenantDefaultSchema().
/// These are intentionally distinct from provisioning_mod.ProvisionError so
/// test bodies can match on them without weakening tests that import
/// provisioning_mod directly.
const HarnessRecoveryError = error{
    /// The canonical provisionTenantSchema() call returned MigrationFailed
    /// more times than the caller-budgeted `max_recovery_attempts`. The
    /// schema state is unchanged — the caller must investigate.
    RecoveryFailed,
    /// The advisory lock acquire itself timed out after 90s. Distinct from
    /// RecoveryFailed so a noisy CI does not collide with a real recovery
    /// failure.
    LockAcquireTimeout,
    /// A non-MigrationFailed ProvisionError variant surfaced from the
    /// canonical path inside the recovery loop. The schema state is
    /// unchanged; the underlying variant is preserved as a payload in the
    /// test log.
    CanonicalProvisionFailed,
};
```

### 6.2 Mapping

| Underlying condition | Surface error | Action |
|---|---|---|
| Canonical `provisionTenantSchema()` succeeds | (returns void) | — |
| Canonical returns `MigrationFailed` with transient signature (55P03 / 40P01) | retry | bounded exponential backoff, max `max_recovery_attempts` |
| Canonical returns `MigrationFailed` with persistent signature | `RecoveryFailed` | fast-fail the test; no destructive action |
| Canonical returns `PoolExhausted` / `SchemaCreationFailed` / etc. | `CanonicalProvisionFailed` (logged with underlying variant) | fast-fail the test |
| Advisory-lock acquire raises 55P03 | `LockAcquireTimeout` | distinct from `RecoveryFailed` so CI logs are not ambiguous |
| Generic DB error inside the lock | propagate as `CanonicalProvisionFailed` | — |

### 6.3 Removed error path

The `error.MigrationFailed => { … DROP CASCADE … retry … }` branch in `ensureTenantDefaultSchema()` is deleted entirely. There is no replacement; the new behaviour is "retry on transient, escalate on persistent, never destroy".

## 7. State transitions

The fix introduces no module state. The relevant state transitions are the lock-state on the lock-acquire connection and the test binary's outcome:

```
ensureTenantDefaultSchema() entered
  │
  ├─ acquireAdvisoryLock(conn, tenant_id) →
  │     │
  │     ├─ lock acquired: state = LOCKED
  │     │
  │     └─ lock_timeout exceeded (55P03):
  │           state = UNLOCKED, return LockAcquireTimeout
  │
  ├─ for attempt in 1..=max_recovery_attempts:
  │     │
  │     ├─ provisionTenantSchema() returns ok: return success
  │     │
  │     ├─ provisionTenantSchema() returns MigrationFailed:
  │     │     │
  │     │     ├─ last PG error was 55P03 / 40P01 (transient):
  │     │     │   sleep(min(2^attempt * 100ms, 2s))
  │     │     │   continue
  │     │     │
  │     │     └─ else (persistent):
  │     │         return RecoveryFailed
  │     │
  │     └─ other ProvisionError variant: return CanonicalProvisionFailed
  │
  ├─ (loop exhausted without success): return RecoveryFailed
  │
  ├─ defer: releaseAdvisoryLock(conn, tenant_id) catch {}
  │
  └─ connection released to pool
```

### 7.1 What state does NOT change

- `tenant_default` schema: never `DROP`ped by this code path. It is left in whatever state the canonical migrator left it in.
- `public.tenant_schemas`: no rows deleted by this code path.
- `public.schema_migrations`: no rows deleted by this code path.
- Sibling binaries' connections: unaffected. Their queries against `tenant_default` resolve as long as the schema exists, which it does throughout the recovery.

## 8. Dependencies

### 8.1 New imports in `tests/unit/test_api08_auth.zig`

- `provisioning_mod.acquireAdvisoryLock` and `provisioning_mod.releaseAdvisoryLock` — already imported via `const provisioning_mod = @import("provisioning");`. No new `build.zig` wiring required; the existing module graph (`build.zig:684-693`) exposes the provisioning module.

### 8.2 New public surface in `src/db/provisioning.zig`

- `pub const advisoryLockKeyPrefix = "bpm.provisioning.provisionTenantSchema:";` — read-only constant, no side effects.
- `pub fn acquireAdvisoryLock(conn, tenant_id_str) ProvisionError!void` — wraps the existing inline `pg_advisory_lock` call.
- `pub fn releaseAdvisoryLock(conn, tenant_id_str) ProvisionError!void` — wraps the existing inline `pg_advisory_unlock` call.

### 8.3 Imports unchanged

- `provisioning_mod` already imports `pool_mod`, `migrations`, `tenant_context_mod`. No new imports.
- The lock helper functions do not introduce a circular dependency: `tests/unit/test_api08_auth.zig` already depends on `provisioning_mod` for `provisionTenantSchema()`.

### 8.4 What this design MUST NOT depend on

- Build-level test serialization (out of scope; would mask unsafe behaviour).
- Modifying `tests/unit/definition_retrieval_test.zig` (out of scope; the PD-07 tests are victims).
- Modifying `tests/integration/helpers.zig` (out of scope; integration harness already has its own lock).
- Reusing `src/db/provisioning.zig::provisionTenantSchema()`'s internal lock-acquire/defer-release pattern by reaching inside that function — encapsulation is preserved; the new helpers wrap the same SQL but are independently callable.

## 9. Regression test plan

Each regression test below belongs in `tests/integration/` (the canonical location for tests that need `BPM_TEST_DB_URL` and cross-binary concurrency), not in `tests/unit/`. Per `docs/agents/AGENT_SYSTEM.md` and the prevention guidance in the diagnosis, DB-backed tests must be integration tests with per-test UUIDs.

### 9.1 New test file: `tests/integration/iss0209_tenant_default_recovery_race_test.zig`

This file must contain, at minimum, the following five tests, each tagged `regression: ISS-0209 — …`:

#### Test 1: `regression: ISS-0209 — ensureTenantDefaultSchema never DROP SCHEMA CASCADE during transient contention`

- Pre-state: drop `tenant_default` and delete its registry row, leaving `provisionTenantSchema()` ready to provision.
- Spawn two goroutines (or two `std.Thread`s) that both call `ensureTenantDefaultSchema(...)` with `max_recovery_attempts = 5`.
- Assert: `tenant_default` exists after both calls return.
- Assert: `public.tenant_schemas` row for `00000000-0000-0000-0000-000000000000` has `migrations_applied_at IS NOT NULL`.
- Assert: neither test thread emitted `DROP SCHEMA` SQL (verified by `pg_stat_statements` after the test or by a `BEFORE/AFTER` schema-name presence assertion).
- Assert: the test as a whole completes within 30s under load (no 90s lock-timeout fire).

#### Test 2: `regression: ISS-0209 — concurrent ensureTenantDefaultSchema and definition_retrieval_test makePool() leave process_definitions queryable`

- Pre-state: clean `tenant_default` schema.
- Spawn two threads. Thread A calls `ensureTenantDefaultSchema()` (the new helper). Thread B does the same `makePool()` work that `tests/unit/definition_retrieval_test.zig::makePool()` does, including a `SELECT id FROM process_definitions LIMIT 1` query.
- Assert: Thread B's `SELECT` does not raise C42P01 at any point during Thread A's execution.
- Assert: both threads return success.
- Assert: the count of `DROP SCHEMA` SQL statements on `tenant_default` during the test, as observed by `pg_stat_statements`, is 0.

#### Test 3: `regression: ISS-0209 — RecoveryFailed surfaces after exhausting max_recovery_attempts on persistent failure`

- Pre-state: corrupt `tenant_default` by creating a non-idempotent conflicting relation that the migrator cannot resolve.
- Call `ensureTenantDefaultSchema(max_recovery_attempts = 2)`.
- Assert: the function returns `error.RecoveryFailed`.
- Assert: `tenant_default` schema still exists at function return.
- Assert: `public.tenant_schemas` row for the default tenant is unchanged (no row deletion by the helper).

#### Test 4: `regression: ISS-0209 — LockAcquireTimeout surfaces distinctly from RecoveryFailed`

- Pre-state: hold the canonical advisory lock on a separate session for 95 seconds.
- Call `ensureTenantDefaultSchema(max_recovery_attempts = 1)` from another session.
- Assert: the function returns `error.LockAcquireTimeout` within 95-100 seconds.
- Assert: `tenant_default` schema still exists at function return.
- Assert: no `DROP SCHEMA` SQL has been issued by the helper.

(Test 4's 95-second lock hold requires either a dedicated `BPM_TEST_DB_URL_SLOW` instance or a `pg_sleep()` from a side session; the implementer may reduce it to 5 seconds by lowering the lock_timeout bracket to 5s for this test alone, mirroring the ISS-0151 bracket pattern.)

#### Test 5: `regression: ISS-0209 — acquireAdvisoryLock + releaseAdvisoryLock round-trip is observable`

- Call `acquireAdvisoryLock(conn, tenant_id)`; in a side session, verify `pg_locks` shows an entry for `hashtext('bpm.provisioning.provisionTenantSchema:<tenant_id>')::bigint`.
- Call `releaseAdvisoryLock(conn, tenant_id)`; verify the entry is gone.
- Assert: the constant `provisioning_mod.advisoryLockKeyPrefix` equals `"bpm.provisioning.provisionTenantSchema:"`.

### 9.2 Pre-existing tests that must remain passing

The five DB-backed TC-IDN-* tests in `tests/unit/test_api08_auth.zig` (TC-IDN-01-06, TC-IDN-04-04a, TC-IDN-04-04b, TC-IDN-04-05a, TC-IDN-04-05b) and the DB-backed PD-07 tests (TC-PD-07-01 through TC-PD-07-20) must pass without modification under `zig build test --summary all` in five consecutive runs (per the diagnosis acceptance criterion AC-1).

### 9.3 Build-graph regression check

After implementing, run:

```bash
for i in 1 2 3 4 5; do
  zig build test --summary all 2>&1 | tee -a /tmp/iss0209-rerun-$i.log
done
```

Exit code must be 0 in all five runs. Total passing count must equal `tests/unit/*.zig` test count (no skipped tests beyond the documented `error.SkipZigTest` paths).

## 10. Acceptance criteria (from diagnosis, with verification)

| AC | Verification |
|---|---|
| AC-1: `zig build test --summary all` passes 100% in 5 consecutive runs | §9.3 rerun loop; exit code 0 each time |
| AC-2: No C42P01 on `process_definitions`, `users`, `api_tokens`, `user_roles` during concurrent runs | §9.2 pre-existing tests + §9.1 Test 2 |
| AC-3: No code path can `DROP SCHEMA CASCADE` for `tenant_default` without holding the canonical lock | `ensureTenantDefaultSchema()` no longer calls `DROP SCHEMA` at all (§5 data flow). AC-3 is satisfied by removal, not by lock-coverage. |
| AC-4: TC-IDN-* and TC-PD-07 tests can run concurrently without one deleting the other's schema | §9.1 Test 1 + §9.1 Test 2 |
| AC-5: A regression test demonstrates provisioning/recovery contention leaves `tenant_default` present with required tables | §9.1 Test 1 + Test 2 |

## 11. Prevention (from diagnosis, with operationalisation)

| Prevention rule | Where it lives |
|---|---|
| Treat shared-schema recovery as a critical section: lock must cover check → destructive action → metadata repair → reprovisioning → readiness verification. | Encoded in the new `acquireAdvisoryLock` / `releaseAdvisoryLock` helpers and their use inside `ensureTenantDefaultSchema()` (§4.2, §5). |
| Do not interpret every `MigrationFailed` as schema corruption; distinguish transient contention from genuine drift before destructive repair. | Encoded in §5.1 and §6.2: retry-on-transient, escalate-on-persistent, never-DROP. |
| Keep DB-backed tests out of `tests/unit/`; use TestHarness or per-test tenant schemas with per-test UUIDs. | The five DB-backed TC-IDN-* tests are already in `tests/unit/`; the implementer must NOT move them in this fix (out of scope). The new regression tests live in `tests/integration/` per §9. A future follow-up run may relocate the existing TC-IDN-* tests; that is a separate issue, not part of ISS-0209. |
| Maintain a build-graph audit identifying independent test binaries that share `BPM_TEST_DB_URL` and `tenant_default`. | Documented as an open question in §12. The fix does not require this audit to pass; it only requires that the audit be created as a follow-up artefact. |
| Run repeated concurrent `zig build test --summary all` regression checks after any change to provisioning, migration, or test-database cleanup code. | Encoded in §9.3. The implementer MUST run this loop before completing the BACKEND-DEV handoff. |

## 12. Open questions

1. **Should the five TC-IDN-* tests be moved from `tests/unit/` to `tests/integration/`?** Out of scope for this fix. The diagnosis flags it as a prevention rule; the implementer must NOT move them in this run (it would re-trigger the build-graph audit and risk ISS-0162-style regressions). File as a follow-up issue after this fix lands, with reference to ISS-0209 §11 row 3.
2. **Should `provisionTenantSchema()` itself accept a `recovery_strategy` parameter instead of relying on the test-only helper?** No — that would couple production semantics to a test-only concern. The two-helper approach in §4.2 keeps the production path unchanged and lets the test layer choose its own strategy.
3. **Should the `lock_timeout = '90s'` bracket be configurable per-call?** Yes — the regression test in §9.1 Test 4 needs a shorter bracket. The implementer should add a third optional parameter `lock_timeout_ms: ?u32 = null` to `acquireAdvisoryLock`; when `null`, the default `'90s'` applies. This is a minor extension, not a behavioural change.

## 13. Verification steps

1. **Run §9.1 Tests 1-5 against `BPM_TEST_DB_URL`.**
   - All 5 must pass.
   - No `DROP SCHEMA` SQL must appear in `pg_stat_statements` for any test that calls `ensureTenantDefaultSchema()`.

2. **Run the five-consecutive rerun loop in §9.3.**
   - All 5 runs exit 0.
   - Total passing count is identical across all 5 runs.

3. **Sanity-check the build-graph audit.**
   - `git grep -nE "tenant_default|ensureTenantDefaultSchema|provisionTenantSchema" -- 'tests/**/*.zig'` lists every caller.
   - Every caller outside `src/db/provisioning.zig` and the two test files (`test_api08_auth.zig`, `definition_retrieval_test.zig`) must be flagged in the audit; none exist today.

4. **Confirm the constant is reachable from tests.**
   - `zig build test-integration-tm` exercises the new helper; the integration test file must reference `provisioning_mod.advisoryLockKeyPrefix` and observe the expected value.

5. **Lint gate.**
   - `python3 tools/lint_design_artefact.py src/design/iss0209-test-api08-recovery.md` exits 0 (no BLOCKER, no MAJOR).
   - `python3 tools/lint_handoffs.py` exits 0.
   - `zig build` exits 0.
   - `zig build test` exits 0.

## Reference

- Upstream diagnosis: [`docs/issue-reports/ISS-0209-diagnosis.yaml`](../../docs/issue-reports/ISS-0209-diagnosis.yaml)
- Canonical provisioning: [`src/db/provisioning.zig`](../../src/db/provisioning.zig)
- Existing lock pattern: [`src/db/provisioning.zig:89-118`](../../src/db/provisioning.zig) (ISS-0131 / GH #424)
- Integration lock pattern: [`tests/integration/helpers.zig`](../../tests/integration/helpers.zig) `runMigrations()` and `runMigrationsForSchema()` (ISS-0151 / GH #483)
- Cross-binary race precedent: [`src/design/iss0162_test_harness_cross_binary_races.md`](iss0162_test_harness_cross_binary_races.md)
- Cleanup ordering precedent: [`src/design/iss0148_clean_test_db_ordering_and_lock.md`](iss0148_clean_test_db_ordering_and_lock.md)
- Search-path transaction guard: [`src/design/iss0128-event-store-search-path.md`](iss0128-event-store-search-path.md)
- Schema-per-tenant design: [`src/design/spt-01-schema-per-tenant-provisioning.md`](spt-01-schema-per-tenant-provisioning.md)