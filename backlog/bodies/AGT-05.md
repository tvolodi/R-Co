> **Extends:** AGT-04, binding run determinism into spec identity.

> A task spec SHALL carry `rng_seed` as a uint64, SHALL be rejected with HTTP 400 `rng_seed_zero` when that value is 0, and SHALL fold `rng_seed` into the canonical JSON before `spec_hash` is computed. Two specs that differ only in their seed therefore carry different identities, and an agent cannot reuse one spec identity for runs that would diverge. A zero seed is refused rather than defaulted, so an unset seed cannot silently produce a run whose determinism is unrecorded.

**Acceptance Criteria:**
- GIVEN a spec with `rng_seed` of 0, WHEN it is registered, THEN the platform returns HTTP 400 `rng_seed_zero` and writes no `task_specs` row.
- GIVEN a spec with `rng_seed` absent, WHEN it is registered, THEN the platform returns HTTP 400 `rng_seed_zero`; no default seed is substituted.
- GIVEN two specs identical apart from `rng_seed` values 42 and 43, WHEN both are registered, THEN their `spec_hash` values differ and both rows persist.
- GIVEN a spec registered with `rng_seed` of 42, WHEN an artifact is submitted claiming a `spec_hash` computed with `rng_seed` omitted from the canonical form, THEN the hashes differ and the submission returns HTTP 409 `spec_hash_mismatch`.
- GIVEN a scenario run replayed with the stored spec, WHEN the seed is read from the spec rather than from the environment, THEN the replay uses the same seed that produced the original artifact.
- `rng_seed` is serialised in the canonical JSON as an unsigned integer with no exponent form, so its contribution to `spec_hash` is stable across submitters.

**See:** AGT-04, AGT-03, SIM-01, AGT-06
