> The outbox SHOULD have a per-tenant depth cap `BPM_OUTBOX_DEPTH_CAP`, read from the environment at startup with a default of 50000 and never inferred from disk, memory, or observed throughput. Depth SHALL be read from a cached counter that the outbox drainer refreshes every 250 ms; no request path SHALL issue `SELECT count(*) FROM plat_outbox`. A cached value older than 5 s SHALL be treated as at-cap.

**Acceptance Criteria:**
- GIVEN the drainer is running, WHEN it completes a publish cycle, THEN it writes the current pending-row count to the shared counter, and the counter is no more than 250 ms behind the table.
- GIVEN an ingress request, WHEN the depth check runs, THEN it reads one cached integer and adds under 1 ms to the request; no `count(*)` is executed on the request path.
- GIVEN the counter has not been refreshed for more than 5 s, WHEN the depth check runs, THEN depth is treated as at-cap and the gate closes; loss of depth visibility closes ingress rather than opening it.
- GIVEN two tenants, WHEN one reaches its cap, THEN the other tenant's depth, gate state, and refusal counters are unaffected; all of them are keyed per tenant schema.
- `BPM_OUTBOX_DEPTH_CAP` and `BPM_OUTBOX_LOW_WATER` are documented in `.env.example` with their defaults and their empty-value behaviour.

**See:** OBP-02 (external refusal reading this depth), OBP-03 (internal overflow reading this depth), OBP-04 (the hysteresis gate), API-10 (rate limiting, a separate control on a different dimension)
