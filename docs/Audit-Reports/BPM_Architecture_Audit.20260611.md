# BPM Platform — Architecture Audit

**Scope:** Correctness & internal consistency
**Subject document:** `BPM_Platform_Backend_Architecture.md` v1.0 (2026-06-11)
**Audit date:** 2026-06-11
**Method:** Static review of the architecture description only (no codebase access). Findings reference section/line concepts in the source document.

---

## Summary

The document is well structured and unusually honest about in-flight work (the CEL→`expr` cutover and the schema-per-tenant migration are clearly flagged). The kernel design — append-only events, pure transition function, single-transaction writes — is sound in principle.

However, the document accreted multi-tenancy, OIDC, and three extension runtimes on top of an original single-tenant kernel description, and several sections were **not reconciled** with each other. The most consequential issues are concrete contradictions between the §5 schema and the prose specs, and a few event-sourcing/concurrency claims that the described mechanisms do not actually guarantee.

Findings are rated:

- **High** — a described behavior is contradicted by the schema or cannot work as written; likely a real bug or correctness gap.
- **Medium** — internally inconsistent or under-specified in a way that will cause incorrect behavior in some path.
- **Low** — stale wording, terminology drift, or documentation completeness.

| # | Finding | Area | Severity |
|---|---|---|---|
| 1 | `transition()` signature returns only `InstanceState`, but the engine is specified to *emit events* | Event sourcing | High |
| 2 | Scheduler moves timers to status `FAILED`, which violates the `timers` CHECK constraint | Schema vs. design | High |
| 3 | Group/Role claim uses `assignee_ref IS NULL`, but `assignee_ref` is already set at activation | Schema vs. design | High |
| 4 | Webhook delivery claims at-least-once but uses an in-process, post-commit notification (no outbox) | Event sourcing | High |
| 5 | Audit log written as a post-handler middleware step, not inside the state-change transaction | Crash safety | High |
| 6 | `§5` core schema has no tenant scoping and is unreconciled with the schema-per-tenant model | Multi-tenancy | High |
| 7 | `active_tokens` as an array of node IDs cannot represent token multiplicity; parallel-join counter has no defined state | Concurrency | Medium |
| 8 | `token_hash` comment says "bcrypt/SHA-256", but lookup-by-hash only works with SHA-256 | Schema vs. design | Medium |
| 9 | Rate limiter is per-node in-memory; the stated per-token RPM is not enforced in HA | Concurrency | Medium |
| 10 | OIDC access tokens have no `token_id`; cache and rate-limit keying are undefined for them | Identity | Medium |
| 11 | Task completion is not guarded against terminal (ERROR/CANCELLED) instance status | Correctness | Medium |
| 12 | Partial variable merge emits overwrites *before* the `EXECUTION_ERROR`, leaving partial state | Event sourcing | Medium |
| 13 | `EXECUTION_ERROR` retry re-presents the same triggering event → may not converge | Correctness | Medium |
| 14 | Internal/cascade events need deterministic idempotency keys; derivation is unspecified | Event sourcing | Medium |
| 15 | Two reproducibility mechanisms (`definition_snapshot` JSONB + artifact hash) with no `artifact_hash` column | Consistency | Medium |
| 16 | Scheduler combines a whole-cycle advisory lock with `FOR UPDATE SKIP LOCKED` (redundant / contradictory model) | Concurrency | Low |
| 17 | Startup missed-timer sweep (SCH-05) has no stated lock → multi-node double-fire risk | Concurrency | Medium |
| 18 | `idempotency_key` commented "global scope" but is per-tenant under schema-per-tenant | Multi-tenancy | Low |
| 19 | `audit_log.resource_id UUID NOT NULL` can't represent text-keyed resources (roles, event types) | Schema | Low |
| 20 | `api_tokens.roles[]` duplicates `user_roles`; source of truth / staleness undefined | Identity | Low |
| 21 | State-reconstruction perf rationale ("sequential heap scan") is technically inaccurate | Performance claim | Low |
| 22 | §5 documents migrations 001–012 only; 027–037 and GBL-* migrations are absent | Documentation | Low |

---

## High-severity findings

### 1. The pure transition function cannot emit the events the design depends on

`§6.4` gives the signature:

```zig
pub fn transition(alloc, snapshot, state, event) TransitionError!InstanceState
```

It returns **only** the new `InstanceState`. Yet throughout the document the engine is described as *emitting events*: the variable-collision policy (EE-09) says "emit `VARIABLE_OVERWRITTEN` event" and "emit `EXECUTION_ERROR` event"; the transition-rules table and §4.1/§4.2 have the engine producing `TASK_ACTIVATED`, `INSTANCE_COMPLETED`, etc.

