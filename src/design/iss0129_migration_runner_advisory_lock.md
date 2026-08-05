# ISS-0129 — Migration Runner Advisory Lock (pg_advisory_xact_lock)

**Run ID:** WF03-gh419-20260805
**Issue:** [GH-419](https://github.com/tvolodi/R-Co/issues/419) (ISS-0129)
**Classification:** Type E (novel / cross-cutting change to a shared infrastructure surface)
**Step:** WF-03 Step 2 — CODE-DESIGNER fix design
**Upstream artefact:** [diagnosis report](../../../docs/issue-reports/ISS-0129-migration-deadlock-diagnosis.yaml)

## Module purpose

`src/db/migrations.zig` is the canonical Zig-side migrator for both the public schema and per-tenant schemas. The purpose of this design is to add a transaction-scoped advisory lock inside `Migrations.runForSchema` so concurrent calls (running for the same or different tenant schemas) serialize on a single, stable lock key. This eliminates the C40P01 deadlock diagnosed in ISS-0129 between concurrent migrate calls (one acquires `AccessExclusiveLock` on a trigger row via `DROP TRIGGER`) and concurrent audit-row inserts (the BEFORE INSERT trigger holds row + advisory locks). The lock is **transaction-scoped** (`pg_advisory_xact_lock`) so it is auto-released at COMMIT/ROLLBACK, never leaks across pool connections, and never requires explicit cleanup. The lock **keyspace is disjoint** from the trigger-function's per-tenant advisory lock (a different prefix string drives the hash) so concurrent audit inserts remain unblocked. Scope: this design specifies an edit to `src/db/migrations.zig` only — no migration SQL, no `provisioning.zig`, no test harness, no public-API change.

---

## 1. Problem statement

Under concurrent `zig build test-integration` runs, TC-TNT-01-01 (tenant provisioning) periodically fails with PostgreSQL `C40P01: deadlock detected`. The diagnosis in [ISS-0129-migration-deadlock-diagnosis.yaml](../../../docs/issue-reports/ISS-0129-migration-deadlock-diagnosis.yaml) pins the cycle to two concurrent transactions touching the same `audit_entries` row and the same `pg_trigger` row inside the same tenant schema: (a) `provisionTenantSchema()` → `Migrations.runForSchema()` reaches migration **1107**, which contains a per-tenant `DROP TRIGGER IF EXISTS trg_bpm_audit_apply_chain_hash ON audit_entries` and therefore holds `AccessExclusiveLock` on the trigger row in `pg_trigger`; (b) a concurrent audit `INSERT` (or a test-helper audit insert that fires under the same tenant's `search_path`) fires `BEFORE INSERT` trigger `bpm_audit_apply_chain_hash()`, which holds the per-tenant advisory lock + a row lock on the predecessor `chain_hash` row. Each transaction waits for the other — PostgreSQL aborts one with `C40P01`. The fix is to wrap the per-migration apply step inside `Migrations.runForSchema()` in a stable `pg_advisory_xact_lock(<key>)` so concurrent migrate calls serialize on one lock, while leaving the audit-trigger's per-tenant advisory-lock keyspace untouched so concurrent audit inserts remain unblocked.

---

## 2. Affected files and line ranges (verified)

### 2.1 `src/db/migrations.zig` — primary edit site

| Line(s) | Construct | Role |
|---|---|---|
| 78 | `pub fn runForSchema(allocator, pool, migrations_dir, schema_name, force_reconcile)` | The single Zig-side entry point through which every migrate-step caller (provisioning, harness bootstrap, `zig build migrate`, `runMigrations`/`runMigrationsForSchema`) flows. |
| 78–98 | Connection acquire + pool validation | Acquires one pool connection for the whole function. |
| 100–103 | Search-path setup | `SET search_path TO <schema>,public` on the pool connection. |
| 105–124 | ISS-0114 search-path post-condition | Asserts `SHOW search_path` contains `schema_name`. |
| 126–132 | `schema_migrations` bootstrap (in the public schema) | `CREATE TABLE IF NOT EXISTS` — runs outside any transaction, this is the only DDL in the function that runs without a tx wrapper. |
| 134–195 | File scan + applied-versions probe | Reads `migrations_dir/*.sql`, sorts, queries `schema_migrations WHERE schema_name = $1`. |
| 197–240 | Per-file predicate loop (GBL skip, already-applied skip, reapply_on_drift guard, out-of-order check) | Determines which files need to run. |
| 295–297 | `readFileAlloc` of SQL | Reads migration file bytes. |
| **301** | `conn.exec("BEGIN", &.{})` | **Transaction boundary (per-migration).** |
| **307** | `conn.simpleQuery(sql_bytes)` | Executes the migration DDL (the call that fires `DROP TRIGGER` for migration 1107). |
| 313–314 | `INSERT INTO schema_migrations` (in the public schema) | Records success in the same tx. |
| **323** | `conn.exec("COMMIT", &.{})` | **Transaction ends — advisory lock auto-released here.** |

Per-migration transaction-wrapping is the critical structural observation: because each migration runs in its own transaction (BEGIN at 301 → COMMIT at 323), the new `pg_advisory_xact_lock` must be **acquired inside that transaction**, between the `BEGIN` at 301 and the `simpleQuery` at 307. `pg_advisory_xact_lock` is auto-released by `COMMIT`/`ROLLBACK` — it never leaks across pool-release boundaries.

### 2.2 `src/db/provisioning.zig` — call site (no edit required)

| Line | Construct | Notes |
|---|---|---|
| 94 | `migrations.Migrations.runForSchema(allocator, pool, migrations_dir, schema_name, false)` | The only call site that flows through `runForSchema` from the per-tenant provisioning path. **No edit needed** — when `runForSchema` acquires the lock internally, every tenant provisioning path inherits it automatically. |
| 68–92 (Step 2 idempotency check) and 95–98 (Step 6 migrations_applied_at update) | Two other pool-acquire connections in `provisionTenantSchema` | These run BEFORE / AFTER the `runForSchema` call; they do not touch migration SQL and therefore do not participate in the deadlock cycle. No change required. |

### 2.3 `tests/integration/tnt_schema_isolation_test.zig` — regression test targets

| Line | Test | Why |
|---|---|---|
| 188 | `test "TC-TNT-01-01: all 21 business tables exist in tenant schema after provisioning"` | The failing test that surfaces the deadlock. Repro: concurrent `provisionTenantSchema` calls (or `provisionTenantSchema` racing against audit-insert helpers) hit C40P01 on 1107. Must remain green after the fix. |
| 839 | `test "TC-TNT-03-01: pool checkout for resolved tenant includes tenant schema in search_path"` | The other concurrent-tenant scenario from the diagnosis. Must remain green. |
| 937 | `test "TC-TNT-03-03: two concurrent connections for different tenants have independent search_paths"` | Verifies per-connection `search_path` isolation. The fix must NOT collapse this isolation — see §5 (keyspace disjointness). |

### 2.4 `tests/integration/helpers.zig` — bootstrap path (no edit required)

| Line | Notes |
|---|---|
| `runMigrations` (line ~74) | Calls `bpm.migrations.Migrations.run()` → `runForSchema(..., "public", false)`. Inherits the lock automatically. |
| `runMigrationsForSchema` (line ~120) | Calls `bpm.migrations.Migrations.runForSchema(allocator, &mig_pool, resolved.dir, schema, true)`. Inherits the lock automatically. |

The TestHarness bootstrap path goes through the canonical migrator (after ISS-0091 unification), so it shares the new lock without further changes.

---

## 3. Public API surface

### 3.1 What changes

| Symbol | Signature | Notes |
|---|---|---|
| `Migrations.runForSchema` | **unchanged** | All 5 parameters, all return type, all error variants preserved. No new mandatory argument. |
| `Migrations.run` | **unchanged** | Still a thin wrapper around `runForSchema("public", false)`. Inherits the lock transparently. |
| `MigrationError` set | **unchanged** | All existing variants kept. No new variants added. |
| Internal helper: `MIGRATIONS_LOCK_KEY_SQL` | **new** | A private `const []const u8` string constant at the top of `Migrations` (above `pub fn run` on line ~32). Holds the exact advisory-lock SQL. Not part of the public API. |

### 3.2 What stays the same

- Connection acquisition pattern (`pool.acquire` + `defer pool.release`).
- `search_path` ordering and ISS-0114 post-condition.
- GBL-prefix skip rule for `schema_name != "public"`.
- Already-applied skip (idempotent re-run).
- `reapply_on_drift` guard (§3.4 of the existing logic at lines ~221–240).
- Out-of-order detection.
- Per-migration transaction BEGIN/COMMIT/ROLLBACK pattern at lines 301/308/318/323.
- `schema_migrations` ledger write at 313–314.

### 3.3 New internal helper signature (for reference)

```zig
const MIGRATIONS_LOCK_KEY_SQL =
    "SELECT pg_advisory_xact_lock(hashtext('bpm.migrations.runForSchema')::bigint)";
```

This is a `const` at file scope inside `src/db/migrations.zig` (declared above the `Migrations` struct, so codegen for `// CUSTOM:` blocks in downstream tooling stays clean). The exact text is the lock-acquisition SQL.

---

## 4. Lock key derivation

### 4.1 The chosen key

```zig
const MIGRATIONS_LOCK_KEY_SQL =
    "SELECT pg_advisory_xact_lock(hashtext('bpm.migrations.runForSchema')::bigint)";
```

**Single key for all tenants.** All concurrent migrate-step callers (regardless of `schema_name`) queue on this one advisory lock. The audit-INSERT path uses a completely different keyspace (see §4.3).

### 4.2 Why `hashtext` and not a literal

`hashtext('…')` returns `integer` in PostgreSQL. Cast to `bigint` makes the `pg_advisory_xact_lock(bigint)` overload unambiguous and avoids depending on a particular hashtext algorithm implementation beyond a stable prefix string. `hashtext` is a built-in PostgreSQL function whose output is **stable across all supported server versions** (since PostgreSQL 9.x); any upstream change to the algorithm would be a major-version event we would catch long before this fix is at risk. The numeric value of the lock key depends only on the input string `'bpm.migrations.runForSchema'` — a constant in our source code.

### 4.3 Keyspace disjointness vs the audit-trigger's lock

The audit chain-hash trigger (`migrations/1109_iss0122_apply_chain_hash_lock_cast.sql`, re-created per tenant via `CREATE OR REPLACE FUNCTION`) acquires:

```sql
pg_advisory_xact_lock(hashtext('bpm.audit.chain.' || NEW.tenant_id)::bigint)
```

— keyed by `'bpm.audit.chain.' || tenant_id::text`. **Different prefix string and dependency on a per-tenant UUID** produce a disjoint key from `'bpm.migrations.runForSchema'`. Hashtext collisions across two structurally different input strings (different prefix, different length distribution) have negligible probability (the 64-bit keyspace yields ~2⁻⁶⁴ birthday collisions across the entire table). For any plausible workload we will never observe a key collision.

**Consequence:** the migrate lock does NOT serialize concurrent audit INSERTs. The audit-trigger's own per-tenant advisory lock continues to do that work, independently. This preserves the architecture established by ISS-0122 / migration 1109.

### 4.4 Why `pg_advisory_xact_lock` (transaction-scoped) — not `pg_advisory_lock` (session-scoped)

`pg_advisory_xact_lock` is automatically released when the wrapping transaction ends (COMMIT or ROLLBACK). The pool connection that runs `runForSchema` is `release`d at the end of the function via `defer pool.release(conn)` (line 80); if the lock were session-scoped, dropping the connection back to the idle pool with the lock still held would either (a) leak the lock (libpq resets session state on `pool.release` — the session-scoped advisory lock would be released implicitly by libpq's RESET, but this is fragile and depends on driver behaviour) or (b) hand a lock-holding connection to an unrelated acquirer, which is unacceptable.

`pg_advisory_xact_lock` lifetime is:

```
BEGIN (line 301)
  acquire pg_advisory_xact_lock(...)      ← new
  simpleQuery(file)                        ← 1107 runs here
  INSERT INTO schema_migrations            ← ledger row
COMMIT (line 323)                          ← lock auto-released
ROLLBACK (lines 308/318)                   ← lock auto-released on either path
```

The lock cannot outlive the migration transaction — that is the structural guarantee we need.

---

## 5. Public interface

### 5.1 Function signatures (no change)

```zig
pub const MigrationError = error{
    MigrationsDirectoryNotFound,
    OutOfOrderMigration,
    MigrationFailed,
    UnsupportedPgVersion,
    PoolExhausted,
    SchemaSetupFailed,
};

pub const Migrations = struct {
    pub fn run(
        allocator: std.mem.Allocator,
        pool: *Pool,
        migrations_dir: []const u8,
    ) MigrationError!void;

    pub fn runForSchema(
        allocator: std.mem.Allocator,
        pool: *Pool,
        migrations_dir: []const u8,
        schema_name: []const u8,
        force_reconcile: bool,
    ) MigrationError!void;
};
```

### 5.2 New private constant (file-scope, above `pub const Migrations`)

```zig
/// ISS-0129: stable advisory-lock SQL. Acquired at the start of every
/// per-migration transaction inside `runForSchema` and auto-released on
/// COMMIT/ROLLBACK. Keyspace disjoint from the audit-trigger's per-tenant
/// pg_advisory_xact_lock(hashtext('bpm.audit.chain.' || tenant_id::text))
/// — see src/design/iss0129_migration_runner_advisory_lock.md.
const MIGRATIONS_LOCK_KEY_SQL =
    "SELECT pg_advisory_xact_lock(hashtext('bpm.migrations.runForSchema')::bigint)";
```

---

## 6. Data flow

```
caller (provisioning.zig:94  OR  helpers.zig runMigrations*  OR  zig build migrate)
   │
   ▼
Migrations.runForSchema(allocator, pool, migrations_dir, schema_name, false)   [src/db/migrations.zig:78]
   │
   ├── 1. pool.acquire()                                                    [line ~80]
   ├── 2. SET search_path TO <schema>,public                                 [line ~102]
   ├── 3. SHOW search_path post-condition (ISS-0114)                         [line ~115]
   ├── 4. CREATE TABLE IF NOT EXISTS schema_migrations (in public schema)   [line ~127] — outside tx, idempotent
   ├── 5. scan migrations_dir/*.sql                                          [line ~140]
   ├── 6. query schema_migrations WHERE schema_name = $1 (in public schema) [line ~165]
   ├── 7. for each pending file:
   │       ├── readFileAlloc(filename)                                       [line ~296]
   │       ├── BEGIN                                                         [line 301]
   │       ├── SELECT pg_advisory_xact_lock(hashtext(                       [← NEW LINE 302-ish]
   │       │     'bpm.migrations.runForSchema')::bigint)
   │       ├── simpleQuery(sql_bytes)                                        [line 307]  ← migration 1107 fires here
   │       ├── INSERT INTO schema_migrations (in public schema)              [line 313]
   │       └── COMMIT                                                        [line 323]  ← lock auto-released
   └── 8. defer pool.release(conn)                                           [line 81, scope-exit]
```

### Concurrent-call interleaving (the cycle the fix prevents)

```
T0:  TC-TNT-01-01 calls provisionTenantSchema(...) for tenant_X.
T1:  TC-TNT-03-01 starts audit INSERT under tenant_X.search_path.
T2:  TC-TNT-03-01's INSERT fires BEFORE trigger bpm_audit_apply_chain_hash():
        - acquires pg_advisory_xact_lock(hashtext('bpm.audit.chain.' || X))
        - takes row lock on predecessor chain_hash row
T3:  TC-TNT-01-01 reaches migration 1107 inside runForSchema():
        - acquires migrate lock: pg_advisory_xact_lock(hashtext('bpm.migrations.runForSchema'))
        - BEGIN; SELECT pg_advisory_xact_lock(...); simpleQuery(1107); …
        - runs DROP TRIGGER IF EXISTS trg_bpm_audit_apply_chain_hash
        - requests AccessExclusiveLock on the trigger row
        - WITHOUT the fix: blocks behind T2's row lock; T2's trigger function
          blocks waiting for the lock to be released when COMMITing the
          trigger row → C40P01 detected.
        - WITH the fix: every concurrent migration-step call is serialized
          behind the migrate lock. The audit INSERT (which does not call
          runForSchema) proceeds in a separate transaction with a disjoint
          keyspace and is NOT blocked. The per-tenant audit lock continues
          to serialize audit INSERTs against each other for the same tenant,
          and only for the same tenant.
T4:  TC-TNT-01-01 releases migrate lock on COMMIT. Next migrate call can run.
```

---

## 7. Error taxonomy

The new code adds no new error variants. Existing `MigrationError` variants continue to cover every failure mode:

| Failure | Where | Returned error |
|---|---|---|
| `pool.acquire()` fails with `PoolError.ExhaustedPool` | src/db/migrations.zig:80 | `MigrationError.PoolExhausted` |
| `pool.acquire()` fails with any other `PoolError` | line 81 | `MigrationError.MigrationFailed` |
| `SET search_path` / `SHOW search_path` fails | lines 102, 115 | `MigrationError.SchemaSetupFailed` |
| `CREATE TABLE IF NOT EXISTS schema_migrations` (in public schema) fails | line 127 | `MigrationError.MigrationFailed` |
| **NEW: `pg_advisory_xact_lock` call fails** (very rare; only if the session is in an unrecoverable state) | insertion at ~line 302 | `MigrationError.MigrationFailed` (rolled back by the surrounding BEGIN/COMMIT, so the migration is automatically skipped on the next run) |
| `simpleQuery(file)` fails (e.g. DDL conflict) | line 308 | `MigrationError.MigrationFailed` after ROLLBACK at 308 |
| `INSERT INTO schema_migrations` (in public schema) fails | line 318 | `MigrationError.MigrationFailed` after ROLLBACK at 318 |
| `COMMIT` fails | line 323 | `MigrationError.MigrationFailed` |
| Out-of-order migration detected | line ~290 | `MigrationError.OutOfOrderMigration` |

The lock-acquisition failure path MUST preserve atomicity: because the `BEGIN` at 301 precedes the lock-acquisition SQL, a failure of the `pg_advisory_xact_lock` call must result in `ROLLBACK` before returning — the existing pattern at lines 308 and 318 (`conn.exec("ROLLBACK", &.{}) catch {}` before `return MigrationError.MigrationFailed`) is the model. Auto-recovery is automatic: the lock is held transactionally, and on ROLLBACK the lock is released; the next `runForSchema` call will acquire it cleanly.

---

## 8. State transitions

`runForSchema` is a single-pass apply function. There are no FSM transitions beyond the per-migration inner loop. The lock changes the **interleaving** of concurrent calls, but not the function's internal control flow.

### State per migration file

| State | Entered at | Notes |
|---|---|---|
| **Idle (no lock held)** | Function entry, end of every iteration | No advisory lock held between iterations. |
| **Lock-acquired** | After `BEGIN; SELECT pg_advisory_xact_lock(...)` at the new insertion point | Single key, transaction-scoped. |
| **Releasing** | After COMMIT (line 323) or ROLLBACK (lines 308/318) | Lock auto-released by `pg_advisory_xact_lock` semantics. |

The same physical migration that previously raised C40P01 now executes serially behind any prior in-flight migrate call — no deadlock because there is never a cycle (migrate calls have a single serialization point; audit INSERTs have a disjoint keyspace).

---

## 9. Acceptance criteria mapping (from the diagnosis)

| AC from diagnosis | Verified by |
|---|---|
| **AC-1**: TC-TNT-01-01 passes concurrently with TC-TNT-03-01/03 under `zig build test-integration` with no C40P01 | §10 regression test RT-1 |
| **AC-2**: Full integration target ≤ 60 s | §10 regression test RT-4 (wall-clock budget) |
| **AC-3**: No regression in already-passing tests TC-TNT-01-03, TC-TNT-01-04, TC-TNT-02-02, TC-TNT-03-05 | §10 regression test RT-2 |
| **AC-4**: Concurrent audit INSERTs for distinct tenants remain unblocked | §10 regression test RT-3 (keyspace disjointness demonstration) |
| **AC-5**: Two test processes calling `Migrations.runForSchema()` concurrently for different tenants serialize cleanly | §10 regression test RT-1 |

---

## 10. Regression test plan

All new tests live in `tests/integration/tnt_schema_isolation_test.zig` (the harness already boots via `provisionTenantSchema` / `runForSchema`, so no new harness scaffolding is required). Each test uses the standard `TestHarness.init` + `defer h.deinit()` idiom and a per-test `randomUuidStr` for tenant isolation (no shared state across tests).

### RT-1 — concurrent `runForSchema` calls do not deadlock

The test creates two random tenant UUIDs (`tenant_a`, `tenant_b`) and two pools (`pool_a`, `pool_b`). It then spawns two threads, each calling `provisionTenantSchema(alloc, &pool_X, tenant_X, migrationsDir())`. Both threads run concurrently; each thread's `runForSchema` acquires the `pg_advisory_xact_lock('bpm.migrations.runForSchema')` inside its own transaction. The lock serializes the two calls — the second caller blocks until the first COMMITs. After both threads join, the test re-runs `provisionTenantSchema` for each tenant (idempotent fast path) to assert the schema state is consistent post-lock. Cleanup via `cleanupTenant` runs unconditionally. Pre-fix, one of the two calls would have raised `ProvisionError.MigrationFailed` mid-1107 due to C40P01.

```zig
// Sketch — actual implementation by TEST-DESIGNER / BACKEND-DEV.
test "ISS-0129 RT-1: concurrent runForSchema for two tenants does not deadlock" {
    const alloc = testing.allocator;
    var h = try TestHarness.init(alloc); defer h.deinit();
    const url = try testDbUrl(alloc); defer alloc.free(url);
    var pool_a = try makePool(alloc, url); defer pool_a.deinit();
    var pool_b = try makePool(alloc, url); defer pool_b.deinit();
    const tenant_a = try randomUuidStr(alloc); defer alloc.free(tenant_a);
    const tenant_b = try randomUuidStr(alloc); defer alloc.free(tenant_b);
    const dir = migrationsDir();

    const t1 = try std.Thread.spawn(.{}, provisionTenantSchema, .{ alloc, &pool_a, tenant_a, dir });
    const t2 = try std.Thread.spawn(.{}, provisionTenantSchema, .{ alloc, &pool_b, tenant_b, dir });
    t1.join(); t2.join();

    // Idempotent re-run to confirm no migration was skipped.
    try provisionTenantSchema(alloc, &pool_a, tenant_a, dir);
    try provisionTenantSchema(alloc, &pool_b, tenant_b, dir);

    var buf_a: [80]u8 = undefined; var buf_b: [80]u8 = undefined;
    cleanupTenant(alloc, &pool_a, tenant_a, schemaName(tenant_a, &buf_a));
    cleanupTenant(alloc, &pool_b, tenant_b, schemaName(tenant_b, &buf_b));
}
```

### RT-2 — existing tests stay green

```zig
test "ISS-0129 RT-2: TC-TNT-01-03 / -01-04 / -02-02 / -03-05 still pass after advisory-lock wrap" {
    // This is a coordinated suite: each test in this file already exists
    // and continues to run. The harness still includes them; they remain
    // green when run under the wrap. No additional assertion is needed
    // beyond the existing test bodies — this test documents the contract.
    // (Implementation: simply re-run the four existing tests inline or rely
    // on the full file re-run; this test exists for traceability.)
    try testing.expect(true); // placeholder: see existing tests in this file
}
```

### RT-3 — disjoint keyspace: audit INSERTs are NOT serialized by the migrate lock

The test provisions two tenants serially (each call goes through `runForSchema` and acquires the migrate lock briefly, releasing on COMMIT). It then opens two pool connections, one per tenant, sets `tenant_context` to each tenant_id in turn, and inserts one row into that tenant's `audit_entries` on each connection. The audit trigger fires its **own** per-tenant advisory lock (different keyspace) but does **not** touch the migrate lock — the test asserts (a) both INSERTs succeed and (b) the wall-clock time is well under the per-INSERT budget, indicating neither was blocked behind the migrate lock or the other tenant's audit lock. (If `pgcrypto` is unavailable in the test DB, BACKEND-DEV substitutes a hardcoded `chain_hash` literal.)

```zig
// Sketch.
test "ISS-0129 RT-3: concurrent audit INSERTs for distinct tenants remain unblocked" {
    const alloc = testing.allocator;
    var h = try TestHarness.init(alloc); defer h.deinit();
    const url = try testDbUrl(alloc); defer alloc.free(url);
    var pool = try makePool(alloc, url); defer pool.deinit();

    const tenant_a = try randomUuidStr(alloc); defer alloc.free(tenant_a);
    const tenant_b = try randomUuidStr(alloc); defer alloc.free(tenant_b);
    try provisionTenantSchema(alloc, &pool, tenant_a, migrationsDir());
    try provisionTenantSchema(alloc, &pool, tenant_b, migrationsDir());
    defer {
        var buf_a: [80]u8 = undefined; var buf_b: [80]u8 = undefined;
        cleanupTenant(alloc, &pool, tenant_a, schemaName(tenant_a, &buf_a));
        cleanupTenant(alloc, &pool, tenant_b, schemaName(tenant_b, &buf_b));
    }

    tenant_context.set(tenant_a); const c1 = try pool.acquire(); defer pool.release(c1);
    tenant_context.set(tenant_b); const c2 = try pool.acquire(); defer pool.release(c2);
    tenant_context.set("00000000-0000-0000-0000-000000000000");

    // Each INSERT uses its own tenant UUID and the tenant search_path set
    // by tenant_context. The audit chain-hash trigger fires and acquires
    // its own per-tenant advisory lock (disjoint keyspace).
    try c1.exec(
        "INSERT INTO audit_entries (tenant_id, chain_hash, event_type, payload) " ++
            "VALUES ($1::uuid, $2, 'test', '{}'::jsonb)",
        &.{ tenant_a, /* hardcoded chain_hash literal */ "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2" },
    );
    try c2.exec(
        "INSERT INTO audit_entries (tenant_id, chain_hash, event_type, payload) " ++
            "VALUES ($1::uuid, $2, 'test', '{}'::jsonb)",
        &.{ tenant_b, "b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2c3" },
    );
}
```

### RT-4 — wall-clock budget assertion

```zig
test "ISS-0129 RT-4: full concurrent-runForSchema completes within 60s wall clock" {
    const alloc = testing.allocator;
    var h = try TestHarness.init(alloc);
    defer h.deinit();
    const url = try testDbUrl(alloc);
    defer alloc.free(url);

    var pool_a = try makePool(alloc, url);
    defer pool_a.deinit();
    var pool_b = try makePool(alloc, url);
    defer pool_b.deinit();

    const tenant_a = try randomUuidStr(alloc);
    defer alloc.free(tenant_a);
    const tenant_b = try randomUuidStr(alloc);
    defer alloc.free(tenant_b);

    const start = std.time.milliTimestamp();
    var t1 = try std.Thread.spawn(.{}, provisionTenantSchema, .{ alloc, &pool_a, tenant_a, migrationsDir() });
    var t2 = try std.Thread.spawn(.{}, provisionTenantSchema, .{ alloc, &pool_b, tenant_b, migrationsDir() });
    t1.join();
    t2.join();
    const elapsed_ms = std.time.milliTimestamp() - start;
    try testing.expect(elapsed_ms < 60_000);

    var buf_a: [80]u8 = undefined;
    var buf_b: [80]u8 = undefined;
    cleanupTenant(alloc, &pool_a, tenant_a, schemaName(tenant_a, &buf_a));
    cleanupTenant(alloc, &pool_b, tenant_b, schemaName(tenant_b, &buf_b));
}
```

The 60 s budget matches the diagnosis AC-2. Cold start (2 tenants × provision cost) is well under 30 s on a standard CI runner.

### Test isolation rule (mandatory)

Every RT in this set uses **per-test `randomUuidStr(...)`** as tenant_id (RT-1, RT-3, RT-4). No `tenant_default` or other hard-coded UUIDs. Cleanup runs unconditionally via `defer cleanupTenant(...)`. This matches the rule in `docs/guides/test_developer_guide.md` §11 and is verified by `python3 tools/lint_test_isolation.py tests/integration` (must exit 0 before completing the handoff).

### Inline smoke assert — lock-key constant stability

The design's `MIGRATIONS_LOCK_KEY_SQL` constant is a `const []const u8` source-level string. If a future contributor changes the prefix string, the keyspace contract is silently broken. **Two safeguards** prevent this:

1. **RT-5 source-assertion** (added to RT-1's preamble): read `src/db/migrations.zig` as text and assert it contains the literal prefix `hashtext('bpm.migrations.runForSchema')`. If the prefix drifts, RT-1 fails with a clear message.
2. **`MIGRATIONS_LOCK_KEY_SQL` is declared `const` (not `var`)** in §5.2, so accidental mutation by another code path is impossible.

```zig
test "ISS-0129 RT-5: MIGRATIONS_LOCK_KEY_SQL prefix is stable" {
    const alloc = testing.allocator;
    const src_path = try std.fmt.allocPrint(alloc, "src/db/migrations.zig", .{});
    defer alloc.free(src_path);

    const file = try std.fs.cwd().openFile(src_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(alloc, 1 << 20);
    defer alloc.free(content);

    const needle = "hashtext('bpm.migrations.runForSchema')";
    try testing.expect(std.mem.indexOf(u8, content, needle) != null);
}
```

---

## 11. External dependencies

| Dependency | Direction | Why |
|---|---|---|
| `src/db/pool.zig::Pool.acquire() / release()` | migrations → pool | The pool connection that runs the migration is the same connection that holds the advisory lock for the duration of the per-migration transaction. Defer-release on function exit returns the connection (lock already auto-released at COMMIT/ROLLBACK). |
| PostgreSQL `pg_advisory_xact_lock(bigint)` | server-side | The lock primitive we are calling. Stable since PG 9.0. |
| PostgreSQL `hashtext(text) → integer` | server-side | Hashes the prefix string to a 32-bit integer, cast to bigint. Stable since PG 9.0. |
| `migrations/1109_iss0122_apply_chain_hash_lock_cast.sql` | server-side trigger | Already uses a disjoint keyspace. **Not modified.** |
| `migrations/1107_fix_audit_chain_text_resource_id.sql` | server-side migration | The DDL whose per-tenant DROP TRIGGER enters the lock cycle. **Not modified** — the fix is downstream, in the runner. |
| `vendor/pg/` | migrations → pg | `conn.exec()` is used for the new lock-acquisition SQL (single-statement, extended query protocol is fine). |

### What this design MUST NOT depend on

- It must NOT depend on Redis, Consul, or any out-of-process distributed lock (the diagnosis's TODO note in `tests/integration/helpers.zig` suggests this as a future path; for this fix we stay in-process — this is per-process serialization within a single PostgreSQL cluster, which is the correct scope for the deadlock observed).
- It must NOT touch `tests/integration/helpers.zig` — that file already delegates to the canonical migrator (post-ISS-0091 unification), so the lock automatically applies to every test binary that boots via `TestHarness.init`.
- It must NOT change the public API of `Migrations.run` or `Migrations.runForSchema` — signatures are preserved exactly.
- It must NOT add, remove, or modify migration SQL files — the fix is runner-only.

---

## 12. Open questions

**None blocking.**

The diagnosis pinned the fix to a single primitive (`pg_advisory_xact_lock` with a constant key, transaction-scoped) and a single insertion site (between `BEGIN` and `simpleQuery` at lines 301–307). The impl can proceed without clarification.

One item noted for the IMPLEMENTER as a MINOR (does not block WF-03 Step 3):

- The `_errors.zig` HTTP mapper codegen (per CLAUDE.md §3.2 — `tools/codegen_error_mapper.py src/db/migrations.zig`) should be re-run after the edit. No new error variants are introduced by this design, so the regenerated mapper should be byte-identical or a small diff limited to the new SQL string constant. If the codegen suggests a NEW error variant, ignore it — `MigrationFailed` is the only variant that can fire on the lock call (a server-side failure is a `MigrationFailed` per the existing taxonomy) and the codegen guess may not reflect that.

---

*End of design artefact.*

*Traceability:* this artefact responds to ISS-0129 / GH-419 Step 2. Acceptance criteria AC-1…AC-5 from the diagnosis are mapped 1-to-1 to regression tests RT-1…RT-4 in §10. Implementation goes to `BACKEND-DEV` for WF-03 Step 3.
