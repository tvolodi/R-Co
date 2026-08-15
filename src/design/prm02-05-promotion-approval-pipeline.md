# Module: prm02-05-promotion-approval-pipeline

**Requirement IDs:** PRM-02, PRM-03, PRM-04, PRM-05
**Run ID:** WF02-prm02-05-20260816 (Stage 16)
**Step:** 01 (CODE-DESIGNER)
**Priority:** MUST (all four)
**Workflow:** PW-01 (promotion pipeline)
**Type:** Type E — prose design (PRM-04 also touches the already-landed
`promotion_reviews` migration; the schema is specified authoritatively here so
BACKEND-DEV verifies alignment with `migrations/096_promotion_reviews.sql`)

**Extends:**
- `src/definition/promotion_plan.zig` / `src/api/routes/promotions.zig` (PRM-01,
  RELEASED — `PromotionPlan`, `PlanEntry`, `computePromotionPlan()`, submit route)
- `src/design/prm-01-promotion-plan-and-diff-report.md` (PRM-01 design)
- PRM-06..PRM-09 (RELEASED — assertion re-run, read endpoint, rollback, solution pack)
- `docs/processes/system/definition-promotion.md` — Steps 4, 5, 6, 8, 9, 10, 18
- `docs/processes/system/definition-promotion.md` Business Rules — fixed step ordering
  (`reject_if_conflicts` → `require_approved_review` → assertion re-run → pointer
  move → `mark_review_applied`), conflict-first, digest-bound approval, one live
  review per digest

This artefact is the single authoritative design for the middle of the promotion
pipeline: everything between "plan computed" (PRM-01) and "assertion re-run"
(PRM-06). It supersedes the per-requirement drafts produced by the earlier
`WF02-prm-batch2-20260814` design run where they disagree with the requirement text
(see Open questions §1 for the digest entry-shape reconciliation, the one place they
do).

---

## Classification rationale

Applying `templates/lego-catalog.md` selection rules:

1. **Type C?** PRM-04 owns the `promotion_reviews` table. That migration already
   exists on the branch (`migrations/096_promotion_reviews.sql`) from the prior
   batch; this run's design specifies the target schema (columns, CHECK over the six
   statuses, the partial unique index) so BACKEND-DEV verifies 096 conforms rather
   than writing a second migration. PRM-02 and PRM-03 introduce no tables — PRM-02
   reads `process_definitions` (exists) and writes to the event store (exists);
   PRM-03 stores its digest as a column on PRM-04's table.
2. **Type A?** No new CRUD endpoint: `approve`, `reject`, `apply`, and `context`
   are coordinated multi-constraint operations, not a 1-to-1 store-method mapping.
3. **Type D / Type B?** No React Flow node, no list page.
4. **Type E — yes.** Conflict pre-flight ordering, a canonical-digest algorithm, a
   six-state machine with CHECK enforcement, and a non-skippable approval gate are
   structurally novel, cross-cutting business logic. Per the catalog: "when in
   doubt, prefer Type E."

No `zig`/`sql`/`ts` fenced blocks are used in this artefact (CODE-DESIGN-VALIDATOR
gate criterion g); signatures and schema appear as prose and tables.

---

## Module purpose

This batch turns the promotion pipeline's plan (PRM-01) into a **reviewed, bound,
gated promotion**. PRM-02 rejects a promotion before it can begin if the target
tenant has advanced past the version the source branched from. PRM-03 binds every
approval to an immutable `plan_digest` over the canonical JSON of the plan, so an
approval can never be replayed against a different diff. PRM-04 persists the whole
review lifecycle in `promotion_reviews` — six CHECK-constrained statuses, an
optimistic-lock `row_version`, and at most one live review per
`(tenant_id, plan_digest)`. PRM-05 guarantees that nothing is applied to a tenant
without an approval by a principal distinct from the requester, with **no request
parameter, header, flag, or configuration value** that bypasses the gate, and gives
the reviewer a context endpoint that serves exactly the diff the digest binds. The
four requirements together enforce the process document's fixed step ordering:
conflict pre-flight → approved review → assertion re-run → pointer move → review
marked applied.

---

## Fixed pipeline ordering (the invariant this batch guarantees)

The submit handler executes these steps in exactly this order, and no step may be
reordered or omitted (process document Business Rule: "Fixed step ordering"):