A function returning only final state cannot communicate those events to the orchestrator that persists them. `VARIABLE_OVERWRITTEN` (with old *and* new values) and `EXECUTION_ERROR` in particular cannot be reliably reconstructed by diffing the returned state. Either the signature is wrong (it should return `{state, []Event}`) or the prose is wrong. As written they contradict. This is foundational because every write path in §4 and §7.1 depends on the engine handing events to the transaction.

**Recommendation:** Make the return type explicit, e.g. `TransitionError!TransitionResult{ state, emitted_events }`, and update §6.4 to match the emit-language used elsewhere.

### 2. Scheduler sets a timer status the schema forbids

`§6.6` failure handling: "the timer row is moved to status `FAILED` and a DLQ entry is created."

The `timers` table (migration 007) declares `status TEXT NOT NULL CHECK (status IN ('PENDING','FIRED','CANCELLED'))`. `FAILED` is not in the allowed set, so that UPDATE will be rejected by the CHECK constraint at runtime.

**Recommendation:** Add `'FAILED'` to the constraint (and to migration 007), or reuse an existing status. Whichever, the schema and §6.6 must agree.

### 3. Group/Role task claim guard contradicts how `assignee_ref` is populated

`§6.5`: `activate(instance_id, node_id, assignee)` inserts the task with its assignee; for a GROUP/ROLE task that means `assignee_type='GROUP'`, `assignee_ref=<group>`. But the claim semantics state the optimistic guard is "compare `assignee_ref IS NULL`."

For a group task, `assignee_ref` is **not** NULL — it holds the group. So the `IS NULL` check can never succeed, and there is no separate column to record the individual who claimed it. The `tasks` schema has `assignee_type`, `assignee_ref`, `completed_by` but **no `claimed_by` / owner** column distinct from the group assignment.

**Recommendation:** Add a distinct claim column (e.g. `claimed_by UUID`) and make the optimistic compare-and-set target it (`claimed_by IS NULL`), keeping `assignee_ref` as the group/role pool.

### 4. Webhooks claim at-least-once but the delivery trigger is best-effort

`§6.9` headlines "At-least-once outbound HTTP delivery," but step 1 says the dispatcher "receives a notification (passed directly in-process, same goroutine/thread, not via DB polling)" *after* the committing transaction (§4.1/§4.2 show webhook dispatch as a post-transaction async step).

If the process crashes after `COMMIT` but before the dispatcher enqueues/persists the delivery, the event is committed but the webhook is never produced — that is **at-most-once**, not at-least-once. The `webhook_deliveries` table (§6.9) survives restarts only for deliveries that were already written; it doesn't help events whose delivery record was never created. There is no transactional outbox tying "event committed" to "delivery enqueued."

**Recommendation:** Use a transactional outbox — write the pending delivery row inside the same transaction as the event, and have the worker pool poll/drain it. Then in-process notification becomes a latency optimization rather than the delivery guarantee.

### 5. Audit logging is outside the state-change transaction

`§7.1` asserts the core invariant: every write is a *single atomic transaction* with "no multi-step sequences that span transaction boundaries." But `§6.1`/`§6.8` place the audit writer at **step 9 of the HTTP pipeline, after the route handler (step 8)** has already returned. That makes the `audit_log` insert a separate transaction from the state change it records.

Consequences: (a) a crash between the handler commit and the audit write loses the audit row for a change that *did* happen; (b) capturing `before_state`/`after_state` from middleware after the handler has committed is racy. Either way the audit trail is not transactionally consistent with the events it audits — a meaningful gap for a platform whose selling point is a "tamper-evident, replayable audit trail."

**Recommendation:** Write `audit_log` inside the handler's transaction (or derive audit purely from the event log, which is already the tamper-evident ground truth, and drop the separate middleware write).

### 6. The §5 schema was never reconciled with multi-tenancy

