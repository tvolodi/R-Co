# Module: obp-04-outbox-gate-hysteresis-escalation

**Requirement ID:** OBP-04
**Run ID:** WF02-batch-7-20260816 (Stage 16)
**Type:** Type E (gate state machine + escalation) + Type C (`plat_outbox_gate` migration)
**Extends:** the outbox backpressure family (OBP-01/02/03, described by
`docs/processes/system/outbox-backpressure.md` — PW-08) and the existing outbox
implementation `src/effects/queue.zig` + `src/effects/worker.zig` (EXP-301, the
`effects_outbox` table). OBP-04 owns the gate state, the hysteresis rule, and the two
escalation thresholds; OBP-01/02/03 (future requirements) own the depth counter, the
ingress refusal, and the internal `OutboxOverflow` emit path that call into this gate.
**Authoritative process source:** `docs/processes/system/outbox-backpressure.md`
(`sys-outbox-backpressure`, PW-08) — steps 12-14, the Business Rules (Hysteresis,
Per-tenant accounting), the Outputs table (`plat_outbox_gate`,
`EXECUTION_OUTBOX_GATE_OPENED`), and the SLAs & Escalations table (refusal-rate
escalation, gate-closed-duration escalation, `GateFlapping`) fully specify the
behaviour this design translates into Zig module boundaries and the Type C migration.
**See also (referenced, not implemented here):** OBS-05 (the DLQ the drainer feeds),
OBS-06 (`docs/design/obs-06-alerting-hooks.md` — the Platform Admin escalation channel
AC4/AC5 require), DDL-05 (the `plat_` prefix rule the `plat_outbox_gate` name satisfies),
DB-02 (pooled connections for the drainer's depth refresh).

---

## Classification rationale

Applying `templates/lego-catalog.md`'s selection rules in order:

1. **Type C — yes, for the schema.** OBP-04 requires per-tenant gate state to be
   recorded ("Gate state SHALL be recorded per tenant in `plat_outbox_gate` with the
   timestamp of the last transition"). `plat_outbox_gate` does **not** exist in the
   codebase (confirmed: `grep -r "plat_outbox_gate" src/ migrations/` matches only the
   process doc's prose). One Type C migration YAML is produced alongside this document:
   `templates/specs/obp-04-plat-outbox-gate.migration.yaml`.
2. **Type E — yes, for the gate logic.** The hysteresis state machine (close at cap,
   reopen only at the 80% low-water mark), the flapping defect detection, and the two
   escalation paths are genuinely novel cross-cutting logic — lego-catalog.md's
   "cross-module orchestration" bucket — with no CRUD template shape.

So this batch produces: **1 Type C migration YAML + 1 Type E design document** (this file).

## Existing pattern found and followed

Per the handoff's instruction to ground every design in a prior pattern:

| Aspect | Precedent | OBP-04 (this design) |
|---|---|---|
| Shared in-process counters | `src/obs/metrics.zig` (Prometheus-style in-process counters) and `src/ordering/observability.zig` (`std.atomic.Value` counters for the ordering family) | Followed for the refusal-rate counter feeding AC4's 100/min threshold |
| Rolling rate window | `src/api/middleware/ratelimit.zig` (sliding-window rate limiting) | Followed for AC4's "more than 100 refusals in one minute" — reuse the existing windowing mechanism rather than introducing a second |
| Alarm/escalation channel | `src/design/obs-06-alerting-hooks.md` (Platform Admin alerting) | Followed for both AC4 (escalate) and AC5 (page + restart) — referenced, not re-derived |
| Event append conventions | `src/design/ISS-0670-platform-event-convention.md` (the `EXECUTION_*` event family, seeded in `migrations/1152_iss0670_platform_event_types_seed.sql`) | Followed for `EXECUTION_OUTBOX_GATE_OPENED` (AC2) and the flapping defect event (AC3) |
| Drainer cadence | `src/effects/worker.zig` (a background poll loop refreshing outbox state every `poll_interval_ms`) | Followed as the refresh cadence the gate's 250 ms depth-refresh and the "one refresh interval" flapping window (AC3) hang off |

**Deliberately NOT re-derived:** the ingress refusal path (OBP-02), the internal
`error.OutboxOverflow` emit path (OBP-03), and the cached depth counter (OBP-01) are all
future requirements described by the process doc but not yet implemented in this
codebase. This design defines the **gate interface those modules will call** — it does
not implement the refusal middleware or the emit path, because those are not OBP-04's
acceptance criteria. The gate module is written so OBP-01/02/03 can consume it without
a signature change.

## Module purpose

`src/outbox/gate.zig` (new) implements the per-tenant outbox ingress gate: the single
decision function that says whether ingress is currently open or closed for a tenant,
governed by hysteresis — the gate closes when the tenant's cached outbox depth reaches
`BPM_OUTBOX_DEPTH_CAP`, and reopens only when depth falls to `BPM_OUTBOX_LOW_WATER`
(fixed at 80 per cent of the cap, default 40000). It records every transition's state
and timestamp in `plat_outbox_gate`, appends `EXECUTION_OUTBOX_GATE_OPENED` (with the
closed duration) on each reopen, detects the gate-flapping defect that signals a
misconfigured low-water mark, and owns the two Platform Admin escalations: refusal rate
over 100/min (AC4) and closed duration over 300 s (AC5). It is keyed per tenant schema,
so one tenant's depth never refuses another tenant's ingress (AC6).

The gate is **not** the ingress middleware and **not** the drainer: it is the state
machine both consult. OBP-02's middleware calls `evaluateAndDecide` to learn open/closed
and to record a refusal; OBP-01's drainer calls the same function with the refreshed
depth to learn whether a reopen has occurred.

## Public interface

### `src/outbox/gate.zig` — gate state machine and escalation

```zig
/// The two legal gate states (mirrors plat_outbox_gate.state CHECK constraint).
pub const GateState = enum {
    open,
    closed,

    pub fn toWire(self: GateState) []const u8; // "open" / "closed"
    pub fn fromWire(s: []const u8) ?GateState;
};

/// Per-tenant gate configuration. Depth is keyed per tenant schema (AC6); cap and
/// low-water come from the environment at startup, low-water fixed at 80% of cap.
pub const OutboxGateConfig = struct {
    depth_cap: u64 = 50_000,             // BPM_OUTBOX_DEPTH_CAP
    low_water: u64 = 40_000,             // BPM_OUTBOX_LOW_WATER = 80% of cap
    refresh_interval_ms: u64 = 250,      // depth-refresh cadence; also AC3's window
    refusal_threshold_per_minute: u32 = 100, // AC4
    closed_duration_escalation_s: u64 = 300, // AC5
    stale_depth_timeout_ms: u64 = 5_000, // OBP-01: a stale counter closes the gate

    /// Recompute the hysteresis low-water mark from the cap (AC3 restore).
    pub fn deriveLowWater(cap: u64) u64;  // floor(cap * 4 / 5), i.e. 80%
};
```

```zig
/// The gate's decision for one depth observation of one tenant.
pub const GateDecision = enum {
    /// Depth is below the cap and the gate was open: keep accepting.
    remain_open,
    /// Depth reached the cap: close the gate; the next ingress is refused.
    close_now,
    /// Gate is closed and depth has NOT yet reached the low-water mark: stay closed.
    remain_closed,
    /// Gate is closed and depth reached the low-water mark: reopen; the next
    /// ingress is accepted and EXECUTION_OUTBOX_GATE_OPENED is appended (AC2).
    reopen_now,
};

/// Decoded plat_outbox_gate row (individually-freed fields, explicit deinit(),
/// mirroring effects/queue.zig's OutboxRow).
pub const GateStatus = struct {
    tenant_schema: []u8,
    state: GateState,
    depth: u64,
    cap: u64,
    low_water: u64,
    last_transition_at: []u8, // ISO-8601 UTC
    closed_duration_ms: u64,  // duration of the most recent closed period
    refusal_count_1m: u64,    // AC4 window counter
    refusal_window_started_at: []u8,

    pub fn deinit(self: GateStatus, allocator: std.mem.Allocator) void;
};

pub const OutboxGateError = error{
    PoolExhausted,
    PersistenceFailed,
    EscalationFailed,   // alerting hook refused the escalation (AC4/AC5)
    OutOfMemory,
};
```

The four functions below are the full public surface. `evaluateAndDecide` is the single
entry point both OBP-01's drainer and OBP-02's middleware call; it is the only function
that may mutate `plat_outbox_gate.state`.

```zig
/// Core hysteresis evaluation (AC1/AC2/AC3). Pure decision over (previous state,
/// current depth, cap, low-water) — no I/O — so it is unit-testable without a DB.
/// Returns which transition, if any, the caller must persist and emit.
pub fn decide(
    previous: GateState,
    depth: u64,
    cap: u64,
    low_water: u64,
    refresh_interval_ms: u64,
    last_transition_at_ms: i64,
) struct { decision: GateDecision, flapping: bool };

/// Read the current gate row for a tenant, initialising open at depth 0 if absent.
pub fn readGate(
    allocator: std.mem.Allocator,
    conn: anytype,
    tenant_schema: []const u8,
    config: OutboxGateConfig,
) OutboxGateError!GateStatus;
```

```zig
/// Apply one depth observation: read the row, run decide(), persist the transition
/// in plat_outbox_gate (state, last_transition_at, closed_duration_ms), and — when
/// the decision is reopen_now — append EXECUTION_OUTBOX_GATE_OPENED with the closed
/// duration (AC2). The state write and the event append are one transaction.
/// When `flapping` is true, record the defect and restore low_water to 80% of cap
/// (AC3). Called by OBP-01's drainer on its 250 ms refresh and by OBP-02's
/// middleware on each request.
pub fn evaluateAndDecide(
    allocator: std.mem.Allocator,
    conn: anytype,
    tenant_schema: []const u8,
    depth: u64,
    config: OutboxGateConfig,
) OutboxGateError!GateDecision;
```

```zig
/// Record one refused ingress for a tenant and advance AC4's rolling one-minute
/// window. Called by OBP-02's middleware after it refuses a request (before BEGIN).
/// Returns true when the 100/min threshold was crossed so the caller escalates.
pub fn recordRefusal(
    allocator: std.mem.Allocator,
    conn: anytype,
    tenant_schema: []const u8,
    config: OutboxGateConfig,
) OutboxGateError!bool;

/// Evaluate AC5's closed-duration threshold and AC4's refusal rate on the
/// scheduler/drainer cadence. Pages Platform Admin (AC5: page + drainer restart +
/// closed duration recorded) or escalates (AC4). The drainer-restart action is an
/// operator/infra hook — see Open questions §2.
pub fn evaluateEscalations(
    allocator: std.mem.Allocator,
    conn: anytype,
    tenant_schema: []const u8,
    config: OutboxGateConfig,
    alert: *const fn (allocator: std.mem.Allocator, severity: enum { escalate, page }, detail: []const u8) OutboxGateError!void,
) OutboxGateError!void;
```

### `plat_outbox_gate` — the table (Type C, see the migration YAML)

```zig
// plat_outbox_gate (
//   tenant_schema      text PRIMARY KEY,          -- AC6: keyed per tenant schema
//   state              text NOT NULL 'open' CHECK (state IN ('open','closed')),
//   depth              bigint NOT NULL 0,         -- last observed depth
//   cap                bigint NOT NULL,           -- BPM_OUTBOX_DEPTH_CAP
//   low_water          bigint NOT NULL,           -- BPM_OUTBOX_LOW_WATER (80% of cap)
//   last_transition_at timestamptz NOT NULL,      -- "timestamp of the last transition"
//   closed_at          timestamptz,               -- start of the most recent closed period
//   closed_duration_ms bigint NOT NULL 0,         -- duration the gate was closed (AC2/AC5)
//   refusal_count_1m   bigint NOT NULL 0,         -- AC4 rolling window counter
//   refusal_window_started_at timestamptz,        -- start of the current 1-minute window
//   created_at / updated_at timestamptz NOT NULL
// )
```

## Data flow

```
OBP-01 drainer (future)  every 250 ms            OBP-02 middleware (future)  per request
        |  refreshed depth                              |  depth from cached counter
        v                                               v
+----------------------------------------------------------------------------------+
| outbox/gate.zig  evaluateAndDecide(tenant_schema, depth, config)                 |
|   readGate -> plat_outbox_gate row                                                |
|   decide(previous state, depth, cap, low_water, ...)  [pure, AC1/AC2/AC3]        |
|        |                                                                          |
|   depth >= cap and open  -> close_now   (persist state='closed', closed_at)       |
|   closed and depth <= low_water -> reopen_now                                     |
|       (persist state='open', closed_duration_ms; append                          |
|        EXECUTION_OUTBOX_GATE_OPENED with closed duration -- AC2)                  |
|   closed and depth > low_water -> remain_closed                                   |
|   open and depth < cap     -> remain_open                                         |
|   flapping detected (open+closed within one refresh interval) ->                  |
|       record defect + low_water := deriveLowWater(cap) -- AC3                     |
+----------------------------------------------------------------------------------+
        |
        v
  GateDecision returned to caller (open/closed) for OBP-02 to accept/refuse

Separately, on the drainer/scheduler cadence:
  recordRefusal(...) -> refusal_count_1m window    -- AC4 (>100/min -> escalate)
  evaluateEscalations(...) -> closed_duration_ms   -- AC5 (>300s -> page + restart)
```

## Error taxonomy

```zig
pub const OutboxGateError = error{
    PoolExhausted,    // pool.acquire() failed while reading/persisting gate state
    PersistenceFailed, // any query/exec failure on plat_outbox_gate or the event append
    EscalationFailed,  // the alerting hook refused AC4's escalate or AC5's page
    OutOfMemory,
};
```

Deliberately narrow. The process doc's named failure states are **not** Zig errors in
this design, matching the ordering family's precedent: `GateFlapping` (AC3) is a
detected defect recorded as data and repaired by restoring the 80% low-water mark —
it is a normal outcome of `decide`, surfaced as the `flapping` boolean, never thrown.
`StaleDepthCounter` and `DrainerStalled` (AC5) are conditions `evaluateEscalations`
detects and acts on, not catchable errors. `CrossTenantRefusal` (AC6 violation) is
impossible by construction: the gate row's primary key IS the tenant schema.

## State transitions

`plat_outbox_gate.state` per tenant:

```
open --depth >= cap--> closed     (close_now; closed_at = now)
closed --depth <= low_water--> open (reopen_now; closed_duration_ms recorded; event)
closed --depth > low_water--> closed (remain_closed — gate does NOT reopen at the cap, AC1)
open --depth < cap--> open        (remain_open)
```

`low_water` is a writable per-row value: AC3's flapping recovery rewrites it to
`deriveLowWater(cap)` (80% hysteresis restored). `closed_duration_ms` is the length of
the most recent closed period, written at reopen (consumed by AC2's event and AC5's
duration check). No other transitions exist; a transition that does not match this set
(the process doc's `GateFlapping`) is recorded as data, not as a new state.

## Dependencies

- **Depends on:** `db` (`pool.zig`), `src/obs/logger.zig`, `src/obs/metrics.zig`
  (refusal-rate counter), the existing outbox implementation `src/effects/queue.zig` /
  `src/effects/worker.zig` (the family this gate extends — the gate reads the same
  `effects_outbox` the drainer drains, via the cached depth OBP-01 owns), the alerting
  hook `docs/design/obs-06-alerting-hooks.md` (AC4 escalate / AC5 page), and the event
  append surface defined by `src/design/ISS-0670-platform-event-convention.md`
  (`EXECUTION_OUTBOX_GATE_OPENED` — the event type must be seeded in the event-type
  registry; see Open questions §1).
- **Must NOT depend on:** `src/api/middleware/ratelimit.zig` directly (referenced only as
  the windowing pattern to reuse for AC4's one-minute window — the refusal counter lives
  on `plat_outbox_gate`, not in the HTTP middleware); `src/engine/*` (the gate never
  reasons about instance state); `src/platform/ddl_validate.zig` (the reserved-prefix
  rule is already enforced at DDL validation time by DDL-05).
- **Future-consumer note:** OBP-01/02/03 (the cached depth counter, the ingress refusal
  middleware, the internal `OutboxOverflow` emit path) are the intended callers of
  `evaluateAndDecide` / `recordRefusal`. This design fixes their interface now so those
  later handoffs do not need to change this module's signatures.

## Acceptance-criterion coverage (OBP-04)

| AC | Design location |
|---|---|
| AC1 (oscillation 49999/50001 does not flip; stays closed to 40000) | `decide` hysteresis: close at cap, reopen only at low-water; `remain_closed` when closed and depth > low-water |
| AC2 (reopen at 40000 → next request accepted + `EXECUTION_OUTBOX_GATE_OPENED` with closed duration) | `reopen_now` branch of `decide` + `evaluateAndDecide`'s single-transaction state write + event append carrying `closed_duration_ms` |
| AC3 (open+close within one 250 ms refresh interval → defect recorded, low-water == cap diagnosed, 80% hysteresis restored) | `decide`'s `flapping` detection using `refresh_interval_ms` + `last_transition_at`; AC3 recovery writes `low_water := deriveLowWater(cap)` |
| AC4 (>100 refusals/min for one tenant → Platform Admin escalated) | `recordRefusal` rolling window + `refusal_threshold_per_minute`; escalation via the alerting hook |
| AC5 (closed > 300 s → page, drainer restarted, closed duration recorded) | `evaluateEscalations` using `closed_duration_s` and the row's `closed_at`/`closed_duration_ms`; page + restart via alerting hook (see Open questions §2) |
| AC6 (gate state keyed per tenant schema; one tenant's depth never refuses another's) | `plat_outbox_gate.tenant_schema` PRIMARY KEY; every function takes `tenant_schema` explicitly |

## Open questions

1. **`EXECUTION_OUTBOX_GATE_OPENED` event-type seeding.** The event convention doc and
   the platform event-type seed (`migrations/1152_iss0670_platform_event_types_seed.sql`)
   list `EXECUTION_OUTBOX_GATE_OPENED` by name, but the seed's exact registry shape must
   be confirmed so `evaluateAndDecide`'s append passes the event-type registry gate.
   Non-blocking — the append uses the existing event-store append surface; seeding is an
   implementation detail.
2. **AC5's "drainer is restarted" action.** The design routes AC5 through the alerting
   hook's page channel and records the closed duration, but the actual drainer restart is
   an operator/infra action (process/supervisor), not a Zig call this module can make.
   The `alert` callback signature leaves room for a page-to-operator that triggers the
   restart; whether an automated restart path exists is a deployment concern outside this
   module's boundary. Flagged so BACKEND-DEV/REQ-ANALYST can confirm the intended
   operator loop.
3. **OBP-01/02/03 are not yet implemented.** `evaluateAndDecide` is designed to be called
   by them; until they ship, this module's only callers in this batch are its own
   integration tests and the drainer cadence wiring. Non-blocking for OBP-04 — the
   requirement's own ACs (gate behaviour, escalations, per-tenant keying) are all
   testable through `decide` + the table without OBP-01/02/03 present.

None of these leave an OBP-04 acceptance criterion uncovered. Handoff `result.status` for
the OBP-04 portion is **PASS**.
