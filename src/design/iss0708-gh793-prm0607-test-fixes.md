# Module: iss0708-gh793-prm0607-test-fixes (ISS-0708 / GH-793)

Type E prose design — **test-code-only** fix for three PRM-06/07 integration-test
failures. **Single target file:** `tests/integration/prm-06-07-promotion-assertion.test.zig`.
No production code, no migrations. This artefact is the Step 2 fix design for the
Step 1 (ISSUE-FIXER) diagnosis; implementation is Step 3 (BACKEND-DEV / ISSUE-FIXER).

## Classification

**Type E** (novel cross-cutting test-setup fix). It is not Type A (no HTTP route),
B (no list page), C (no migration), or D (no React Flow node). The three patches are
independent test-fixture/setup corrections in one file; none maps to a reusable Lego
parameter file.

## Module purpose

`prm-06-07-promotion-assertion.test.zig` exercises PRM-06 (idempotent pre-promotion
assertion re-run) and PRM-07 (sandbox teardown on every exit path) against a real
PostgreSQL test database. Three of its nine tests fail against the current schema
because their fixtures pre-date two schema facts: (1) migration `096_promotion_reviews.sql`
declares `requested_by uuid NOT NULL`, `def_type text NOT NULL`, and
`serialised_plan text NOT NULL`, but the shared fixture helper `insertPromotionReviewsRow`
omits all three columns (sqlstate 23502 — Cluster A); (2) `promotion_assertion_runs`
may carry a conditional FK `promotion_assertion_runs_review_fk` onto `promotion_reviews`
(migration `1156_prm06_promotion_assertion_runs.sql`), but TC-PRM-07-03 never seeds a
parent review row (sqlstate 23503 in environments where the FK exists — Cluster B);
and (3) TC-PRM-07-01 manually replicates the `recordTeardownFailure` UPDATE but leaves
it schema-unqualified, so it targets `tenant_default` (0 rows) while the fixture row
was inserted into `public` (assertion mismatch — Cluster C). This design defines the
exact patch shapes for all three clusters in the single target file. **No production
module needs a change**: the production `recordTeardownFailure`
(`src/definition/assertion_rerun.zig`) and `handleGetPromotion`
(`src/api/routes/promotion_read.zig`) both run under a real tenant `search_path` and
are correct; the defects are entirely in the test code's fixture/setup.

## Scope and non-goals

- **In scope:** three test-setup patches, all in
  `tests/integration/prm-06-07-promotion-assertion.test.zig`.
- **Out of scope:** production code (`src/`), migrations, build.zig. The combined
  test target already exists (`test-integration-prm06-07`); it is not changed.
- **Out of scope (tracked separately):** the same `insertPromotionReviewsRow`
  NOT-NULL omission is latent in `tests/integration/prm-08-rollback-sandbox.test.zig`
  (lines 233–258). It is a MINOR follow-up, not part of this run.

---

## Cluster A — TC-PRM-06-03 (sqlstate 23502, `requested_by` NOT NULL)

**Test:** `test "TC-PRM-06-03: applyPromotionAssertionRerun returns SandboxUnavailable ..."`
(line 455). **Helper:** `insertPromotionReviewsRow` (lines 99–113). **Call site:** line 482.

### Symptom