| # | Step | Owner | Failure surface |
|---|---|---|---|
| 1 | Permission + source-tenant validation | PRM-01 (RELEASED) | 403 / 422 |
| 2 | Compute the plan (read-only, no write transaction) | PRM-01 (RELEASED) | 404 / 422 |
| 3 | **Conflict pre-flight** — before any transaction opens, before the digest, before the review row | PRM-02 (this batch) | 409 `PromotionConflict` |
| 4 | Canonicalise plan + compute `plan_digest` | PRM-03 (this batch) | — |
| 5 | Insert `promotion_reviews` row (`pending_review`) | PRM-04 (this batch) | 409 `DuplicateReview` |
| 6 | Reviewer reads context (stored plan + digest + assertions + NEEDS_REVIEW) | PRM-05 (this batch) | 404 |
| 7 | Approve (`pending_review → approved`) — digest match, no self-approval | PRM-04 + PRM-05 | 400 / 403 / 409 |
| 8 | Assertion re-run in sandbox | PRM-06 (RELEASED) | → `failed` |
| 9 | Apply (`approved → applied`) — digest match, **no bypass** | PRM-04 + PRM-05 | 400 / 409 |
| 10 | Pointer move + `DEFINITION_PROMOTION_APPLIED` in the same transaction, then review `applied` | PRM-04 (this batch) | 500 |

PRM-02's own AC states the ordering contract: "The conflict check executes before
the plan digest is computed (PRM-03) and before the review row is inserted (PRM-04);
no ordering makes it run later." TEST-DESIGNER obligation: a negative assertion that
no `BEGIN` / write-intent query against the target tenant fires before step 3
completes, and that the digest and review insert happen strictly after step 3.

---

## PRM-02 — Conflict pre-flight rejection

### Purpose

Detect, as the **first step** of the promotion pipeline and **before any
transaction opens**, whether the target tenant has advanced past the version the
source was branched from. A conflict exists when `target_active_version >
base_version`. On conflict the platform returns a typed rejection naming each
conflicting definition with its source-side and target-side change, appends exactly
one `DEFINITION_PROMOTION_REJECTED` event in its own transaction, and moves no
version pointer.

### Public interface (prose signatures)

- `ConflictRejection` — struct with `target_definition_id` (uuid text), `target_version`
  (u32), `source_change` (text, e.g. "branched from version 1"), `target_change`
  (text, e.g. "target is now at version 3").
- `rejectIfConflicts(allocator, pool, target_tenant_id, process_key, base_version, promotion_id, source_tenant_id, actor_id)`
  → `ConflictCheckError!?ConflictRejection`. Returns `null` (no conflict) or a
  populated `ConflictRejection` after appending the rejection event.
- `rejectIfConflictsMulti(allocator, pool, target_tenant_id, process_keys, base_versions, promotion_id, source_tenant_id, actor_id)`
  → `ConflictCheckError![]const ConflictRejection`. Collects one rejection per
  conflicting `process_key` so the 409 body can name **each** conflicting
  definition (PRM-02 AC1: "naming each conflicting definition").
- `ConflictCheckError` — `PoolExhausted`, `TransactionFailed`.

### Conflict condition and ordering guarantee

- `conflict = (target_active_version > base_version)`, where `target_active_version`
  is read from `process_definitions` in the target tenant for the given `process_key`
  with `status = 'ACTIVE'`. Zero rows on the target → no conflict (the plan is
  all-`added`, PRM-01 AC2, handled upstream).
- The active-version read is a **plain read with no lock** (`no FOR UPDATE`) and
  runs **outside** any transaction that will later write to the target tenant. At
  the moment the conflict is raised, the rejection path holds **no transaction open
  against the target tenant schema** (PRM-02 AC4).
- On conflict: the `DEFINITION_PROMOTION_REJECTED` event is appended in its own
  **independent, platform-scoped** transaction (event store `events` +
  `plat_event_idempotency` for ES-03 idempotency), with idempotency key
  `DEFINITION_PROMOTION_REJECTED-<promotion_id>` where `promotion_id` is a synthetic
  UUID generated at submit time. Exactly one event is appended (PRM-02 AC2).
