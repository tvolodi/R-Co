> The platform SHALL re-run the assertions carried by the promotion artifact as a pre-production gate, in an ephemeral sandbox built from the promotion-candidate definitions and loaded with only the artifact's `fixtures[]`. The replay runs under a frozen clock, an RNG seeded from the artifact's `rng_seed`, and the stub effect recorder, and strips `non_deterministic_fields` before comparison. Each run is recorded in `promotion_assertion_runs` with `UNIQUE (tenant_id, idempotency_key)` and key `promotion_rerun:<review_id>:<plan_digest>`.

**Acceptance Criteria:**
- GIVEN apply is called twice for the same review and digest, WHEN the second call runs, THEN it returns the outcome already recorded under the idempotency key and claims no second sandbox.
- GIVEN organic rows exist in the source tenant, WHEN the sandbox is loaded, THEN the sandbox contains only the rows named in `fixtures[]`.
- GIVEN the same artifact is replayed twice, WHEN results are compared after stripping `non_deterministic_fields`, THEN the two result sets are identical.
- GIVEN any assertion fails, WHEN the run completes, THEN `promotion_assertion_runs.status` is `failed`, the review moves `approved` to `failed`, the platform returns HTTP 422 listing the failing assertion identifiers, and the target active version pointer is unchanged.
- GIVEN no ephemeral sandbox becomes free within 60 seconds, WHEN the claim times out, THEN the platform returns HTTP 503 `SandboxUnavailable` and the review remains `approved`.

**See:** PRM-04, PRM-05, PRM-07, ENV-01, ENV-03
