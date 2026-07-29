> **Extends:** AGT-01, refusing silent compatibility shims on the envelope.

> A deprecated envelope field name SHALL be rejected as a validator error and SHALL NOT be aliased to its replacement. The legacy name `ignore_fields` SHALL return HTTP 400 `deprecated_field:ignore_fields` naming the replacement `non_deterministic_fields`; the submitted value is discarded and no artifact row is written. A stale submitter therefore fails loudly at the boundary rather than storing an artifact whose exclusion set was read from a field the platform no longer defines.

**Acceptance Criteria:**
- GIVEN an envelope carrying `ignore_fields`, WHEN it is validated, THEN the platform returns HTTP 400 `deprecated_field:ignore_fields` with the replacement name in the response body, and writes no `agent_artifacts` row.
- GIVEN an envelope carrying both `ignore_fields` and `non_deterministic_fields`, WHEN it is validated, THEN the same HTTP 400 is returned; the presence of the current field does not excuse the deprecated one.
- GIVEN an envelope carrying `ignore_fields` with an empty array, WHEN it is validated, THEN the same HTTP 400 is returned; an empty deprecated field is still an error.
- GIVEN a deprecated field is rejected, WHEN the stored artifact set is inspected, THEN no row exists whose `non_deterministic_fields` column was populated from a deprecated name.
- GIVEN a future field rename, WHEN the replacement is introduced, THEN the prior name is added to the deprecated-name set with its own `deprecated_field:<name>` identifier rather than to an alias map.
- The deprecated-name check runs before payload schema validation, so a submitter using a deprecated name receives HTTP 400 rather than HTTP 422.

**See:** AGT-01, AGT-03, API-10
