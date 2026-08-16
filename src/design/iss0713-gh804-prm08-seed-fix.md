# Module: iss0713-gh804-prm08-seed-fix (ISS-0713 / GH-804)

Type E prose design — **test-code-only** fix for the PRM-08 integration-test
fixture *seed* mismatch. **Single target file:**
`tests/integration/prm-08-rollback-sandbox.test.zig`. No production code, no
migrations. This artefact is the WF-03 Step 2 fix design for the Step 1
(ISSUE-FIXER) diagnosis; implementation is Step 3 (BACKEND-DEV / ISSUE-FIXER).

## Classification

**Type E** (novel cross-cutting test-fixture fix). It is not Type A (no HTTP
route), B (no list page), C (no migration), or D (no React Flow node). The patch
is a single test-helper seed correction in one file — the same class as the
already-validated ISS-0711/GH-802 fixture fix
(`src/design/iss0711-gh802-prm08-fixture-fix.md`) — and does not map to a
reusable Lego parameter file.

## Module purpose

`prm-08-rollback-sandbox.test.zig` exercises PRM-08 (rollback of a definition
version; SHOULD) against a real PostgreSQL test database. TC-PRM-08-03 (PRM-08
AC4 — `superseded_review_id` is populated when a matching `promotion_reviews`
row exists) seeds a review row via the fixture helper
`insertPromotionReviewsRow` (line 233) at its **single** call site (line 472).
The production supersede in `src/definition/rollback.zig` Step 5 (lines 286–298)
runs `UPDATE promotion_reviews SET status='superseded' ... WHERE
tenant_id = $2::uuid AND def_id = $3::uuid AND status IN ('applied','approved')`
with `$2 = DEFAULT_TENANT_ID` (the zero UUID — the tenant under which the test's
`process_definitions` are seeded and the tenant passed to
`rollbackDefinitionVersion`) and `$3 = current_active_id` = the ACTIVE V2
definition id (`def_id_v2`). The current fixture seeds the row with the test's
fresh random tenant UUID and the helper's hardcoded zero `def_id`, so the seeded
row can **never** satisfy the supersede WHERE clause: the row stays `'approved'`
and TC-PRM-08-03's `expectEqualStrings('superseded', ...)` assertion (line 504)
is unsatisfiable. This design defines the exact patch shape to make the seeded
row match the supersede predicate. **No production module needs a change for
this defect**: the seed bug is entirely in the test code's call-site arguments
and helper parameterisation.

## Scope and non-goals

- **In scope:** one test-helper + one call-site patch in
  `tests/integration/prm-08-rollback-sandbox.test.zig` — add a `def_id`
  parameter to `insertPromotionReviewsRow` (replacing the hardcoded zero-UUID
  literal with `$4::text`) and seed at the call site with
  `tenant_id = DEFAULT_TENANT_ID` and `def_id = def_id_v2`.
- **Out of scope — production code (GH-803):** the production supersede step in
  `src/definition/rollback.zig` Step 5 compares `def_id = $3::uuid` against the
  TEXT column `promotion_reviews.def_id`, producing sqlstate `42883` (operator
  does not exist: text = uuid), swallowed by `catch null` so
  `superseded_review_id` is always null. That is **ISS-0712 / GH-803** — a
  production change tracked in its own run. **This run does NOT touch
  `src/definition/rollback.zig`.**
- **Out of scope — any other production code:** `src/definition/rollback.zig`
  is the only production module implicated by the supersede path, and this run
  does not modify it or any other `src/` file. **Why no production change is
  required:** the production supersede predicate (`tenant_id = DEFAULT_TENANT_ID
  AND def_id = current_active_id`) is the *intended* contract; the fixture simply
  does not seed a row that satisfies it. Fixing the fixture seed to match the
  contract is the correct test-only repair and keeps production behaviour
  untouched.
- **Out of scope — the NOT NULL 23502 fixture gap (GH-802):** already fixed by
  ISS-0711/GH-802 (helper now populates `requested_by` / `def_type` /
  `serialised_plan`). This run builds on that already-applied change.
- **Out of scope:** any migration (`migrations/`), any build target change
  (`build.zig`), any other test file. The combined target
  `test-integration-prm08` already exists (`build.zig:3147`); it is not changed.
- **Do NOT use** `.vscode/run-zig-test-integration.ps1` or the
  `zig-test-integration-cmd` task — they hardcode the stale `5433` port. This
  run's test DB is on `5453`.

