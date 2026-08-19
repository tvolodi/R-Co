# Test Specification: AGT-05 — Non-zero RNG Seed Folded into Spec Identity

**Requirement:** AGT-05  
**Run ID:** WF02-agt05-07-20260819  
**Test file:** tests/integration/test_agt05_07.zig  

---

## Summary

AGT-05 requires that `rng_seed` is mandatory and non-zero on `POST /api/v1/agent/task-specs`,
and that its value is included in the canonical JSON before `spec_hash` is computed. A zero
or absent seed returns HTTP 400 `rng_seed_zero`. Two specs differing only in `rng_seed` have
different `spec_hash` values and are stored as separate rows.

---

## Test Cases

| ID | Title | Inputs | Expected |
|---|---|---|---|
| TC-AGT05-01 | Zero seed rejected | `rng_seed: 0` in body | HTTP 400, `detail: rng_seed_zero`, no `task_specs` row |
| TC-AGT05-02 | Absent seed rejected | No `rng_seed` in body | HTTP 400, `detail: rng_seed_zero`, no `task_specs` row |
| TC-AGT05-03 | Differing seeds produce different hashes | Two specs identical except `rng_seed: 42` vs `rng_seed: 43` | Both return HTTP 201; spec_hash values differ; both rows persist |
| TC-AGT05-04 | Artifact with wrong spec_hash mismatch | Register spec with seed; submit artifact using spec_hash computed without seed | HTTP 409 `spec_hash_mismatch` |
| TC-AGT05-05 | Seed serialised as unsigned integer | Submit spec with large positive rng_seed; fetch stored row | `rng_seed` column value matches submitted value |

---

## Notes

- AC5 (replay uses stored rng_seed) is a SIM-01 concern; test TC-AGT05-05 verifies only that
  the value is persisted stably, not replay behaviour.
- All test blocks use per-test UUIDs and clean up via `defer`.
- No `error.SkipZigTest` is used on any test block.
