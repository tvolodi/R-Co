# Process: Agent Artifact Lifecycle

| Field | Value |
|-------|-------|
| Process ID | `sys-agent-artifact-lifecycle` |
| Platform Workflow | PW-11 |
| Owner | Platform Admin |
| Scope | System-wide (platform tenant; non-production environments only) |
| Requirements | AGT-01, AGT-02, AGT-03, AGT-04, AGT-05, AGT-06, AGT-07 |
| Source | `docs/workflows.yaml` (PW-11) - `docs/Audit-Reports/Borrowing_From_ASCOA-GO.20260729.md` §2.8 |

## Summary

Governs how an authoring agent submits its work as an immutable, deterministically
identified artifact into the staging environment, how a resubmission of the same
attempt is recognised as a re-hit rather than a new row, and how retention keeps a
verified artifact for as long as anything still pins it. Artifact identity is bound
to the task spec through a `spec_hash` over canonical JSON that includes a non-zero
RNG seed, so a spec that would produce different work produces a different identity.

---

## Roles

| Role | Actor | Responsibility |
|------|-------|----------------|
| Orchestrating Agent | ORCH principal | Submits the task spec that artifacts are bound to |
| Authoring Agent | BACKEND-DEV / TEST-DESIGNER / UAT-RUNNER principal | Submits the artifact envelope for one attempt |
| BPM Platform | System | Enforces environment, validates the envelope, computes and compares `spec_hash` |
| Reviewer | RELEASE-VALIDATOR principal | Marks an artifact `verified` or leaves it `needs_review` |
| Retention Sweeper | System (scheduled) | Runs the dual sweep over `needs_review` and `verified` artifacts |

---

## Inputs

| Input | Type | Constraints |
|-------|------|-------------|
| `kind` | enum | `test_report`, `design_artifact`, `patch_set`, `scenario_run`; discriminates the payload schema |
| `task_spec_id` | UUID | Must reference an existing row in `task_specs` in the same tenant |
| `attempt_count` | integer | >= 1; monotonically increasing per task spec |
| `spec_hash` | hex(64) | SHA-256 of the canonical JSON of the task spec, as computed by the submitter |
| `payload` | object | Validated against the schema selected by `kind` |
| `non_deterministic_fields` | string[] | Field paths excluded from artifact comparison; the legacy name `ignore_fields` is rejected |
| `rng_seed` | uint64 (on the task spec) | Must be non-zero; folded into `spec_hash` |
| `environment` | enum (server-derived) | Must be `staging`; taken from the deployment config, never from the request |

---

## Steps

| # | Actor | Action | Decision | Outcome | Requirement |
|---|-------|--------|----------|---------|-------------|
| 1 | Orchestrating Agent | Submits a task spec with a `rng_seed` | `rng_seed == 0`? | -> 400 `rng_seed_zero`; the spec is not persisted | AGT-05 |
| 2 | Platform | Serialises the spec to canonical JSON (RFC 8785 JCS) with `rng_seed` included, computes `spec_hash = SHA-256(canonical)` | - | `task_specs` row written with `spec_hash`; the row is immutable from this point | AGT-04, AGT-05 |
| 3 | Authoring Agent | Submits `POST /api/v1/agent/artifacts` with the envelope | Deployment environment is `production`? | -> 403 `wrong_environment`; no row is written and no payload is read | AGT-02 |
| 4 | Platform | Reads `kind` and selects the payload schema | `kind` outside the enum? | -> 400 `unknown_artifact_kind` naming the received value | AGT-01 |
| 5 | Platform | Validates the envelope field names | Envelope carries `ignore_fields`? | -> 400 `deprecated_field:ignore_fields`; the value is not aliased to `non_deterministic_fields` | AGT-07 |
| 6 | Platform | Validates the payload against the `kind` schema | Payload fails the schema? | -> 422 `artifact_payload_invalid` with the failing JSON pointer | AGT-01 |
| 7 | Platform | Executes `INSERT INTO agent_artifacts (...) ON CONFLICT (tenant_id, task_spec_id, attempt_count) DO UPDATE SET touched_at = now() RETURNING xmax = 0 AS inserted` | `inserted` is true? | -> 201 Created; `artifact_id` returned; state `needs_review` | AGT-03 |
| 8 | Platform | On `inserted = false`, compares the stored `spec_hash` with the submitted one | Hashes equal? | -> 200 OK with the existing `artifact_id`; the stored payload is left untouched | AGT-03 |
| 9 | Platform | On `inserted = false` with differing hashes | Hashes differ? | -> 409 `spec_hash_mismatch` carrying both hashes; the stored row is left untouched | AGT-03, AGT-04 |
| 10 | Authoring Agent | Retries the same attempt after a transport failure | - | Step 7 returns `inserted = false`, Step 8 returns 200; exactly one row exists for the attempt | AGT-03 |
| 11 | Reviewer | Marks the artifact `verified` and records `verified_at` | Artifact state is `needs_review`? | State -> `verified`; the needs-review TTL stops applying | AGT-06 |
| 12 | Platform | Records the pin `(task_spec_version, process_definition_version)` in `artifact_version_pins` at verification time | - | The verified artifact is bound to the exact version pair it was produced against | AGT-06 |
| 13 | Retention Sweeper | Sweep 1: deletes `needs_review` artifacts where `created_at <= now() - STAGING_REVIEW_TTL_DAYS` (30) | Artifact is `verified`? | Excluded from sweep 1 by the state predicate | AGT-06 |
| 14 | Retention Sweeper | Sweep 2: deletes a `verified` artifact only when the pinned version pair has been collected AND `verified_at <= now() - STAGING_VERIFIED_TTL_DAYS` (365) | Either condition unmet? | Row is retained; the later of the two moments governs | AGT-06 |

