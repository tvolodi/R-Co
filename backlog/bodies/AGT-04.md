> **Extends:** PD-08, applying content-addressed immutability to agent task specs.

> A task spec SHALL be immutable once written. Its identity SHALL be `spec_hash`, the SHA-256 of the RFC 8785 canonical JSON serialisation of the spec document, stored as 64 lowercase hex characters in `task_specs.spec_hash`. Key order, insignificant whitespace, and number formatting in the submitted document SHALL NOT change the hash. A changed spec is a new spec with a new `task_spec_id` and a new `spec_hash`; there is no update path on `task_specs`.

**Acceptance Criteria:**
- GIVEN one spec document serialised twice with different key orders and different insignificant whitespace, WHEN both are canonicalised and hashed, THEN both produce the same 64-character `spec_hash`.
- GIVEN a spec whose numeric field is written as `1.0` in one submission and `1` in another, WHEN both are canonicalised, THEN RFC 8785 number formatting is applied and the resulting hashes are equal.
- GIVEN a stored `task_specs` row, WHEN any update to its spec document is attempted, THEN the platform returns HTTP 409 `task_spec_immutable` and the stored row is unmodified.
- GIVEN a spec differing from a stored spec in exactly one field value, WHEN it is registered, THEN it receives a different `spec_hash` and a different `task_spec_id`, and the stored spec remains addressable.
- GIVEN an artifact submitted with a `spec_hash` that matches no `task_specs` row in the tenant, WHEN it is handled, THEN the platform returns HTTP 404 `task_spec_not_found`.
- `spec_hash` covers the server-set `orchestrator_principal` of SBX-02, so a spec cannot be re-registered under a different orchestrator identity without changing its hash.

**See:** PD-08, REPO-07, AGT-03, AGT-05, SBX-02, PIN-01
