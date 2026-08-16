# Test Spec: OBP-04 — Outbox gate hysteresis and escalation

**Requirement:** OBP-04 — The ingress gate SHALL close at `BPM_OUTBOX_DEPTH_CAP` and reopen only
when depth falls to `BPM_OUTBOX_LOW_WATER`, fixed at 80 per cent of the cap with a default of
40000. It SHALL NOT reopen at the cap itself. Gate state SHALL be recorded per tenant in
`plat_outbox_gate` with the timestamp of the last transition, and each reopen SHALL append
`EXECUTION_OUTBOX_GATE_OPENED` carrying the duration the gate was closed.

**Priority:** SHOULD
**Test layer:** unit (`decide` pure hysteresis + `deriveLowWater`) + integration (real
`evaluateAndDecide` / `recordRefusal` / `evaluateEscalations` against `plat_outbox_gate` +
`public.events`)
**Test-tier score (test_developer_guide.md §2.1):** DB schema (2, migration 1164 creates
`plat_outbox_gate`) + tenant isolation (2, gate state is keyed per tenant schema — AC6) = **4
points → sandbox tier by the rubric's raw score** — same note as `tests/specs/ORD-01.md`: no
Wasm/sandbox surface exists for this outbox family, so unit + integration against real Postgres
is the proportionate ceiling.
**Design:** `src/design/obp-04-outbox-gate-hysteresis-escalation.md`
**Implementation:** `src/outbox/gate.zig` (`decide`, `readGate`, `evaluateAndDecide`,
`recordRefusal`, `evaluateEscalations`), migration `1164_obp04_plat_outbox_gate.sql`

---

## Acceptance criteria mapping

| # | Acceptance criterion (verbatim from `docs/requirements.yaml`) | Test case(s) |
|---|---|---|
| AC1 | GIVEN the cap is 50000 and depth oscillates between 49999 and 50001, WHEN requests arrive, THEN the gate stays closed until depth reaches 40000; it does not flip open and closed per request. | `obp04: gate stays closed on 49999/50001 oscillation until low-water (AC1)` (unit `decide`) + `TC-OBP-04-AC1-evaluate-oscillation` (integration through `evaluateAndDecide`) |
| AC2 | GIVEN the gate is closed and the drainer reduces depth to 40000, WHEN the next external request arrives, THEN it is accepted and `EXECUTION_OUTBOX_GATE_OPENED` is appended with the closed duration. | `TC-OBP-04-AC2-reopen-appends-event` (integration) + `obp04_plat_outbox_gate: reopen_persists_transition_and_duration` (schema test) |
| AC3 | GIVEN the gate opens and closes within one 250 ms refresh interval, WHEN the transition is observed, THEN it is recorded as a defect indicating the low-water mark has been set equal to the cap, and the 80 per cent hysteresis is restored. | `obp04: open+close within one refresh interval flags flapping (AC3)` (unit `decide`) + `TC-OBP-04-AC3-flapping-restores-low-water` (integration) |
| AC4 | GIVEN more than 100 refusals in one minute for a single tenant, WHEN the rate is evaluated, THEN Platform Admin is escalated, because the drainer is not keeping pace with the emit rate. | `TC-OBP-04-AC4-refusal-threshold-crossing` (integration `recordRefusal`) + `TC-OBP-04-AC4-escalation-alert` (integration `evaluateEscalations` with alert hook) |
| AC5 | GIVEN the gate has been closed for more than 300 s, WHEN the duration is evaluated, THEN Platform Admin is paged, the drainer is restarted, and the closed duration is recorded. | `TC-OBP-04-AC5-closed-duration-page` (integration `evaluateEscalations` with alert hook) + `obp04_plat_outbox_gate: closed_gate_sweep_finds_long_closed_tenant` (schema partial-index test) |
| AC6 | Gate state is keyed per tenant schema, so one tenant's depth never refuses another tenant's ingress. | `obp04_plat_outbox_gate: per_tenant_keying_keeps_rows_independent` (schema test) |

---

## Test cases

### obp04: gate stays closed on 49999/50001 oscillation until low-water (AC1)
**Given:** `decide(.closed, 49999, 50000, 40000, 250, 1000)`, then `decide(.closed, 50001, ...)`,
then `decide(.closed, 40000, ...)`.
**When:** Each is evaluated.
**Then:** `remain_closed` for 49999 and 50001 (does NOT reopen at the cap or above it);
`reopen_now` only at 40000 — no per-request open/closed flip.
**Layer:** unit
**Acceptance criterion mapped:** AC1
**Zig test:** `obp04: gate stays closed on 49999/50001 oscillation until low-water (AC1)` (in `src/outbox/gate.zig`)

