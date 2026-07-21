# What My-Fab Can Borrow From ASCOA-GO — Architecture & Functionality

**Type:** Comparative borrowing analysis (peer platforms)
**Current project:** My-Fab BPM Platform (Zig backend, React SPA) — `c:\Users\tvolo\dev\ai-dala\My-Fab`
**Reference project:** ASCOA-GO (Go modular monolith, React SPA + Flutter) — `c:\Users\tvolo\dev\abitech\ascoa-go`
**Date:** 2026-06-26 · **Method:** Static document + source-tree comparison (no execution).
**Builds on:** `docs/Audit-Reports/BPM_vs_ASCOA-GO_Gap_Analysis.20260611.md` (v2, 2026-06-11).

---

## 0. How to read this

A detailed gap analysis already exists from 2026-06-11. This document does **not** repeat it. Instead it:

1. Confirms which of that analysis' recommendations are now partially in place in My-Fab's `src/` tree, and
2. Focuses on what is **newly borrowable** — items ASCOA-GO has built or specified since June 11 (notably a full Flutter mobile tier, formalized step-failure semantics, a generic saga runner, restore reconciliation, and a modular agent-instruction system).

The two platforms are the **same archetype** — multitenant (schema-per-tenant) hosts for per-client business apps, layered API → expression/script → BPM engine → business apps, with dynamic forms, an agent authoring pipeline, and a React front end. Language (Zig vs Go) is the least interesting difference. Borrowing here means borrowing **specifications, design patterns, and operational discipline** — not Go code.

---

## 1. Executive summary — the borrow list, ranked

| # | What to borrow | Type | Effort | Value | New since 6/11? |
|---|---|---|---|---|---|
| 1 | **Flutter mobile tier** (generic definition-interpreter, offline definition cache, OIDC/PKCE, generic renderers) | Architecture + product | High | High | ✅ New |
| 2 | **Formalized step-failure semantics** (retry policy + dead-letter + parallel-branch isolation) — FR-BPM-13/14/15 | Engine spec | Medium | High | ✅ New (now implemented in ASCOA) |
| 3 | **`instance_waits` restore-reconciliation descriptor** — FR-BPM-16 | Engine spec | Low–Med | High | ✅ New |
| 4 | **Async effects with result re-entry** (move external I/O out of the step) | Architecture | Medium | High | Carried over |
| 5 | **First-class compensation / error-boundary constructs** + a generic saga runner | Engine spec | High | High | Pattern matured |
| 6 | **Modular agent-instruction files** (`.github/instructions/*.instructions.md`) | Process/governance | Low | Medium | ✅ New |
| 7 | **Per-tenant secrets subsystem** (envelope encryption + by-reference resolution) | Architecture | Medium | High | Carried over |
| 8 | **Operational specs**: stated scale anchor, tier→quota model, written sandbox threat model, ephemeral throwaway-sandbox tier | Documentation/spec | Low–Med | Medium | Carried over |
| 9 | **Architecture-document craft** (resolved-decisions table, heartbeat framing, audit-driven changelog) | Documentation | Low | Medium | Refined |

Items 4, 5, 7, 8 were already recommended on 6/11 and several now have module stubs in My-Fab (`src/effects`, `src/secrets`, `src/entities`). Items 1, 2, 3, 6 are the genuinely fresh borrows.

---

## 2. What My-Fab already has (do NOT re-borrow)

My-Fab's `src/` tree shows it has begun or completed much of the 6/11 backlog. Confirmed present:

