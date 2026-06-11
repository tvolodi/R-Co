# BPM Platform vs. ASCOA-GO — Architecture Gap Analysis (v2)

**Type:** Comparative architecture analysis (peer platforms)
**Subject (current project):** BPM Platform — `docs/BPM_Platform_Backend_Architecture.20260611.md` (v1.1) + `docs/addon-1/01-architecture.md` (v0.4-draft) + `docs/BPM_Platform_Functional_Requirements.md`
**Reference platform:** ASCOA-GO — `ARCHITECTURE_v0.4.md` + `FUNCTIONAL_REQUIREMENTS_v0.4.md`
**Date:** 2026-06-11 · **Revision:** v2 (supersedes v1 of the same date)
**Method:** Static document + source-tree comparison (no execution).

> **Why v2.** The first revision framed BPM as a "pure execution kernel" and ASCOA-GO as a "full platform," and treated everything absent from the *backend* architecture file as absent from the product. That was wrong. The `addon-1` architecture states plainly that BPM is "a low-level process execution kernel that doubles as a **software factory** for higher-level business applications (ERP, CRM, HRM)," with an L4 **Form & Report Engine**, a three-tier execution model, a versioned **Platform Repository**, an **Architect→Developer→DevOps agent pipeline**, schema-per-tenant multitenancy, and a React SPA. **The two systems are peers.** The genuine differences are narrower and deeper than v1 claimed, and they are the subject of this revision.

---

## 1. Executive summary

BPM and ASCOA-GO are the **same product archetype**: a multitenant (schema-per-tenant) platform that hosts per-client business applications, layered as API → scripting (DSL / Lua / Wasm / formulas) → BPM engine → business apps, with dynamic forms, an agent authoring pipeline, and a React front end. The visible difference of language (Zig vs Go) is the least interesting one.

Once the false "kernel vs platform" gap is removed, the real differences reduce to three, in order of consequence:

1. **Data-model philosophy (the headline).** BPM's first guiding principle is *event sourcing as ground truth* — "no state stored as mutable rows updated in place; all state is derived by projecting an immutable event log," with read-models/projections always rebuildable. ASCOA-GO stores business-app data in **mutable hybrid relational+JSONB entity tables** as the system of record (optimistic concurrency, expand/contract field promotion, declared-filterable JSONB keys). This single choice explains most of the apparent feature gaps in v1 — and it is where BPM's biggest *open design question* actually lives (§3).

2. **Transaction & saga model.** Both share *one transaction per step* on a single Postgres. They diverge on (a) external side effects — BPM calls out **synchronously inside the step** (service tasks); ASCOA-GO performs them **asynchronously** via an effects worker with result re-entry by `correlation_id`; and (b) **compensation** — BPM models it **by hand** as paired service-task nodes (e.g. `quarantine`/`release-quarantine`) and a provisioning onboarding saga; ASCOA-GO uses a **dedicated saga runner with reverse compensation** plus async effects. *Neither has first-class compensation/error-boundary constructs in the engine* — both defer that — but ASCOA-GO is more honest and more systematic about async-and-compensate as the business-level transaction model (§4).

3. **A handful of operational specs that are genuinely thinner in BPM**, independent of the above: secrets management, a stated scale anchor, a tier→quota model, a written sandbox threat model, and the ephemeral throwaway-sandbox tier for the agent loop (§5).

BPM is **ahead** of ASCOA-GO at the engine level (true event sourcing, pure I/O-free transition function, in-transaction tamper-evident audit, identified-multiset tokens with explicit join counters). Those strengths are not just to be preserved — they are the *foundation that makes BPM's answer to your entity-management and JSONB concerns cleaner than ASCOA-GO's* (§3.3).

---

## 2. What v1 got wrong (retractions)

The following v1 "gaps to add" were misattributions and are withdrawn — they are either present in BPM under a different name, or they are ASCOA-GO solving a problem that only exists because of its mutable-store choice:

| v1 claim | Correction |
|---|---|
| "Dynamic forms missing" | BPM has an L4 **Form Engine**; forms are versioned Repository artifacts (`kind = form`). |
| "Formula engine missing" | BPM has the **Tier-1 Expression DSL** (`src/expr`) for the same role; the real task is exposing/finishing it (§5). |
| "SPA missing" | BPM has a React SPA (`web/src` — forms, canvas/BPM designer, admin, instances, tasks). |
| "Agent authoring loop missing" | BPM has the **Architect→Developer→DevOps pipeline** (the software factory). |
| "Hybrid relational+JSONB store to add" | This is ASCOA-GO's data model, **not a target for BPM** — BPM is event-sourced (§3). |
| "Expand/contract field promotion to add" | Only meaningful for a mutable store; BPM's equivalent is **re-projection** (§3.3), which is simpler. |
| "`row_version` optimistic concurrency to add" | Largely moot under append-only event sourcing; relevant only to specific read-model/claim paths (§3.4). |
| "Backup/restore = per-schema dump reconciliation" | BPM's primary mechanism is **event-log replay**; only the in-flight-timer re-arm subset still applies (§5). |

---

## 3. The headline difference — data model & entity management

### 3.1 The divergence

- **BPM:** business-app state = an append-only event log; all queryable/displayable state is a **projection** (read-model) rebuildable from events. Forms write events; reports/lists are projections. Projections are first-class, versioned, atomically activated artifacts in the Repository.
- **ASCOA-GO:** business-app state = **mutable hybrid tables**, one per entity (typed columns for queried fields + one `JSONB` column for the rest), with `row_version` optimistic concurrency, a hot-field monitor, and expand/contract promotion of JSONB keys into columns.

### 3.2 Your concern #1 — "a standard set of entities will not be enough"

