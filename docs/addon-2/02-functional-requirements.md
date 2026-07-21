# BPM Platform — Functional Requirements (Borrowing from ASCOA-GO)

**Version:** 0.1-draft
**Date:** 2026-06-26
**Scope:** The `BRW-*` requirement family — capabilities adopted from ASCOA-GO. Mobile tier, engine failure/compensation/restore, effects/saga verification, secrets rotation, operational specs.
**Companion document:** `01-architecture-addition.md`
**Source analysis:** `docs/Audit-Reports/Borrowing_From_ASCOA-GO.20260626.md`

---

## How to read this document

Each requirement has a stable **ID** (`BRW-<AREA>-<n>`, never reused), a **Title**, a normative **Statement** (MUST / SHOULD / MAY, RFC 2119), a **Priority**, and **Acceptance hints** an implementing agent can verify.

**Verify-then-extend marker.** Many requirements act on subsystems that already exist. Each such requirement opens with a **VERIFY** clause (confirm the current behaviour, by reading `src/`) and then an **EXTEND** clause (the delta to build). A requirement is not complete until both are satisfied. If VERIFY shows the behaviour already fully exists, the requirement is closed as *already-satisfied* with a one-line note — not re-implemented.

**Priority legend:** **MUST** — required for the borrow to be considered done · **SHOULD** — strongly recommended, deferral needs recorded rationale · **COULD** — desirable, defer freely.

**Areas:** `MOB` mobile · `ENG` engine failure/compensation/restore · `EFX` effects · `SAGA` saga runner · `SEC` secrets · `OPS` operations.

---

## Area MOB — Mobile tier (greenfield)

### BRW-MOB-1 — Generic definition-interpreter mobile app
**Priority:** MUST
**Statement:** The platform MUST provide a mobile application (`apps/mobile/`) that is a generic interpreter of server-delivered definitions. It MUST ship a single tenant-agnostic build with no per-tenant code or assets, and MUST execute no tenant-authored formula or script logic on-device in v1 (all evaluation server-side, identical to the SPA).
**Acceptance hints:**
- A single build artifact authenticates against and renders for at least two distinct tenants without rebuild.
- Static inspection: no tenant identifiers, formula evaluators, or script runtimes compiled into the bundle.
- All computed-field/visibility evaluation traffic resolves to the existing server formula endpoint.

