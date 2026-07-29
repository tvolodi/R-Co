> The platform SHALL release the claimed sandbox on every exit path of the assertion re-run, including assertion failure, infrastructure failure and panic. A release failure appends `PROMOTION_ASSERTION_TEARDOWN_FAILED`, sets `promotion_assertion_runs.status` to `teardown_failed`, and is surfaced on the promotion read endpoint, but never converts a passing run into a promotion failure.

**Acceptance Criteria:**
- GIVEN every assertion passed and the sandbox release then fails, WHEN the pipeline continues, THEN the promotion applies, `promotion_assertion_runs.status` is `teardown_failed`, and `PROMOTION_ASSERTION_TEARDOWN_FAILED` is appended.
- GIVEN the assertion replay panics, WHEN the panic unwinds, THEN the sandbox release is still invoked before the error is returned.
- GIVEN a teardown failure was recorded, WHEN `GET /api/v1/promotions/{id}` is called, THEN the response names the failed teardown and the sandbox identifier.
- A teardown failure never sets `promotion_reviews.status` to `failed` and never blocks the version pointer move.
- GIVEN a leaked sandbox, WHEN the sandbox reaper next runs, THEN the sandbox is reclaimed and the reclamation is recorded against the same run.

**See:** PRM-06, PRM-04, ENV-01, ENV-03