### TC-OBP-04-AC1-evaluate-oscillation: evaluateAndDecide keeps a closed gate closed through the oscillation
**Given:** A seeded closed gate (state='closed', cap 50000, low_water 40000) in `plat_outbox_gate`.
**When:** `evaluateAndDecide` is called with depth 49999, then 50001, then 40000.
**Then:** The first two return `remain_closed` and leave state='closed'; the third returns
`reopen_now` and flips state='open' — the gate does not flip per request.
**Layer:** integration
**Acceptance criterion mapped:** AC1 (end-to-end through the persistence path)
**Zig test:** `TC-OBP-04-AC1-evaluate-oscillation` (`tests/integration/obp04_gate_test.zig`)

### obp04: gate closes at cap and reopens only at low-water (AC1/AC2)
**Given:** `decide(.open, 49999, ...)`, `decide(.open, 50000, ...)`, `decide(.closed, 41000, ...)`.
**When:** Each is evaluated.
**Then:** `remain_open` under the cap; `close_now` at the cap; `remain_closed` above low-water
while closed.
**Layer:** unit
**Acceptance criterion mapped:** AC1/AC2
**Zig test:** `obp04: gate closes at cap and reopens only at low-water (AC1/AC2)` (in `src/outbox/gate.zig`)

### TC-OBP-04-AC2-reopen-appends-event: reopen at low-water appends EXECUTION_OUTBOX_GATE_OPENED with the closed duration
**Given:** A seeded closed gate (state='closed', depth 49999, cap 50000, low_water 40000,
`closed_at = now() - interval '10 seconds'`).
**When:** `evaluateAndDecide` is called with depth 40000.
**Then:** Returns `reopen_now`; the row flips to state='open' with `closed_duration_ms >= 10000`
(≈10 s); a `public.events` row with `event_type = 'EXECUTION_OUTBOX_GATE_OPENED'` exists whose
payload carries `tenant_schema` and the closed duration — the state write and the event append
share one transaction.
**Layer:** integration
**Acceptance criterion mapped:** AC2
**Zig test:** `TC-OBP-04-AC2-reopen-appends-event` (`tests/integration/obp04_gate_test.zig`)

### obp04_plat_outbox_gate: reopen_persists_transition_and_duration
**Given:** A seeded closed gate (closed 400 s ago).
**When:** The reopen UPDATE runs (state='open', depth 40000, closed_duration_ms from closed_at).
**Then:** The row reads state='open', depth=40000, closed_duration_ms >= 400000 — the data AC2's
event carries.
**Layer:** integration (schema)
**Acceptance criterion mapped:** AC2
**Zig test:** `obp04_plat_outbox_gate: reopen_persists_transition_and_duration`

### obp04: open+close within one refresh interval flags flapping (AC3)
**Given:** `decide(.closed, 40000, 50000, 50000, 250, 100)` (transition within 250 ms of the last)
and `decide(.closed, 40000, 50000, 40000, 250, 60000)` (long after).
**When:** Each is evaluated.
**Then:** The quick transition reports `flapping == true`; the slow one reports `flapping == false`.
**Layer:** unit
**Acceptance criterion mapped:** AC3
**Zig test:** `obp04: open+close within one refresh interval flags flapping (AC3)` (in `src/outbox/gate.zig`)

### TC-OBP-04-AC3-flapping-restores-low-water: a detected defect restores the 80% hysteresis mark
**Given:** A seeded closed gate with `low_water = 40001` (misconfigured, not 80%) and
`last_transition_at = now()` (so the next transition is within one refresh interval).
**When:** `evaluateAndDecide` is called with depth 40000 (a reopen_now transition).
**Then:** `flapping` is detected and the row's `low_water` is rewritten to
`deriveLowWater(cap) = 40000` — the 80% hysteresis mark is restored in place.
**Layer:** integration
**Acceptance criterion mapped:** AC3
**Zig test:** `TC-OBP-04-AC3-flapping-restores-low-water` (`tests/integration/obp04_gate_test.zig`)

### obp04: deriveLowWater restores 80% hysteresis (AC3)
**Given:** `deriveLowWater(50000)` and `deriveLowWater(100)`.
**When:** Evaluated.
**Then:** Returns `40000` and `80` respectively — `floor(cap * 4 / 5)`.
**Layer:** unit
**Acceptance criterion mapped:** AC3
**Zig test:** `obp04: deriveLowWater restores 80% hysteresis (AC3)` (in `src/outbox/gate.zig`)

### TC-OBP-04-AC4-refusal-threshold-crossing: recordRefusal returns true past the 100/min threshold
**Given:** A config with `refusal_threshold_per_minute = 3` and a fresh gate row.
**When:** `recordRefusal` is called 4 times.
**Then:** The first 3 calls return `false` (count 1, 2, 3 — at threshold, not above); the 4th
returns `true` (count 4 > 3); `refusal_count_1m` in the row is 4.
**Layer:** integration
**Acceptance criterion mapped:** AC4
**Zig test:** `TC-OBP-04-AC4-refusal-threshold-crossing` (`tests/integration/obp04_gate_test.zig`)