### BRW-MOB-2 — Tenant bootstrap sequence
**Priority:** MUST
**Statement:** The app MUST resolve tenant identity from a deep-link subdomain or manual slug entry, fetch an unauthenticated tenant configuration, authenticate via OIDC Authorization-Code + PKCE through the platform browser, store tokens in OS-secure storage, and load the user profile/permissions before showing tenant content.
**Acceptance hints:**
- `GET /tenant-config` (or the SPA's existing equivalent — **VERIFY** which) returns `{ realm_url, locales, default_locale, branding, environment_kind }`.
- OIDC uses Custom Tabs (Android) / SFSafariViewController (iOS), not an embedded webview.
- Dedicated error screens exist for: tenant-not-found, network-unavailable, OIDC-failure, secure-storage-unavailable.

### BRW-MOB-3 — Offline definition cache with delta sync and version pinning
**Priority:** MUST
**Statement:** The app MUST cache definitions locally keyed by `(type, id, version)`, render from cache on launch without a definition spinner, and refresh via background delta sync. A pinned interaction (task payload carrying `{ form_id, form_version }`) MUST render the exact pinned version and MUST NOT silently fall back to the active version.
**Acceptance hints:**
- **VERIFY:** confirm task payloads already carry `form_version`; if not, that gap is raised against the task API.
- `GET /definitions/delta?since=<ts>` returns only changed definitions (this endpoint MAY be new).
- Airplane-mode launch renders previously cached definitions; a pinned form with a missing cached version triggers a server fetch, never an active-version substitution.

### BRW-MOB-4 — Generic renderers with six mandatory states
**Priority:** MUST
**Statement:** The app MUST provide form, list, process-instance, and task-inbox renderers driven by the same server definition format as the SPA. Every renderer MUST handle all six states: loading, fetch-failure, permission-denied, stale-version, validation-error, and 429-backpressure.
**Acceptance hints:**
- Form renderer supports all platform field types (text, number, boolean, date, datetime, select, multi-select, reference, file, computed, hidden).
- List renderer supports filter and keyset pagination.
- Task renderer supports inbox / claim / complete against the existing task API.
- A forced 429 from the server produces a retry-after countdown, not a crash.

### BRW-MOB-5 — On-device security
**Priority:** MUST
**Statement:** Tokens MUST be stored only in OS-secure storage (Keychain / EncryptedSharedPreferences), never in plain preferences or logs. The token audience MUST be scoped to the tenant realm. Cleartext traffic MUST be disabled. Secret values MUST be masked by default with one-time reveal on creation.
**Acceptance hints:**
- Static check: no token value reaches a log sink; no plaintext-preferences API is used for tokens.
- Android `network-security-config` and iOS ATS forbid cleartext.
- `[S]` certificate pinning and root/jailbreak detection are documented as required before any corporate-tier deployment.

### BRW-MOB-6 — API client with auth, refresh, retry, typed errors
**Priority:** SHOULD
**Statement:** All network access SHOULD go through a single API client that attaches the bearer token, performs silent refresh on 401 then retries the original request, applies exponential backoff on 5xx, and normalizes every error to a typed `ApiError` before it reaches UI state.
**Acceptance hints:** A 401 mid-session triggers one silent refresh + retry; on refresh failure tokens are cleared and the user is routed to login. No raw transport exception reaches a widget.

### BRW-MOB-7 — Internationalisation
**Priority:** SHOULD
**Statement:** All user-visible strings SHOULD come from localisation resources (no hardcoded strings). The locale set and fallback chain MUST match the platform's web locale policy (**VERIFY** the SPA's configured locales and reuse them; do not assume a locale set).
**Acceptance hints:** Tenant content resolves from the session locale using the same `{locale: value}` map the SPA uses; date/number formatting follows session locale.

### BRW-MOB-8 — v1 scope boundary
**Priority:** MUST
**Statement:** v1 MUST be online-first with a read-through definition cache. Offline writes, push-based cache invalidation, and an on-device form builder MUST be out of v1 scope and recorded as deferred.
**Acceptance hints:** No optimistic offline write queue exists in v1; the scope table in the mobile architecture doc matches the shipped feature set.

---

## Area ENG — Engine failure, compensation, restore

### BRW-ENG-1 — Formalized per-node retry policy
**Priority:** MUST
**Statement:**
**VERIFY:** the DLQ (`src/dlq`) already tracks `retry_count` / `retry_limit` for `SERVICE_TASK / WEBHOOK / TIMER`. Confirm whether backoff, jitter, and deterministic-failure handling already exist.
**EXTEND:** each retryable node MUST carry a `RetryPolicy{ MaxAttempts, InitialInterval, CapInterval, Jitter }` (default 3 attempts, 100 ms→5 s, 10 % jitter). Failures classified as **deterministic** (Wasm trap, memory/wall-clock/resource-cap violation, OOM) MUST consume a reduced budget. The per-attempt idempotency key MUST be `<step_execution_id>-attempt-N` with the attempt counter persisted, not re-parsed from the key.
**Acceptance hints:** a deterministic failure exhausts its budget in fewer attempts than a transient one; the retry loop provably terminates; backoff windows observed between attempts.

