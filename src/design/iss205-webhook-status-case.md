# ISS-0205 — webhook_deliveries.status Case Alignment — Design

**Issue:** GitHub #400 / ISS-0205  
**Severity:** BLOCKER  
**Scope:** `src/webhook/dispatcher.zig` (single source file, 8 SQL literals)  
**Classification:** Type E (application/schema contract drift — novel cross-cut)  
**Related migration:** [`migrations/085_iss106_webhook_deliveries_outbox.sql`](../../migrations/085_iss106_webhook_deliveries_outbox.sql)  
**Related diagnosis:** `handoffs/WF03-gh400-20260804/step-1-issue-fixer-diagnosis.json`  
**Branch:** `feature/WF03-gh400-20260804`  
**Hard rule acknowledged:** Zero implementation code in this artefact. Zig snippets that quote the *current* SQL are acceptable as evidence; new Zig code is **not** required and **must not** be authored here.

---

## Module Purpose

`src/webhook/dispatcher.zig` is the outbound webhook delivery worker. It writes outbox rows to `webhook_deliveries` (an INSERT path), claims due rows from it (three SELECT worker-queries), and updates terminal status when a delivery succeeds, exhausts retries, or fails non-terminally.

Migration 085 (`085_iss106_webhook_deliveries_outbox.sql`) installed a CHECK constraint that constrains `webhook_deliveries.status` to the UPPERCASE domain:

```
{PENDING, DELIVERED, FAILED, RETRYING}
```

but `dispatcher.zig` writes **lowercase** literals (`'pending'`, `'success'`, `'failed'`, `'exhausted'`) at 8 SQL sites. Two INSERTs violate the constraint at runtime (`23514 — check constraint violated`); six other sites misalign with the canonical domain (worker SELECTs would silently miss already-uppercase rows; UPDATE terminal-status writes would be rejected on the success/exhausted paths because `'success'` and `'exhausted'` are not in the domain at all).

This artefact enumerates the contract mapping and the exact 8 SQL edits that realign the application to the contract migration 085 already defines. No schema change is required.

---

## Public Interface

The module's public surface (`src/webhook/dispatcher.zig`) is **unchanged by this fix**. Only the embedded SQL string literals change. The function signatures that wrap these SQL sites remain:

- `insertWebhookDeliveriesInTx(subs, event_id, event_type, instance_id, payload_json, trace_id) PersistenceError!u32` — INSERT path, site @ line 88.
- `enqueueDeliveryAttempts(subs, event_type, envelope) PersistenceError!u32` — INSERT path, site @ line 172.
- `dispatchDueWebhookAttempts(now, limit) DispatchError![]DeliveryResult` — SELECT claim path (no filter by tenant), site @ line 207.
- `dispatchDueWebhookAttemptsForTrace(trace_id, now, limit) DispatchError![]DeliveryResult` — SELECT claim path filtered by trace_id, site @ line 251.
- `dispatchDueWebhookAttemptsForSubscription(sub_id, now, limit) DispatchError![]DeliveryResult` — SELECT claim path filtered by subscription, site @ line 295.
- `dispatchOne(attempt) DispatchError!DeliveryOutcome` — UPDATE terminal status; sites @ lines 371 (success), 406 (exhausted), 440 (non-exhausted failure).

No new exports. No new parameters. No allocator changes. No transaction-shape changes.

---

## Error Taxonomy

Existing error sets declared in the module are unchanged. This fix introduces **no new error cases**. The 8 SQL edits convert previously-violating INSERTs into compliant INSERTs (no new `error.PersistenceFailed` outcomes from a status-violation path); previously-mismatched SELECTs now match rows the worker expects to match (delivering attempted dispatches instead of returning an empty result set).

| Error variant | HTTP status (if surfaced) | Status before this fix | Status after this fix |
|---|---|---|---|
| `PersistenceFailed` (CHECK violation at INSERT) | 500 | triggered on every outbox write | **never** triggered by the 8 status sites |
| `EmptyClaim` (no due rows match) | n/a (worker) | silently missed UPPERCASE rows | matches due UPPERCASE rows as designed |
| `PersistenceFailed` (UPDATE terminal status CHECK violation) | 500 | triggered on every success/exhausted UPDATE | **never** triggered by the 8 status sites |

---

## Context

GH #400 reports that webhook deliveries occasionally fail with a `23514 — check constraint "webhook_deliveries_status_check" violated` PostgreSQL error. The 3 failing integration tests at `tests/integration/iss205_webhook_outbox_test.zig` (TC1, TC2, TC3) all fail at the same SQL site: `insertWebhookDeliveriesInTx` writes `'pending'` while migration 085 requires `'PENDING'`. Migration 085 is already applied (Step 4 installed the CHECK) and its Step 3 reconciliation has already remapped historical rows to UPPERCASE. The application is the out-of-contract side, not the schema.

