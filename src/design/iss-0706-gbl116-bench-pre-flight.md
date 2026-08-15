<!-- filepath: src/design/iss-0706-gbl116-bench-pre-flight.md -->

# Design: ISS-0706 / GH-791 — GBL-116 pre-flight blocks `zig build bench` on a fresh DB

- **Run:** WF03-GH791-20260815
- **Branch:** `feature/WF03-GH791-20260815` (off `main` at `0e4d24bf`)
- **Issue:** GH-791 / ISS-0706
- **Diagnosis source:** `handoffs/WF03-GH791-20260815/diagnosis-01.md`
- **Design author:** CODE-DESIGNER (Step 02)
- **Design classification:** Type E (novel / cross-cutting — runner + build wiring; no templated CRUD/migration pattern fits)

---

## 1. Summary

Two interlocking defects break `zig build bench` on a fresh DB:

1. The bench step's transitive `zig build migrate` child process inherits the
   bench's environment but receives **no `BPM_DB_URL`** (only
   `BPM_BENCH_DB_URL`), so `migrate.zig` exits at line 18 with
   `BPM_DB_URL environment variable is not set` before any migration runs.
2. Even when `BPM_DB_URL` IS propagated, the in-loop hook's
   `provisionTenantSchema` call at `migrate.zig:142-187` is **silently
   swallowed** (`std.log.warn` then `return`) — when the call fails, the
   default tenant's `tenant_schemas.migrations_applied_at` stays `NULL`,
   and the GBL-116 pre-flight loop at `migrations/GBL-116_tnt07_rls_cleanup.sql:39-56`
   trips with `RAISE EXCEPTION 'TNT-07 pre-flight failed. Unready tenants: <uuid>'`.

The fix is **(a) + (d)** from the diagnosis: inject the resolved bench URL
into the migrate child process so `migrate.zig` can connect, **and** fail
loudly inside `migrate.zig` when the post-condition
(`migrations_applied_at IS NOT NULL` for the default tenant) is not
satisfied after the hook ran. The GBL-116 pre-flight gate stays untouched —
both legs push the bench path into a state where the gate's contract is
genuinely satisfied, so production behaviour is unchanged.

The fix is bidirectional and bi-directional in scope: surgical (runner + 5
lines of build.zig wiring + 1 static string in the cosmetic error
message) and isolated to the bench path; no schema change, no migration
file change, no change to the gate's contract.

---

## 2. Approach (a + d) — concrete plan

### 2.1 Leg (a) — Build-time URL injection

The cleanest fix is to make `build.zig`'s `run_bench` step declare the
URL it intends to use as `BPM_DB_URL` for the migrate child process.
This mirrors the contract migrate.zig's hard `BPM_DB_URL` read at
`src/tools/migrate.zig:17-21` already assumes, and it is symmetric with
the CI fresh-DB path at `.github/workflows/ci.yml:441` which already does
this via the step's `env:` block.

A static injection at build-time avoids any process-boundary coupling
between `bench.zig` and `migrate.zig`: the migrate child reads the env
var before opening its first connection, so a late injection (e.g. via
running a sidecar provisioning script) would not arrive in time.

#### 2.1.1 Resolution order to encode

The injection must mirror `tests/bench/bench.zig::resolveDbUrl` precedence
exactly (verified line-by-line in
`tests/bench/bench.zig:131-176`):

1. `BPM_BENCH_DB_URL` (preferred bench-specific URL)
2. `BPM_DB_URL` (generic primary)
3. `BPM_TEST_DB_URL` (last-resort test DB)
4. `.env` lookup of the same three keys, in the same order

A custom approach (e.g. "always use `BPM_TEST_DB_URL`") would silently
divert the bench from a primary DB to a test DB on operator machines,
worsening the situation. The mirror is mandatory.

#### 2.1.2 Mechanism — `setEnvironmentVariable` on the migrate step

`build.zig:3764-3768` already constructs `run_migrate`. The bench step
at `build.zig:3789-3798` already declares `run_bench.step.dependOn(&run_migrate.step)`.
The injection is a single
`run_migrate.setEnvironmentVariable("BPM_DB_URL", <resolved>)` call placed
at the bench step's construction site, BEFORE the `dependOn` line.

`setEnvironmentVariable` is the right API (not `addPrefixedEnvironmentVariable`):
the merge semantics of `addPrefixed*` would prepend the parent environment's
value, which is exactly what we want to override (the orchestrator may
have set a stale `BPM_DB_URL`).

### 2.2 Leg (d) — Loud post-condition check in `migrate.zig`

The existing in-loop hook at `src/tools/migrate.zig:142-187` and the
post-loop fallback at `migrate.zig:297-315` both swallow `MigrationFailed`
errors with `std.log.warn`. The fix is to add a post-condition check
immediately after the `provisionTenantSchema(...)` call returns from
either site:

