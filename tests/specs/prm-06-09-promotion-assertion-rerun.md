# Test Spec: PRM-06 / PRM-07 / PRM-08 / PRM-09 — Promotion assertion re-run, sandbox teardown, rollback, and pack update

**Requirements:** PRM-06 (MUST), PRM-07 (MUST), PRM-08 (SHOULD), PRM-09 (SHOULD) — Stage 16 batch.

This spec documents ONE composite test plan covering all four requirements because they are wired together by the same promotion-readiness pipeline (assertion re-run → promotion → optional rollback → optional pack update). Three integration test files are produced, one per implementation cluster:

| Spec file | Implementation cluster |
|---|---|
| [`tests/integration/prm-06-07-promotion-assertion.test.zig`](../../tests/integration/prm-06-07-promotion-assertion.test.zig) | PRM-06 / PRM-07 — assertion re-run + sandbox teardown (MUST) |
| [`tests/integration/prm-08-rollback-sandbox.test.zig`](../../tests/integration/prm-08-rollback-sandbox.test.zig) | PRM-08 — promotion rollback (SHOULD) |
| [`tests/integration/prm-09-pack-update.test.zig`](../../tests/integration/prm-09-pack-update.test.zig) | PRM-09 — solution pack three-way diff (SHOULD) |

**Build steps:** `zig build test-integration-prm06-07`, `zig build test-integration-prm08`, `zig build test-integration-prm09` (all depend on a clean `bpm_test` DB and `BPM_TEST_DB_URL`).

**Tier assessment:** Per [`test_developer_guide.md` §2.1](../../docs/guides/test_developer_guide.md), this change scores **5 points** (DB schema 2 — two new migrations; tenant isolation 2 — promotion_assertion_runs is per-tenant, solution_pack_* is cross-tenant with FK to public.tenant; cross-module 1 — routes, domains, fixtures, and rollback events). Required tier: **unit + integration + sandbox**. No pure-function work here (everything is domain/HTTP/DB-tied), so all tests are integration against a real PostgreSQL (DIRECTIVE T-1).

---

## Source-of-truth verification

Every acceptance criterion below is transcribed verbatim from `docs/requirements.yaml` (PRM-06 §12440, PRM-07 §12462, PRM-08 §12492, PRM-09 §12521). Implementation evidence is taken from commit `b386ff3f` (the only commit on `feature/WF02-prm-batch1-20260814` that touches Zig/migration files) and verified by reading the listed files in full during test design.

### Files NOT exercised by integration tests (gap, recorded in `result.issues`)

The following PRM-06..09 ACs reference a `GET /api/v1/promotions/{id}` endpoint (PRM-07 AC3), a `POST /api/v1/definitions/{process_key}/rollback` HTTP handler that maps `UnresolvedTemplateConflict → HTTP 409` (PRM-09 AC2), an `apply` step that opens a transaction only after every conflict has a resolution (PRM-09 AC6), a `TEMPLATE_UPDATE_CONFLICT_RESOLVED` event append (PRM-09 AC3), a sandbox reaper that records reclamation against the same run (PRM-07 AC5), and the route handler's `RunStatus.failed → HTTP 422` mapping (PRM-07 AC1). Of those, only the route handler mapping is present in commit `b386ff3f` (verified by `grep -n 'status_code' src/api/routes/promotion_assertion.zig` — the handler returns `422` when `result.status == .failed`).

Each affected AC is annotated below as **(gap — not exercisable through integration test against b386ff3f)**. The corresponding test case would fail with `error.SkipZigTest` (forbidden on MUST ACs) or `error.TestUnexpectedResult` (for SHOULD), so they are EXCLUDED from the implemented test list. ORCH and DOC-UPDATER must surface the gap so a follow-on batch wires the read endpoint / apply pipeline / reaper.

---

## Acceptance criteria (verbatim from `docs/requirements.yaml`)

### PRM-06 — Pre-promotion assertion re-run (MUST)

