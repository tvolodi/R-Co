# Module: fix-ISS-0106 — serialize ISS-503 out of the concurrent `test-integration` group

## Summary

GitHub #364 / ISS-0106 (BLOCKER). `db_integration_test.zig`'s TC-DB-01-01 and
TC-DB-01-02 fail non-deterministically under `zig build test-integration`
(`SELECT COUNT(*) FROM schema_migrations` observed as `0`), amid Postgres
`deadlock detected` (40P01) errors. ISSUE-FIXER's source-verified root cause
(`docs/issues/ISS-0106.json`): `tests/integration/test_iss503_rls_removal.zig`
(TC-ISS503-01/02/03) opens its own raw `pg.Conn` — bypassing
`helpers.zig`'s `TestHarness`/advisory-lock machinery entirely — and executes
GBL-084's full DDL body (`ALTER TABLE ... DROP COLUMN`, `DROP POLICY`,
`DROP FUNCTION` against shared `public`-schema business tables) inside an
uncommitted transaction that is held open for the whole test body before a
final `ROLLBACK`. Every DDL statement in that body takes `AccessExclusiveLock`.
`build.zig`'s `test-integration` step wires ~20 independent test-binary `Run`
steps as sibling dependencies of one umbrella `Step` with no ordering between
them, so Zig's build runner executes them concurrently by default — meaning
ISS-503's long `AccessExclusiveLock`-holding transaction runs in the same
window as every other DDL/migration-touching binary (including
`db_integration_test.zig`'s own `TestHarness.init()` → `runMigrations()` /
`runForSchema()` calls), producing genuine cross-binary Postgres deadlocks
when lock-acquisition order differs between concurrent transactions.

This design addresses the root cause directly: remove the concurrency window
by restructuring the `build.zig` dependency graph so the ISS-503 binary never
runs at the same time as any other `test-integration` member. It does not
add a retry, a sleep, or a lock-timeout workaround — those would mask the
symptom (query queuing/serialization skew and occasional deadlock aborts)
without removing the actual overlapping-`AccessExclusiveLock` condition that
causes it.

## Fix scope confirmation

Exactly the 2 files listed in `ISS-0106.json.files_to_change`:

- `build.zig` — primary fix (dependency-graph restructuring).
- `tests/integration/test_iss503_rls_removal.zig` — defense-in-depth hardening
  (see "Advisory-lock hardening" section below for the decision and scope).

No third file is required. `tests/integration/helpers.zig` and
`src/db/migrations.zig` were already read and confirmed by ISSUE-FIXER not to
need changes — this design does not revisit that conclusion, and the advisory
lock this design's hardening step reuses is read from `helpers.zig`, not
written to it (see below). Total: 2 files, within the ≤5 constraint.

## Part 1 — `build.zig`: serialize ISS-503 out of the concurrent group (primary fix)

### Current structure (as read from `build.zig`, current `main` branch)

`build.zig` declares one `Step.Compile` (`b.addTest`) and one wrapping
`Step.Run` (`b.addRunArtifact`) per integration test binary. Around line
1106–1116, the ISS-503 binary is declared exactly like every sibling:

- `iss503_integration_tests` — the compiled test artifact
  (`tests/integration/test_iss503_rls_removal.zig`).
- `run_iss503_integration_tests` — the `Step.Run` that executes it
  (`b.addRunArtifact(iss503_integration_tests)`, with `setCwd` and
  `BPM_MIGRATIONS_DIR` configured).

Two independent aggregate `Step`s currently depend on
`run_iss503_integration_tests.step`:

1. **`test_integration_iss503_step`** (line ~1303–1305, `zig build
   test-integration-iss503`) — a narrow-scope step that depends only on
   `clean_test_db.step` and `run_iss503_integration_tests.step`. This step
   already runs ISS-503 alone (it has no sibling `dependOn` calls), and is
   out of scope for this fix — leave it exactly as-is.

2. **`test_integration_step`** (line 1243, `zig build test-integration`) —
   the umbrella step. Starting at line 1244 it calls `.dependOn(&clean_test_db.step)`
   once, then issues one `.dependOn(&run_<X>_integration_tests.step)` call per
   binary for ~20 binaries (lines 1245–1266, plus two more appended later at
   lines 1396 and 1446 for binaries declared further down the file). Line
   1258 is `test_integration_step.dependOn(&run_iss503_integration_tests.step)`
   — this is the one sibling edge that must be removed and replaced.