- **Event sourcing as ground truth** (`src/event_store`, `src/engine`) — My-Fab is *ahead* of ASCOA-GO here; ASCOA uses mutable hybrid+JSONB tables. Keep My-Fab's model; do not import ASCOA's expand/contract field-promotion machinery.
- **Effects module** (`src/effects`, with `adapters/`) — exists; the open question is whether it is *async with result re-entry* (see §5.3).
- **Secrets module** (`src/secrets`, with `integration/`) — exists; verify it implements envelope encryption + by-reference resolution, not just env reads.
- **Dynamic entities** (`src/entities`) — exists as a module; the 6/11 analysis recommended events + typed projection tables (not indexed JSONB). Confirm the implementation followed that.
- **Expression engine** (`src/expr`), **Lua + Wasm runtimes** (`src/lua`, `src/wasm`), **webhook ingress** (`src/webhook`), **scheduler/timers** (`src/scheduler`), **DLQ** (`src/dlq`), **human tasks** (`src/tasks`), **simulation/UAT** (`src/simulation`), **agent identities** (`src/oidc`, `src/identity/provider`).

So the borrowing target is **not** "add a platform layer." It is a short list of specific engine specs, one new product tier (mobile), and operational hardening.

---

## 3. Top borrow — the Flutter mobile tier (genuinely new)

ASCOA-GO now ships a complete `docs/ARCHITECTURE_MOBILE.md` and an `apps/mobile/` Flutter app. **My-Fab has no mobile tier at all.** This is the single largest new capability gap.

What makes it cleanly borrowable is that it reuses the **same governing principle as the web SPA**: a generic interpreter of server-delivered definitions, one tenant-agnostic build, no per-tenant code, no on-device tenant logic in v1. Because My-Fab's SPA already follows that principle, the same server contracts (definition fetch, form/list/process/task renderers, batched formula evaluation, version-pinned task payloads) drive the mobile app unchanged.

Specifically borrowable elements:

- **Generic-renderer architecture** with the same 6 mandatory UI states (loading, fetch failure, permission denied, stale version, validation error, 429 backpressure) shared with web — a strong consistency contract.
- **Tenant bootstrap sequence**: slug from deep link or manual entry → unauthenticated `tenant-config` fetch → OIDC Authorization Code + PKCE via platform browser → secure token storage → `/me` → warm cache then delta-sync.
- **Offline-first definition cache** (Isar, keyed by `(type, id, version)`, delta sync on foreground) with the **version-pinning rule** ("never silently use the active version for a pinned interaction").
- **Security checklist**: encrypted token storage only, no client-side formula execution, screenshot/`FLAG_SECURE` handling, no cleartext traffic, one-time secret reveal.
- **A v1/deferred scope table** that keeps offline writes, push invalidation, and form builder out of v1.

Recommended action: adopt `ARCHITECTURE_MOBILE.md` as the template for a My-Fab mobile architecture doc, mapping ASCOA's Go/Keycloak server contracts onto My-Fab's existing endpoints. The Dart/Flutter stack itself (go_router, Riverpod, Dio, flutter_appauth, flutter_secure_storage, Isar, intl) transfers verbatim — it is backend-agnostic.

---

## 4. Engine specs to borrow (high value, well-bounded)

### 4.1 Step-failure semantics — FR-BPM-13/14/15

ASCOA has now **implemented and documented** what the 6/11 analysis called immature in both platforms:

- **FR-BPM-13 — Retry policy + dead-letter.** A per-node `RetryPolicy{ MaxAttempts, InitialInterval, CapInterval, Jitter }`, default 3 attempts with 100 ms→5 s backoff and 10 % jitter; **deterministic failures** (Wasm traps, resource-cap violations, OOM) get a shorter budget; per-attempt idempotency key `<step_execution_id>-attempt-N` with the counter persisted, not re-parsed.
- **FR-BPM-14 — Failed-instance management.** Dead-letter transitions the instance to a `failed` state; the failure log row is committed in a **separate transaction** after the step rolls back, so the failure record survives the rollback; surfaced in observability with retry/cancel actions running the *pinned* definition version.
- **FR-BPM-15 — Parallel-branch failure isolation.** Sibling tokens continue; the AND-join blocks on the failed token until it is retried-to-success or the instance is cancelled — the join never proceeds with a missing token.

