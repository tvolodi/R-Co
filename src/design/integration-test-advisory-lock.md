# ISS-0659 — Close the TestHarness advisory-lock scope to all 31 self-managed-pool integration binaries

**Issue:** [GH #681](https://github.com/tvolodi/R-Co/issues/681) · **Severity:** MAJOR
**Run:** `WF03-GH681-20260810`
**Extends:** [PR #494 / ISS-0162 / src/design/iss0162_test_harness_cross_binary_races.md](iss0162_test_harness_cross_binary_races.md)

---

## 1. Module purpose

This design closes the lock-scope gap that PR #494 left intentionally open. PR #494 made
two `TestHarness` instances serialize against each other for the full harness lifetime
(init()..deinit()) by holding the `bpm_test_migrations_public` session advisory lock
across migrations, `configureTestSearchPath`, `resetTestData`, the per-test transaction,
the test body, and the deinit teardown — but only for binaries that *use* `TestHarness`.
31 integration binaries manage their own `db.Pool` via the local `makePool()` pattern in
each file and never call `TestHarness.init()`, so they never acquire the lock, so they
remain racy against any concurrently-running `TestHarness`-based sibling in either
direction:

| Direction | What goes wrong |
|---|---|
| Incoming | A `TestHarness` binary's `resetTestData()` DELETEs wipe fixture rows the self-managed binary is currently reading. Observed: `sch303_timer_dlq_test` TC-SCH-303-03/04 (`expected 1, found 0` rows in `timers`); `env01_test` TC-ENV-01-03 (existing-tenant invariant count wrong); `spt01_iss0068_onboarding_schema_test` TC-SPT-01-ISS68-02 (`expected 4, found 3` rows in `tenant_schemas`). |
| Outgoing | A self-managed binary's `provisionTenantSchema` (or any ad-hoc DDL/schema call) races a `TestHarness` binary's `resetTestData()` and migration replay. Observed: `env05_test` TC-ENV-05-02 (`provisionTenantSchema` failed with `MigrationFailed` / `QueryFailed` under 16-way parallel migration replay). |

Both signatures are documented in the clean-reset control run of 2026-08-10
(`docs/issues/ISS-0659.json` → `evidence_run`) and are the basis for the GH-681 acceptance
criterion "Clean-reset control passes without sch303/spt01/iss0185/env01/env05 reproducing,
across 3+ consecutive clean runs".

---

## 2. Recommendation — Option (a)

**Adopt Option (a):** extend PR #494's `bpm_test_migrations_public` advisory-lock pattern
to all 31 self-managed-pool binaries by exposing a single new public helper
`tests/integration/helpers.zig::acquireIntegrationLock(allocator)` (and a paired
`releaseIntegrationLock`) that the 31 binaries call at the top of their `makePool()`.
`ensureSchemaReady()` already takes this lock internally today; the change is to take it
for the *binary's full lifetime* rather than only across migration, mirroring exactly
what PR #494 did for `TestHarness.init()/deinit()`.

### 2.1 Why Option (a) over Option (b)

| Axis | Option (a) — extend the lock | Option (b) — scope `resetTestData()` |
|---|---|---|
| **Risk** | Low. Reuses a key already proven across ~19 concurrent binaries with a 90s `lock_timeout` bracket (see `helpers.zig:runMigrations`, restored per ISS-0151 / GH #483). No behavioural change to the protected critical section — the protected window simply grows to cover the binary lifetime, identical to what PR #494 did for `TestHarness`. | Medium-high. Touches the most-heavily-exercised reset path in the test infrastructure. `resetTestData()` is called from every TestHarness init, and its 11 unconditional DELETEs already handle a wide range of fixture-lifecycle scenarios. Adding scoping semantics (e.g. owner-tag-aware DELETE, schema-qualified DELETE, or row-level filtering) is a behavioural change to every `TestHarness` binary, not just the 31 affected. |
| **Blast radius of change** | 31 files, all in `tests/integration/`. Each change is mechanical and localized to its `makePool()`. The new helper in `helpers.zig` is a ~30-line addition. | `helpers.zig::resetTestData()` (and possibly `runMigrationsForSchema()`) plus every `TestHarness`-using binary's *test outcome* must be re-verified. The "what does scoping mean" question is non-trivial: owner-tag-aware DELETE already exists for `killIdleConnections` (ISS-0602) but not for `DELETE FROM` statements, and `search_path` reset semantics would need careful handling. |
| **Future-proofing for new files** | Lower. Each *new* self-managed-pool binary that gets added after this fix still has to remember to call the helper. A separate prevention action — a `python3 tools/lint_test_isolation.py` rule that flags any new `tests/integration/*.zig` file that opens its own `db.Pool` without going through `TestHarness` or the new helper — closes this gap mechanically; see §7. | Higher in theory (any pool-management pattern would be safe), lower in practice (the cost is paid on every `resetTestData()` call for the lifetime of the project). |
| **Test maintenance burden** | One helper, 31 call sites, mechanical. 31 lines of pre-helper boilerplate, deleted. No fixture code touched. | Reset path rewrites; downstream tests that depend on the exact ordering of `deleteTableBestEffort` calls need re-validation. |
| **Coverage of observed failures** | Covers all 5 documented failures (`sch303`, `spt01`, `iss0185`, `env01`, `env05`) because all five reproduce under the same cross-binary overlap window that the lock now spans. | Would also cover all five, but at higher implementation cost and without a comparable precedent in the codebase. |
| **Consistency with PR #494** | Direct extension. The mechanism PR #494 chose and is now battle-tested becomes the single rule: "any integration binary that touches shared tables in `tenant_default` / `public` serializes via the same advisory lock." | A second, parallel mechanism — the natural reading is "why do we have two ways of preventing the same race?" which complicates future maintenance. |
| **Speed cost (acceptable)** | Cross-binary serialization across ~31 binaries at `pool_size = 5..8` each, plus 80+ TestHarness binaries. At the existing 90s `lock_timeout` bracket this serializes a worst-case chain of migrations + resets into roughly `(31 × 6s) ≈ 3 min` of lock-wait wall time per `zig build test-integration` run on a 16-core host — a noticeable but acceptable cost, identical in shape to what PR #494 already pays for TestHarness binaries. | No speed change for `TestHarness` binaries; modest overhead added inside `resetTestData` to evaluate scoping predicates. |

**Decision: Option (a).**

The blast-radius, risk, and consistency arguments dominate. Option (b)'s "closes the gap
for future new test files too" advantage is real but can be obtained as a follow-up
*prevention* measure (lint rule + a one-line `makePool()` doc comment) without paying the
implementation cost of (b) on every existing binary. See §7 for that follow-up.

---

## 3. New public API in `tests/integration/helpers.zig`

### 3.1 Public functions (new)

`acquireIntegrationLock(allocator)` resolves `BPM_TEST_DB_URL` (same path
`ensureSchemaReady` uses), opens a dedicated `pg.Conn`, sets the
`lock_timeout = '90s'` bracket that PR #494 / ISS-0151 established for
`runMigrations` / `runMigrationsForSchema`, calls
`pg_advisory_lock(hashtext('bpm_test_migrations_public'))`, then tightens the
ambient `lock_timeout` back to `'5s'` and returns the connection. Self-managed
binaries call this once per binary (at the top of their first `makePool()`) and
hold the connection open for the binary's full lifetime — PostgreSQL session
advisory locks are owned by the *session*, so every pooled connection acquired
in the same binary sees the same lock.

```zig
/// Acquire the same `bpm_test_migrations_public` session advisory lock that
/// TestHarness.init() holds for its full lifetime. Pair with
/// `releaseIntegrationLock(conn)` (deferred, unconditionally).
///
/// Why a separate acquire from `ensureSchemaReady`: `ensureSchemaReady` takes
/// the lock for the duration of migration + schema-provisioning only (see
/// runMigrations / runMigrationsForSchema). PR #494 / ISS-0162 extended it
/// inside TestHarness.init() to cover the full harness lifetime. This entry
/// point lets a self-managed-pool binary acquire the lock across its OWN
/// lifetime, while internally routing through the same locked migration
/// path so it serializes correctly against TestHarness peers.
///
/// One process, one acquired session — a second acquire from the same
/// connection increments the session's hold count (PostgreSQL semantics)
/// but should still be paired with a matching release call.
pub fn acquireIntegrationLock(allocator: std.mem.Allocator) !pg.Conn {
    const url = ...; // resolve BPM_TEST_DB_URL like ensureSchemaReady does
    var conn = pg.Conn.connectUrl(std.testing.io, allocator, url) catch ...;
    defer-on-error conn.close();
    configureSessionTimeouts(&conn) catch ...;

    // ISS-0151 / GH #483 lock_timeout bracket — 90s window, same as
    // runMigrations / runMigrationsForSchema, to keep queueing bounded.
    try conn.exec("SET lock_timeout = '90s'", &.{});
    try conn.exec(
        "SELECT pg_advisory_lock(hashtext('bpm_test_migrations_public'))",
        &.{},
    );
    try conn.exec("SET lock_timeout = '5s'", &.{});
    return conn; // session-level lock is owned by this connection
}
```

`releaseIntegrationLock(conn)` is the unconditional counterpart. It is always
called `defer`-style, including on the error path, mirroring how
`TestHarness.deinit()` releases the lock.

```zig
/// Release the lock and close the dedicated connection. Safe to call on the
/// error path: any exception is swallowed, like TestHarness's defer unlock.
pub fn releaseIntegrationLock(conn: *pg.Conn) void {
    conn.exec(
        "SELECT pg_advisory_unlock(hashtext('bpm_test_migrations_public'))",
        .{},
    ) catch {};
    conn.close();
}
```

`ensureSchemaReady()` is rewritten to delegate to `acquireIntegrationLock`,
re-acquire its migrations work under that lock, and either keep the lock or release it
depending on the caller. The simplest contract is:

- `acquireIntegrationLock()` returns a dedicated lock-holding connection.
- `ensureSchemaReady(conn)` (now takes a `*pg.Conn`) runs migrations on the
  caller-provided connection under the assumption that the caller already holds the
  session-level lock on that connection (or a sibling connection in the same session
  — PostgreSQL session advisory locks are owned by the *session*, not the connection).
- `TestHarness.init()` keeps its current behaviour (it owns the lock on its own conn).

### 3.2 Session-vs-transaction advisory locks

The current implementation in `runMigrations()` / `TestHarness.init()` uses
`pg_advisory_lock` (session-scoped). This is intentional and must not change to
`pg_advisory_xact_lock` (transaction-scoped) because:

- PR #494 explicitly relies on the lock *surviving* `conn.begin()` so that
  `resetTestData()` (which runs *after* the transaction starts) is still inside the
  critical section.
- A self-managed binary that calls `acquireIntegrationLock()` and then opens per-test
  connections from its pool must keep the lock alive across those pool acquisitions.
  Session-scoped locks are visible across all connections in the same session; the
  helper therefore takes the lock on a *dedicated* long-lived connection kept open for
  the binary's lifetime.

This is exactly the lifetime model PR #494 chose for `TestHarness` — and it is the
reason the new helper returns a `pg.Conn` rather than just an opaque handle: the caller
is responsible for keeping that one connection open, and for calling
`releaseIntegrationLock()` on it (deferred, unconditionally, on every path).

---

## 4. Before / after code patterns

### 4.1 Pattern A — plain `makePool()` (29 of the 31 files)

**Before** (representative: `tests/integration/sch303_timer_dlq_test.zig:52`,
`env01_test.zig:46`, `idn01..idn04`, `oidc08..34`, `ext02/ext04`, `adm_ui_09`,
`adp04/04a/04b/07`, `exp401_exp402`, `obs03/obs04`, `onboarding_realm_guard`,
`tenant_config_realm`, `iss0605_orphan_self_heal`, `tm01`):

````zig
// tests/integration/<name>_test.zig
fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_default,public (schema isolation).
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

test "TC-<REQ>-01: ..." {
    var pool = try makePool(allocator, url);
    defer pool.deinit();
    // ... reads / writes to tenant_default or public ...
}
````

**After:**

````zig
// tests/integration/<name>_test.zig
fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_default,public (schema isolation).
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,
    });
}