`zig build test-integration-prm06-07` fails `TC-PRM-06-03` with sqlstate `23502`
(not_null_violation): `insertPromotionReviewsRow` inserts a `promotion_reviews` row
without the three NOT NULL columns `requested_by`, `def_type`, `serialised_plan`
introduced in migration `096_promotion_reviews.sql`. (The issue body's "migration
1144" citation is wrong — `096_promotion_reviews.sql` is the real source.)

### Root cause

The helper was written before `096_promotion_reviews.sql` added the NOT NULL columns.
The INSERT list `(id, tenant_id, status, def_id, plan_digest, created_at)` predates
`requested_by`/`def_type`/`serialised_plan`. The `def_id` literal
`'00000000-...'::uuid` still works because PostgreSQL applies an implicit
uuid→text assignment cast.

### Patch shape

**Before** (helper, lines 99–113):

```zig
fn insertPromotionReviewsRow(
    pool: *Pool,
    tenant_id: []const u8,
    review_id: []const u8,
    status: []const u8,
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO promotion_reviews (id, tenant_id, status, def_id, plan_digest, created_at)
        \\VALUES ($1::uuid, $2::uuid, $3, '00000000-0000-0000-0000-000000000000'::uuid,
        \\        'prm06-test-plan-digest', NOW())
        \\ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status
    ,
        &[_][]const u8{ review_id, tenant_id, status },
    );
}
```

**After** (helper — add `requested_by` param + three columns):

```zig
fn insertPromotionReviewsRow(
    pool: *Pool,
    tenant_id: []const u8,
    review_id: []const u8,
    status: []const u8,
    requested_by: []const u8,          // NEW — feeds NOT NULL requested_by
) !void {
    const conn = try pool.acquire();
    defer pool.release(conn);
    try conn.exec(
        \\INSERT INTO promotion_reviews
        \\    (id, tenant_id, status, def_id, plan_digest, created_at,
        \\     requested_by, def_type, serialised_plan)
        \\VALUES ($1::uuid, $2::uuid, $3,
        \\        '00000000-0000-0000-0000-000000000000'::uuid,
        \\        'prm06-test-plan-digest', NOW(),
        \\        $4::uuid, 'assertion_rerun', 'prm06-test-serialised-plan')
        \\ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status
    ,
        &[_][]const u8{ review_id, tenant_id, status, requested_by },
    );
}
```

`def_type` / `serialised_plan` use sentinel fixture literals (consistent with the
existing `def_id` / `plan_digest` sentinels); `requested_by` is caller-supplied so the
value can be a fresh random UUID per test (no hardcoded UUID literals, per the file's
isolation convention).

**Before** (call site, line 482):

```zig
    const has_pr = try promotionReviewsTableExists(&pool);
    if (has_pr) {
        try insertPromotionReviewsRow(&pool, tenant_id, review_id, "approved");
```

**After** (call site — generate a fresh `requested_by`):

```zig
    const requested_by = try randomUuidStr(alloc);
    defer alloc.free(requested_by);
    const has_pr = try promotionReviewsTableExists(&pool);
    if (has_pr) {
        try insertPromotionReviewsRow(&pool, tenant_id, review_id, "approved", requested_by);
```

This is the **only** existing call site (verified by search), so the signature change
ripples to exactly this one site plus the new TC-PRM-07-03 site added in Cluster B.

---

## Cluster C — TC-PRM-07-01 (expected `teardown_failed`, found `passed`)

**Test:** `test "TC-PRM-07-01: a successful assertion run whose sandbox release fails ..."`
(line 643). **Manual UPDATE:** lines 694–702.

### Symptom

`TC-PRM-07-01` fails the assertion `status == "teardown_failed"` because the manual
UPDATE that simulates `recordTeardownFailure` matches **0 rows**; the row remains
`'passed'`.

### Root cause (schema-qualification mismatch — refined by Step 1)

`makePool` sets the tenant context to the zero UUID
`00000000-0000-0000-0000-000000000000`, so every connection's `search_path` becomes
`tenant_default, public` (per `pool.zig` `schemaNameForTenant`). The test inserts its
fixture row into **`public`** (qualified `INSERT INTO public.promotion_assertion_runs`),
but the manual teardown UPDATE is **unqualified**
(`UPDATE promotion_assertion_runs SET ...`), which resolves to
`tenant_default.promotion_assertion_runs` — a different table — so 0 rows are
updated. This is a test-only mismatch: production `recordTeardownFailure`
(`assertion_rerun.zig:607`) runs under a real tenant `search_path` where the row and
the UPDATE live in the same schema.

### Patch shape

**Before** (manual UPDATE, lines 694–702 — unqualified target):

```zig
            \\UPDATE promotion_assertion_runs SET
            \\    status = CASE
            \\        WHEN status = 'failed' THEN 'failed'
            \\        ELSE 'teardown_failed'
            \\    END,
            \\    teardown_error = $2
            \\WHERE id = (SELECT id FROM public.promotion_assertion_runs
            \\             WHERE tenant_id = $1::uuid AND idempotency_key = $3 LIMIT 1)::uuid
            \\RETURNING id::text
```

**After** (minimal fix — qualify the UPDATE target to match the INSERT):

```zig
            \\UPDATE public.promotion_assertion_runs SET
            \\    status = CASE
            \\        WHEN status = 'failed' THEN 'failed'
            \\        ELSE 'teardown_failed'
            \\    END,
            \\    teardown_error = $2
            \\WHERE id = (SELECT id FROM public.promotion_assertion_runs
            \\             WHERE tenant_id = $1::uuid AND idempotency_key = $3 LIMIT 1)::uuid
            \\RETURNING id::text
```

**Optional refinement (recommended, mirrors production):** capture the run id at
insert time via `RETURNING id::text` on the qualified INSERT, then key the UPDATE
directly by run id (exactly as production `recordTeardownFailure` does with
`WHERE id = $1::uuid`). This removes the fragile `tenant_id + idempotency_key`
subselect and makes the simulation match production's SQL shape more closely. The
minimal qualifier fix alone satisfies the acceptance criteria; the refinement is a
robustness bonus, not a blocker.

---

## Cluster B — TC-PRM-07-03 (defensive parent `promotion_reviews` seed)

**Test:** `test "TC-PRM-07-03: handleGetPromotion returns 200 with teardown_error and
sandbox_id ..."` (line 885). **Assertion-runs INSERT:** lines ~911–928.

### Symptom

In environments where the conditional FK `promotion_assertion_runs_review_fk`
(`review_id` → `promotion_reviews(id)`, added by migration `1156` only when
`promotion_reviews` exists in the schema) is present, `TC-PRM-07-03` fails with
sqlstate `23503` because it inserts into `promotion_assertion_runs` without first
seeding a parent `promotion_reviews` row. **Not reproducible in this workspace**
(schema inspection shows no review FK on either copy; the test passes here), but the
defect is real in any DB where the FK was applied, so the defensive fix is specified.

### Root cause

The test seeds only the run row; it never seeds the owning review row that a foreign
key on `review_id` requires. The FK's conditional creation (migration 1156) means the
failure is environment-dependent.

### Patch shape

**Before** (lines ~905–928 — direct run-row INSERT, no parent):

```zig
    try insertTestTenant(&pool, tenant_id, tenant_id);

    // Insert a teardown_failed run row with sandbox_id and teardown_error set.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        try conn.exec(
            \\INSERT INTO promotion_assertion_runs
            \\    (tenant_id, review_id, idempotency_key, status, plan_digest,
            \\     assertions_total, assertions_passed, assertions_failed,
            \\     sandbox_id, teardown_error, started_at, completed_at)
            \\VALUES ($1::uuid, $2::uuid, $3, 'teardown_failed', 'prm07-ac3-digest',
            \\        1, 1, 0,
            \\        $4::uuid, 'ProvisionFailed', NOW(), NOW())
        ,
            &[_][]const u8{ tenant_id, review_id, idem_key, sandbox_id },
        );
    }
```

**After** (seed the parent `promotion_reviews` row first, via the fixed
`insertPromotionReviewsRow`):

```zig
    try insertTestTenant(&pool, tenant_id, tenant_id);

    // Seed the parent review row first (defensive: satisfies the conditional
    // promotion_assertion_runs_review_fk from migration 1156 when present).
    const requested_by = try randomUuidStr(alloc);
    defer alloc.free(requested_by);
    try insertPromotionReviewsRow(&pool, tenant_id, review_id, "approved", requested_by);

    // Insert a teardown_failed run row with sandbox_id and teardown_error set.
    {
        const conn = try pool.acquire();
        defer pool.release(conn);
        try conn.exec(
            \\INSERT INTO promotion_assertion_runs
            \\    (tenant_id, review_id, idempotency_key, status, plan_digest,
            \\     assertions_total, assertions_passed, assertions_failed,
            \\     sandbox_id, teardown_error, started_at, completed_at)
            \\VALUES ($1::uuid, $2::uuid, $3, 'teardown_failed', 'prm07-ac3-digest',
            \\        1, 1, 0,
            \\        $4::uuid, 'ProvisionFailed', NOW(), NOW())
        ,
            &[_][]const u8{ tenant_id, review_id, idem_key, sandbox_id },
        );
    }
```

Both the parent seed and the run-row INSERT are unqualified, so they land in the same
`tenant_default` schema under the test connection's `search_path` — consistent with
`handleGetPromotion`, which reads `promotion_assertion_runs` unqualified through the
same `search_path`. Cleanup is unaffected (`dropTenantFixtures` already deletes both
tables).

---

## Public interface

Only test-helper/test-setup changes; no production interface changes.

```zig
// CHANGED — helper signature (tests/integration/prm-06-07-promotion-assertion.test.zig:99)
fn insertPromotionReviewsRow(
    pool: *Pool,
    tenant_id: []const u8,
    review_id: []const u8,
    status: []const u8,
    requested_by: []const u8,          // NEW — NOT NULL promotion_reviews.requested_by
) !void;
// Contract: inserts/upserts a promotion_reviews row in the connection's current
// schema with all NOT NULL columns populated (requested_by from the caller,
// def_type/serialised_plan from fixture sentinels).

// UNCHANGED callers now supply the new argument:
//   TC-PRM-06-03 line 482  -> pass a fresh randomUuidStr(alloc)
//   TC-PRM-07-03 (new)      -> pass a fresh randomUuidStr(alloc)
```

No new public functions are required. Cluster C is an in-place SQL string fix
(qualify the UPDATE target; optional run-id capture via `RETURNING id::text` on the
existing qualified INSERT). Cluster B adds one call to the already-public helper.

---

## Data flow diagram

```
                  makePool() sets search_path = tenant_default, public
                  (tenant context = zero UUID -> schemaNameForTenant -> tenant_default)

 CLUSTER A  TC-PRM-06-03
   insertPromotionReviewsRow(..., requested_by)  --unqualified INSERT-->  promotion_reviews [tenant_default]
        requested_by/def_type/serialised_plan now populated (was: 23502)     ^
                                                                            |
 CLUSTER B  TC-PRM-07-03                                                     |
   insertPromotionReviewsRow(..., requested_by)  --unqualified INSERT-->  promotion_reviews [tenant_default]
   INSERT promotion_assertion_runs                --unqualified INSERT-->  promotion_assertion_runs [tenant_default]
        review_id FK satisfied defensively (was: 23503 when FK present)
   handleGetPromotion                            --unqualified SELECT-->   reads back [tenant_default] (200)

 CLUSTER C  TC-PRM-07-01
   INSERT public.promotion_assertion_runs        --qualified INSERT--->   public.promotion_assertion_runs
   UPDATE public.promotion_assertion_runs SET ... --QUALIFIED now--->     same row -> status = teardown_failed (was: 0 rows)
        (before: unqualified UPDATE -> tenant_default.promotion_assertion_runs -> 0 rows -> stayed 'passed')
```

---

## Error taxonomy

| Condition | Before fix | After fix |
|---|---|---|
| `promotion_reviews.requested_by` NOT NULL (sqlstate 23502) | Cluster A: TC-PRM-06-03 fails | Helper populates `requested_by` (fresh UUID) |
| `promotion_reviews.def_type` / `serialised_plan` NOT NULL (sqlstate 23502) | latent (same INSERT) | Helper populates both sentinels |
| `promotion_assertion_runs_review_fk` violation (sqlstate 23503) | Cluster B: TC-PRM-07-03 fails where FK present | Parent review row seeded first |
| Manual teardown UPDATE matches 0 rows → status stays `passed` | Cluster C: TC-PRM-07-01 assertion fails | UPDATE qualified to `public`, matches the fixture row |
| `BPM_TEST_DB_URL` missing | `error.MissingTestDatabaseUrl` (pre-existing, T-1 directive) | unchanged |
| Env: DB up but API/IDP down | not applicable — all 9 tests are DB-only | unchanged |

No new error paths are introduced; the fixes remove three failure modes from the test
fixtures.

---

## State transitions

- `promotion_reviews.status`: unchanged semantics — the helper still upserts
  `'approved'` etc. via `ON CONFLICT ... DO UPDATE SET status = EXCLUDED.status`.
  The fix only additionally populates the previously-missing NOT NULL columns.
- `promotion_assertion_runs.status` (Cluster C): `'passed'` → `'teardown_failed'`.
  The state machine is unchanged; the fix makes the manual UPDATE actually reach the
  intended row (`public`) instead of silently hitting 0 rows in `tenant_default`.
- No production state machines are touched.

---

## Dependencies

**What this module (the test file) calls:**
- `helpers.zig` (`acquireIntegrationLock`, `releaseIntegrationLock`) — integration
  serialisation.
- `bpm` internals: `pool.Pool` / `PoolConfig`, `api_tenant_context.set`,
  `promotion_assertion_rerun` (`applyPromotionAssertionRerun`, `buildIdempotencyKey`,
  `stripNonDeterministicFields`, `PromotionArtifact`, `RunStatus`),
  `sandbox_pool.SandboxPool` (`claim`/`release`/`reclaimLeakedSandboxes`),
  `promotion_assertion_routes`, `promotion_read_routes.handleGetPromotion`,
  `api_auth.AuthContext`.
- Test DB schema: migration `096_promotion_reviews.sql`,
  `1156_prm06_promotion_assertion_runs.sql` (per-tenant bootstrap).

**Must NOT depend on:**
- Any production code change (none is required).
- The `.vscode/run-zig-test-integration.ps1` or `zig-test-integration-cmd` task —
  they hardcode the stale `5433` port; this run's test DB is on `5453`.
- The issue body's incorrect file split (`prm-06-promotion-assertion.test.zig` /
  `prm-07-assertion-rerun.test.zig` do not exist; the combined file is authoritative).

