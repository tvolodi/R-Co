> **Extends:** SIM-01, promoting agent run output from a simulation artifact to a first-class stored envelope.

> An authoring agent SHALL submit its work through `POST /api/v1/agent/artifacts` as an envelope carrying `kind`, `task_spec_id`, `attempt_count`, `spec_hash`, `payload`, and `non_deterministic_fields`. `kind` is an enum over `test_report`, `design_artifact`, `patch_set`, `scenario_run` and SHALL discriminate the schema the `payload` is validated against. An envelope whose `kind` is outside the enum returns HTTP 400 `unknown_artifact_kind`; a payload that fails the schema selected by its `kind` returns HTTP 422 `artifact_payload_invalid` naming the failing JSON pointer.

**Acceptance Criteria:**
- GIVEN an envelope with `kind` of `test_report`, WHEN the payload is validated, THEN it is checked against the `test_report` schema and against no other schema.
- GIVEN an envelope with `kind` of `patch_set` carrying a `test_report` payload, WHEN it is validated, THEN the platform returns HTTP 422 `artifact_payload_invalid` with the JSON pointer of the first failing member, and writes no `agent_artifacts` row.
- GIVEN an envelope with `kind` of `benchmark`, WHEN it is parsed, THEN the platform returns HTTP 400 `unknown_artifact_kind` naming the received value and listing the four accepted discriminants.
- GIVEN a valid envelope, WHEN it is stored, THEN the `agent_artifacts` row carries `kind` as a column, and a query filtering on `kind` returns that row without parsing the payload.
- GIVEN an envelope carrying two payload members that each match a different `kind` schema, WHEN it is validated, THEN only the schema named by `kind` is applied and unrecognised members are rejected; the schema is closed, and unknown members are not ignored.
- The four payload schemas are versioned alongside the envelope and are published at `GET /api/v1/agent/artifacts/schemas`.

**See:** SIM-01, AGT-02, AGT-03, AGT-04, AGT-07, ENV-01