---

## Business Rules

| Rule | Detail |
|------|--------|
| Kind discrimination | The envelope carries exactly one `kind`, and `kind` selects the payload schema. An envelope with a payload that does not match its `kind` is a 422, not a partial store. |
| Non-production only | Artifacts persist in the `staging` schema. A submission against a production deployment returns 403 `wrong_environment` before the payload is parsed. The environment comes from deployment config; a request-supplied environment is discarded. |
| Idempotency key | `(tenant_id, task_spec_id, attempt_count)` is unique. `RETURNING xmax = 0` distinguishes a fresh insert (201) from a re-hit (200). |
| Re-hit is not an overwrite | A re-hit with a matching `spec_hash` updates `touched_at` only. The stored payload is never replaced. |
| Hash mismatch is a conflict | A re-hit with a differing `spec_hash` is 409. The same attempt number cannot describe two different specs. |
| Task spec immutability | A `task_specs` row is immutable once written. A changed spec is a new spec with a new `spec_hash` and a new `task_spec_id`. |
| Determinism in identity | `rng_seed` is validated non-zero and folded into the canonical JSON before hashing, so two runs that would diverge on seed carry different spec identities. |
| Canonical JSON | `spec_hash` is SHA-256 over RFC 8785 canonical JSON. Key order, whitespace, and number formatting in the submitted document do not change the hash. |
| Deprecated names rejected | `ignore_fields` is a validator error. It is never aliased to `non_deterministic_fields`, so a stale submitter fails loudly instead of silently writing an artifact with the wrong exclusion set. |
| Dual-sweep retention | `needs_review` artifacts expire 30 days after creation. `verified` artifacts survive until both the pinned version pair is collected and 365 days have elapsed since verification - whichever moment is later. |
| Attempt monotonicity | `attempt_count` increases by 1 per retry of the same task spec. A submission with an `attempt_count` below the stored maximum is a 409 `attempt_count_regressed`. |

---

## Outputs

| Output | Description |
|--------|-------------|
| `artifact_id` | UUID of the stored artifact row |
| `agent_artifacts` row | `state` in `needs_review` -> `verified`, carrying `kind`, `spec_hash`, `attempt_count`, `touched_at` |
| `task_specs` row | Immutable spec with `spec_hash` and `rng_seed` |
| `artifact_version_pins` row | `(artifact_id, task_spec_version, process_definition_version)` written at verification |
| HTTP status | 201 fresh insert, 200 re-hit, 409 hash mismatch or attempt regression |
| Event log entries | `TaskSpecRegistered`, `ArtifactSubmitted`, `ArtifactVerified`, `ArtifactCollected` |

---

## SLAs & Escalations

| Timer | Duration | Trigger | Escalation Action |
|-------|----------|---------|-------------------|
| Needs-review TTL | 30 days | `created_at` on an unverified artifact | Sweep 1 deletes the row; the authoring agent must resubmit to restore it |
| Verified TTL | 365 days | `verified_at` | Sweep 2 becomes eligible once the pin is also collected |
| Pin release | Version pair collected | Pinned versions garbage-collected | Sweep 2 becomes eligible once the 365-day TTL has also elapsed |
| Sweeper cadence | Daily at 03:00 UTC | Scheduler tick | Sweep 1 runs first, then sweep 2 |
| Submission response | 500 ms | Artifact submission | Platform write NFR |

---

## Error / Exception Paths

| Error | Trigger | Recovery |
|-------|---------|---------|
| 400 `rng_seed_zero` | Task spec carries `rng_seed = 0` | Submitter supplies a non-zero seed; the spec identity changes |
| 400 `deprecated_field:ignore_fields` | Envelope uses the legacy field name | Submitter renames the field to `non_deterministic_fields` and resubmits |
| 400 `unknown_artifact_kind` | `kind` outside the enum | Submitter corrects `kind` to one of the four discriminants |
| 403 `wrong_environment` | Submission against a production deployment | Submit against the staging deployment; no production write path exists |
| 422 `artifact_payload_invalid` | Payload fails the schema selected by `kind` | Submitter fixes the payload at the reported JSON pointer |
| 409 `spec_hash_mismatch` | Same `(tenant_id, task_spec_id, attempt_count)` resubmitted with a different `spec_hash` | Submitter increments `attempt_count` or registers a new task spec |
| 409 `attempt_count_regressed` | `attempt_count` below the stored maximum for the spec | Submitter uses the next attempt number |
| 404 `task_spec_not_found` | `task_spec_id` unknown in this tenant | Orchestrating agent registers the spec before the artifact is submitted |
| Duplicate submission | Network retry of an accepted request | Step 8 returns 200 with the original `artifact_id`; exactly one row exists |
| Premature collection | Pin collected while the verified TTL is still running | Sweep 2 skips the row; deletion waits for the later moment |
| Sweeper crash mid-run | Process terminated between sweeps | The next daily tick re-runs both sweeps; state predicates make already-deleted rows a no-op |
