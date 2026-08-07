# ISS-0612 — provisionTenantSchema() Advisory-Lock Scope Fix

**Run ID:** WF03-GH556-20260807
**Issue:** [GH-556](https://github.com/tvolodi/R-Co/issues/556) (ISS-0612)
**Classification:** Type E (novel / cross-cutting change to a shared infrastructure surface — concurrency control over an existing orchestration function)
**Step:** WF-03 Step 2 — CODE-DESIGNER fix design
**Related:** ISS-0131/GH-424 (introduced the lock this issue fixes the scope of), ISS-0129/GH-419 (migration-runner xact lock), ISS-0114/GH-377 (Step 6a promotion)

Covers: ISS-0612

## Module purpose

`src/db/provisioning.zig::provisionTenantSchema()` is the single Zig-side entry point that idempotently provisions a PostgreSQL schema for a tenant: it creates the schema, applies all pending migrations inside it, and promotes the tenant row to `storage_mode='SCHEMA'`. Its ISS-0131 advisory-lock block exists specifically so that concurrent calls for the *same* `tenant_id` do not race each other through this multi-step, multi-connection sequence. This design restructures that lock so its critical section actually covers the work it was written to protect, and resolves the deadlock/lock-layering hazards that restructuring introduces.

---

## 1. Problem statement (confirmed)

`provisionTenantSchema()` (lines 94–259) executes in this order:

1. **Lines 100–102** — validate `tenant_id_str` (no I/O).
2. **Lines 117–125** — the advisory-lock block: acquire `lock_conn` from the pool, call `acquireAdvisoryLock`, then (via `defer`, still inside the same nested `{ }`) call `releaseAdvisoryLock`, then release `lock_conn` back to the pool. All four actions happen before the block's closing brace at line 125.
3. **Lines 127–161 (Step 2)** — idempotency check, on a **freshly acquired, different** connection.
4. **Lines 163–179 (Steps 3–4)** — derive schema name, call `bpm_provision_tenant_schema()`, on **yet another** freshly acquired connection.
5. **Lines 181–183 (Step 5)** — `migrations.Migrations.runForSchema(...)`, which internally acquires **its own** connection from the pool.
6. **Lines 185–197 (Step 6)** — update `tenant_schemas.migrations_applied_at`, on **another** freshly acquired connection.
7. **Lines 199–250 (Step 6a)** — promote `tenant` row to `storage_mode='SCHEMA'`, on **another** freshly acquired connection.
8. **Lines 252–258 (Step 6b)** — thread-local cache update (no I/O, no pool connection).

The lock is fully acquired and released within step 2, before step 3 even begins. Because `pg_advisory_lock` is a *session*-scoped lock and the lock-holding connection is released back to the idle pool at the end of step 2, by the time step 3 starts, no lock is held anywhere. Steps 3–7 are five separate pool round-trips, each on a connection with no relationship to `lock_conn`, and nothing prevents two threads calling `provisionTenantSchema()` for the same `tenant_id` from interleaving arbitrarily across all of them. This is the exact race the lock's own comment (lines 104–116) says it prevents.

---

## 2. Primary fix — extend the critical section over Steps 2 through 6a

### 2.1 Structural change

Steps 2, 3–4, 6, and 6a **must run on the same connection that holds the advisory lock** (`lock_conn`), and that connection must not be released — and the lock must not be released — until after step 6a completes (or the function returns early via an error). Step 5 (`runForSchema`) is the one exception; see §3 for why it cannot share `lock_conn` and how correctness is preserved regardless.

Concretely, restructure the function body as follows (line references are to the current file; "moves inside" means the statement body is relocated, not merely renamed):

- **Delete** the standalone nested block at lines 117–125 as a self-contained unit. Its `pool.acquire()` call becomes the *single* connection acquisition that seeds the whole critical section — call this variable `lock_conn`, acquired once, near the top of the function (immediately after the input validation at lines 100–102).
- Immediately after acquiring `lock_conn`, call `acquireAdvisoryLock(lock_conn, tenant_id_str)` exactly as today (line 123's logic, unchanged). Do **not** pair it with an immediately-following `releaseAdvisoryLock` defer at this point — the release now belongs at the very end of the critical section, not here.
- **Step 2 (current lines 128–161, the idempotency check)**: remove its own `pool.acquire()`/`defer pool.release()` pair (currently lines 129–133). Reuse `lock_conn` for the `conn.query(...)` call at line 135. The early `return;` at line 156 (already-provisioned fast path) now must go through a shared cleanup path that still releases the advisory lock and `lock_conn` before returning — see §2.2 on cleanup ordering.
- **Steps 3–4 (current lines 163–179, schema-name derivation + `bpm_provision_tenant_schema()` call)**: schema-name derivation (line 165) is pure/no I/O and is unaffected. Remove Step 4's own `pool.acquire()`/`defer pool.release()` pair (currently lines 169–173). Reuse `lock_conn` for the `conn.exec(...)` call at line 175.
- **Step 5 (current line 182, `runForSchema`)**: stays exactly as today — it keeps acquiring its own connection internally and is **not** given `lock_conn`. See §3 for the rationale; this is the one step that deliberately stays outside the connection-sharing change (though it remains *temporally* inside the lock's held-duration — the lock stays held on `lock_conn` while `runForSchema` runs on a different connection).
- **Step 6 (current lines 186–197, `migrations_applied_at` update)**: remove its own `pool.acquire()`/`defer pool.release()` pair (currently lines 187–191). Reuse `lock_conn` for the `conn.exec(...)` call at line 193.
- **Step 6a (current lines 217–250, tenant promotion)**: remove its own `pool.acquire()`/`defer pool.release()` pair (currently lines 218–222). Reuse `lock_conn` for the `conn.exec(...)` call at line 224.
- **After Step 6a completes** (immediately before Step 6b's thread-local update at line 258, which needs no connection and can run after the lock is dropped): call `releaseAdvisoryLock(lock_conn, tenant_id_str)`, then `pool.release(lock_conn)`. Step 6b itself does not need to be inside the critical section — it only touches thread-local state, not the database — so it may run after the lock is released.
- **Step 6b (current lines 252–258)**: unchanged in content, only its position relative to the lock's release shifts (now strictly after release, which is also true today).

### 2.2 Cleanup ordering on every exit path (error returns and the idempotency fast-path)

Every one of Steps 2 through 6a can return early on error today (`ProvisionError.QueryFailed`, `SchemaCreationFailed`, `MigrationFailed`, `RegistryUpdateFailed`, `SchemaPromotionFailed`, `PoolExhausted`), and Step 2's fast path returns early on success. Under the current code each step's own `defer pool.release(conn)` fires automatically on any of these returns because each step owns its own connection scope. Once Steps 2–6a share one `lock_conn` instead, that per-step `defer` disappears — so the release-lock-then-release-connection pair must be re-established as a single `defer` (or two chained `defer`s in acquire order: lock first, then connection) registered **once**, immediately after `acquireAdvisoryLock` succeeds, covering the entire remainder of the function:

```
lock_conn = pool.acquire()
defer pool.release(lock_conn)
acquireAdvisoryLock(lock_conn, tenant_id_str)
defer releaseAdvisoryLock(lock_conn, tenant_id_str) catch {}
... Steps 2 through 6a, all using lock_conn ...
```

This is structurally identical to the pattern already used in the current (too-narrow) lines 117–124 — only the *scope* it wraps changes, from "just itself" to "Steps 2 through 6a". `defer` unwinds in reverse-registration order, so on any early return the advisory lock is released before the connection is released to the pool, which is the same ordering the current code already establishes for its (too-small) scope. This satisfies acceptance criterion 1: the critical section now covers Steps 2–6a on the same connection, and every exit path — success, idempotency fast-path, or any Step 2–6a error — releases the lock deterministically via `defer`, exactly once, before the connection returns to the pool.

### 2.3 What can safely stay outside the lock's scope

- **Step 1 (input validation, lines 100–102)** — pure, no I/O, no shared state. Stays before lock acquisition; no reason to hold a pool connection to validate a string length.
- **Step 6b (thread-local cache prime, lines 252–258)** — touches only this thread's local state, not the database or any cross-thread-visible row. It does not need the tenant-level mutual exclusion the lock provides (nothing else can race a thread-local write from *this* thread), so it can run after `lock_conn` is released, exactly as today.
- **Step 5's internal connection** (used by `runForSchema`) — deliberately not folded into `lock_conn`. See §3.

---

## 2. (continued) Public interface

`provisionTenantSchema`'s signature, parameter list, and `ProvisionError` return set are **unchanged** by this fix. `acquireAdvisoryLock` and `releaseAdvisoryLock` are also unchanged in signature and behavior — only the *call sites and scope* around them move. No caller of `provisionTenantSchema` needs to change.

---

## 3. Deadlock analysis (critical)

### 3.1 The hazard

`runForSchema` (`src/db/migrations.zig:104–543`) acquires its **own** connection from the pool (line 112) — independent of whatever connection `provisionTenantSchema` is using. If Steps 2–6a (including the call to `runForSchema`) all ran on `lock_conn` while `lock_conn` held the session-scoped tenant advisory lock, then during `runForSchema`'s execution there would be **two live connections from the same pool held by the same logical operation at the same time**: `lock_conn` (idle, waiting for `runForSchema` to return) and the connection `runForSchema` itself acquired. That is not by itself a deadlock — but it does raise two real risks that must be addressed:

1. **Pool exhaustion under low `pool_size`.** Holding `lock_conn` checked out for the *entire* duration of `runForSchema` (which itself acquires a second connection) means two of the pool's connections are consumed by one `provisionTenantSchema` call. Under `pool_size=3` (the stress-test configuration that reproduced this issue) and 12 concurrent same-tenant callers, only one caller can hold the lock at a time (by design — that is the mutual exclusion working correctly), but the *other 11* callers are now blocked at `pool.acquire()` for `lock_conn` itself, competing for the pool's remaining 1–2 connections just to start their own critical section, while the lock-holder additionally ties up a second connection inside `runForSchema`. This is a **connection-scarcity hazard**, not a lock-ordering deadlock — but it is exactly the failure mode the stress test observed (connections stuck checked out, `PoolExhausted` on forced termination). It must be treated as seriously as a deadlock because its symptom (indefinite stall) is identical.

2. **Lock-ordering hazard, checked explicitly.** Does `runForSchema`'s internal connection ever need to wait on a lock that `lock_conn` holds, or vice versa? `runForSchema`'s only advisory lock is `MIGRATIONS_LOCK_KEY_SQL` (migrations.zig:31–32), acquired via `pg_advisory_xact_lock` inside the **per-migration transaction** (immediately after `BEGIN`, migrations.zig:463) on `runForSchema`'s own connection — a completely different connection object and a completely different lock keyspace (`hashtext('bpm.migrations.runForSchema')` vs. `hashtext(advisoryLockKeyPrefix || tenant_id_str)`). PostgreSQL advisory locks are keyed and do not block across unrelated keys, so `runForSchema`'s connection acquiring `MIGRATIONS_LOCK_KEY_SQL` **never waits on** the tenant-level lock held on `lock_conn`, and `lock_conn` (which does no further querying while `runForSchema` runs — it is simply idle, held by the Zig call stack, not blocked in Postgres) never waits on anything `runForSchema` holds. There is **no cross-lock wait-for cycle**, hence no deadlock in the classic sense (two sessions each waiting on a lock the other holds).

### 3.2 Resolution: keep `runForSchema` off `lock_conn`, accept the two-connections-in-flight cost, and size the fix to pool capacity

Given §3.1's finding — no lock-ordering deadlock, but a real connection-scarcity risk — this design's resolution is:

- **`runForSchema` keeps acquiring its own connection internally, exactly as it does today.** It is not refactored to accept an externally supplied connection, and `provisionTenantSchema` does not pass `lock_conn` into it. This avoids two further hazards that *would* be introduced by forcing `runForSchema` onto `lock_conn`: (a) `runForSchema` issues `BEGIN`/`COMMIT` per migration file on its connection — sharing that connection with `lock_conn`'s session-scoped `pg_advisory_lock` would tie the advisory lock's connection into transaction boundaries it was deliberately designed to be independent of (the ISS-0131 comment at provisioning.zig:113–116 explains exactly why the tenant lock is session-scoped rather than xact-scoped: so it survives across `runForSchema`'s internal per-migration commits); (b) it would make `provisionTenantSchema` and `runForSchema` connection-management concerns entangled, which is a larger and riskier refactor than this issue's scope warrants.
- **The critical section (Steps 2–6a) genuinely does hold `lock_conn` checked out for the duration of `runForSchema`**, which itself holds a second connection. This is intentional and necessary — the whole point of the fix is that `runForSchema` for a given tenant must not start until any *other* concurrent `provisionTenantSchema` call for the same tenant has fully finished (including its own `runForSchema` pass), otherwise migrations race exactly as ISS-0129/ISS-0144 already found. The lock must stay held across Step 5, not be dropped before it and re-acquired after.
- **This makes the fix's minimum viable pool size two connections per concurrently-provisioning tenant, not one.** That is a real, load-bearing constraint this design surfaces rather than hides: any deployment or test harness that provisions tenants under `pool_size` too small to give at least 2 connections to the single tenant currently allowed through the lock (1 for `lock_conn`, 1 for `runForSchema`'s internal acquire) will see `pool.acquire()` block or return `PoolExhausted` for `runForSchema`'s connection — but that is a **bounded, single-connection wait for the lock-holder itself**, not an unbounded multi-thread pile-up, because every *other* same-tenant caller is now correctly blocked at the outer `acquireAdvisoryLock` call (or, if `pool.acquire()` for `lock_conn` itself fails first under extreme scarcity, they fail fast with `PoolExhausted` rather than silently corrupting state). This is a strict improvement over today's behavior (all 12 threads racing unprotected through 5 independent connection acquisitions each) and matches the stress test's own pool_size=3 configuration: with the fix, at most 2 of the 3 connections are consumed by the single thread currently inside the critical section, leaving 1 free connection for the other 11 threads to queue on `pool.acquire()` for their own `lock_conn` — no thread is ever silently stuck with a phantom-held server-side lock, which was the actual observed defect.
- **Recommendation on whether `MIGRATIONS_LOCK_KEY_SQL` should become per-tenant:** No — not as part of this fix, and not to resolve a deadlock, because §3.1 already established there is no deadlock to resolve. `MIGRATIONS_LOCK_KEY_SQL` being global is a **separate, pre-existing throughput characteristic** (all concurrent migration work across *every* tenant serializes onto one transaction at a time), documented in ISS-0129's own design as intentional ("Single key for all tenants: every concurrent migrate-step caller ... queues on this one advisory lock"). Narrowing it to per-tenant would be a legitimate follow-on performance improvement (it would let `runForSchema` calls for *different* tenants run their migration transactions concurrently instead of queueing globally), but it is orthogonal to this issue's defect (the outer lock's scope), carries its own regression risk against ISS-0129's deadlock fix, and is out of scope here. File it as a separate, forward-looking enhancement if desired — do not fold it into this fix.

### 3.3 Summary answer to the deadlock question

No cross-lock wait-for cycle exists between `lock_conn`'s session lock and `MIGRATIONS_LOCK_KEY_SQL`'s xact lock — they are different keys on different connections and PostgreSQL advisory locks never contend across keys. The real risk this restructuring introduces is **connection-pool scarcity** (two connections held by one logical provisioning pass instead of one), not a deadlock. The fix accepts that cost as inherent to correct serialization and relies on `PoolExhausted` (already a defined, handled `ProvisionError` variant) as the fail-fast backstop under pools too small to sustain even one full critical-section pass — which is a pre-existing, already-handled condition, not a new failure mode this fix introduces.

---

## 4. Third lock layer — `bpm_provision_tenant_schema()`'s internal `pg_advisory_xact_lock`

`bpm_provision_tenant_schema()` (migrations/060_schema_per_tenant_bootstrap.sql:73–99) takes `pg_advisory_xact_lock(hashtext(v_schema_name))` at line 89, inside its own implicit single-statement transaction, keyed on the **schema name** (not the raw `tenant_id`) — a third keyspace, disjoint from both Zig-side locks (`advisoryLockKeyPrefix || tenant_id_str` and `'bpm.migrations.runForSchema'`).

**Recommendation: keep it. Do not remove it.** Rationale:

- **It protects a different caller surface.** `bpm_provision_tenant_schema()` is a `public`, directly callable SQL function (`SELECT public.bpm_provision_tenant_schema($1::uuid)`), not a private implementation detail reachable only through `provisionTenantSchema()`. Any other Zig code path, any SQL migration, any operator running `psql` directly, or any future caller that invokes this function without going through `provisionTenantSchema()`'s Zig-side lock entirely bypasses both Zig-side locks. Its own internal lock is the only protection those callers get, and it is self-contained (acquired and auto-released within the function's own transaction), so it costs nothing to callers that already hold the outer lock — `pg_advisory_xact_lock` on an already-held session lock's *different* key is not blocked by it (again, disjoint keyspace, no cross-key contention).
- **It is not made redundant by the Zig-side fix.** Once §2's fix lands, `provisionTenantSchema()` callers are serialized at the Zig level before they ever reach this SQL function, so in the *common* path the SQL-level lock will typically be uncontended (acquire it, find nothing else holds it, proceed) — but "typically uncontended" is not the same as "safe to remove". It remains the last line of defense for the direct-call path described above, and removing it would silently regress that path's safety the next time someone calls the function outside `provisionTenantSchema()` (e.g. an ad-hoc migration script or an operational runbook).
- **No coordination changes are needed.** The three lock layers do not need to be merged or made lock-order-aware relative to each other, because (a) Zig-side lock 1 (`lock_conn`'s session lock) and lock 3 (this SQL function's xact lock) are sequential, not concurrent, once §2's fix holds `lock_conn` across the call to `bpm_provision_tenant_schema()` — the outer lock is already held by the only thread permitted to be inside Steps 2–6a for this tenant, so lock 3 will never see contention from a sibling `provisionTenantSchema()` call, only (harmlessly) re-enter uncontended; and (b) lock 2 (`MIGRATIONS_LOCK_KEY_SQL`) is on an entirely separate connection and keyspace as established in §3.

---

## 5. Defense-in-depth — `Pool.release()` and `pg_advisory_unlock_all()`

### 5.1 Recommendation: add it

`Pool.release()` (`src/db/pool.zig:834–873`) should call `pg_advisory_unlock_all()` on the connection defensively, immediately before the connection is placed back into the idle set — conceptually alongside the existing `resetConnectionSearchPath` call (line 857), which already establishes the precedent that `release()` actively scrubs session state before a connection re-enters circulation rather than trusting every caller to have cleaned up perfectly.

### 5.2 Placement

Immediately after the `resetConnectionSearchPath(conn)` call (line 857) and before the mutex-guarded idle-set insertion (lines 859–873), issue `SELECT pg_advisory_unlock_all()` on `conn` (mirroring how `resetConnectionSearchPath` issues its own `conn.exec(...)` and marks `conn._is_valid = false` on failure — line 383–386). `pg_advisory_unlock_all()` releases every session-level advisory lock held by the current session and is a no-op (succeeds trivially) when none are held, so it is always safe to call unconditionally on every release, not just ones suspected of holding a lock.

### 5.3 Cost/benefit

- **Cost:** one additional round-trip query per `pool.release()` call — the same order of cost `resetConnectionSearchPath` already imposes on every release today. It is not free, but it is bounded, constant-time, and already accepted as a precedent for this exact kind of defensive cleanup on this exact code path.
- **Benefit:** it converts any *future* bug of this class (a code path that acquires a session-scoped advisory lock and, through an error path, a missed `defer`, or a new call site that forgets the release-before-pool-release discipline established in §2.2) from "silently hangs every future caller that happens to acquire this exact connection and contends on this exact key, for however long it takes someone to notice a full-suite test hang" into "harmless no-op, because the pool itself guarantees no connection re-enters the idle set carrying a stale lock." Given that ISS-0612 is itself a report of exactly this failure class actually happening in production-equivalent testing (a 25+ minute hang with zero error output), and given the difficulty of diagnosing it after the fact (this issue took a dedicated stress-test reproduction to pin down), the detection/prevention value clearly outweighs one extra round-trip on a code path that is not itself latency-critical (`pool.release()` is not on the hot query path of request handling — it is bookkeeping at the end of a connection's use).
- **This is explicitly a second, independent layer, not a substitute for §2's fix.** §2 fixes the actual defect (the lock scope not covering the work it claims to protect). §5's `pg_advisory_unlock_all()` is a safety net that limits the *blast radius* of any future regression of the same shape, at every release, regardless of which code path acquired the lock. Both should ship together: §2 alone leaves the pool with no structural defense against the next such bug; §5 alone (without §2) would still let Steps 2–6a race unprotected — it only prevents the *hang*, not the *data race* the lock exists to prevent. They are complementary, not alternatives.

---

## 6. Error taxonomy

No new error variants are introduced. `ProvisionError` (provisioning.zig:44–62) is unchanged — `PoolExhausted`, `QueryFailed`, `SchemaCreationFailed`, `MigrationFailed`, `RegistryUpdateFailed`, `SchemaPromotionFailed`, `InvalidTenantId` all retain their current meaning and trigger conditions; only their determinism improves, because Steps 2–6a can no longer observe a partially-completed concurrent sibling call's intermediate state. `PoolError.ExhaustedPool` surfacing as `ProvisionError.PoolExhausted` when `lock_conn` cannot be acquired, or when `runForSchema`'s internal acquire fails under the two-connections-in-flight load described in §3.2, are both already-handled, pre-existing branches — no new catch arms are needed in `provisionTenantSchema`. `Pool.release()`'s `PoolError` set is unaffected by §5's addition: `pg_advisory_unlock_all()` failing is handled the same way `resetConnectionSearchPath`'s failure already is (mark `conn._is_valid = false`, let the existing invalid-connection discard path in `release()` handle it — no new error variant required).

---

## 7. Dependencies

- `src/db/pool.zig` — `Pool.acquire`, `Pool.release`, `Conn.exec`, `Conn.query` (unchanged interfaces; `Pool.release`'s internal body gains one unconditional `conn.exec` call per §5).
- `src/db/migrations.zig` — `Migrations.runForSchema` (unchanged; continues to manage its own connection and its own `MIGRATIONS_LOCK_KEY_SQL` transaction-scoped lock).
- `migrations/060_schema_per_tenant_bootstrap.sql` — `bpm_provision_tenant_schema()` (unchanged; its internal `pg_advisory_xact_lock` is retained per §4).
- `src/db/tenant_context.zig` — `setStorageMode` (unchanged; Step 6b call site unaffected).

---

## 8. Acceptance-criteria cross-check

| Acceptance criterion (from handoff) | Addressed in |
|---|---|
| Restructure lock scope to cover Steps 2–6a | §2.1, §2.2 |
| Explicitly address deadlock risk between tenant-level session lock and `MIGRATIONS_LOCK_KEY_SQL`'s global xact lock | §3.1, §3.2, §3.3 |
| Address the three-independent-lock-layer problem | §3.2 (layers 1 & 2), §4 (layer 3) |
| Explicit recommendation on `Pool.release()` defense-in-depth (`pg_advisory_unlock_all`) | §5 |
| No implementation code present | This document contains prose and one indented pseudocode sketch (§2.2) under the 40-line fenced-code-block limit, no compilable Zig |
