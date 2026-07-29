> The platform SHALL change an instance's pins only through `POST /api/v1/instances/{id}/rebind-pins`, which takes explicit `{kind, ref, version}` entries and a mandatory reason, and appends `INSTANCE_PINS_REBOUND` recording the prior version, the new version, the actor and the reason for each changed entry. The operation is all-or-nothing and is rejected on a terminal instance. No automatic process upgrades a running instance's pins.

**Acceptance Criteria:**
- GIVEN a running instance, WHEN a valid rebind is submitted, THEN `INSTANCE_PINS_REBOUND` is appended carrying `prior_version`, `new_version`, actor and reason for each changed entry.
- GIVEN a rebind naming a reference absent from the current pin set, WHEN it is processed, THEN the platform returns HTTP 422 `UnknownPinRef` and applies none of the entries in the request.
- GIVEN an instance in `COMPLETED`, `CANCELLED` or `FAILED`, WHEN a rebind is submitted, THEN the platform returns HTTP 409 `InstanceNotRebindable`.
- GIVEN a rebind request with no reason field, WHEN it is validated, THEN the platform returns HTTP 422.
- No scheduled job, catalog publication or definition promotion changes the pin set of a running instance.

**See:** PIN-02, PIN-03, PIN-04, PRM-08, ADP-11