The 8 SQL sites enumerated below are the entire scope of the production fix. No regression tests need to be added: the existing ISS-205 test suite already exercises the affected INSERT (TC1), enqueueDeliveryAttempts (TC2), and successful dispatch UPDATE (TC3). Once the case is corrected, these tests go green.

---

## Contract — Status Mapping

The application writes 4 distinct lowercase literals across the 8 sites; migration 085 accepts 4 UPPERCASE values. The mapping below is the binding contract between this fix and the schema.

| source_lc (currently in dispatcher.zig) | CHECK value (migration 085 domain) | rationale |
|---|---|---|
| `'pending'`   | `'PENDING'`   | direct remap; the row is unprocessed and the worker is about to claim it |
| `'success'`   | `'DELIVERED'` | rename — CHECK has no `'success'`; migration Step 3 already remaps `success → DELIVERED` for legacy rows, so the application must agree |
| `'failed'`    | `'FAILED'`    | direct remap; in-flight retryable failure |
| `'exhausted'` | `'FAILED'`    | migration Step 3 also remaps `exhausted → FAILED`; the row has hit `max_attempts` and the worker will not retry it, so `'FAILED'` is the right terminal state — consistent with migration reconciliation |

`RETRYING` is part of the CHECK domain but **is never written** by `dispatcher.zig`. That is correct today (no design flaw), but the contract leaves room for a future path to set `'RETRYING'` if we ever want a distinct in-flight-retry state. We do not introduce that here.

`succeeded` is **not** in the domain; the dispatcher never writes it; no future-proofing required.

---

## Design — Exact SQL Edits

All 8 edits are inside `src/webhook/dispatcher.zig`. Each is a SQL string literal; the surrounding Zig structure (prepared-statement parameter binding, transaction shape, error mapping) is unchanged.