---

## The patch — fixture seed alignment (tenant_id + def_id)

**Helper:** `insertPromotionReviewsRow` (lines 233–258). **Call site:** line 472
inside TC-PRM-08-03 (AC4 path). **Verified:** the helper has exactly ONE call
site (grep: only line 472), so a dedicated AC4 helper would add no value —
parameter threading keeps one source of truth (Option A in the Step 1 fix spec).

### Symptom

With the GH-802 (23502) helper fix applied and GH-803 NOT yet applied, running
`BPM_TEST_DB_URL=postgres://bpm:bpm@localhost:5453/bpm_test zig build
test-integration-prm08` reproduces: 3 pass, 1 fail; TC-PRM-08-03 fails at line
504 `expectEqualStrings('superseded', superseded)` — expected `'superseded'`,
found `'approved'`. The seeded row is never superseded because the supersede
WHERE cannot match it. Step 1 reproduced exactly this (2026-08-16, current tree).

### Root cause

The fixture seeds the `promotion_reviews` row under the wrong tenant and with the
wrong `def_id` relative to what the production supersede query matches:

- **tenant_id:** the call site passes the test's fresh random `tenant_id`
  (randomUuidStr), but the definitions and the rollback run under
  `DEFAULT_TENANT_ID` (zero UUID), so the supersede `tenant_id = $2` never
  matches.
- **def_id:** the helper hardcodes
  `'00000000-0000-0000-0000-000000000000'::uuid`, but the supersede matches
  `def_id = current_active_id` = `def_id_v2` (the ACTIVE V2 definition being
  rolled back from).

The fixture `status` `'approved'` is already inside the predicate set
`IN ('applied','approved')`, so no status change is needed — only tenant_id and
def_id.

### Patch shape — helper (add def_id parameter)

**Before** (lines 233–258):

```zig
fn insertPromotionReviewsRow(
    pool: *Pool,
    tenant_id: []const u8,
    review_id: []const u8,
    requested_by: []const u8,          // NEW — feeds NOT NULL requested_by
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO promotion_reviews
        \\    (id, tenant_id, status, def_id, plan_digest, created_at,
        \\     requested_by, def_type, serialised_plan)
        \\VALUES ($1::uuid, $2::uuid, 'approved',
        \\        '00000000-0000-0000-0000-000000000000'::uuid,
        \\        'prm08-test-plan-digest', NOW(),
        \\        $3::uuid, 'rollback', 'prm08-test-serialised-plan')
        \\ON CONFLICT (id) DO UPDATE SET status = 'approved'
    ,
        &[_][]const u8{ review_id, tenant_id, requested_by },
    );
}
```

**After** (add a 5th parameter `def_id: []const u8`; replace the hardcoded zero
UUID literal with `$4::text`; extend the params array; everything else unchanged,
including the `ON CONFLICT` clause and the `'approved'` status):

```zig
fn insertPromotionReviewsRow(
    pool: *Pool,
    tenant_id: []const u8,
    review_id: []const u8,
    requested_by: []const u8,          // existing — feeds NOT NULL requested_by
    def_id: []const u8,                // NEW — feeds promotion_reviews.def_id
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO promotion_reviews
        \\    (id, tenant_id, status, def_id, plan_digest, created_at,
        \\     requested_by, def_type, serialised_plan)
        \\VALUES ($1::uuid, $2::uuid, 'approved',
        \\        $4::text,
        \\        'prm08-test-plan-digest', NOW(),
        \\        $3::uuid, 'rollback', 'prm08-test-serialised-plan')
        \\ON CONFLICT (id) DO UPDATE SET status = 'approved'
    ,
        &[_][]const u8{ review_id, tenant_id, requested_by, def_id },
    );
}
```

Binding `$4::text` is precise: `promotion_reviews.def_id` is TEXT and `def_id_v2`
is already a UUID string, so `::text` avoids relying on an implicit uuid→text
assignment cast (the same class of implicit-cast ambiguity that produced the
GH-803 42883).

### Patch shape — call site (DEFAULT_TENANT_ID + def_id_v2)

**Before** (lines 467–473, inside TC-PRM-08-03, AC4 path):

```zig
    const requested_by = try randomUuidStr(alloc);
    defer alloc.free(requested_by);
    const has_pr = try promotionReviewsTableExists(&pool);

    if (has_pr) {
        try insertPromotionReviewsRow(&pool, tenant_id, review_id, requested_by);
    }
```

