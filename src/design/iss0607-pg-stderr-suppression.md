# Module: iss0607-pg-stderr-suppression (vendor/pg/pg.zig)

Type E prose design — bugfix to the vendored PostgreSQL client.
Scope is constrained to **one** stderr-emitting call site in `vendor/pg/pg.zig`
and **one** new build flag in `build.zig`. No new module, no new public type,
no signature change on any existing `pg.Conn` method.

ISS-0607 / GH-542 (revised after diagnosis): the failure attributed to
"pg.zig:451 AuthenticationFailed" was a misdiagnosis. The actual cause of
`test-integration-iss107` aborting is that `vendor/pg/pg.zig` writes
`POSTGRES ERROR: …` to stderr for **every** server-side error response, and
`zig test` treats any stderr output as a binary-level failure. Negative tests
that deliberately provoke a constraint violation (e.g. iss107 TC-04
`UPDATE tenant SET storage_mode='BOGUS'`) trigger the print before the
`expectError(error.ServerError, …)` assertion ever runs, so the binary aborts
mid-suite.

Fix: silence the print by default; expose a build flag
`-Dlog-pg-errors=<bool>` so developers and CI can opt back in when they need
the full error text for post-mortem debugging. The `error.ServerError`
return value is preserved unchanged — only the **side effect** of printing
to stderr is gated.

---

## Module purpose (5 lines max)

1. `vendor/pg/pg.zig` calls `std.debug.print("\nPOSTGRES ERROR: {s}\n", …)`
   for every `ErrorResponse` message in `readUntilReady` (one site, line 316).
2. `zig test` interprets any stderr output during a test binary as a hard
   failure for that binary, even when the calling test is asserting the
   error.
3. Negative-path integration tests (iss107 TC-04, all `expectError` tests
   that provoke a CHECK / FK / UNIQUE violation) therefore abort the entire
   test binary before their assertion runs.
4. The error still propagates correctly through the typed `PgError.ServerError`
   return value — only the **logging side effect** is undesirable.
5. Developers still need the full text for post-mortem work, so the fix must
   keep the print reachable behind an opt-in flag rather than deleting it.

---

## Approach: detect the build flag at compile time

Use the **same `build_options` module mechanism** already in use throughout
this repo. `build.zig` lines 62–66 already create a `build_options` step
and `addOptions()` entries (`platform_version`, `adp12_phase`,
`migrations_dir`). Two minimal additions:

1. `build.zig` — read a user option and add it to `build_options`:
   ```zig
   const log_pg_errors = b.option(bool, "log-pg-errors", "Print PostgreSQL ErrorResponse payloads to stderr") orelse false;
   // ...
   build_options.addOption(bool, "log_pg_errors", log_pg_errors);
   ```
2. `vendor/pg/pg.zig` — declare at module scope:
   ```zig
   const build_options = @import("build_options");
   // ...
   const log_pg_errors = build_options.log_pg_errors;
   ```
   and wrap the existing `std.debug.print(...)` call in a compile-time
   `if (log_pg_errors)` block.

Because both the option lookup and the add happen at `pub fn build` time
**before** `pg_dep = b.dependency("pg", …)` is consumed, every module that
links `pg` (bpm, pool, event_store, etc.) sees the same constant.

The check is `if (log_pg_errors) std.debug.print(…) else {}`, which Zig
eliminates entirely in the false branch — no runtime branch, no string
literal retained, no overhead in CI. This is the project-precedent pattern
(see `src/api/openapi/version_source.zig`, `src/api/routes/onboarding.zig`
for `build_options`-driven compile-time gating).

> **Why `b.option(…, "log-pg-errors", …)` and not `@hasDecl`?**
> `@hasDecl` would require every consumer of `pg` to also have a
> `build_options` module that declares the field, otherwise the compiler
> errors at first use of `@hasDecl`. A typed `addOption(bool, …)` makes
> the dependency explicit at the `pg` import site via the standard module
> wiring (see `b.dependency("pg", …)` consumers in `build.zig`). It also
> gives a clean `zig build -Dlog-pg-errors=true …` CLI surface.

> **Why not `std.builtin.mode == .Debug`?**
> Tests must run in `Debug` (Zig forbids `ReleaseSafe/ReleaseFast` for
> `zig test`), and CI runs the binary in `Debug` too. Mode-based gating
> would either (a) flip on for CI (which is what we want to suppress), or
> (b) require developers to build in `ReleaseSafe` for clean test output.
> An explicit flag is the only correct answer.

---

## Public API impact

**None.** No function signature changes, no struct field changes, no
behaviour change other than the gated side effect:

| Symbol | Today | After fix |
|---|---|---|
| `pg.PgError` (enum) | `{ ConnectionFailed, AuthenticationFailed, ProtocolError, ServerError, InvalidUrl, OutOfMemory, Timeout, UnexpectedEof, UnsupportedAuthMethod }` | unchanged |
| `pg.ConnectOptions` | `{ host, port, database, user, password }` | unchanged |
| `pg.Result.deinit()` | unchanged | unchanged |
| `pg.Conn.open(url)` | `PgError!Conn` | unchanged |
| `pg.Conn.exec(sql, params)` | `PgError!void` | unchanged — returns `ServerError` exactly as before |
| `pg.Conn.query(sql, params, allocator)` | `PgError!Result` | unchanged |
| Side effect on `ServerError` | writes `POSTGRES ERROR: …` to stderr | silent unless `-Dlog-pg-errors=true` |

Callers in `src/db/pool.zig`, `src/event_store/store.zig`, and every
integration test continue to receive `error.ServerError` exactly as today.
The fix removes only the stderr write; it does **not** swallow, suppress,
or rewrite the error path that a gate might inspect.

---

## File-by-file change list

### 1. `vendor/pg/pg.zig` (the only vendor change)

**Existing module-scope imports** (lines 9–14):
```zig
const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const mem = std.mem;
const crypto = std.crypto;
const base64 = std.base64;
```
**Add one line** immediately after this block:
```zig
const build_options = @import("build_options");
```

**Module-scope constant** — add immediately below the new import:
```zig
const log_pg_errors = build_options.log_pg_errors;
```

**Existing call site** (lines 314–319, inside `fn readUntilReady`):
```zig
'E' => { // ErrorResponse
    const err_raw = self.reader.interface.take(payload_len) catch return PgError.ConnectionFailed;
    std.debug.print("\nPOSTGRES ERROR: {s}\n", .{err_raw});
    got_error = true;
},
```

**Wrap** the `std.debug.print` call in a compile-time guard:
```zig
'E' => { // ErrorResponse
    const err_raw = self.reader.interface.take(payload_len) catch return PgError.ConnectionFailed;
    if (log_pg_errors) std.debug.print("\nPOSTGRES ERROR: {s}\n", .{err_raw});
    got_error = true;
},
```

That is the **complete** diff to `vendor/pg/pg.zig`. No other call site
prints "POSTGRES ERROR" or anything related. Grep confirms a single match.

### 2. `build.zig` (one option declaration + one addOption)

**Existing block** (lines 62–66):
```zig
const build_options = b.addOptions();
build_options.addOption([]const u8, "platform_version", "0.1.0");
build_options.addOption(?[]const u8, "adp12_phase", adp12_phase);
build_options.addOption([]const u8, "migrations_dir", b.path("migrations").getPath(b));
```

**Add** a new `b.option(…)` declaration near the existing `adp12_phase`
declaration (line 60):
```zig
const log_pg_errors = b.option(bool, "log-pg-errors", "Print PostgreSQL ErrorResponse payloads to stderr") orelse false;
```
**And** one new `addOption` line:
```zig
build_options.addOption(bool, "log_pg_errors", log_pg_errors);
```

`build_options_mod` is already passed to every consumer of `pg` via
the existing module wiring (see lines 299, 377, 516, 563, 695, 1316,
1672, 2138, 2175, 2260, 2267 for the places that pass `build_options_mod`
into the module graph). No new wiring is required — the option propagates
through the existing module tree because every place that depends on `pg`
also depends on `build_options`.

### 3. No other files change

- `src/db/pool.zig` — unchanged. The error path it cares about
  (`PgError.ServerError`) is preserved.
- `src/event_store/store.zig` — unchanged.
- `src/tools/migrate.zig` — unchanged.
- Every `tests/integration/*` file — unchanged.
- `CHANGELOG.md`, `docs/status/requirement_status.yaml` — not in scope
  for this design (DOC-UPDATER owns those at a later step).

---

## Test plan

### New regression test (TEST-DESIGNER owns the file; design just specifies it)

**File:** `tests/integration/iss0607_pg_stderr_suppression_test.zig`
**Sketch:**
```zig
test "regression: ISS-0607 — negative-path test no longer aborts binary on stderr" {
    // Provoke a CHECK constraint violation (same path that aborts iss107 TC-04).
    var h = try helpers.TestHarness.init(std.testing.allocator);
    defer h.deinit();

    try h.conn.exec(
        "INSERT INTO tenant (id, slug, name, status, realm_id, default_tenant, storage_mode) "
        "VALUES ($1, $2, $3, 'ACTIVE', $4, true, 'tenant')",
        .{ test_uuid(), "iss0607-tenant", "ISS-0607 Tenant", "realm-iss0607" },
    );

    // Negative path: storage_mode='BOGUS' must violate tenant_storage_mode_check.
    const result = h.conn.exec(
        "UPDATE tenant SET storage_mode = 'BOGUS' WHERE id = $1",
        .{test_uuid()},
    );

    // Two assertions in one test:
    //   (a) typed error still propagates,
    //   (b) reaching this assertion means zig test did NOT abort on stderr.
    try std.testing.expectError(error.ServerError, result);
}
```

