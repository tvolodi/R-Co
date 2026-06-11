# BPM Platform — Expansion Backlog (v2)

**Source:** `docs/Audit-Reports/BPM_vs_ASCOA-GO_Gap_Analysis.20260611.md` (v2)
**Reference platform:** ASCOA-GO (`ARCHITECTURE_v0.4.md`, `FUNCTIONAL_REQUIREMENTS_v0.4.md`)
**Purpose:** Convert the corrected gap analysis into development-ready epics and issues.
**Date:** 2026-06-11 · **Revision:** v2 (supersedes v1)

> **Why v2.** v1 mis-scoped the work as "build a platform layer that BPM lacks." The two systems
> are peers. The corrected work is: (1) build a **dynamic-entity subsystem on BPM's event-sourced
> grain** (typed projection tables, *not* indexed JSONB; re-projection, *not* expand/contract);
> (2) make external I/O **async** and **compensation first-class** (saga-as-process); (3) close a
> short list of thinner operational specs. The hybrid-JSONB / expand-contract / `row_version` /
> SPA-build epics from v1 are withdrawn.

---

## How to use this backlog

Self-contained issues; pickable with the issue text + the gap analysis + the architecture docs
+ repo access. One issue → one WF-02 run (WF-03 for fixes) → one branch → one PR. **DoD:** code +
idempotent additive-first migration (+ rollback where applicable) + unit tests for pure logic +
integration test on real PostgreSQL + architecture doc updated.

**Inviolable guardrails (gap analysis §1, §8 — do not regress):**
- The **event log stays the system of record**; entity/read data are **projections rebuildable from events**, never a parallel mutable source of truth.
- The **transition function stays I/O-free**; audit stays in-transaction; tokens stay an identified multiset with explicit join counters.
- **No JSONB as a queried/indexed store.** Anything filtered/sorted/joined is a real typed column in a projection table. JSONB only for free-form, never-indexed blobs.

**Priority:** `P0` foundational · `P1` first full-platform tenant · `P2` should-have · `P3` later.
**Estimate:** `S` ≤ ½d · `M` ≈ 1d · `L` ≈ 2–3d · `XL` epic-sized.

---

## Epics

| Epic | Title | Theme | Wave |
|---|---|---|---|
| EXP-1 | Foundation: scale anchor, one expression engine, wait descriptors | Hardening | 0 |
| EXP-2 | Dynamic entity subsystem (events → typed projections) | **Data model** | 1 |
| EXP-3 | Async outbound effects + result re-entry | **Transactions** | 1 |
| EXP-4 | First-class compensation / error-boundary constructs | **Transactions** | 2 |
| EXP-5 | Secrets module | Hardening | 1 |
| EXP-6 | Tier → quota model | Hardening | 2 |
| EXP-7 | Agent loop: ephemeral sandboxes + threat model | Agent platform | 3 |

---

## EPIC-1 — Foundation (Wave 0)

### [EXP-101] State a scale anchor in the architecture — P0, S
**Why:** No target scale is stated; schema-per-tenant simplifications are unjustified without a ceiling (gap §5; ASCOA-GO §1.1). Document-only.
**Tasks:** Add a "Scale anchor" section; state target + ceiling tenant counts; annotate every single-primary / single-sweep simplification to cite it; list large-N escape hatches (`db_host` sharding, read replicas) as deferred.
**Acceptance:** Architecture doc has a scale-anchor section referenced by each single-node claim.
**Owner:** REQ-ANALYST + human.

### [EXP-102] Finish CEL → `src/expr` cutover (one expression engine) — P0, L
**Why:** Two expression engines coexist (`vendor/cel` live; `src/expr` built but unwired, Open Q1). Tenants (forms, entity constraints, gateways) must depend on one engine.
**Tasks:** Differential corpus harness (CEL vs `expr` over stored gateway conditions); wire `src/expr` into `src/engine/transition.zig`; cut over; retire `cel` for new work. Keep transition fn pure.
**Acceptance:** Gateway conditions evaluate via `src/expr`; differential suite passes; no production module imports `cel`.
**Touchpoints:** `src/engine/transition.zig`, `src/expr/*`, `vendor/cel`.