### BRW-ENG-2 — Failed-instance lifecycle
**Priority:** MUST
**Statement:** On retry-budget exhaustion the instance MUST transition to a `failed` state and the failing token to `failed`. The failure log record MUST be committed in a transaction **separate from** (and after) the rolled-back step transaction, so it survives the rollback. A `process.step_failed` event MUST be emitted via the outbox. Failed instances MUST be surfaced (observability/DLQ) with **retry** (re-runs the pinned definition version) and **cancel** (cancels all tokens) actions. A subsequent advance on a `failed`/`completed`/`cancelled` instance MUST be rejected, not silently re-driven.
**Acceptance hints:** killing a step mid-transaction still leaves exactly one durable failure record; retrying a failed instance executes the version it started with, not the current active version.

### BRW-ENG-3 — Parallel-branch failure isolation
**Priority:** MUST
**Statement:** When one token of a parallel (AND) split fails, sibling tokens MUST continue to execute. The AND-join MUST block until the failed token is resolved (retried-to-success or instance cancelled) and MUST NOT proceed with a missing token.
**Acceptance hints:** a two-branch parallel process with one failing branch shows the healthy branch completing while the join stays pending; cancelling the instance releases the join path deterministically.

### BRW-ENG-4 — Compensation and error-boundary constructs
**Priority:** SHOULD
**Statement:**
**VERIFY:** the design `src/design/compensation-restore-reconciliation.md` (EXP-401) defines the types but is marked "no implementation code."
**EXTEND:** implement engine-level compensation — a handler attached to a scope, triggered by an error-boundary event on error or cancel, recorded as a **first-class compensation event** visible in replay/audit. The definition validator MUST treat a compensation handler as reachable only when the attached scope **dominates** the protected node in the graph.
**Acceptance hints:** a failing protected scope fires its registered handler in reverse order; the compensation chain appears in the event log; the validator rejects a handler attached to a non-dominating scope.