### TC-OBP-04-AC4-escalation-alert: evaluateEscalations escalates Platform Admin past the refusal rate
**Given:** A gate row with `refusal_count_1m > refusal_threshold_per_minute` (seeded above the
threshold), and an alert hook that records invocations.
**When:** `evaluateEscalations` runs.
**Then:** The alert hook fires exactly once with `severity == .escalate` and a detail naming the
tenant schema.
**Layer:** integration
**Acceptance criterion mapped:** AC4
**Zig test:** `TC-OBP-04-AC4-escalation-alert` (`tests/integration/obp04_gate_test.zig`)

### TC-OBP-04-AC5-closed-duration-page: evaluateEscalations pages Platform Admin past 300 s closed
**Given:** A gate row with `state = 'closed'` and `closed_duration_ms = 400000` (≥ 300 s), and an
alert hook that records invocations.
**When:** `evaluateEscalations` runs.
**Then:** The alert hook fires exactly once with `severity == .page` and a detail naming the tenant
and the closed duration (the drainer-restart is the operator action the page triggers).
**Layer:** integration
**Acceptance criterion mapped:** AC5
**Zig test:** `TC-OBP-04-AC5-closed-duration-page` (`tests/integration/obp04_gate_test.zig`)

### obp04_plat_outbox_gate: closed_gate_sweep_finds_long_closed_tenant
**Given:** A closed gate (closed 400 s ago) and an open gate for another tenant.
**When:** The AC5 sweep query (`state = 'closed' AND closed_at <= now() - interval '300 seconds'`)
runs.
**Then:** Only the long-closed tenant is found; the open gate is excluded (the partial index scans
only closed gates).
**Layer:** integration (schema)
**Acceptance criterion mapped:** AC5
**Zig test:** `obp04_plat_outbox_gate: closed_gate_sweep_finds_long_closed_tenant`

### obp04_plat_outbox_gate: per_tenant_keying_keeps_rows_independent
**Given:** A closed gate for tenant A (depth 49999) and an open gate for tenant B (depth 1000).
**When:** Both rows are read.
**Then:** Two independent rows exist with distinct state/depth — tenant A's depth never touches
tenant B's row (AC6).
**Layer:** integration (schema)
**Acceptance criterion mapped:** AC6
**Zig test:** `obp04_plat_outbox_gate: per_tenant_keying_keeps_rows_independent`

### obp04_plat_outbox_gate: state_check_constraint_rejects_unknown_value
**Given:** An INSERT with `state = 'flapping'`.
**When:** Executed.
**Then:** Fails with `error.ServerError` (SQLSTATE 23514) — state is open/closed only; flapping is
recorded as data, never persisted as a state.
**Layer:** integration (schema contract)
**Acceptance criterion mapped:** supports AC3 (flapping is a defect datum, not a state)
**Zig test:** `obp04_plat_outbox_gate: state_check_constraint_rejects_unknown_value`

### obp04_plat_outbox_gate: low_water_must_be_below_cap
**Given:** An INSERT with `low_water = 50000` (equal to the cap).
**When:** Executed.
**Then:** Fails (SQLSTATE 23514) — a gate can never be configured to reopen at the cap (AC3's
defect is unpersistable and must be repaired by restoring `floor(cap * 4 / 5)`).
**Layer:** integration (schema contract)
**Acceptance criterion mapped:** AC3
**Zig test:** `obp04_plat_outbox_gate: low_water_must_be_below_cap`

### obp04_plat_outbox_gate: low_water_must_be_below_cap_above_cap
**Given:** An INSERT with `low_water = 60000` (above the cap).
**When:** Executed.
**Then:** Fails (SQLSTATE 23514) — same 80%-hysteresis invariant (AC3).
**Layer:** integration (schema contract)
**Acceptance criterion mapped:** AC3
**Zig test:** `obp04_plat_outbox_gate: low_water_must_be_below_cap_above_cap`

---

## Run status (2026-08-16, `test-integration-obp04-gate`)
6/6 integration gate tests pass (`TC-OBP-04-AC1..AC5`); 4/4 module unit tests pass; 6/6 schema
contract tests pass. Full OBP-04 suite green — no implementation defects found.


---

## Fixture isolation
Integration tests run on a `TestHarness` connection (single transaction rolled back on deinit) for
the gate row + event writes, so no fixture leaks. All tenant schemas use per-test UUID-derived
names. Alert-hook recording uses module-level `const std.atomic.Value` counters (immutable binding,
no module-level `var` — T020 clean).