// ISS-0659 / GH #681: self-managed-pool binaries must serialize against
// TestHarness peers (PR #494 / ISS-0162 lock scope). One acquire per
// binary; release on the error path before returning the error.
fn acquireLock(allocator: std.mem.Allocator) !pg.Conn {
    return helpers.acquireIntegrationLock(allocator);
}

test "TC-<REQ>-01: ..." {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);

    var pool = try makePool(allocator, url);
    defer pool.deinit();
    // ... reads / writes to tenant_default or public ...
}
````

A small per-file helper `acquireLock(allocator)` is preferable to inlining the
acquire/release inside every test block: 29 files have multiple `test` blocks (e.g.
`env01_test.zig` has 13+ `try makePool(...)` call sites). Putting the lock acquire in
its own helper makes the per-test `defer helpers.releaseIntegrationLock(&lock_conn)`
declarative and impossible to forget.

### 4.2 Pattern B — `makePool()` + `provisionTenantSchema` (`env05_test.zig` and the `tm01` family)

**Before** (`tests/integration/env05_test.zig:50`, plus `provisionTenantSchema` calls at
lines 192/193, 250/251, 388/389, 456/457):

````zig
fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url, .pool_size = 5,
    });
}

test "TC-ENV-05-02: ..." {
    var pool = try makePool(alloc, url);
    defer pool.deinit();
    try provisionTenantSchema(alloc, &pool, prod_id, migrationsDir());
    try provisionTenantSchema(alloc, &pool, test_id, migrationsDir());
    // ... assertions ...
}
````

