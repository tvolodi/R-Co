# Test Spec: PRM-05 — Non-skippable approval gate

**Requirement:** PRM-05 — The platform SHALL provide no bypass parameter, header, flag or configuration value for the promotion approval gate. The reviewer must be a different principal from the submitter (self-approval → HTTP 403).
**Priority:** MUST
**Test layer:** integration

## Test Tier Derivation

| Dimension | Points | Notes |
|---|---|---|
| DB schema | 0 | Gate logic in API handlers, no new table |
| Tenant isolation | 0 | Single-review enforcement |
| Transactional boundary | 1 | Gate checks inside transaction |
| **Total** | **1** | **Unit + integration** |

## Test Cases

### TC-PRM-05-01: Apply blocked when review status is pending_review

**Given:** A promotion review in `pending_review` status.

**When:** `handleApplyReview` is called.

**Then:** Returns HTTP 400 `INVALID_REVIEW_TRANSITION`. Review remains `pending_review`. No bypass occurs.

**Layer:** integration  
**Acceptance criterion:** PRM-05 AC2 — apply gate requires `status == approved`, no bypass.

---

### TC-PRM-05-02: Apply blocked when review status is rejected

**Given:** A promotion review in `rejected` status.

**When:** `handleApplyReview` is called.

**Then:** Returns HTTP 400 `INVALID_REVIEW_TRANSITION`. Review remains `rejected`.

**Layer:** integration  
**Acceptance criterion:** PRM-05 AC2.

---

### TC-PRM-05-03: Apply blocked when review status is failed

**Given:** A promotion review in `failed` status.

**When:** `handleApplyReview` is called.

**Then:** Returns HTTP 400 `INVALID_REVIEW_TRANSITION`. Review remains `failed`.

**Layer:** integration  
**Acceptance criterion:** PRM-05 AC2.

---

### TC-PRM-05-04: Apply succeeds when review status is approved

**Given:** A promotion review in `approved` status with matching digest.

**When:** `handleApplyReview` is called with correct `plan_digest`.

**Then:** Returns HTTP 200. Review transitions to `applied`.

**Layer:** integration  
**Acceptance criterion:** PRM-05 AC2 — gate passes when `status == approved`.

---

### TC-PRM-05-05: Self-approval returns HTTP 403

**Given:** A `pending_review` review where `requested_by == actor_id`.

**When:** `handleApproveReview` is called with `approved_by` equal to `requested_by`.

**Then:** Returns HTTP 403 `SELF_APPROVAL_FORBIDDEN`. Review stays `pending_review`.

**Layer:** integration  
**Acceptance criterion:** PRM-05 AC1 — "The principal recorded in requested_by cannot approve its own review."

---

### TC-PRM-05-06: Different principal can approve

**Given:** A `pending_review` review where `requested_by != approver`.

**When:** `handleApproveReview` is called by a different principal.

**Then:** Returns HTTP 200. Review transitions to `approved`, `approved_by` is set to approver.

**Layer:** integration  
**Acceptance criterion:** PRM-05 AC1 — separation of duties enforced.

---

### TC-PRM-05-07: Reject does NOT enforce self-approval restriction

**Given:** A `pending_review` review where `requested_by == rejector`.

**When:** `handleRejectReview` is called by the same principal who submitted.

**Then:** Returns HTTP 200. Review transitions to `rejected`.

**Layer:** integration  
**Acceptance criterion:** PRM-05 design note — "Reject does NOT have the same restriction."

---

### TC-PRM-05-08: Apply request body rejects unknown fields

**Given:** An `approved` review.

**When:** `handleApplyReview` is called with body `{ "plan_digest": "...", "bypass": true }`.

**Then:** Returns HTTP 422 `UNKNOWN_FIELD`. Review stays `approved`. No bypass parameter is accepted.

**Layer:** integration  
**Acceptance criterion:** PRM-05 AC3 — "no request parameter, header, flag or configuration value that bypasses the check."

---

### TC-PRM-05-09: Approve request body rejects unknown fields

**Given:** A `pending_review` review.

**When:** `handleApproveReview` is called with body `{ "plan_digest": "...", "approved_by": "...", "force_approve": true }`.

**Then:** Returns HTTP 422 `UNKNOWN_FIELD`. Review stays `pending_review`.

**Layer:** integration  
**Acceptance criterion:** PRM-05 AC3.

---

### TC-PRM-05-10: Context endpoint returns stored plan (not live recomputed)

**Given:** A `pending_review` review with `plan_digest` and `serialised_plan` stored at submit time.

**When:** `handleGetPromotionContext` is called.

**Then:** Returns the exact stored `plan_digest` and `serialised_plan`. The values match what was stored, not a live recomputation.

**Layer:** integration  
**Acceptance criterion:** PRM-05 design — "context endpoint serves stored plan, never live re-computation."

---

### TC-PRM-05-11: Digest mismatch on approve blocks transition

**Given:** A `pending_review` review with stored `plan_digest = "abc123"`.

**When:** `handleApproveReview` is called with `plan_digest = "wrong_digest"`.

**Then:** Returns HTTP 409 `PLAN_DIGEST_MISMATCH`. Review stays `pending_review`.

**Layer:** integration  
**Acceptance criterion:** PRM-03 — digest verification gates approval.

---

### TC-PRM-05-12: Digest mismatch on apply blocks transition

**Given:** An `approved` review with stored `plan_digest = "abc123"`.

**When:** `handleApplyReview` is called with `plan_digest = "wrong_digest"`.

**Then:** Returns HTTP 409 `PLAN_DIGEST_MISMATCH`. Review stays `approved`.

**Layer:** integration  
**Acceptance criterion:** PRM-03 — digest verification gates apply.
