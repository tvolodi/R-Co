# Test Spec: VLD-04 — Validation gate at authoring and promotion

**Requirement:** VLD-04 — The platform SHALL enforce semantic validation at two points: on
definition draft save and on `POST /api/v1/definitions/{id}/validate`, and again at promotion
submit before the PRM-01 plan is computed. A clean pass records a `semantically_valid` verdict on
the definition version together with the CEL compiler version that produced it; a verdict produced
by a different compiler version is re-verified rather than trusted. Compilation is bounded at 5
seconds per definition.

**Priority:** SHOULD
**Test layer:** unit (verdict semantics) + integration (real `runSemanticGate` /
`storedVerdictIsCurrent` / `persistVerdict` against `process_definitions` + `public.events`)
**Test-tier score (test_developer_guide.md §2.1):** DB schema (2, migration 1165 adds the verdict
columns to `process_definitions`) + tenant isolation (2, `process_definitions` is tenant-scoped) =
**4 points → sandbox tier by the rubric's raw score** — same note as `tests/specs/ORD-01.md`: no
Wasm/sandbox surface exists for the validation family, so unit + integration against real Postgres
is the proportionate ceiling.
**Design:** `src/design/vld-04-validation-gate-authoring-promotion.md`
**Implementation:** `src/validation/gate.zig` (`runSemanticGate`, `storedVerdictIsCurrent`,
`persistVerdict`), migration `1165_vld04_definition_semantic_verdict.sql`

---

## Acceptance criteria mapping

| # | Acceptance criterion (verbatim from `docs/requirements.yaml`) | Test case(s) |
|---|---|---|
| AC1 | GIVEN any finding at draft save, WHEN the request completes, THEN the platform returns HTTP 422 and the version is not marked `semantically_valid`. | `TC-VLD-04-AC1-draft-save-finding-invalid` (integration: `runSemanticGate` on an invalid graph → `.invalid`, row `semantically_valid = false`, `validation_finding_count > 0`). HTTP 422 mapping lives in the handler — see Structural verification note. `TC-VLD-04-AC1-PATCH` (integration: live `handlePatch` surface — PATCH with an invalid graph returns HTTP 422 and leaves `semantically_valid = false` in DB; covers ISS-0717). |
| AC2 | GIVEN any finding at promotion submit, WHEN the request completes, THEN the platform returns HTTP 422, computes no promotion plan and creates no `promotion_reviews` row. | `TC-VLD-04-AC2-promotion-finding-invalid` (integration: the gate returns `.invalid` for a promotion-submitted definition; no plan / no `promotion_reviews` row is guaranteed by the gate-before-plan ordering — see Structural verification note). |
| AC3 | GIVEN a stored verdict produced by an earlier compiler version, WHEN promotion submit runs, THEN validation re-runs instead of accepting the stored verdict. | `TC-VLD-04-AC3-stale-verdict-reruns` + `TC-VLD-04-AC3-current-verdict-reused` (integration `storedVerdictIsCurrent` + `runSemanticGate` `check_stored_first`) |
| AC4 | GIVEN compilation exceeds 5 seconds, WHEN the budget expires, THEN the platform returns HTTP 422 `ValidationTimeout` naming the sites compiled before expiry. | `TC-VLD-04-AC4-timeout` (integration: `runSemanticGate` with a forced-small budget against a large graph → `GateResult.timeout`) |
| AC5 | A clean pass appends `DEFINITION_VALIDATED`; a failure appends `DEFINITION_VALIDATION_FAILED` carrying the finding count. | `TC-VLD-04-AC5-valid-event` + `TC-VLD-04-AC5-failed-event` (integration: verify the `public.events` rows appended by `persistVerdict`/`runSemanticGate`) |

---

## Structural verification notes — AC1/AC2's HTTP 422 and "no plan / no review row" halves

