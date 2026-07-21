# BPM Platform — Borrowing Implementation Order

**Version:** 0.1-draft
**Date:** 2026-06-26
**Companion documents:** `01-architecture-addition.md`, `02-functional-requirements.md`
**Purpose:** A single list of the `BRW-*` requirements sorted by implementation order, with dependencies, parallel tracks, and rationale. This is the build sequence; the FR document is the contract.

---

## 1. Ordering principles

1. **Verify before extend.** Every requirement touching shipped code (`src/effects`, `src/secrets`, `src/entities`, `src/dlq`, EXP-601 quotas) opens with a VERIFY clause. The first action on each is a source read that may collapse the requirement to *already-satisfied*.
2. **Cheap documentation first.** Scale anchor and threat model are pure docs that gate later work; they cost little and de-risk much.
3. **Foundational engine before constructs.** Failure semantics (retry/dead-letter/parallel isolation) must exist before compensation, which must exist before restore reconciliation can produce a complete recovery picture.
4. **Mobile is an independent track.** It depends only on existing server contracts, so it runs in parallel with the entire backend sequence from day one.
5. **Conditional work last.** The ephemeral-sandbox tier is gated on the agent-authoring roadmap and is sequenced only if that surface is confirmed near-term.

---

## 2. The ordered list

Two concurrent tracks: **Track A — Backend** (sequential within phases) and **Track M — Mobile** (parallel, self-contained).

### Track A — Backend

| Order | ID | Title | Priority | Depends on | Type |
|---|---|---|---|---|---|
| A0.1 | BRW-OPS-1 | Stated scale anchor | MUST | — | Doc |
| A0.2 | BRW-OPS-3 | Written sandbox threat model | MUST | — | Doc |
| A1.1 | BRW-ENG-1 | Per-node retry policy + deterministic-failure budget | MUST | A0.2 (threat model informs caps) | Extend `src/dlq`/engine |
| A1.2 | BRW-ENG-2 | Failed-instance lifecycle (out-of-band failure log, retry/cancel) | MUST | A1.1 | Extend engine |
| A1.3 | BRW-ENG-3 | Parallel-branch failure isolation | MUST | A1.2 | Extend engine |
| A2.1 | BRW-ENG-4 | Compensation + error-boundary constructs (impl EXP-401) | SHOULD | A1.3 | Build (from design) |
| A2.2 | BRW-ENG-5 | Restore reconciliation + `instance_waits` (impl EXP-402/103) | SHOULD | A2.1 | Build (from design) |
| A3.1 | BRW-SEC-1 | HMAC ingress key rotation w/ grace window | SHOULD | — (independent) | Extend `src/secrets` |
| A3.2 | BRW-EFX-1 | Async-effects coverage + circuit breaker | SHOULD | — (independent) | Verify `src/effects` + `[S]` |
| A3.3 | BRW-SAGA-1 | Extract generic minimal saga runner | SHOULD | A2.1 (shares compensation concepts) | Refactor onboarding |
| A3.4 | BRW-OPS-2 | Tier→quota model coverage | SHOULD | — (independent) | Verify EXP-601 |
| A4.1 | BRW-OPS-4 | Ephemeral throwaway-sandbox tier | COULD | A1–A2 (failure + waits), roadmap confirm | Conditional build |

### Track M — Mobile (parallel from start; depends only on existing server contracts)

| Order | ID | Title | Priority | Depends on |
|---|---|---|---|---|
| M1 | BRW-MOB-1 | Generic definition-interpreter app shell | MUST | existing definition/SPA contracts |
| M2 | BRW-MOB-2 | Tenant bootstrap (slug → config → OIDC PKCE → secure store) | MUST | M1; `tenant-config` endpoint (verify) |
| M3 | BRW-MOB-5 | On-device security (secure token storage, no cleartext) | MUST | M2 |
| M4 | BRW-MOB-3 | Offline definition cache + delta sync + version pinning | MUST | M2; `definitions/delta` endpoint (may be new) |
| M5 | BRW-MOB-4 | Generic renderers + six mandatory states | MUST | M4; existing form/list/task APIs |
| M6 | BRW-MOB-6 | API client (auth/refresh/retry/typed errors) | SHOULD | M2 |
| M7 | BRW-MOB-7 | i18n (reuse SPA locale policy) | SHOULD | M5 |
| M8 | BRW-MOB-8 | Enforce v1 scope boundary (online-first; defer offline writes) | MUST | M5 |