```
After provisionTenantSchema returns (either site):
    SELECT count(*) FROM public.tenant_schemas
     WHERE tenant_id            = $1::uuid
       AND migrations_applied_at IS NOT NULL
```

If the count is 0 AND the call was actually attempted (i.e. the pool
opened successfully — captured by a local `provision_attempted: bool`)
THEN `std.log.err(...)` and `std.process.exit(1)`.

If the pool itself never opened (the existing `catch |err| { std.log.warn(...); return; }`),
the function must keep the soft-warn behaviour: that is a separate
"DB unreachable" failure mode the operator must debug themselves, and
the bench path already has its own retry-fallback via
`BPM_TEST_DB_URL` (see `tests/bench/bench.zig:55-69`).

The post-condition is **only checked when the provisioning call was
actually attempted**, because pre-ISS-502 DBs (where the default tenant
was provisioned but `migrations_applied_at` was never set because the
DB was bootstrapped before the hook landed) need to migrate on
subsequent runs without a hard failure. After the first successful
run of the new code, the post-condition naturally holds, so subsequent
migrations are unblocked.

### 2.3 What we DON'T do (and why)

- **No change to `migrations/GBL-116_tnt07_rls_cleanup.sql`'s pre-flight.** The
  gate stays strict. Production must keep failing when the contract is
  violated; only the bench path is forced to honour the contract.
- **No carve-out for the `00000000-0000-0000-0000-000000000000` tenant.**
  This is the exact "magic tenant" pattern that ISS-0707 / `INV-1`
  anti-patterns warn against (see `docs/anti-patterns.md`).
- **No shell-script bootstrap.** Approach (c) from the diagnosis — a
  bash that manually `UPDATE`s `migrations_applied_at` — would silently
  defeat the gate's intent for any future maintainer who doesn't know
  about the script.
- **No change to `tests/bench/bench.zig::resolveDbUrl`.** The bench's
  existing precedence is correct; we only need to mirror it in build.zig.

---

## 3. Files to change (with line numbers and signature diffs)

### 3.1 `build.zig` — inject `BPM_DB_URL` into the migrate child process

**Edit site:** between lines 3791 and 3795 (after the existing
`run_bench.setCwd(...)` and `run_bench.setEnvironmentVariable("BPM_MIGRATIONS_DIR", ...)`
calls, BEFORE the `run_bench.step.dependOn(&run_migrate.step)` line).

**Intent:** Add a URL-resolution helper that mirrors `bench.zig::resolveDbUrl`
precedence, then call `run_migrate.setEnvironmentVariable("BPM_DB_URL", <resolved>)`.

#### 3.1.1 New helper function (signature only — no implementation)

```zig
/// Mirror of tests/bench/bench.zig::resolveDbUrl precedence:
///   BPM_BENCH_DB_URL -> BPM_DB_URL -> BPM_TEST_DB_URL -> .env lookup of same three.
/// Returns the URL string and the source name (for diagnostic logging).
/// MUST stay byte-for-byte equivalent to the bench's resolver — diverging
/// causes the bench and its migrate child to disagree about which DB they
/// are about to touch.
fn resolveBenchMigrateDbUrl(b: *std.Build) struct { url: []const u8, source: []const u8 } {
    // Reads from b.graph.env_map (the static build env), then falls back to
    // .env file lookup using the same env-candidate list as bench.zig.
}
```

**Inputs:**

- `b: *std.Build` — to access `b.graph.env_map` (the static build
  environment inherited from the shell).
- The `.env` file at the project root (read via `std.Io.Dir.cwd().readFileAlloc`,
  same approach as `tests/bench/bench.zig::readDotEnvValue`).

**Outputs:**

- `url: []const u8` — the resolved DB URL (lifetime: lives for the
  duration of the build; we copy if needed).
- `source: []const u8` — one of `"BPM_BENCH_DB_URL"` / `"BPM_DB_URL"` /
  `"BPM_TEST_DB_URL"` / `"<none>"` for the `BENCHMARK_SETUP_INFO` log
  line.

**Failure mode:** if no URL is found in env OR `.env`, **do NOT set
`BPM_DB_URL`** — leave `migrate.zig`'s own `BPM_DB_URL environment variable is not set`
error to surface (the bench path will then exit with a clear error in
the bench binary itself, see `bench.zig:48-51`). The CI fresh-DB path
sets `BPM_DB_URL` in its `env:` block, so it remains unaffected.

#### 3.1.2 Wiring at `run_bench` construction (lines 3789-3798)

```zig
// AFTER (existing):
//    run_bench.setCwd(b.path("."));
//    run_bench.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir);
// ADD:
//    if (resolveBenchMigrateDbUrl(b)) |resolved| {
//        run_migrate.setEnvironmentVariable("BPM_DB_URL", resolved.url);
//        std.debug.print("BENCH_MIGRATE_URL_INFO|source={s}\n", .{resolved.source});
//    }
//    // (else: leave BPM_DB_URL unset so migrate.zig's own error surfaces)
// THEN (existing):
//    run_bench.step.dependOn(&run_migrate.step);
```