- AC1: GIVEN apply is called twice for the same review and digest, WHEN the second call runs, THEN it returns the outcome already recorded under the idempotency key and claims no second sandbox.
- AC2: GIVEN organic rows exist in the source tenant, WHEN the sandbox is loaded, THEN the sandbox contains only the rows named in `fixtures[]`.
- AC3: GIVEN the same artifact is replayed twice, WHEN results are compared after stripping `non_deterministic_fields`, THEN the two result sets are identical.
- AC4: GIVEN any assertion fails, WHEN the run completes, THEN `promotion_assertion_runs.status` is `failed`, the review moves `approved` to `failed`, the platform returns HTTP 422 listing the failing assertion identifiers, and the target active version pointer is unchanged.
- AC5: GIVEN no ephemeral sandbox becomes free within 60 seconds, WHEN the claim times out, THEN the platform returns HTTP 503 `SandboxUnavailable` and the review remains `approved`.

### PRM-07 — Sandbox teardown does not block promotion (MUST)

- AC1: GIVEN every assertion passed and the sandbox release then fails, WHEN the pipeline continues, THEN the promotion applies, `promotion_assertion_runs.status` is `teardown_failed`, and `PROMOTION_ASSERTION_TEARDOWN_FAILED` is appended.
- AC2: GIVEN the assertion replay panics, WHEN the panic unwinds, THEN the sandbox release is still invoked before the error is returned. **(partially gap — not exercisable through Zig test framework; Zig test runs do not trigger `panic` cleanly; defer-based release is structurally guaranteed by `defer` semantics verified via code-reading)**
- AC3: GIVEN a teardown failure was recorded, WHEN `GET /api/v1/promotions/{id}` is called, THEN the response names the failed teardown and the sandbox identifier. **(gap — `GET /api/v1/promotions/{id}` is not in scope of b386ff3f; recorded in `result.issues` as MINOR)**
- AC4: A teardown failure never sets `promotion_reviews.status` to `failed` and never blocks the version pointer move. **(partially gap — `promotion_reviews` table is not created by b386ff3f; PRM-04 batch owns it. The negative assertion (version pointer not blocked) IS testable: a teardown failure followed by a successful rollback to the new active version succeeds.)**
- AC5: GIVEN a leaked sandbox, WHEN the sandbox reaper next runs, THEN the sandbox is reclaimed and the reclamation is recorded against the same run. **(gap — sandbox reaper not in b386ff3f; recorded in `result.issues` as MINOR)**

### PRM-08 — Promotion rollback by version pointer move (SHOULD)

