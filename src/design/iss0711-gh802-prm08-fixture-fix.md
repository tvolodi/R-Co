# Module: iss0711-gh802-prm08-fixture-fix (ISS-0711 / GH-802)

Type E prose design — **test-code-only** fix for the PRM-08 integration-test
fixture defect. **Single target file:**
`tests/integration/prm-08-rollback-sandbox.test.zig`. No production code, no
migrations. This artefact is the WF-03 Step 2 fix design for the Step 1
(ISSUE-FIXER) diagnosis; implementation is Step 3 (BACKEND-DEV / ISSUE-FIXER).

## Classification

**Type E** (novel cross-cutting test-fixture fix). It is not Type A (no HTTP
route), B (no list page), C (no migration), or D (no React Flow node). The patch
is a single test-helper fixture correction in one file — the same class as the
already-validated ISS-0708/GH-793 Cluster A fix — and does not map to a reusable
Lego parameter file.

## Module purpose

`prm-08-rollback-sandbox.test.zig` exercises PRM-08 (rollback of a definition
version; SHOULD) against a real PostgreSQL test database. Its fixture helper
`insertPromotionReviewsRow` (lines 233–258) inserts a `promotion_reviews` row
that omits the three NOT NULL columns introduced by migration
`096_promotion_reviews.sql` — `requested_by uuid NOT NULL`,
`def_type text NOT NULL`, `serialised_plan text NOT NULL` — so the fixture INSERT
fails with sqlstate `23502` (not_null_violation) whenever a test seeds a review
row against the current migration set. The sole seeding path is TC-PRM-08-03
(AC4 — superseded_review_id, conditional on the table existing), which calls the
helper at line 466. This design defines the exact patch shape for that helper and
its single call site, mirroring the already-validated ISS-0708/GH-793 Cluster A
patch in `tests/integration/prm-06-07-promotion-assertion.test.zig`. **No
production module needs a change for this defect**: the fixture bug is entirely in
the test code's INSERT statement.

## Scope and non-goals

- **In scope:** one test-helper patch in
  `tests/integration/prm-08-rollback-sandbox.test.zig` (helper lines 233–258 plus
  the single call site at line 466), adding `requested_by` to the helper signature
  and the three NOT NULL columns to the INSERT.
- **Out of scope — production code (GH-803):** the production supersede step in
  `src/definition/rollback.zig` compares `def_id = $3::uuid` against the TEXT
  column `promotion_reviews.def_id`, producing sqlstate `42883` (operator does not
  exist: text = uuid), swallowed by `catch null` so `superseded_review_id` is
  always null. That is **ISS-0712 / GH-803** — a production change tracked in its
  own run. **This run does NOT touch `src/definition/rollback.zig`.**
- **Out of scope — test seed-logic (GH-804):** TC-PRM-08-03 seeds its
  `promotion_reviews` row under a random tenant UUID + zero `def_id` (hardcoded in
  the helper), which can never match the supersede WHERE
  (`tenant_id=DEFAULT_TENANT_ID AND def_id=<active V2 id>`), so the `'superseded'`
  assertion fails after the 23502/42883 fixes. That is **ISS-0713 / GH-804** — a
  fixture seed-logic change tracked in its own run. **This run does NOT change the
  test's seed tenant/def_id logic.**
- **Out of scope:** any migration (`migrations/`), any build target change
  (`build.zig`), any other test file. The combined target
  `test-integration-prm08` already exists (`build.zig:3147`); it is not changed.
- **Do NOT use** `.vscode/run-zig-test-integration.ps1` or the
  `zig-test-integration-cmd` task — they hardcode the stale `5433` port. This
  run's test DB is on `5453`.

---

## The patch — Cluster A mirror (sqlstate 23502, NOT NULL columns)

**Helper:** `insertPromotionReviewsRow` (lines 233–258). **Call site:** line 466
inside TC-PRM-08-03. **Mirror reference:** the identical fix already shipped for
ISS-0708/GH-793 in `tests/integration/prm-06-07-promotion-assertion.test.zig`
(helper lines 99–118, call site line 489).

### Symptom

`BPM_TEST_DB_URL=postgres://bpm:bpm@localhost:5453/bpm_test zig build
test-integration-prm08` fails TC-PRM-08-03 with sqlstate `23502`
(not_null_violation) on the helper's INSERT (line 240, called from line 466). Step
1 reproduced exactly this: `sqlstate=23502 params=2 sql=INSERT INTO
promotion_reviews (id, tenant_id, status, def_id, plan_digest, created_at) ...`.