**Note on ordering:** `run_migrate` is declared at `build.zig:3764-3768`,
BEFORE `run_bench` at `build.zig:3789`. Both `addRunArtifact` calls
produce `*Step` objects; the env-var injection must happen AFTER both
declarations but BEFORE the `dependOn` call. The injected env-var
takes effect at run time, when migrate.zig's main() reads the
environ_map via `init.environ_map.get("BPM_DB_URL")` (line 17).

#### 3.1.3 Why this exact pattern (vs alternatives considered)

- **Inject `BPM_TEST_DB_URL` only as a fallback:** rejected — the
  existing `bench.zig::resolveDbUrl` already prefers `BPM_BENCH_DB_URL`
  over `BPM_DB_URL` over `BPM_TEST_DB_URL`. Mirroring that order is
  the only correct behaviour.
- **Have `bench.zig` call `provisionTenantSchema` directly (Approach a
  alternative):** rejected — adds a coupling between `bench.zig` and a
  Zig runtime helper (`@import("db_provisioning")`) that `bench.zig`
  currently doesn't import; the build.zig approach is zero-import.
- **Set `BPM_DB_URL` in `.vscode/tasks.json` only:** rejected — most
  bench invocations are via `zig build bench` from arbitrary shells; a
  build-time static injection is the only reliable scope.

### 3.2 `src/tools/migrate.zig` — fail loudly on post-condition miss

**Edit sites:** the in-loop hook at lines 142-187 AND the post-loop
fallback at lines 297-315. Both sites have the same shape; the diff
intent is identical for both.

#### 3.2.1 In-loop hook diff (lines 172-187)

**Before (current):**

```zig
const default_tenant_id = "00000000-0000-0000-0000-000000000000";
db_provisioning.provisionTenantSchema(allocator, &provision_pool, default_tenant_id, build_options.migrations_dir) catch |err| {
    std.log.warn("default tenant schema provisioning failed: {} (tenant_id={s})", .{ err, default_tenant_id });
};
```

**After (intent):**

```zig
const default_tenant_id = "00000000-0000-0000-0000-000000000000";
var provision_attempted: bool = true;  // set false in the pool-open catch arm
db_provisioning.provisionTenantSchema(allocator, &provision_pool, default_tenant_id, build_options.migrations_dir) catch |err| {
    std.log.warn("default tenant schema provisioning failed: {} (tenant_id={s})", .{ err, default_tenant_id });
};

// Post-condition check (leg d): migrations_applied_at must be set after
// the hook returns. If the call returned without throwing but the column
// is still NULL, provisionTenantSchema failed silently — refuse to proceed
// into GBL-gated migrations. See src/design/iss-0706-gbl116-bench-pre-flight.md
// for the full rationale.
if (provision_attempted) {
    var lock_conn = provision_pool.acquire() catch |err| {
        std.log.err("post-condition: could not acquire pool connection: {}", .{err});
        std.process.exit(1);
    };
    defer provision_pool.release(lock_conn);
    const count_row = lock_conn.query(allocator,
        "SELECT count(*)::bigint FROM public.tenant_schemas WHERE tenant_id = $1::uuid AND migrations_applied_at IS NOT NULL",
        &.{default_tenant_id},
    ) catch |err| {
        std.log.err("post-condition: query failed: {}", .{err});
        std.process.exit(1);
    };
    defer count_row.deinit();
    const count: i64 = if (count_row.rows.len > 0 and count_row.rows[0].len > 0 and count_row.rows[0][0] != null)
        std.fmt.parseInt(i64, count_row.rows[0][0].?, 10) catch 0
    else
        0;
    if (count == 0) {
        std.log.err("post-condition: default tenant_schemas.migrations_applied_at is NULL after provisionTenantSchema() returned — aborting migrate", .{});
        std.process.exit(1);
    }
}
```

