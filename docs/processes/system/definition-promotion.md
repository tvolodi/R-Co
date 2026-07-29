# Process: Definition Promotion

| Field | Value |
|-------|-------|
| Process ID | `sys-definition-promotion` |
| Owner | Platform Admin / Authoring Agent |
| Scope | System-wide (test tenant -> production tenant) |
| Platform Workflow | PW-01 |
| Requirements | PRM-01, PRM-02, PRM-03, PRM-04, PRM-05, PRM-06, PRM-07, PRM-08, PRM-09 |
| Source | `docs/workflows.yaml` (PW-01) - `docs/Audit-Reports/Borrowing_From_ASCOA-GO.20260729.md` §2.1, §2.10 (FR-TPL-3, FR-TPL-5) |

## Summary

Moves a definition version from a test tenant into a production tenant through a
fixed, non-skippable ordering: conflict pre-flight, human approval bound to a
`plan_digest`, pre-promotion assertion re-run in an ephemeral sandbox, active
version pointer move, review closure. R-Co is event-sourced, so promotion
carries no DDL: the promotion is an append to the target tenant's event log plus
a move of the active version pointer, and rollback is the reverse pointer move.

---

## Roles

| Role | Actor | Responsibility |
|------|-------|----------------|
| Authoring Agent | Agent identity (`src/oidc`) | Submits a promotion plan for review; carries assertions and fixtures in the artifact |
| Platform Admin | Human reviewer | Reads the serialised plan and approves or rejects it; triggers apply and rollback |
| BPM Platform | System | Computes the plan, detects conflicts, enforces the gate, moves the version pointer |
| Sandbox Runner | System | Claims the ephemeral sandbox, loads fixtures, replays assertions, releases the sandbox |
| Instance Executor | System | Continues in-flight instances on their pinned snapshot across the pointer move |

---

## Inputs

| Input | Type | Constraints |
|-------|------|-------------|
| `source_tenant_id` | UUID | Must be a test tenant (ENV-03); production source is rejected |
| `target_tenant_id` | UUID | Must be an active production tenant |
| `process_key` | string | Must exist in the source tenant with at least one `active` version |
| `source_version` | integer | The version being promoted |
| `base_version` | integer | Target-tenant version the source branched from; drives conflict detection |
| `artifact_id` | UUID | Content-addressed artifact carrying `assertions[]`, `fixtures[]`, `rng_seed` |
| `plan_digest` | hex(64) | Supplied on approve and on apply; must equal the stored digest |

---

## Steps

