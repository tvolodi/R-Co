# Module: verify_schema_baseline_fix (tools/verify_schema_baseline.py — ISS-0146 / GH #458)

Type E prose design — bugfix to an existing tooling script, not a new module.
Covers the fix for ISS-0146: (1) stale `GBL-105_iss0112_schema_ledger_reconcile.sql`
filename literal, now `GBL-133_...`, resolved dynamically instead of re-hardcoded;
(2) unbounded `return main()` recursion in the `--auto-fix` path, replaced with a
bounded, non-recursive retry; (3) a manual verification procedure for the
previously-unverified `--auto-fix` reconcile path.

No new module, no new public interface beyond the signature changes to two
existing functions (`auto_fix`, `main`). All three ISS-0146 acceptance criteria
are addressed below.

---

## Public interface

Signature changes only — no new files, no new modules.

```
resolve_reconcile_migration(migrations_dir: Path) -> Path
    # NEW helper. Locates the iss0112 schema-ledger-reconcile migration file
    # dynamically. Raises ReconcileFileResolutionError (see Data types) if
    # zero or more than one match is found. Never returns a path that does
    # not exist.

auto_fix(db_url: str, migrations_dir: Path) -> bool
    # CHANGED return type: was `-> None`, now `-> bool`.
    # Returns True only if the reconcile SQL was located AND executed AND
    # committed without exception. Returns False on any failure (file not
    # found / ambiguous match / SQL execution error). Never raises past its
    # own boundary — all failure modes degrade to `return False` plus a
    # stderr message, matching the current best-effort style.

run_checks(conn, migrations_dir: Path, migration_files: list[str],
           check_tenants: bool) -> list[str]
    # NEW helper, extracted from the body of the current main()'s `with
    # connect(...)` block (lines ~210-254). Pure check-and-report: runs the
    # four existing check_* functions against an already-open connection,
    # prints the same [OK]/[FAIL] lines main() prints today, and returns the
    # `failures` list. Contains NO auto-fix logic and NO recursion. This is
    # what makes main() re-runnable without recursing into itself.

main() -> int
    # CHANGED internals only; CLI contract (flags, exit codes 0/1/2) is
    # unchanged. No longer calls itself. Loops at most twice over
    # run_checks(): once for the initial check, and — only if failures
    # exist and --auto-fix was passed — once more after a single auto_fix()
    # attempt. See "Retry-cap control flow" below for exact structure.
```

---

## Data types

```
ReconcileFileResolutionError(RuntimeError)
    # Raised by resolve_reconcile_migration() when the glob match count is
    # not exactly 1. Message MUST state the match count and list whatever
    # matched (so a future rename-collision is diagnosable from stderr
    # alone, not just "file not found").