**Exact `lock_conn` acquisition API:** must match the Zig version in
use (0.16.0 per `.github/workflows/ci.yml:432`). Verify against
`src/db/pool.zig` for the current `acquire()` / `release()` signature
before patching. The pseudocode above is the design intent; the
BACKEND-DEV agent must match the live API. Most likely shape (based on
the existing code's `pool.init` calls at line 175):

```zig
const lock_conn = provision_pool.acquire() catch |err| { ... };
defer provision_pool.release(lock_conn);
```

#### 3.2.2 Pool-open catch arm (lines 172-175)

**Before:**

```zig
var provision_pool = pool_mod.Pool.init(init.io, allocator, .{ .url = url, .pool_size = 2 }) catch |err| {
    std.log.warn("default tenant schema provisioning skipped: could not open pool: {}", .{err});
    return;
};
```

**After (intent):** same body, but declare `provision_attempted: bool = false;`
BEFORE the loop iteration where this lives, and set `provision_attempted = true;`
immediately after the pool opens. The post-condition check is gated on
`provision_attempted`, so a DB-unreachable scenario continues to emit
the existing `warn` and `return` (no behavioural change for unreachable
DBs).

#### 3.2.3 Post-loop fallback (lines 297-315)

**Identical pattern to 3.2.1.** Replace the silent-swallow call with a
call followed by the same post-condition check, gated on the same
`provision_attempted` flag.

#### 3.2.4 Why NOT change the surrounding error semantics

- **Pool-open failure (DB unreachable):** out of scope. The bench path
  has its own `BPM_TEST_DB_URL` retry fallback (verified
  `bench.zig:55-69`). A hard failure here would mask the bench's
  fallback retry.
- **Pool acquisition failure during post-condition:** hard exit is
  correct — the pool opened two minutes ago, so a brief acquire
  failure means the DB is genuinely broken, and we should not
  continue into GBL-116 with a half-provisioned DB.
- **`provisionTenantSchema` throwing `MigrationFailed`:** the existing
  `warn` is appropriate. The post-condition check catches the silent
  subset of failure modes (the function returns OK but the column is
  still NULL) — that's the only case the diagnosis identifies.

### 3.3 `migrations/GBL-116_tnt07_rls_cleanup.sql` — diagnostic message fix (cosmetic)

**Edit site:** line 34 (the `RAISE EXCEPTION` message text).

**Before:**

```sql
RAISE EXCEPTION 'TNT-07 pre-flight failed: tnt05_progress table does not exist. Run GBL-074 and GBL-075 first.';
```

**After (intent):**

```sql
RAISE EXCEPTION 'TNT-07 pre-flight failed: tnt05_progress table does not exist. Run GBL-113 and GBL-114 first.';
```

**Rationale:** the original message references non-existent files
(`GBL-074`/`GBL-075`) — the actual files are
`migrations/GBL-113_tnt05_backfill_tracking.sql` and
`migrations/GBL-114_tnt05_backfill_run.sql`. This is a copy-paste
artifact from a pre-rename naming convention. Purely cosmetic; does
not change gate behaviour, does not change the failure path. The
diagnosis flags this as item 4 under "Risks and regression vectors".

### 3.4 Files NOT changed (anti-dependencies)

- `migrations/GBL-116_tnt07_rls_cleanup.sql` — pre-flight loop body
  (lines 39-61) is unchanged. Gate stays strict.
- `tests/bench/bench.zig` — `resolveDbUrl` precedence is unchanged.
- `src/db/provisioning.zig` — `provisionTenantSchema` signature is
  unchanged. The fix lives in the caller, not the callee.
- `src/main.zig` — `runApiServer`'s existing `provisionTenantSchema`
  call (line 182) is unchanged. Production behaviour is preserved.
- `.github/workflows/ci.yml` — the fresh-DB job (line 441) already sets
  `BPM_DB_URL` in its env block; no change needed.
- `.vscode/run-zig-bench.ps1` — already loads `.env` and forwards all
  BPM_*_URL variables to the bench process; no change needed (the
  build.zig-injected env-var reaches the migrate child via the
  `setEnvironmentVariable` API, which is layered above the shell env
  in the child process).

---

## 4. Migration safety (the gate stays strict for production; only the bench path is relaxed/fixed)

The GBL-116 pre-flight gate's contract is:

> For every row in `public.tenant`, that tenant must have (a) a row in
> `public.tenant_schemas` with `migrations_applied_at IS NOT NULL`, AND
> (b) at least one row in `public.tnt05_progress` with `status='COMPLETED'`.

After this fix:

- **Production** (API server bootstrap path, `src/main.zig::runApiServer`):
  `provisionTenantSchema` is called at startup (line 182), and the same
  post-condition check now applies (the same edit applies to `main.zig` in
  a **follow-up** if a similar failure is ever observed there — but the
  diagnosis does NOT mandate this for the current run; see
  "Dependencies" §7.1). Production's existing behaviour is preserved:
  when all is well, `migrations_applied_at` is set, gate passes. When
  something goes wrong, the post-condition catches it loudly instead of
  silently moving on.
- **Bench path** (this fix's primary target): `migrate.zig`'s in-loop
  hook now connects to the bench DB (because `BPM_DB_URL` is injected)
  AND fails loudly when the post-condition does not hold (so a flaky
  bench path either succeeds or fails visibly — never silently skips
  provisioning).
- **CI fresh-DB path** (`.github/workflows/ci.yml:441`): already sets
  `BPM_DB_URL` in its env block, so the build.zig injection is a no-op
  there (the env variable is already set; `setEnvironmentVariable` only
  overrides when the parent env is unset). The fresh-DB's empty state
  means the in-loop hook runs successfully, the post-condition passes,
  and behaviour is unchanged.

**Tenant isolation regression risk:** zero. The fix is scoped to the
default tenant's `provisionTenantSchema` call, which is already the
established pattern (`main.zig::runApiServer`).

**Backfill side-effect:** if `provisionTenantSchema` is called against a
partially-migrated public schema (some GBL- files applied, others not),
the call re-runs tenant-schema migrations and may rewrite
`tenant_schemas` columns. This is idempotent and is the same behaviour
`main.zig` already relies on. The post-condition is a read-only check
— `SELECT count(*) ...` does not mutate state.

---

## 5. Test plan

### 5.1 New regression tests (mandatory)

Each new test must be named `regression: ISS-0706 — <description>` so the
correspondence to the issue is queryable.

5.1.1 **Test 1 — `zig build bench` succeeds on a fresh bench DB.**

- **Scope:** end-to-end smoke of the bench path on a fresh PG instance.
- **Setup:** drop and recreate `bpm_test` (the bench DB at
  `BPM_BENCH_DB_URL=postgres://bpm:bpm@localhost:5433/bpm_test`).
- **Execute:** `zig build bench` (from a clean shell, with only
  `BPM_BENCH_DB_URL` set — NOT `BPM_DB_URL`).
- **Expected:** exit code 0; `NFR_BENCH_SUMMARY|overall_passed=true|run_id=...`
  line emitted.
- **Failure mode without fix:** `error.ServerError` from GBL-116, exit
  code non-zero, `NFR_BENCH_SUMMARY` line absent.

5.1.2 **Test 2 — `zig build bench` succeeds on a fresh bench DB with NO
shell env vars (`.env`-only path).**

- **Scope:** covers the `.env` fallback inside `build.zig`'s
  `resolveBenchMigrateDbUrl` helper.
- **Setup:** unset all of `BPM_BENCH_DB_URL`, `BPM_DB_URL`,
  `BPM_TEST_DB_URL` in the shell; ensure `.env` has the same three
  variables set; drop and recreate the bench DB.
- **Execute:** `zig build bench`.
- **Expected:** exit code 0; `BENCH_MIGRATE_URL_INFO|source=BPM_BENCH_DB_URL`
  (or whatever `.env` key was resolved) appears in the stdout.

5.1.3 **Test 3 — migrate.zig's post-condition catches silent failure.**

- **Scope:** unit-level regression for the post-condition check itself.
- **Setup:** start with a fresh DB where migration 060 has run (creating
  the `tenant_schemas` row for the default tenant with
  `migrations_applied_at = NULL`). Manually corrupt the in-process
  `provisionTenantSchema` outcome (e.g. via a test shim that swaps the
  function for a stub returning `{}` without updating the column).
- **Execute:** `zig build migrate`.
- **Expected:** exit code non-zero; stderr contains
  `post-condition: default tenant_schemas.migrations_applied_at is NULL`.
- **Implementation note:** this test requires a Zig test harness for
  `migrate.zig`'s main(); the existing `tests/integration/helpers.zig`
  is the right place. The test shim hook is a new field in
  `db_provisioning::provisionTenantSchema` (test-only path, gated
  behind `@import("build_options").test_mode`).

5.1.4 **Test 4 — production path (`zig build migrate` against a fresh
PG via `BPM_DB_URL`) is unaffected.**

- **Scope:** proves the post-condition check does not introduce a
  regression for the supported CI path.
- **Setup:** fresh PG instance at `postgres://bpm:bpm@localhost:5432/bpm_fresh_ci`,
  `BPM_DB_URL` set, no other BPM_*_URL set.
- **Execute:** `zig build migrate`.
- **Expected:** exit code 0; all migration files applied; the post-condition
  check passes naturally (the in-loop hook succeeds in satisfying the
  column).

5.1.5 **Test 5 — `BPM_DB_URL` is NOT set when no env-var exists.**

- **Scope:** proves the build.zig helper degrades gracefully (does NOT
  invent a URL).
- **Setup:** unset all of `BPM_BENCH_DB_URL`, `BPM_DB_URL`,
  `BPM_TEST_DB_URL`, and remove `.env` (or have an empty `.env`).
- **Execute:** `zig build bench`.
- **Expected:** exit code non-zero; stderr contains
  `BPM_DB_URL environment variable is not set` (from `migrate.zig`'s
  own check at line 18). The bench binary's own `BENCHMARK_SETUP_ERROR`
  diagnostic is then expected to follow.

5.1.6 **Test 6 — pre-ISS-502 DBs still migrate successfully.**

- **Scope:** proves the post-condition is gated on `provision_attempted`
  (so a DB whose `tenant_schemas.migrations_applied_at` was already set
  before the hook landed does NOT abort).
- **Setup:** use the existing `db_test` (or `bpm_dev`) — a long-lived
  DB where the default tenant's `tenant_schemas.migrations_applied_at`
  is already set.
- **Execute:** `zig build migrate`.
- **Expected:** exit code 0; only newer migrations are applied; the
  post-condition check passes naturally (count > 0).

### 5.2 Existing tests that must continue to pass

The following suites must be re-run after the fix is applied; any
regression is a blocker.

| Test | Path | Why it matters |
|---|---|---|
| `env01` (test-integration) | `tests/integration/` | Pre-flight gates must not regress for the env01 health probe |
| `tests/bench/bench.zig` (unit-level) | `tests/bench/bench.zig` | ResolveDbUrl precedence is unchanged |
| `tools/verify_test_env.py` | `tools/verify_test_env.py` | Step 04 gate's exit code must remain 0 |
| Full integration suite (`zig build test-integration-tm`) | `tests/integration/` | Pre-flight invariants must not break tenant-isolation tests |
| NFR suite (`zig build bench`) | `tests/bench/bench.zig` | The whole point of the fix |
| `lint_migration_schema.py` | `tools/` | The cosmetic SQL message fix must not trip the linter |
| `lint_design_artefact.py` on `src/design/iss-0706-gbl116-bench-pre-flight.md` | `tools/` | The design itself must be lint-clean |

### 5.3 Tests that MUST NOT be added

- **No test that mocks `provisionTenantSchema` at the SQL level via
  raw `UPDATE public.tenant_schemas SET migrations_applied_at = NOW()`.**
  That would directly encode the "hand-curated bypass" pattern that
  Approach (c) rejected. The post-condition is the *only* legitimate
  way to set this column.
- **No `./tools/run-bench-bootstrap.sh`-style helper script.** The
  diagnosis specifically rejected Approach (c) — the fix must live in
  the runner + build wirings, not in a shell-script workaround.

---

## 6. Acceptance criteria

Each MUST and MUST-NOT criterion is independently verifiable.

### 6.1 MUST (positive correctness)

1. **MUST-1:** `zig build bench` exits 0 on a fresh bench DB with only
   `BPM_BENCH_DB_URL` set in the environment.
2. **MUST-2:** `zig build bench` exits 0 on a fresh bench DB with only
   `.env` containing `BPM_BENCH_DB_URL` (no shell env vars).
3. **MUST-3:** `zig build migrate` exits 0 on a fresh PG instance with
   `BPM_DB_URL` set (reproduces the existing CI fresh-DB path success).
4. **MUST-4:** When `provisionTenantSchema` returns successfully but
   `migrations_applied_at` is still NULL, `migrate.zig` exits with a
   non-zero code and stderr contains
   `post-condition: default tenant_schemas.migrations_applied_at is NULL`.
5. **MUST-5:** When all BPM_*_URL env vars are unset AND `.env` has no
   DB URL, `zig build bench` exits non-zero with a clear error from
   `migrate.zig` (NOT a hang or silent skip).
6. **MUST-6:** On a long-lived DB (e.g. `db_test`) where
   `migrations_applied_at` is already set, `zig build migrate` exits 0
   and the post-condition check passes without aborting.
7. **MUST-7:** `tools/verify_test_env.py` exits 0 after the fix is
   applied (the env-verify Step 04 gate).
8. **MUST-8:** `python tools/lint_handoffs.py` exits 0 on the new
   design file (no new BLOCKER/MAJOR findings).
9. **MUST-9:** The cosmetic SQL message in `migrations/GBL-116_tnt07_rls_cleanup.sql`
   references `GBL-113 and GBL-114` (not `GBL-074 and GBL-075`).
10. **MUST-10:** All 6 new regression tests (5.1.1 - 5.1.6) pass.

### 6.2 MUST-NOT (negative correctness)

11. **MUST-NOT-1:** `migrations/GBL-116_tnt07_rls_cleanup.sql`'s pre-flight
    loop body (lines 39-61) MUST NOT be modified. Gate stays strict.
12. **MUST-NOT-2:** The pre-flight MUST NOT skip the
    `00000000-0000-0000-0000-000000000000` tenant. No "magic tenant"
    carve-out.
13. **MUST-NOT-3:** `BPM_BENCH_DB_URL` MUST NOT be re-pointed to a
    production DB URL by the fix. The resolution precedence stays
    bench-specific.
14. **MUST-NOT-4:** The post-condition check MUST NOT insert or update
    `public.tenant_schemas.migrations_applied_at` directly. It is a
    read-only `SELECT count(*)`, never a write.
15. **MUST-NOT-5:** The post-condition check MUST NOT abort when the
    pool itself failed to open (DB unreachable). The check is gated on
    `provision_attempted` to preserve the bench's `BPM_TEST_DB_URL`
    retry fallback.
16. **MUST-NOT-6:** No new shell-script wrapper (e.g.
    `bench-bootstrap.sh`) is added. The fix lives in build.zig + migrate.zig.
17. **MUST-NOT-7:** `tests/bench/bench.zig::resolveDbUrl` MUST NOT be
    modified. The build.zig helper mirrors it.
18. **MUST-NOT-8:** `src/main.zig::runApiServer` MUST NOT be modified
    in this run. (The same post-condition check on `runApiServer` is a
    sensible follow-up but is out of scope for ISS-0706.)
19. **MUST-NOT-9:** No new module-level import is added to `tests/bench/bench.zig`.
    The fix is zero-import for the bench binary.
20. **MUST-NOT-10:** No new product-level env var is introduced. The fix
    reuses the existing `BPM_BENCH_DB_URL` / `BPM_DB_URL` / `BPM_TEST_DB_URL`
    precedence.

---

## 7. Dependencies

### 7.1 depends_on

1. **No other fix must land first.** This fix is self-contained. It
   does not require any other WF to complete.
2. **`tools/verify_test_env.py` (the env-verify Step 04 gate)** must
   exit 0 after the fix is applied — this is verified by MUST-7, not
   by a separate dep. The Step 04 gate is a verification step, not a
   prerequisite.
3. **`tools/utcnow.py` and the orchestrator-clock convention** must be
   in place for the handoff bookkeeping (no code dependency, just a
   workflow convention inherited from `docs/agents/instructions/core-directives.md`).

### 7.2 Order of changes within this fix

The two coordinated changes must land together in a single commit
(recommended) or two commits in the same PR:

1. **First commit (or single commit):** `build.zig` env-injection +
   `src/tools/migrate.zig` post-condition check + the cosmetic SQL
   message fix.
2. **Second commit (optional):** the 6 new regression tests.

Order rationale: the code change is small enough to review in a single
PR; the tests are independently verifiable.

### 7.3 Out-of-scope follow-ups (NOT deps of this fix)

- Adding the same post-condition check to `src/main.zig::runApiServer`
  (so the production server's startup path also fails loudly on
  silent `provisionTenantSchema` failure). Sensible follow-up; not
  required to resolve ISS-0706.
- Refactoring `migrate.zig`'s hard `BPM_DB_URL` read to support a
  `BPM_BENCH_DB_URL` fallback internally. Would reduce the need for
  the build.zig helper, but is a larger refactor that changes the
  run-time contract of `migrate.zig`. Out of scope.
- Migrating the `pool_size = 2` for the in-loop hook to a higher
  value to fix the race documented in the diagnosis §"Risks" item 2.
  Pre-existing race; not blocking this fix.

---

## 8. MUST-NOT-depend-on (anti-dependencies)

The following MUST NOT be modified as part of this fix:

1. **`migrations/GBL-116_tnt07_rls_cleanup.sql` pre-flight loop body** —
   gate stays strict.
2. **`tests/bench/bench.zig::resolveDbUrl`** — the bench's existing
   precedence is correct.
3. **`src/db/provisioning.zig::provisionTenantSchema`** — the
   function signature is unchanged; the fix is in the caller.
4. **`src/main.zig::runApiServer`** — out of scope this run.
5. **`.github/workflows/ci.yml` fresh-DB job** — already passes; no
   change.
6. **`.vscode/run-zig-bench.ps1`** — already loads `.env` and forwards
   all BPM_*_URL variables; no change.
7. **Any new env var** — the fix reuses the existing three.
8. **Any new module-level dependency** in `tests/bench/bench.zig` —
   the fix is zero-import for the bench binary.
9. **Any new SQL file** — no schema migration is added or modified
   beyond the cosmetic message fix.
10. **Any new shell-script wrapper** — no `bench-bootstrap.sh` or
    PowerShell `bootstrap-bench.ps1` is added.
11. **`tools/verify_test_env.py`** — already classifies the bench
    environment correctly; no change.

---

## 9. Risks and mitigations

| Risk | Mitigation |
|---|---|
| **R1.** Pre-ISS-502 DB where `provisionTenantSchema` was never called might trip the post-condition check on first run after the fix. | The post-condition is gated on `provision_attempted` (true only when the pool opened AND the call was made). If the call succeeds, the column is set; if it fails, the existing `warn` is logged and the post-condition is checked. The `IF NOT EXISTS` semantics in `0105_tenant_schemas.sql` and similar ensure the call is idempotent — a pre-existing row remains valid, only the column is updated. |
| **R2.** The pool-open catch arm (DB unreachable) is gated to `warn`, but a hard post-condition failure might be misinterpreted as DB-unreachable. | The post-condition check requires `provision_attempted = true` AND a successful `pool.acquire()`. If acquire fails, the post-condition bails with `std.process.exit(1)` and a clear `post-condition: could not acquire pool connection: <err>` message. Operators can distinguish DB-unreachable from post-condition-miss via the error text. |
| **R3.** Build-time URL resolution might disagree with `bench.zig::resolveDbUrl` if one is updated and the other isn't. | The design specifies a "MUST stay byte-for-byte equivalent" invariant on the helper. The new Test 2 (5.1.2) explicitly covers the `.env` fallback path. A future maintainer who changes one must change both. A lint check could be added later (out of scope for this fix). |
| **R4.** The fix touches `migrate.zig`'s main(), which is complex. A logic error could break the existing `zig build migrate` path. | Test 4 (5.1.4) explicitly reproduces the existing CI path; Test 6 (5.1.6) covers the long-lived DB path. The existing `tests/integration/` suite (including `env01`) runs after the fix and would catch any regression. |
| **R5.** The cosmetic SQL message fix (`GBL-074/075` → `GBL-113/114`) is a one-line change that could be mistakenly expanded into a logic change. | The diff is bounded to a single string literal in an existing `RAISE EXCEPTION` message. `lint_migration_schema.py` is run as part of the change verification. |
| **R6.** The `lock_conn` API in `src/tools/migrate.zig` may use a different signature than the pseudocode in §3.2.1. | The pseudocode is design intent; the BACKEND-DEV agent must verify against `src/db/pool.zig`'s current `acquire()` / `release()` signature before patching. The post-condition uses the same connection-acquisition pattern as the existing `provisionTenantSchema` call. |
| **R7.** Race between concurrent `zig build bench` and `zig build test-integration` on the same DB exhausting the `pool_size = 2` for the in-loop hook. | Pre-existing race; the diagnosis does not mandate fixing it. The post-condition check runs AFTER the call returns, so the race window is unchanged. Out of scope per the diagnosis. |
| **R8.** The `BENCH_MIGRATE_URL_INFO` diagnostic line emitted by `build.zig`'s helper could be misparsed by ORCH's stdout-grep health probes. | ORCH's health probe uses `tools/verify_test_env.py`'s exit code (verified `build.zig:3804-3820`), not stdout grep. The diagnostic line is informational only. |
| **R9.** Adding `run_migrate.setEnvironmentVariable` BEFORE the `dependOn` line might not propagate to the child process if the build system reorders. | The Zig `0.16.0` build API performs `setEnvironmentVariable` calls deterministically during phase 1 (analysis); the `dependOn` call only declares the graph dependency. The migration runs as a subprocess in phase 2 with the env-var already set. Verified by reading the existing `run_bench.setEnvironmentVariable("BPM_MIGRATIONS_DIR", migrations_dir)` call at line 3791, which uses the same pattern. |

---

## 10. Open questions (none blocking)

- **OQ-1.** Should the same `setEnvironmentVariable("BPM_DB_URL", ...)` pattern be applied to other steps that depend on `run_migrate` (e.g. `test-integration-tm`)? Answer: **no** — the integration test runner already passes `BPM_DB_URL` via `.vscode/tasks.json` and the `cmd` shell, and the CI fresh-DB path sets it in the env block. The bench path is the only one missing this wiring. **Resolved in scope.**
- **OQ-2.** Should the post-condition check be a separate helper function (e.g. `verifyDefaultTenantProvisioned`) instead of inline? Answer: **inline for now** — the check is small and only used in two adjacent sites. A helper can be extracted in a follow-up if a third site appears. **Resolved in scope.**

---

## 11. File change summary (recap)

| File | Change | Lines affected |
|---|---|---|
| `build.zig` | Add `resolveBenchMigrateDbUrl` helper; call `run_migrate.setEnvironmentVariable("BPM_DB_URL", ...)` at the bench step construction site | ~25 net-new lines around lines 3791-3795 |
| `src/tools/migrate.zig` | Add post-condition check in both the in-loop hook and the post-loop fallback; add `provision_attempted: bool` flag | ~25 net-new lines around lines 142-187 and 297-315 |
| `migrations/GBL-116_tnt07_rls_cleanup.sql` | Cosmetic fix: `GBL-074`/`GBL-075` → `GBL-113`/`GBL-114` in the static error message | line 34 only |
| `tests/integration/` (5.1.3) | New test for the post-condition check | new file |
| `tests/bench/bench.zig` (5.1.1, 5.1.2, 5.1.5) | New regression tests | new file or new test functions |

No other files are modified. No new env vars, no new modules, no new
migrations, no new shell scripts.

---

## 12. Design verification checklist (BACKEND-DEV run-time)

- [ ] `build.zig::resolveBenchMigrateDbUrl` mirrors `bench.zig::resolveDbUrl`
  precedence exactly.
- [ ] `run_migrate.setEnvironmentVariable` is called BEFORE the
  `run_bench.step.dependOn(&run_migrate.step)` line.
- [ ] `migrate.zig::provision_attempted` is declared at the appropriate
  scope (inside `main()`, before the loop OR before the post-loop fallback).
- [ ] The post-condition count query uses `$1::uuid` cast and casts the
  result to `i64` for comparison.
- [ ] The cosmetic SQL message fix is exactly the literal string
  replacement (no whitespace changes).
- [ ] All 6 new regression tests are placed under `tests/integration/`
  (or appropriate subdirectory) and named per the `regression: ISS-0706 — <description>` convention.
- [ ] `tools/verify_test_env.py` exits 0 after the fix.
- [ ] `python tools/lint_handoffs.py --changed` exits 0 for the new
  handoff file.

— END —