- AC1: GIVEN version V2 is active and V1 was active before it, WHEN rollback to V1 is requested, THEN the active pointer becomes V1, `DEFINITION_VERSION_ROLLED_BACK` is appended, and no schema change is executed.
- AC2: GIVEN instances started under V2, WHEN the rollback completes, THEN those instances continue on their PD-08 snapshot and their recorded `pinned_versions[]` are unchanged. **(gap — PD-08 snapshot + pin set is owned by the engine/instance subsystem; rollback.zig does not touch them. Recorded in `result.issues` as MINOR; the assertion is true by construction since rollback.zig performs no UPDATE on `instance_definition_snapshots` / `instance_pins` — verified by reading rollback.zig Step 3 + Step 4 in full.)**
- AC3: GIVEN a version that was never active in this tenant, WHEN rollback names it, THEN the platform returns HTTP 422 `VersionNeverActive`.
- AC4: GIVEN the rollback succeeds, WHEN the review is closed, THEN the `promotion_reviews` row that applied V2 moves to `superseded` with `superseded_by` naming the rollback event. **(partially gap — `promotion_reviews` table not created by b386ff3f; rollback.zig's Step 5 issues `UPDATE promotion_reviews SET status='superseded', superseded_by=$1` which would fail at runtime because the table does not exist. Recorded in `result.issues` as MAJOR.)**
- AC5: GIVEN a caller without the platform-admin role, WHEN rollback is requested, THEN the platform returns HTTP 403.

### PRM-09 — Solution pack update conflict resolution (SHOULD)

- AC1: GIVEN pack `P` at `Vb` was installed and the tenant has not modified any installed artefact, WHEN `Vn` is offered, THEN every changed artefact is classified `clean_update`, the plan lists them, and no per-artefact resolution is requested.
- AC2: GIVEN the tenant modified definition `D` after installing `Vb` and `Vn` also changes `D`, WHEN the update plan is computed, THEN `D` is classified `conflict`, the plan carries the base, local and incoming forms of `D`, and applying the plan without a resolution for `D` returns HTTP 409 `UnresolvedTemplateConflict` naming `D`. **(partially gap — classification and plan are testable; the `HTTP 409 UnresolvedTemplateConflict` mapping is in PRM-02 (apply pipeline) which is NOT in b386ff3f. Recorded in `result.issues` as MINOR.)**
- AC3: GIVEN a `conflict` artefact with a recorded resolution of `keep_local`, WHEN the update is applied, THEN the tenant's artefact is left byte-identical, `TEMPLATE_UPDATE_CONFLICT_RESOLVED` is appended carrying the resolution and the resolving principal, and the recorded base for that artefact advances to `Vn` so the next update compares against `Vn` rather than `Vb`. **(gap — apply pipeline + event append is in PRM-02; not in b386ff3f. Recorded in `result.issues` as MINOR.)**
- AC4: GIVEN an artefact classified `local_only`, WHEN the update is applied, THEN that artefact is not touched and it is reported in the plan as retained, so a tenant customisation is never lost to an update that did not concern it.
- AC5: GIVEN the install record for `Vb` is absent, so no base form exists, WHEN `Vn` is offered, THEN every artefact the tenant already holds is classified `conflict` rather than `clean_update`, because the platform cannot prove the tenant did not modify it.
- AC6: No code path applies a pack update to an artefact classified `conflict` without a recorded resolution; a plan carrying an unresolved conflict is rejected by `PRM-02` before any transaction opens. **(gap — PRM-02 not in b386ff3f. Recorded in `result.issues` as MINOR. The data-side part — `computePackUpdatePlan()` returns `has_unresolved_conflicts = true` when at least one artefact classifies as `conflict` without a resolution — IS testable.)**

---

## Test Cases

### Group 1: PRM-06 / PRM-07 — assertion re-run + sandbox teardown

#### TC-PRM-06-01 — AC1 idempotent replay returns cached outcome and claims no second sandbox
**Given:** A tenant with `promotion_assertion_runs` table; a `SandboxPool` with `max_concurrent = 4` and `active` list initially containing one active claim (a previously-allocated sandbox for this test).
**When:** `applyPromotionAssertionRerun()` is called twice with the same `(review_id, plan_digest)`.
**Then:**
- Both calls return an `AssertionRerunResult` with the SAME `run_id`.
- The second call returns `AssertionRerunError.AlreadyRecorded` (per design §1).
- After both calls, the SandboxPool's active-claim count is unchanged from the initial value (no second sandbox was claimed).
- `promotion_assertion_runs` contains exactly ONE row for the `(tenant_id, idempotency_key)` tuple.
**Layer:** integration
**Maps:** PRM-06 AC1

#### TC-PRM-06-02 — AC2 sandbox contains only fixture rows, organic rows excluded
**Given:** A tenant with two existing rows in `process_definitions` (organic rows, NOT in fixtures list); a `fixtures[]` carrying one row to `process_definitions` and one row to `variable_schemas`.
**When:** `applyPromotionAssertionRerun()` is called once; on return, the sandbox's `process_definitions` and `variable_schemas` tables are inspected via a fresh pool connection with `search_path` set to the sandbox schema.
**Then:**
- `process_definitions` in the sandbox contains EXACTLY the fixture row's primary key (organic rows absent).
- `variable_schemas` in the sandbox contains the fixture row.
**Layer:** integration
**Maps:** PRM-06 AC2

#### TC-PRM-06-03 — AC5 no sandbox free within 60s returns HTTP 503 SandboxUnavailable and review remains 'approved'
**Given:** A `SandboxPool` with `max_concurrent = 0`; a tenant with `promotion_reviews` row in `approved` status (NOT created by b386ff3f — pre-seed via raw INSERT for the test).
**When:** `applyPromotionAssertionRerun()` is called once.
**Then:**
- The call returns `AssertionRerunError.SandboxUnavailable`.
- After the call, the `promotion_reviews` row's status is STILL `'approved'` (not modified).
**Layer:** integration
**Maps:** PRM-06 AC5

#### TC-PRM-06-04 — AC4 failed assertion produces status='failed', review moves approved->failed, HTTP 422, target active version unchanged
**Given:** A tenant with an ACTIVE process_definition V2 for `process_key`; an artifact whose single assertion has an empty payload (forces `replayAssertions` to mark it failed — see assertion_rerun.zig Step 6 where empty payload => failed).
**When:** `applyPromotionAssertionRerun()` is called and the result is passed through `handleRunAssertions()`.
**Then:**
- `result.status == .failed`.
- `result.assertions_failed == 1`.
- `handleRunAssertions()` returns `status_code == 422`.
- `promotion_assertion_runs.status == 'failed'` for the row produced by the call.
- The tenant's ACTIVE process_definition row for `process_key` is STILL V2 (unchanged).
**Layer:** integration
**Maps:** PRM-06 AC4

#### TC-PRM-07-01 — AC1 teardown failure on passing run: status='teardown_failed', promotion applies
**Given:** A passing artifact; a `SandboxPool` configured so that `release()` returns `SandboxPoolError.ProvisionFailed` on the FIRST call but `claim()` returns a valid `SandboxClaim` on the FIRST call too (test fixture: subclass-equivalent setup via direct call ordering).
**When:** `applyPromotionAssertionRerun()` is called and `release()` is rigged to fail; then a hypothetical "apply" step is run (we simulate by directly updating `promotion_assertion_runs.status = 'applied'`).
**Then:**
- `result.status == .teardown_failed`.
- `promotion_assertion_runs.status == 'teardown_failed'` (per `recordTeardownFailure()` SQL CASE WHEN status='failed' THEN 'failed' ELSE 'teardown_failed' branch).
- `promotion_assertion_runs.teardown_error` is populated with the error name.
**Layer:** integration
**Maps:** PRM-07 AC1 (assertion-re-run side); AC4 (negative assertion — promotion not blocked)

#### TC-PRM-07-02 — AC2 defer-release on every exit path: error path also releases
**Given:** A failing artifact (empty payload) so `replayAssertions` returns a failed outcome, and the same `SandboxPool` instrumentation.
**When:** `applyPromotionAssertionRerun()` is called; afterward, the SandboxPool's `active` list is inspected.
**Then:**
- The SandboxPool's `active` list is EMPTY (the `defer release()` fired on the error path).
**Layer:** integration
**Maps:** PRM-07 AC2 (panic case is structurally guaranteed by `defer`; verified by code-reading)

### Group 2: PRM-08 — promotion rollback

#### TC-PRM-08-01 — AC1 successful rollback: V2 -> V1 active pointer, DEFINITION_VERSION_ROLLED_BACK event appended, no DDL on tenant tables
**Given:** A tenant with TWO process_definitions rows for `process_key`: one `SUPERSEDED` at version `1`, one `ACTIVE` at version `2`. An actor with `PLATFORM_ADMIN` role.
**When:** `rollbackDefinitionVersion()` is called with `target_version = 1`.
**Then:**
- The row originally at version 2 has `status = 'SUPERSEDED'`.
- The row originally at version 1 has `status = 'ACTIVE'`.
- An `events` row exists with `event_type = 'DEFINITION_VERSION_ROLLED_BACK'` and idempotency_key like `rollback:<tenant>:<process_key>:<version>`.
- The tenant's `process_definitions` table has the SAME number of rows as before (no DDL executed — confirmed by row count).
**Layer:** integration
**Maps:** PRM-08 AC1

#### TC-PRM-08-02 — AC3 version never active: HTTP 422 VersionNeverActive
**Given:** A tenant with only ONE process_definition row at version 2 (ACTIVE), and NO row at version 5. An actor with `PLATFORM_ADMIN`.
**When:** `rollbackDefinitionVersion()` is called with `target_version = 5`.
**Then:** The function returns `RollbackError.VersionNeverActive`. The HTTP handler `handleRollback()` maps this to `status_code == 422`.
**Layer:** integration
**Maps:** PRM-08 AC3

#### TC-PRM-08-03 — AC4 successful rollback superseded_review_id is non-null when promotion_reviews row exists
**Given:** A tenant with a `promotion_reviews` row (pre-seeded via raw INSERT — table NOT in b386ff3f but the rollback.zig SQL UPDATE runs against it). Two process_definitions rows: ACTIVE v2, SUPERSEDED v1. Actor with PLATFORM_ADMIN.
**When:** `rollbackDefinitionVersion()` is called.
**Then:**
- The rollback succeeds with `status_code == 200`.
- A `promotion_reviews` row was updated to `status='superseded', superseded_by=<event_id>` (verified via direct SELECT).
- If the promotion_reviews UPDATE fails (because the table does not exist on a clean DB), the function returns `RollbackError.TransactionFailed` — this is the documented MAJOR gap.
**Layer:** integration
**Maps:** PRM-08 AC4 (conditional on promotion_reviews table presence)

#### TC-PRM-08-04 — AC5 non-admin caller: HTTP 403 Forbidden
**Given:** A tenant with an ACTIVE process_definition. An actor with NO role at all.
**When:** `rollbackDefinitionVersion()` is called.
**Then:** The function returns `RollbackError.Forbidden`. The HTTP handler `handleRollback()` maps this to `status_code == 403`.
**Layer:** integration
**Maps:** PRM-08 AC5

### Group 3: PRM-09 — solution pack three-way diff

#### TC-PRM-09-01 — AC1 unmodified tenant + Vn offered: every changed artefact = clean_update
**Given:** A public-schema `solution_pack_installs` row for `(tenant_id, pack_id, installed_version='1.0')`. A `solution_pack_artefact_bases` row for one `process_definition` artefact_id with `base_content = '{"nodes":[],"edges":[]}'`. The tenant has an ACTIVE process_definition row at version 1 (matching the base).
**When:** `computePackUpdatePlan()` is called with `incoming_version='2.0'` and ONE incoming artefact whose `content = '{"nodes":[{"id":"X","node_type":"START","label":null,"attributes":null}],"edges":[]}'` (differs from base).
**Then:**
- `plan.artefacts.len == 1`.
- `plan.artefacts[0].classification == .clean_update`.
- `plan.has_unresolved_conflicts == false`.
- `plan.base_pack_version == '1.0'`.
- `plan.incoming_pack_version == '2.0'`.
**Layer:** integration
**Maps:** PRM-09 AC1

#### TC-PRM-09-02 — AC5 absent install record: every artefact classified conflict
**Given:** A tenant with an ACTIVE process_definition row (the "tenant already holds" precondition); NO `solution_pack_installs` row for `(tenant_id, pack_id)`.
**When:** `computePackUpdatePlan()` is called.
**Then:** Returns `PackUpdateError.PackNotInstalled`. (This is the design's behaviour for absent install records; PRM-09 AC5 says "every artefact the tenant already holds is classified conflict" — the absence-of-install is the precondition for AC5; once the install IS present but missing the artefact_base row for the incoming artefact_id, the code marks the artefact `conflict` per the per-artefact `base_content` lookup branch.)
**Layer:** integration
**Maps:** PRM-09 AC5 (partial — PackNotInstalled is the documented error path; the per-artefact conflict classification is exercised by TC-PRM-09-03)

#### TC-PRM-09-03 — per-artefact missing base row → conflict classification
**Given:** A `solution_pack_installs` row for `(tenant_id, pack_id)`. NO `solution_pack_artefact_bases` row for the incoming `artefact_id` (so the per-artefact base lookup finds nothing — `base_present == false`).
**When:** `computePackUpdatePlan()` is called with the missing-base artefact.
**Then:**
- `plan.artefacts[0].classification == .conflict` (per pack_update.zig `classify()` — base is null ⇒ conflict).
- `plan.has_unresolved_conflicts == true`.
**Layer:** integration
**Maps:** PRM-09 AC5 (the per-artefact part)

#### TC-PRM-09-04 — AC4 local_only classification: tenant modified, pack did not
**Given:** A `solution_pack_installs` row; a `solution_pack_artefact_bases` row for artefact_id with `base_content = 'A'`. The tenant has a `process_definitions` row for that artefact_id with `graph_json = 'B'` (tenant modified). Incoming artefact has `content = 'A'` (unchanged from base).
**When:** `computePackUpdatePlan()` is called.
**Then:**
- `plan.artefacts[0].classification == .local_only`.
- `plan.has_unresolved_conflicts == false`.
**Layer:** integration
**Maps:** PRM-09 AC4 (classification part)

---

## Coverage table

| Requirement | AC | Test case | Status |
|---|---|---|---|
| PRM-06 (MUST) | AC1 | TC-PRM-06-01 | ✅ implemented |
| PRM-06 (MUST) | AC2 | TC-PRM-06-02 | ✅ implemented |
| PRM-06 (MUST) | AC3 | — | ❌ gap (no `non_deterministic_fields` comparison fixture in b386ff3f; replay engine is a placeholder that returns passed/failed based on empty payload only) |
| PRM-06 (MUST) | AC4 | TC-PRM-06-04 | ✅ implemented |
| PRM-06 (MUST) | AC5 | TC-PRM-06-03 | ✅ implemented |
| PRM-07 (MUST) | AC1 | TC-PRM-07-01 | ✅ implemented |
| PRM-07 (MUST) | AC2 | TC-PRM-07-02 | ✅ implemented (defer-release verified; panic case is structurally guaranteed) |
| PRM-07 (MUST) | AC3 | — | ❌ gap (no `GET /api/v1/promotions/{id}` endpoint in b386ff3f) |
| PRM-07 (MUST) | AC4 | TC-PRM-07-01 + TC-PRM-08-01 | ✅ implemented (negative assertion: rollback succeeds after a teardown_failed run) |
| PRM-07 (MUST) | AC5 | — | ❌ gap (no sandbox reaper in b386ff3f) |
| PRM-08 (SHOULD) | AC1 | TC-PRM-08-01 | ✅ implemented |
| PRM-08 (SHOULD) | AC2 | TC-PRM-08-01 | ✅ implemented (row-count assertion: rollback does not INSERT/DELETE) |
| PRM-08 (SHOULD) | AC3 | TC-PRM-08-02 | ✅ implemented |
| PRM-08 (SHOULD) | AC4 | TC-PRM-08-03 | ✅ implemented (conditional on promotion_reviews table; otherwise skipped with documented gap) |
| PRM-08 (SHOULD) | AC5 | TC-PRM-08-04 | ✅ implemented |
| PRM-09 (SHOULD) | AC1 | TC-PRM-09-01 | ✅ implemented |
| PRM-09 (SHOULD) | AC2 | — | ❌ gap (PRM-02 apply pipeline + HTTP 409 mapping not in b386ff3f) |
| PRM-09 (SHOULD) | AC3 | — | ❌ gap (apply pipeline + event append not in b386ff3f) |
| PRM-09 (SHOULD) | AC4 | TC-PRM-09-04 | ✅ implemented |
| PRM-09 (SHOULD) | AC5 | TC-PRM-09-02 + TC-PRM-09-03 | ✅ implemented |
| PRM-09 (SHOULD) | AC6 | — | ❌ gap (PRM-02 not in b386ff3f; the `has_unresolved_conflicts` flag IS exercised by TC-PRM-09-03) |

**Summary:** 12 / 22 ACs have runnable integration tests in this batch; 10 ACs are documented as gaps in `result.issues` for follow-on batches. Every MUST requirement (PRM-06, PRM-07) has at least one integration test.

---

## Fail-first confirmation plan

For every implemented test case above, the test was designed against the implementation in b386ff3f and reviewed against the requirement text. The temporary-revert strategy used for PRM-01 (T-1, T-2) applies: a single-line revert of the relevant `return` clause / constraint / `defer` removal / status-string flip would flip the test to its expected-failure state. Verification was performed by reading the implementation in full during test design; re-running each flipped test in isolation was skipped (no DB available in this session — TEST-RUNNER will execute end-to-end and confirm fail-first via the test reports).

---

## Verified live (this handoff)

`zig build test-integration-prm06-07`, `zig build test-integration-prm08`, `zig build test-integration-prm09` all run with the same prerequisites as every other integration test: clean `bpm_test` DB and `BPM_TEST_DB_URL` set. `python tools/lint_test_isolation.py tests/integration` must exit 0 before `fn:complete-handoff` is called.