My-Fab has a `src/dlq` module (one file) — likely thinner than this. Borrow the **semantics and acceptance criteria**, not the Go code. The "failure is a defined state, not an exception path" framing is worth importing into My-Fab's architecture doc as a first-class engine rule.

### 4.2 Restore reconciliation — FR-BPM-16 (`instance_waits`)

The 6/11 analysis already flagged in-flight wait reconciliation. ASCOA has since formalized it: when a step arms a wait, it persists an **`instance_waits` descriptor** (kind = `timer | catch_event | human_task`, `fire_at`, correlation/task ref) in the **tenant schema, in the same transaction** that creates the platform-schema timer. On single-tenant restore, a reconciliation saga purges transient platform rows and **re-arms waits from these descriptors**, marking un-re-armable instances `failed (restored_orphan)`.

This makes a tenant logical dump self-sufficient and lets an instance show what it is blocked on from its own schema. Low-to-medium effort, high resilience payoff. Borrow the descriptor + reconciliation-saga design directly.

---

## 5. Architecture patterns to borrow

### 5.1 First-class compensation + generic saga runner

ASCOA ships a small **generic saga runner** (`internal/saga/`: persisted step state, forward execution, reverse compensation, resumability, `reconcile_pins`) used for provisioning/de-provisioning — deliberately minimal (linear steps + reverse compensation, no gateways/events) so it never grows into a second engine. My-Fab has **no saga module** and models compensation by hand as paired service-task nodes.

