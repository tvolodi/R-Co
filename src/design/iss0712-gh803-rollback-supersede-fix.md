# Module: iss0712-gh803-rollback-supersede-fix (ISS-0712 / GH-803)

Type E prose design — **production-code fix** for the PRM-08 rollback supersede
defect. **Single target file:** `src/definition/rollback.zig` (Step 5 supersede
UPDATE, lines 286–298). No migrations, no other source files. This artefact is
the WF-03 Step 2 fix design for the Step 1 (ISSUE-FIXER) diagnosis
(`docs/issue-reports/WF03-GH803-20260816-step-1-issue-fixer-INNER-REPORT.yaml`);
implementation is Step 3 (BACKEND-DEV). Companion runs: ISS-0711/GH-802 (test
fixture 23502, already merged) and ISS-0713/GH-804 (test seed tenant/def_id,
already merged).

## Classification

**Type E** (novel cross-cutting production fix). It is not Type A (no HTTP
route), B (no list page), C (no migration — explicitly out of scope), or D (no
React Flow node). The patch is a precise two-part edit to a single production
module whose error-handling semantics change observably (a silently-swallowed
42883 becomes a surfaced `RollbackError.TransactionFailed`), so it does not map
to a reusable Lego parameter file.

## Module purpose

`src/definition/rollback.zig` implements PRM-08: promotion rollback as a version
pointer move. `rollbackDefinitionVersion` re-points the active version of a
(tenant, process_key) pair to a previously-active target version, appends a
`DEFINITION_VERSION_ROLLED_BACK` event, and — Step 5 — supersedes any matching
`promotion_reviews` row (`status = 'superseded'`, `superseded_by = <event id>`)
and returns the superseded review's id in `RollbackResult.superseded_review_id`
(PRM-08 AC4).

The production supersede UPDATE compares the bound def id against
`promotion_reviews.def_id`, which migration `096_promotion_reviews.sql` declares
as `text NOT NULL`, but the SQL casts the parameter `$3::uuid`. PostgreSQL has no
implicit `text = uuid` operator, so the statement raises sqlstate **42883**
("operator does not exist: text = uuid") at execution time. The surrounding
`catch null` — written to tolerate the `promotion_reviews` table not existing
(PRM-04 is a later batch) — conflates "table missing" with "query failed" and
swallows *every* error, so `superseded_review_id` is **always** `null` and
PRM-08 AC4 is functionally broken in every environment where the table exists.
This design defines the exact Step 3 patch: (a) drop the `::uuid` cast on `$3`
so the predicate is `text = text`; (b) replace the bare `catch null` with a
SQLSTATE-42P01-distinguishing catch that tolerates only a genuinely missing table
and propagates every other query error.

## Scope and non-goals

- **In scope:** `src/definition/rollback.zig` Step 5 only — two lines (290 and
  295) plus the surrounding catch block shape. No other source file.
- **Out of scope — test fixture 23502 (GH-802):** already fixed by ISS-0711
  (helper now populates `requested_by` / `def_type` / `serialised_plan`). This
  run does not touch `tests/integration/prm-08-rollback-sandbox.test.zig`.
- **Out of scope — test seed tenant/def_id (GH-804):** already fixed by ISS-0713
  (seed now uses `DEFAULT_TENANT_ID` + the ACTIVE V2 `def_id`). Not this run.
- **Out of scope — any migration:** none is needed. The schema is correct; the
  bug is the cast in the query, not the column type. `migrations/096_promotion_reviews.sql`
  is read-only context.
- **Out of scope — any test file, any build target change (`build.zig`):**
  `test-integration-prm08` already exists (`build.zig:3147`); unchanged.

---

## The patch — two precise edits to Step 5

**Statement:** lines 286–295. **Verified against the actual source**
(2026-08-16): line 290 is `WHERE tenant_id = $2::uuid AND def_id = $3::uuid`,
line 295 is `) catch null; // table may not exist (PRM-04 is a later batch)`.

### Change A — drop `::uuid` on `$3` (line 290)

