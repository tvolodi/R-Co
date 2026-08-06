# ISS-0162 — Two cross-binary races in the shared integration TestHarness

**Issue:** [GH #486](https://github.com/tvolodi/R-Co/issues/486) · **Severity:** MAJOR
**Run:** `WF03-ISS-0162-20260806`

---

## Reproduction (established before any change)

Serial runs are stable — 6/6 consecutive `zig build test-integration-exp` runs gave 12/12.
The instability is **cross-binary**, so it only appears when two or more test binaries run
against the shared `bpm_test` database at once. Three concurrent invocations reproduced
both signatures the issue describes on the first attempt:

| Concurrent run | Result | Signature |
|---|---|---|
| 1 | 10/12 | `StoreError.InstanceNotFound` + `expect(r2.is_duplicate)` failure |
| 2 | 11/12 | `expect(r2.is_duplicate)` failure |
| 3 | 12/12 | clean |

Both failures are preceded by `killIdleConnections: unexpected cross-owner idle connections
remain` / `resetTestData: cross-owner idle connections remain; continuing`.

---

## Race B — `resetTestData` deletes a live sibling's fixture rows

**This is the root cause of both observed failures, and it is a lock-scope defect.**

`TestHarness.init()` (`tests/integration/helpers.zig`) holds the
`bpm_test_migrations_public` advisory lock across migrations →
`configureTestSearchPath` → `resetTestData` → `ensureDefaultOidcSeeds`, then **explicitly
releases it** before `conn.begin()` and before returning the harness to the test body.

So the lock makes init mutually exclusive *with other inits*, and nothing more. The
sequence that fails:

```
binary A: init ─ lock ─ resetTestData ─ unlock ─ BEGIN ─── test body writes fixtures ───▶
binary B:            (queued on lock) ──── lock ─ resetTestData ─ unlock ─ ...
                                                  ▲
                                    DELETEs A's rows, COMMITTED, while A's
                                    test is mid-flight
```

`resetTestData` issues unconditional `DELETE`s against `instance_projections`, `events`,
`process_definitions`, and nine other shared tables in the `tenant_default` schema — a
schema **every** integration binary provisions and shares. Those deletes commit. Binary A's
per-test transaction is READ COMMITTED, so each new statement in A sees B's committed
deletion. Hence:

- the synthetic entity-type instance vanishes → `StoreError.InstanceNotFound`
- the first call's idempotency row vanishes → the replay is no longer recognised as a
  duplicate → `expect(r2.is_duplicate)` fails

The per-test transaction does **not** isolate the test from this: it isolates A's *writes*
from other readers, not A's *reads* from another session's committed deletes. That is the
assumption the current design gets wrong.

### Fix

Hold the advisory lock for the **whole harness lifetime** — acquire in `init()`, release in
`deinit()` — instead of releasing it after `resetTestData`. This makes the entire
init-through-teardown window mutually exclusive across binaries, which is the actual
correctness requirement: no binary may run `resetTestData` while another binary's test is
live.

This extends the existing, already-battle-tested `bpm_test_migrations_public` key rather
than introducing a second key. Per `src/design/fix-ISS-0107.md`, a distinct key would
reopen the same race (two keys give mutual exclusion only within each key's own critical
section, never across them).

**Cost:** integration binaries that share `tenant_default` now serialize fully rather than
only through init. This is the correct trade — they were never actually safe to overlap;
the suite only appeared to work because the overlap window was narrow. The existing
90s `lock_timeout` bracket already accommodates queueing across ~19 binaries.

**Release must be unconditional.** `deinit()` runs on every path, and the unlock is
`catch {}`-guarded so it can never block teardown. A session-level advisory lock is also
released automatically when the connection closes, so a hard process abort cannot strand
it.

---

## Race A — `schema_migrations` 23505 on `tenant_default`

`src/db/migrations.zig` is the **only** writer to `public.schema_migrations` that does not
use `ON CONFLICT DO NOTHING`:

| Writer | Guard |
|---|---|
| `src/db/migrations.zig:490` | **none** ← |
| `src/tools/migrate.zig:245` | `ON CONFLICT DO NOTHING` |
| `tests/integration/helpers.zig:83` | `ON CONFLICT DO NOTHING` |
| `migrations/GBL-133_*.sql` (both inserts) | `ON CONFLICT DO NOTHING` |

The runner already re-checks "was this applied?" under the transaction-scoped
`bpm.migrations.runForSchema` lock (added for ISS-0144), which closes the common
check-then-act window. But the bare `INSERT` remains the single unguarded write in the
system, and it converts any residual race into a **hard failure of the entire binary**:
once one file trips 23505, every later block fails at `TestHarness.init` with
`error.OutOfOrderMigration`, cascading one race into five apparent failures.

### Fix

Add `ON CONFLICT (schema_name, version) DO NOTHING` to the ledger insert, matching every
other writer. The row's only purpose is to record that this `(schema_name, version)` is
applied; if a concurrent holder recorded it first, the desired end state already holds and
failing is wrong.

This is defence in depth, not the primary fix — the recheck-under-lock is what prevents the
duplicate DDL. This ensures that if the ledger write ever does collide, the outcome is a
no-op rather than a cascading binary-wide failure.

**Not** a duplicate of #483/ISS-0151 (`tenant_<uuid>`, `clean_test_db` sweep racing tenant
provisioning). This is `tenant_default`, which that sweep excludes by construction.

---

## Acceptance criteria

- [ ] 3 concurrent `test-integration-exp` invocations all report 12/12
- [ ] Neither `InstanceNotFound` nor `expect(r2.is_duplicate)` appears under concurrency
- [ ] `zig build test-integration-exp` still passes serially
- [ ] The ledger insert is the only behavioural change in `src/db/migrations.zig`
