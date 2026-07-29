# Session Handoff — ASCOA-GO borrow backlog

**Session:** 2026-07-29, Claude Cowork (cloud), model `claude-opus-5`
**Continues in:** Claude Code, local, this repo
**Read first.** This is a session continuation brief, not a pipeline handoff. It
is not in `handoffs/<RUN-ID>/` because ORCH reads that directory as JSON.

---

## 1. What this session did

Compared R-Co against its peer platform ASCOA-GO
(`C:\Users\tvolo\dev\ASCOA\ascoa-go`), produced a borrow report, then converted
that report into a two-level backlog: **platform workflows** (`PW-nn`) above
**functional requirements**, wired so a workflow can be handed to WF-05 as a
unit once its requirements are done.

Two earlier borrow analyses already existed (2026-06-11, 2026-06-26). This one
builds on them rather than repeating them: ASCOA-GO touched 505 of its 627
`internal/` files since 2026-06-29, so most of what is borrowable now is new.

---

## 2. State of the repo RIGHT NOW — read this before doing anything

**Nothing has been applied.** Artefacts are on disk; no tool has been run.

| Fact | Value |
|---|---|
| `docs/requirements.yaml` | **untouched**, 551,406 bytes, 442 requirements |
| `tools/reqctl.py` | **unpatched**, no `.bak-*` file exists |
| `docs/status/implementation_order.md` | **untouched and stale** — v0.2, 2026-05-26, stages 1-12 only, references a `requirement_status.json` that no longer exists, and nothing in the agent system reads it |
| The 92 new requirements | authored, validated, **not registered** |
| `backlog/` | present at repo root, input to the applier |
| `_incoming/R-Co-platform-workflows-20260729.zip` | the delivered package, already unpacked into place |

The whole chain was executed end-to-end against a *copy* of the real
`requirements.yaml` before delivery: 92 registered, `reqctl validate` PASS,
`wfctl validate` PASS, re-run skips all 92. It has not been run here.

---

## 3. What is on disk

| Path | What |
|---|---|
| `docs/Audit-Reports/Borrowing_From_ASCOA-GO.20260729.md` | the report everything derives from |
| `docs/workflows.yaml` | **new canonical file** — the 16 `PW-nn` entries, plus an `excluded:` block for everything deliberately not modelled as a workflow |
| `docs/processes/system/*.md` | 16 new process maps in the existing house schema; their Steps tables carry a `\| Requirement \|` column |
| `docs/traceability_borrow_to_requirements.md` | report section → workflow → requirement, both directions |
| `docs/status/requirement_dependencies.md` | the plain "X needs Y first" list |
| `docs/agents/RUNBOOK_platform_workflows.md` | **ORCH operating procedure — the real entry point** |
| `docs/agents/INSTALL_platform_workflows.md` | install steps |
| `docs/agents/PIPELINE_BACKLOG.md` | `PI-01..09`, the process items, as ADHOC handoffs |
| `docs/agents/uat-scenario-schema-v1.1-addendum.md` | additive schema change so platform workflows can be UAT-gated |
| `tools/wfctl.py` | workflow catalogue CLI — read/verify only, never writes requirements |
| `tools/depsort.py` | derives implementation order from dependencies |
| `tools/patch_reqctl_workflow.py` | idempotent patch adding the `workflow` field to reqctl |
| `tools/apply_borrow_backlog.py` | the one-shot applier |
| `backlog/bodies/*.md` + `backlog/meta-*.yaml` | 92 requirement bodies and their metadata |
| `tests/simulation/scenarios/platform/*.yaml` | 18 platform UAT scenarios |
| `tests/simulation/scenarios/{swiftroute,vortex}-*.yaml` | 2 tenant UAT scenarios (PW-09, PW-10) |

---

## 4. The model

```
PW-nn (docs/workflows.yaml, tools/wfctl.py)      an end-to-end capability the platform executes
  |-- process_map     docs/processes/system/<slug>.md
  |-- requirements[]  docs/requirements.yaml      (reqctl owns content + status)
  +-- uat_scenarios[] tests/simulation/scenarios/ (UAT-RUNNER, WF-05)
```

`PW-nn` is **not** `WF-0n`. `WF-0n` are the development workflows this pipeline
runs; `PW-nn` are product capabilities the platform executes. They never share
a field.

Ownership, which must not blur: `reqctl` owns requirement content and status and
is the only writer of `docs/requirements.yaml`. `wfctl` owns the catalogue and
*derives* workflow status from requirement status.

