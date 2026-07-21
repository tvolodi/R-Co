# BPM Platform — Architecture Addition (Borrowing from ASCOA-GO)

**Version:** 0.1-draft
**Date:** 2026-06-26
**Companion documents:**
- `02-functional-requirements.md` — the `BRW-*` requirements this document structures.
- `03-implementation-order.md` — sequenced build plan.
- Source analysis: `docs/Audit-Reports/Borrowing_From_ASCOA-GO.20260626.md` and `…/BPM_vs_ASCOA-GO_Gap_Analysis.20260611.md`.
- Reference platform: ASCOA-GO `docs/ARCHITECTURE_v0.4.md`, `docs/ARCHITECTURE_MOBILE.md`.
- Predecessor extension: `docs/addon-1/01-architecture.md` (Stages 6.5–11).

---

## 1. Purpose and authority

This document specifies **structural additions** to the BPM Platform that adopt proven patterns from ASCOA-GO, a peer platform. It does **not** restate or modify shipped behaviour. It introduces only what is genuinely new or under-built.

It follows `addon-1`'s authority model: where this document conflicts with a shipped requirement, the shipped requirement wins for shipped subsystem behaviour; new-subsystem behaviour (the mobile tier, compensation constructs) is governed here. Each structural addition maps to one or more `BRW-*` functional requirements in the companion document.

**Verify-then-extend discipline.** Several subsystems this document touches already exist in `src/`. For each, the requirement is to *confirm current behaviour first*, then build only the delta. The table in §2 records what was found in the source tree on 2026-06-26 so the architecture is grounded in reality, not in the (now partly stale) June gap analysis.

---

## 2. Baseline — what already exists (verified 2026-06-26)

| Capability | Status in `src/` | Implication for this addition |
|---|---|---|
| **Async effects** (`src/effects`) | **Shipped** — EXP-301/302/303: `EFFECT_EMITTED` → worker (FOR UPDATE SKIP LOCKED) → `EFFECT_COMPLETED/FAILED` re-entry; stub executor for sandbox. | Do **not** rebuild. Only verify coverage + add per-endpoint circuit breaking `[S]`. |
| **Per-tenant secrets** (`src/secrets`) | **Shipped** — AES-256-GCM envelope encryption, AES-KW key wrap, by-reference resolution (`sec://…`), log redaction, webhook HMAC keys. | Do **not** rebuild. Gap is HMAC **rotation with dual-key grace window**. |
| **Dynamic entities** (`src/entities`) | **Shipped** — EXP-201/202: event-sourced `ENTITY_RECORD_*`, typed projection table `entity_record_latest`, projector rebuild, validator (queried+json exclusion, index coverage). | Matches the recommended events+projections model. No structural change needed. |
| **Quota enforcement** (`src/api/middleware/quota_enforcement.zig`) | **Shipped** — EXP-601: tier→quota policy, dimensions `entity_write / file_write / sandbox_allocate / agent_retry / script_execute`. | Verify dimension coverage; extend only if a borrowed dimension is missing. |
| **Step failure / DLQ** (`src/dlq`, `src/engine`) | **Partial** — DLQ store with `retry_count` / `retry_limit`; item types `SERVICE_TASK / WEBHOOK / TIMER`. | Formalize per-node **retry policy** (backoff, jitter, deterministic-failure classification), **failed-instance** lifecycle, **parallel-branch isolation**. |
| **Compensation + restore** (`src/design/compensation-restore-reconciliation.md`) | **Designed, not implemented** — EXP-401 (compensation/error-boundary), EXP-402 (restore reconciliation), EXP-103 (`instance_waits`). | Promote from design to implementation. |
| **Provisioning saga** (`src/api/routes/onboarding.zig`) | **Shipped as hand-rolled onboarding** — schema → realm → seed, with compensating deletes. | Extract a **generic minimal saga runner** (linear + reverse compensation). |
| **Mobile tier** | **Absent** — no `apps/mobile`, no mobile architecture doc. | New subsystem. Largest addition. |
| **Scale anchor / sandbox threat model / ephemeral sandbox tier** | **Absent as written specs** — simulation runtime is scenario-replay (`src/simulation`). | Documentation + a new agent-tier sandbox if agent-authored tenant logic is in scope. |

The net effect: the backend borrows reduce to **finishing designed work** (compensation, restore), **formalizing partial work** (failure semantics, saga extraction), and **closing doc gaps** (scale anchor, threat model). The one large greenfield addition is the **mobile tier**.

---

## 3. Mobile tier (new subsystem)

### 3.1 Governing principle

