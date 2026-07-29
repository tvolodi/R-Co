> **Extends:** SBX-01, making the orchestrator identity server-authoritative.

> The task-spec handler SHALL set `spec.orchestrator_principal` to the subject of the verified token before the spec is canonicalised, and SHALL discard any `orchestrator_principal` present in the request body without raising an error. The persisted JSON is therefore authoritative, and because canonicalisation precedes hashing, the AGT-04 `spec_hash` covers the server-set value. A spec cannot be registered under an orchestrator identity the caller does not hold.

**Acceptance Criteria:**
- GIVEN a token whose subject is `orch-a`, WHEN a spec is submitted with no `orchestrator_principal` in the body, THEN the persisted spec carries `orchestrator_principal` of `orch-a`.
- GIVEN a token whose subject is `orch-a`, WHEN a spec is submitted with `"orchestrator_principal": "orch-b"` in the body, THEN the submitted value is discarded, the persisted spec carries `orch-a`, and no error is returned.
- GIVEN the same submission, WHEN `spec_hash` is computed, THEN it is computed over the canonical JSON carrying `orch-a`, so a client that computed its hash over `orch-b` receives HTTP 409 `spec_hash_mismatch` on artifact submission.
- GIVEN two orchestrators submit byte-identical spec bodies, WHEN both are persisted, THEN their canonical forms differ in `orchestrator_principal` and their `spec_hash` values differ.
- GIVEN a persisted spec, WHEN it is read back, THEN `orchestrator_principal` matches the token subject recorded in the `TaskSpecSubmitted` audit entry for that submission.
- The force-set runs before canonicalisation, so no code path hashes a client-supplied principal.

**See:** SBX-01, AGT-04, AGT-05, IDN-05, OBS-03