`§5` presents `events`, `definitions`, `instances`, `tasks`, `webhook_subscriptions`, etc. with **no tenant column and no schema-placement note**. `§11.1` states these same business tables live per tenant in `tenant_<slug>` schemas, while the *legacy* model (ADP) used a `tenant_id` column + RLS. The §5 schema matches neither cleanly: it has no `tenant_id` (so it can't be the legacy RLS model it claims coexists today) and no annotation of which migrations are `GBL-`/`public` vs per-tenant.

Because SPT-02/03/04 are still PENDING (both paths coexist), the document also never specifies, during coexistence, **which path the engine reads and writes** — if writes land in a tenant schema while reads still honor legacy `tenant_id`/RLS predicates on `public`, the two views can diverge. This is the highest *operational* correctness risk and it's under-specified beyond "safety net."

**Recommendation:** Update §5 to annotate each table as `public`/`GBL-` vs per-tenant, show the actual tenant key for the legacy path, and document the authoritative read/write path during SPT coexistence.

---

## Medium-severity findings

### 7. Token representation loses multiplicity; parallel-join state is undefined

`InstanceState.active_tokens` is `[]NodeId` and `instances.active_tokens` is a JSONB array of node IDs. A set/array of node IDs cannot represent **two tokens on the same node** (legal during loops or when parallel branches reconverge) and gives tokens no identity. Separately, the PARALLEL_GATEWAY join (§6.4) needs a per-join counter and an "incoming-active-branch count," but `InstanceState` carries no field for join counters. Since state must be deterministically rebuildable from the event log, any join bookkeeping that isn't in the persisted/replayed state is a correctness hole.

**Recommendation:** Model tokens as a multiset with stable token IDs, and make join counters part of `InstanceState` so replay reproduces them exactly.

### 8. `token_hash` comment conflates bcrypt and SHA-256

Migration 008 comments `token_hash` as "bcrypt/SHA-256 hash," but §6.7 validates by `SELECT … WHERE token_hash = $1` after SHA-256. A salted bcrypt hash is non-deterministic and cannot be looked up by equality, so bcrypt is incompatible with the described hot path. (SHA-256 of a 32-byte random token is acceptable here precisely because the token is high-entropy — but the comment should not imply bcrypt is an option.)

### 9. Rate limiting is not global in the HA topology

`§6.1` step 5 keys the limiter on `token_id` **in-memory**, and `§8.2` states nodes share "no shared in-process state." With N nodes behind the load balancer, the effective limit becomes ~N × `BPM_RATE_LIMIT_RPM`, and the per-token RPM contract (API-10) is not actually enforced. It's also not tenant-aware.

**Recommendation:** Either document the limit as per-node best-effort, or move counters to a shared store (PostgreSQL/Redis) for a true global limit.

### 10. OIDC tokens are unspecified in the token-keyed hot paths

`§12.1` says auth accepts both local bearer tokens and OIDC access tokens, but the LRU cache (keyed on the `api_tokens` row) and the rate limiter (keyed on `token_id`) assume a local token. OIDC principals have no `token_id`. How they are cached, rate-limited, and revoked (the `token_revoked` LISTEN/NOTIFY channel is about `api_tokens`) is undefined.

### 11. No guard on completing tasks of terminal instances

When an instance enters ERROR (frozen) or CANCELLED, its PENDING tasks are not transitioned — `tasks.status` only has `PENDING/COMPLETED/CANCELLED` and nothing in the flow cancels them. A worker could still `POST /tasks/:id/complete` against a frozen/cancelled instance. The completion path needs an explicit guard rejecting completion when the parent instance is not ACTIVE.

### 12. Partial variable merge persists overwrites before the error

The EE-09 loop (§6.4) emits `VARIABLE_OVERWRITTEN` for keys processed before it hits an invalid key, then emits `EXECUTION_ERROR` and breaks. If all emitted events are committed together, the instance ends in ERROR but with some variables already overwritten — a partially applied merge. On retry, those keys may be overwritten again. The intended atomicity of a task's variable merge (all-or-nothing vs. partial) should be defined explicitly.

### 13. ERROR-retry may not converge

`§6.4` EE-10 retry "re-presents the last triggering event to the engine." If the error is deterministic in that event (e.g., an unparseable/false-everywhere gateway, a schema-invalid variable), re-presenting the identical event reproduces the identical error. Without a way to also change the definition/data, retry loops without progress. Worth specifying what an operator can change between retries, or supporting "retry with corrected input."

### 14. Idempotency keys for engine-generated events are unspecified

`events.idempotency_key` is `UNIQUE NOT NULL` (§7.3 calls it the single dedup mechanism). Client-submitted commands can carry a key, but cascade events the engine emits (`TASK_ACTIVATED`, `TIMER_FIRED`, `INSTANCE_COMPLETED`, `VARIABLE_OVERWRITTEN`) also need keys, and they must be **deterministic** so replays/retries don't create duplicates or spuriously collide. The derivation rule (e.g., hash of instance_id + source event seq + node) isn't stated.

### 15. Two overlapping reproducibility mechanisms

`§6.3`/PD-08 copies the full graph into `instances.definition_snapshot`; `§15.1`/ADP-05 says instances "reference the artifact hash they executed against." The `instances` table (migration 005) has `definition_snapshot` but **no `artifact_hash` column**, so the §15 mechanism isn't represented in the schema, and the relationship between the two (is the snapshot authoritative, or the hash?) is unclear. Storing both also duplicates data.

### 17. Startup missed-timer sweep lacks the concurrency guard

`§6.6` SCH-05 runs an unconditional sweep of all due timers on startup, "before entering the poll loop." The poll loop is guarded by `pg_try_advisory_lock`, but the startup sweep is not described as taking that lock. If several nodes (re)start together — common after a rolling deploy — they can each sweep the same due timers concurrently. `FOR UPDATE SKIP LOCKED` mitigates within a single statement but the sweep should still hold the scheduler advisory lock to match the steady-state model.

---

## Low-severity / consistency notes

**16 — Scheduler locking model is over-determined.** §4.3/§6.6 hold a whole-cycle `pg_try_advisory_lock` (so only one node runs the cycle) *and* use `FOR UPDATE SKIP LOCKED` (the pattern for many concurrent workers). Under the single-lock-holder model, SKIP LOCKED is redundant. Pick one: either many nodes draining a shared queue via SKIP LOCKED (no global lock), or one leader per cycle (no need for SKIP LOCKED). The current §8.2 claim "exactly one node fires timers per cycle" also makes the scheduler a single-node bottleneck worth calling out.

**18 — "global scope" idempotency wording is stale.** `events.idempotency_key` comment says "global scope," but under schema-per-tenant each tenant has its own `events` table, so uniqueness (and the `sequence_num` "global ordering") is per-tenant. Functionally fine; the comments should say per-tenant. Same applies to `idx_events_global_seq` "global stream."

**19 — `audit_log.resource_id UUID NOT NULL` is too rigid.** Several resources are text-keyed (`roles.role_name`, `event_type_registry.event_type`, definitions by name). Auditing changes to them can't supply a UUID. Consider `resource_id TEXT` or a nullable UUID + text key.

**20 — Role source-of-truth duplication.** Roles live both in `user_roles` and denormalized into `api_tokens.roles[]` (returned directly at validation). A role change won't reflect in existing tokens until expiry, and the document doesn't state which is authoritative. Define it (and whether token roles are a deliberate point-in-time grant).

**21 — Reconstruction performance rationale is inaccurate.** §7.4 says the `(instance_id, sequence_num)` index "guarantees a sequential heap scan." An index scan over that key yields ordered access but generally **random heap fetches**, not a sequential scan (unless index-only or the table is clustered). The 10k-events-in-5s target is still easily met; the stated reason is just wrong. Also note replay must JOIN `event_payloads_overflow` for large payloads — the reconstruction SELECT shown omits that.

**22 — §5 omits the current migration set.** §5 documents migrations 001–012, but the stage plan and §11–§13 reference 027–037, 069–070, and several `GBL-*` migrations. §5 should either include them or explicitly scope itself to the kernel and point to the per-tenant/GBL migration catalog.

---

## Things that are right (worth preserving)

- Append-only `events` as ground truth with derived, rebuildable projections is a clean event-sourcing core, and §7.1's single-transaction invariant is the correct backbone (the audit and webhook gaps above are deviations *from* it, not flaws in it).
- The `idempotency_key` `ON CONFLICT DO NOTHING RETURNING` dedup (§7.3) is genuinely lock-free and concurrency-safe for client-supplied keys.
- Bootstrap-token fail-closed on `BPM_ENV=production` (process exits at startup) is a good safe default.
- Issuing the plaintext API token once and storing only its hash (§6.7) is correct.
- The document's own Open Questions (§10) already track the two biggest live risks (CEL→`expr` cutover, SPT migration) accurately and honestly — including that no production module imports `src/expr/` yet. The CEL→`expr` cutover additionally carries an unflagged **semantic-equivalence risk**: stored gateway expressions are CEL, and the replacement engine must evaluate them identically or definitions need re-validation/translation.

---

## Suggested priority order

1. Resolve the schema-vs-design contradictions that fail at runtime: timer `FAILED` status (#2), group-claim column (#3).
2. Fix the event-sourcing integrity gaps: transition return type (#1), webhook outbox (#4), audit-in-transaction (#5).
3. Specify multi-tenant read/write authority during SPT coexistence and reconcile §5 (#6, #18, #22).
4. Close the concurrency/identity gaps: token model & join state (#7), global rate limiting (#9), OIDC token keying (#10), startup sweep lock (#17).
5. Tidy the remaining consistency/documentation items.