### BRW-ENG-5 — Restore reconciliation with `instance_waits`
**Priority:** SHOULD
**Statement:**
**VERIFY:** EXP-103 (`instance_waits`) and EXP-402 (restore reconciliation) are designed, not implemented.
**EXTEND:** every wait-arming step MUST persist a durable `instance_waits` descriptor (kind `timer | catch_event | human_task`, `fire_at`, correlation/task ref) in the **tenant schema, in the same transaction** that arms the wait. Tenant restore MUST run a reconciliation pass: replay events → rebuild projections → purge transient platform-schema rows → re-arm waits from descriptors → mark any non-re-armable instance `restored_orphan`, surfaced as a **DLQ condition plus an observability flag** (resolving the design's open question #1).
**Acceptance hints:** a tenant logical dump + restore re-arms all timers/catch-waits without external state; an instance whose wait cannot be re-armed appears in the DLQ as `restored_orphan` rather than hanging silently.

---

## Area EFX — Effects (verify-then-extend on shipped code)

### BRW-EFX-1 — Async-effects coverage and hardening
**Priority:** SHOULD
**Statement:**
**VERIFY:** `src/effects` already implements `EFFECT_EMITTED` → worker → `EFFECT_COMPLETED/FAILED` re-entry with a sandbox stub executor (EXP-301/302/303). Confirm: (a) a process can model `emit effect → wait on catch event → branch on outcome`; (b) outbound HTTP sends a stable idempotency key derived from the originating effect event id.
**EXTEND:** add **per-endpoint circuit breaking** `[S]`; confirm the sandbox stub records intent (channel, payload, count) for deterministic assertions.
**Acceptance hints:** a catch-event node branches on `effect.completed` vs `effect.failed`; a configured endpoint that fails repeatedly trips its breaker; sandbox assertions like `notifications_sent: 1` are checkable without real I/O.

---

## Area SAGA — Generic saga runner

### BRW-SAGA-1 — Minimal generic saga runner
**Priority:** SHOULD
**Statement:**
**VERIFY:** provisioning is currently hand-rolled in `src/api/routes/onboarding.zig` with compensating deletes.
**EXTEND:** extract a small generic saga runner — persisted step state, forward execution, reverse compensation, resumability — supporting **linear steps + reverse compensation only** (no gateways, no events). It MUST be used by provisioning/de-provisioning and MUST NOT be exposed to tenants. Richer orchestration MUST remain in the BPM engine, not the saga runner.
**Acceptance hints:** a provisioning failure at step N compensates steps N-1…1 in reverse; an interrupted saga resumes from its persisted state; the runner has no gateway/branch constructs.

---

## Area SEC — Secrets

### BRW-SEC-1 — HMAC ingress key rotation with grace window
**Priority:** SHOULD
**Statement:**
**VERIFY:** `src/secrets` already provides AES-256-GCM envelope encryption, by-reference resolution, log redaction, and webhook HMAC keys.
**EXTEND:** webhook HMAC ingress keys MUST support rotation — each signature carries a key id; rotation issues a new key while the prior key stays valid for a **dual-key grace window**, after which it is revoked. Issuance and key-id display are MUST; the full rotation-with-grace-window flow is SHOULD.
**Acceptance hints:** during the grace window, signatures from both the old and new key validate; after the window the old key is rejected; no secret material appears in logs or traces.

---

## Area OPS — Operational specifications

### BRW-OPS-1 — Stated scale anchor
**Priority:** MUST
**Statement:** The architecture MUST state an explicit target tenant ceiling (tenant count and schema count) and justify the single-primary / single-drainer / single-sweep simplifications against it.
**Acceptance hints:** a number exists in the architecture doc; each schema-per-tenant simplification cites it.

### BRW-OPS-2 — Tier→quota model coverage
**Priority:** SHOULD
**Statement:**
**VERIFY:** EXP-601 quota middleware enforces `entity_write / file_write / sandbox_allocate / agent_retry / script_execute`.
**EXTEND:** confirm every borrowed dimension (storage volume, file count, sandbox concurrency, agent retry budget) maps to a tier policy enforced centrally in kernel middleware; add any missing dimension. No quota may be enforced ad hoc in a single subsystem only.
**Acceptance hints:** each dimension has a tier→limit row; exceeding any dimension is rejected by the central middleware with a consistent error shape.

### BRW-OPS-3 — Written sandbox threat model
**Priority:** MUST
**Statement:** A written threat model MUST exist for the two untrusted runtimes (Lua, Wasm) and the agent pipeline, enumerating the host-function allowlist, resource caps, and isolation guarantees, and it MUST gate agent-authored production code (no agent-authored code reaches production without satisfying it).
**Acceptance hints:** the document lists allowed host functions and denied capabilities (network, disk, real clock); a promotion gate references it.

### BRW-OPS-4 — Ephemeral throwaway-sandbox tier (conditional)
**Priority:** COULD
**Statement:** **IF** agent-authored tenant logic becomes a near-term product surface, the platform SHOULD add a warm-pool, sub-second-claim, torn-down-on-exit sandbox schema tier with a virtual clock (`advance_clock`) and an assertion / `complete_task` control API, reusing the existing simulation runtime and agent identities. If agent-authoring stays a later phase, this requirement is deferred with recorded rationale.
**Acceptance hints:** a claimed sandbox reaches ready (pooled schema + tenant DDL + fixtures) within the sub-second target; timers fire deterministically only via `advance_clock`; the sandbox is torn down on every exit path.

---

## Dependency summary (full ordering in `03-implementation-order.md`)

```
BRW-OPS-1, BRW-OPS-3        (docs, no deps)
        │
BRW-ENG-1 → BRW-ENG-2 → BRW-ENG-3      (failure semantics)
        │
        ▼
BRW-ENG-4 (compensation) → BRW-ENG-5 (restore)
        │
BRW-SAGA-1, BRW-EFX-1, BRW-SEC-1, BRW-OPS-2   (verify/extend, parallelisable)
        │
BRW-OPS-4 (conditional)

BRW-MOB-1 … BRW-MOB-8   — independent track; depends only on existing server contracts
```

---

*Requirements only. Every VERIFY clause must be discharged against the live `src/` tree before the corresponding EXTEND work begins.*
