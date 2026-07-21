# Audit Validation Review — Architecture & Feature Audits

**Type:** Independent validation of prior audit reports + fresh recommendations
**Subjects validated:**
1. `BPM_Architecture_Audit.20260611.md` (correctness audit of the backend architecture doc)
2. `BPM_vs_ASCOA-GO_Gap_Analysis.20260611.md` (v2 comparative analysis)
3. `Borrowing_From_ASCOA-GO.20260626.md` (borrowing analysis)

**Validation date:** 2026-07-02
**Method:** Every checkable claim in the three audits was verified against the current source tree (`src/`, `migrations/`, `docs/`, `.github/instructions/`) and `docs/status/requirement_status.yaml` (309 requirements: 301 RELEASED, 4 IMPLEMENTED, 1 TESTED, 3 PENDING). No runtime execution.

---

## 1. Overall verdict

All three audits are **valid, internally consistent, and demonstrably effective** — this is a rare case where audit findings can be traced finding-by-finding into shipped fixes. The 2026-06-11 architecture audit's findings were resolved almost in full within days (architecture doc v1.1 changelog explicitly enumerates them; the code fixes are verifiable as ISS-1xx/2xx/3xx requirements and migrations 081–093, GBL-081–099). The gap analysis's recommendations became the `src/entities`, `src/effects`, `src/secrets`, and quota subsystems. The borrowing analysis was operationalized as `docs/addon-2` (BRW-* requirements) on the same date.

Three weeks later, the audits are therefore **largely stale as descriptions of current state** — which is the correct outcome for an audit. What remains open is listed in §4, and this validation surfaced **one new critical finding the audits asked to be verified but never was** (§5.1).

---

## 2. Validation of the Architecture Audit (2026-06-11)

Finding-by-finding verification against the current tree:

| # | Finding (severity) | Current status | Evidence |
|---|---|---|---|
| 1 | `transition()` can't emit events (High) | **FIXED** | `src/engine/transition.zig` returns `TransitionResult{ state, emitted_events }` (ISS-201) |
| 2 | Timer `FAILED` violates CHECK (High) | **FIXED** | `migrations/081_iss101_timers_failed_status.sql` |
| 3 | Group-claim guard vs `assignee_ref` (High) | **FIXED** | `migrations/082_iss102_tasks_claimed_by.sql`; claim CAS on `claimed_by` |
| 4 | Webhook at-least-once without outbox (High) | **FIXED** | `migrations/085_iss106_webhook_deliveries_outbox.sql`, `src/design/iss205_webhook_transactional_outbox.md` |
| 5 | Audit log outside the transaction (High) | **FIXED** | In-transaction tamper-evident chain: migrations 035, 051, 057, 059 |
| 6 | §5 schema unreconciled with multi-tenancy; SPT coexistence authority undefined (High) | **PARTIALLY OPEN** | ISS-501–504 (storage_mode authority, cutover transaction, RLS removal, migration tracking) are IMPLEMENTED but not RELEASED; **SPT-02/03/04 remain PENDING** — the dual-path coexistence risk still exists in production terms |
| 7 | Token multiplicity / join counters (Med) | **FIXED** | `src/engine/instance.zig`: `token_id` UUIDs (ISS-105), `join_counters` in persisted state |
| 9 | Rate limiter per-node only (Med) | **FIXED** | `migrations/GBL-083_rate_limit_buckets.sql` (shared-store buckets) |
| 11 | No terminal-instance guard on task completion (Med) | **FIXED** | ISS-208 race-safe guard in `src/api/routes/tasks.zig` |
| 12 | Partial variable merge (Med) | **FIXED (TESTED, not RELEASED)** | ISS-202 two-phase all-or-nothing merge, tested 2026-06-12 |
| 17 | Startup sweep without lock (Med) | **FIXED** | ISS-302 session-level advisory lock in `src/scheduler/scheduler.zig` |
| 19 | `audit_log.resource_id UUID` too rigid (Low) | **FIXED** | `GBL-081`/`GBL-082` migrate to TEXT (ISS-103) |
| 8, 10, 13–16, 18, 20–22 | Doc-level findings | **RESOLVED in doc v1.1** | `BPM_Platform_Backend_Architecture.20260611.md` changelog explicitly addresses timers/claimed_by/resource_id/artifact_hash/token_hash and the spec-language findings |