### [EXP-103] Persist `instance_waits` descriptors in the tenant schema — P0, M
**Why:** Make a tenant dump self-sufficient so restore can re-arm in-flight waits (gap §5; ASCOA-GO C2).
**Tasks:** `instance_waits` table (kind ∈ `timer|catch_event|human_task`, `fire_at`, correlation/task ref); write it in the **same transaction** that arms the wait.
**Acceptance:** Arming any wait creates exactly one descriptor row in the same txn; crash between arm and commit leaves neither.
**Touchpoints:** `migrations/*`, `src/scheduler/*`, `src/tasks/*`, `src/engine/instance.zig`.

---

## EPIC-2 — Dynamic entity subsystem (Wave 1) — *the headline build*

> Implements gap analysis §3. Entities are **event-sourced**; the read/query surface is **one
> real relational table per entity with real typed columns and B-tree indexes**, regenerated from
> the log. JSONB only for free-form, never-queried fields. "Field promotion" = **re-projection**.

### [EXP-201] Entity definition format + Repository artifact — P0, M
**Why:** BPM has no first-class dynamic-entity abstraction; a standard set of forms/projections is insufficient for ERP/CRM/HRM reference data (gap §3.2).
**Tasks:** JSON entity-definition (fields, types, indexes, FKs, constraints; `queried: true` ⇒ projection column, free-form ⇒ JSONB); register as a new Repository `kind = entity` artifact; version the **logical shape**; pin from in-flight instances like `definition_snapshot`.
**Acceptance:** An entity definition canonicalises + hashes deterministically; logical-shape versions retained while referenced; validator rejects a field marked both queried and JSONB-only.
**Depends on:** EXP-102 · **Touchpoints:** `src/repository/*`, `src/definition/*`.