```

No database schema changes. No new CLI flags are required to satisfy the
three acceptance criteria (a `--max-auto-fix-attempts` override is listed
under "Open questions" as optional, not required).

---

## Error taxonomy

| Condition | Where raised/detected | How surfaced | Exit code |
|---|---|---|---|
| `ReconcileFileResolutionError`: zero files match `*_iss0112_schema_ledger_reconcile.sql` | `resolve_reconcile_migration()` | Caught inside `auto_fix()`, printed to stderr with the glob pattern and searched directory named, `auto_fix()` returns `False` | 1 (via `main()`'s no-retry-after-failed-fix path) |
| `ReconcileFileResolutionError`: 2+ files match the glob | `resolve_reconcile_migration()` | Same as above, message additionally lists every matched filename so the ambiguity is diagnosable from stderr alone | 1 |
| Reconcile SQL execution raises (any `Exception` from `cur.execute`/`conn.commit`) | `auto_fix()` | Caught, printed to stderr with the resolved filename and the exception text (same style as today's existing `except Exception as exc` at line 167), `auto_fix()` returns `False` | 1 |
| `psycopg2.OperationalError` on the initial or recheck connection attempt | `main()`'s `connect()` call | Printed to stderr (unchanged from current behavior at line 255-256) | 2 |
| `BPM_TEST_DB_URL` / `--db-url` missing | `main()` (unchanged, line 200-202) | Printed to stderr | 2 |
| Drift detected, `--auto-fix` not passed | `main()` (unchanged behavior, new message wording) | Printed to stderr: "FAIL: N drift condition(s) detected." | 1 |
| Drift detected, `--auto-fix` passed, one fix attempt made, drift still present on recheck | `main()`'s bounded loop, `attempt >= max_attempts` branch | Printed to stderr: "FAIL: N drift condition(s) remain after one auto-fix attempt; not retrying further..." | 1 |
| Drift detected, `--auto-fix` passed, `auto_fix()` itself returns `False` | `main()`'s bounded loop, immediately after the `auto_fix()` call | Printed to stderr: "FAIL: auto-fix attempt did not succeed; see error above. Not retrying." | 1 |
| All checks pass (first pass, or after a successful auto-fix + recheck) | `main()` | "All baseline checks PASS." to stdout | 0 |

All error paths are terminal within a single `main()` invocation — none of
them re-enter the loop beyond the documented `max_attempts = 2` bound, and
none of them raise an uncaught exception out of `main()` itself (the only
exceptions permitted to propagate are `SystemExit` via `sys.exit(main())`
at the bottom of the file, unchanged from today).

---

## 1. Stale filename fix — dynamic resolution

**Problem sites** (all four confirmed in ISS-0146's root-cause analysis):
docstring line ~18, `auto_fix()` lines ~155-168 (three separate literal
occurrences: the path build, the success message, the failure message),
argparse `--auto-fix` help text ~line 186, and the runtime status message
at ~line 260 ("re-applying GBL-105...").

**Design decision:** per ISS-0088/GH#337 precedent (identical anti-pattern
class: a hardcoded filename silently desyncs on the next rename, "with no
compile-time signal") and per ISS-0146's own acceptance criterion 1, do
**not** simply substitute the literal `GBL-105...` for `GBL-133...` — that
only resets the clock until the next renumbering. Resolve the file
dynamically by globbing for the stable part of the name.

**Stability observation:** in this migration-naming scheme the `GBL-NNN`
numeric prefix is the part that changes on renumbering (confirmed via the
db362fd rename commit cited in ISS-0146 — ~22 sibling files were
renumbered in the same commit). The suffix `_iss0112_schema_ledger_reconcile.sql`
is the stable, purpose-bearing part and is not expected to change on a
renumbering-only rename.

**`resolve_reconcile_migration(migrations_dir)` — exact behavior:**

1. Glob `migrations_dir` for the pattern `*_iss0112_schema_ledger_reconcile.sql`
   (same `Path.glob()` mechanism `get_migration_files()` already uses at
   line 49 — no new dependency).
2. Sort the matches (for determinism; mirrors `get_migration_files()`'s
   existing `sorted(...)` convention).
3. If the match count is exactly 1: return that single `Path`.
4. If the match count is 0: raise `ReconcileFileResolutionError` with a
   message naming the glob pattern and `migrations_dir` searched (e.g.
   "no file matching '*_iss0112_schema_ledger_reconcile.sql' found under
   `<migrations_dir>`; cannot auto-fix"). Do NOT silently return `None` or
   skip — the caller must be able to print a clear, specific error rather
   than a generic failure.
5. If the match count is >1: raise `ReconcileFileResolutionError` listing
   all matched filenames, and state explicitly that this is ambiguous and
   the tool will not guess. (Defensive: this is the scenario where two
   iss0112-reconcile files could coexist mid-rename or due to a botched
   copy — silently picking one, e.g. the first alphabetically, would risk
   applying the wrong ledger-reconcile SQL against a shared test database.
   Fail clearly instead.)

**Call sites updated to use this helper instead of the literal:**

- `auto_fix()`: replace the literal path build (`migrations_dir /
  "GBL-105_iss0112_schema_ledger_reconcile.sql"`) with a call to
  `resolve_reconcile_migration(migrations_dir)`, wrapped so that a raised
  `ReconcileFileResolutionError` is caught at the top of `auto_fix()`,
  printed to stderr (message = the exception's message, no filename
  literal), and causes `auto_fix()` to `return False` immediately — no
  behavior change in *how* failure is communicated (still stderr + no
  exception escaping to `main()`), only *how the target file is found*.
- `auto_fix()`'s success/failure print messages (currently "auto-fix
  GBL-105 applied" / "auto-fix GBL-105 failed: ..."): replace the literal
  "GBL-105" token with the resolved file's actual name (e.g.
  `resolved_path.name`) so the printed message always matches the file
  that was actually executed, and never goes stale again regardless of
  future renumbering.
- `main()`'s runtime status message ("re-applying GBL-105..."): change to
  a generic phrase that names the *purpose* rather than a specific
  filename, e.g. "re-applying iss0112 schema-ledger reconcile migration...".
  This line does not need the resolved filename (that appears in
  `auto_fix()`'s own success/failure message immediately after), so it
  should not embed any migration-number literal at all.
- Docstring line ~18 (`--auto-fix` flag description) and argparse help
  text ~line 186: both currently say "via GBL-105" / "re-emitting the
  GBL-105 ledger reconcile SQL". Reword both to describe the mechanism
  without naming a specific migration number, e.g. "attempt a one-shot
  auto-reconcile by re-emitting the iss0112 schema-ledger-reconcile
  migration SQL (resolved dynamically from `migrations/`)". This keeps the
  help text truthful regardless of future renumbering — the same
  motivation as the code-level fix, applied to documentation strings.

---

## 2. Bounded retry cap — non-recursive control flow

**Problem:** `main()` currently computes `failures`, and when
`failures and args.auto_fix` is true, calls `auto_fix()` (side-effecting,
previously returned `None`) and then unconditionally `return main()`
(line 264) with no depth counter and no check of whether the fix actually
worked. Because `auto_fix()` failed identically every time (stale
filename), the same `failures` were recomputed forever, bounded only by
Python's call-stack recursion limit — each level opening a fresh Postgres
connection (`connect(args.db_url)` inside `main()`'s own `with` block),
which is what produced the observed 5x-loop / "sorry, too many clients
already" symptom.

**Design decision:** enforce that auto-fix is genuinely **one-shot**, per
the tool's own existing docstring language ("attempt a one-shot
auto-reconcile") — the current code says one-shot but behaves as
unbounded-recursive. Fix behavior to match the documented contract, do not
just raise a numeric cap.

**Refactor — extract `run_checks()`:**

Pull the entire body of the current `with connect(args.db_url) as conn:`
block (everything from `check_migration_ledger_count` through
`check_expected_check_constraints`, lines ~211-254) out of `main()` into a
new helper `run_checks(conn, migrations_dir, migration_files,
check_tenants) -> list[str]`. This helper:

- Takes an already-open `conn` (connection lifecycle stays owned by
  `main()`, unchanged from today).
- Runs the same four checks in the same order, printing the same
  `[OK]`/`[FAIL]` lines it prints today (no change to visible check
  output).
- Returns the `failures` list. No recursion, no auto-fix call, no
  knowledge of `--auto-fix` at all — this helper's only job is
  "check-and-report once."

**Non-recursive `main()` control flow:**

Setup stage (unchanged from current lines 171-205 — parse args, validate
`db_url`, resolve `migrations_dir` + `migration_files`), then a bounded
loop replaces the old `return main()` recursion:

```
attempt = 0
max_attempts = 2   # 1 initial check + at most 1 post-auto-fix recheck

