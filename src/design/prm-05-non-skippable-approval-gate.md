# Module: prm-05-non-skippable-approval-gate

**Requirement ID:** PRM-05
**Run ID:** WF02-prm-batch2-20260814 (Stage 16)
**Step:** 01 (CODE-DESIGNER)
**Type:** Type E — Novel business logic

**Extends:**
- `src/design/prm-04-promotion-review-state-machine.md` (state machine, `approveReview`, `rejectReview`)
- `src/design/prm-03-plan-digest.md` (digest binding)
- `docs/processes/system/definition-promotion.md` — Steps 7, 8, 9, 11

---

## Classification rationale

Applying `templates/lego-catalog.md` selection rules:

1. **Type C?** No new table introduced. The gate logic is enforcement of an existing table's state transitions — not schema work.
2. **Type A?** Not a standard CRUD endpoint. The gate requires: (a) self-approval prevention (`requested_by != approved_by`), (b) status CHECK before apply, (c) unknown-field rejection on approve/apply request bodies, (d) context endpoint serving stored data, not live re-computation. Multi-constraint enforcement across request validation and state.
3. **Type E — yes.** The approval gate is a cross-cutting business rule spanning: self-approval prevention, digest verification, status enforcement, request schema validation (no bypass fields), and the context endpoint semantics. These are all coordinated constraints not reducible to a single CRUD operation.

---

## Module purpose

Enforce that every promotion requires an approved review before it can be applied. There is **no bypass parameter, header, flag, or configuration value** that skips this check. The reviewer must be a different principal from the submitter. The context endpoint serves the **stored** plan (not a live re-diff) so the digest binds to exactly what the reviewer saw.

---

## Public interface

```zig
/// Verifies that apply may be called on a review.
/// Returns error if status != approved.
/// No bypass parameter is checked — this is the non-skippable gate.
pub const ApplyGateError = error{
    /// Review status is not 'approved'. HTTP 400.
    InvalidReviewTransition,
    PoolExhausted,
    TransactionFailed,
};

/// Validates an approval request.
/// Checks: (1) reviewer != requested_by, (2) status == pending_review, (3) digest matches.
/// Returns error on any check failure; returns void on success.
pub const ApprovalGateError = error{
    /// reviewer principal == requested_by. HTTP 403.
    SelfApprovalForbidden,
    /// Review not in pending_review. HTTP 400.
    InvalidReviewTransition,
    /// plan_digest mismatch. HTTP 409.
    PlanDigestMismatch,
    PoolExhausted,
    TransactionFailed,
};

/// Checks whether a principal is allowed to act on a review.
/// Self-approval is the only rule here (the rest is state-machine level).
pub fn canPrincipalApprove(requested_by: []const u8, approver: []const u8) bool;

/// Returns the stored plan, digest, and review context for a given review_id.
/// The data comes from the stored serialised_plan on the promotion_reviews row,
/// NEVER from a live re-computation of the diff.
pub fn getPromotionContext(
    allocator: std.mem.Allocator,
    pool: *pool_mod.Pool,
    review_id: []const u8,
) (error{ PoolExhausted, TransactionFailed } | ?PromotionContext);
```

---

## Data flow diagram

    Authoring Agent: POST /api/v1/promotions
            |  [PRM-01 computes plan]
            |  [PRM-02 conflict check]
            |  [PRM-03 digest computed]
            |  [PRM-04 INSERT promotion_reviews status=pending_review]
            v
            +---> GET /api/v1/promotions/{id}/context
                    |  Returns: serialised_plan, plan_digest, assertions[],
                    |           NEEDS_REVIEW package, def_type, def_id
                    |  [Data from STORED row, never live-recomputed]
            +---> POST /api/v1/promotions/{id}/approve
                    |  Body: { plan_digest, approved_by }
                    |  Gate: (1) approved_by != requested_by --> 403
                    |        (2) status == pending_review   --> 400
                    |        (3) plan_digest == stored      --> 409
                    |  All pass: approveReview() --> pending_review->approved
            +---> POST /api/v1/promotions/{id}/reject
                    |  Body: {} (no digest needed)
                    |  Gate: status == pending_review --> 400; actor != requested_by
                    |  All pass: rejectReview() --> pending_review->rejected
            +---> POST /api/v1/promotions/{id}/apply
                    |  Body: { plan_digest }
                    |  Gate: status == approved --> 400 [NO bypass parameter]
                    |        plan_digest == stored --> 409
                    |  All pass: PRM-06 sandbox claim --> apply or fail

---

## Non-skippable gate enforcement

**The apply gate has no bypass.** PRM-05 AC3 explicitly requires:

> "The platform SHALL provide no request parameter, header, flag or configuration value that bypasses the check."

This means:
- `POST /api/v1/promotions/{id}/apply` **request body schema** has exactly one field: `{ plan_digest: string }`.
- Any additional field in the request body must be rejected with HTTP 422 (unknown field).
- There is no `Authorization` header flag, no `X-Skip-Gate` header, no `?bypass=true` query param.
- The `require_approved_review` check is enforced **in the handler** by checking `review.status == 'approved'` before taking any further action.
- Pre-vetted templates (e.g. platform-published) use a **separate entry point** that never reaches `apply` — not a bypass flag on `apply`. This is enforced at the API design level.

