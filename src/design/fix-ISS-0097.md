# Fix design — ISS-0097 / GH-352

**threadlocal tenant context not inherited by worker threads spawned mid-test**

Status: DESIGNED
Author: CODE-DESIGNER step, WF03-GH352-20260809
Related: ISS-0095 (GH-349, prior/adjacent fix), ISS-0070 (GH-285, production
occurrence of the same architectural gap, discovered as a regression during
this investigation — filed and forwarded separately, NOT fixed by this design)

---

## 1. Investigation findings (mandatory per issue body)

### 1.1 The threadlocal mechanism

`src/api/tenant_context.zig` stores the resolved tenant id and storage mode in
Zig `threadlocal var` storage:

```zig
pub threadlocal var _current: [36]u8 = DEFAULT_TENANT_ID.*;
pub threadlocal var _has_value: bool = false;
pub threadlocal var _storage_mode: StorageMode = .LEGACY_RLS;
pub threadlocal var _storage_mode_resolved: bool = false;
```

`get()` returns `""` unless `set()` was called on **this exact OS thread**.
Zig threadlocal storage is per-thread by construction — a `std.Thread.spawn()`
worker starts with a fresh, zero-initialized copy regardless of what the
spawning thread had stored. This is not a bug in `tenant_context.zig`; it is
the documented, correct semantics of `threadlocal var`, and — per `db/pool.zig`
comments — appears to be deliberately relied on elsewhere to avoid one
request's tenant leaking into a different request's connection on a
thread-pooled server.

### 1.2 How `pool.acquire()` reads it

`src/db/pool.zig`:

```zig
fn currentRequestTenantId() []const u8 {
    return tenant_context_mod.get();
}
...
fn applyRequestStorageRouting(conn: *Conn) PoolError!void {
    const tenant_id = currentRequestTenantId();
    if (tenant_id.len == 0) {
        try conn.exec("SET search_path TO public", &.{});
        return;
    }
    ... // SCHEMA or LEGACY_RLS routing using the resolved tenant_id
}
```

`Pool.acquire()` (line ~802) calls `applyRequestStorageRouting(conn)`
unconditionally on every checkout (line ~837), before returning the
connection to the caller. There is no per-call parameter to `acquire()` that
can override the ambient threadlocal value — the routing decision is made
entirely from `tenant_context_mod.get()` at acquire time, read from whichever
OS thread called `acquire()`.

Consequence: a worker thread that never calls `tenant_context.set(...)` gets
`tenant_id.len == 0` on every `acquire()` it performs, unconditionally routing
to `SET search_path TO public` — regardless of what the spawning thread's
threadlocal held.

### 1.3 `TC-EE-10-05` in `tests/integration/instance_error_test.zig`

```zig
const t1 = try std.Thread.spawn(.{}, worker.run, .{&ctx1});
const t2 = try std.Thread.spawn(.{}, worker.run, .{&ctx2});
t1.join();
t2.join();
```

`worker.run` calls `ctx.store.setInstanceError(...)`
(`InstanceStore.setInstanceError`, `src/engine/instance.zig:2701`), which
calls `self.pool.acquire()` at line 2714. The main test thread's `makePool()`
helper (line 76-84 of this test file) correctly calls
`bpm.api_tenant_context.set("00000000-...-000000000000")` **before**
`Pool.init()` — but that `set()` only affects the main thread's own
threadlocal. Neither `t1` nor `t2` calls `set()` on its own thread, so both
workers' `pool.acquire()` calls route to `search_path=public`, where the
`instance_projections`/`events`/etc. business tables no longer exist
post-GBL-073 (a `tenant_default`-scoped table set). The test fails inside
`setInstanceError`'s SQL, not from any race-condition defect in
`setInstanceError` itself.

This confirms the issue's own diagnosis: the fix does **not** belong in
`makePool()` (already correct, already runs on the right thread) — it belongs
wherever the worker thread's entry function begins.

### 1.4 Production-impact grep — `std.Thread.spawn` in `src/` (the issue's explicit request)

Four call sites found in `src/` (excluding `tests/`, `src/design/*.md` prose,
and comments):

| # | Call site | Spawned function | Touches `pool.acquire()`? | Verdict |
|---|---|---|---|---|
| 1 | `src/webhook/dispatcher.zig:667` | `CaptureServer.run` | No | **Test-only.** `CaptureServer` is an in-process HTTP capture server embedded in this source file's own `test "..."` blocks (uses `std.testing.io`, `std.testing.allocator`); it has no DB/pool interaction of any kind. Not a production path despite living in `src/`. |
| 2 | `src/identity/provider/bootstrap.zig:472` | `KcHttpCallState.threadFn` → `doFetch` | No | Production path (Keycloak realm-bootstrap HTTP call issued on its own thread so a fresh `std.Io.Threaded` avoids stale APC state — see the surrounding comment). Pure `std.http.Client` HTTP call; never touches `db.Pool`. |
| 3 | `src/api/routes/onboarding.zig:151` | `runSagaBackground` → `identity/onboarding.zig::executeSaga` | **Yes** | Production path — see §1.5 below. This is the one that matters. |
| 4 | `src/lua/timeout.zig:212` | `watchdogLoop` | No | Production path (Lua script execution timeout watchdog). Touches only `WatchdogState`'s three `std.atomic.Value` fields (design explicitly documents "never `L`, never `RunLimiter`/`MemoryLimiter`" — INV-6); no DB access at all. |