loop:
    attempt += 1
    try:
        with connect(args.db_url) as conn:
            failures = run_checks(conn, migrations_dir, migration_files,
                                   args.check_tenants)
    except psycopg2.OperationalError as exc:
        print ERROR could not connect ...; return 2

    if not failures:
        print "All baseline checks PASS."; return 0
    if not args.auto_fix:
        print "FAIL: N drift condition(s) detected." (stderr); return 1
    if attempt >= max_attempts:
        print to stderr: "FAIL: N drift condition(s) remain after one
            auto-fix attempt; not retrying further (see
            docs/guides/test_infrastructure_guide.md §6)."
        return 1
    # attempt == 1, auto_fix requested, failures present: the one
    # permitted auto-fix attempt, then loop back for one recheck.
    print "auto-fix requested; re-applying iss0112 schema-ledger
           reconcile migration..."
    fixed = auto_fix(args.db_url, migrations_dir)
    if not fixed:
        print to stderr: "FAIL: auto-fix attempt did not succeed; see
            error above. Not retrying."
        return 1
    print "Re-running checks after auto-fix..."
    # loop continues -> attempt becomes 2 -> run_checks() called once
    # more -> if failures persist, `attempt >= max_attempts` fires and
    # returns 1 above. No third attempt is reachable.