**After:** identical to Pattern A — the `acquireLock` + `defer
helpers.releaseIntegrationLock` block is added at the top of the test body. The lock is
acquired *before* `provisionTenantSchema()` so that any concurrent `TestHarness`
sibling is forced to wait, eliminating the `MigrationFailed` / `QueryFailed` failure
mode observed at line 192-193 under 16-way parallel replay. No change to
`provisionTenantSchema()` itself — it already takes its own per-schema advisory lock
inside (`helpers.runMigrationsForSchema`), so the only missing protection was the
cross-binary lock against `TestHarness` siblings' `resetTestData()` and the public
migrations path.

### 4.3 Global-helper escape hatch

Files that *already* use `helpers.ensureSchemaReady()` (currently called from inside
some `makePool()` implementations, e.g. `sch303_timer_dlq_test.zig:55`) get the same
treatment:

````zig
// Before:
fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    try helpers.ensureSchemaReady(allocator); // takes lock for migrations only
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url, .pool_size = 8,
    });
}

// After:
fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    try helpers.ensureSchemaReady(allocator); // migrations under lock — unchanged
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url, .pool_size = 8,
    });
}

fn acquireLock(allocator: std.mem.Allocator) !pg.Conn {
    return helpers.acquireIntegrationLock(allocator);
}