**Evidence of regression fix:** this test exists **at all**. Today the
test binary aborts before `expectError` runs (see diagnosis log
`scratch/test-iss107-main.log`). After the fix, the binary reaches the
assertion, the assertion passes, and the rest of the integration suite
(iss107 + iss0605 + every other negative-path test) continues to run.

### How existing tests behave after the fix

| Test family | Behaviour today | Behaviour after fix |
|---|---|---|
| `test-integration-iss107` (TC-04 negative) | Aborts binary at first negative path; suite incomplete | All TC-01…TC-09 run to completion |
| `test-integration-iss0605` (constraint negative) | Same abort | Runs to completion |
| All other `expectError(error.ServerError, …)` tests | Same abort pattern; may pass by accident if the negative case is at the end | Run reliably, in order |
| `zig build test` (unit tests, no DB) | Unaffected | Unaffected |
| `zig build bench` | May emit a lot of stderr noise | Unchanged; `-Dlog-pg-errors=true` keeps the old behaviour available for benchmark debugging |

### Verification commands for BACKEND-DEV (executed at Step 3)

```bash
zig build                                         # compiles the gated constant
zig build test --summary all                      # unit tests still green
$env:BPM_TEST_DB_URL="postgres://bpm:bpm@localhost:5434/bpm_test"
zig build test-integration-iss107 --summary all   # the previously-aborting suite now completes
zig build test-integration-iss0605 --summary all  # the parallel suite also completes
```

A full CI run with `-Dlog-pg-errors=false` (the default) must produce
**zero** lines containing `POSTGRES ERROR:` in any test binary's stderr,
unless the binary itself fails for an unrelated reason. A spot-check with
`-Dlog-pg-errors=true` must reproduce the historical stderr output (proving
the print path still exists).

---

## Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Developer loses ability to diagnose a server-side error in development | Medium | Medium | `zig build -Dlog-pg-errors=true run` (or `… test-integration`) restores the print. Document the flag in `docs/guides/backend_developer_guide.md §6` next to the other build commands and in `CHANGELOG.md`. |
| A CI job somewhere is grepping `POSTGRES ERROR:` in test output and would silently stop matching | Low | Low | The fix ships under ISS-0607 — search for that ID across `tools/`, `.github/workflows/`, `docs/guides/` before merging. The known codebase surface (verified): no script greps for `POSTGRES ERROR` outside of the diagnosis flow itself, which is one-off. |
| Someone in the future re-introduces an unguarded `std.debug.print` in `vendor/pg/pg.zig` | Low | Low | Acceptable trade-off — the file is vendored, not auto-regenerated, and a code-review checklist item ("server-error stderr prints must be gated") catches it. |
| Test author interprets the regression test as "test that stderr is empty" and writes a brittle string-match assertion | Low | Low | Test asserts `expectError(error.ServerError, …)` and relies on the assertion running at all. Do **not** assert on stderr content — that is what created the original bug. |
| A typed error other than `ServerError` is emitted by `readUntilReady` (e.g. `ConnectionFailed` on a stream read) and was previously visible via the same stderr print | Very low | Very low | The print is in the same code path that handles `'E'` (ErrorResponse). `ConnectionFailed` is returned via `catch` clauses that **do not** go through the print. Verified by reading lines 314–319 in context. |

---

## Implementation guidance (pseudo-code, NOT production code)

```text
// vendor/pg/pg.zig — at module scope
const build_options = @import("build_options");
const log_pg_errors = build_options.log_pg_errors;     // comptime bool

// inside fn readUntilReady, the 'E' arm
'E' => {
    const err_raw = self.reader.interface.take(payload_len)
        catch return PgError.ConnectionFailed;
    if (log_pg_errors) std.debug.print("\nPOSTGRES ERROR: {s}\n", .{err_raw});
    got_error = true;
},

// build.zig — at top of pub fn build
const log_pg_errors = b.option(
    bool,
    "log-pg-errors",
    "Print PostgreSQL ErrorResponse payloads to stderr",
) orelse false;

// inside the existing build_options.addOption(…) block
build_options.addOption(bool, "log_pg_errors", log_pg_errors);
```

### Things explicitly NOT in this design (do not add them)

- **No log-level abstraction in `pg.zig`.** Adding `log(…)` / `Logger` /
  `log_sink: ?*Writer` to `Conn` is the **Option B** direction in the
  diagnosis doc; it is the right long-term fix but is **out of scope** for
  ISS-0607. Tracking under a separate issue is acceptable, but not this PR.
- **No changes to `PgError` variants.** The error set stays exactly as it
  is; only the stderr side effect changes.
- **No removal of `err_raw`.** The variable is still needed when
  `log_pg_errors` is true. (And even when false, the `take(payload_len)`
  call is required to advance the stream position.)
- **No change to `pg.Conn` struct layout.** Compile-time gating means no
  field is added, no `ConnectOptions` entry is added, and ABI is unchanged.
- **No new module for the option.** `build_options` is already the
  project-wide channel for compile-time configuration; adding a parallel
  module would duplicate infrastructure for no benefit.