### 1.5 Call site 3 — does the onboarding saga's production use of `pool.acquire()` on a spawned thread actually break?

`runSagaBackground` (`src/api/routes/onboarding.zig:249`) runs
`onboarding_mod.executeSaga(gpa, ctx.manager, ctx.pool, ...)` entirely on the
spawned/detached background thread. `executeSaga` and its helpers
(`createTenantInDb`, `validateProductionTenantRef`,
`db_provisioning.provisionTenantSchema`) all call `pool.acquire()` from that
thread, which never calls `tenant_context.set()`. So — exactly like
`TC-EE-10-05` — every `acquire()` on this path routes to
`search_path=public`.

**This turns out to be harmless for tenant/schema provisioning specifically,
by design, not by luck:**

- `createTenantInDb` and `validateProductionTenantRef` operate on
  `public.tenant` — the canonical, sole home of the global tenant registry
  (confirmed: `pg_class`/`pg_namespace` shows `tenant` exists only in
  `public`). Routing to `search_path=public` reaches the correct table
  either way.
- `db_provisioning.provisionTenantSchema` explicitly schema-qualifies every
  statement it issues (`public.tenant_schemas`, `public.tenant`,
  `public.bpm_provision_tenant_schema()`) — it never relies on ambient
  `search_path` routing to reach a tenant-scoped table. Its one write to
  `tenant_context_mod` (`setStorageMode(.SCHEMA)`, provisioning.zig:247) is
  a **priming write** for the *next* acquire in the *same* thread, not a
  read of ambient state.
- `migrations.Migrations.runForSchema` (called from `provisionTenantSchema`)
  sets its own `search_path` directly on the acquired connection
  (`migrations.zig:124-129`) immediately after acquire, overriding whatever
  `applyRequestStorageRouting` set. It is deliberately independent of the
  threadlocal-driven routing.

