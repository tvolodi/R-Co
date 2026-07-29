> The platform SHALL read the effective pin set during state reconstruction from `INSTANCE_STARTED` and the most recent `INSTANCE_PINS_REBOUND` event, never from the live service catalog or module registry. A sub-process child instance inherits its parent's pin set and adds entries only for references the parent does not carry. `GET /api/v1/instances/{id}/pins` returns the effective set with the source event identifier for each entry.

**Acceptance Criteria:**
- GIVEN a completed instance whose catalog has changed since it ran, WHEN its state is reconstructed, THEN the reconstructed dependency versions equal the versions recorded in `INSTANCE_STARTED`.
- GIVEN a child instance started with `parent_instance_id`, WHEN its pin set is written, THEN entries for references the parent already pins carry `source = inherited` and the parent's version.
- GIVEN a child reference that resolves to a version differing from an inherited pin, WHEN the child starts, THEN the inherited pin is used and the conflict is recorded in the child's `INSTANCE_STARTED` payload.
- GIVEN a call to `GET /api/v1/instances/{id}/pins`, WHEN it is served, THEN each entry names the event identifier it was read from.
- Reconstruction issues no read against the service catalog or the module registry.

**See:** PIN-02, PIN-03, PIN-05, IR-07, XC-05, PLC-01