This is correct and it is the **one genuine structural gap** in BPM. Today BPM has *event types*, *forms*, and *projections*, but **no first-class dynamic-entity abstraction** — no tenant-authored notion of "Customer / Asset / Employee" as a managed record type with CRUD, relationships, constraints, and a general query surface. For process-centric data this is fine (an instance's variables + projections cover it). For ERP/CRM/HRM it is not: those domains are *entity-centric*, with large reference-data catalogs (customers, items, GL accounts, assets) that exist independently of any one process instance and must be created, related, queried, and reported on directly.

So BPM needs a **dynamic entity-management subsystem**. The question is *how* to build it without (a) abandoning event sourcing, and (b) repeating ASCOA-GO's JSONB-indexing approach you object to. §3.3 answers both.

### 3.3 Recommended model — entities as events + typed projection tables (and why it beats hybrid+JSONB)

Build dynamic entities **on the grain BPM already has**:

- **System of record = events.** A tenant-defined entity type gets a generic event family (`ENTITY_RECORD_CREATED / UPDATED / DELETED`, payload = field values, keyed by record id). This satisfies guiding principle #1 — no mutable rows as truth — and inherits BPM's existing idempotency, audit chaining, and crash-safety for free.
- **Read side = one real relational table per entity, generated from the entity definition.** Every declared field becomes a **real typed column with a real B-tree index** and real foreign keys; the projector folds the event stream into it. This is the existing "projection" artifact, specialized to entities.
- **JSONB only for genuinely free-form, never-queried blobs** (e.g. an unstructured `notes` payload) — *never as the indexed/queried store*.

This directly answers your concern #2:

> **Your concern #2 — "indexing of JSONB is really a bad idea."** Agreed, for a queryable store. GIN indexes on JSONB bloat badly, amplify writes, give the planner poor selectivity estimates, and don't serve range/sort well; expression indexes force you to declare keys up front anyway. ASCOA-GO partly concedes this — its whole expand/contract machinery exists *to migrate hot JSONB keys into real columns*. BPM should skip that migration tax: in a projection table, **anything queryable is a real column from the start**, because the projection is regenerated from the log, not migrated in place. JSONB is kept only where you would never index it.

And it dissolves ASCOA-GO's hardest problems instead of importing them:

| ASCOA-GO problem | BPM under events+projections |
|---|---|
| Expand/contract field promotion, dual-write window, lost-write hazard (its C1 fix) | **Re-projection.** Change the entity definition → rebuild the projection table from the event log. No dual-write, no placement state machine, no lost-write window. |
| `row_version` optimistic concurrency / 409 UX (its H3 fix) | Append-only writes don't overwrite; conflicts are resolved by event ordering. Optimistic checks needed only where a *command* must reject stale input (e.g. task completion) — a narrow case, not a platform-wide concern. |
| Hot-field monitor recommending JSONB→column promotions | Unneeded as a migration driver; can survive as a pure *indexing* hint on projection tables. |
| Backup/restore field-shape reconciliation | Projections are disposable; restore = restore events + rebuild projections. |

**Cost to be honest about.** Event-sourcing every entity write means (a) projector lag (eventual consistency between a write and its read-model — usually milliseconds, but real), (b) re-projection cost for very large entities (mitigated by snapshots, which BPM already contemplates for instance state), and (c) you must decide whether entity *reads inside a step* are allowed to hit a possibly-stale projection or must fold from events. These are normal event-sourcing trade-offs, not blockers — but they should be decided explicitly (§7, open questions).

### 3.4 Where optimistic concurrency still matters

Append-only logging removes most write-conflict hazards, but not all: a **command that validates against current state** (human-task completion submitting a decision, or an entity command asserting "update only if unchanged") still needs a guard. BPM already does this correctly for task *claim* (optimistic compare-and-set on `claimed_by`). Extend the same pattern — a version/sequence token checked at command time — to entity commands and task completion. This is a small, targeted adoption of ASCOA-GO's idea, not its platform-wide `row_version`.

---

## 4. Transaction & saga model

### 4.1 What's shared

Both enforce **one transaction per step** (token advance + data write + event/outbox insert commit atomically) on a single Postgres, so neither needs distributed transactions for the local case.

### 4.2 Where they diverge — and your concern #3

You're essentially right that **ASCOA-GO leans on async + business-level compensation** rather than long synchronous transactions:

- **External side effects.** ASCOA-GO forbids any escaping I/O inside a step (enforced by the Wasm host allowlist) and routes every outbound call through an **effects worker**; the result re-enters the process as an `effect.completed`/`effect.failed` event carrying the originating `correlation_id`. A process therefore models an external call as `emit request → wait on catch event → branch on outcome` — fully **async**. **BPM, by contrast, calls external systems synchronously inside the step** (service-task node with a timeout). That means external latency is lock-hold and pooled-connection-hold time, and a slow/failed dependency entangles engine state.
- **Multi-resource consistency (sagas).** ASCOA-GO runs provisioning in a **dedicated Go saga runner** with persisted step state and **reverse compensation**. BPM does the equivalent with its **onboarding saga** (idempotent, each step compensatable, provider-side compensating deletes) — so on *provisioning* the two are at rough parity.
- **Business-process compensation.** Here both are immature. BPM models compensation **by hand** in the graph — a `quarantine` service task paired with a `release-quarantine` service task, fired on a `false_positive` branch (BO_VORTEX). ASCOA-GO explicitly **defers** formal BPM error-boundary events and compensation handlers to v2. So *neither* has first-class compensation; BPM's is hand-rolled-per-process, ASCOA-GO's is roadmapped.

### 4.3 Recommendation

Two adoptions give BPM ASCOA-GO's robustness while keeping event sourcing:

1. **Async effects with result re-entry.** Introduce an effects subsystem so external I/O leaves the step transaction: the step emits an effect event; an effects worker performs the call; the outcome re-enters via `correlation_id`. This *reinforces* BPM's pure-engine principle (the engine stops doing I/O), and it makes external calls testable via a stub effects executor in sandboxes. This is the single most valuable engine-level change.
2. **First-class compensation / error-boundary constructs.** Promote compensation from hand-modeled paired tasks to engine constructs (a compensation handler attached to a scope, triggered on error/cancel), so sagas-as-business-processes are declarative and auditable rather than copy-pasted per definition. This is the natural home for the "saga as transaction" pattern you're pointing at, and it is on ASCOA-GO's own v2 roadmap — BPM can lead here.

Note these two are *complementary*: async effects make external steps non-blocking; compensation constructs make multi-step business transactions reversible. Together they are "saga processes as transactions" done properly.

---

## 5. Genuinely thinner specs in BPM (independent of the above)

These remain valid regardless of data model, and several are cheap:

- **Outbound effects discipline** — see §4.3(1). (Currently inline service-task I/O.)
- **Secrets management.** BPM stores `hmac_secret` "encrypted at rest" and reads creds from env, but has no general secrets subsystem. As service tasks / effects call authenticated external APIs, adopt ASCOA-GO's **per-tenant envelope encryption + by-reference resolution** (values never in definitions/logs/traces); the module also owns webhook HMAC keys. *Do this before the effects/connector work.*
- **Stated scale anchor.** ASCOA-GO anchors at ~100 tenants and justifies every schema-per-tenant simplification against it; BPM states no ceiling. Add one — it's documentation, and it de-risks the single-primary / single-sweep assumptions.
- **Tier → quota model.** BPM has a tenant `type` and per-runtime resource caps but no tier→quota mapping (storage / file / sandbox quotas, agent retry budget) enforced centrally in kernel middleware. Introduce it now so quotas are cross-cutting, not retrofitted per subsystem — especially once entities multiply storage.
- **Written sandbox threat model.** BPM runs *two* untrusted runtimes (Lua + Wasm) and an agent pipeline; the threat-model document (ASCOA-GO's owed FR-NFR-4) is *more* urgent here and should gate agent-authored production code.
- **Ephemeral throwaway-sandbox tier.** BPM's Simulation/UAT runtime is scenario-replay; ASCOA-GO's agent loop additionally uses **warm-pool, sub-second-claim, torn-down-on-exit** sandbox schemas with a virtual clock and an assertion/`complete_task` control API. If agent-authored *tenant* logic is in scope, this tier is worth adopting; BPM's agent identities (`src/oidc/agent_lifecycle.zig`) and Repository give a head start.
- **In-flight wait reconciliation on restore.** Even with event-replay backup, restoring one tenant can leave instances waiting on timers/keys that already fired. Adopt ASCOA-GO's `instance_waits` descriptor (persist the intended wait in the tenant schema in the same transaction that arms the timer) so a tenant dump is self-sufficient and waits can be re-armed.

---

## 6. Implementation/runtime choices (neutral)

| Concern | BPM | ASCOA-GO | Note |
|---|---|---|---|
| Language | Zig | Go | Neutral; affects ecosystem, not architecture |
| Wasm host | Wasmtime | wazero (pure Go) | wazero avoids CGo; Wasmtime more mature/faster — neutral |
| Lua | LuaJIT embedded | Lua compiled → Wasm | BPM keeps a distinct Lua tier; ASCOA-GO unifies on one Wasm boundary |
| Expression/formula | Vendored CEL (live) → `src/expr` (built, not yet wired) | `expr-lang/expr` native server-side | BPM should finish the CEL→`src/expr` cutover so there's one engine before tenants depend on it |
| Execution tiering | Explicit 3-tier DSL→Lua→Wasm (+ future Tier-4 LLM), Architect picks minimum-power tier | "Wasm everywhere," Lua authoring | BPM's tiering is richer and a genuine strength |

---

## 7. Open questions for the owner

1. **Entity store consistency (§3.3).** For entity *reads inside a step*, may a step read a (possibly stale) projection, or must it fold from events for read-your-writes? This is the central event-sourcing decision for the entity subsystem.
2. **Re-projection at scale (§3.3).** Are entity snapshots in scope from the start (to bound rebuild cost for large reference-data entities), or added later?
3. **Async effects vs. synchronous service tasks (§4.3).** Adopt async-effects platform-wide and deprecate inline service-task I/O, or keep synchronous service tasks for low-risk fast calls and add effects alongside?
4. **Compensation constructs (§4.3).** Build engine-level compensation/error-boundary now, or continue hand-modeling paired service tasks until the entity + effects work lands?
5. **Scale ceiling (§5).** What is BPM's actual target tenant count? Everything in the schema-per-tenant simplification hinges on it.
6. **Agent-authored tenant logic (§5).** Is the ephemeral-sandbox + assertion-API loop a near-term product surface, or later phase? It sizes the sandbox work.

---

## 8. Verdict

This is not "add a platform layer." It is **one architectural decision plus a short hardening list**:

- **Decide and build the dynamic-entity subsystem** on BPM's own grain — events as record-of-truth, **typed projection tables (not indexed JSONB)** as the read/query surface, **re-projection instead of expand/contract**. This answers your entity-management and JSONB concerns together and plays to BPM's existing strengths.
- **Move external I/O async and make compensation first-class** — the "saga processes as transactions" model — so BPM matches ASCOA-GO's async/compensate robustness while keeping its purer engine.
- **Close the thin operational specs** (secrets, scale anchor, quotas, sandbox threat model, ephemeral sandbox, wait-reconciliation).

The companion `BPM_Platform_Expansion_Backlog.20260611.md` sequences this into epics and issues.

---

*Static comparison; claims about BPM reflect its v1.1 backend doc, the `addon-1` architecture, the functional requirements, and the current `src/`/`web/` tree, not runtime behavior.*