### Root cause

The helper was written before `096_promotion_reviews.sql` added the NOT NULL
columns. The INSERT list
`(id, tenant_id, status, def_id, plan_digest, created_at)` predates
`requested_by` / `def_type` / `serialised_plan`. The `def_id` literal
`'00000000-...'::uuid` still works because PostgreSQL applies an implicit
uuid→text assignment cast (`promotion_reviews.def_id` is `text`).

### Patch shape — helper

**Before** (lines 233–258):

```zig
fn insertPromotionReviewsRow(
    pool: *Pool,
    tenant_id: []const u8,
    review_id: []const u8,
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO promotion_reviews (id, tenant_id, status, def_id, plan_digest, created_at)
        \\VALUES ($1::uuid, $2::uuid, 'approved',
        \\        '00000000-0000-0000-0000-000000000000'::uuid,
        \\        'prm08-test-plan-digest', NOW())
        \\ON CONFLICT (id) DO UPDATE SET status = 'approved'
    ,
        &[_][]const u8{ review_id, tenant_id },
    );
}
```

**After** (add `requested_by` param + the three NOT NULL columns; everything else
unchanged, including the `ON CONFLICT` clause):

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

`requested_by` is caller-supplied so each test can pass a fresh random UUID (per
the file's isolation convention — no hardcoded UUID literals). `def_type` /
`serialised_plan` use fixture sentinels (consistent with the existing
`def_id` / `plan_digest` sentinels; migration 096 imposes no CHECK on either, so
any non-null text is valid).

### Patch shape — call site

**Before** (line 466, inside TC-PRM-08-03, AC4 path):

```zig
    const has_pr = try promotionReviewsTableExists(&pool);

    if (has_pr) {
        try insertPromotionReviewsRow(&pool, tenant_id, review_id);
    }
```

**After** (generate a fresh `requested_by` — the file already defines
`randomUuidStr` at line ~50, so no new helper is needed):

```zig
    const requested_by = try randomUuidStr(alloc);
    defer alloc.free(requested_by);
    const has_pr = try promotionReviewsTableExists(&pool);

    if (has_pr) {
        try insertPromotionReviewsRow(&pool, tenant_id, review_id, requested_by);
    }
```

This is the **only** call site (verified by search), so the signature change
ripples to exactly this one site.

---

## Public interface

Only test-helper changes; no production interface changes.

```zig
// CHANGED — helper signature (tests/integration/prm-08-rollback-sandbox.test.zig:233)
fn insertPromotionReviewsRow(
    pool: *Pool,
    tenant_id: []const u8,
    review_id: []const u8,
    requested_by: []const u8,          // NEW — NOT NULL promotion_reviews.requested_by
) !void;
// Contract: inserts/upserts a promotion_reviews row in the connection's current
// schema with all NOT NULL columns populated (requested_by from the caller,
// def_type/serialised_plan from fixture sentinels, status 'approved' as today).

// UNCHANGED caller now supplies the new argument:
//   TC-PRM-08-03 line 466 -> pass a fresh randomUuidStr(alloc)
```

No new public functions are required; `randomUuidStr` already exists in the file.

---

## Data flow diagram

```
       makePool() sets tenant context = zero UUID
       -> per-connection search_path = tenant_default, public
       (migration 096 is tenant_only: promotion_reviews lives only in
        per-tenant schemas, never public)

  TC-PRM-08-03 (AC4)
    insertPromotionReviewsRow(&pool, tenant_id, review_id, requested_by)
        --unqualified INSERT--> promotion_reviews [tenant_default]
        requested_by/def_type/serialised_plan now populated (was: 23502)

    rollback.rollbackDefinitionVersion(...)
        --supersede UPDATE-->  promotion_reviews [tenant_default]
        (WHERE tenant_id + def_id; residual 42883 = GH-803, seed mismatch = GH-804)
```

The helper's INSERT is unqualified, so it resolves through the test connection's
`search_path` into the same `tenant_default` schema the production supersede
UPDATE targets — consistent with how every other fixture INSERT in this file
behaves. Cleanup (`dropTenantFixtures`) is unaffected; it already deletes
`promotion_reviews` rows for the default tenant.

---

## Error taxonomy

| Condition | Before fix | After fix |
|---|---|---|
| `promotion_reviews.requested_by` NOT NULL (sqlstate 23502) | TC-PRM-08-03 fails at helper line 240 | Helper populates `requested_by` (fresh UUID) |
| `promotion_reviews.def_type` / `serialised_plan` NOT NULL (sqlstate 23502) | latent (same INSERT) | Helper populates both sentinels |
| Production supersede `def_id = $3::uuid` vs TEXT column (sqlstate 42883) | **OUT OF SCOPE** — ISS-0712 / GH-803 (production change, separate run) | unchanged here |
| TC-PRM-08-03 seed tenant/def_id cannot match supersede WHERE → `'superseded'` assertion fails | **OUT OF SCOPE** — ISS-0713 / GH-804 (seed-logic change, separate run) | unchanged here |
| `BPM_TEST_DB_URL` missing | `error.MissingTestDatabaseUrl` (pre-existing, DIRECTIVE T-1) | unchanged |

No new error paths are introduced; the fix removes the 23502 failure mode from
the test fixture.

---

## State transitions

- `promotion_reviews.status`: unchanged semantics — the helper still upserts
  `'approved'` via `ON CONFLICT (id) DO UPDATE SET status = 'approved'` (this
  clause is not part of the fix and is preserved verbatim). The fix only
  additionally populates the previously-missing NOT NULL columns.
- The production `status` transitions (`pending_review → approved →
  applied/superseded/...`) are unchanged and are not part of this run.
- No production state machine is touched.

---

## Dependencies

**What this module (the test file) calls:**
- `helpers.zig` (`randomUuidStr`-style helpers are local; the file imports
  `helpers.zig` for the shared harness), `bpm` internals: `pool.Pool` /
  `PoolConfig`, `api_tenant_context.set`, `definition_rollback`
  (`rollbackDefinitionVersion`, `RollbackError`), `definition_rollback_routes`
  (`handleRollback`), `api_auth` (`AuthContext`, `Role`).
- Test DB schema: migration `096_promotion_reviews.sql` (the source of the NOT
  NULL columns this patch feeds).

**Must NOT depend on:**
- Any production code change (`src/definition/rollback.zig` is GH-803, separate
  run).
- Any migration change (none is required; the schema already defines the columns).
- Any change to the test's seed tenant/def_id logic (that is GH-804, separate
  run).
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
- **Expected after the fix:** the sqlstate `23502` failure at helper line 240
  (observed by Step 1 as `3 pass, 1 fail (TC-PRM-08-03)`) is **gone**. The fixture
  INSERT now supplies all NOT NULL columns.