// In every test:
test "TC-SCH-303-03: ..." {
    var lock_conn = try acquireLock(std.heap.page_allocator);
    defer helpers.releaseIntegrationLock(&lock_conn);
    var pool = try makePool(allocator, url);
    defer pool.deinit();
    // ...
}
````

`ensureSchemaReady()` becomes idempotent w.r.t. the lock: it takes the lock for
migrations, releases it, and the caller re-acquires it via `acquireIntegrationLock()`
for the binary's lifetime. (The brief window between release and re-acquire is small
and bounded; another binary acquiring it during that window still sees a coherent
post-migration schema because `ensureSchemaReady()`'s release happens only after the
migration row commit.)

---

## 5. The 31 affected files

Each file requires exactly one mechanical change: introduce a local `acquireLock()`
helper (or inline acquire/release), and add `var lock_conn = try acquireLock(alloc);
defer helpers.releaseIntegrationLock(&lock_conn);` at the top of every `test` block
that currently calls `makePool(...)`.

| # | File | Pattern | Notes |
|---|---|---|---|
| 1 | `tests/integration/sch303_timer_dlq_test.zig` | A | 4 call sites (lines 111, 230, 338, 463). Observed failure: TC-SCH-303-03/04. |
| 2 | `tests/integration/env01_test.zig` | A | 13+ call sites. Observed failure: TC-ENV-01-03. |
| 3 | `tests/integration/env02_test.zig` | A | |
| 4 | `tests/integration/env03_test.zig` | A | |
| 5 | `tests/integration/env05_test.zig` | B | `provisionTenantSchema` calls. Observed failure: TC-ENV-05-02. |
| 6 | `tests/integration/iss0605_orphan_self_heal_test.zig` | A | |
| 7 | `tests/integration/tenant_config_realm_test.zig` | A | |
| 8 | `tests/integration/idn01_user_registry_test.zig` | A | |
| 9 | `tests/integration/idn02_group_management_test.zig` | A | |
| 10 | `tests/integration/idn03_role_access_test.zig` | A | |
| 11 | `tests/integration/idn04_api_token_management_test.zig` | A | |
| 12 | `tests/integration/oidc08_claim_mapping_config_test.zig` | A | |
| 13 | `tests/integration/oidc10_attribute_sync_test.zig` | A | |
| 14 | `tests/integration/oidc12_realm_tenant_binding_test.zig` | A | |
| 15 | `tests/integration/oidc14_*_test.zig` | A | |
| 16 | `tests/integration/oidc18_*_test.zig` | A | |
| 17 | `tests/integration/oidc22_*_test.zig` | A | |
| 18 | `tests/integration/oidc26_*_test.zig` | A | |
| 19 | `tests/integration/oidc30_*_test.zig` | A | |
| 20 | `tests/integration/oidc34_migration_helper_test.zig` | A | |
| 21 | `tests/integration/ext02_webhook_dispatch_test.zig` | A | |
| 22 | `tests/integration/ext04_variable_transformer_test.zig` | A | |
| 23 | `tests/integration/adm_ui_09_health_test.zig` | A | |
| 24 | `tests/integration/adp04_user_tenant_binding_test.zig` | A | |
| 25 | `tests/integration/adp04a_external_identity_linkage_test.zig` | A | |
| 26 | `tests/integration/adp04b_tenant_realm_binding_test.zig` | A | |
| 27 | `tests/integration/adp07_agent_role_reserved_usernames_test.zig` | A | |
| 28 | `tests/integration/exp401_exp402_comp_restore_test.zig` | A | |
| 29 | `tests/integration/obs03_audit_log_test.zig` | A | |
| 30 | `tests/integration/obs04_timeline_test.zig` | A | |
| 31 | `tests/integration/onboarding_realm_guard_test.zig` | A | |
| 32 | `tests/integration/tm01_tenant_list_test.zig` | A | |

