# Test Spec: PRM-03 — Plan digest

**Requirement:** PRM-03 — The platform MUST compute a SHA-256 digest of the canonical JSON serialisation of the promotion plan at submit time, store it on the `promotion_reviews` row, and verify it on approve/apply (mismatch = HTTP 409).
**Priority:** MUST
**Test layer:** unit + integration

## Test Tier Derivation

| Dimension | Points | Notes |
|---|---|---|
| DB schema | 0 | Digests stored on existing promotion_reviews (PRM-04) |
| Tenant isolation | 0 | Digest comparison is pure |
| Transactional boundary | 0 | Pure function |
| **Total** | **0** | **Unit + integration** |

## Test Cases

### TC-PRM-03-01: Digest is deterministic — same plan produces same digest

**Given:** Two `PromotionPlan` values with identical content.

**When:** `computePlanDigest(plan_a)` and `computePlanDigest(plan_b)` are called.

**Then:** Both return the same 64-character lowercase hex string.

**Layer:** unit  
**Acceptance criterion:** PRM-03 AC — digest is deterministic over plan content.

---

### TC-PRM-03-02: Digest is canonical — keys sorted lexicographically

**Given:** A `PromotionPlan` with entries whose JSON representation keys appear in non-sorted order.

**When:** `computePlanDigest(plan)` is called.

**Then:** Returns the same digest as a plan with identical values but keys explicitly sorted: `after`, `before`, `change_kind`, `id`, `type`.

**Layer:** unit  
**Acceptance criterion:** PRM-03 canonical JSON rules — keys sorted lexicographically.

---

### TC-PRM-03-03: Different plan produces different digest

**Given:** Plan A: one entry `{type: graph_node, id: "node-1", change_kind: added, before: null, after: null}`.
Plan B: same but `id: "node-2"`.

**When:** Digests are computed for both.

**Then:** The digests differ.

**Layer:** unit  
**Acceptance criterion:** PRM-03 AC — any content difference produces a different digest.

---

### TC-PRM-03-04: Digest is 64-char lowercase hex (SHA-256 output)

**Given:** Any `PromotionPlan`.

**When:** `computePlanDigest(plan)` is called.

**Then:** The result matches regex `^[a-f0-9]{64}$`.

**Layer:** unit  
**Acceptance criterion:** PRM-03 AC — "lowercase hexadecimal, 64 characters."

---

### TC-PRM-03-05: null values included in digest

**Given:** Entry A: `before: null, after: "null"`. Entry B: `before: "null", after: null`.

**When:** Digests are computed.

**Then:** Digests differ (null is serialised as the JSON literal `null`, not the string `"null"`).

**Layer:** unit  
**Acceptance criterion:** PRM-03 canonical rules — "null values are included as the literal `null`."

---

### TC-PRM-03-06: verifyDigest returns true on match

**Given:** Stored digest `abc123...` (64 hex chars).

**When:** `verifyDigest(stored, "abc123...")` is called.

**Then:** Returns `true`.

**Layer:** unit  
**Acceptance criterion:** PRM-03 AC — "Returns true if equal."

---

### TC-PRM-03-07: verifyDigest returns false on mismatch

**Given:** Stored digest `abc123...` (64 hex chars).

**When:** `verifyDigest(stored, "def456...")` is called.

**Then:** Returns `false`.

**Layer:** unit  
**Acceptance criterion:** PRM-03 AC — mismatch triggers HTTP 409.

---

### TC-PRM-03-08: Digest stored on promotion_reviews at submit time

**Given:** A promotion plan is submitted.

**When:** `handleSubmitPromotion(...)` completes successfully.

**Then:** The `promotion_reviews` row has `plan_digest` set to the computed SHA-256 hex string, and `serialised_plan` contains the canonical JSON.

**Layer:** integration  
**Acceptance criterion:** PRM-03 AC — "digest and full serialised plan stored on promotion_reviews."

---

### TC-PRM-03-09: Approve fails with HTTP 409 on digest mismatch

**Given:** A pending review exists with stored `plan_digest`.

**When:** `handleApproveReview` is called with `plan_digest` that does not match.

**Then:** Returns HTTP 409 `PLAN_DIGEST_MISMATCH`. Review stays in `pending_review`.

**Layer:** integration  
**Acceptance criterion:** PRM-03 AC — digest mismatch blocks approval.

---

### TC-PRM-03-10: Apply fails with HTTP 409 on digest mismatch

**Given:** An approved review exists with stored `plan_digest`.

**When:** `handleApplyReview` is called with `plan_digest` that does not match.

**Then:** Returns HTTP 409 `PLAN_DIGEST_MISMATCH`. Review stays in `approved`.

**Layer:** integration  
**Acceptance criterion:** PRM-03 AC — digest mismatch blocks apply.

---

### TC-PRM-03-11: Digest comparison uses constant-time logic

**Given:** Two digests that differ in only the last character.

**When:** `verifyDigest` is called many times with varying timing.

**Then:** Response time does not reveal which byte differs (timing-safe comparison).

**Layer:** unit  
**Acceptance criterion:** PRM-03 design note — constant-time comparison to avoid timing attacks.