The gate the user asked for:

```bash
python3 tools/wfctl.py uat-ready PW-04
```

Exit 0 means every gating requirement is `TESTED` or `RELEASED`, every named
scenario file exists, and every dependency workflow is at least `IMPLEMENTED` —
and it prints the WF-05 dispatch block. Exit 1 lists what is missing.

---

## 5. Do this next, in order

```bash
python3 tools/apply_borrow_backlog.py --dry-run   # preflight, writes nothing
python3 tools/apply_borrow_backlog.py             # registers the 92
python3 tools/wfctl.py next                       # what can start
```

Expected: `requirements registered : 92`, both validators PASS.

Then follow `docs/agents/RUNBOOK_platform_workflows.md` §4. Its order, condensed:

| # | Item | Vehicle |
|---|---|---|
| 0 | `ISS-BRW-01` — `secrets/crypto.zig` stores plaintext | WF-03 |
| 1-4 | `PI-01..PI-04` (split CLAUDE.md, security invariants + agent, `zig build check`, one command surface) | ADHOC |
| 5 | `ISS-BRW-02` — `.env.example` | WF-03, any time |
| 6 | the 92 requirements | WF-02, batches of ≤4 |
| — | `PI-05..PI-09` | ADHOC, when the pain bites |

---

## 6. Facts a fresh agent will otherwise get wrong

1. **`reqctl` is the only write path to `docs/requirements.yaml`.** Never edit
   it directly. `docs/status/requirement_status.yaml` is generated —
   `reqctl render-status`, never by hand.

2. **`reqctl validate` reports 4 MAJOR and 8 MINOR that predate this work** —
   `OIDC-F-06`, `TD-UI-01`, `TD-UI-02` cite unresolvable IDs; `WH-UI-03`
   contains vague language; several old entries have no prose body. `BLOCKER` is
   0 before and after. Do not treat these as caused by the backlog, and do not
   let them block the install.

3. **The 92 land as `DRAFT`.** They have not been through WF-01 / REQ-VALIDATOR.
   Either validate a workflow's requirements before dispatching WF-02 for it, or
   accept them and let the 1b/3b design gates catch problems.

4. **`ISS-BRW-01` is a verified defect, not a suspicion.** `src/secrets/crypto.zig`
   `encrypt()` does `_ = master_key;`, generates a nonce, auth tag and data key
   that are never used, and sets `ciphertext = allocator.dupe(u8, plaintext)`.
   `decrypt()` returns `dupe(envelope.ciphertext)`. The envelope declares
   `.aes_256_gcm` / `.aes_kw_256`. Every tenant secret is in the database in
   plaintext behind metadata claiming otherwise. The code comment calls it a
   deliberate "Wave-1 envelope model". Fix with
   `std.crypto.aead.aes_gcm.Aes256Gcm` and add a test asserting
   `ciphertext != plaintext`. Read the file before writing the fix.

5. **There is no `depends_on` field on a requirement.** Order is derived from
   `> **Extends:** X` lines (hard, acyclic) and workflow `depends_on` (hard).
   `**See:**` is deliberately **not** an edge — it means "related" and contains
   real cycles (`TD-UI-01 ↔ TD-UI-02`, `OIDC-F-05 ↔ OIDC-F-06`). Only 27 of the
   141 open requirements have a prerequisite; 93 have none.

6. **The UAT schema v1.1 addendum is written but NOT applied to the agent docs.**
   `docs/agents/uat-scenario-schema-v1.1-addendum.md` §7 lists the changes
   `UAT-RUNNER`, `PRODUCT-OWNER`, `WF-05` and `WF-06` need (accept
   `company_id: platform`, `via: system`, `system_state` + required `evidence`;
   skip the BO steps for platform workflows). **Those edits have not been made.**
   A platform-workflow UAT run will fail until they are.

7. **`docs/guides/frontend_design_system.md` is complete and unimplemented.**
   `web/src/components/ui/` holds one file; `design-tokens/r-co.tokens.json` is
   377 bytes. PW-14 implements the existing spec — it does not replace it. Use
   R-Co's own token names, not the reference platform's.

8. **DIRECTIVE T-2 forbids MSW.** Every frontend requirement in PW-13..PW-16 is
   written to be provable by Playwright against a real backend, or by a pure
   static/bundle scan. Do not introduce a Vitest+MSW substrate.

