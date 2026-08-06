# ISS-0148 — Cleanup/Test Ordering in the Build Graph + Advisory-Lock Guard in the Orphan Sweep

**Run ID:** WF03-gh477-20260806
**Issue:** [GH-477](https://github.com/tvolodi/R-Co/issues/477) (ISS-0148)
**Classification:** **Type E** (novel / cross-cutting change to shared build tooling and a maintenance script)
**Step:** WF-03 Step 2 — CODE-DESIGNER fix design
**Upstream artefact:** [diagnosis report](../../docs/issue-reports/ISS-0148-diagnosis.yaml)
**Implementer:** BACKEND-DEV (Step 3), after the CODE-DESIGN-VALIDATOR gate

## Classification rationale

Applying the selection rules in `templates/lego-catalog.md` in order:

1. **Type C?** No. No table/column is added, altered, or removed; no migration file is created.
2. **Type A?** No. No HTTP route is added.
3. **Type D?** No. No React Flow node.
4. **Type B?** No. No admin/list page.
5. **Type E — yes.** The change is cross-cutting build-graph topology plus a concurrency guard in a shared maintenance script. `templates/lego-catalog.md` explicitly reserves "cross-module orchestration" and shared-infrastructure concerns for Type E, and there is no Lego piece for build-graph wiring.

---

## Module purpose

Two files are in scope, and the design covers both as one coherent fix:

- **`build.zig`** — restructure the dependency edges so `clean_test_db` is a true ordering **predecessor** of every integration-test run artifact, instead of an unordered **sibling** of them. This is the primary fix: it removes the temporal overlap in which the race can occur.
- **`tools/clean_test_db.py`** — make the orphan tenant-schema sweep hold the same PostgreSQL advisory lock the migration runner already uses, so the sweep and any in-flight `Migrations.runForSchema` transaction are mutually exclusive. This is defence in depth: it makes the drop impossible under *any* scheduling, including invocations that do not go through the build graph at all.

Out of scope: `src/db/migrations.zig` (the diagnosis confirmed its locking, snapshot re-check, transaction boundaries and `search_path` handling are all correct), and every TNT test file (they are faithful detectors of the defect and must not be weakened).

---

## 1. Problem statement

`zig build test-integration-tnt` fails intermittently on TC-TNT-01-01 with PostgreSQL `42P01 relation "<X>" does not exist`, raised from `Migrations.runForSchema` while provisioning a fresh per-test tenant schema. Both the missing relation and the failing migration file vary run to run.

The diagnosis established the mechanism with a DDL-level server log capture and two control arms:

| Arm | Result |
|---|---|
| `zig build test-integration-tnt` (through the build graph) | 5/5 FAIL |
| The **same compiled** `test.exe` invoked directly (no build graph) | 6/6 PASS |

The mechanism, in four steps:

1. `build.zig` hangs `clean_test_db.step` and the `run_*` test artifacts off the **same parent step** as siblings. Zig's build runner imposes **no ordering edge between siblings of one step**, so it is free to run the cleanup script concurrently with the test binaries.
2. TC-TNT-01-01 provisions `tenant_<uuid>` and enters `runForSchema`, applying ~80 per-tenant migration files, one transaction per file.
3. Concurrently, `drop_orphaned_tenant_schemas()` enumerates tenant schemas by **name shape alone** (`LIKE 'tenant\_%'`) and cannot distinguish a leaked schema from one that a live test is migrating right now. It includes the in-flight schema and issues `DROP SCHEMA ... CASCADE`, then deletes the corresponding migration-ledger rows.
4. `runForSchema` keeps applying files against a schema that no longer exists. The first file doing unqualified, `search_path`-resolved work on a table an earlier file created fails `42P01`. **Because the drop lands at a random point in the ~80-file sequence, which file fails and which relation is named vary run to run** — this is precisely the previously unexplained variability.

### 1.1 Explicit non-cause — the duplicate-key error is a red herring

Runs of this suite also emit `C23505 duplicate key value violates unique constraint "schema_migrations_schema_version_uq"` for `(tenant_<uuid>, 001_event_store.sql)`. **This is not part of the defect and must not drive the fix.** It is TC-TNT-02-05's *deliberate* duplicate INSERT, which that test asserts must fail, and it appears identically in **passing** runs (exit 0). Any implementation that "fixes" this error, suppresses it, or treats its disappearance as a success signal has misread the diagnosis. The pass criterion is the **exit code** of the build step, never the absence of this string.

### 1.2 Approaches explicitly rejected

Carried forward from the diagnosis; the implementer must not reach for any of these:

- **Weakening, skipping, or deleting TC-TNT-01-01 or any TNT test.** Forbidden by CLAUDE.md; the test is the detector, not the fault.
- **Retrying `runForSchema` on `42P01`.** This masks a genuine "someone deleted my schema" condition and would make real migration bugs silent.
- **Narrowing the sweep's name pattern, or making it quieter.** This reduces the failure *rate* without removing the race — satisfying the detector rather than fixing the condition.

---

## 2. Affected code — complete verified enumeration

Both lists below were produced by parsing `build.zig` (1621 lines) for `b.step(...)` declarations and their `dependOn` edges, not by estimation.

### 2.1 The defective shape

Every entry below is a step that depends on **both** `clean_test_db.step` **and** one or more `run_*` artifacts, with no ordering edge between them. **39 steps** carry the defect.

| # | Line | Step name | Sibling run artifact(s) |
|---|---|---|---|
| 1 | 1190 | `test-integration` | `run_iss503_integration_tests_after_others` (+ 30 more via the barrier — see §2.2) |
| 2 | 1253 | `test-integration-xc04` | `run_xc04_integration_tests` |
| 3 | 1257 | `test-integration-stage11-sim-xc04` | `run_stage11_sim_xc04_integration_tests` |
| 4 | 1261 | `test-integration-sim05-08` | `run_sim05_08_integration_tests` |
| 5 | 1265 | `test-integration-obs03` | `run_obs03_integration_tests` |
| 6 | 1269 | `test-integration-obs04` | `run_obs04_integration_tests` |
| 7 | 1276 | `test-adp12-regression` | `run_adp12_regression_tests` |
| 8 | 1280 | `test-integration-tm` | `run_tm_integration_tests` |
| 9 | 1284 | `test-integration-iss502` | `run_iss502_integration_tests` |
| 10 | 1288 | `test-integration-iss503` | `run_iss503_integration_tests` |
| 11 | 1292 | `test-integration-exp` | `run_exp_integration_tests` |
| 12 | 1296 | `test-integration-spt01-iss68` | `run_spt01_iss0068_integration_tests` |
| 13 | 1300 | `test-integration-iss0071` | `run_iss0071_realm_guard_integration_tests` |
| 14 | **1304** | **`test-integration-tnt`** | `run_tnt_integration_tests`, `run_tnt_backfill_integration_tests` — **the reported failure** |
| 15 | 1309 | `test-integration-iss101` | `run_iss101_integration_tests` |
| 16 | 1313 | `test-integration-iss102` | `run_iss102_integration_tests` |
| 17 | 1317 | `test-integration-iss103` | `run_iss103_integration_tests` |
| 18 | 1321 | `test-integration-iss0091` | `run_iss0091_integration_tests` |
| 19 | 1325 | `test-integration-iss106` | `run_iss106_integration_tests` |
| 20 | 1329 | `test-integration-iss107` | `run_iss107_integration_tests` |
| 21 | 1333 | `test-integration-iss105` | `run_iss105_integration_tests` |
| 22 | 1337 | `test-integration-iss202` | `run_iss202_integration_tests` |
| 23 | 1341 | `test-integration-iss203` | `run_iss203_integration_tests` |
| 24 | 1345 | `test-integration-iss207` | `run_iss207_integration_tests` |
| 25 | 1349 | `test-integration-iss208` | `run_iss208_integration_tests` |
| 26 | 1353 | `test-integration-iss601` | `run_iss601_integration_tests` |
| 27 | 1357 | `test-integration-iss0125` | `run_iss0125_integration_tests` |
| 28 | 1365 | `test-integration-iss0123` | `run_iss0123_integration_tests` |
| 29 | 1369 | `test-integration-iss0122` | `run_iss0122_integration_tests` |
| 30 | 1373 | `test-integration-iss0121` | `run_iss0121_integration_tests` |
| 31 | 1377 | `test-integration-iss0129` | `run_iss0129_integration_tests` |
| 32 | 1385 | `test-integration-iss0602-same` | `run_iss0602_same_integration_tests` |
| 33 | 1389 | `test-integration-iss0602-cross` | `run_iss0602_cross_integration_tests` |
| 34 | 1393 | `test-integration-iss205` | `run_iss205_integration_tests` |
| 35 | 1397 | `test-integration-sch303` | `run_sch303_integration_tests` |
| 36 | 1414 | `test-integration-exp103` | `run_exp103_integration_tests` |
| 37 | 1431 | `test-integration-svc` | `run_svc_integration_tests` |
| 38 | 1447 | `test-integration-env` | `run_env_integration_tests` |
| 39 | 1464 | `test-integration-iss0072` | `run_iss0072_integration_tests` |

`clean-test-db` (line 1187) also depends on `clean_test_db.step`, but has no sibling run artifact — it is the standalone cleanup entry point and is **not** defective.

### 2.2 Two findings beyond the diagnosis

Both were discovered while enumerating; the implementer must handle them or the fix is incomplete.

**(a) The umbrella `test-integration` path is worse than the per-suite steps.** `test_integration_step` (line 1190) depends directly on only `clean_test_db.step` and `run_iss503_integration_tests_after_others.step`. All **30** other binaries reach it transitively through the `test-integration-others-internal` barrier (line 1204), which itself has **no** edge to `clean_test_db.step`. So on the umbrella path, 30 test binaries are ordered against the sweep only by accident. A fix applied per-*step* would miss them entirely; the fix must attach to the **run artifacts**, which is what §3 specifies.

**(b) One step runs an integration binary with no cleanup at all.** `test-integration-iss0076` (line 1273) depends on `run_iss0076_integration_tests` **without** any `clean_test_db.step` edge. This is a separate pre-existing gap (a suite running against an uncleaned database), not the ISS-0148 race. Adopting the §3 helper uniformly closes it as a side effect, since the helper attaches the ordering edge to the artifact. The implementer should note this in the handoff result as an incidental finding; it needs no separate issue because the fix subsumes it.

### 2.3 `tools/clean_test_db.py`

| Lines | Construct | Role in the defect |
|---|---|---|
| 46–61 | `run_psql(sql) -> bool` | Executes one statement via `docker-compose exec -T db_test psql -c`. **Each call is its own psql process and therefore its own session and transaction** — the single most important structural fact for §4. |
| 64–75 | `run_psql_query(sql) -> list[str]` | Same, in tuples-only mode, for SELECTs. Same one-session-per-call property. |
| 78–124 | `drop_orphaned_tenant_schemas()` | The sweep. Enumerates from `tenant_schemas` ∪ `information_schema.schemata` by name shape, validates each against `^tenant_[0-9a-f]{32}$`, then drops each and deletes the ledger rows. **The whole function is the critical section.** |
| 119 | `DROP SCHEMA IF EXISTS <name> CASCADE` | The statement caught in the smoking-gun log. |
| 123 | ledger-row `DELETE` | Removes the dropped schemas' migration records. |
| 211, 231 | The two call sites of the sweep | Second call is under `--include-fixtures`. |

---

## 3. Layer 1 — build-graph ordering (primary fix)

### 3.1 Design principle

The ordering edge must be attached to the **run artifact**, not to the aggregating step. Two reasons, both structural:

- Finding (a) above: binaries reached through the `test-integration-others-internal` barrier never touch a step that depends on `clean_test_db`. Only an edge on the artifact itself reaches them.
- A `Step`'s `dependOn` edges are a **global property of that Step** in Zig's build graph, not scoped to the path by which it was reached. Attaching `clean_test_db` to each run artifact therefore guarantees the ordering on *every* path that can reach that artifact — the narrow per-suite step, the umbrella, and the barrier alike.

This same global-edge property is the reason the existing ISS-0106 barrier needed a **second, dedicated** run artifact (`run_iss503_integration_tests_after_others`, line 1247) rather than adding an edge to the shared one. That precedent is a constraint on this design, handled in §3.4.

### 3.2 The helper

Introduce a single file-local helper in `build.zig`. Described by signature and behaviour only; the implementer writes the body.

**Name:** `integrationRun` (or an equally descriptive name).

**Parameters:**
- the `*std.Build` instance,
- the compiled test artifact to run (`*std.Build.Step.Compile`),
- the migrations-directory string already threaded through the existing call sites,
- the `clean_test_db` run step, to be attached as the ordering predecessor.

**Returns:** the created `*std.Build.Step.Run`.

**Behaviour, in order:**
1. Create the run artifact from the compile artifact.
2. Set the working directory to the repository root, as every existing call site does.
3. Set the `BPM_MIGRATIONS_DIR` environment variable from the passed-in value, as every existing call site does.
4. **Declare the returned run step to depend on the `clean_test_db` run step.** This is the ordering edge that fixes the defect.

Steps 1–3 are exactly the three lines repeated verbatim at all 43 existing `addRunArtifact` sites for integration binaries; folding them into the helper is what makes step 4 impossible to omit. This satisfies the "one abstraction, not 39 hand edits" constraint. Once the helper is the only construction path, the ordering edge becomes intrinsic to *how an integration run artifact is built*, so a future contributor adding a suite gets it automatically and cannot reintroduce the defect by forgetting a line.

### 3.3 Application

Convert every integration/regression run artifact to be created through the helper — **43** `addRunArtifact` sites, which is the superset covering all 39 defective steps in §2.1 plus the barrier-only and no-cleanup cases in §2.2. Once each artifact carries its own edge, the pre-existing `dependOn(&clean_test_db.step)` lines on the 39 aggregating steps become redundant. The implementer may either leave them (harmless — Zig deduplicates, and each aggregating step still needs its edge to its run artifact) or remove them; **leaving them is the lower-risk choice** and is recommended, because removing 39 lines risks dropping a step's only remaining edge by mistake. What must **not** happen is removing an aggregating step's edge to its *run artifact*.

### 3.4 Interaction with the existing ISS-0106 barrier — must be preserved

The barrier at line 1204 serializes `test_iss503_rls_removal.zig` behind every other `test-integration` binary, because it holds `AccessExclusiveLock` outside the shared harness machinery. The new edges must not disturb it:

- `run_iss503_integration_tests_after_others` (line 1247) keeps its `dependOn(test_integration_others_step)` edge unchanged. It additionally gains the `clean_test_db` edge like every other artifact — this is consistent (cleanup before everything) and adds no cycle, since `clean_test_db` depends only on `lint_test_table_refs` and on nothing in the test group.
- `run_iss503_integration_tests` (the shared artifact behind the narrow `test-integration-iss503` step) keeps carrying **no** barrier edge, preserving ISS-0106's explicit non-goal of leaving that narrow step unaffected. It gains only the `clean_test_db` edge.
- **Acyclicity argument:** all new edges point from a run artifact to `clean_test_db`, and `clean_test_db` has no edge into any run artifact. The added edges therefore form a star into a graph sink-side node and cannot close a cycle with the barrier's existing edges.

### 3.5 What Layer 1 does and does not guarantee

**Does:** within a single `zig build` invocation, no test binary starts until the sweep has finished. Zig caches step execution, so `clean_test_db` runs exactly once per invocation regardless of how many artifacts now depend on it — the implementer should confirm this in the build output (the `Dropped N orphaned tenant schema(s).` line appears once).

**Does not:** constrain anything outside that one build invocation — a developer running `zig build clean-test-db` while a suite is running in another terminal, a second workspace pointed at the same database, or CI overlapping two jobs. That residual exposure is exactly what Layer 2 closes.

**Note on parallelism:** making every binary depend on the single `clean_test_db` step orders each binary against *the sweep* only. It introduces no ordering between the binaries themselves, so suite-level parallelism is unchanged.

---

## 4. Layer 2 — advisory-lock guard in the sweep (defence in depth)

### 4.1 The lock to reuse

`src/db/migrations.zig` line 31 defines the migration runner's serialization primitive:

- **Key expression:** `hashtext('bpm.migrations.runForSchema')` cast to `bigint`.
- **Acquisition:** `pg_advisory_xact_lock(...)`, i.e. **transaction-scoped** — auto-released at `COMMIT`/`ROLLBACK`, never leaks across pool-release boundaries.
- **Where taken:** inside each per-migration transaction, immediately after `BEGIN` and before the migration SQL executes (migrations.zig ~line 439).
- **Keyspace:** deliberately disjoint from the audit trigger's per-tenant `hashtext('bpm.audit.chain.' || tenant_id::text)`, so audit inserts stay unblocked. See `src/design/iss0129_migration_runner_advisory_lock.md`.

Reusing this exact key is what makes the guard correct: it is the same primitive the runner already holds, so the sweep and any in-flight `runForSchema` transaction become mutually exclusive by construction. Inventing a second key would serialize the sweep against nothing.

**Single key for all tenants.** Every `runForSchema` caller queues on this one key regardless of `schema_name`. The sweep therefore excludes *all* concurrent migration activity while it holds the lock, which is the desired semantics — the sweep operates on the whole schema namespace, not one tenant.

### 4.2 The critical-section problem this design must solve

`run_psql` spawns a **fresh `psql` process per call**, so every statement runs in its own session and its own implicit transaction. A transaction-scoped lock taken by one `run_psql` call is released the instant that process exits — before the next call even starts. **A naive "call `run_psql('SELECT pg_advisory_xact_lock(...)')` first, then drop" therefore provides no protection whatsoever**, because the lock is gone by the time the DROP runs. The implementer must not do this.

The critical section must span the enumerate → validate → drop → delete-ledger sequence as **one** database session. Two mechanisms satisfy this; the design specifies the first and permits the second.

**Required mechanism — one psql session for the whole sweep.** Add a helper alongside `run_psql`/`run_psql_query` that executes a *multi-statement script* in a single `psql` invocation (the existing `docker-compose exec -T db_test psql` shape, with the script supplied on stdin rather than via `-c`). The script, in order:

1. `BEGIN`.
2. Acquire `pg_advisory_xact_lock(hashtext('bpm.migrations.runForSchema')::bigint)`.
3. Perform the enumerate + drop + ledger-delete work.
4. `COMMIT` — which releases the lock.

Because the lock is transaction-scoped and the whole sequence is one transaction in one session, the lock is held continuously across the DROPs. Note that step 3's enumeration must happen **under** the lock, not before it: an enumeration taken before acquisition can name a schema that a concurrent test provisions and starts migrating in the interval, reintroducing the race in miniature. This is the same "re-check under the lock" discipline ISS-0144 established for the runner's `applied` snapshot, and the same lesson is recorded in `docs/anti-patterns.md`.

The name-shape validation against `^tenant_[0-9a-f]{32}$` (line 113) is a SQL-injection guard on interpolated DDL and **must be preserved**. If enumeration moves server-side, the validation must move with it as an equivalent server-side pattern check — it must not be silently dropped on the grounds that "the names come from the database anyway."

**Permitted alternative — session-scoped lock.** If a single-script formulation proves impractical, `pg_advisory_lock` / `pg_advisory_unlock` (session-scoped rather than transaction-scoped) held across a persistent psql session is acceptable, on one hard condition: the release must be guaranteed on **every** exit path, including exceptions and non-zero psql exits. A session-scoped lock leaked by an aborted sweep would block every subsequent migration on the database — a worse failure than the one being fixed. If the implementer cannot demonstrate guaranteed release, use the required mechanism instead.

### 4.3 Blocking vs. skipping

**The sweep blocks. It does not skip, and it does not use the `_try_` variant.**

Rationale: `pg_advisory_xact_lock` waits until the lock is granted. The sweep's job is to leave the database at a known baseline; a sweep that gave up because a migration was in flight would return without cleaning, and the run would proceed against a dirty database — reintroducing the ISS-0090 leak the sweep exists to prevent. Waiting is also bounded in practice: it waits at most for one per-file migration transaction, since the runner takes the lock per file and releases it at each `COMMIT`. The sweep does not wait for a whole 80-file migration sequence to finish.

The consequence is a real interleaving: the sweep may acquire the lock *between* two of a live test's migration files and drop that test's schema mid-sequence. **Layer 2 alone does not prevent this; Layer 1 does, by ensuring no test is running when the sweep executes.** The two layers are complementary and neither is sufficient alone — this is why both are required. Layer 2's guarantee is narrower and specific: no DROP can ever be *interleaved with the execution of a single migration file*, which is the corruption window that produces `42P01` from a half-applied file. The implementer must not treat Layer 2 as a reason to weaken Layer 1.

### 4.4 Existing behaviour that must be preserved

- `tenant_default` is never dropped — it is the harness's persistent fixture. The existing exclusion applies unchanged in the locked path.
- The `--include-fixtures` second sweep call (line 231) goes through the same locked path; it must not retain an unlocked variant.
- The best-effort posture of the sweep is unchanged: a failure to drop one schema still prints a warning and continues rather than aborting the run. Lock **acquisition** failure is the exception — see §5.
- The `Dropped N orphaned tenant schema(s).` output line is retained. It is diagnostic output, and the ISS-0148 smoking-gun analysis depended on it. Per CLAUDE.md's gate rule, it must not be removed or reworded to make anything stop matching.

---

## 5. Error taxonomy

| Condition | Layer | Behaviour | Rationale |
|---|---|---|---|
| Lock acquisition blocks | 2 | Wait. No timeout. | §4.3. Waiting is bounded by one per-file migration transaction. |
| Lock acquisition fails (connection refused, psql cannot start) | 2 | Abort the sweep with a non-zero exit and a message naming the failure. | The sweep cannot establish exclusivity, so proceeding would be exactly the unguarded behaviour being removed. `main()` already exits non-zero when the initial TRUNCATE fails (line 150); this follows that precedent. |
| A `DROP SCHEMA` fails for one schema | 2 | Warn to stderr, continue with remaining schemas, do not abort. | Preserves existing best-effort semantics. One undroppable leaked schema must not fail the whole run. |
| Enumeration returns no schemas | 2 | Return without dropping. Existing early return at line 107. | Normal case on a clean database. |
| A schema name fails the `^tenant_[0-9a-f]{32}$` check | 2 | Warn and skip that name; never interpolate it into DDL. Existing behaviour at line 117. | SQL-injection guard. Non-negotiable. |
| Transaction rolls back mid-sweep | 2 | Lock released by transaction semantics; report non-zero. | Transaction scoping means no explicit cleanup is needed. |
| A run artifact is created without the helper | 1 | Not detectable by the compiler. Mitigated by the helper being the only construction path, and by the §6 review check. | Zig's build graph has no way to assert "this artifact has a cleanup predecessor". |
| A new edge closes a dependency cycle | 1 | `zig build` fails at graph construction. | §3.4 argues acyclicity; the build is the check. |

No new Zig error-set members are introduced — Layer 1 changes graph topology only, and Layer 2 lives in Python. `src/db/migrations.zig`'s `MigrationError` is unchanged.

---

## 6. Public interface

Neither layer changes any runtime API, HTTP route, database schema, or migration. The interface surface is build steps and a script's internal structure.

**`build.zig`**

- Every existing `test-integration-*` step name, the `test-integration` umbrella, `test-adp12-regression`, and `clean-test-db` are **preserved verbatim**. No step is renamed, added, or removed, so no CI invocation, guide, or agent instruction referencing a step name needs updating.
- The `test-integration-others-internal` barrier keeps its name and semantics.
- New: one file-local helper function (§3.2), not exported — `build.zig` has no public functions other than `build` itself.

**`tools/clean_test_db.py`**

- CLI surface unchanged: same `--include-fixtures` flag, same defaults, same exit-code contract (0 on success, non-zero on cleanup failure).
- `drop_orphaned_tenant_schemas()` keeps its name and its no-argument, no-return signature. Its internals move under the lock.
- New: one module-level helper for executing a multi-statement script in a single psql session (§4.2), alongside the existing `run_psql` / `run_psql_query`.
- Stdout/stderr contract unchanged, including the `Dropped N orphaned tenant schema(s).` line.

**`src/db/migrations.zig`** — read-only dependency. Layer 2 reuses its lock key expression; no edit.

---

## 7. Verification

The pass criterion is the **exit code**, never the presence or absence of any string in the output. Per CLAUDE.md, a gate satisfied by changing what it measures is not a fix.

### 7.1 Primary criterion (GH #477 acceptance)

```
zig build test-integration-tnt
```
must exit **0** on **5 consecutive runs**, against the shared `bpm_test` database, with `BPM_TEST_DB_URL` set. Baseline for comparison: the same command failed 5/5 before the fix. The implementer records all 5 exit codes.

### 7.2 Mechanism confirmation

Re-run with `log_statement='ddl'` on `db_test` and confirm that **no `DROP SCHEMA` for a tenant schema is interleaved with that schema's own migration statements**. This directly re-tests the smoking gun. Distinguish the two protocols as the diagnosis did: `psql -c` (the sweep) logs `LOG: statement:`, the migration runner logs `LOG: execute <unnamed>:`. Reset `log_statement` afterwards (`ALTER SYSTEM RESET` + `pg_reload_conf()`), as the diagnosis did.

### 7.3 Ordering confirmation

Confirm from the build output that `clean_test_db` runs **exactly once** per invocation and **before** any test binary produces output. The `Dropped N orphaned tenant schema(s).` line appearing once, ahead of test output, is the observable signal.

### 7.4 No-regression checks

- `zig build` exits 0 with no `error set` output (per the BACKEND-DEV checklist).
- `zig build test-integration` exits 0 — this exercises the umbrella + barrier path from finding (a), which the narrow tnt step does not cover.
- `git diff` touches **no** file under `tests/` and **not** `src/db/migrations.zig`. If either appears in the diff, the fix has drifted into weakening the detector.
- `python tools/lint_test_table_refs.py` still exits 0 (it gates `clean_test_db` in the graph).

### 7.5 Retest deferred from the diagnosis

The diagnosis flagged `tnt_backfill_export_cleanup_test.zig` failures observed only under artificial contention, deferring judgement. TEST-RUNNER (Step 5) re-checks this binary under the normal path once the fix lands, and files it as its own issue if it still fails. It is not in scope for Step 3.

### 7.6 Environment note

`python3` does not exist on this host; use `python`. `build.zig` already invokes `python` (lines 1178, 1184) and this design does not change that.

---

## 8. Dependencies

| Dependency | Nature | Status |
|---|---|---|
| `src/db/migrations.zig` line 31 lock key | Layer 2 reuses the exact key expression | Exists; unchanged by this design |
| `src/design/iss0129_migration_runner_advisory_lock.md` | Keyspace-disjointness rationale for that lock | Exists |
| ISS-0106 barrier (`build.zig` 1204–1251) | Must be preserved intact | Exists; §3.4 |
| ISS-0090 sweep rationale | Why the sweep exists; must keep working | Documented in the sweep's own docstring |
| `docs/anti-patterns.md` (build-graph sibling scheduling; re-check under lock) | Both entries directly govern this fix | Exists |
| Docker Compose `db_test` service | Both `run_psql` and the new script helper go through `docker-compose exec` | Unchanged |
| PostgreSQL `hashtext` / `pg_advisory_xact_lock` | Layer 2 primitive | Built-in |

---

## 9. Implementation notes for BACKEND-DEV (Step 3)

1. **Layer 1 first, then verify, then Layer 2.** Layer 1 alone should make §7.1 pass. Verifying in that order isolates each layer's contribution and gives a clean answer if something remains flaky.
2. **Attach the edge to run artifacts, not to aggregating steps** — §3.1. This is the single most important structural decision in the design; a per-step fix silently misses the 30 barrier-routed binaries.
3. **Do not take the advisory lock with a bare `run_psql` call** — §4.2. It releases when that psql process exits, protecting nothing.
4. **Enumerate under the lock, not before it** — §4.2.
5. **Do not touch any test file or `src/db/migrations.zig`** — §7.4.
6. **Ignore the C23505 duplicate-key line entirely** — §1.1. It is expected in both passing and failing runs.
7. Report finding (b) from §2.2 (`test-integration-iss0076` had no cleanup edge) in the handoff result as an incidental finding closed by this fix.
