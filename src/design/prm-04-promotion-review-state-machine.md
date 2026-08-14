# Module: prm-04-promotion-review-state-machine

**Requirement ID:** PRM-04
**Run ID:** WF02-prm-batch2-20260814 (Stage 16)
**Step:** 01 (CODE-DESIGNER)
**Type:** Type C (migration) + Type E (state machine + API transitions)

**Extends:**
- `src/definition/promotion_plan.zig` (PRM-01 — `PromotionPlan` output)
- `src/definition/promotion.zig` (ENV-03 — promotion pipeline context)
- `docs/processes/system/definition-promotion.md` — Steps 6, 10, 18

---

## Classification rationale

Applying `templates/lego-catalog.md` selection rules:

1. **Type C — yes.** `promotion_reviews` is a new table with columns, constraints, a status CHECK, and a partial unique index. One YAML parameter file (`templates/specs/prm04-promotion-reviews.migration.yaml`) covers the schema.
2. **Type E — also yes.** The state machine logic (permitted edges, transition enforcement, `row_version`-based optimistic locking, `approved_by`/`approved_at` tracking) is novel business logic not captured by the Type C template. The API transitions (approve, reject, apply, mark_failed) are coordinated multi-step operations within transactions.

**Final classification:** Type C (migration parameter file) + Type E (this prose artefact for state machine and API transitions).

---

## Module purpose

Persist promotion approvals in a `promotion_reviews` table. This table is the **central state machine** for the promotion pipeline: it records who requested a promotion, what plan was approved, who approved it, and whether it has been applied, rejected, superseded, or failed. All transitions are ACID and the `status` field is CHECK-constrained to exactly six values.

The table is also the **idempotency anchor** for the digest (PRM-03): one live review per `(tenant_id, plan_digest)` prevents duplicate reviews.

---

## Database schema (Type C parameter)

See `templates/specs/prm04-promotion-reviews.migration.yaml` for the full migration parameter file. Key elements:

```sql
CREATE TABLE promotion_reviews (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL,
    plan_digest     text NOT NULL,          -- lowercase hex SHA-256, 64 chars
    def_type        text NOT NULL,          -- 'process' for now; extensible
    def_id          text NOT NULL,          -- process_key
    serialised_plan text NOT NULL,          -- full JSON, canonical form (PRM-03)
    status          text NOT NULL DEFAULT 'pending_review'
        CHECK (status IN (
            'pending_review','approved','rejected','applied','failed','superseded'
        )),
    requested_by    uuid NOT NULL,          -- principal who submitted the plan
    approved_by     uuid,                   -- set on pending_review -> approved
    approved_at     timestamptz,            -- set on approval
    superseded_by   uuid,                   -- review_id that superseded this one
    row_version     integer NOT NULL DEFAULT 1,  -- optimistic lock
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Partial unique index: one live review per digest per tenant
CREATE UNIQUE INDEX promotion_reviews_plan_digest_active_uniq
    ON promotion_reviews (tenant_id, plan_digest)
    WHERE status IN ('pending_review', 'approved');

-- Index for superseded lookups during rollback (PRM-08)
CREATE INDEX idx_promotion_reviews_tenant_status
    ON promotion_reviews (tenant_id, status)
    WHERE status IN ('applied', 'superseded');
```

---

## State machine diagram

```
                    ┌──────────────────────┐
                    │   pending_review     │
                    └──────────┬───────────┘
                               │
              ┌────────────────┼────────────────┐
              │                │                │
              ▼                ▼                ▼
     ┌────────────┐   ┌────────────┐   (no direct transition
     │  approved  │   │  rejected  │    to superseded from
     └─────┬──────┘   └────────────┘    pending_review --
           │                                  PRM-04 AC: rejected->superseded
           │                                  is NEW (fixes BLOCKER vs RELEASED
           │                                  PRM-08; a rejected review can be
           │                                  closed by a subsequent promotion
           │                                  of the same definition)
           │          ┌──────────────────────┘
           │          │
           │          ▼
           │   ┌────────────┐
           │   │  applied   │──────► superseded
           │   └─────┬──────┘         (via PRM-08 rollback
           │         │                   or PRM-09 supersession)
           │         │ (PRM-06 assertion failure)
           │         ▼
           │   ┌────────────┐
           │   │   failed   │──────► superseded
           │   └────────────┘         (same as applied->superseded)
           │
           └───────────────────────────────────────► superseded
               (explicit: another review for same
                tenant+digest superseded this one)
```

**Permitted edges (7 total, per PRM-04 AC):**

| From | To | Trigger |
|---|---|---|
| `pending_review` | `approved` | `POST .../approve` — PRM-04 AC1 |
| `pending_review` | `rejected` | `POST .../reject` — PRM-04 AC1 |
| `pending_review` | `superseded` | NEW: another review for same `(tenant_id, plan_digest)` advanced first |
| `approved` | `applied` | `POST .../apply` — PRM-04 AC4 |
| `approved` | `failed` | Assertion re-run failure — PRM-04 AC3 |
| `applied` | `superseded` | PRM-08 rollback or PRM-09 supersession — PRM-04 AC4 |
| `failed` | `superseded` | PRM-08 rollback or PRM-09 supersession — PRM-04 AC4 |
| `rejected` | `superseded` | NEW: explicit supersession when a newer review advances — PRM-04 AC4 note |