`src/validation/gate.zig` is the gating orchestration layer; the HTTP status mapping (422) and the
"gate runs BEFORE PRM-01's plan computation" ordering live in the calling handlers
(`PUT /api/v1/definitions/{id}`, `POST /api/v1/definitions/{id}/validate`,
`POST /api/v1/promotions`) — which are VLD-04's declared call-site contracts, not code this module
owns. What the module owns, and what these tests prove:

- **AC1's 422** is the handler's mapping of `GateResult.invalid`. The gate's contribution — "the
  version is not marked `semantically_valid`" — is fully testable here: `runSemanticGate` persists
  `semantically_valid = false` with the finding count on a finding.
- **AC2's "no plan / no promotion_reviews row"** is guaranteed by *ordering* (the gate runs before
  plan computation, so a failing gate returns before any plan or review-row write), not by a
  rollback this module performs. This spec covers the gate's own half (returns `.invalid` for a
  definition with findings) and records the handler-ordering guarantee as a forward pointer; the
  `promotion_reviews` table itself is PRM-01's surface and is not touched by this batch.

These are the same convention as `tests/specs/ORD-04.md`'s "Structural verification notes": the
testable module boundary is proven, and the handler-level half is named, not silently dropped.

---

## Test cases

### vld04: COMPILER_VERSION re-export matches the pipeline constant
**Given:** `gate.COMPILER_VERSION` and `validation.COMPILER_VERSION`.
**When:** Compared.
**Then:** Equal — the invalidation rule (AC3) reads the same version source as the validator.
**Layer:** unit
**Acceptance criterion mapped:** AC3 (version source of truth)
**Zig test:** `vld04: COMPILER_VERSION re-export matches the pipeline constant` (in `src/validation/gate.zig`)

### TC-VLD-04-AC1-draft-save-finding-invalid: a finding at draft save leaves the version not semantically valid
**Given:** A DRAFT definition whose graph has an invalid CEL guard (a condition referencing a
variable that resolves to `UnknownVariable` under the empty env), stored in `process_definitions`.
**When:** `runSemanticGate` runs (draft-save call site).
**Then:** Returns `GateResult.invalid`; the row's `semantically_valid` is `false`, `compiler_version`
is set to the current constant, `validation_finding_count > 0` — the version is not marked valid
(handler maps `.invalid` → HTTP 422).
**Layer:** integration
**Acceptance criterion mapped:** AC1
**Zig test:** `TC-VLD-04-AC1-draft-save-finding-invalid` (`tests/integration/vld04_gate_test.zig`)

### TC-VLD-04-AC2-promotion-finding-invalid: the gate blocks a promotion submit with findings
**Given:** A DRAFT definition with findings (invalid graph).
**When:** `runSemanticGate` runs (promotion-submit call site, `check_stored_first = true`).
**Then:** Returns `GateResult.invalid` — the promotion handler returns before computing any PRM-01
plan or creating a `promotion_reviews` row (ordering guarantee; see Structural verification note).
**Layer:** integration
**Acceptance criterion mapped:** AC2
**Zig test:** `TC-VLD-04-AC2-promotion-finding-invalid` (`tests/integration/vld04_gate_test.zig`)

### TC-VLD-04-AC3-stale-verdict-reruns: a verdict from an earlier compiler version is re-verified
**Given:** A definition with `semantically_valid = true` and `compiler_version = 'old-version'`
(stale).
**When:** `storedVerdictIsCurrent` runs, then `runSemanticGate(..., check_stored_first = true)` runs.
**Then:** `storedVerdictIsCurrent` returns `false`; `runSemanticGate` does NOT trust the stored
verdict — it re-runs validation and returns the fresh outcome (valid or invalid per the current
graph), and the persisted `compiler_version` is updated to the current constant.
**Layer:** integration
**Acceptance criterion mapped:** AC3
**Zig test:** `TC-VLD-04-AC3-stale-verdict-reruns` (`tests/integration/vld04_gate_test.zig`)