Two complementary borrows (both on ASCOA's own v2 roadmap — My-Fab can lead):

1. A generic saga runner for provisioning-style multi-resource operations, kept minimal by design.
2. **Engine-level compensation / error-boundary constructs** (a compensation handler attached to a scope, triggered on error/cancel), so business-process sagas are declarative and auditable rather than copy-pasted per definition.

### 5.2 Per-tenant secrets subsystem

Borrow ASCOA's **envelope-encryption + by-reference resolution** model: secret values never appear in definitions, logs, or traces; the module also owns webhook HMAC ingress keys and their rotation (dual-key grace window). My-Fab has a `src/secrets` module already — confirm it implements this discipline rather than env reads, and do it **before** expanding effects/connector work that calls authenticated external APIs.

### 5.3 Async effects with result re-entry

Confirm whether My-Fab's `src/effects` performs external I/O **asynchronously** (step emits an effect event → effects worker performs the call → outcome re-enters via `correlation_id`) or **synchronously inside the step**. The async model keeps external latency out of lock-hold/connection-hold time, reinforces the pure-engine principle, and makes external calls testable via a stub effects executor in sandboxes. If My-Fab still calls synchronously inside steps, this is the single most valuable engine-level change to borrow.

### 5.4 Operational specifications (cheap, mostly documentation)

- **Stated scale anchor.** ASCOA anchors every schema-per-tenant simplification to ~100 tenants (design ceiling ~500 schemas). My-Fab states no ceiling. Add one — it de-risks the single-primary / single-drainer assumptions and is pure documentation.
- **Tier → quota model.** Map tenant tier to storage/file/sandbox quotas and agent retry budget, enforced centrally in kernel middleware — before entities multiply storage, so quotas are cross-cutting, not retrofitted.
- **Written sandbox threat model.** My-Fab runs *two* untrusted runtimes (Lua + Wasm) plus an agent pipeline; a written threat model is *more* urgent here than in ASCOA and should gate agent-authored production code.
- **Ephemeral throwaway-sandbox tier.** ASCOA's agent loop uses warm-pool, sub-second-claim, torn-down-on-exit sandbox schemas with a **virtual clock** (`advance_clock`) and an **assertion / `complete_task` API**. My-Fab's simulation runtime is scenario-replay; if agent-authored *tenant* logic is a near-term surface, this tier is worth adopting (My-Fab's agent identities give a head start).

---

## 6. Process & governance to borrow

### 6.1 Modular agent-instruction files

ASCOA splits agent guidance into small, enforceable, scoped files under `.github/instructions/`:

`architecture-rules`, `db-migration-rules`, `flutter-conventions`, `go-conventions`, `react-conventions`, `requirement-format`, `security-invariants`, `testing-rules` — each with an `applyTo` glob and explicit "flag as BLOCKER" violation lists.

My-Fab concentrates equivalent guidance in a single very large `CLAUDE.md` (~62 KB) plus `docs/anti-patterns.md`. Borrowing the **modular, scoped, per-domain instruction pattern** (each file short, glob-targeted, with concrete BLOCKER lists) would make My-Fab's rules easier for agents to load selectively and easier to maintain. ASCOA's `architecture-rules.instructions.md` is a good model: each rule states the invariant, then an explicit list of code patterns to flag as BLOCKER.

### 6.2 Impact-analyzer agent

ASCOA's roster includes a dedicated **`impact-analyzer`** agent (alongside requirement-analyst, code-developer, test-designer/runner/strategist, security-reviewer, quality-gate, db-migration-author, doc-writer). My-Fab's pipeline has design validators and a release validator but no dedicated up-front blast-radius analysis step. Consider adding one to the WF-02/WF-03 pipelines.

### 6.3 Architecture-document craft

ASCOA's `ARCHITECTURE_v0.4.md` is worth borrowing as a *form*:

- A **"Top-level decisions (resolved)"** table — one row per concern, decision, and rationale.
- The **heartbeat-cycle** framing as the single organizing loop every component serves.
- An **audit-driven changelog** at the top ("Changes since v0.3: (C1)… (H2)…") that records what each audit round resolved.
- Inline cross-references (§-numbers) and per-requirement implementation footnotes tying spec to source files.

This makes the document self-auditing and easy to diff across revisions — a good template for My-Fab's architecture docs.

---

## 7. What NOT to borrow

- **Mutable hybrid relational + JSONB entity store**, `row_version` everywhere, expand/contract field promotion, hot-field monitor. My-Fab is event-sourced; its equivalent is **re-projection**, which is simpler and avoids the dual-write/lost-write hazards ASCOA spent three audit rounds fixing. (Targeted optimistic-concurrency at command boundaries — task completion, entity commands — is the one narrow exception worth keeping.)
- **Wasm-everywhere / Lua-compiled-to-Wasm** unification. My-Fab's explicit 3-tier DSL→Lua→Wasm model is richer and a genuine strength; keep it.
- **Per-schema dump reconciliation as the primary backup mechanism.** My-Fab replays the event log; only the in-flight-wait re-arm subset (§4.2) applies.

---

## 8. Recommended sequence

1. **Confirm current state** of `src/effects` (async?), `src/secrets` (envelope encryption?), and `src/entities` (events + typed projections?) — three quick source reads that determine whether §5.2/§5.3 are "borrow" or "already done."
2. **Borrow the engine specs** (FR-BPM-13/14/15/16) into My-Fab's requirements — high value, well-bounded, ASCOA's acceptance criteria are reusable.
3. **Write the mobile architecture doc** from ASCOA's template (§3).
4. **Harden operations** (scale anchor, quotas, sandbox threat model) — cheap documentation wins.
5. **Adopt modular agent-instruction files** (§6.1) and consider an impact-analyzer agent (§6.2).
6. **Decide compensation/saga direction** (§5.1) — the one large architectural commitment; sequence after entities + async effects land.

---

*Static comparison. Claims about My-Fab reflect its `src/`/`docs/` tree and the prior 6/11 gap analysis; claims about ASCOA-GO reflect its `docs/` (ARCHITECTURE_v0.4, ARCHITECTURE_MOBILE, FR-* requirements dated through 2026-06-23/26) and `internal/` tree — not runtime behavior of either system.*
