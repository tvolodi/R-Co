# BPM Platform — Correctness Remediation Backlog

**Source:** v1.1 correctness & consistency pass on `BPM_Platform_Backend_Architecture.md`
**Purpose:** Convert the documented fixes into development-ready requirements and issues.
**Audience:** Autonomous coding agents + human reviewers.
**Date:** 2026-06-11

---

## How to use this backlog with an agent team

Each issue below is **self-contained**: an agent should be able to pick it up with only the
issue text, the architecture doc, and repo access. To run it as a workflow:

1. **Import.** Create the six epics first, then the issues under them. Keep the `ID` in the
   title (e.g. `[ISS-201] …`) so cross-references and dependency links survive import. If you
   later push to a tracker, the `Labels` and `Depends on` fields map to tracker labels and
   blocking links.
2. **Order by dependency, not by number.** Start with the schema/migration epic (EPIC-1) — most
   other work assumes those columns exist. The `Depends on` field is the source of truth; a
   suggested wave order is given in [Execution order](#execution-order).
3. **One issue → one branch → one PR.** Each issue names its touchpoints (files + migrations)
   and a test plan. The PR is done when every acceptance criterion is checked and the test plan
   passes in CI against a real PostgreSQL (per the doc's stage-gate test strategy).
4. **Definition of Done (applies to every issue).** Code + migration (forward and, where
   applicable, a documented rollback) + unit tests for any pure logic + an integration test
   against real PostgreSQL covering the acceptance criteria + the architecture doc kept in sync
   if behaviour deviates from v1.1. No issue is done with failing tests or a partial migration.
5. **Guardrails for agents.** Migrations must be idempotent and additive-first (add column /
   backfill / switch reads / drop legacy in separate issues — never a destructive change in the
   same migration that introduces a column). Do not remove the legacy RLS path until its
   dedicated issue (ISS-503). Treat the pure transition function's I/O-free property as
   inviolable.

**Priority key:** `P0` runtime-breaking or data-integrity; `P1` correctness gap that bites in
some path; `P2` quality/consistency. **Estimate:** rough agent-session size (S ≤ ½ day, M ≈ 1
day, L ≈ 2–3 days).

---

## Epics

| Epic | Theme | Issues |
|---|---|---|
| **EPIC-1** | Schema & migrations | ISS-101 … ISS-107 |
| **EPIC-2** | Event-sourcing integrity | ISS-201 … ISS-208 |
| **EPIC-3** | Scheduler & concurrency | ISS-301 … ISS-303 |
| **EPIC-4** | Identity, auth & rate limiting | ISS-401 … ISS-404 |
| **EPIC-5** | Multi-tenancy & SPT coexistence | ISS-501 … ISS-504 |
| **EPIC-6** | Performance & cutover quality | ISS-601 … ISS-602 |

---

## EPIC-1 — Schema & migrations

> Foundational. These add the columns/tables that EPIC-2..5 depend on. Each is an additive,
> idempotent migration; backfills and read-path switches are separate issues where noted.

### [ISS-101] Allow `FAILED` in `timers.status` CHECK constraint
- **Epic:** EPIC-1 · **Priority:** P0 · **Estimate:** S · **Labels:** schema, scheduler, bug
- **Depends on:** —
- **Context:** §6.6 moves a timer to status `FAILED` after exhausted retries, but migration 007's
  CHECK is `('PENDING','FIRED','CANCELLED')`. The UPDATE is rejected at runtime.
- **Acceptance criteria:**
  - [ ] New migration alters `timers.status` CHECK to include `'FAILED'`.
  - [ ] Migration is idempotent and applies cleanly to every existing tenant schema.
  - [ ] Updating a timer to `FAILED` succeeds; an invalid value still raises.
- **Touchpoints:** `migrations/0xx_timers_failed_status.sql`; `src/scheduler/scheduler.zig`.
- **Test plan:** Integration test: insert timer, set `FAILED`, assert row + DLQ entry created;
  assert `'BOGUS'` rejected.

### [ISS-102] Add `tasks.claimed_by` and a real claim path
- **Epic:** EPIC-1 · **Priority:** P0 · **Estimate:** M · **Labels:** schema, tasks, bug
- **Depends on:** —
- **Context:** §6.5 claim used `assignee_ref IS NULL`, but `assignee_ref` holds the GROUP/ROLE
  pool and is set at activation, so the guard can never succeed and there's no column for the
  individual who claimed the task.
- **Acceptance criteria:**
  - [ ] Migration adds `tasks.claimed_by UUID NULL`.
  - [ ] `POST /tasks/:id/claim` performs `UPDATE … SET claimed_by=$worker WHERE task_id=$id AND claimed_by IS NULL AND status='PENDING'`; 0 rows → `409`.
  - [ ] Only `claimed_by` (or a USER-assigned `assignee_ref`) may complete the task.
  - [ ] Partial indexes from §5.2 added: unclaimed-pool and `claimed_by` ("my tasks").
- **Touchpoints:** `migrations/0xx_tasks_claimed_by.sql`; `src/tasks/store.zig`; `src/api/routes/tasks.zig`.
- **Test plan:** Concurrent double-claim test (two workers, one wins, other gets 409); completion
  authorization test.

### [ISS-103] Change `audit_log.resource_id` to `TEXT`
- **Epic:** EPIC-1 · **Priority:** P1 · **Estimate:** S · **Labels:** schema, audit
- **Depends on:** —
- **Context:** Some resources are text-keyed (`role_name`, `event_type`, definition name) and
  cannot be stored in a `UUID NOT NULL` column.
- **Acceptance criteria:**
  - [ ] Migration changes `resource_id` to `TEXT NOT NULL` (existing UUID rows cast to text).
  - [ ] Audit writes for a role/event-type change succeed.
  - [ ] `idx_audit_resource` still valid.
- **Touchpoints:** `migrations/0xx_audit_resource_id_text.sql`; `src/obs/audit.zig`.
- **Test plan:** Audit a role grant (text key) and an instance change (uuid key); both queryable.

### [ISS-104] Add `instances.artifact_hash` and populate at start
- **Epic:** EPIC-1 · **Priority:** P1 · **Estimate:** S · **Labels:** schema, engine, repository
- **Depends on:** —
- **Context:** §15.1/ADP-05 says instances reference the artifact hash they ran against, but
  `instances` had no such column. `definition_snapshot` stays authoritative for execution; the
  hash is provenance.
- **Acceptance criteria:**
  - [ ] Migration adds `instances.artifact_hash TEXT NULL`.
  - [ ] Instance-start writes the promoted artifact's content hash.
  - [ ] Reproducibility query can resolve an instance → artifact.
- **Touchpoints:** `migrations/0xx_instances_artifact_hash.sql`; `src/engine/instance.zig`; `src/repository/artifacts.zig`.
- **Test plan:** Start an instance from a promoted artifact; assert `artifact_hash` matches the repo hash.

### [ISS-105] Persist the new token model (`{token_id,node_id}` + `join_counters`)
- **Epic:** EPIC-1 · **Priority:** P0 · **Estimate:** M · **Labels:** schema, engine, event-sourcing
- **Depends on:** —
- **Context:** §6.4 replaces `active_tokens: []NodeId` with an identified multiset and adds
  persisted `join_counters`. The projection columns must carry the new shape. (Engine logic is
  ISS-206; this issue is the storage/shape + migration + backfill.)
- **Acceptance criteria:**
  - [ ] `instances.active_tokens` stores `[{token_id, node_id}]`; new `instances.join_counters JSONB NOT NULL DEFAULT '{}'`.
  - [ ] Backfill converts existing `[node_id]` arrays to `[{token_id:gen, node_id}]`.
  - [ ] Replay from events reproduces identical `active_tokens` + `join_counters` (round-trip test).
- **Touchpoints:** `migrations/0xx_instances_token_model.sql`; `src/engine/instance.zig` (serde).
- **Test plan:** Backfill a fixture DB; rebuild via replay; assert byte-equal projection.

### [ISS-106] Formalize the `webhook_deliveries` outbox table
- **Epic:** EPIC-1 · **Priority:** P0 · **Estimate:** S · **Labels:** schema, webhook
- **Depends on:** —
- **Context:** §6.9 now guarantees at-least-once via a transactional outbox. The delivery table
  must be a first-class, documented migration (it was previously "added in Stage 6", unlisted).
- **Acceptance criteria:**
  - [ ] Per-tenant `webhook_deliveries`: `delivery_id`, `subscription_id`, `event_id`, `status ∈ (PENDING,DELIVERED,FAILED,RETRYING)`, `attempt`, `next_attempt_at`, `last_error`, `created_at`.
  - [ ] Index for worker claim: `(status, next_attempt_at)`.
- **Touchpoints:** `migrations/0xx_webhook_deliveries.sql`.
- **Test plan:** Insert/claim path exercised by ISS-205.

### [ISS-107] Add `public.tenants.storage_mode` flag
- **Epic:** EPIC-1 · **Priority:** P0 · **Estimate:** S · **Labels:** schema, multi-tenancy
- **Depends on:** —
- **Context:** §11.3 introduces `storage_mode ∈ {LEGACY_RLS, SCHEMA}` so each tenant has exactly
  one authoritative storage path during SPT coexistence.
- **Acceptance criteria:**
  - [ ] `GBL-` migration adds `public.tenants.storage_mode TEXT NOT NULL DEFAULT 'LEGACY_RLS' CHECK (...)`.
  - [ ] Existing tenants default to `LEGACY_RLS`; newly provisioned (post-SPT) tenants default to `SCHEMA`.
- **Touchpoints:** `migrations/GBL-0xx_tenant_storage_mode.sql`; `src/db/provisioning.zig`.
- **Test plan:** Provision a new tenant → `SCHEMA`; legacy tenant unchanged.

---

## EPIC-2 — Event-sourcing integrity

### [ISS-201] Make `transition()` return `{state, emitted_events}`
- **Epic:** EPIC-2 · **Priority:** P0 · **Estimate:** L · **Labels:** engine, event-sourcing, api-change
- **Depends on:** —
- **Context:** §6.4 — the pure function returned only `InstanceState`, but the orchestrator must
  persist the exact events the engine decided on (`VARIABLE_OVERWRITTEN`, `EXECUTION_ERROR`,
  etc.) which can't be reconstructed by diffing state.
- **Acceptance criteria:**
  - [ ] Signature returns `TransitionResult{ state, emitted_events: []Event }`.
  - [ ] Engine performs no I/O and does **not** re-append the trigger; orchestrator appends trigger + `emitted_events` in one transaction.
  - [ ] All call sites updated; existing behaviour preserved for happy paths.
- **Touchpoints:** `src/engine/transition.zig`, `src/engine/instance.zig`, every orchestrator caller.
- **Test plan:** Unit tests asserting emitted-event lists per event type; integration test asserting trigger+emitted committed atomically.

### [ISS-202] Two-phase (all-or-nothing) variable merge (EE-09)
- **Epic:** EPIC-2 · **Priority:** P1 · **Estimate:** M · **Labels:** engine, event-sourcing
- **Depends on:** ISS-201
- **Context:** The old loop emitted `VARIABLE_OVERWRITTEN` for early keys before hitting an
  invalid key, leaving a half-applied merge.
- **Acceptance criteria:**
  - [ ] Phase 1 validates **all** keys with no state change/events; on any failure, emit only `EXECUTION_ERROR` and leave variables untouched.
  - [ ] Phase 2 applies all keys and emits overwrites only when every key is valid.
  - [ ] Retry after failure sees the pre-merge state.
- **Touchpoints:** `src/engine/transition.zig`.
- **Test plan:** Unit test: mixed valid/invalid output → no overwrite events, instance ERROR, variables unchanged.

### [ISS-203] Deterministic idempotency keys for engine-emitted events
- **Epic:** EPIC-2 · **Priority:** P1 · **Estimate:** M · **Labels:** engine, event-sourcing, idempotency
- **Depends on:** ISS-201
- **Context:** §7.3 — cascade events need deterministic keys so replay/retry can't duplicate or
  collide.
- **Acceptance criteria:**
  - [ ] Key = stable hash of `(instance_id, triggering_event_seq, node_id, emitted_event_type, ordinal)`.
  - [ ] Re-running the same transition yields identical keys; `ON CONFLICT DO NOTHING` dedups.
  - [ ] Client-supplied command keys are unaffected.
- **Touchpoints:** `src/engine/transition.zig`, `src/event_store/store.zig`.
- **Test plan:** Replay a transition twice into the same DB; assert zero duplicate events.

### [ISS-204] Write `audit_log` inside the state-change transaction
- **Epic:** EPIC-2 · **Priority:** P0 · **Estimate:** M · **Labels:** audit, crash-safety
- **Depends on:** ISS-103
- **Context:** §6.1/§6.8/§7.1 — audit was a post-handler middleware step in a separate
  transaction, so a crash could lose an audit row for a committed change, or record a rolled-back
  one.
- **Acceptance criteria:**
  - [ ] The audit INSERT is enlisted in the handler's transaction (commits/rolls back with it).
  - [ ] Post-handler middleware no longer performs the audit write.
  - [ ] `before_state`/`after_state` captured within the same transaction.
- **Touchpoints:** `src/api/middleware/*`, `src/obs/audit.zig`, state-changing route handlers.
- **Test plan:** Crash-injection integration test (kill between event commit and old audit point) → audit and event are both present or both absent.

### [ISS-205] Webhook transactional outbox (true at-least-once)
- **Epic:** EPIC-2 · **Priority:** P0 · **Estimate:** L · **Labels:** webhook, event-sourcing, reliability
- **Depends on:** ISS-106
- **Context:** §6.9 — delivery was triggered by a post-commit in-process signal (at-most-once).
- **Acceptance criteria:**
  - [ ] Matching `webhook_deliveries` rows are inserted **in the same transaction** as the event.
  - [ ] Worker pool claims due/PENDING rows with `FOR UPDATE SKIP LOCKED`; in-process notify is only a latency optimisation; a periodic + startup sweep drains orphans.
  - [ ] Back-off ladder (5s,30s,2m,10m,30m / 5 attempts) recorded in the row; final failure pauses subscription + fires OBS-06.
  - [ ] Kill-after-commit test still delivers the webhook on restart.
- **Touchpoints:** `src/webhook/dispatcher.zig`, route handlers, `migrations` (ISS-106).
- **Test plan:** Integration: commit event, kill before workers run, restart → POST eventually sent; duplicate-safe (HMAC body identical).

### [ISS-206] Engine token multiset + persisted parallel-join counters
- **Epic:** EPIC-2 · **Priority:** P0 · **Estimate:** L · **Labels:** engine, concurrency, event-sourcing
- **Depends on:** ISS-105, ISS-201
- **Context:** §6.4 — node-id sets can't represent two tokens on one node; join counting needs
  state that replay rebuilds.
- **Acceptance criteria:**
  - [ ] `InstanceState` carries `active_tokens: []Token{token_id,node_id}` and `join_counters`.
  - [ ] PARALLEL split assigns fresh token ids; join increments the persisted counter and advances only when active-branch count is reached (cancelled branches subtracted).
  - [ ] Loops/reconverging branches keep correct multiplicity; replay reproduces exact arrangement.
- **Touchpoints:** `src/engine/transition.zig`, `src/engine/instance.zig`.
- **Test plan:** Unit tests for nested parallel + loop graphs; replay round-trip equality.

### [ISS-207] Convergent `EXECUTION_ERROR` retry (EE-10)
- **Epic:** EPIC-2 · **Priority:** P1 · **Estimate:** M · **Labels:** engine, dlq, operability
- **Depends on:** ISS-201
- **Context:** §6.4 — re-presenting the identical triggering event to a deterministic engine
  reproduces the identical error (no progress).
- **Acceptance criteria:**
  - [ ] `retry` requires a changed cause (new definition version or authorised correction event); a bare no-op retry is rejected with a hint.
  - [ ] `retry-with-input` re-presents the trigger with operator-supplied corrected payload.
  - [ ] `discard` still terminates the instance as CANCELLED.
- **Touchpoints:** `src/engine/instance.zig`, `src/dlq/store.zig`, `src/api/routes/dlq.zig`.
- **Test plan:** Error instance: bare retry → rejected; retry-with-input corrected → advances.

### [ISS-208] Guard task completion against terminal instances
- **Epic:** EPIC-2 · **Priority:** P1 · **Estimate:** S · **Labels:** tasks, correctness
- **Depends on:** —
- **Context:** §6.5 — a worker could complete a task on an ERROR/CANCELLED/COMPLETED instance.
- **Acceptance criteria:**
  - [ ] `complete()` returns `409` if the parent instance is not `ACTIVE`.
  - [ ] Guard is enforced inside the transaction (race-safe), not just a pre-check.
- **Touchpoints:** `src/tasks/store.zig`, `src/api/routes/tasks.zig`.
- **Test plan:** Cancel instance, attempt task completion → 409; no events appended.

---

## EPIC-3 — Scheduler & concurrency

### [ISS-301] Remove whole-cycle scheduler lock; use SKIP LOCKED shared queue
- **Epic:** EPIC-3 · **Priority:** P1 · **Estimate:** M · **Labels:** scheduler, concurrency, scalability
- **Depends on:** —
- **Context:** §4.3/§6.6/§8.2 — the cluster-wide advisory lock serialised firing to one node and
  was redundant with `FOR UPDATE SKIP LOCKED`.
- **Acceptance criteria:**
  - [ ] Poll loop no longer takes a cluster-wide leader lock; multiple nodes drain due timers concurrently via SKIP LOCKED with no double-firing.
  - [ ] Single-node path is identical code (no special-casing).
- **Touchpoints:** `src/scheduler/scheduler.zig`.
- **Test plan:** Two-node integration test firing a batch of due timers → each fired exactly once.

### [ISS-302] Run startup missed-timer sweep under an advisory lock
- **Epic:** EPIC-3 · **Priority:** P1 · **Estimate:** S · **Labels:** scheduler, concurrency
- **Depends on:** ISS-301
- **Context:** §6.6 SCH-05 — simultaneous multi-node restart could double-sweep.
- **Acceptance criteria:**
  - [ ] Startup sweep guarded by `pg_try_advisory_lock(SCHEDULER_STARTUP_LOCK_ID)`; only the holder sweeps, others go straight to the poll loop.
  - [ ] Sweep still selects `FOR UPDATE SKIP LOCKED` as defence in depth; swept timers get `is_late_fire=TRUE`.
- **Touchpoints:** `src/scheduler/scheduler.zig`.
- **Test plan:** Launch two nodes concurrently against due timers; assert single sweep, no double fire.

### [ISS-303] Route exhausted-retry timers to `FAILED` + DLQ
- **Epic:** EPIC-3 · **Priority:** P1 · **Estimate:** S · **Labels:** scheduler, dlq
- **Depends on:** ISS-101
- **Context:** §6.6 failure handling now relies on the `FAILED` status added in ISS-101.
- **Acceptance criteria:**
  - [ ] After `BPM_DLQ_MAX_RETRIES`, timer → `FAILED` and a `dead_letter_items` row (`source_type='TIMER'`) is created in one transaction.
- **Touchpoints:** `src/scheduler/scheduler.zig`, `src/dlq/store.zig`.
- **Test plan:** Force repeated firing failures; assert FAILED + DLQ entry after N.

---

## EPIC-4 — Identity, auth & rate limiting

### [ISS-401] Shared-store, globally-enforced rate limiter
- **Epic:** EPIC-4 · **Priority:** P1 · **Estimate:** M · **Labels:** api, rate-limit, multi-node
- **Depends on:** —
- **Context:** §6.1 step 5 — the in-memory per-node counter meant the real limit was ~N× the
  configured RPM in HA.
- **Acceptance criteria:**
  - [ ] Sliding-window counter in a shared store (`BPM_RATE_LIMIT_BACKEND` = `postgres`|`redis`), keyed `(tenant_id, principal)`.
  - [ ] `principal` = api_token id for local tokens, `(realm, sub)` for OIDC (see ISS-403).
  - [ ] Limit enforced globally across nodes; `429` + `Retry-After` on exceed.
  - [ ] Config validated at startup.
- **Touchpoints:** `src/api/middleware/*`, `src/config/*`.
- **Test plan:** Two-node test exceeding RPM in aggregate → throttled at the global limit.

### [ISS-402] OIDC token validation cache keying & revocation
- **Epic:** EPIC-4 · **Priority:** P1 · **Estimate:** M · **Labels:** identity, oidc
- **Depends on:** —
- **Context:** §12.1 — auth accepts OIDC access tokens, but they have no `api_tokens` row, so the
  LRU cache and `token_revoked` channel didn't cover them.
- **Acceptance criteria:**
  - [ ] OIDC tokens validated against the tenant realm issuer/JWKS; cached keyed `(realm, jti)` with TTL bounded by token `exp`.
  - [ ] Revocation via realm logout / `jti` denylist (not the `api_tokens` LISTEN/NOTIFY channel).
- **Touchpoints:** `src/api/middleware/auth.zig`, `src/oidc/*`.
- **Test plan:** Valid OIDC token cached then honoured; revoked `jti` rejected before `exp`.

### [ISS-403] Rate-limit keying for OIDC principals
- **Epic:** EPIC-4 · **Priority:** P2 · **Estimate:** S · **Labels:** identity, rate-limit
- **Depends on:** ISS-401, ISS-402
- **Context:** OIDC principals must be keyable in the shared limiter.
- **Acceptance criteria:**
  - [ ] OIDC requests rate-limited on `(tenant_id, realm, sub)`.
- **Touchpoints:** `src/api/middleware/*`.
- **Test plan:** OIDC principal hitting the limit is throttled independently of local tokens.

### [ISS-404] Codify `api_tokens.roles[]` as a point-in-time grant
- **Epic:** EPIC-4 · **Priority:** P2 · **Estimate:** S · **Labels:** identity, docs, tests
- **Depends on:** —
- **Context:** §6.7 — roles live in both `user_roles` and `api_tokens.roles[]`; authority was
  ambiguous. Resolution: token roles are fixed at issuance; `user_roles` is the user registry;
  changes don't retroactively alter issued tokens.
- **Acceptance criteria:**
  - [ ] Token validation reads roles from the token snapshot; a `user_roles` change does not alter an already-issued token's effective roles.
  - [ ] Behaviour covered by tests; doc note confirmed.
- **Touchpoints:** `src/identity/service.zig`, tests.
- **Test plan:** Issue token, change `user_roles`, assert token unchanged until re-issue/revoke.

---

## EPIC-5 — Multi-tenancy & SPT coexistence

### [ISS-501] Resolve read/write authority from `storage_mode`
- **Epic:** EPIC-5 · **Priority:** P0 · **Estimate:** M · **Labels:** multi-tenancy, routing
- **Depends on:** ISS-107
- **Context:** §11.3 — during SPT coexistence a tenant must be served by exactly one path; the
  resolved `storage_mode` pins `search_path` for the request.
- **Acceptance criteria:**
  - [ ] Tenant-context resolution (§11.2) reads `storage_mode` once and pins routing: `LEGACY_RLS` → `public` + RLS predicate; `SCHEMA` → tenant schema.
  - [ ] No request mixes read on one path and write on the other.
- **Touchpoints:** `src/api/middleware/*` (tenant context), `src/db/*`.
- **Test plan:** Same tenant under each mode → reads and writes hit the expected store only.

### [ISS-502] SPT cutover transaction flips `storage_mode` after verified copy (SPT-02)
- **Epic:** EPIC-5 · **Priority:** P0 · **Estimate:** L · **Labels:** multi-tenancy, migration
- **Depends on:** ISS-501
- **Context:** §11.3 / risk 7 — copy rows into the tenant schema, verify, then flip to `SCHEMA`
  inside the cutover transaction.
- **Acceptance criteria:**
  - [ ] `src/admin/tenant_migration.zig` copies + verifies row counts/checksums, then flips `storage_mode='SCHEMA'` atomically.
  - [ ] Failure rolls back leaving the tenant in `LEGACY_RLS` (safe).
  - [ ] Idempotent re-run is a no-op for already-migrated tenants.
- **Touchpoints:** `src/admin/tenant_migration.zig`.
- **Test plan:** Migrate a seeded legacy tenant; verify parity, post-cutover routing, and rollback on injected failure.

### [ISS-503] Remove legacy `tenant_id`/RLS predicates (SPT-03)
- **Epic:** EPIC-5 · **Priority:** P1 · **Estimate:** L · **Labels:** multi-tenancy, cleanup
- **Depends on:** ISS-502
- **Context:** §11.3 — after all tenants are `SCHEMA`, drop the `bpm.tenant_id` session var,
  `tenant_id` predicates, and RLS policies.
- **Acceptance criteria:**
  - [ ] Guard: only proceeds when no tenant remains in `LEGACY_RLS`.
  - [ ] RLS policies + `tenant_id` predicates removed; `GBL-077` teardown completed.
  - [ ] Regression suite green (ties to ISS-504).
- **Touchpoints:** `migrations/GBL-0xx_rls_removal.sql`, store modules.
- **Test plan:** Full regression on a schema-only DB; assert no references to `tenant_id`/RLS remain.

### [ISS-504] Reconcile §5 schema + per-tenant migration tracking (SPT-04)
- **Epic:** EPIC-5 · **Priority:** P2 · **Estimate:** M · **Labels:** multi-tenancy, docs, tests
- **Depends on:** ISS-503
- **Context:** §5 was annotated in v1.1 for per-tenant placement; confirm migration-state tracking
  is per schema and re-run the ADP-12 default-tenant regression.
- **Acceptance criteria:**
  - [ ] `public.schema_migrations` tracks `GBL-`; each `tenant_<slug>.schema_migrations` tracks per-tenant migrations.
  - [ ] Provisioning a new tenant records its per-tenant migration state in its own schema.
  - [ ] ADP-12 default-tenant regression updated and green.
- **Touchpoints:** `src/db/provisioning.zig`, test suite.
- **Test plan:** Provision tenant; assert correct migration ledger per schema; default-tenant regression passes.

---

## EPIC-6 — Performance & cutover quality

### [ISS-601] State snapshots for large-instance reconstruction
- **Epic:** EPIC-6 · **Priority:** P2 · **Estimate:** M · **Labels:** performance, engine
- **Depends on:** —
- **Context:** §7.4 — full replay meets NFR-04 at 10k events but degrades for very large
  instances; the prior "sequential heap scan" rationale was inaccurate and replay must also join
  overflow payloads.
- **Acceptance criteria:**
  - [ ] Periodic per-instance state snapshot; reconstruction folds events since the latest snapshot.
  - [ ] Replay joins `event_payloads_overflow` to reconstruct full payloads.
  - [ ] NFR-04 (≤5s for 10k events) verified by benchmark; large-instance path documented.
- **Touchpoints:** `src/engine/instance.zig` (reconstruction), `migrations` (snapshot table if added).
- **Test plan:** Benchmark 10k-event replay (< 5s) and a large-instance snapshot path.

### [ISS-602] CEL→`expr` differential test corpus (cutover gate)
- **Epic:** EPIC-6 · **Priority:** P1 · **Estimate:** L · **Labels:** engine, expr, risk
- **Depends on:** ISS-201
- **Context:** Open Question 1 — stored gateway conditions are CEL; cutting over to `src/expr/`
  must be semantically identical or definitions need re-validation/translation.
- **Acceptance criteria:**
  - [ ] Differential harness evaluates a corpus of real/stored gateway conditions on both `vendor/cel` and `src/expr/` and asserts identical results.
  - [ ] Divergences catalogued; cutover blocked until the corpus is green (or a documented translation step exists).
  - [ ] No production module imports `src/expr/` on the engine path until this gate passes.
- **Touchpoints:** `src/expr/*`, `vendor/cel`, `src/engine/transition.zig`, test harness.
- **Test plan:** Run the corpus in CI; report parity; gate the cutover PR on it.

---

## Execution order

Suggested waves (respecting `Depends on`):

1. **Wave 1 — schema foundation:** ISS-101, 102, 103, 104, 105, 106, 107.
2. **Wave 2 — engine & integrity:** ISS-201 → then 202, 203, 206, 207; ISS-204 (needs 103); ISS-205 (needs 106); ISS-208; ISS-303 (needs 101).
3. **Wave 3 — scheduler & auth:** ISS-301 → 302; ISS-401 → 402 → 403; ISS-404.
4. **Wave 4 — tenancy cutover:** ISS-501 → 502 → 503 → 504.
5. **Wave 5 — quality/perf:** ISS-601; ISS-602 (gate before any CEL→expr cutover).

## Coverage map (audit finding → issue)

| Audit # | Finding | Issue(s) |
|---|---|---|
| 1 | transition() returns only state | ISS-201 |
| 2 | timer FAILED vs CHECK | ISS-101, ISS-303 |
| 3 | group claim guard | ISS-102 |
| 4 | webhook at-least-once | ISS-106, ISS-205 |
| 5 | audit outside txn | ISS-103, ISS-204 |
| 6 | §5 tenant placement / SPT authority | ISS-107, ISS-501, ISS-502, ISS-504 |
| 7 | token multiplicity / join state | ISS-105, ISS-206 |
| 8 | token_hash bcrypt/SHA-256 | doc-only (fixed in v1.1); covered by ISS-404 tests |
| 9 | per-node rate limiter | ISS-401 |
| 10 | OIDC token keying | ISS-402, ISS-403 |
| 11 | completion on terminal instance | ISS-208 |
| 12 | partial variable merge | ISS-202 |
| 13 | retry convergence | ISS-207 |
| 14 | internal idempotency keys | ISS-203 |
| 15 | snapshot vs artifact hash | ISS-104 |
| 16 | scheduler lock redundancy | ISS-301 |
| 17 | startup sweep lock | ISS-302 |
| 18 | idempotency "global" wording | doc-only (v1.1) |
| 19 | audit_log.resource_id UUID | ISS-103 |
| 20 | role source-of-truth | ISS-404 |
| 21 | reconstruction perf wording | ISS-601 |
| 22 | §5 migration completeness | ISS-504 |