**Assessment of the audit itself:** methodology (static review, explicit severity rubric, "things that are right" section, priority ordering) was sound; severity ratings were proportionate; no finding proved false. The one imperfection: it audited doc v1.0 the same day v1.1 was produced, so the report never recorded which findings v1.1 already absorbed — traceability had to be reconstructed here.

## 3. Validation of the two comparative audits

**Gap Analysis v2 (2026-06-11).** Its self-retraction of v1 was correct — the `addon-1` platform scope, L4 form engine, SPA, and agent pipeline all exist. Its three "real differences" were accurate at the time and all three were acted on: dynamic entities as events + typed projections (`src/entities/`: `events.zig`, `projector.zig`, `commands.zig` — matches the recommended model, not indexed JSONB), async effects with result re-entry (`src/effects/`: worker, queue, EFFECT_EMITTED → EFFECT_COMPLETED re-entry, `GBL-097` effects outbox), and the operational specs (quota model `src/config/quota_policy.zig` + `src/api/middleware/quota_enforcement.zig`; sandbox threat model `docs/sandbox_threat_model.md` EXP-701 dated 2026-06-14; `instance_waits` migration 093). Verdict: **valid; recommendations substantially implemented**.

**Borrowing analysis (2026-06-26).** Accurate on what My-Fab already had, and its "verify-then-extend" step 1 was properly executed in `docs/addon-2/01-architecture-addition.md` §2. Its borrow list became the BRW-* requirement set (`docs/addon-2/02-functional-requirements.md`: MOB-1..8, ENG-1..5, EFX-1, SAGA-1, SEC-1, OPS-1..4). Modular agent instructions partially adopted (`.github/instructions/` now holds backend-dev, frontend-dev, orchestrator files). Verdict: **valid; operationalized but not yet executed** — see §4.2.

One caveat on both: they asked to "verify `src/secrets` implements envelope encryption rather than env reads" and marked it carried-over/high-priority — but no subsequent artefact records that verification. This validation performed it; see §5.1.

---

## 4. What remains open from the audits (validated as still-open today)

### 4.1 SPT cutover is the oldest unresolved High finding
SPT-02/03/04 (data migration into tenant schemas, RLS removal, tracking reconciliation) are still PENDING, and the machinery built to execute them (ISS-501–504) sits at IMPLEMENTED without test/release. Until the cutover runs and the legacy path is retired, finding #6 of the architecture audit — the dual-path read/write divergence risk — remains live. This is the single most consequential leftover.

### 4.2 The addon-2 (BRW) backlog is specified but untracked
`requirement_status.yaml` contains **zero BRW-* entries**. The addon-2 requirements exist only in the addon document, outside the status machinery that drives the WF pipelines, stage gates, and release decisions. Nothing from the borrowing audit's build list (mobile tier, retry-policy formalization, compensation constructs, saga runner, HMAC key rotation, scale anchor) has started.

### 4.3 Specific still-missing items (verified absent)
Engine-level compensation/error-boundary constructs — no implementation in `src/engine/` (only design notes: `src/design/compensation-restore-reconciliation.md`); compensation remains hand-modeled per process. Generic saga runner — no module; only the onboarding saga in `src/identity/onboarding.zig`. Mobile tier — no `apps/` directory, no mobile architecture doc. Stated scale anchor — still absent from the architecture doc (BRW-OPS-1 correctly lists it as a MUST doc item).

### 4.4 Status hygiene
ISS-202 has been TESTED since 2026-06-12 and ISS-501–504 IMPLEMENTED since 2026-06-12 with no movement in three weeks — either the runs stalled or the status file wasn't updated. Both possibilities warrant a look.

---

## 5. New findings from this validation

### 5.1 CRITICAL — Secrets "envelope encryption" is a placeholder that stores plaintext
`src/secrets/crypto.zig`:

- `encrypt()` sets `ciphertext = dupe(plaintext)` — the secret value is stored **unencrypted**. The nonce, auth tag, and "wrapped data key" are **random bytes with no cryptographic relationship** to the payload; `master_key` is discarded (`_ = master_key`). The envelope metadata nonetheless declares `aes_256_gcm` / `aes_kw_256`.
- `decrypt()` ignores the master key and returns the stored "ciphertext" directly, so nothing would notice the absence of real crypto.