Zig's build runner treats every `dependOn` edge on a `Step` as "must complete
before this step is considered done," but it does **not** impose any
ordering *among* a step's own dependencies — siblings with no edge between
them are scheduled according to the runner's own parallelism (bounded by
`-j`/available worker threads), which is concurrent by default. Because
`run_iss503_integration_tests.step` currently has no incoming edge from any
of the other 19+ sibling `Run` steps (nor they from it), the runner is free
to execute it at the same time as `run_integration_tests.step`
(`db_integration_test.zig`'s own binary, via `main_test.zig`) or any other
member. That is the entire mechanism of the bug: no ordering edge exists
between the DDL-heavy ISS-503 binary and the rest of the group.

### Required change (structural, not literal diff)

Introduce a **barrier / fence** in the dependency graph: the rest of the
`test-integration` group must be forced to complete in full before
`run_iss503_integration_tests.step` is allowed to start (running it *after*
is preferred over *before*, since it lets the far larger/more
frequently-changed body of the suite fail fast without waiting on the
single DDL-heavy binary first; either ordering removes the concurrency
window, so *after* is a preference, not a hard requirement of correctness).

Concretely:

1. **Stop adding `run_iss503_integration_tests.step` to `test_integration_step`
   as a plain sibling.** Remove line 1258
   (`test_integration_step.dependOn(&run_iss503_integration_tests.step);`)
   from the flat sibling list.

2. **Introduce one new intermediate barrier `Step`** — a step with no action
   of its own, whose sole purpose is to represent "all of the
   non-ISS-503 `test-integration` members have finished." Zig's build system
   supports exactly this via a plain `b.step(name, description)` (the same
   primitive already used for every umbrella step in this file, e.g.
   `test_integration_step` itself, `clean_test_db_step`, etc. — a `Step`
   created via `b.step()` performs no work by itself; it only aggregates
   `dependOn` edges and is satisfied once all of them are satisfied). Give it
   every `.dependOn(&run_<X>_integration_tests.step)` edge that
   `test_integration_step` currently holds for the OTHER ~19+ binaries
   (i.e., the exact list at lines 1245–1266 minus the ISS-503 line, plus the
   two later-appended ones at lines 1396/1446) — the same edges, just
   redirected onto this new intermediate step instead of directly onto
   `test_integration_step`. `clean_test_db.step` stays a direct dependency of
   this new barrier step (or of `test_integration_step` — either placement
   is correct since `clean_test_db` must precede everything and has no
   ordering conflict with the barrier itself).

3. **Chain the ISS-503 run step behind that barrier.** Give
   `run_iss503_integration_tests.step` a new `dependOn` edge on the barrier
   step created in (2). This is the critical edge: because
   `run_iss503_integration_tests` is a concrete `Step.Run`, and Zig's `Step`
   base type accepts `dependOn` on any `*Step` regardless of concrete kind
   (the same pattern already used throughout this file for
   `<run_x>.step.dependOn(&clean_test_db.step)`-style edges, and for
   `clean_test_db.step.dependOn(&lint_test_table_refs.step)` at line 1239),
   this is a direct, supported operation — `run_iss503_integration_tests.step.dependOn(&<barrier>.step)`.
   This forces the build runner to treat "the barrier step is done" as a
   precondition for starting ISS-503's run, and since the barrier step's own
   completion condition is "every other `test-integration` binary has
   finished," this transitively serializes ISS-503 to run only after the
   rest of the group — never concurrently with any of them.

4. **Re-attach ISS-503 to the umbrella step through the same edge type as
   everything else.** `test_integration_step` needs
   `.dependOn(&run_iss503_integration_tests.step)` restored (so `zig build
   test-integration` still runs ISS-503 as part of the full suite and still
   fails the umbrella step if ISS-503 fails) — but now this edge is safe,
   because by the time the build runner is willing to start
   `run_iss503_integration_tests.step` (per point 3), the barrier — and
   therefore every sibling — has already completed.

Resulting DAG shape for `test-integration`:

```
clean_test_db
     |
     v
 <barrier: all-other-integration-tests>  (new Step, aggregates the ~19+
     |         ^                          existing sibling Run steps
     |         |  (all of them, concurrently among themselves —
     |         |   unaffected by this change)
     |    (already-existing edges, redirected here from
     |     test_integration_step)
     v
 run_iss503_integration_tests
     |
     v
 test_integration_step   (depends on the barrier transitively via
                           run_iss503_integration_tests, AND depends
                           on run_iss503_integration_tests directly to
                           surface its own pass/fail)
```

Note that the ~19+ *other* binaries remain fully concurrent with each other —
this design narrows the fix to exactly the one binary ISSUE-FIXER identified
as the DDL-lock-holding offender. It does not serialize the whole suite (that
would be a large, unjustified performance regression and is not what the
root cause calls for).

### Why this produces "runs alone" behavior in Zig's build graph

Zig's build runner is a task scheduler over the step DAG: a step becomes
eligible to run only once every step it `dependOn`s has finished, and
eligible steps with no relative ordering are free to run in parallel. By
construction, after this change there is a path from every one of the
~19+ other binaries' `Run` steps to `run_iss503_integration_tests.step`
(through the barrier), and no path in the other direction — so the
scheduler can never start ISS-503 before all of them finish, and (because
nothing in the graph depends on ISS-503 finishing before those other
binaries start) they retain their current concurrency among themselves. The
net effect is exactly "ISS-503 runs alone, after everything else" without
touching any of the other 19+ binaries' own wiring.

### Naming guidance (non-binding — BACKEND-DEV's judgement on exact identifiers)

Suggested identifiers consistent with this file's existing naming
conventions (`snake_case`, `_step` suffix for `b.step()`-created steps):
`test_integration_others_step` or `test_integration_pre_iss503_barrier_step`
for the new intermediate step. This is a naming suggestion only — it carries
no externally-visible `zig build <name>` surface unless BACKEND-DEV chooses
to expose it via `b.step()` with a description (optional; it is legitimate
for the barrier to be a step that is never named/exposed as a top-level `zig
build` target if the chosen API path allows an unexposed `Step` — if the
concrete Zig version in use requires every `Step` to be registered via
`b.step()` to exist at all, then exposing it as an internal-use-only named
step, e.g. `test-integration-others-internal`, with a description noting
"internal barrier — not intended for direct invocation," is the correct
fallback).

### Non-goals for this change

- Do **not** alter `test_integration_iss503_step` (`zig build
  test-integration-iss503`) — it already runs ISS-503 alone and is
  unaffected.
- Do **not** alter the concurrency of the other ~19+ binaries relative to
  each other.
- Do **not** introduce a sleep, retry, or deadlock-retry wrapper anywhere —
  that would treat the symptom (occasional 40P01) rather than the cause
  (genuine temporal overlap of incompatible locks).

## Part 2 — advisory-lock hardening in `test_iss503_rls_removal.zig`: DEFERRED, not included

**Decision: do not add advisory-lock hardening in this fix.** Per the
"Design MUST be minimal" rule (WF-03 Step 2), Part 1 alone fully closes the
proven concurrency window — the root cause is provably eliminated once
ISS-503's binary cannot execute while any other `test-integration` binary is
running, regardless of whether ISS-503 also takes an advisory lock. Adding a
second, redundant serialization mechanism (`pg_advisory_lock` inside
`test_iss503_rls_removal.zig`) has zero effect on top of Part 1 for the
BLOCKER this issue actually reports, and would still be structurally
incomplete as *sole* protection even if it were added: `ISS-0106.json`'s
`chosen_resolution` field already establishes that
`bpm_test_migrations_public` (or any single dedicated key) only ever
serializes ISS-503 against *other advisory-lock-aware callers* — it provides
no protection against a plain `TestHarness.init()`/`runMigrations()` caller
racing it unless that caller happens to take the *same* lock key at the
*same* moment, which is exactly the coincidence Part 1 removes structurally
instead of relying on.

Rationale against adding it now, weighed explicitly:

- **What it would buy:** a residual safety net if some future change to
  `build.zig` accidentally reintroduces concurrency for ISS-503 (e.g. a
  merge conflict silently restores the old sibling edge, or a new binary is
  added and mistakenly wired as concurrent with ISS-503 instead of behind
  the barrier).
- **What it would cost:** touching a 3rd behavioral surface
  (`test_iss503_rls_removal.zig`'s three raw-connection tests would each
  need `pg_advisory_lock`/`pg_advisory_unlock` calls added around their
  `BEGIN`/DDL/`ROLLBACK` bodies) for a scenario Part 1 already prevents by
  construction — the graph edge is a compile-time-checked structural
  guarantee, not a runtime race that "usually" works.
- **Verdict:** the residual risk is a *build.zig regression*, not a
  *runtime race left open by this fix*. The correct defense against a future
  `build.zig` regression is a comment at the barrier step (see Part 1) plus,
  if BACKEND-DEV or a future contributor wants a stronger structural
  guardrail, a follow-up issue for a lint/CI check that asserts ISS-503's run
  step has no concurrent-with edges — not a second, independent runtime lock
  bolted onto the test file. That follow-up is explicitly out of scope here
  (no such check currently exists for any of the other 19+ binaries either,
  so requiring it only for ISS-503 as part of this fix would be
  over-engineering relative to the rest of the codebase's current
  conventions).

**Action for `tests/integration/test_iss503_rls_removal.zig` in this fix:**
add a short doc comment (near the top of the file, alongside the existing
"IMPORTANT — shared `public` schema semantics" block, or as its own
paragraph immediately after it) stating that these tests rely on `build.zig`
serializing this binary out of the concurrent `test-integration` group
(cross-referencing ISS-0106/#364 and the barrier step introduced in Part 1
by name), and that reintroducing concurrent execution of this binary
alongside any other `public`-schema-touching binary will reopen the deadlock
this issue fixed. This is documentation only — no behavioral/functional
change to the file, no new imports, no new connection/lock calls. This is
why `tests/integration/test_iss503_rls_removal.zig` remains listed in
`files_to_change`: the change is a comment addition, not a no-op.

## Error taxonomy changes

None. This is a build-graph/dependency-ordering change, not an error-set
change. No new `error{}` members, no changed function return types, no
changed `error_map`. `test_iss503_rls_removal.zig`'s only change is a doc
comment (see Part 2) — no code paths, and therefore no error paths, are
added, removed, or altered.

## Callers / scripts impacted

- `zig build test-integration` (the umbrella step) — behavior change: total
  wall-clock time increases slightly, because ISS-503 no longer overlaps
  with the rest of the group and instead runs serially after it. This is the
  intended fix, not a regression: the prior "faster but occasionally
  deadlocks and produces a false failure on unrelated tests" behavior is
  strictly worse than "slightly slower but deterministic."
- `zig build test-integration-iss503` — unaffected (already runs ISS-503
  alone).
- `.github/agents/test-runner.agent.md` and
  `.github/instructions/backend-dev.instructions.md` — both reference `zig
  build test-integration` as a plain invocation with no hard-coded timeout,
  parallelism flag, or duration assumption; no change needed.
- No `.github/workflows/` directory exists in this repository (checked
  directly — `ls .github/workflows` finds nothing), so there is no GitHub
  Actions CI workflow YAML to audit for a hard-coded timeout on this step.
  If CI is added later, the barrier-induced serial tail for ISS-503 should
  be accounted for in any timeout chosen at that time, but that is out of
  scope for this fix since no such CI config currently exists.
- No other `zig build test-integration-*` narrow-scope step
  (`test-integration-xc04`, `-tm`, `-svc`, `-env`, etc.) depends on
  `test_integration_step` or on the new barrier step — each of those is
  independently wired directly to its own single binary plus
  `clean_test_db.step`, so none of them are affected by this change.

## Open questions

None blocking. The one implementation-detail choice left to BACKEND-DEV is
the exact identifier chosen for the new barrier step (see "Naming guidance"
above) and whether the barrier needs to be registered via `b.step()` to be
constructible as a valid `*Step` handle under the Zig version this repo
currently builds with — BACKEND-DEV should follow whatever this file's
existing `Step`-construction idiom requires (the file consistently uses
`b.step(name, description)` for every non-leaf aggregating step observed
during this design's review, so the same idiom is expected to apply here).