- No `promotion_reviews` row and no `promotion_assertion_runs` row is created on a
  conflict (PRM-02 AC3) — the handler returns before step 5 of the pipeline order.

### HTTP contract

`POST /api/v1/promotions` with a conflict → HTTP **409** `PROMOTION_CONFLICT`,
body listing one conflict object per conflicting definition:

```json
{
  "error": "PROMOTION_CONFLICT",
  "message": "Target tenant has advanced past base_version",
  "conflicts": [
    {
      "process_key": "<process_key>",
      "target_definition_id": "<uuid>",
      "target_version": 3,
      "source_change": "branched from version 1",
      "target_change": "target is now at version 3"
    }
  ]
}
```

### Acceptance-criterion mapping

| PRM-02 AC | Design element |
|---|---|
| 409 `PromotionConflict` body listing `{definition_id, source_change, target_change}` per conflict | `rejectIfConflictsMulti` + 409 body shape above |
| Exactly one `DEFINITION_PROMOTION_REJECTED` event; target active pointer unchanged | Event append in its own transaction; no pointer write anywhere on this path |
| No `promotion_reviews` / `promotion_assertion_runs` row on conflict | Handler returns 409 before review insert (pipeline step 5) |
| Rejection path holds no transaction open against the target tenant schema | Lock-free read + independent platform-scoped event transaction |
| Conflict check runs before digest (PRM-03) and before review row (PRM-04) | Fixed pipeline ordering (step 3 before steps 4–5) |

---

## PRM-03 — Plan digest binds approval to a diff

### Purpose

Bind every approval to a `plan_digest`: the lowercase hexadecimal SHA-256 over the
canonical JSON serialisation of the promotion plan. The digest and the full
serialised plan are stored on the `promotion_reviews` row at submit time. Approve
and apply both require the digest in the request body; a mismatch is rejected with
HTTP 409 `PlanDigestMismatch`.

### Canonical JSON serialisation algorithm

The digest is computed over a JSON **array of plan entries**, where each entry is a
JSON object with exactly the keys `type`, `id`, `changes` (requirement entry shape
`{type, id, changes}`). Canonical means:

1. Object keys sorted lexicographically, ascending by Unicode code point. For the
   entry object this yields the key order `changes`, `id`, `type`.
2. No insignificant whitespace — no spaces after `:`, no spaces after `,`, no
   newlines or indentation. Compact form throughout.
3. UTF-8 encoded.
4. `null` values are emitted as the literal `null`, never omitted.

The `changes` value is itself a compact JSON object with keys sorted
lexicographically (`after`, `before`, `change_kind`) describing the change for that
entry: `change_kind` in `added` / `modified` / `removed`, with `before` / `after`
carrying the JSON-serialised prior/new state (`null` for `added` / `removed`
respectively). This maps PRM-01's `PlanEntry` fields (`type`, `id`, `change_kind`,
`before`, `after`) deterministically into the requirement's `{type, id, changes}`
entry shape. The digest bytes are the SHA-256 of the resulting UTF-8 array text;
the digest string is the 64-character lowercase hexadecimal form.

Determinism: two byte-identical plans produce the same digest; any difference in
plan content (including whitespace or key order) changes the digest.

### Public interface (prose signatures)

- `computePlanDigest(allocator, plan)` → `[]const u8` (64-char lowercase hex,
  caller-owned). Computes at **submit time** only.
- `verifyDigest(stored, provided)` → `bool`. Compares the request-body digest with
  the stored digest using **constant-time comparison** (both must be 64 chars).
  Used at approve and apply; the stored value is compared, never recomputed.

### Digest-binding rules

- At submit: digest + full serialised plan are stored on the review row
  (pipeline step 4 → 5).
- At approve: body digest must equal stored digest, else HTTP 409 `PlanDigestMismatch`
  and the review remains `pending_review` (PRM-03 AC2).
- At apply: body digest must equal stored digest, else HTTP 409 `PlanDigestMismatch`
  and **no sandbox is claimed** (PRM-03 AC3).
- When the source definition changes after an approval, a **new** submission
  computes a **new** plan → **new** digest → **new** review row; the earlier
  approval is bound to the old digest and cannot be applied to the new plan
  (PRM-03 AC4) — cross-application is impossible because apply verifies the body
  digest against the stored digest of the row being applied.