### [EXP-202] Entity command API → event family — P0, L
**Why:** System of record stays the event log (guardrail; principle #1).
**Tasks:** `ENTITY_RECORD_CREATED|UPDATED|DELETED` event family (payload = field values, keyed by record id); REST commands (`POST/PATCH/DELETE /entities/:type/:id`) that append events inside one transaction; reuse existing idempotency + audit chaining.
**Acceptance:** A create/update/delete appends exactly one event; replaying the stream reproduces record state; idempotent re-submit is a no-op.
**Depends on:** EXP-201 · **Touchpoints:** new `src/entities/*`, `src/event_store/*`, `src/api/routes/*`.

### [EXP-203] Typed projection tables (generated DDL) + projector — P0, L
**Why:** Real columns + B-tree indexes for everything queryable; **no JSONB indexing** (gap §3.3, guardrail).
**Tasks:** Generate one table per entity type from the definition (typed columns, declared indexes, FKs; one optional `freeform JSONB` column for never-queried fields); a projector folds the entity event stream into it; rebuildable on demand.
**Acceptance:** Querying a defined entity hits real columns/indexes (`EXPLAIN` shows index scans, no JSONB GIN); dropping + rebuilding the projection from events yields identical rows.
**Depends on:** EXP-202 · **Touchpoints:** `src/entities/*`, `src/repository/projections/*`, `migrations/*`.

### [EXP-204] Re-projection in place of expand/contract — P1, M
**Why:** Schema evolution without ASCOA-GO's dual-write / lost-write hazard (gap §3.3).
**Tasks:** On an entity-definition shape change, build the new projection table from the log and atomically swap the read pointer (reuse Repository atomic activation); old projection retained until no pinned instance needs it.
**Acceptance:** Adding/retyping a queryable field rebuilds the projection from events with zero dual-write window; rollback = reactivate prior projection; no JSONB migration step exists.
**Depends on:** EXP-203 · **Touchpoints:** `src/entities/*`, `src/definition/promotion.zig`.

### [EXP-205] Entity query API (list/filter/sort/keyset) — P1, L
**Why:** ERP/CRM/HRM are query-heavy; the SPA list views need it (gap §3).
**Tasks:** Definition-driven list/filter/sort over **projection columns only**, keyset pagination + max page size; enforce read permissions incl. server-side field stripping.
**Acceptance:** Filter/sort on a projection column paginates by keyset; a filter on a non-projected (free-form) field is rejected; unauthorised fields stripped server-side.
**Depends on:** EXP-203 · **Touchpoints:** `src/entities/*`, `src/api/pagination.zig`, `src/api/authorization.zig`.

### [EXP-206] Command-time optimistic concurrency (narrow) — P1, S
**Why:** Append-only removes most conflicts; a *command validating against current state* still needs a guard (gap §3.4) — extend the existing task-claim CAS pattern, not a platform-wide `row_version`.
**Tasks:** Optional `expected_version`/sequence token on entity update + task-completion commands; reject stale with 409; check inside the appending transaction so a stale task completion leaves the token un-advanced and the task claimed.
**Acceptance:** Concurrent stale update → one 409; stale task completion does not advance the token.
**Depends on:** EXP-202 · **Touchpoints:** `src/entities/*`, `src/tasks/store.zig`.

---

## EPIC-3 — Async outbound effects (Wave 1)

> Implements gap analysis §4.3(1). Moves external I/O out of the step so the engine stays pure.

### [EXP-301] Effects subsystem + effects-worker + result re-entry — P1, L
**Why:** BPM currently calls external systems synchronously inside the step (external latency = lock-hold time) (gap §4.2).
**Tasks:** `effects` module (HTTP connector: per-call timeout, retry/backoff, dead-letter; email channel; secrets by reference); effects-worker consuming delivery rows; result re-enters as `effect.completed`/`effect.failed` carrying the originating `correlation_id`; idempotency key derived from the effect event id.
**Acceptance:** A process expresses `emit effect → wait on catch event → branch on outcome`; retries are at-least-once with a stable idempotency header; no engine-path module performs network I/O.
**Depends on:** EXP-501 (secrets) · **Touchpoints:** new `src/effects/*`, `src/webhook/*` (reuse outbox), `src/engine/*`.

### [EXP-302] Migrate service tasks off inline I/O — P1, M, **decision-gated**
**Why:** Remove synchronous external calls from the step (gap §4.3, open Q3).
**Tasks:** Convert `src/engine/service_task.zig` to emit effect events; **owner decides** whether any low-risk synchronous service tasks remain.
**Acceptance:** Service-task semantics expressed as effect emit + re-entry; engine path I/O-free.
**Depends on:** EXP-301 · **Touchpoints:** `src/engine/service_task.zig`.

### [EXP-303] Stub effects executor for sandboxes — P1, S
**Why:** Make `notifications_sent`-style assertions checkable/deterministic (ASCOA-GO FR-OUT-5); feeds EXP-7.
**Acceptance:** In a sandbox, an emitted effect increments a recorded count and performs nothing.
**Depends on:** EXP-301 · **Touchpoints:** `src/effects/*`, `src/simulation/*`.

---

## EPIC-4 — Compensation / error-boundary constructs (Wave 2)

> Implements gap analysis §4.3(2) — "saga processes as transactions" as engine constructs rather
> than hand-modeled paired service tasks. ASCOA-GO defers this to v2; BPM can lead.

### [EXP-401] Compensation handler + error-boundary node types — P1, L
**Why:** Today compensation is copy-pasted per process (e.g. `quarantine`/`release-quarantine`); make it declarative and auditable.
**Tasks:** Add a compensation-handler attachable to a scope/activity and an error-boundary event that triggers it on error/cancel; engine records compensation as first-class events; graph validator checks handler reachability and that compensated activities are reversible.
**Acceptance:** A definition declares a compensation handler; on a triggered error the engine fires it and the audit log shows the compensation chain; cancelling a scope runs registered compensations in reverse order.
**Depends on:** EXP-301 (compensation often performs effects) · **Touchpoints:** `src/engine/*`, `src/definition/graph.zig`, validator.

### [EXP-402] Restore reconciliation using wait descriptors — P2, M
**Why:** Even with event replay, restoring a tenant can leave instances waiting on already-fired timers/keys (gap §5; ASCOA-GO C2).
**Tasks:** Restore flow: replay/restore events + rebuild projections → re-arm waits from `instance_waits` (EXP-103) → mark un-re-armable instances `restored_orphan` (surface via DLQ/observability).
**Acceptance:** Restore a tenant with an instance waiting on a timer + a human task, after those fired live; reconcile; assert nothing hung and no stale key suppresses recovery.
**Depends on:** EXP-103 · **Touchpoints:** `src/admin/*`, `src/db/*`.

---

## EPIC-5 — Secrets module (Wave 1)

### [EXP-501] Per-tenant envelope-encrypted secrets, resolved by reference — P1, L
**Why:** Only `hmac_secret` "encrypted at rest" exists; effects/connectors need managed tenant credentials (gap §5; ASCOA-GO §12.7).
**Tasks:** `secrets` module: per-tenant secrets under envelope encryption (data keys wrapped by host KMS/env master key); resolution **by reference** at execution; values never in definitions/logs/traces; module owns webhook HMAC keys (key id now; grace-window rotation later).
**Acceptance:** A script/effect receives a secret only by reference; no value appears in any log/trace/definition; key material is envelope-encrypted at rest.
**Depends on:** EXP-101 · **Touchpoints:** new `src/secrets/*`, `src/webhook/*`.

---

## EPIC-6 — Tier → quota model (Wave 2)

### [EXP-601] Central tier→quota enforcement in kernel middleware — P2, L
**Why:** No tier→quota mapping today; must be central as entities (storage), files, and sandboxes multiply (gap §5; ASCOA-GO FR-TIER).
**Tasks:** Tier classification → script CPU/memory limits, entity-storage / file / concurrent-sandbox quotas, agent retry budget; enforced in kernel middleware, configured in one place.
**Acceptance:** Exceeding a tenant quota is rejected centrally; limits live in one config surface.
**Depends on:** EXP-202 · **Touchpoints:** `src/api/middleware/*`, `src/config/*`.

---

## EPIC-7 — Agent loop: ephemeral sandboxes + threat model (Wave 3)

> Gated on owner decision (gap §7 Q6): is agent-authored *tenant* logic a near-term surface? If
> later phase, this epic is P3.

### [EXP-701] Sandbox threat-model document — P1, M, **gates go-live**
**Why:** Two untrusted runtimes (Lua + Wasm) + agent pipeline; the written model is owed before untrusted code runs in production (gap §5; ASCOA-GO FR-NFR-4). Document-only; can start anytime.
**Acceptance:** Reviewed/signed-off doc covering Lua + Wasm host-API surface, capability gating, fuel/memory/timeout limiters, sandbox-control auth; referenced as a go-live gate.
**Owner:** ARCHITECT + human.

### [EXP-702] Ephemeral sandbox tier (warm pool, claim-to-ready) — P2, XL
**Why:** The agent loop needs throwaway per-agent environments distinct from the UAT runtime (gap §5; ASCOA-GO FR-ENV-1..7).
**Tasks:** `tenant_<slug>_sbx_<uuid>` schemas from a background-replenished warm pool (platform DDL pre-built); claim path = acquire + entity projection DDL + fixtures; sub-second claim-to-ready measured on the full path; torn down on every exit; same isolation + Wasm caps as production.
**Acceptance:** Claim-to-ready measured vs the sub-second target on the full path; sandbox passes the cross-tenant isolation suite.
**Depends on:** EXP-203 · **Touchpoints:** new `src/sandbox/*`, `src/db/provisioning.zig`.

### [EXP-703] Virtual clock + assertion/control API + sandbox auth — P2, L
**Why:** Timer/approval processes must be testable deterministically; the control surface must be authenticated (gap §5; ASCOA-GO FR-ENV-8/9, FR-AGT-2/8/9).
**Tasks:** `execute|assert|trace|advance_clock|complete_task` with frozen-clock + seeded RNG + stub effects (EXP-303); agents as per-tenant Keycloak service principals; sandbox bound to `(tenant, agent, task_spec)`; role simulation confined to sandboxes.
**Acceptance:** A two-step timer+approval process passes deterministically across repeated runs; a non-owning principal is denied; role simulation rejected in staging/production.
**Depends on:** EXP-702, EXP-303, `src/oidc/agent_lifecycle.zig` · **Touchpoints:** `src/sandbox/*`, `src/oidc/*`, `src/api/middleware/auth.zig`.

---

## Execution order

| Wave | Epics / issues | Gate to next |
|---|---|---|
| **0** | EXP-101, EXP-102, EXP-103 | One expression engine; scale stated; waits persisted |
| **1** | EXP-201→206, EXP-301→303, EXP-501 | Entities queryable via typed projections; external I/O async; secrets managed |
| **2** | EXP-401→402, EXP-601 | Compensation declarative; restore reconciles; quotas central |
| **3** | EXP-701→703 | Agent loop behind a signed threat model |

**Suggested first vertical slice.** One tenant; one custom entity (e.g. `equipment_inspection`) stored as events and projected into a typed table; one two-step approval process whose approval is a user-task node; one DSL formula and one Lua script; one outbound notification via the **stub** effects executor; queried through the entity query API; promoted once through the human gate. This thread exercises EXP-102, EXP-201/202/203/205/206, EXP-301/303, EXP-501 — validating the **events→typed-projection** model and the **async-effects** model together before breadth is built.

---

*Touchpoints name likely modules from the current `src/`/`web/` tree and may shift on implementation. Every issue inherits the inviolable guardrails above.*