```

Key properties this satisfies (mapping to ISS-0146 acceptance criterion 2):

- **No recursion.** `main()` calls itself zero times; the loop is a plain
  `while`/`for` construct bounded by `max_attempts = 2`.
- **`auto_fix()` returns a status** (`bool`), so `main()` can distinguish
  "fix applied, worth rechecking" (`True` — proceed to the recheck) from
  "fix failed outright, no point rechecking" (`False` — fail fast
  immediately, do not even spend a second `run_checks()` round-trip or
  open another connection).
- **At most 2 connections opened per invocation** (one per `run_checks()`
  call), replacing the previous unbounded-per-recursion-depth connection
  growth that exhausted Postgres's `max_connections`.
- **Fails fast with a clear terminal message** distinguishing three
  distinct end states: (a) fixed successfully → checks pass → exit 0;
  (b) auto-fix itself failed (file missing/ambiguous, or SQL error) →
  clear stderr message naming the failure → exit 1, no retry; (c) auto-fix
  "succeeded" but drift persists on recheck → clear stderr message stating
  N conditions remain after one attempt → exit 1, no retry.
- **`max_attempts` as a named constant** (not threaded through as a new
  CLI flag) is sufficient to satisfy the acceptance criterion; see "Open
  questions" for the optional CLI-override extension BACKEND-DEV may skip.

---

## 3. Verification path (manual repro — no pytest suite required)

This tool has no Python test framework wired up (confirmed — this is a
standalone script under `tools/`, not part of `zig build test`), so the
verification is a precise, reproducible manual procedure BACKEND-DEV runs
at Step 3 (self-review) against `db_test`, not a new automated suite.

**Repro procedure:**

1. Confirm target database: `echo $BPM_TEST_DB_URL` must point at the
   local `db_test` instance (never a shared/CI database — this test
   intentionally corrupts a row).
2. Deliberately orphan a tenant row — connect with a `search_path` that
   resolves the public `tenant` table (the tool itself always queries
   `tenant` and the standard PostgreSQL system catalog view for schema
   existence, unqualified — see `check_tenant_schemas_consistent`) and
   insert a row with
   `storage_mode='SCHEMA'` and an `id` for which no matching
   `tenant_<uuid-no-dashes>` (or `tenant_default` for the nil UUID) schema
   exists. Use a fresh random UUID so the row can be identified and
   cleaned up unambiguously afterward, e.g.:
   ```
   INSERT INTO tenant (id, storage_mode, ...other required NOT NULL columns...)
   VALUES ('<fresh-uuid>', 'SCHEMA', ...);
   ```
   (BACKEND-DEV: read the `tenant` table's current column list before
   writing this INSERT — do not guess column names.)
3. Run: `python tools/verify_schema_baseline.py --check-tenants --auto-fix`
4. **Expected behavior after the fix:**
   - `check_tenant_schemas_consistent` reports `[FAIL]` and lists the
     orphaned tenant → its expected schema name (this part is unchanged
     — the detection was never broken, only the fix was).
   - Exactly one "`--auto-fix requested; re-applying iss0112 schema-ledger
     reconcile migration...`" line appears (not five).
   - `auto_fix()` locates the current reconcile file via
     `resolve_reconcile_migration()` (no "not found" error — this is the
     regression check for fix #1) and executes it.
   - Exactly one "`Re-running checks after auto-fix...`" line appears,
     followed by exactly one more round of `[OK]`/`[FAIL]` check output
     (not a fifth repeated block).
   - Final exit code is **0** if the reconcile SQL's logic actually
     resolves this class of drift (i.e. the ledger-reconcile migration is
     designed to fix exactly this orphaned-row condition per its own
     purpose), OR a single clean **exit 1** with the new "N drift
     condition(s) remain after one auto-fix attempt" message if the
     reconcile SQL does not address this particular row (e.g. if it only
     reconciles ledger rows, not tenant/schema mismatches — BACKEND-DEV
     must read `GBL-133_iss0112_schema_ledger_reconcile.sql`'s actual SQL
     body to know which outcome is correct; either is an acceptable
     *fixed* result for ISS-0146 as long as it is a single clean
     terminal outcome, not a repeat loop).
   - No `psycopg2.OperationalError` / "sorry, too many clients already" —
     confirm via `SELECT count(*) FROM pg_stat_activity WHERE datname =
     current_database();` before and after the run; the count must return
     to its pre-run baseline (i.e. no leaked connections), and must never
     spike by more than 1-2 during the run.
5. **Cleanup (mandatory, regardless of outcome):** `DELETE FROM tenant
   WHERE id = '<fresh-uuid>'` and, if `resolve_reconcile_migration`
   schema-provisioned anything for that tenant, drop it too. Do not leave
   the deliberately-orphaned row in
   `db_test` after verification — this matches the cleanup ISS-0144's
   resolution notes had to do manually because the auto-fix path was
   broken; with this fix, the row should either be *reconciled* by the
   tool itself or *removed* by this manual cleanup step, never left
   behind either way.
6. Re-run `python tools/verify_schema_baseline.py --check-tenants` (no
   `--auto-fix`) once more to confirm a clean baseline (`All baseline
   checks PASS.`, exit 0) after cleanup.

This procedure directly exercises all three fixes together: dynamic file
resolution (step 4's "no not-found error"), the bounded retry (step 4's
"exactly one repeat, not five"), and the actual reconcile behavior on a
real orphaned row (step 4's pass/fail-clean outcome) — which is the one
path ISS-0144 explicitly noted had never been observed to succeed.

---

## Key invariants

- `auto_fix()` never raises past its own boundary; every failure mode
  (file resolution, SQL execution) is caught internally and surfaced as
  `return False` + a stderr message.
- `main()` never calls itself. The entire retry mechanism is a bounded
  loop with `max_attempts = 2`, enforced by a local counter, not by
  parsing text output or catching a specific exception type.
- No migration file is ever selected ambiguously — `resolve_reconcile_migration`
  fails loudly (raises, caught, printed, `auto_fix` returns `False`) on
  0-match or 2+-match, never silently picks one.
- At most 2 Postgres connections are opened per `verify_schema_baseline.py`
  invocation, regardless of how many drift conditions are detected or
  whether `--auto-fix` is passed.
- CLI contract (flag names, exit codes 0/1/2, `[OK]`/`[FAIL]` line format
  for the four existing checks) is unchanged — this is a bugfix to
  internal control flow and file resolution, not a CLI redesign.

---

## External dependencies

- `pathlib.Path.glob()` — already imported/used in this file
  (`get_migration_files`, line 49); no new dependency.
- `psycopg2` — unchanged, already the sole DB dependency.
- `migrations/GBL-133_iss0112_schema_ledger_reconcile.sql` — the current
  on-disk file `resolve_reconcile_migration` must resolve to today; its
  SQL body is out of scope for this fix (confirmed byte-identical
  business logic vs. the old GBL-105 name per ISS-0146's root-cause
  analysis, only embedded string literals differ).
- `docs/guides/test_infrastructure_guide.md §6` — referenced in the
  fail-fast message for operator guidance; no content change required
  there for this fix (verify the anchor exists; if §6 does not already
  document the auto-fix one-shot contract, that is a documentation gap
  DOC-UPDATER should note, not a blocker for this fix).

**This module MUST NOT depend on:**

- **No new third-party packages.** The fix must be implementable using only
  what this file already imports (`psycopg2` for the DB connection,
  stdlib `pathlib`, `argparse`, `os`, `sys`). Do not add any new pip
  dependency to resolve the filename, implement the retry cap, or run the
  verification procedure.
- **No subprocess/shell-out to apply the migration.** The reconcile SQL
  must continue to execute in-process via the existing `psycopg2` cursor
  `execute()` path (as `auto_fix()` does today) — not via `subprocess.run`,
  `os.system`, `psql -f`, or any external process invocation.
- **No coupling to `zig build test-integration` or the Zig test harness.**
  `tools/verify_schema_baseline.py` is a standalone Python tool invoked
  directly (`python tools/verify_schema_baseline.py ...`); the manual
  verification procedure in section 3 runs it directly against `db_test`
  and must not be wired into, or made a precondition of, any Zig build
  step or test target.
- **No runtime dependency on `docs/issues/*.json`.** `ISS-0146.json` is a
  diagnosis/bookkeeping artifact consumed by agents during triage — it is
  not a runtime input to `verify_schema_baseline.py`, and the fixed code
  must not read from, glob, or otherwise depend on the `docs/issues/`
  directory to do its work.

---

## Open questions

- Whether to expose `max_attempts` as a `--max-auto-fix-attempts` CLI
  override (e.g. for a future scenario needing more than one retry) is
  left to BACKEND-DEV's discretion — the ISS-0146 acceptance criteria only
  require *a* bounded cap, not operator configurability. Recommend
  keeping it a named constant (`MAX_AUTO_FIX_ATTEMPTS = 2` at module
  scope) unless a concrete need for runtime configuration surfaces later;
  do not add flag surface area speculatively.
- Whether `resolve_reconcile_migration` should be generalized beyond the
  single iss0112 case (e.g. a general "resolve migration by stable
  suffix" utility reusable by other tools) is out of scope for this fix.
  ISS-0146's scope is `tools/verify_schema_baseline.py` only; a general
  utility is a separate, future improvement if a second caller emerges.