- The reviewer context endpoint serves the plan **stored at submit time** and never
  re-computes a live diff (PRM-03 AC5; PRM-05 context contract below).

### Acceptance-criterion mapping

| PRM-03 AC | Design element |
|---|---|
| Two byte-identical plans → same 64-char lowercase hex | Canonical serialisation + SHA-256, deterministic by construction |
| Approve with mismatching body digest → 409, stays `pending_review` | `verifyDigest` in approve gate before any transition |
| Apply with mismatching body digest → 409, no sandbox claimed | `verifyDigest` in apply gate before any transition or sandbox claim |
| Source changes after approval → new digest + new review; earlier approval cannot apply the new plan | Digest stored per review row; apply verifies body digest against that row's stored digest |
| Context endpoint serves the stored plan, never a live diff | `GET .../context` reads `serialised_plan` / `plan_digest` from the review row |

---

## PRM-04 — Promotion review state machine

### Purpose

Persist promotion approvals in a `promotion_reviews` table — the central state
machine of the promotion pipeline. It records who requested a promotion, what plan
(digest) was approved, who approved it, and whether it has been applied, rejected,
failed, or superseded. Every transition is ACID; `status` is CHECK-constrained to
exactly six values; the partial unique index guarantees at most one **live** review
per `(tenant_id, plan_digest)`.

### Schema (target — verify `migrations/096_promotion_reviews.sql` conforms)

| Column | Type | Constraint / default |
|---|---|---|
| `id` | uuid | PRIMARY KEY, default `gen_random_uuid()` |
| `tenant_id` | uuid | NOT NULL |
| `plan_digest` | text | NOT NULL — 64-char lowercase hex (PRM-03) |
| `def_type` | text | NOT NULL — `process` for now; extensible |
| `def_id` | text | NOT NULL — `process_key` |
| `serialised_plan` | text | NOT NULL — full canonical JSON plan stored at submit (PRM-03) |
| `status` | text | NOT NULL default `pending_review`; CHECK over exactly six values |
| `requested_by` | uuid | NOT NULL — submitting principal |
| `approved_by` | uuid | nullable — set on `pending_review → approved` |
| `approved_at` | timestamptz | nullable — set on approval |
| `superseded_by` | uuid | nullable — review_id that superseded this one |
| `row_version` | integer | NOT NULL default 1 — optimistic lock |
| `created_at` / `updated_at` | timestamptz | NOT NULL default `now()`; `updated_at` refreshed on every transition |

Constraints and indexes:

- CHECK constraint `chk_promotion_reviews_status` over the six status values
  `pending_review`, `approved`, `rejected`, `applied`, `failed`, `superseded`.
- **Partial unique index** `promotion_reviews_plan_digest_active_uniq` on
  `(tenant_id, plan_digest)` `WHERE status IN ('pending_review','approved')` — at
  most one live review per digest per tenant; a second same-digest submission
  violates it → HTTP 409 `DuplicateReview` (PRM-04 AC2).
- Supporting indexes: `(tenant_id)`, `(status)`, `(requested_by)`, and a partial
  `(tenant_id, status)` index for `applied`/`superseded` lookups (PRM-08 rollback).

### State machine

Six statuses; permitted transitions:

| From | To | Trigger |
|---|---|---|
| `pending_review` | `approved` | approve — PRM-04 AC1 |
| `pending_review` | `rejected` | reject |
| `pending_review` | `superseded` | superseded by a later review of the same digest |
| `approved` | `applied` | apply + pointer move — PRM-04 AC4 |
| `approved` | `failed` | assertion re-run failure — PRM-04 AC3 |
| `approved` | `superseded` | superseded by a later review |
| `applied` | `superseded` | PRM-08 rollback / PRM-09 supersession |
| `failed` | `superseded` | PRM-08 rollback / PRM-09 supersession |
| `rejected` | `superseded` | superseded by a later review of the same definition |

A transition outside this edge set is rejected twice: at the database by the CHECK
constraint (the constraint is on the status **value set**, and the transition
functions additionally guard the source status) and at the API with HTTP 400
`InvalidReviewTransition` (PRM-04 AC5).

### Public interface (prose signatures)