---

## Self-approval prevention

**The principal recorded in `requested_by` cannot approve its own review.** This is a separation-of-duties rule enforced at the approval gate:

```zig
// canPrincipalApprove:
pub fn canPrincipalApprove(requested_by: []const u8, approver: []const u8) bool {
    // Principals must be different. UUID comparison.
    return !std.mem.eql(u8, requested_by, approver);
}
```

On the `approveReview` path:
- If `approver == requested_by` → `SelfApprovalForbidden` → HTTP 403.

Note: **Reject does NOT have the same restriction.** A reviewer can reject their own submitted review — the separation-of-duties rule is about approval, not rejection. (A principal who submits a plan should not be able to approve it unilaterally; rejection is acceptable as it does not advance the promotion.)

---

## GET /api/v1/promotions/{id}/context — stored-data semantics

The context endpoint must serve **exactly what was stored at submit time**, not a live re-computed diff:

| Field | Source | Notes |
|---|---|---|
| `serialised_plan` | `promotion_reviews.serialised_plan` | Canonical JSON stored at INSERT |
| `plan_digest` | `promotion_reviews.plan_digest` | Digest of the stored plan |
| `assertions[]` | From `artifact_id` lookup | Artifact carries assertions; fetch and return |
| `NEEDS_REVIEW` package | From `artifact_id` lookup | Per PRM-05 AC: "assertions carried by the artifact... and the NEEDS_REVIEW package" |
| `def_type`, `def_id` | `promotion_reviews` row | The definition being promoted |

**Critical:** The `plan_digest` in the context response is the digest of the **stored** plan, computed at submit time. The reviewer can use this to independently verify the plan: recompute the digest over the `serialised_plan` and confirm it matches `plan_digest`. This is how the digest binds the reviewer's decision to the exact diff.

---

## Request body schema validation

Approve request body:
```json
{
  "plan_digest": "<64-char hex string>",   // REQUIRED
  "approved_by": "<UUID>"                  // REQUIRED — the reviewer principal
}
```
Any additional field → HTTP 422 `UNKNOWN_FIELD`.

Apply request body:
```json
{
  "plan_digest": "<64-char hex string>"    // REQUIRED
}
```
Any additional field → HTTP 422 `UNKNOWN_FIELD`. No `approved_by` on apply — the gate check is purely status-based.

---

## Error taxonomy

| Error | Trigger | Surfaced as |
|---|---|---|
| `SelfApprovalForbidden` | `approved_by == requested_by` on approve | HTTP 403 `SELF_APPROVAL_FORBIDDEN` |
| `InvalidReviewTransition` | Apply called when `status != approved` | HTTP 400 `INVALID_REVIEW_TRANSITION` |
| `PlanDigestMismatch` | Approve/apply body digest ≠ stored digest | HTTP 409 `PLAN_DIGEST_MISMATCH` |
| `PoolExhausted` | Cannot acquire DB connection | HTTP 503 `SERVICE_UNAVAILABLE` |
| `TransactionFailed` | DB operation fails | HTTP 500 `INTERNAL_ERROR` |

---

## Dependencies

| Dependency | Kind | Notes |
|---|---|---|
| `promotion_reviews` table | DB | State machine; created by PRM-04 migration |
| `computePlanDigest()` (PRM-03) | Code | For context endpoint to independently verify stored digest |
| `approveReview()` / `rejectReview()` (PRM-04) | Code | State transitions gated by this module's checks |
| `PromotionContext` return type | Type | Returned by `getPromotionContext()`; carries plan + digest + assertions |

**Must NOT depend on:** Any bypass mechanism anywhere in the codebase. The gate must be structurally non-bypassable — verified by the absence of any bypass field in the apply schema.

---

## Open questions

1. **`NEEDS_REVIEW package:** The exact shape of the "NEEDS_REVIEW package" is not defined in PRM-05's AC text. It likely refers to the artifact's metadata (assertions + fixtures + rng_seed) that the reviewer must have access to. BACKEND-DEV to define a `PromotionContext` struct that includes `serialised_plan`, `plan_digest`, `assertions[]`, and whatever the artifact lookup returns as the `NEEDS_REVIEW` data. If the artifact is not yet linked at submit time, the context endpoint should return an appropriate error.

2. **`rejected -> superseded` edge:** PRM-04 added this edge (fixing the BLOCKER vs RELEASED PRM-08 conflict). The `rejectReview()` function must allow a rejected review to be subsequently superseded. This is implemented at the PRM-04 level (state machine), but PRM-05's context endpoint and the rejection flow must be aware that `rejected` is not terminal — it can transition to `superseded` via a subsequent promotion of the same definition. The UI (not this design's scope) should reflect this.

3. **Pre-vetted template entry point:** PRM-05 AC4 says "pre-vetted platform-published template installed during provisioning" uses a **separate entry point** that never calls `apply`. This is an architectural decision for FRONTEND-DEV and the API designer: there must be a different promotion path for platform-published content that reaches production without a human review step. The separation must be at the API routing level (a different route), not at the handler level (a conditional bypass). This needs clarification from REQ-ANALYST if not already covered elsewhere.