**Before:**

```zig
        \\UPDATE promotion_reviews SET status = 'superseded', superseded_by = $1::uuid
        \\WHERE tenant_id = $2::uuid AND def_id = $3::uuid
        \\  AND status IN ('applied', 'approved')
        \\RETURNING id::text
```

**After:**

```zig
        \\UPDATE promotion_reviews SET status = 'superseded', superseded_by = $1::uuid
        \\WHERE tenant_id = $2::uuid AND def_id = $3
        \\  AND status IN ('applied', 'approved')
        \\RETURNING id::text
```

**Rationale.** `$3 = current_active_id` is the `id::text` uuid string read in
Step 2, so it is already text at the binding site. With no cast PostgreSQL infers
`$3` as `text` (the column type of `promotion_reviews.def_id`) and resolves
`text = text` via the text equality operator. `superseded_by = $1::uuid` stays:
`$1 = event_id` is text bound against the `uuid` column `superseded_by`, and that
cast is correct. `tenant_id = $2::uuid` stays: `$2 = tenant_id` is text bound
against the `uuid` column `tenant_id`, and that cast is correct. Only `$3` was
wrong (text column, so the `::uuid` cast forced an impossible `text = uuid`
comparison).

### Change B — replace the bare `catch null` with a 42P01-distinguishing catch (line 295)

**Before:**

```zig
    ) catch null; // table may not exist (PRM-04 is a later batch)
```

**After** (canonical `lastSqlState()` pattern, mirroring PAR-01 in
`src/event_store/store.zig`):

```zig
    ) catch |err| blk: {
        // lastSqlState() returns a slice INTO the connection's mutable buffer;
        // copy before anything can overwrite it (canonical pattern: PAR-01 in
        // src/event_store/store.zig). PostgreSQL SQLSTATE is always exactly 5 chars.
        var sqlstate_buf: [5]u8 = undefined;
        const is_missing_table = if (conn.lastSqlState()) |s| blk2: {
            @memcpy(&sqlstate_buf, s);
            break :blk2 std.mem.eql(u8, &sqlstate_buf, "42P01");
        } else false;
        if (is_missing_table) break :blk null; // table may not exist (PRM-04 is a later batch)
        return switch (err) {
            pool_mod.PoolError.ExhaustedPool => RollbackError.PoolExhausted,
            else => RollbackError.TransactionFailed,
        };
    };
```

**Type correctness.** `conn.queryRow` returns `PoolError!?[]?[]u8`. The catch
block evaluates to `?[]?[]u8`: `break :blk null` coerces `null` to the optional
row type, and the `return switch (err)` exits the function with
`RollbackError!RollbackResult` — the same shape PAR-01 uses to return a store
error from its catch block. `std` and `pool_mod` are already imported
(`rollback.zig` lines 14–16).

**Copy-before-overwrite invariant.** `conn.lastSqlState()` (defined in
`src/db/pool.zig` line 563) returns a slice *into* the connection's mutable
`last_sqlstate` buffer, not an owned copy. The `@memcpy` into `sqlstate_buf`
happens inside the `if (conn.lastSqlState()) |s|` capture, before the `eql`
comparison and before any return — and there is **no intervening statement**
between the failed `queryRow` and the copy in this shape, so the SQLSTATE being
read is the failed UPDATE's, not some later query's. `std.mem.eql` against the
5-byte local buffer avoids comparing the live (mutable) connection slice.

---

## Error-handling semantics — why 42P01-only tolerance is correct

The original `catch null` had a legitimate purpose: `promotion_reviews` is
created by the PRM-04 batch, which may be applied *after* this rollback code
deploys, so the UPDATE must not hard-fail when the table does not yet exist.
The defect is that `catch null` cannot tell that case apart from a genuine query
failure. The fix narrows the tolerated condition to exactly one server error:

| SQLSTATE | Meaning | After fix |
|---|---|---|
| `42P01` | `undefined_table` — `promotion_reviews` genuinely absent (PRM-04 later batch) | `break :blk null` → no review to supersede, `superseded_review_id = null`, rollback proceeds (the original intent, preserved) |
| `42883` | `undefined_function` — "operator does not exist" (the current bug) | **eliminated by Change A** (`text = text` needs no operator); if it ever recurs it now surfaces as `TransactionFailed` → HTTP 500 |
| `22P02` | `invalid_text_representation` — a bound id is not a valid UUID | `TransactionFailed` → HTTP 500 (was: silently swallowed) |
| `23503` / any other server error | genuine data/constraint failure | `TransactionFailed` → HTTP 500 (was: silently swallowed) |
| `PoolError.ExhaustedPool` | pool exhausted | `RollbackError.PoolExhausted` → HTTP 503 (was: swallowed) |
| `lastSqlState()` returns `null` (defensive) | SQLSTATE unreadable | not tolerated → `TransactionFailed` → HTTP 500 |

**Why this is correct, not just better:** the only environment in which a
supersede query is *expected* to fail is one where the table does not exist, and
PostgreSQL reports exactly that with `42P01`. Every other failure means the
rollback transaction state is now inconsistent with the intent of PRM-08 AC4 —
the status pointer move and event append (Steps 3–4) may have succeeded while the
supersede did not — and silently reporting success (`superseded_review_id: null`,
HTTP 200) hides a data-integrity gap. Surfacing those as `TransactionFailed`
(HTTP 500) makes the inconsistency visible to the operator instead of silently
returning a misleading success payload. This is the same trade-off PAR-01 made
for partition-routing failures (`23514`) and is consistent with the function's
sibling queries, which all map `ExhaustedPool → PoolExhausted`,
`else → TransactionFailed` on error.

---

## Public interface

No signature changes. `rollbackDefinitionVersion` keeps its exact signature and
`RollbackError` set; only the *values* it can produce for a failing supersede
change:

```zig
// UNCHANGED signature (src/definition/rollback.zig:46)
pub fn rollbackDefinitionVersion(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    tenant_id: []const u8,
    process_key: []const u8,
    target_version: u32,
    actor_id: []const u8,
) RollbackError!RollbackResult;

// UNCHANGED RollbackResult (src/definition/rollback.zig:20)
//   .definition_id: []const u8   .version: u32
//   .rolled_back_from_version: u32
//   .superseded_review_id: ?[]const u8   // semantics repaired: now populated
//   .event_id: []const u8

// UNCHANGED RollbackError set (src/definition/rollback.zig:34)
//   Forbidden, VersionNeverActive, AlreadyActive, ProcessKeyNotFound,
//   PoolExhausted, TransactionFailed, OutOfMemory
// CHANGED behaviour only: the Step 5 supersede can now return
//   PoolExhausted / TransactionFailed where it previously returned success
//   with superseded_review_id = null on any error.
```

---

## Data flow diagram

```
  POST /api/v1/definitions/{process_key}/rollback
    handleRollback (src/api/routes/definition_rollback.zig:76)
      -> rollbackDefinitionVersion(allocator, pool, tenant_id, process_key, target_version, actor_id)
         conn = pool.acquire();  defer pool.release(conn)
         tenant context set from tenant_id -> search_path resolves per-tenant schema

         Step 1  perm check (user_roles x roles, PLATFORM_ADMIN)          [error -> Forbidden]
         Step 2  SELECT current ACTIVE id::text + target row              ($2 current_active_id)
         Step 3  UPDATE process_definitions SET status='SUPERSEDED'       (current -> SUPERSEDED)
         Step 4  UPDATE process_definitions SET status='ACTIVE'           (target -> ACTIVE)
         Step 4  INSERT events ... DEFINITION_VERSION_ROLLED_BACK         (event_id)
         Step 5  UPDATE promotion_reviews SET status='superseded',
                   superseded_by=$1::uuid, tenant_id=$2::uuid, def_id=$3  <- FIXED predicate (was $3::uuid)
                   RETURNING id::text
                 - table absent (42P01)  -> null, no supersession      [original intent preserved]
                 - any other failure     -> RollbackError (503/500)    [was: swallowed -> always null]
         result.superseded_review_id = RETURNING id or null
```