- `ReviewStatus` — enum over the six values.
- `ReviewRecord` — row projection (id, tenant_id, plan_digest, def_type, def_id,
  serialised_plan, status, requested_by, approved_by?, approved_at?, superseded_by?,
  row_version, created_at, updated_at).
- `SubmitReviewParams` — `{tenant_id, plan_digest, def_type, def_id,
  serialised_plan, requested_by}`.
- `ReviewTransitionError` — `InvalidReviewTransition`, `DuplicateReview`,
  `PoolExhausted`, `TransactionFailed`, `OutOfMemory`.
- `submitReview(allocator, pool, params)` → `![]const u8` (new review_id).
  INSERT with `status='pending_review'`, `row_version=1`; partial-unique-index
  violation → `DuplicateReview`.
- `approveReview(allocator, pool, review_id, actor_id, expected_row_version)` —
  `pending_review → approved`; sets `approved_by`, `approved_at`, bumps
  `row_version`; `WHERE row_version = $expected` (optimistic lock); zero rows →
  `InvalidReviewTransition`. Appends `DEFINITION_PROMOTION_APPROVED` per process
  document Step 10 (see reconciliation note in Open questions §3).
- `rejectReview(allocator, pool, review_id, expected_row_version)` —
  `pending_review → rejected`; optimistic-locked.
- `markReviewApplied(allocator, pool, review_id, expected_row_version)` —
  `approved → applied`. PRM-04 AC4 requires `DEFINITION_PROMOTION_APPLIED` (carrying
  `plan_digest` and the new `definition_id`) to be appended **in the same
  transaction** as the version-pointer move (see Open questions §3 for the current
  implementation gap).
- `markReviewFailed(allocator, pool, review_id, expected_row_version)` —
  `approved → failed`, invoked by the PRM-06 assertion re-run failure path.
- `supersedeReview(allocator, pool, review_id, superseding_review_id, expected_row_version)`
  — `→ superseded`, records `superseded_by`.
- `getReview(allocator, pool, review_id)` → `!?ReviewRecord` — read used by the
  approve/reject/apply gates and the context endpoint.

### Optimistic locking

Every transition UPDATE includes `WHERE id = $id AND row_version = $expected` and
bumps `row_version = row_version + 1`. Zero rows updated ⇒ `InvalidReviewTransition`
(concurrent update or stale read). `row_version` is monotonic, never decremented.

### Acceptance-criterion mapping

| PRM-04 AC | Design element |
|---|---|
| `pending_review → approved` sets `approved_by`/`approved_at`; any other source status → 400 | `approveReview` + gate (status check + `InvalidReviewTransition`) |
| Live review for `(tenant_id, plan_digest)` + same-digest resubmission → 409 | `submitReview` + partial unique index |
| `approved → failed` on assertion re-run failure | `markReviewFailed` called by PRM-06 failure path |
| Apply: `approved → applied` + `DEFINITION_PROMOTION_APPLIED` in the same transaction as the pointer move | `markReviewApplied` within the apply transaction |
| Transition outside the edge set rejected by CHECK at DB and 400 at API | Six-value CHECK + guarded transition functions |

---

## PRM-05 — Non-skippable human approval gate

### Purpose

Require an **approved** review before any promotion is applied, with no request
parameter, header, flag, or configuration value that bypasses the check. The
principal in `requested_by` cannot approve its own review. The context endpoint
serves the stored plan, the assertions carried by the artifact, the `NEEDS_REVIEW`
package, and the `plan_digest`, so the reviewer decides on exactly the diff the
digest binds.

### Apply gate (non-skippable)

`POST /api/v1/promotions/{id}/apply`:

- Request body has **exactly one** field: `{ "plan_digest": "<64-hex>" }`. Any
  unknown field in the body → HTTP 422 `UNKNOWN_FIELD` (PRM-05 AC3) — there is no
  skip field in the schema.
- Gate 1 — status must be `approved`: otherwise HTTP 400 `InvalidReviewTransition`
  and **no sandbox is claimed** (PRM-05 AC1).
- Gate 2 — body digest must equal the stored digest: otherwise HTTP 409
  `PlanDigestMismatch` (PRM-03 AC3).
- No `Authorization`-header flag, no `X-Skip-*` header, no query parameter, and no
  configuration value can bypass gate 1. Enforced structurally: the apply handler
  performs the status check before any further action and the request schema admits
  no bypass field.