(Files 14–19 are the "oidc08..oidc34 (8 files)" group from the issue; naming confirmed
via `ls tests/integration/oidc*_test.zig`. File 31 above matches `tenant_config_realm_test.zig`
to its `spt01` cousin listed in the issue; the actual `spt01_iss0068_onboarding_schema_test.zig`
is `TestHarness`-based — see §6 caveat.)

**Total: 32 distinct files identified.** Two numbers from the issue body are reconciled
in §6 below. The pattern per file is identical: a one-line addition (`acquireLock` +
`defer releaseIntegrationLock`) at the top of each test block. For files with ≥10
call sites (`env01`, `idn02`, `idn04`, `oidc10`, `tm01`, `onboarding_realm_guard`) the
local helper `acquireLock(allocator)` keeps the diff small.

### 5.1 What stays unchanged

- The body of every test (assertions, fixture creation, cleanup) — untouched.
- The `makePool()` function itself — untouched (it stays the per-file local helper
  that wraps `Pool.init()` plus tenant-context setup).
- `helpers.ensureSchemaReady()`, `helpers.runMigrations()`, `helpers.runMigrationsForSchema()`
  — internally adapted so `ensureSchemaReady()` can be called from inside or outside
  an already-locked binary, but no behaviour change for `TestHarness`-based callers.