- **Residual TC-PRM-08-03 failures are OUT OF SCOPE for this run's verdict:**
  - the `superseded_review_id`/`'superseded'` path still fails while
    `src/definition/rollback.zig` carries the `42883` cast bug (ISS-0712 / GH-803,
    production change in a separate run);
  - the `'superseded'` assertion still fails while TC-PRM-08-03 seeds a row that
    cannot match the supersede WHERE (ISS-0713 / GH-804, seed-logic change in a
    separate run).
  The GH-802 acceptance criterion is that the 23502 fixture failure is eliminated
  with no production/migration change; GH-803 and GH-804 are the residual causes of
  any remaining TC-PRM-08-03 assertion failure.
- Step 3 must run the command directly with the explicit `:5453` URL and must NOT
  rely on `.vscode/run-zig-test-integration.ps1`.

---

## Open questions

1. **Sentinel values:** `def_type='rollback'` and
   `serialised_plan='prm08-test-serialised-plan'` are arbitrary fixture strings
   (migration 096 imposes no CHECK on either). The mirror used
   `def_type='assertion_rerun'` for the assertion-rerun path; `'rollback'` is the
   path-descriptive analogue here. Nothing asserts on these columns in PRM-08, so
   any non-null text is acceptable. No REQ-ANALYST clarification needed — a test
   fixture convention, noted for the implementer.
2. **`ON CONFLICT` clause:** the prm-08 helper hardcodes
   `ON CONFLICT (id) DO UPDATE SET status = 'approved'` (the mirror uses
   `status = EXCLUDED.status`). This patch preserves the prm-08 helper's existing
   clause verbatim — a minimal diff. If Step 3 prefers the mirror's
   `EXCLUDED.status` form, it is a safe, equivalent improvement but not an
   acceptance criterion.
3. **GH-803/GH-804 sequencing:** the GH-802 acceptance criterion
   ('test-integration-prm08 passes — no sqlstate 23502') is satisfied by this
   patch alone at the fixture level, but the *full* TC-PRM-08-03 `'superseded'`
   assertion will only pass once GH-803 (production 42883) and GH-804 (seed
   tenant/def_id) are also fixed. ORCH should sequence those two runs; they are
   explicitly out of scope here.
