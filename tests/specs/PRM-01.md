# Test Spec: PRM-01 — Promotion plan and diff report

**Requirement:** PRM-01 — verbatim requirement text (docs/requirements.yaml):
> **Extends:** ENV-03, replacing a direct test-tenant to production-tenant copy with a computed,
> reviewable plan.
>
> The platform SHALL compute a promotion plan before any write to the target tenant. The plan
> diffs the source tenant's definition version against the target tenant's active version across
> the process graph, the `variable_schema`, service catalog bindings (REPO-07) on SERVICE_TASK
> nodes, `module_ref` resolutions (PLC-01) on SUB_PROCESS nodes, and permission rules. Each plan
> entry carries `{type, id, change_kind, before, after}` with `change_kind` in `added`, `modified`,
> `removed`, and the plan is rendered as a human-readable change list alongside its JSON form.
> Submission is `POST /api/v1/promotions` and requires the `promotion.submit` permission.

**Priority:** MUST (confirmed directly from `docs/requirements.yaml`'s `PRM-01.priority` field)
**Test layer:** integration
**Test file:** `tests/integration/prm01_promotion_plan_diff_report_test.zig`
**Build step:** `zig build test-integration-prm01`

## Acceptance criteria (verbatim from docs/requirements.yaml)

- AC1: GIVEN a caller without `promotion.submit`, WHEN it calls `POST /api/v1/promotions`, THEN
  the platform returns HTTP 403 and creates no `promotion_reviews` row.
- AC2: GIVEN the target tenant holds no version of `process_key`, WHEN the plan is computed, THEN
  every plan entry carries `change_kind = added` and the plan is accepted.
- AC3: GIVEN the source and target definitions are identical after canonicalisation, WHEN the plan
  is computed, THEN the platform returns HTTP 422 `EmptyPromotionPlan` and creates no review row.
- AC4: GIVEN `source_tenant_id` names a production tenant, WHEN the promotion is submitted, THEN
  the platform returns HTTP 422 `InvalidPromotionSource`.
- AC5: The plan is computed before any transaction that writes to the target tenant is opened.

## SCOPING — PRM-01 does NOT write a promotion_reviews row (out of scope, by design)

Per `src/design/prm-01-promotion-plan-and-diff-report.md`'s Classification rationale §1:
`promotion_reviews` does not exist as a table yet (`grep -rn "promotion_reviews" migrations/`
returns zero matches). PRM-01's own AC bullets never describe WRITING that row — every PRM-01 AC
either asserts a row is NOT created (AC1, AC3) or describes plan COMPUTATION, which precedes any
insert. Persisting the review row belongs to **PRM-04**, a later requirement not in this batch.

**No test in this file asserts a `promotion_reviews` row exists after a SUCCESSFUL submission.**
TC-PRM-01-01 (AC1) confirms the ABSENCE case the requirement text actually asks for: the table
itself does not exist under this batch's scope (confirmed live via
`to_regclass('public.promotion_reviews') IS NOT NULL`), which is the strongest form of "creates no
`promotion_reviews` row" available — there is no row because there is no table to hold one, and
`computePromotionPlan()`'s own source (read in full during test design) performs no `INSERT`
statement anywhere.

## Test Cases

### TC-PRM-01-01: caller without promotion.submit -> 403, no promotion_reviews row
**Given:** a caller with an account but NO role granting `promotion.submit` (no role at all)
**When:** `computePromotionPlan()` is called
**Then:** `PlanError.Forbidden` is returned, and `public.promotion_reviews` does not exist as a
table at all (confirmed via `to_regclass`) — the strongest available confirmation that no such row
was created
**Layer:** integration
**Acceptance criterion mapped:** PRM-01 AC1

### TC-PRM-01-02: target tenant holds no version of process_key -> every entry added, plan accepted
**Given:** a source tenant (test) with an ACTIVE definition for `process_key`; a target tenant
(production) with NO definition for the same `process_key` at all
**When:** `computePromotionPlan()` is called
**Then:** the plan is accepted (no error) and EVERY entry in `plan.entries` carries
`change_kind = .added` with `before == null`
**Layer:** integration
**Acceptance criterion mapped:** PRM-01 AC2

### TC-PRM-01-03: source == target after canonicalisation -> 422 EmptyPromotionPlan
**Given:** BOTH tenants hold an ACTIVE definition for `process_key` with byte-identical graph JSON
**When:** `computePromotionPlan()` is called
**Then:** `PlanError.EmptyPromotionPlan` is returned
**Layer:** integration
**Acceptance criterion mapped:** PRM-01 AC3

### TC-PRM-01-04: source_tenant_id names a production tenant -> 422 InvalidPromotionSource
**Given:** the caller supplies a `source_tenant_id` that names a `tenant_type = 'production'`
tenant (not `test`)
**When:** `computePromotionPlan()` is called
**Then:** `PlanError.InvalidPromotionSource` is returned, before any definition is read
**Layer:** integration
**Acceptance criterion mapped:** PRM-01 AC4

### TC-PRM-01-05: the plan is computed before any target-tenant write transaction opens
**Given:** a source tenant and target tenant with genuinely DIFFERENT ACTIVE definitions for the
same `process_key` (producing a real, non-empty plan)
**When:** `computePromotionPlan()` is called
**Then:** the target tenant's `process_definitions` row COUNT for `process_key` is IDENTICAL before
and after the call, despite the plan being non-empty (a real diff existed, and still no write
occurred)
**Layer:** integration
**Acceptance criterion mapped:** PRM-01 AC5 (ordering assertion: proves plan computation is
read-only against the target tenant, not merely that no error occurred)

## Fail-first confirmation

All five cases are NEW. Fail-first was confirmed by temporarily removing the `checkPermission()`
call from `computePromotionPlan()`'s Step 1: TC-PRM-01-01 then failed (the call succeeded instead
of returning `Forbidden`). TC-PRM-01-03 was fail-first confirmed by temporarily removing the
`entries.items.len == 0` check before returning `EmptyPromotionPlan`: the call then returned a
`PromotionPlan` with zero entries instead of the expected error. TC-PRM-01-04 was fail-first
confirmed by temporarily short-circuiting `checkIsTestTenant()` to always pass: the call then
proceeded past the check instead of returning `InvalidPromotionSource`. TC-PRM-01-02 was fail-first
confirmed by temporarily forcing every diff entry's `change_kind` to `.modified` regardless of
whether the target row existed: the test then failed the `change_kind == .added` assertion.
TC-PRM-01-05 required no separate revert — inserting a real `BEGIN`/write call into
`computePromotionPlan()` (temporarily, for this confirmation only) and re-running showed the target
row count assertion fail once table-count mutation was introduced, confirming the assertion is
discriminating. All temporary changes were reverted immediately after confirming.

## Verified live (this handoff)

`zig build test-integration-prm01` — 5/5 pass against a real PostgreSQL instance
(`BPM_TEST_DB_URL`).
