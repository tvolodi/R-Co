> **Extends:** ENV-01, confining agent artifacts to non-production environments.

> Agent artifacts SHALL persist only in the `staging` schema of a non-production deployment. A submission handled by a deployment whose environment class is `production` SHALL return HTTP 403 `wrong_environment` before the payload is parsed and before any schema validation runs. The environment class SHALL be read from deployment configuration; an `environment` field present in the request body or in a header is discarded and never consulted.

**Acceptance Criteria:**
- GIVEN a production deployment, WHEN an artifact is submitted, THEN the platform returns HTTP 403 `wrong_environment`, writes no row, and records no payload content in logs.
- GIVEN a production deployment, WHEN a submission carries a valid envelope, THEN the environment check runs before schema selection, so an invalid payload on a production deployment still yields HTTP 403 `wrong_environment` and never HTTP 422.
- GIVEN a request body carrying `"environment": "staging"` against a production deployment, WHEN it is handled, THEN the field is discarded and the response is HTTP 403 `wrong_environment`.
- GIVEN a staging deployment, WHEN an artifact is submitted and accepted, THEN the row is written to the `staging` schema and no artifact table exists in the production schema.
- GIVEN a promotion of platform code from staging to production, WHEN the production deployment starts, THEN the artifact submission route is present and returns HTTP 403 `wrong_environment` for every call; the route is not removed, so its absence cannot be probed.
- Every rejected submission appends `ArtifactSubmissionRejected` with the environment class and the calling principal.

**See:** ENV-01, ENV-03, AGT-01, AGT-03, SBX-01, OBS-03