---

## 3. Phased timeline (recommended)

**Phase 0 — Documentation gates (days, not weeks).**
A0.1 scale anchor, A0.2 sandbox threat model. These unblock the engine caps in A1 and the agent-code promotion gate. Mobile track M1–M2 can start immediately, in parallel.

**Phase 1 — Engine failure semantics (foundational).**
A1.1 → A1.2 → A1.3, strictly sequential (each builds on the prior). This is the highest-value backend borrow: it makes "failure is a defined state" real and is prerequisite to everything in Phase 2. Mobile M3–M4 proceed in parallel.

**Phase 2 — Engine constructs.**
A2.1 compensation, then A2.2 restore reconciliation. Promotes two designed-but-unbuilt requirements (EXP-401, EXP-402) to implementation. Sequenced because restore needs the compensation/wait picture. Mobile M5 (renderers) lands here.

**Phase 3 — Verify/extend, parallelisable.**
A3.1 secrets rotation, A3.2 effects hardening, A3.3 saga extraction (after A2.1), A3.4 quota coverage — independent of one another; assign to separate streams. Mobile M6–M8 finish the mobile v1 here.

**Phase 4 — Conditional.**
A4.1 ephemeral-sandbox tier — only if the agent-authoring product surface is confirmed near-term; otherwise defer with recorded rationale.

```
Phase:   0          1                 2                  3              4
Backend: OPS-1,3 →  ENG-1→2→3      → ENG-4 → ENG-5    → SEC-1, EFX-1,  → OPS-4
                                                         SAGA-1, OPS-2    (cond.)
Mobile:  MOB-1,2  → MOB-3,4         → MOB-5            → MOB-6,7,8
         (independent track — converges with backend only via existing server contracts)
```

---

## 4. Effort and value at a glance

| Phase | Backend items | Rel. effort | Rel. value | Notes |
|---|---|---|---|---|
| 0 | OPS-1, OPS-3 | Low | Medium | Pure docs; gate later work |
| 1 | ENG-1/2/3 | Medium | High | Highest-value backend borrow |
| 2 | ENG-4/5 | High | High | Finishes designed work |
| 3 | SEC-1, EFX-1, SAGA-1, OPS-2 | Low–Med | Med–High | Mostly verify-then-small-extend |
| 4 | OPS-4 | High | Conditional | Only if agent-authoring is near-term |
| M | MOB-1…8 | High | High | Largest new capability; parallel |

---

## 5. Quick-win shortlist (if capacity is tight)

If only a few items can be taken now, in priority order:

1. **BRW-ENG-1/2/3** — failure semantics. Foundational, well-bounded, reusable acceptance criteria from ASCOA's FR-BPM-13/14/15.
2. **BRW-OPS-1 + BRW-OPS-3** — scale anchor + threat model. A day of documentation that de-risks several assumptions and gates agent code.
3. **BRW-SEC-1** — HMAC rotation. Small extension of shipped secrets; needed before more external connectors go live.
4. **BRW-MOB-1/2** — mobile shell + bootstrap. Starts the largest capability gap on an independent track with no backend blockers.

Deferrable with low regret: BRW-OPS-4 (conditional by nature), BRW-SAGA-1 (current hand-rolled onboarding works), BRW-EFX-1 extend portion (effects already async; only the `[S]` circuit breaker is new).

---

## 6. Verification gate per item

Every `BRW-*` item is "done" only when its FR acceptance hints pass **and** (for verify-then-extend items) the VERIFY clause was discharged against the live tree and recorded. Items that VERIFY reveals as already-satisfied are closed with a one-line note in the changelog, not re-implemented — this is the expected outcome for parts of EFX-1, OPS-2, and possibly portions of ENG-1.

---

*Build sequence only. Re-confirm each VERIFY clause against `src/` before starting the corresponding EXTEND work; the source tree moves faster than this document.*