---

## Public interface

**Inline signatures (full types in prose above):**

`ReviewStatus` enum: `pending_review | approved | rejected | applied | failed | superseded`

`ReviewTransitionError`: `InvalidReviewTransition | DuplicateReview | PoolExhausted | TransactionFailed | OutOfMemory`

`approveReview(allocator, pool, review_id, actor_id, plan_digest) ReviewTransitionError!void`

`rejectReview(allocator, pool, review_id, actor_id) ReviewTransitionError!void`

`markReviewApplied(allocator, pool, review_id) ReviewTransitionError!void`

`markReviewFailed(allocator, pool, review_id) ReviewTransitionError!void`

`supersedeReview(allocator, pool, review_id, superseding_review_id) ReviewTransitionError!void`

---

## Data flow diagram

    Promotion plan submitted (POST /api/v1/promotions)
            |
            |  [PRM-01 computes plan]
            |  [PRM-02 conflict check — no conflict]
            |  [PRM-03 digest computed]
            v
    INSERT INTO promotion_reviews (..., status='pending_review', row_version=1)
            |
            |  Partial unique index: (tenant_id, plan_digest)
            |  WHERE status IN ('pending_review','approved')
            |  --> duplicate digest: HTTP 409 DuplicateReview
            v
    Review in: pending_review
            |
            |  [PRM-05: GET .../context returns stored plan + digest]
            v
    POST .../approve  { plan_digest, approved_by }
            |  Gate: digest match, actor != requested_by, status=pending_review, row_version match
            v
    UPDATE ... SET status='approved', approved_by=..., approved_at=now(),
                  row_version=row_version+1
      WHERE id=$review_id AND row_version=$expected_version
            |  Append DEFINITION_PROMOTION_APPROVED event
            v
    Review in: approved
            |  [PRM-06: assertion re-run in sandbox]
            +-- success --> POST .../apply --> markReviewApplied --> applied
            +-- failure --> markReviewFailed --> failed
            |  [PRM-08: rollback / PRM-09: supersession]
            v
    Review in: applied | failed | rejected | superseded (terminal or closed)

---

## Error taxonomy

| Error | Trigger | Surfaced as |
|---|---|---|
| `InvalidReviewTransition` | Transition not in the 7-edge set, or wrong `row_version` | HTTP 400 `INVALID_REVIEW_TRANSITION` |
| `DuplicateReview` | Partial unique index violation on `(tenant_id, plan_digest)` | HTTP 409 `DUPLICATE_REVIEW` |
| `PoolExhausted` | Cannot acquire DB connection | HTTP 503 `SERVICE_UNAVAILABLE` |
| `TransactionFailed` | Event append or UPDATE fails | HTTP 500 `INTERNAL_ERROR` |

---

## Optimistic locking

Every transition UPDATE includes `WHERE row_version = $expected_version`. The UPDATE returns a row count; if zero rows match, the transition fails with `InvalidReviewTransition`. The `row_version` is incremented on every UPDATE, never decremented.

`updated_at` is also updated on every state transition (maintained by a trigger or application-level update).

---

## Dependencies

| Dependency | Kind | Notes |
|---|---|---|
| `PromotionPlan` type | Code | Serialised plan stored in `serialised_plan` column |
| `computePlanDigest()` (PRM-03) | Code | Digest stored at insert time |
| `event_store.store.zig` | Code | Event append for `DEFINITION_PROMOTION_APPROVED`, `DEFINITION_PROMOTION_APPLIED` |
| `rejectIfConflicts()` (PRM-02) | Code | Conflict check must run before this table is written |
| `promotion_assertion_runs` table | DB prerequisite | Created by PRM-06; FK not needed but run_id is recorded against this review |

**Must NOT depend on:** PRM-06/07/08/09 implementation details — this module defines the table and state machine; the later requirements write into it.

---

## Open questions

1. **`def_type` values:** Currently only `'process'` is used. The table is designed to be extensible (solution pack reviews could reuse the same table with `def_type = 'solution_pack'`). BACKEND-DEV to add an explicit CHECK constraint over known values if the set is closed, or leave as text if extensible.

2. **`superseded_by` semantics:** `superseded_by` stores the `review_id` of the review that caused supersession (for PRM-08 rollback: the rollback event id; for PRM-09: the new review's id). BACKEND-DEV to confirm this is the intended semantics and that the field name is not confusingly similar to `superseded_by` in other tables.

3. **`approved_by` NULL on reject:** The `approved_by` column is `NULL` for a rejected review — a review is rejected without an approver. This is consistent with the data model but the API response for a rejected review should omit `approved_by` rather than returning `null` explicitly. BACKEND-DEV to handle this in the API serialization layer.