| # | Actor | Action | Decision | Outcome | Requirement |
|---|-------|--------|----------|---------|-------------|
| 1 | Authoring Agent | `POST /api/v1/promotions` with source, target, `process_key`, `artifact_id` | Caller holds `promotion.submit` and an agent realm role? | -> 403 Forbidden if not | PRM-01 |
| 2 | Platform | Compute the promotion plan: diff source against target for graph JSON, variable schema, service catalog bindings, `module_ref` resolutions, permission rules | Target has no version of `process_key`? | Every plan entry is recorded as `added` | PRM-01 |
| 3 | Platform | Render the plan as a human-readable change list, one entry per `{type, id, changes}` | Plan is empty? | -> 422 `EmptyPromotionPlan`; nothing to promote | PRM-01 |
| 4 | Platform | Run `reject_if_conflicts` as pre-flight, before any transaction opens | Target active version > `base_version`? | -> 409 Conflict with a typed `ConflictRejection` body naming each conflicting definition; one `DEFINITION_PROMOTION_REJECTED` event appended in its own transaction; no version pointer moves | PRM-02 |
| 5 | Platform | Canonicalise the plan to JSON with sorted keys and no insignificant whitespace, then compute `plan_digest` = SHA-256 over `{type, id, changes}` | -- | `plan_digest` returned to the caller and stored on the review | PRM-03 |
| 6 | Platform | Insert into `promotion_reviews` with `status = pending_review` and the full serialised plan | A row exists for the same `(tenant_id, plan_digest)` in `pending_review` or `approved`? | -> 409 Conflict from the partial unique index `promotion_reviews_plan_digest_active_uniq` | PRM-04 |
| 7 | Platform Admin | `GET /api/v1/promotions/{id}/context` to read the serialised plan, the carried assertions, and the `NEEDS_REVIEW` package | Context is served from the stored plan, never from a live re-diff | Reviewer sees exactly the diff the digest binds | PRM-05 |
| 8 | Platform Admin | `POST /api/v1/promotions/{id}/approve` with `plan_digest` in the body | Caller is the submitting principal? | -> 403 Forbidden; submit and approve are separated principals | PRM-05 |
| 9 | Platform | Compare the body `plan_digest` against the stored `plan_digest` | Digests differ? | -> 409 `PlanDigestMismatch`; an approval cannot be replayed against a different diff | PRM-03 |
| 10 | Platform | Transition `pending_review` -> `approved`, record `approved_by` and `approved_at`, append `DEFINITION_PROMOTION_APPROVED` | Review not in `pending_review`? | -> 400 Invalid state transition | PRM-04 |
| 11 | Platform Admin | `POST /api/v1/promotions/{id}/apply` | `require_approved_review`: status is `approved`? | -> 400; no request parameter, header, flag or config value skips this check | PRM-05 |
| 12 | Platform | Write `promotion_assertion_runs` with `UNIQUE (tenant_id, idempotency_key)`, key `promotion_rerun:<review_id>:<plan_digest>` | Key already present? | Return the recorded outcome; no second sandbox is claimed | PRM-06 |
| 13 | Sandbox Runner | Claim an ephemeral sandbox seeded from the promotion-candidate definitions | No sandbox free within 60 s? | -> 503 `SandboxUnavailable`; review stays `approved` and apply is retryable | PRM-06 |
| 14 | Sandbox Runner | Load only the artifact's `fixtures[]` into the sandbox; test-tenant organic data is never copied | Fixture set missing or unreadable? | -> 422 `FixtureLoadFailed`; run status `failed` | PRM-06 |
| 15 | Sandbox Runner | Replay every carried assertion under a frozen clock, seeded RNG from `artifact.rng_seed`, and the stub effect recorder; strip `non_deterministic_fields` before comparison | Any assertion fails? | Run status `failed`; review `approved` -> `failed`; -> 422 listing the failing assertion IDs; no version pointer moves | PRM-06 |
| 16 | Platform | Release the sandbox on every exit path, including assertion failure, infrastructure failure and panic (`defer`) | Release fails? | Append `PROMOTION_ASSERTION_TEARDOWN_FAILED`; set run status `teardown_failed`; promotion continues | PRM-07 |
| 17 | Platform | Append the promoted definition version to the target tenant's event log and move the active version pointer for `process_key` | A prior active version exists? | Prior version -> `superseded`; in-flight instances continue on their pinned snapshot (PD-08) | PRM-08 |
| 18 | Platform | `mark_review_applied`: `approved` -> `applied`; append `DEFINITION_PROMOTION_APPLIED` carrying `plan_digest` and the new `definition_id` | -- | -> 200 with `definition_id`, `version`, `plan_digest` | PRM-04 |
| 19 | Platform Admin | `POST /api/v1/definitions/{process_key}/rollback` with the target version | Was that version ever active in this tenant? | -> 422 `VersionNeverActive` if not | PRM-08 |
| 20 | Platform | Move the active version pointer back and append `DEFINITION_VERSION_ROLLED_BACK` | -- | No DDL runs; rollback completes as a pointer move; the rolled-back review row -> `superseded` | PRM-08 |
| 21 | Tenant Admin | `POST /api/v1/solution-packs/{pack_id}/updates` naming the offered version | Was an earlier version of this pack installed in this tenant? | -> 404 `PackNotInstalled` if not | PRM-09 |
| 22 | Platform | Compare base (the artefacts as the earlier version installed them), theirs (the tenant's current artefacts) and incoming, classifying each artefact `unchanged`, `clean_update`, `local_only` or `conflict` | Is the install record for the earlier version present? | -> Every held artefact is classified `conflict` when no base form exists, because the platform cannot prove the tenant did not modify it | PRM-09 |
| 23 | Tenant Admin | Record a resolution of `keep_local`, `take_incoming` or `merged` against each `conflict` artefact | Does every `conflict` artefact carry a resolution? | -> 409 `UnresolvedTemplateConflict` naming the first unresolved artefact | PRM-09 |
| 24 | Platform | Emit the resolved update as one promotion plan and route it into step 1 of this process | -- | The update passes the same conflict pre-flight, approval gate and assertion re-run as any other change | PRM-09, PRM-01 |

---

## Business Rules

| Rule | Detail |
|------|--------|
| Fixed step ordering | `reject_if_conflicts` -> `require_approved_review` -> assertion re-run -> pointer move -> `mark_review_applied`. No step may be reordered or omitted |
| Conflict check runs first | The conflict pre-flight executes before any transaction opens, so a rejected promotion holds no locks and writes only its rejection event |
| Approval is digest-bound | Approval applies to one `plan_digest`. Any change to the plan produces a new digest and requires a new review |
| Gate is non-skippable | There is no bypass parameter. Pre-vetted platform templates use a separate entry point that never reaches `apply`, rather than a skip flag |
| Separation of duties | The principal that submits a review cannot approve it |
| Review state machine | `pending_review`, `approved`, `rejected`, `applied`, `failed`, `superseded`. Permitted edges: pending_review -> approved, pending_review -> rejected, pending_review -> superseded, approved -> applied, approved -> failed, approved -> superseded |
| One live review per digest | Partial unique index over `(tenant_id, plan_digest)` where `status IN ('pending_review','approved')` |
| Fixtures only | The assertion re-run reads the artifact's fixture set. Reading test-tenant organic data in the sandbox is a defect, not a fallback |
| Determinism | Frozen clock, seeded RNG and stub effects are set before the first assertion runs; `non_deterministic_fields` are stripped before comparison |
| Teardown never blocks | A sandbox release failure is recorded and surfaced to the operator; it never converts a passing promotion into a failure |
| Promotion carries no DDL | The platform is event-sourced. A promotion appends events and moves a pointer; it does not alter table structure |
| Rollback is a pointer move | Rollback re-points the active version. Instances started before the rollback keep their pinned snapshot and are unaffected |
| Pack updates never overwrite silently | A solution pack update is a three-way comparison against the recorded install base. An artefact both the tenant and the pack changed is a `conflict` and is not applied until a resolution is recorded with its resolving principal |
| A customisation the update did not touch is retained | An artefact classified `local_only` is left untouched and reported as retained |
| The base advances on resolution | Applying a resolved update advances the recorded install base to the new version, so the next update compares against it rather than against the original install |

---

## Outputs

| Output | Description |
|--------|-------------|
| `review_id` | UUID of the `promotion_reviews` row |
| `plan_digest` | SHA-256 over the canonical-JSON plan; the identity of the approved diff |
| `definition_id` | UUID of the definition version now active in the target tenant |
| `promotion_assertion_runs` row | Status `applied`, `failed` or `teardown_failed`, with the idempotency key |
| Event log entries | `DEFINITION_PROMOTION_REJECTED`, `DEFINITION_PROMOTION_APPROVED`, `DEFINITION_PROMOTION_APPLIED`, `DEFINITION_VERSION_ACTIVATED`, `DEFINITION_VERSION_ROLLED_BACK`, `PROMOTION_ASSERTION_TEARDOWN_FAILED` |
| Active version pointer | Target tenant's `process_key` points at the promoted version |

---

## SLAs & Escalations

| Event | Behaviour |
|-------|-----------|
| Review awaiting approval | No automatic timer. A review stays `pending_review` until approved, rejected or superseded by a newer submission for the same definition |
| Sandbox claim | 60 s wait cap; on expiry the apply call returns 503 and the review remains `approved` |
| Assertion re-run budget | 600 s wall clock; on expiry the run is marked `failed` and the sandbox is released |
| Teardown failure | `PROMOTION_ASSERTION_TEARDOWN_FAILED` is surfaced on `GET /api/v1/promotions/{id}` for operator follow-up; the leaked sandbox is reclaimed by the sandbox reaper |
| API response | Platform NFR: <= 200 ms read, <= 500 ms write. The apply call is exempt; it is bounded by the assertion re-run budget |

---

## Error / Exception Paths

| Error | Trigger | Recovery |
|-------|---------|---------|
| 403 `Forbidden` | Caller lacks `promotion.submit`, or the submitter attempts to approve | Approve with a distinct Platform Admin principal |
| 409 `PromotionConflict` | Target active version advanced past `base_version` | Rebase the source definition on the current target version and resubmit |
| 409 `PlanDigestMismatch` | Approve or apply body carries a digest the review does not hold | Re-read `GET .../context` and approve the current digest |
| 409 `DuplicateReview` | A live review already exists for this `(tenant_id, plan_digest)` | Act on the existing review instead of opening a second one |
| 422 `EmptyPromotionPlan` | Source and target are identical | No promotion is required |
| 422 `FixtureLoadFailed` | The artifact's fixture set is missing or unreadable | Resubmit the artifact with a complete fixture set; the review must be re-approved |
| 422 `AssertionFailed` | One or more carried assertions failed in the sandbox | Fix the definition in the test tenant, produce a new artifact, submit a new review |
| 400 `InvalidReviewTransition` | Approve on a non-`pending_review` row, or apply on a non-`approved` row | Read the current status and act on the permitted edge |
| 503 `SandboxUnavailable` | No ephemeral sandbox free within 60 s | Retry apply; the approval remains valid because the digest is unchanged |
| `TeardownFailed` | Sandbox release failed after the assertion run | Promotion is unaffected; the sandbox reaper reclaims the sandbox and the operator sees the event |
| 422 `VersionNeverActive` | Rollback names a version that was never active in the target tenant | Roll back to a version present in the tenant's activation history |
| 404 `PackNotInstalled` | An update is requested for a pack the tenant never installed | Install the pack first; an update has no base to compare against |
| 409 `UnresolvedTemplateConflict` | Apply is called while an artefact changed by both the tenant and the pack has no recorded resolution | Record `keep_local`, `take_incoming` or `merged` for the named artefact, then re-apply |