**But one write on this exact call path IS broken by the same architectural
gap, and it is a live, currently-failing production defect:**
`persistOnboardingResult` (`src/api/routes/onboarding.zig:516-544`), called
at the end of `runSagaBackground` on the same un-contexted background
thread, issues `UPDATE tenant_default.onboarding_registry ...`. This was
originally a *correct* workaround for **ISS-0070** (GH-285, opened
2026-06-15) — filed for precisely this thread-spawn/threadlocal gap, before
ISS-0097 existed as its own issue. It schema-qualified the table explicitly
instead of relying on `search_path` routing. It was correct at the time
because `onboarding_registry` was, for a period, duplicated into
`tenant_default` as an unintended dual-schema shadow table.
`migrations/GBL-134_iss0185_drop_global_registry_shadows.sql` (ISS-0185, GH
#518) subsequently dropped that shadow — `onboarding_registry`'s sole home
per migration `056`'s own `-- scope: public` header was always `public` —
but `persistOnboardingResult`'s hardcoded qualifier was never updated to
match. Confirmed live against this workspace's `bpm_test`
(2026-08-09T17:27Z): `UPDATE tenant_default.onboarding_registry` throws
`relation "tenant_default.onboarding_registry" does not exist`, silently
swallowed by the surrounding `catch {}`. Every onboarding-saga background
completion (success or failure) currently fails to persist its terminal
state.

**This is a genuine, currently-live production gap** — but it is a
*different* defect (a stale/wrong schema qualifier left over from a
previous, no-longer-applicable fix for ISS-0070, now further stale after
ISS-0185's cleanup) than what ISS-0097 is scoped to fix (a test file's
worker threads not calling `tenant_context.set()` at all). Per this
project's issue-queue protocol and the explicit instruction not to
scope-creep a MINOR/test-only issue into fixing an unrelated, more severe
production finding: **this has been filed as an update to the existing
ISS-0070/GH-285 (not a new issue — GH-285 is still open, its 2026-07-29
"LIKELY_FIXED" triage was never confirmed by a test run, and this is a
regression of that same open issue caused by GBL-134), commented on GH-285,
and forwarded to the global queue for its own WF-03 run.** It is NOT fixed
on this branch.

### 1.6 Existing precedent in `tests/`

A broader grep of `std.Thread.spawn` in `tests/` (10 files) shows this exact
problem was already hit and fixed twice before, using the same pattern:

- `tests/integration/concurrent_instances_test.zig`, `completionThread`
  (line 240-246) and a second worker (line 372-374): both call
  `bpm.api_tenant_context.set(DEFAULT_TENANT_ID)` as the **first statement**
  inside the spawned thread's own entry function, before any `pool.acquire()`.
- `tests/integration/iss102_claim_test.zig`, `claimWorkerThread`
  (line 352-354): identical pattern.

Neither of these files touches `pool.zig`, `Pool.acquire()`, or introduces
any new API surface — they simply make the worker thread responsible for its
own tenant context, exactly as the main thread already is.

`tests/integration/audit_chain_utf8_test.zig` spawns two threads (lines 412,
453) that do NOT call `pool.acquire()` at all (confirmed by grep — no
`pool.acquire` in that file), so they are unaffected by this gap and require
no change.

---

## 2. Fix direction chosen

**Chosen: pass the tenant id into the worker thread's context struct, and
have the worker's entry function call `bpm.api_tenant_context.set(...)` as
its first statement — mirroring the exact pattern already proven in
`concurrent_instances_test.zig` and `iss102_claim_test.zig`.**

Concretely, in `tests/integration/instance_error_test.zig`:

1. Add a `tenant_id: []const u8` field to the `ThreadCtx` struct (or simply
   read the already-in-scope `"00000000-0000-0000-0000-000000000000"`
   literal directly inside `worker.run`, matching this file's own existing
   style — it does not use a named `DEFAULT_TENANT_ID` constant anywhere,
   unlike `concurrent_instances_test.zig`).
2. `worker.run` calls `bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000")`
   as its first statement, before calling `ctx.store.setInstanceError(...)`.

### 2.1 Why this direction and not the other two

The issue lists three possible directions and explicitly asks for reasoned
trade-offs, not a mechanical pick:

**(a) Chosen — pass an explicit tenant-id into worker thread entry functions;
call `.set()` as the first statement.**
- Minimal: touches only the test file, zero production code, zero API
  surface change.
- Preserves the existing threadlocal-for-request-isolation design intact.
  Per `db/pool.zig`'s `ISS-501` comments, storage-mode/tenant routing is
  deliberately threadlocal so that a thread handling one request's
  connection never leaks another request's tenant scoping — the fix must
  not weaken that guarantee.
- **Already proven correct** by two other test files using the identical
  pattern for the identical problem (`concurrent_instances_test.zig`,
  `iss102_claim_test.zig`) — this is not a novel design, it is applying an
  established, working convention to a third file that was missing it.
- Confirmed by this issue's own investigation (§1.5) that production code
  does NOT currently need this fix — the one production call site that
  spawns a thread touching `pool.acquire()` (onboarding saga) either
  reaches tables whose canonical/sole home is `public` (so the "no tenant"
  fallback routing is correct) or explicitly overrides `search_path` itself
  rather than depending on ambient routing. So there is no discovered
  production need to justify a larger change.

**(b) Rejected — a pool-level API that accepts an explicit tenant id
per-`acquire()`.**
- This is a real, bigger surface change: every one of the dozens of existing
  `pool.acquire()` call sites across `src/` would need to decide whether to
  pass an explicit tenant id or keep using ambient threadlocal routing,
  creating two parallel routing mechanisms to reason about.
- Nothing in this investigation surfaced a call site that actually needs
  per-acquire explicit tenant routing — the one production case that spawns
  threads touching the pool already works via schema-qualified SQL, not via
  wanting a different tenant per acquire.
- Justified only if multiple call sites needed it; none do today. Adding
  unused API surface "for the future" is scope creep on a MINOR,
  test-scoped issue.

**(c) Rejected — restructure `tenant_context` storage to not be
threadlocal.**
- Most invasive of the three, and the issue itself flags that it "needs a
  concurrency-safety review" before it could even be considered.
- The comments already in `pool.zig` (ISS-501) indicate the threadlocal
  design is deliberate — it exists specifically so a thread-pooled server
  never lets one request's resolved tenant/storage-mode leak into a
  different request handled later by the same OS thread. Removing
  threadlocal isolation (e.g. moving to a request-scoped struct threaded
  explicitly through every call) would be a legitimate architecture
  improvement in the abstract, but it is answering a question nobody asked
  here: nothing in this investigation found a *correctness* problem with
  threadlocal-per-request in the actual request-handling path — only in a
  test file's worker threads, and (separately, already filed) in one
  production write that has its own narrower, already-attempted fix.
- Severity as stated in the issue is MINOR, contingent on the production
  check in §1.5 not finding a production-severity gap. It did not (the one
  production thread-spawn site touching the pool works correctly by
  construction, independent of this gap) — so nothing here justifies
  invalidating the deliberate threadlocal-isolation design.

### 2.2 Scope boundary

This design fixes **only** `TC-EE-10-05` in
`tests/integration/instance_error_test.zig`. The `persistOnboardingResult`
regression found in §1.5 is explicitly **out of scope** for this design and
this branch — it is tracked as an update to ISS-0070 / GH-285 and forwarded
to the global queue for its own WF-03 run.

---

## 3. Acceptance criteria

- [ ] `TC-EE-10-05` passes against a live `BPM_TEST_DB_URL` (no `search_path`
      fallback to `public`, both worker threads see
      `tenant_default,public` routing).
- [ ] No change to any file under `src/` (this is a test-only fix, per
      §1.5's conclusion that no production defect requires a code change
      here).
- [ ] No new public API surface added to `pool.zig` or `tenant_context.zig`.
- [ ] `zig build` exits 0 with no "error set" output.
- [ ] `zig build test` (full unit suite) shows no regressions.