The UPDATE is unqualified, so it resolves through the connection's `search_path`
into the same per-tenant schema the fixture seeds (GH-804) and the same table
migration 096 creates.

---

## Error taxonomy

| Condition | Before fix | After fix |
|---|---|---|
| `promotion_reviews.def_id` TEXT vs `def_id = $3::uuid` (sqlstate 42883) | 42883 raised, swallowed by `catch null`; `superseded_review_id` always null; PRM-08 AC4 broken | cast dropped (`def_id = $3`, text = text); predicate matches; AC4 populates `superseded_review_id` |
| `promotion_reviews` table genuinely absent (PRM-04 later batch; sqlstate 42P01) | `null` (by accident — catch-null swallowed everything) | `null` (by design — 42P01 checked explicitly) |
| Any other server error on the supersede (`22P02`, `23503`, ...) | silently swallowed → HTTP 200 with `superseded_review_id: null` | `RollbackError.TransactionFailed` → HTTP 500 INTERNAL_ERROR |
| `PoolError.ExhaustedPool` on the supersede | silently swallowed → HTTP 200 | `RollbackError.PoolExhausted` → HTTP 503 SERVICE_UNAVAILABLE |
| `lastSqlState()` null (defensive) | swallowed | not tolerated → HTTP 500 |

---

## State transitions

- `promotion_reviews.status` `'applied'|'approved' → 'superseded'`: this is the
  transition Change A repairs. With the cast dropped, the UPDATE executes and
  flips every matching row's status; the `RETURNING id::text` of the first
  matching row becomes `RollbackResult.superseded_review_id`.
- Zero-row match (no review row, or no row in `('applied','approved')`): UPDATE
  succeeds with no rows; `superseded_review_id` remains `null` — unchanged
  semantics, still correct.
- `process_definitions` transitions (Steps 3–4: `ACTIVE → SUPERSEDED`,
  `SUPERSEDED/ACTIVE → ACTIVE`) are untouched by this fix.
- No new state machine is introduced; the fix only makes an existing transition
  reachable and makes its failures observable.

---

## Blast radius

**Production callers of `rollbackDefinitionVersion` / `RollbackError` — exactly
one:** `handleRollback` in `src/api/routes/definition_rollback.zig` (line 76),
mapping `RollbackError` to HTTP (lines 84–89):

| `RollbackError` | HTTP | Notes |
|---|---|---|
| `Forbidden` | 403 | unchanged |
| `VersionNeverActive` / `AlreadyActive` | 422 | unchanged |
| `ProcessKeyNotFound` | 404 | unchanged |
| `PoolExhausted` | 503 | now also reachable from Step 5 (was swallowed) |
| `TransactionFailed` / `OutOfMemory` | 500 | now also reachable from Step 5 (was swallowed) |

- **Observable behaviour change:** a genuine supersede failure that previously
  returned HTTP 200 with `superseded_review_id: null` now returns HTTP 500
  (`INTERNAL_ERROR`) or 503 (`SERVICE_UNAVAILABLE`). The `rollbackDefinitionVersion`
  return type is unchanged, so the handler needs no edit — its existing
  error-mapping switch already covers every `RollbackError` value.
- **Tests that exercise the supersede path:** `tests/integration/prm-08-rollback-sandbox.test.zig`
  (TC-PRM-08-01/02/03/04), driven by `test-integration-prm08` (`build.zig:3147`).
  TC-PRM-08-03's `'superseded'` assertion is the one that now passes once GH-802
  (fixture), GH-804 (seed), and this production cast fix are all present.
- **Why no migration is needed:** the defect is entirely in the query text —
  the `::uuid` cast on a TEXT column. The schema (migration 096) is already
  correct (`def_id text NOT NULL`, `superseded_by uuid`, `tenant_id uuid`). No
  DDL, no backfill, no data rewrite; nothing about `migrations/` changes.