**After** (seed the row under the default tenant and the ACTIVE V2 definition id
— the exact values the production supersede predicates on):

```zig
    const requested_by = try randomUuidStr(alloc);
    defer alloc.free(requested_by);
    const has_pr = try promotionReviewsTableExists(&pool);

    if (has_pr) {
        try insertPromotionReviewsRow(&pool, DEFAULT_TENANT_ID, review_id, requested_by, def_id_v2);
    }
```

`def_id_v2` is the local (line 453) id of the ACTIVE V2 definition `'2'` seeded
at line 464 under `DEFAULT_TENANT_ID` — it equals the production
`current_active_id` that Step 5 supersedes FROM when rolling back to version 1.
`def_id_v1` (the SUPERSEDED V1) is NOT used for the supersede predicate.

---

## Public interface

Only test-helper changes; no production interface changes.

```zig
// CHANGED — helper signature (tests/integration/prm-08-rollback-sandbox.test.zig:233)
fn insertPromotionReviewsRow(
    pool: *Pool,
    tenant_id: []const u8,
    review_id: []const u8,
    requested_by: []const u8,          // existing — NOT NULL promotion_reviews.requested_by
    def_id: []const u8,                // NEW — promotion_reviews.def_id (TEXT)
) !void;
// Contract: inserts/upserts a promotion_reviews row in the connection's current
// schema with all NOT NULL columns populated and def_id taken from the caller,
// so callers can seed a row that matches the production supersede predicate.

// UNCHANGED caller now supplies the correct tenant and def_id:
//   TC-PRM-08-03 line 472 -> insertPromotionReviewsRow(&pool, DEFAULT_TENANT_ID,
//                             review_id, requested_by, def_id_v2)
```

No new public functions are required; `DEFAULT_TENANT_ID` (line 37) and
`randomUuidStr` already exist in the file.

---

## Data flow diagram

```
       makePool() sets tenant context = zero UUID
       -> per-connection search_path = tenant_default, ... (migration 096 is
          tenant_only: promotion_reviews lives only in per-tenant schemas)

  TC-PRM-08-03 (AC4)
    insertPromotionReviewsRow(&pool, DEFAULT_TENANT_ID, review_id, requested_by, def_id_v2)
        --unqualified INSERT--> promotion_reviews [tenant_default]
        tenant_id = zero, def_id = def_id_v2 (was: random tenant + zero def_id)

    rollback.rollbackDefinitionVersion(..., DEFAULT_TENANT_ID, ...)
        --supersede UPDATE-->  promotion_reviews [tenant_default]
        WHERE tenant_id = zero AND def_id = current_active_id (= def_id_v2)
        => now MATCHES the seeded row (was: matched nothing)
        (residual sqlstate 42883 = GH-803, production cast, out of scope here)
```

The helper's INSERT is unqualified, so it resolves through the test connection's
`search_path` into the same schema the production supersede UPDATE targets.
Cleanup (`dropTenantFixtures`) already deletes `promotion_reviews` rows where
`tenant_id = DEFAULT_TENANT_ID`, so seeding under the default tenant is
consistent with cleanup and additionally fixes a latent leak — the current
random-tenant fixture row would never be deleted.

---

## Error taxonomy

| Condition | Before fix | After fix |
|---|---|---|
| TC-PRM-08-03 seeds row that can never match supersede WHERE (`tenant_id` random, `def_id` zero) → `'superseded'` assertion fails | TC-PRM-08-03 fails at line 504 (expected `'superseded'`, found `'approved'`) | Fixture row now matches the predicate (tenant = zero, def_id = def_id_v2) |
| Production supersede `def_id = $3::uuid` vs TEXT column (sqlstate 42883) | **OUT OF SCOPE** — ISS-0712 / GH-803 (production change, separate run) | unchanged here |
| `promotion_reviews` NOT NULL columns (sqlstate 23502) | already fixed by GH-802 | unchanged here (GH-802 helper retained) |
| `BPM_TEST_DB_URL` missing | `error.MissingTestDatabaseUrl` (pre-existing, DIRECTIVE T-1) | unchanged |
| Rollback path errors under `has_pr` | TC-PRM-08-03 rethrows under `has_pr` | unchanged semantics — errors surfaced, not masked |

