> **Extends:** FIL-01, bounding a single upload before storage is contacted.

> A single upload SHALL be capped by the tenant's subscription tier: 10 MiB for `free`, 50 MiB for `standard`, 250 MiB for `enterprise`. The cap SHALL be enforced against the streamed part as it is read, and the platform SHALL abort with HTTP 413 `upload_exceeds_tier_cap` at the moment the byte count crosses the cap, before the object store is contacted and before any transaction is opened. The single-upload cap is independent of the tenant quota of FIL-03; a part under the cap can still be refused with HTTP 507.

**Acceptance Criteria:**
- GIVEN a `free`-tier tenant, WHEN a 12 MiB part is uploaded, THEN the platform returns HTTP 413 `upload_exceeds_tier_cap` carrying the tier name and the cap in bytes, and no object is written to the store.
- GIVEN a part whose declared `Content-Length` is under the cap but whose streamed body exceeds it, WHEN the byte count crosses the cap during the read, THEN the read is aborted at that byte and HTTP 413 is returned; the declared length is not trusted.
- GIVEN an `enterprise`-tier tenant, WHEN a 200 MiB part is uploaded and quota allows it, THEN the upload commits and `size_bytes` reads 209715200.
- GIVEN a tenant whose tier changes from `standard` to `free`, WHEN a 30 MiB upload is attempted after the change, THEN it is refused with HTTP 413; attachments stored under the prior tier stay readable.
- The cap check runs before the FIL-03 transaction opens, so a refused upload consumes no quota and emits no outbox row.

**See:** FIL-01, FIL-03, FIL-08, TNT-01
