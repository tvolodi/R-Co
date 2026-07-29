> The platform SHALL record the resolved pin set as the `pinned_versions[]` field of the `INSTANCE_STARTED` event payload, appended in the same transaction as the instance row insert. The event log is the record of record for pins; no side table stores them.

**Acceptance Criteria:**
- GIVEN an instance start commits, WHEN the event log is read, THEN `INSTANCE_STARTED` carries one `pinned_versions[]` entry per enumerated reference plus one entry of kind `variable_schema`.
- GIVEN the `INSTANCE_STARTED` append fails, WHEN the transaction ends, THEN it rolls back and no instance row exists, so no committed instance has an unrecorded pin set.
- GIVEN a request for the effective pin set, WHEN it is served, THEN the values come from the event log; no pin table is queried.
- GIVEN a definition carrying zero service catalog and zero module references, WHEN the instance starts, THEN `pinned_versions[]` contains exactly the `variable_schema` entry.
- Every entry records `source` as `resolved`, `override` or `inherited`.

**See:** PD-08, PIN-01, PIN-04, ES-07, IR-07