The mobile app is a **generic interpreter of server-delivered definitions** — identical in principle to the existing React SPA. One tenant-agnostic build serves every tenant; the app ships renderers that operate over JSON definitions fetched at runtime; **no per-tenant code or assets are bundled**. In v1 the app executes **no tenant logic** on-device — all formula/script evaluation stays server-side, exactly as the SPA does. This reuse of principle is what makes the tier cheap: it consumes the *same* server contracts the SPA already exposes (definition fetch, form/list/process/task APIs, batched formula evaluation, version-pinned task payloads).

### 3.2 Placement and stack

```
apps/mobile/                 # new top-level app, peer to web/
  lib/
    bootstrap/   auth/   api/   definitions/
    renderers/   form/ list/ process/ task/
    features/    design_system/   i18n/   shared/
```

Stack (backend-agnostic, transfers verbatim from ASCOA's `ARCHITECTURE_MOBILE.md`): Flutter 3.x · Dart 3 · go_router · Riverpod · Dio · flutter_appauth (OIDC Auth-Code + PKCE) · flutter_secure_storage · a local definition cache (Isar or equivalent) · intl. Platform targets Android API 26+, iOS 15+.

### 3.3 Three things the mobile tier requires from the existing backend

1. **An unauthenticated `tenant-config` endpoint** returning `{ realm_url, locales, default_locale, branding, environment_kind }` for slug-based bootstrap. *Verify whether the SPA already relies on an equivalent; reuse it if so.*
2. **A definition delta-sync endpoint** (`GET /definitions/delta?since=…`) so the device can warm an offline cache and refresh incrementally. *This may be new.*
3. **Version-pinned task payloads** carrying `{ form_id, form_version }` — already implied by the platform's version-pinning rule; confirm the task API emits them.

These three are the only backend touch-points; everything else is client-side. They are captured as acceptance hints in `BRW-MOB-*`.

### 3.4 Boundary

v1 is **online-first with a read-through definition cache**. Offline writes, push-based cache invalidation, and an on-device form builder are explicitly out of v1 scope (deferred), mirroring ASCOA's scope table. This keeps the tier additive and avoids an offline-write conflict model the platform does not yet need.

---

## 4. Engine additions — failure, compensation, restore

### 4.1 Failure is a defined state, not an exception path

Adopt ASCOA's framing as a first-class engine rule. A step fails when its script traps, exceeds a resource cap, or its transaction aborts. The semantics, layered onto the existing DLQ:

- **Per-node retry policy** `{ MaxAttempts, InitialInterval, CapInterval, Jitter }`, default 3 attempts, 100 ms→5 s backoff, 10 % jitter. **Deterministic failures** (Wasm trap, memory/wall-clock/resource-cap violation, OOM) get a reduced budget — re-running an infinite loop helps no one. Per-attempt idempotency key `<step_execution_id>-attempt-N`, counter **persisted, not re-parsed**.
- **Failed-instance lifecycle.** On budget exhaustion the instance transitions to a `failed` state and the token to `failed`. The **failure log row is committed in a separate transaction** after the step transaction rolls back, so the failure record survives the rollback. Failed instances surface in observability/DLQ with **retry** (re-runs the *pinned* definition version) and **cancel** (cancels all tokens) actions.
- **Parallel-branch isolation.** Sibling tokens of a failed token **continue to execute**; the AND-join **blocks** until the failed token is resolved (retried-to-success or instance cancelled). The join never proceeds with a missing token.

Because the platform is event-sourced and `transition.zig` is pure I/O-free, these are additions to the *orchestration* layer around the transition function, never inside it.

### 4.2 Compensation and error-boundary constructs (promote EXP-401)

Promote compensation from hand-modeled paired service tasks to **engine constructs**: a compensation handler attached to a scope, triggered by an error-boundary event on error or cancel, recorded as a **first-class compensation event** so the chain is visible in replay and audit. The existing design (`src/design/compensation-restore-reconciliation.md`) already defines the types (`CompensationHandlerRef`, `ErrorBoundaryNode`, `CompensationRecord`, `CompensationTriggerReason`); this addition authorizes its implementation. The validator must treat a handler as reachable only when the attached scope **dominates** the protected node in the definition graph (resolving the design's open question #2).

### 4.3 Restore reconciliation and `instance_waits` (promote EXP-402 / EXP-103)

Persist a durable **`instance_waits` descriptor** in the **tenant schema** in the *same transaction* that arms a wait (timer / catch-event / human-task), carrying wait kind, `fire_at`, and the correlation/task reference. On single-tenant restore, run a **reconciliation pass**: replay events → rebuild projections → purge transient platform-schema rows → **re-arm waits** from the descriptors → mark any non-re-armable instance `restored_orphan` (surfaced via DLQ/observability). This makes a tenant logical dump self-sufficient and prevents silently-hung instances after restore. The design's open question #1 (`restored_orphan` as status vs flag vs DLQ record) is resolved in the FR: it is a **DLQ-surfaced instance condition** plus an observability flag.

### 4.4 Why these three are sequenced together

Restore (4.3) needs a complete wait picture, which requires both the wait-descriptor write (armed at every wait point) and an understanding of compensation scopes (4.2) so a restored-and-failed instance compensates correctly rather than dead-ending. Hence the implementation order builds failure semantics → compensation → restore.

---

## 5. Effects and saga

### 5.1 Effects — verify, don't rebuild

`src/effects` already implements the async emit→deliver→re-enter loop with a sandbox stub. The architectural addition is narrow: confirm the **catch-event branch contract** (a process can `emit effect → wait on catch event → branch on outcome`), confirm a **stable idempotency key derived from the effect event id** is sent on outbound HTTP, and add **per-endpoint circuit breaking** `[S]`. No new module.

### 5.2 Generic minimal saga runner

Extract the shipped onboarding provisioning logic into a **small, generic saga runner**: persisted step state, forward execution, reverse compensation, resumability — **linear steps + reverse compensation only, no gateways, no events**. Kept deliberately minimal so it never grows into a second engine; richer orchestration belongs to the BPM engine, not the saga runner. Used by provisioning/de-provisioning in v1; not exposed to tenants. This is a refactor-to-pattern of existing code plus a persisted-state store, not a greenfield build.

---

## 6. Operational additions

- **Stated scale anchor.** Record an explicit target tenant ceiling (e.g. ~N tenants / ~M schemas) so every schema-per-tenant simplification (single primary, single drainer, single sweep) is justified against it. Pure documentation; de-risks the single-writer assumptions.
- **Tier→quota model.** EXP-601 is shipped; verify it covers every borrowed dimension (storage, file, sandbox, agent-retry budget, script-execute) and that enforcement is **central in kernel middleware**, not retrofitted per subsystem.
- **Written sandbox threat model.** The platform runs *two* untrusted runtimes (Lua + Wasm) plus an agent pipeline — a documented threat model is more urgent here than in ASCOA. It must **gate agent-authored production code**.
- **Ephemeral throwaway-sandbox tier (conditional).** If agent-authored *tenant* logic becomes a near-term product surface, add a warm-pool, sub-second-claim, torn-down-on-exit sandbox schema with a **virtual clock** (`advance_clock`) and an **assertion / `complete_task` control API**. The existing `src/simulation` scenario-replay runtime and agent identities (`src/oidc`) give a head start. Scoped as conditional because it is only justified by the agent-authoring roadmap.

---

## 7. What this addition explicitly does NOT adopt

- **Mutable hybrid relational + JSONB entity store**, `row_version`-everywhere, expand/contract field promotion, hot-field monitor. The platform is event-sourced; its equivalent is **re-projection**, already implemented in `src/entities`. Keeping ASCOA's mutable store would import the dual-write/lost-write hazards ASCOA spent three audit rounds fixing. (Targeted optimistic concurrency at command boundaries — task completion, entity commands — is the one narrow exception and is already the pattern in `src/tasks`.)
- **Wasm-everywhere / Lua-compiled-to-Wasm** unification. The explicit 3-tier DSL→Lua→Wasm model is richer and a deliberate strength; keep it.
- **Per-schema dump reconciliation as the primary backup mechanism.** Primary mechanism stays event-log replay; only the in-flight-wait re-arm subset (§4.3) is borrowed.

---

## 8. Traceability — additions to requirements

| Addition (this doc) | Requirements | Prior art in repo |
|---|---|---|
| Mobile tier (§3) | BRW-MOB-1 … BRW-MOB-8 | none (greenfield) |
| Failure semantics (§4.1) | BRW-ENG-1, BRW-ENG-2, BRW-ENG-3 | `src/dlq`, `src/engine` |
| Compensation constructs (§4.2) | BRW-ENG-4 | EXP-401 design |
| Restore reconciliation (§4.3) | BRW-ENG-5 | EXP-402 / EXP-103 design |
| Effects verification (§5.1) | BRW-EFX-1 | EXP-301/302/303 (shipped) |
| Generic saga runner (§5.2) | BRW-SAGA-1 | onboarding routes (shipped) |
| Secrets HMAC rotation (§6) | BRW-SEC-1 | `src/secrets` (shipped base) |
| Scale anchor (§6) | BRW-OPS-1 | none |
| Quota verification (§6) | BRW-OPS-2 | EXP-601 (shipped) |
| Sandbox threat model (§6) | BRW-OPS-3 | none |
| Ephemeral sandbox tier (§6) | BRW-OPS-4 | `src/simulation`, `src/oidc` |

---

*Structural addition only. Claims about current `src/` state reflect a static read on 2026-06-26 and must be reconfirmed by the implementing agent per the verify-then-extend rule before building.*