### Approve gate

`POST /api/v1/promotions/{id}/approve` — request body `{ "plan_digest",
"approved_by" }`; any unknown field → 422 `UNKNOWN_FIELD`:

- Gate 1 — `approved_by != requested_by`: self-approval → HTTP 403
  `SELF_APPROVAL_FORBIDDEN`, review remains `pending_review` (PRM-05 AC2).
  Rejection carries no such restriction (a submitter may reject their own request;
  separation of duties is about approval).
- Gate 2 — status must be `pending_review`: otherwise HTTP 400
  `InvalidReviewTransition`.
- Gate 3 — body digest must equal the stored digest: otherwise HTTP 409
  `PlanDigestMismatch`, review remains `pending_review`.

### Context endpoint contract

`GET /api/v1/promotions/{id}/context` returns, in **one document** (PRM-05 AC5):

| Field | Source | Notes |
|---|---|---|
| `review_id` | `promotion_reviews.id` | |
| `plan_digest` | `promotion_reviews.plan_digest` | digest of the **stored** plan |
| `serialised_plan` | `promotion_reviews.serialised_plan` | canonical JSON stored at submit; reviewer can recompute the digest over it to confirm binding |
| `assertions[]` | artifact lookup | assertions carried by the promotion artifact (PRM-06) |
| `needs_review_package` | artifact lookup | the `NEEDS_REVIEW` package (PRM-06 artifact metadata) |
| `status`, `requested_by`, `def_type`, `def_id`, `created_at`, `row_version` | `promotion_reviews` | review metadata |

**Stored-data semantics:** every field comes from the stored review row or the
artifact, never from a live re-computation of the diff (PRM-03 AC5). The reviewer
decides on exactly the diff the digest binds.

### Pre-vetted template entry point

PRM-05 AC4: a pre-vetted platform-published template installed during provisioning
must reach the target tenant through a **separate entry point that never calls
apply** — not through a bypass flag on apply. The separation is at the API
routing/provisioning level (a distinct promotion path), never a conditional bypass
inside the apply handler. See Open questions §4.

### Acceptance-criterion mapping

| PRM-05 AC | Design element |
|---|---|
| Apply with status != `approved` → 400, no sandbox claimed | Apply gate 1 (status check before any action) |
| Approve with principal == `requested_by` → 403, stays `pending_review` | Approve gate 1 (`SelfApprovalForbidden`) |
| Unrecognised body field on approve/apply → 422; no skip field exists | Strict request-schema validation (`UNKNOWN_FIELD`) on both handlers |
| Pre-vetted template → separate entry point, never calls apply | Routing-level separation; no bypass flag |
| Context response has plan + `assertions[]` + `NEEDS_REVIEW` package + `plan_digest` in one document | Context endpoint contract above |

---

## Data flow — multi-step promotion flow (sequence diagram)

```mermaid
sequenceDiagram
    participant A as Authoring Agent (submitter)
    participant R as Reviewer (approver)
    participant P as BPM Platform
    participant T as Target tenant
    participant S as Sandbox (PRM-06)

    A->>P: POST /api/v1/promotions {source, target, process_key, base_version}
    P->>P: 1. computePromotionPlan (PRM-01, read-only)
    P->>P: 2. rejectIfConflicts (PRM-02) before any txn opens
    alt conflict (target_active > base_version)
        P->>P: append DEFINITION_PROMOTION_REJECTED (own txn)
        P-->>A: 409 PROMOTION_CONFLICT (per-definition body)
    else no conflict
        P->>P: 3. computePlanDigest over canonical {type,id,changes} (PRM-03)
        P->>T: 4. INSERT promotion_reviews (pending_review) (PRM-04)
        P-->>A: 201 {review_id, plan_digest}
        R->>P: GET /api/v1/promotions/{id}/context (PRM-05)
        P-->>R: stored plan + digest + assertions[] + NEEDS_REVIEW
        R->>P: POST .../{id}/approve {plan_digest, approved_by}
        P->>P: gates: no self-approval, status, digest match (PRM-04/05)
        P->>P: pending_review -> approved; append DEFINITION_PROMOTION_APPROVED
        P-->>R: 200 {status: approved}
        P->>S: 5. assertion re-run (PRM-06, released)
        alt re-run fails
            P->>P: approved -> failed (PRM-04)
        else re-run passes
            A->>P: POST .../{id}/apply {plan_digest}
            P->>P: gate: status == approved (NO bypass), digest match (PRM-05)
            P->>T: 6. move version pointer
            P->>P: append DEFINITION_PROMOTION_APPLIED in same txn; approved -> applied (PRM-04)
            P-->>A: 200 {status: applied, definition_id, version, plan_digest}
        end
    end
```