---

## Verification plan

```
BPM_TEST_DB_URL=postgres://bpm:bpm@localhost:5453/bpm_test zig build test-integration-prm06-07
```

Must exit **0** with **9/9 tests passing**.

- The combined target `test-integration-prm06-07` is the only target for this file
  (build.zig:3130). **There is no separate `test-integration-prm-06` or
  `test-integration-prm-07` target** — do not look for one; the combined target runs
  the single file and covers all nine tests.
- The test DB on `:5453` is confirmed UP for this workspace; the API (`:8090`) and
  IDP (`:8091`) are NOT required — all 9 tests are DB-only.
- Step 1 observed 7 pass / 2 fail before the fix; after all three clusters are applied,
  the two failures (TC-PRM-06-03, TC-PRM-07-01) must pass and TC-PRM-07-03 must
  remain green (it already passes here; Cluster B keeps it green where the FK exists).

---

## Open questions

1. **Cluster C optional refinement:** take the run-id capture (`RETURNING id::text` on
   the INSERT, then `WHERE id = $run_id` on the UPDATE, mirroring production
   `recordTeardownFailure`) or ship the minimal qualifier fix only? Recommended:
   the minimal fix is required; the refinement is a robustness bonus and is safe to
   include, but is not an acceptance criterion.
2. **Sentinel values:** `def_type='assertion_rerun'` and
   `serialised_plan='prm06-test-serialised-plan'` are arbitrary fixture strings. They
   are fine for assertion-rerun tests, but must not be reused where `def_type`
   semantics are asserted. No REQ-ANALYST clarification needed — this is a test
   fixture convention, noted for the implementer.
3. **Duplicate helper defect in prm-08** (`prm-08-rollback-sandbox.test.zig:233–258`):
   same `insertPromotionReviewsRow` NOT-NULL omission, out of ISS-0708 scope. It
   should be filed/tracked as its own follow-up so it does not resurface as a 23502
   in the PRM-08 batch.