A code comment acknowledges this ("reserve true AEAD wrapping for a follow-up hardening step"), but: (a) both comparative audits conditioned the effects/connector expansion on real secrets discipline being in place *first*, and the async-effects subsystem has since shipped; (b) the envelope metadata actively misrepresents the at-rest protection, which will mislead any future audit or compliance review; (c) no BRW/ISS requirement tracks the hardening follow-up — BRW-SEC-1 covers HMAC key rotation, not AEAD completion. **Recommendation: raise a BLOCKER-severity issue (WF-03) to implement real AES-256-GCM + key-wrap in `crypto.zig`, re-encrypt existing rows, and add a test asserting ciphertext ≠ plaintext.** Until then, treat all stored secrets as plaintext-at-rest in any security assessment.

### 5.2 Duplicate architecture documents invite drift
Both `BPM_Platform_Backend_Architecture.md` (v1.0) and `BPM_Platform_Backend_Architecture.20260611.md` (v1.1, the corrected one) sit in `docs/`. The undated filename is the one agent function docs reference (e.g. `docs/agents/functions/fn-load-requirements.md`), but it is the *superseded* version. Replace v1.0's content with a stub pointing to v1.1 (or make the undated file the living document and delete the dated copy), so agents can't read the pre-audit spec by accident.

### 5.3 Audit-process observations
The audit trail would be stronger with two cheap conventions, both already recommended by the borrowing analysis (§6.3) and not yet adopted: an audit-driven changelog at the top of the architecture doc mapping each revision to the audit findings it resolves (v1.1 does this well — keep it up), and a per-finding disposition record (a short YAML in `docs/Audit-Reports/` marking each finding FIXED/OPEN/WONTFIX with the resolving requirement ID). This validation had to reconstruct dispositions by grepping migrations; a 20-line YAML per audit would make the next validation trivial.

---

## 6. Recommendations

### 6.1 Architecture (priority order)

1. **Fix the secrets placeholder crypto (§5.1) before any new connector/effects surface ships.** This is the only item here I'd classify as a defect rather than a plan.
2. **Execute the SPT cutover.** Test and release ISS-501–504, run SPT-02, then retire the legacy `tenant_id`/RLS path (SPT-03/04). Every week of coexistence extends the exposure window of the audit's finding #6, and the cutover machinery is already built.
3. **Adopt the addon-2 engine specs next (BRW-ENG-1/2/3, then ENG-5):** formalized retry policy with deterministic-failure short budget, failed-instance lifecycle, parallel-branch failure isolation, and `instance_waits` restore reconciliation (the wait descriptors are persisted — migration 093, wired into `src/engine/instance.zig`, the scheduler, and the effects worker — but the restore-time reconciliation saga that re-arms waits and marks `restored_orphan` instances is not implemented). These are well-bounded and their acceptance criteria are already written.
4. **Defer compensation constructs (BRW-ENG-4) and the saga runner (BRW-SAGA-1) until after 2–3,** as addon-2's own ordering suggests — they are the largest engine commitment and depend on the failure semantics being formalized first.
5. **Write the two cheap doc anchors now:** the scale anchor (BRW-OPS-1 — a paragraph that justifies single-primary/single-sweep against a stated tenant ceiling) and the §5.2 doc de-duplication. Both are hours, not days.

### 6.2 Features / product

1. **Register the BRW-* set in `requirement_status.yaml`** so the addon-2 backlog is governed by the same stage gates, WF pipelines, and retrospectives as everything else. Untracked requirements don't get built.
2. **Mobile tier (BRW-MOB-1..8) is the largest genuine feature gap** and the audits' analysis holds: the generic definition-interpreter approach means the server contracts already exist. Start with the mobile architecture doc (mapping ASCOA's template onto My-Fab endpoints) before any Flutter code, and keep the v1 scope boundary (no offline writes, no push, no form builder).
3. **Entity subsystem follow-through.** `src/entities` matches the recommended events + typed-projection model. Two open questions from the gap analysis (§7.1/7.2) still have no recorded decision: read-your-writes semantics for entity reads inside a step, and entity snapshots for re-projection at scale. Decide and document both before tenants build large reference-data catalogs on it.
4. **Close the loop on ISS-202 and the IMPLEMENTED Epic-5 items** — cheap status-hygiene wins that make the release dashboard truthful again.

---

*Validation basis: file-level inspection on 2026-07-02 of the paths cited inline. Claims about runtime behavior were not tested; where the audits made runtime claims, this review verified only that the corresponding code/migrations exist.*