### TC-VLD-04-AC3-current-verdict-reused: a current + valid stored verdict is not recompiled
**Given:** A definition with `semantically_valid = true` and `compiler_version = CURRENT`.
**When:** `storedVerdictIsCurrent` runs, then `runSemanticGate(..., check_stored_first = true)` runs.
**Then:** `storedVerdictIsCurrent` returns `true`; `runSemanticGate` returns `GateResult.valid`
without recompiling (the stored verdict is reused) and persists a fresh `validated_at`.
**Layer:** integration
**Acceptance criterion mapped:** AC3 (positive case — trust a current verdict)
**Zig test:** `TC-VLD-04-AC3-current-verdict-reused` (`tests/integration/vld04_gate_test.zig`)

### TC-VLD-04-AC4-timeout: compilation beyond the budget returns GateResult.timeout
**Given:** A definition whose graph is large enough that `validateDefinition` exceeds a forced
tiny budget (`budget_ms` set below real compile latency, e.g. 0/1 ms), so `elapsed_ms > budget_ms`.
**When:** `runSemanticGate` runs with that budget.
**Then:** Returns `GateResult.timeout` (the handler maps to HTTP 422 `ValidationTimeout` naming the
sites compiled before expiry).
**Layer:** integration
**Acceptance criterion mapped:** AC4
**Zig test:** `TC-VLD-04-AC4-timeout` (`tests/integration/vld04_gate_test.zig`)
> Note: the 5 s process-doc budget is enforced as a wall-clock bound around the pure
> `validateDefinition`; because mocks/clocks are forbidden, the timeout branch is exercised with a
> genuinely slow input (large graph) against a sub-second budget. If the graph is not slow enough
> on the host, this test fails — that is a host-capacity signal, not a defect (see the DDL-04 AC5
> note for the same fail-first convention).

### TC-VLD-04-AC5-valid-event: a clean pass appends DEFINITION_VALIDATED
**Given:** A DRAFT definition whose graph compiles clean (literal-only guards, 0 findings).
**When:** `runSemanticGate` runs.
**Then:** Returns `GateResult.valid`; the row is `semantically_valid = true` with `compiler_version =
CURRENT`; a `public.events` row with `event_type = 'DEFINITION_VALIDATED'` is appended carrying the
`definition_id` and `compiler_version`.
**Layer:** integration
**Acceptance criterion mapped:** AC5
**Zig test:** `TC-VLD-04-AC5-valid-event` (`tests/integration/vld04_gate_test.zig`)

### TC-VLD-04-AC5-failed-event: a failure appends DEFINITION_VALIDATION_FAILED with the finding count
**Given:** A DRAFT definition with findings (invalid graph).
**When:** `runSemanticGate` runs.
**Then:** Returns `GateResult.invalid`; a `public.events` row with `event_type =
'DEFINITION_VALIDATION_FAILED'` is appended whose payload carries `definition_id` and the
`finding_count`.
**Layer:** integration
**Acceptance criterion mapped:** AC5
**Zig test:** `TC-VLD-04-AC5-failed-event` (`tests/integration/vld04_gate_test.zig`)

### vld04_definition_semantic_verdict: verdict_columns_exist_with_defaults
**Given:** A freshly inserted definition version.
**When:** The verdict columns are read.
**Then:** `semantically_valid = false`, `compiler_version` NULL, `validated_at` NULL,
`validation_finding_count = 0` — the "never validated" starting state (AC1).
**Layer:** integration (schema contract)
**Acceptance criterion mapped:** AC1 (default state)
**Zig test:** `vld04_definition_semantic_verdict: verdict_columns_exist_with_defaults`

### vld04_definition_semantic_verdict: clean_pass_records_verdict_with_compiler_version
**Given:** A definition whose verdict is updated to `semantically_valid = true` with the current
compiler version.
**When:** The row is read.
**Then:** `semantically_valid = true`, `compiler_version = CURRENT`, `validated_at` NOT NULL,
finding count 0 (AC5/AC3 comparison source).
**Layer:** integration (schema contract)
**Acceptance criterion mapped:** AC5
**Zig test:** `vld04_definition_semantic_verdict: clean_pass_records_verdict_with_compiler_version`