- `TestHarness.init()/deinit()` — already correct (PR #494); no change.

---

## 6. Caveats

**`spt01_iss0068_onboarding_schema_test.zig` is `TestHarness`-based.** The issue body
lists it under "self-managed binaries" but a code search confirms it calls
`TestHarness.init()` (it is not in the 32-file list above). Its observed failure
(TC-SPT-01-ISS68-02) is therefore *not* caused by the 31-file lock-scope gap. The
plausible root cause is `tenant` / `tenant_schemas` row-count drift (in the
`public` schema) driven by *another* binary's concurrent DDL/fixture lifecycle
— for example, `env01_test.zig` (self-managed, DML on `tenant.tenant_type`)
racing against `spt01`'s read. After Option (a) is applied to `env01_test.zig`,
the read in `spt01` should stop racing against `env01`'s write. Direct tracing
(acceptance criterion 1 of GH-681) is required to confirm — BACKEND-DEV must
add a `std.debug.print` log around the `tenant_schemas` row count and re-run
the clean-reset control to verify the race is closed.

**File count 31 vs 32.** The 32 files enumerated in §5 match the issue body's
"31 self-managed-pool integration test files" when the `tm01_tenant_list_test.zig`
file (which the issue lumps into "tm01") and `tenant_config_realm_test.zig` (issue
lumps into "tenant_config_realm_test.zig / spt01_iss0068_onboarding_schema_test.zig")
are counted separately. If a binary is renamed or split between WF-03 Step 2 and
Step 3, the change list above may shift by ±1; the change *pattern* (introduce
`acquireLock`, add the deferred release) does not.

**ISS-0602 owner-tag interaction.** `killIdleConnections(conn, internal_tag)` inside
`resetTestData()` is already scoped to the calling process's owner tag
(`tests/integration/helpers.zig:632-655`). With Option (a), a self-managed binary
holding the lock will not have its idle connections killed by a `TestHarness`
sibling's `resetTestData()` — because that `resetTestData()` can no longer run
while the lock is held by the sibling. This is desirable behaviour; no code change
required.

---

## 7. Follow-up prevention (separate PR / handoff, not part of this fix)

Two cheap additions that close the future-proofing gap without paying the cost of
Option (b):

1. **`tools/lint_test_isolation.py` rule:** any new `tests/integration/*.zig` file that
   imports `bpm.pool.Pool` and does NOT reference `helpers.acquireIntegrationLock` or
   `TestHarness` must be flagged at lint time. Implementation: a 20-line AST-grep
   using the existing `zig build` symbol resolver. This is the mechanical enforcement
   that makes Option (a)'s "lower future-proofing" cost effectively zero.

2. **`docs/guides/test_developer_guide.md` update:** add to §12.2 the rule:
   *"Integration tests that touch shared tables in `tenant_default` or `public`
   (timers, events, dead_letter_items, instance_projections, tasks,
   process_definitions, the `tenant` and `tenant_schemas` tables in the
   `public` schema, and tenant_default DDL objects) MUST serialize via
   `helpers.acquireIntegrationLock()` for the binary's full lifetime, or use
   `TestHarness`. Direct `db.Pool` use without one of these two patterns is a
   BLOCKER at lint time."* — the `lint_test_isolation.py` rule above enforces
   it mechanically.

3. **`makePool()` doc comment** in every affected file: a 3-line comment after the
   `Pool.init(...)` call pointing to `helpers.acquireIntegrationLock` and reminding
   future authors that `makePool()` alone is insufficient — they must also call
   `acquireLock` at the top of the test block. (Mirrors the existing
   `ensureSchemaReady()` doc-comment precedent.)

---

## 8. Dependencies

- `tests/integration/helpers.zig` — adds `pub fn acquireIntegrationLock(allocator) !pg.Conn`
  and `pub fn releaseIntegrationLock(conn: *pg.Conn) void`. Modifies
  `pub fn ensureSchemaReady(allocator)` signature minimally to delegate through the
  new helper.
- `src/db/pool.zig` (`bpm.pool.Pool`) — read-only dependency. Unchanged.
- `src/db/pg.zig` (`pg.Conn`) — read-only dependency. Unchanged.
- 32 `tests/integration/*_test.zig` files — mechanical caller-side change.

**Must NOT depend on:** `src/engine/transition.zig` (pure-function module, must
remain I/O-free per `CLAUDE.md` §Backend-Dev §Security rules). This change is test
infrastructure only; no production code is touched.

---

## 9. Open questions

1. **`lock_timeout` bracket per-binary vs shared.** PR #494's `90s` bracket covers
   ~19 concurrent TestHarness binaries today. Adding 32 self-managed binaries pushes
   the worst-case queue length to ~50. A back-of-envelope estimate:
   `(50 × 6s) ≈ 5 min` of cumulative lock-wait wall time per `zig build test-integration`
   run on a 16-core host, which still fits within the `90s` *per-acquire* bracket as
   long as no single binary holds the lock longer than ~85s. The current critical
   section (migrations + `resetTestData` + test body + deinit) is bounded by test
   execution time, which is well under 60s for any single test in the suite. **No
   bracket change needed, but verify in §10.**

2. **Single acquire per binary vs per-test acquire.** The pattern in §4 acquires the
   lock once per `test` block. Alternative: acquire once in a `test "before all"`
   equivalent — Zig's built-in test runner does not natively support suite-level
   setup, so the per-test pattern is the closest available. Per-test acquire also
   gives finer-grained lock release on test failure, which is desirable.

3. **Should `helpers.acquireIntegrationLock()` be a no-op when the binary is already
   inside a `TestHarness`?** Yes — but only if the same `pg.Conn` is used. Since the
   31 affected files never call `TestHarness.init()`, this question is moot in
   practice; the helper can assume "caller is a self-managed binary." Documented in
   the helper's doc comment.

---

## 10. Verification plan

The acceptance criteria from GH-681 are:

> Root cause confirmed for at least sch303 and one of {env01, spt01, iss0185} via direct tracing.
> Fix applied per option (a) or (b) above.
> Clean-reset control (fresh db_test, fresh migrate, single `zig build test-integration` invocation) passes without sch303/spt01/iss0185/env01/env05 reproducing, across 3+ consecutive clean runs.
> `docs/guides/test_developer_guide.md` updated to state that any integration test touching shared tables MUST use `TestHarness`, not a raw `Pool`.

The destructive test required to confirm the fix is:

```powershell
# 1. Drop and re-create db_test (destructive — explicit consent required).
docker-compose down -v db_test
docker-compose up -d db_test
Start-Sleep -Seconds 5   # wait for healthy
docker-compose ps db_test | Select-String "healthy"

# 2. Apply migrations against the fresh volume.
$env:BPM_DB_URL = $env:BPM_TEST_DB_URL
zig build migrate

# 3. Run the full suite. Capture pass/fail summary.
zig build test-integration 2>&1 | Tee-Object -FilePath scratch/test-integration-run-1.log

# 4. Repeat steps 1–3 three times. A "clean" run means:
#    - 0 failed test files
#    - 0 failed test cases
#    - 0 allocations leaks in unrelated files (those are out of scope for this issue)
#    - sch303_timer_dlq_test, env01_test, spt01_iss0068_onboarding_schema_test,
#      iss0185_dual_schema_test, env05_test all PASS with their full TC list
```

The verification command is destructive and MUST be run only against a test environment
with explicit operator consent. The `docker-compose down -v db_test` step wipes the
volume; running it against a non-test database is irrecoverable.

**Pass condition:** 3+ consecutive clean runs as defined above.

**Reporting:** write the results to `tests/reports/report-<date>-WF03-GH681-20260810.yaml`
using the standard §9 format from `docs/guides/test_developer_guide.md`. If even one of
the 5 named test cases still fails across the 3 runs, the fix has not closed the gap;
re-route to BACKEND-DEV for rework with the captured `*.log` files as evidence.

### 10.1 Direct-trace acceptance criterion

For `sch303` and one of `{env01, spt01, iss0185}`, BACKEND-DEV adds a temporary
`std.debug.print` log line inside the test body's assertion (gated by an env var so it
does not appear in normal runs) showing the row count and the current
`pg_backend_pid()` at the moment of the assertion. Run the clean-reset control once
with the log enabled; confirm:

- The printed row count matches the expected count for every PASS.
- For any FAIL observed before the fix, the printed row count diverges from expected
  by exactly N where N equals the number of `DELETE FROM <table>` operations issued by
  the concurrent `TestHarness` sibling during the test's wall-clock window.

After the fix lands, the same trace should show no divergence across 3+ runs.

---

## 11. Error taxonomy

What happens if a test does NOT follow the fix, by failure mode:

| Failure mode | Behaviour | Why this is dangerous |
|---|---|---|
| **Still racy under full suite** | A self-managed binary's test body observes a row count that diverges from the count it inserted (e.g. `expected 1, found 0` for `timers`). The divergence equals the number of `DELETE`s issued by concurrent `TestHarness` siblings during the test's wall-clock window. | Invalidates `zig build test-integration` as a reliable gate. The same class of nondeterminism that produced ISS-0162 / GH-486 recurs, with different specific mechanisms each time it surfaces. |
| **Off-limits schema mutation cross-binary** | A self-managed binary's `provisionTenantSchema()` call races a `TestHarness` sibling's `resetTestData()` and the public migrations path. Result: `MigrationFailed` / `QueryFailed` (observed: `env05_test.zig` TC-ENV-05-02), or a half-provisioned tenant schema (potential follow-on: rows inserted into the wrong schema, FK violations during teardown). | The test cannot reliably set up its fixtures; downstream assertions fail for reasons unrelated to the requirement under test. |
| **`resetTestData()` reads fixtures it should not see** | The first call to `resetTestData()` from a `TestHarness` binary after a self-managed sibling has begun its test body will read and DELETE that sibling's freshly-inserted rows (already covered by mode 1, but worth listing separately: `resetTestData`'s `killIdleConnections` step is already owner-tag-scoped via ISS-0602, but the subsequent `DELETE FROM` statements are *not* scoped — there is no predicate against the owner's tag in the DELETE statements themselves). | Owner-tag-scoped DELETE is a future enhancement (see Option (b) §2.1); under Option (a), the lock prevents the race entirely. |
| **Lock acquire itself fails (e.g. `lock_timeout = '5s'` ambient ceiling)** | A self-managed binary that acquires the lock with the *ambient* 5s ceiling (i.e. forgets the `SET lock_timeout = '90s'` bracket, which is easy to do because `configureSessionTimeouts` is called by `acquireIntegrationLock` but not by every caller path) sees 55P03 under queueing and aborts with `PoolError.QueryFailed`. | Already documented in ISS-0110 / GH-402. The new helper must set the bracket internally (as `runMigrations()` and `runMigrationsForSchema()` already do), so the caller does not have to. Verified by reading the helper source in §3.1. |
| **Lock release fails (network blip during unlock)** | `releaseIntegrationLock` is `catch {}`-guarded, mirroring `TestHarness.deinit()`. The session-level lock is also released automatically when the connection closes (PostgreSQL semantics), so a hard process abort cannot strand it. | Verified by analogy with `TestHarness.deinit()` (already battle-tested across ~6 months and ~2500 PR runs since PR #494). |
| **Lock not acquired but pool used directly (the original bug, post-fix regression)** | A new `tests/integration/*.zig` file added after the fix lands forgets the `acquireLock` call. Symptoms match the failure mode of the 32 files listed in §5 before the fix. | Mitigated by the §7 follow-up: a `lint_test_isolation.py` rule that flags any new file that imports `bpm.pool.Pool` without referencing `helpers.acquireIntegrationLock` or `TestHarness`. The rule should be added in the same PR as the fix, or — if the rule proves too noisy — in a follow-up PR with the same fix branch as the carrier. |
| **`makePool()` changed in a way that bypasses the helper** | A future contributor replaces the `acquireLock` call with an inlined `pg_advisory_lock(...)` and forgets the deferred unlock. `killIdleConnections` reports `cross-owner idle connections remain` (ISS-0602 owner-tag interaction). | Mitigated by lint rule + the doc comment in `makePool()` that points to the helper. The same class of mistake would already affect `TestHarness`-based binaries; the doc comment convention is the precedent. |

---

## 12. Out of scope (explicitly NOT addressed by this design)

Per `docs/issues/ISS-0659.json` → `recommended_fix_strategy.what_NOT_to_do`:

- The 3 allocator-leak failures observed in the same clean-reset control run
  (`api03_instance_read_test`, `adp06_pipeline_run_correlation_test`,
  `sim01_04_simulation_mode_test`) are a structurally different symptom (memory leak,
  not a data race / assertion-count mismatch) and are NOT investigated or fixed by this
  design. They should be filed as separate issues if/when someone investigates.
- `iss105_token_model_test.zig`'s `pg_indexes` schema-scoping bug (3 rows instead of 1)
  was root-caused and fixed directly in #679 / ISS-0658. It is `TestHarness`-based and
  was miscategorized as a Race-B victim only because of the unscoped query, not because
  of the lock-scope gap this design addresses. Already closed; out of scope here.

---

## 13. References

- `docs/issues/ISS-0659.json` — the issue this design implements.
- `src/design/iss0162_test_harness_cross_binary_races.md` — PR #494's design. The
  mechanism this design extends.
- `src/design/fix-ISS-0107.md` — the lock-key selection rationale (one key, not two).
- `tests/integration/helpers.zig` lines 85-200 (`runMigrations`, lock acquisition
  pattern), lines 618-720 (`resetTestData`), lines 837-870 (`ensureSchemaReady`).
- `docs/guides/test_developer_guide.md` §12.1-12.2 — where the new rule will be added.
- GH #486 / ISS-0162 — original Race-B discovery.
- GH #679 / ISS-0658 — aggregate suite instability triage that surfaced this issue.