No new error paths are introduced; the fix makes the fixture seed consistent with
the production predicate.

---

## State transitions

- `promotion_reviews.status`: unchanged helper semantics — still upserts
  `'approved'` via `ON CONFLICT (id) DO UPDATE SET status = 'approved'` (this
  clause is not part of the fix and is preserved verbatim). The fix only changes
  which `tenant_id` / `def_id` the seeded row carries, so the production
  supersede UPDATE can transition it `'approved' → 'superseded'`.
- The production `status` transitions (`pending_review → approved →
  applied/superseded/...`) are unchanged and are not part of this run.
- No production state machine is touched.

---

## Dependencies

**What this module (the test file) calls:**
- `helpers.zig` (shared harness import), `bpm` internals: `pool.Pool` /
  `PoolConfig`, `api_tenant_context.set`, `definition_rollback`
  (`rollbackDefinitionVersion`, `RollbackError`), `definition_rollback_routes`
  (`handleRollback`), `api_auth` (`AuthContext`, `Role`).
- Test DB schema: migration `096_promotion_reviews.sql` (the source of
  `promotion_reviews.def_id` TEXT and the NOT NULL columns).

**Must NOT depend on:**
- Any production code change (`src/definition/rollback.zig` is GH-803, separate
  run; the seed fix is test-code-only and independent of GH-803's code).
- Any migration change (none is required; the schema already defines the columns).
- The `.vscode/run-zig-test-integration.ps1` / `zig-test-integration-cmd` task —
  they hardcode the stale `5433` port; the test DB for this run is on `5453`.

---

## Verification plan

```text
BPM_TEST_DB_URL=postgres://bpm:bpm@localhost:5453/bpm_test zig build test-integration-prm08
```

- The target `test-integration-prm08` exists at `build.zig:3147` and runs the
  single file `tests/integration/prm-08-rollback-sandbox.test.zig` in isolation.
- The test DB on `:5453` is confirmed UP for this workspace. The API and IDP are
  NOT required — all four tests in this file are DB-only.
- **What this run verifies:** the fixture seed now satisfies the supersede
  predicate — the row-level contract `tenant_id = DEFAULT_TENANT_ID AND
  def_id = def_id_v2` is correct, so the seeded row *can* be superseded once the
  supersede UPDATE executes without error.
- **GH-803 dependency (explicit):** full 4/4 green ALSO requires the GH-803 /
  ISS-0712 production fix (remove the `::uuid` cast on `def_id = $3` in
  `src/definition/rollback.zig` Step 5 to eliminate sqlstate 42883). With
  GH-804 alone, the supersede UPDATE still errors 42883 (swallowed by `catch
  null`), `superseded_review_id` stays null, and the seeded row remains
  `'approved'` — so TC-PRM-08-03's `'superseded'` assertion can still fail.
  **Any remaining TC-PRM-08-03 failure after this fix is the GH-803 42883 and is
  OUT OF SCOPE for this run's verdict.** GH-804 (fixture seed) is independent
  test-code; GH-803 (production predicate cast) is the companion production fix;
  both are required for the assertion and for 4/4 green.
- Step 3 must run the command directly with the explicit `:5453` URL and must
  NOT rely on `.vscode/run-zig-test-integration.ps1`.

---

## Open questions

1. **Negative control (optional hardening):** Step 1 noted a second
   `promotion_reviews` row with a non-matching `def_id` (e.g. `def_id_v1`)
   could be asserted to remain `'approved'`, proving the supersede predicate's
   selectivity. This aligns with ISS-0713's prevention notes but is NOT an
   acceptance criterion; left to Step 3 discretion. No REQ-ANALYST clarification
   needed — a test-design nicety, not a requirement.
2. **`ON CONFLICT` clause:** the prm-08 helper hardcodes
   `ON CONFLICT (id) DO UPDATE SET status = 'approved'`. This patch preserves it
   verbatim — a minimal diff. If Step 3 prefers the GH-802 mirror's
   `EXCLUDED.status` form, that is a safe, equivalent improvement but not an
   acceptance criterion.
3. **GH-803 sequencing:** this run's acceptance is that the seed fix is correct
   and any remaining TC-PRM-08-03 failure is the GH-803 42883. ORCH must
   sequence GH-803 (production 42883 cast fix) after (or in parallel with) this
   run; full 4/4 green is only achievable once both are merged. GH-803 is
   explicitly out of scope here.