### vld04_definition_semantic_verdict: failed_pass_records_finding_count_and_stays_invalid
**Given:** A definition whose verdict is updated to `semantically_valid = false` with
`validation_finding_count = 3`.
**When:** The row is read.
**Then:** `semantically_valid = false`, `validation_finding_count = 3` — the data
`DEFINITION_VALIDATION_FAILED` carries (AC1/AC5).
**Layer:** integration (schema contract)
**Acceptance criterion mapped:** AC1/AC5
**Zig test:** `vld04_definition_semantic_verdict: failed_pass_records_finding_count_and_stays_invalid`

### vld04_definition_semantic_verdict: stale_compiler_version_is_distinguishable
**Given:** A definition whose verdict was produced by `compiler_version = 'old-version'`.
**When:** The row is read.
**Then:** `compiler_version = 'old-version'` (NOT the current constant) — distinguishable so
`storedVerdictIsCurrent` decides re-verification (AC3).
**Layer:** integration (schema contract)
**Acceptance criterion mapped:** AC3
**Zig test:** `vld04_definition_semantic_verdict: stale_compiler_version_is_distinguishable`

### vld04_definition_semantic_verdict: finding_count_check_rejects_negative
**Given:** An UPDATE setting `validation_finding_count = -1`.
**When:** Executed.
**Then:** Fails (SQLSTATE 23514) and the count is unchanged.
**Layer:** integration (schema contract)
**Acceptance criterion mapped:** supports AC5 (finding count is a non-negative cardinality)
**Zig test:** `vld04_definition_semantic_verdict: finding_count_check_rejects_negative`

### TC-VLD-04-AC1-PATCH: handlePatch returns HTTP 422 on a finding-producing body
**Given:** A DRAFT definition row in `process_definitions` seeded with a valid graph
(`seedDefinition(allocator, conn, valid_graph_json)`). A `definition.Store` initialised from the
same pool. A `PatchDefinitionBody` with `graph` set to `invalid_graph_json` (structurally valid,
semanticially invalid — a guard referencing `amount` which is `UnknownVariable` under the empty
env) and all other fields `null`.
**When:** `definitions_routes.handlePatch(&store, allocator, fx.definition_id, patch_body)` is
called.
**Then:** `HandlerResult.status_code` equals 422; `HandlerResult.body` is non-empty; the
`process_definitions` row's `semantically_valid` column is `false` (queried via `conn` after the
call).
**Layer:** integration (live handler surface)
**Acceptance criterion mapped:** AC1, on the live PATCH draft-save surface (ISS-0717)
**Zig test:** `TC-VLD-04-AC1-PATCH` (`tests/integration/vld04_gate_test.zig`)

---

## Fixture isolation
`storedVerdictIsCurrent` / `persistVerdict` run on a `TestHarness` connection (rolled back on
deinit). `runSemanticGate` needs a real pool (`makePool` pattern); its fixtures (definition rows
keyed by a per-test UUID name in the `process_definitions` shared table) are committed through the
pool and deleted in `defer`, matching `ordering_consumer_test.zig`. No module-level mutable state;
no `error.SkipZigTest`.

---

## Run status (2026-08-16, `test-integration-vld04-gate`)
4/7 gate tests pass (AC2, AC3-current, AC5-valid, AC5-failed); 1/1 unit test passes; 5/5 schema
tests pass. Three tests fail/crash — **BLOCKER implementation defect in the VLD-04 gate's
finding path**: when `runSemanticGate` compiles a graph that produces findings, it corrupts heap
memory — `persistVerdict` then writes a garbage `compiler_version` into `process_definitions`
(verified: a clean pass writes the correct constant; any finding-producing pass writes invalid
bytes), and `TC-VLD-04-AC3-stale-verdict-reruns` / `TC-VLD-04-AC4-timeout` segfault. The
corruption originates in the `validateDefinition` finding path invoked by `runSemanticGate` (the
shipped VLD-01/02/03 pipeline or BACKEND-DEV's gate wiring) and must be root-caused by
ISSUE-FIXER before VLD-04 can reach TESTED. Reported in the handoff.