| Line | Site | Before | After | Reason |
|---|---|---|---|---|
| 88   | `insertWebhookDeliveriesInTx` INSERT | `'pending'` | `'PENDING'` | initial outbox row — TC1 of `iss205_webhook_outbox_test.zig` fails here today |
| 172  | `enqueueDeliveryAttempts` INSERT | `'pending'` | `'PENDING'` | initial outbox row for the second dispatcher INSERT path |
| 207  | `dispatchDueWebhookAttempts` SELECT | `d.status IN ('pending', 'failed')` | `d.status IN ('PENDING', 'FAILED')` | worker must match UPPERCASE domain; before this edit the worker silently claims zero rows after migration 085 has remapped everything to UPPERCASE |
| 251  | `dispatchDueWebhookAttemptsForTrace` SELECT | same | same | trace-filtered worker; same rationale as line 207 |
| 295  | `dispatchDueWebhookAttemptsForSubscription` SELECT | same | same | subscription-filtered worker; same rationale as line 207 |
| 371  | `dispatchOne` success path UPDATE | `SET status = 'success'` | `SET status = 'DELIVERED'` | terminal success state — `'success'` is not in the CHECK domain |
| 406  | `dispatchOne` exhausted path UPDATE | `SET status = 'exhausted'` | `SET status = 'FAILED'` | exhausted = terminal `FAILED` (worker does not retry; consistent with migration Step 3's `exhausted → FAILED` remap) |
| 440  | `dispatchOne` non-exhausted failure UPDATE | `SET status = 'failed'` | `SET status = 'FAILED'` | in-flight retryable failure — direct case correction |

Each edit is a single-quoted literal change inside an existing `\\...` Zig multiline string. No `$N` placeholder, no transaction wrapper, no error-mapping function changes. BACKEND-DEV will produce a commit whose diff is **8 lines changed, 0 lines added, 0 lines deleted**.

---

## Out of Scope

The following SQL sites in `src/webhook/dispatcher.zig` **look related but must NOT be touched**:

- **Line 419:** `SET status = 'PAUSED'` inside an UPDATE against `webhook_subscriptions`. Different table (`webhook_subscriptions`, not `webhook_deliveries`); its CHECK domain is the subscription-status enum, not the delivery-status enum; already UPPERCASE; no change.
- **Lines 68, 154, 207 (join), 251 (join), 297:** `JOIN webhook_subscriptions s ON s.id = d.subscription_id` and the `WHERE s.status = 'ACTIVE'` clauses on `webhook_subscriptions`. Different table; already UPPERCASE; no change.

Touching these would be a correctness regression (subscription CHECK would be violated) and is forbidden.

Likewise, the following are **not part of this fix** and remain unchanged:

- The CHECK constraint itself (`webhook_deliveries_status_check`) — already correct per migration 085.
- The legacy-row reconciliation in migration Step 3 — already idempotent.
- Test fixtures in `tests/integration/iss205_*` — already exercise the affected paths; their assumed uppercase is now true at the application layer.
- `tests/integration/ext02_*` — see Verification.
- `tests/integration/iss106_*` — see Verification.
- `tests/integration/iss601_*` — see Verification (does not touch `webhook_deliveries`).

No migration file is created or modified by this workflow.

---

## Verification

Which integration tests turn green and why:

| Test target | Expected verdict after fix | Why |
|---|---|---|
| `zig build test-integration-iss205` | **3/3 PASS** (TC1, TC2, TC3) | TC1 calls `insertWebhookDeliveriesInTx` → line 88 INSERT `'PENDING'`. TC2 calls `enqueueDeliveryAttempts` → line 172 INSERT `'PENDING'`. TC3 calls `dispatchOne` on a synthesized row and asserts the success UPDATE transition → line 371 `SET status = 'DELIVERED'`. All three sites are in the 8-edit table. |
| `zig build test-integration-iss106` | unchanged (PASS) | This test was authored against migration 085 itself; it verifies the CHECK constraint accepts `'PENDING' / 'DELIVERED' / 'FAILED' / 'RETRYING'` and rejects lowercase. Case-altering the application does not affect the CHECK. No regression. |
| `zig build test-integration-ext02` | unchanged (PASS) — possibly already green, possibly pending ISS-205 case | The ext02 test suite does exercise `enqueueDeliveryAttempts` and the `dispatchOne` terminal-success UPDATE; once those sites flip to UPPERCASE it remains green. Its old assertions used lowercase fixtures — re-baselining its fixtures is part of TEST-DESIGNER's downstream handoff (Step-1 diagnosis `ISS-0205-VERIFY-02`), not this Step-2 design. |
| `zig build test-integration-iss601` | unchanged (PASS, unrelated) | Per Step-1 verification note (`ISS-0205-VERIFY-01`), this test file does not reference `webhook_deliveries` or `webhook_subscriptions`; no status-literal dependency exists. No regression. |

The downstream validation agent (TEST-RUNNER) will run all four suites as a regression matrix. A green run implies that (a) the 8 edits produce no compilation error in `dispatcher.zig`, (b) runtime INSERTs/UPDATEs no longer raise `23514`, (c) the worker SELECTs find what they are supposed to find, and (d) unrelated suites are stable.

---

## Migration

**None.** The CHECK constraint and the Step-3 remap are already installed by migration 085 in the live environment. This design aligns the application to the existing contract — it does **not** alter the contract. No new migration file is created or modified.

If a future migration is needed to widen the domain (e.g. add `'RETRYING'` as a written state), that migration will be its own artefact. It is out of scope for GH #400.

---

## Risk

**Low.** This is a pure case-correction in 8 SQL string literals.

- No behavioural change in the success/failure path.
- No new code path, no new transaction, no new error variant.
- No scheduler/timer/retention interaction. The `next_attempt_at`-based claim (`idx_wd_status_next_attempt`) is unaffected because the worker now matches the rows actually written.
- The change is reversible by reverting one commit; each literal is independent of the others at the source level (Zig has no compile-time dependency between the 8 strings).
- Functional divergence from migration 085 would be visible immediately as new `23514` errors in test output and as a `zig build test-integration-iss205` regression — both are caught by the gate suite.
- The only non-zero behavioural impact is: previously, after migration 085 was applied, **the worker was claiming zero rows** because its SELECT clauses looked for lowercase `'pending'`/`'failed'` while every row in the table was already UPPERCASE. After the fix, the worker resumes claiming and dispatching, which is the design intent. This is the bug fix, not a regression risk.

If production traffic was masking the issue (deliveries silently dropped without 23514 because the SELECT missed), the post-fix rollout may surface backlog activity as the worker drains. That is desirable and matches GH #400's intent.

---

## Open Questions

- None for GH #400. The Step-1 diagnosis flagged three MINOR verification notes; none blocks this design:
  - `ISS-0205-VERIFY-01` (iss601 unaffected) — closed by context above.
  - `ISS-0205-VERIFY-02` (EXT-02 fixture re-baselining is downstream TEST-DESIGNER work) — closed by Step-3 / TEST-DESIGNER handoff, **not** by this Step-2 design.
  - `ISS-0205-KB-01` (prior ISS-0118/GitHub #381 is OPEN and records the same drift, no reusable resolved strategy) — closed by being filed against GH #400 instead.