- **No other module reads `superseded_review_id` or the supersede path:** the
  value is only surfaced in the HTTP response body and asserted in the prm-08
  integration test.

---

## Dependencies

**What `src/definition/rollback.zig` calls (unchanged):** `std`, `pool` module
(`pool_mod.Pool`, `PoolError`), `tenant_context`. The catch shape adds no new
imports — `std.mem.eql`/`@memcpy` come from `std`, and `conn.lastSqlState()` is
an existing method on the pooled connection (`src/db/pool.zig:563`).

**Canonical reference:** `src/event_store/store.zig` PAR-01 (lines ~795–815) —
the exact copy-then-compare `lastSqlState()` pattern this design mirrors.

**Schema dependency (read-only):** `migrations/096_promotion_reviews.sql`
(`def_id text NOT NULL`, `status` CHECK over the six values, partial unique index
`(tenant_id, plan_digest)` on `pending_review`/`approved`).

**Must NOT depend on:** any migration change; any test-file change (GH-802/GH-804
are separate, already-merged runs); `.vscode/run-zig-test-integration.ps1` or the
`zig-test-integration-cmd` task — they hardcode the stale `5433` port; this run's
test DB is on `5453`.

---

## Verification plan

```text
zig build
BPM_TEST_DB_URL=postgres://bpm:bpm@localhost:5453/bpm_test zig build test-integration-prm08
```

- `zig build` must exit 0 (the fix is runtime SQL + a catch shape; it must not
  break the compile).
- `test-integration-prm08` (single file `prm-08-rollback-sandbox.test.zig`,
  DB-only, no API/IDP required; DB on `:5453` is up) must be **4/4 green**
  (TC-PRM-08-01/02/03/04). The current unfixed tree is 3/4 (TC-PRM-08-03 fails on
  the `'superseded'` assertion because the supersede is swallowed); with the
  GH-802 fixture fix and GH-804 seed fix already merged on main **and** this
  production cast fix applied, TC-PRM-08-03's superseded assertion passes because
  the Step 5 supersede UPDATE now executes and sets `status='superseded'`,
  returning the seeded row's id as `superseded_review_id`.
- **Negative check:** the run's `[pool]` stderr must contain **no**
  `sqlstate=42883` line. If `sqlstate=42883` still appears, the cast was not
  dropped (or another `text = uuid` comparison remains) and the fix is not
  complete.
- The API and IDP are NOT required for this target; run the command directly with
  the explicit `:5453` URL (do not use the `.ps1` wrapper).

---

## Open questions

1. **`rollback.zig` doc vs code (pre-existing, out of scope):** the module
   doc comment claims the pointer move, event append, and supersession happen "in
   a single serialisable transaction", but the function does not call
   `conn.begin()` / COMMIT (no BEGIN/COMMIT present; `src/db/pool.zig:656`
   defines `begin` but nothing here uses it). The catch shape follows the
   function's existing per-query error handling (no explicit ROLLBACK on failure,
   connection released via `defer pool.release(conn)`), so this fix neither
   introduces nor worsens any transaction-boundary inconsistency — but the doc
   comment is stale and should be reconciled (REQ-ANALYST / DOC-UPDATER, not this
   run). Flagged for awareness, not a blocker.
2. **Multiple matching rows:** the partial unique index
   `promotion_reviews_plan_digest_active_uniq` constrains only
   `(tenant_id, plan_digest)` for `status IN ('pending_review','approved')`, so
   more than one `'applied'` row for the same `def_id` is possible; the UPDATE
   supersedes all matches and `RETURNING` yields the first. Pre-existing
   behaviour, unchanged by this fix — noted for Step 3, not a criterion.
3. **Prevention (Step 3 hygiene):** ISS-0712's prevention notes recommend
   running the `lint_sql_param_types.py` / `lint_sql_table_refs.py` linters over
   `src/definition/rollback.zig` after the fix so a `::uuid`-vs-TEXT comparison
   is caught statically next time. Not a requirement of this design, but
   recommended to ORCH for a follow-up.
