# Test Spec: PRM-03 — Plan digest binds approval to a diff

**Requirement:** PRM-03 (MUST, stage 16) — The platform SHALL bind every approval to a `plan_digest`: the lowercase hexadecimal SHA-256 over the canonical JSON serialisation of the promotion plan, where canonical means object keys sorted lexicographically and no insignificant whitespace, over the entry shape `{type, id, changes}`. The digest and the full serialised plan are stored on the `promotion_reviews` row at submit time. Approve and apply both require the digest in the request body, and a mismatch is rejected with HTTP 409 `PlanDigestMismatch`.
**Priority:** MUST
**Test layer:** unit (pure digest functions) + integration (storage + approve/apply mismatch gates)
**Source under test:** `src/definition/promotion_digest.zig`, `src/api/routes/promotion_review.zig`
**Implementation file:** `tests/integration/prm03_digest_test.zig`

## Test Tier Derivation

| Dimension | Points | Notes |
|---|---|---|
| DB schema | 1 | Stores `plan_digest` + `serialised_plan` on the `promotion_reviews` row |
| Transactional boundary | 1 | Digest verified before the approve/apply transition |
| **Total** | **2** | **Unit + integration** |

## Test Cases

### TC-PRM-03-01: Digest is deterministic — two byte-identical plans produce the same digest
**Given:** Two `PromotionPlan` values with byte-identical entries.
**When:** `computePlanDigest(allocator, plan)` is called on each.
**Then:** Both produce the same 64-character string.
**Layer:** unit
**Acceptance criterion mapped:** PRM-03 AC1 (two byte-identical plans → same digest).

### TC-PRM-03-02: Digest is 64-char lowercase hexadecimal
**Given:** Any plan with at least one entry.
**When:** `computePlanDigest(allocator, plan)` is called.
**Then:** The result is exactly 64 characters, all in `[0-9a-f]`.
**Layer:** unit
**Acceptance criterion mapped:** PRM-03 AC1 (64-character lowercase hexadecimal SHA-256).

### TC-PRM-03-03: Canonical form — keys sorted lexicographically, no insignificant whitespace
**Given:** A plan entry with id `node-1`, type `graph_node`, change_kind `added`.
**When:** `serialisePlanCanonical(allocator, plan)` is called.
**Then:** The output is a compact array `[{"changes":{"after":null,"before":null,"change_kind":"added"},"id":"node-1","type":"graph_node"}]` — entry keys in order `changes,id,type` and `changes` sub-keys in order `after,before,change_kind`, no whitespace.
**Layer:** unit
**Acceptance criterion mapped:** PRM-03 canonicalisation rule (keys sorted, no insignificant whitespace, entry shape `{type,id,changes}`).

### TC-PRM-03-04: Different plans produce different digests
**Given:** Two plans differing only in one entry's `id`.
**When:** Both are digested.
**Then:** The digests differ.
**Layer:** unit
**Acceptance criterion mapped:** PRM-03 determinism/avalanche — any content change alters the digest.

### TC-PRM-03-05: `null` values are emitted as literal `null`, never omitted
**Given:** A plan entry with `before = null` and `after = null` (a pure `added` entry).
**When:** `serialisePlanCanonical` is called.
**Then:** The canonical JSON contains the literal `null` for both `before` and `after`; the digest is still 64 hex chars.
**Layer:** unit
**Acceptance criterion mapped:** PRM-03 canonical serialisation rule 4 (null values emitted, never omitted).

### TC-PRM-03-06: verifyDigest — match true, mismatch false, wrong-length false
**Given:** A valid 64-char stored digest, a different 64-char digest, and a short digest.
**When:** `verifyDigest(stored, provided)` is called for each pair.
**Then:** Returns `true` for the match, `false` for the mismatch, `false` when either length ≠ 64 (constant-time comparison gate).
**Layer:** unit
**Acceptance criterion mapped:** PRM-03 approve/apply digest gate foundation.

### TC-PRM-03-07: Approve with mismatching body digest → HTTP 409, review stays pending_review
**Given:** A pending review whose stored digest is `D`; a request body with a different digest `D'`.
**When:** `handleApproveReview(pool, alloc, actor, review_id, {"plan_digest":"D'"})` is called (actor ≠ requester).
**Then:** HTTP **409** `PLAN_DIGEST_MISMATCH`; the review remains `pending_review` (row_version unchanged).
**Layer:** integration
**Acceptance criterion mapped:** PRM-03 AC2 (approve mismatch → 409, stays pending_review).

### TC-PRM-03-08: Apply with mismatching body digest → HTTP 409, no sandbox claimed
**Given:** An approved review whose stored digest is `D`; a request body with a different digest `D'`.
**When:** `handleApplyReview(pool, alloc, actor, review_id, {"plan_digest":"D'"})` is called.
**Then:** HTTP **409** `PLAN_DIGEST_MISMATCH`; the review stays `approved`; zero `promotion_assertion_runs` rows exist for `(tenant_id, review_id)` (no sandbox claimed).
**Layer:** integration
**Acceptance criterion mapped:** PRM-03 AC3 (apply mismatch → 409, no sandbox).

### TC-PRM-03-09: Digest and serialised plan stored on promotion_reviews at submit time
**Given:** A plan is digested and submitted via `submitReview` with `tenant_id` set.
**When:** `getReview(review_id)` is called.
**Then:** The returned `ReviewRecord.plan_digest` equals the computed digest and `ReviewRecord.serialised_plan` is non-empty (the stored canonical JSON the reviewer can re-digest).
**Layer:** integration
**Acceptance criterion mapped:** PRM-03 storage rule (digest + full serialised plan stored at submit).

### TC-PRM-03-10: Source changes after approval → new digest + new review; earlier approval cannot apply the new plan
**Given:** Review A approved for digest `D1`. A second submission with a modified plan yields digest `D2` and review B (`D2 ≠ D1`).
**When:** `handleApplyReview(review_id=B, {"plan_digest":"D1"})` is attempted.
**Then:** HTTP **409** `PLAN_DIGEST_MISMATCH` — the earlier approval (bound to `D1`) cannot be applied to the new plan (`D2`). Review B remains `approved`-eligible only for `D2`.
**Layer:** integration
**Acceptance criterion mapped:** PRM-03 AC4 (new digest + new review; earlier approval cannot apply the new plan).

### TC-PRM-03-11: Context endpoint serves the stored plan (never a live re-computation)
**Given:** A pending review with stored `serialised_plan` and `plan_digest`.
**When:** `handleGetPromotionContext(review_id)` is called.
**Then:** HTTP 200; the response body contains the stored `serialised_plan` verbatim and the stored `plan_digest` (the reviewer decides on exactly the diff the digest binds).
**Layer:** integration
**Acceptance criterion mapped:** PRM-03 AC5 (context serves stored plan, never a live diff).
