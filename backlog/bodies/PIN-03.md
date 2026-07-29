> The platform SHALL resolve every versioned dependency during execution through the instance's pin set. A reference with no pin entry raises the typed error `PinMissing` and the step enters the standard retry then dead-letter path. The engine SHALL NOT resolve the current active version in place of a missing pin, and retiring or deprecating a pinned version SHALL NOT affect instances already pinned to it.

**Acceptance Criteria:**
- GIVEN a node whose reference has no entry in the pin set, WHEN the node executes, THEN `PinMissing` is raised naming the reference and no catalog lookup for the latest version occurs.
- GIVEN a newer catalog entry version is published while an instance is in flight, WHEN the instance next reaches a SERVICE_TASK using that reference, THEN it invokes the pinned version.
- GIVEN the pinned catalog entry version is set to DEPRECATED after the instance started, WHEN the node executes, THEN execution proceeds on the pinned version.
- GIVEN the retry budget for a `PinMissing` step is exhausted, WHEN the last retry fails, THEN the step lands in the dead-letter queue with the reference name in the payload.
- No code path substitutes the current active version for a missing or unresolvable pin entry.

**See:** PIN-01, PIN-02, PIN-05, REPO-07, PLC-01, EE-05