9. **A workflow with no `MUST` requirement is gated by all of its requirements.**
   PW-08 is the only one. Without this a wholly-`SHOULD` workflow would report
   `0/0` and pass the UAT gate with nothing built.

10. **`docs/status/implementation_order.md` is stale.** `tools/depsort.py render`
    regenerates it from the data. It was deliberately not run — see §7.

---

## 7. Open decisions — ask, do not guess

The user did not settle these:

1. **Retire or regenerate `docs/status/implementation_order.md`?**
   `depsort render` overwrites it with a generated wave order. Not run, because
   replacing a hand-written file was not authorised.
2. **Add an explicit `depends_on` field to requirements?** Would make dependency
   order meaningful for the 49 pre-existing open requirements, which currently
   have almost none. Patch pattern is the same as the `workflow` field.
3. **Apply the UAT schema v1.1 changes to the agent docs?** See fact 6.
4. **`PI-01..04` before the 92, or start the 92 now?** The recommendation is
   before; the user has not confirmed.

---

## 8. The numbers

| | |
|---|---|
| Requirements in the register | 442 (+9 non-requirement entries = 451) |
| `RELEASED` / `DEPRECATED` | 301 |
| Open, pre-existing R-Co backlog | 49 — `EXP` 14, `ISS` 16, `PLC` 4, `SOL` 3, `SPC` 2, `SPT` 3, `TD-UI` 3, `OIDC-F` 2, `IDN-05`, `ENV-04` |
| Open, new from this backlog | 92 — all carry `workflow: PW-nn` |
| Platform workflows | 16 (`PW-01..PW-16`) |
| UAT scenarios | 20 |
| New requirement prefixes | `PRM` 9, `VLD` 4, `PIN` 5, `MIG` 6, `DDL` 5, `PAR` 6, `ORD` 4, `OBP` 4, `FIL` 8, `QRY` 5, `AGT` 7, `SBX` 6, `RND-UI` 6, `CMP-UI` 6, `CAC-UI` 4, `GRD-UI` 7 |
| New stages | 16 (backend, 42 reqs), 17 (backend, 26), `F8` (frontend, 23) |

---

## 9. What was verified, and what was not

**Verified by reading source or running code:**
- `src/secrets/crypto.zig` does not encrypt (read directly).
- `web/src/api/queryKeys.ts` has no tenant segment (read directly).
- `docs/guides/frontend_design_system.md` exists and is complete; `components/ui/`
  has one file; `design-tokens/r-co.tokens.json` is 377 bytes.
- The full apply → validate → render chain, against a copy of the real
  `requirements.yaml`. Idempotent on re-run.
- All 92 bodies: ID regex, no vague language, every `**See:**` ID resolves, no
  collision with existing IDs, ASCII.
- All 20 scenarios: id matches the catalogue, `uat_surface` step rules,
  `evidence` present on every `system_state` outcome.

**Not verified — assumptions a fresh agent should re-check:**
- Nothing in `src/` was built, run or tested this session. Every claim about
  runtime behaviour comes from reading code and docs.
- ASCOA-GO claims come from its `internal/`, `docs/` and `.github/` trees, not
  from running it.
- The process maps' technical decisions (partition key `created_at`, the widened
  `(event_id, created_at)` PK with a separate `plat_event_idempotency` table,
  `instances.first_event_at` / `last_event_at` bounding reconstruction) were
  derived from `docs/BPM_Platform_Backend_Architecture.md`. They have not been
  checked against the actual migrations. **PW-06 in particular deserves a review
  before implementation.**
- Stage numbers 16, 17 and `F8` were chosen as "next free"; they have not been
  reconciled with any roadmap.

---

## 10. Verification commands

```bash
python3 tools/wfctl.py validate     # exit 1 on BLOCKER
python3 tools/reqctl.py validate    # 4 MAJOR / 8 MINOR pre-existing, BLOCKER 0
python3 tools/depsort.py check      # cycles and dangling references
python3 tools/wfctl.py list         # all 16 workflows and derived status
python3 tools/wfctl.py show PW-01   # goal, requirements, scenarios, source
python3 tools/depsort.py path SBX-01
python3 tools/patch_reqctl_workflow.py --check   # exit 1 if the patch is absent
```

---

*Append a line to `docs/Sessions.md` in its existing format when this session is
closed out — that file was not touched here, since its `d:` / `w:` metric
convention is not documented anywhere I could find.*