---

## Public interface summary (consolidated)

All signatures are specified in prose above; this is the index.

- **PRM-02 (conflict):** `ConflictRejection`, `rejectIfConflicts`,
  `rejectIfConflictsMulti`, `ConflictCheckError`.
- **PRM-03 (digest):** `computePlanDigest`, `verifyDigest`.
- **PRM-04 (review state machine):** `ReviewStatus`, `ReviewRecord`,
  `SubmitReviewParams`, `ReviewTransitionError`, `submitReview`, `approveReview`,
  `rejectReview`, `markReviewApplied`, `markReviewFailed`, `supersedeReview`,
  `getReview`.
- **PRM-05 (gate):** self-approval check (`approved_by != requested_by`), apply
  status gate (`status == approved`), strict request-schema validation
  (`UNKNOWN_FIELD` → 422), `getPromotionContext` (context endpoint contract).
- **HTTP routes (all under `POST /api/v1/promotions` family):**
  `POST /api/v1/promotions` (submit — PRM-01..04), `GET /api/v1/promotions/{id}/context`
  (PRM-05), `POST /api/v1/promotions/{id}/approve` (PRM-04/05),
  `POST /api/v1/promotions/{id}/reject` (PRM-04), `POST /api/v1/promotions/{id}/apply`
  (PRM-04/05).

---

## Error taxonomy (consolidated)

| Error | Trigger | HTTP | Code |
|---|---|---|---|
| `Forbidden` | Caller lacks `promotion.submit` (PRM-01) | 403 | `FORBIDDEN` |
| `InvalidPromotionSource` | `source_tenant_id` is a production tenant (PRM-01) | 422 | `INVALID_PROMOTION_SOURCE` |
| `EmptyPromotionPlan` | Source == target after canonicalisation (PRM-01) | 422 | `EMPTY_PROMOTION_PLAN` |
| `SourceDefinitionNotFound` | No ACTIVE source definition (PRM-01) | 404 | `SOURCE_DEFINITION_NOT_FOUND` |
| `ConflictRejection` | Target active version > `base_version` (PRM-02) | 409 | `PROMOTION_CONFLICT` |
| `PlanDigestMismatch` | Approve/apply body digest != stored digest (PRM-03) | 409 | `PLAN_DIGEST_MISMATCH` |
| `InvalidReviewTransition` | Transition outside the edge set, or wrong `row_version` (PRM-04/05) | 400 | `INVALID_REVIEW_TRANSITION` |
| `DuplicateReview` | Live review already exists for `(tenant_id, plan_digest)` (PRM-04) | 409 | `DUPLICATE_REVIEW` |
| `SelfApprovalForbidden` | Approver == `requested_by` (PRM-05) | 403 | `SELF_APPROVAL_FORBIDDEN` |
| `UnknownField` | Unknown field in approve/apply body (PRM-05 AC3) | 422 | `UNKNOWN_FIELD` |
| `InvalidInput` | Missing/invalid required body field | 422 | `INVALID_INPUT` |
| `MalformedJson` | Body is not valid JSON | 400 | `MALFORMED_JSON` |
| `ReviewNotFound` | `{id}` names no review row | 404 | `REVIEW_NOT_FOUND` |
| `PoolExhausted` | Cannot acquire DB connection | 503 | `SERVICE_UNAVAILABLE` |
| `TransactionFailed` / `OutOfMemory` | Event append, UPDATE, or allocator failure | 500 | `INTERNAL_ERROR` |

---

## Dependencies

