> The ingress gate SHALL close at `BPM_OUTBOX_DEPTH_CAP` and reopen only when depth falls to `BPM_OUTBOX_LOW_WATER`, fixed at 80 per cent of the cap with a default of 40000. It SHALL NOT reopen at the cap itself. Gate state SHALL be recorded per tenant in `plat_outbox_gate` with the timestamp of the last transition, and each reopen SHALL append `EXECUTION_OUTBOX_GATE_OPENED` carrying the duration the gate was closed.

**Acceptance Criteria:**
- GIVEN the cap is 50000 and depth oscillates between 49999 and 50001, WHEN requests arrive, THEN the gate stays closed until depth reaches 40000; it does not flip open and closed per request.
- GIVEN the gate is closed and the drainer reduces depth to 40000, WHEN the next external request arrives, THEN it is accepted and `EXECUTION_OUTBOX_GATE_OPENED` is appended with the closed duration.
- GIVEN the gate opens and closes within one 250 ms refresh interval, WHEN the transition is observed, THEN it is recorded as a defect indicating the low-water mark has been set equal to the cap, and the 80 per cent hysteresis is restored.
- GIVEN more than 100 refusals in one minute for a single tenant, WHEN the rate is evaluated, THEN Platform Admin is escalated, because the drainer is not keeping pace with the emit rate.
- GIVEN the gate has been closed for more than 300 s, WHEN the duration is evaluated, THEN Platform Admin is paged, the drainer is restarted, and the closed duration is recorded.
- Gate state is keyed per tenant schema, so one tenant's depth never refuses another tenant's ingress.

**See:** OBP-01 (cached depth and per-tenant keying), OBP-02 (the refusals counted here), OBP-03, OBS-05