| Module | Depends on | Must NOT depend on |
|---|---|---|
| PRM-02 conflict | `process_definitions` (exists); event store (`events`, `plat_event_idempotency`); `computePromotionPlan` output (PRM-01); `base_version` from submit body | `promotion_reviews` / `promotion_assertion_runs` (created later in the pipeline) |
| PRM-03 digest | `PromotionPlan` / `PlanEntry` types (PRM-01); `std.crypto.hash.sha2.Sha256`; stored digest on `promotion_reviews` (PRM-04) | Any schema decision about how `serialised_plan` is stored (PRM-04's concern) |
| PRM-04 review | `promotion_reviews` (migration 096); event store for `DEFINITION_PROMOTION_APPROVED` / `DEFINITION_PROMOTION_APPLIED`; PRM-06 failure path (calls `markReviewFailed`) | No new graph/definition logic — it consumes the plan, never recomputes it |
| PRM-05 gate | `promotion_reviews` (status/digest/requested_by); artifact lookup for `assertions[]` / `NEEDS_REVIEW` (PRM-06); `computePlanDigest` for reviewer self-verification | Any bypass mechanism anywhere in the codebase |

No circular dependencies introduced: PRM-02 → PRM-03 → PRM-04 → PRM-05 is a strict
consumer chain over PRM-01's plan and PRM-06's artifact.

---

## Open questions

1. **Digest canonical entry shape — requirement says `{type, id, changes}`; the
   existing implementation digests a different shape.** The requirement text and
   the process document (Step 5) both name the canonical entry shape `{type, id,
   changes}`. The earlier `WF02-prm-batch2-20260814` design and the current
   `promotion_digest.zig` implement a five-key shape
   (`after`, `before`, `change_kind`, `id`, `type`). This artefact designs to the
   requirement's canonical entry shape `{type, id, changes}` with `changes` =
   `{change_kind, before, after}` (keys sorted). BACKEND-DEV must reconcile the
   digest computation to this canonical form; the PRM-03 ACs (determinism, mismatch
   rejection) are satisfied by either shape, so the reconciliation is about
   conforming to the requirement's named shape. If REQ-ANALYST intended `changes`
   to be a plain string (`added`/`modified`/`removed`) rather than the
   `{change_kind, before, after}` object, the canonical algorithm above changes in
   one place — flagged so the interpretation is explicit, not silent.
2. **Context endpoint `assertions[]` and `NEEDS_REVIEW` package require an artifact
   lookup.** PRM-05 AC5 mandates them in the context response, but the submit body
   in the current implementation (`source_tenant_id`, `target_tenant_id`,
   `process_key`, `base_version`) carries no `artifact_id`. The process document's
   Inputs table names `artifact_id` at submission. BACKEND-DEV must confirm whether
   `artifact_id` is added to the submit body (and stored on the review row) so the
   context endpoint can serve `assertions[]` and the `NEEDS_REVIEW` package, or
   whether the artifact is resolved another way. The current context handler omits
   these two fields and must be extended.
3. **Event appends on approve and apply.** The process document Step 10 requires
   `DEFINITION_PROMOTION_APPROVED` on approve, and PRM-04 AC4 requires
   `DEFINITION_PROMOTION_APPLIED` appended in the same transaction as the
   version-pointer move. The current `approveReview` / `markReviewApplied`
   implementations only flip `status`. BACKEND-DEV must add the event appends in
   the same transactions to conform (PRM-04 AC4 is a hard requirement).
4. **Pre-vetted template entry point (PRM-05 AC4).** A separate entry point that
   never calls apply must exist for platform-published templates installed during
   provisioning. This is a routing/provisioning-level separation. REQ-ANALYST /
   ORCH to confirm where that entry point lives (e.g. a provisioning-time install
   route) so no bypass flag is ever introduced on apply.
5. **`superseded` edge callers.** The `pending_review → superseded`,
   `applied → superseded`, `failed → superseded`, and `rejected → superseded` edges
   exist in the state machine but the concrete callers (new submission advancing a
   digest, PRM-08 rollback, PRM-09 supersession) live outside this batch's ACs.
   `supersedeReview` must exist and be reachable; wiring the callers is confirmed
   with PRM-08/PRM-09 (RELEASED) during implementation.
6. **Requirement status remains DRAFT while implementation exists on main.**
   PRM-02..PRM-05 are still `DRAFT` in `docs/requirements.yaml` although prior
   batch work (migration 096, `promotion_*` source) is on `main`. Releasing the
   status is ORCH / DOC-UPDATER's concern at the end of this run, not a design
   blocker — noted here so the discrepancy is visible.
