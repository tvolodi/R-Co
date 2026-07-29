# Traceability — Borrow report to platform workflows to requirements

**Generated:** 2026-07-29
**Upstream:** `docs/Audit-Reports/Borrowing_From_ASCOA-GO.20260729.md`
**Downstream:** `docs/workflows.yaml` (PW-nn) and `docs/requirements.yaml` (92 new entries)
**Revised:** 2026-07-29 — `PRM-09` added, closing the FR-TPL-3 gap recorded in §5.2 of the first edition

Answers one question: **where did each of the 92 requirements come from, and did
anything in the report get dropped?**

---

## 1. The chain

The report is prose. Requirements are implementable units. The workflow sits
between them, and is the thing that carries the link:

```
report section  --1:1-->  PW-nn                --1:many-->  requirements
   §2.4                     PW-04                             MIG-01 .. MIG-06
```

Every `PW-nn` entry in `docs/workflows.yaml` carries a `borrow_source` field
naming its report section, and every requirement carries a `workflow` field
naming its `PW-nn`. So the trace runs in both directions with no external index:

```bash
python3 tools/wfctl.py show PW-04          # -> borrow source + its requirements
python3 tools/reqctl.py show MIG-03        # -> workflow: PW-04
```

Each process map under `docs/processes/system/` repeats the citation in its
header table, and its Steps table carries a `| Requirement |` column, so a step
in a map is traceable to a requirement and back up to a report section.

---

## 2. Section to workflow

Sixteen workflows from sixteen report mechanisms. `§2.10` is a list of six
second-tier items, so it fans out to five workflows plus one requirement inside
another.

| Report § | Mechanism | Workflow | Reqs |
|---|---|---|---|
| §2.1 | Promotion as a gated state machine | PW-01 Definition promotion with an approval gate | 8 of 9 |
| §2.2 | Version pinning for non-graph definition kinds | PW-03 Instance version pinning | 5 |
| §2.3 | Time-partitioned append-only logs | PW-06 Event log partition lifecycle | 6 |
| §2.4 | Migration control table + resume | PW-04 Tenant migration fanout and resume | 6 |
| §2.5 | `ValidatePlatformDDL` lock-safety gate | PW-05 Platform DDL safety | 4 of 5 |
| §2.6 | `plat_` reserved prefix | PW-05 (`DDL-05`) | 1 of 5 |
| §2.7 | Per-correlation FIFO at consumption | PW-07 Correlated effect re-entry ordering | 4 |
| §2.8 | Agent-artifact envelope | PW-11 Agent artifact submission and retention | 7 |
| §2.9 | Orchestrator / implementer separation | PW-12 Agent sandbox ownership and role separation | 6 |
| §2.10 | File / attachment subsystem | PW-09 File attachment lifecycle | 8 |
| §2.10 | Generic entity query API | PW-10 Entity record query | 5 |
| §2.10 | Formula type-check at promotion | PW-02 Definition semantic validation | 4 |
| §2.10 | Outbox depth cap, two backpressure paths | PW-08 Outbox backpressure | 4 |
| §2.10 | Reaper conventions | PW-09 (`FIL-07`, `FIL-08`) | 2 of 8 |
| §2.10 | Pre-vetted template auto-promotion (FR-TPL-5) | PW-01 (`PRM-05`, as a criterion — see §5) | 0 |
| §2.10 | Template update diffed against tenant customisations (FR-TPL-3) | PW-01 (`PRM-09`) | 1 of 9 |
| §3.1 | Five mandatory renderer states | PW-13 Renderer state and error contract | 5 of 6 |
| §3.6 | 409 conflict UX | PW-13 (`RND-UI-06`) | 1 of 6 |
| §3.2 | Design system implemented | PW-14 Shared UI component layer | 5 of 6 |
| §3.3 | Generic-renderer principle + field registry | PW-14 (`CMP-UI-05`, `CMP-UI-06`) | 2 of 6 |
| §3.2 | Tenant-scoped query keys | PW-15 Tenant-scoped client cache | 4 |
| §3.4 | Static architecture guards | PW-16 (`GRD-UI-01..05`) | 5 of 7 |
| §3.5 | Accessibility gate | PW-16 (`GRD-UI-06`, `GRD-UI-07`) | 2 of 7 |

**92 requirements. No requirement belongs to two workflows; no requirement is
orphaned.** `wfctl validate` enforces both, as BLOCKER.

---

## 3. Requirement by requirement

### PW-01 — §2.1 Promotion as a gated state machine

| ID | Priority | Title | Report mechanism |
|---|---|---|---|
| PRM-01 | MUST | Promotion plan and diff report | the plan, serialised into the review at submit time |
| PRM-02 | MUST | Conflict pre-flight rejection | `rejectIfConflicts` before any transaction opens; one audit row, no pointer move |
| PRM-03 | MUST | Plan digest binds approval to a diff | SHA-256 over canonical-JSON `{type, id, changes}` |
| PRM-04 | MUST | Promotion review state machine | the six states `pending_review/approved/rejected/applied/failed/superseded` |
| PRM-05 | MUST | Non-skippable human approval gate | `requireApprovedReview`; also carries the FR-TPL-5 routing rule |
| PRM-06 | MUST | Pre-promotion assertion re-run | ephemeral sandbox, artifact fixtures only, frozen clock, seeded RNG, stub effects |
| PRM-07 | MUST | Sandbox teardown does not block promotion | teardown failure emits an operator-visible event instead of failing the promotion |
| PRM-08 | SHOULD | Promotion rollback by version pointer move | rollback is a pointer move because promotion carries no DDL |
| PRM-09 | SHOULD | Solution pack update conflict resolution | §2.10 FR-TPL-3: a pack update is diffed against the tenant's own customisations; nothing overwritten silently |

### PW-02 — §2.10 Formula type-check at promotion (FR-VAL-4)

| ID | Priority | Title |
|---|---|---|
| VLD-01 | MUST | Typed environment from definition context |
| VLD-02 | MUST | Expression compile and type check |
| VLD-03 | MUST | Aggregated validation diagnostics |
| VLD-04 | SHOULD | Validation gate at authoring and promotion |

### PW-03 — §2.2 Version pinning

| ID | Priority | Title |
|---|---|---|
| PIN-01 | MUST | Dependency version resolution at instance start |
| PIN-02 | MUST | Pin set recorded in `INSTANCE_STARTED` |
| PIN-03 | MUST | No fallback to latest version |
| PIN-04 | MUST | Pin resolution on replay and in sub-processes |
| PIN-05 | SHOULD | Explicit instance pin rebind |

Note the event-sourced adaptation: the reference platform uses two side tables;
here the pin set lives in the `INSTANCE_STARTED` event payload, so it survives
replay without a second store.

### PW-04 — §2.4 Migration fanout

| ID | Priority | Title |
|---|---|---|
| MIG-01 | MUST | Platform migration control table |
| MIG-02 | MUST | Control row commits with the DDL |
| MIG-03 | MUST | Tenant migration fanout with continue on failure |
| MIG-04 | MUST | Migration resume for pending and failed tenants |
| MIG-05 | MUST | Idempotent migration re-run |
| MIG-06 | MUST | Migration admin surface and fix-forward policy |

### PW-05 — §2.5 DDL validator + §2.6 reserved prefix

| ID | Priority | Title | From |
|---|---|---|---|
| DDL-01 | MUST | Pure platform DDL validator | §2.5 |
| DDL-02 | MUST | Expand-then-constrain ordering check | §2.5 |
| DDL-03 | SHOULD | Phased DDL generation | §2.5 |
| DDL-04 | MUST | Idempotent batched backfill | §2.5 |
| DDL-05 | MUST | Reserved `plat_` object namespace | §2.6 |

### PW-06 — §2.3 Partitioning

| ID | Priority | Title |
|---|---|---|
| PAR-01 | MUST | Monthly range partitioning of the event log |
| PAR-02 | MUST | Proactive future partition creation |
| PAR-03 | MUST | Partition-scoped retention and archival |
| PAR-04 | MUST | Partition constraints declared before attach |
| PAR-05 | MUST | Online conversion to a partitioned event log |
| PAR-06 | MUST | Time-bounded instance reconstruction queries |

`PAR-06` exists because of a constraint the report raised but did not settle:
partition pruning needs a time predicate, and reconstruction queries by
`instance_id`. The decision taken is to maintain `instances.first_event_at` and
`last_event_at` and bound every reconstruction query with them, rather than
accept per-partition index fan-out. `PAR-03` also reconciles retention-by-drop
with ADP-11, which forbids hard deletion of most event kinds.

### PW-07 — §2.7 Per-correlation FIFO

| ID | Priority | Title | Report mechanism |
|---|---|---|---|
| ORD-01 | MUST | Effect completion claim guard | `FOR UPDATE SKIP LOCKED` prevents double-claiming |
| ORD-02 | MUST | Per-correlation execute guard | `step_execution_id` prevents double-execution |
| ORD-03 | SHOULD | Sequence order guard and gap sweeping | the correlation advisory lock supplies order |
| ORD-04 | MUST | Cross-correlation parallelism and lag metrics | parallel across correlations |

This is the report's "three guards, often conflated" made explicit as three
separate requirements.

### PW-08 — §2.10 Outbox backpressure (FR-GRO-4)

| ID | Priority | Title |
|---|---|---|
| OBP-01 | SHOULD | Outbox depth cap and cached depth counter |
| OBP-02 | SHOULD | External ingress refusal before transaction |
| OBP-03 | SHOULD | Typed outbox overflow on internal emit |
| OBP-04 | SHOULD | Outbox gate hysteresis and escalation |

The only all-SHOULD workflow, so `wfctl` gates it on all four rather than on
nothing.

### PW-09 — §2.10 Files, and the reaper conventions

| ID | Priority | Title | From |
|---|---|---|---|
| FIL-01 | MUST | Human task attachment upload | FR-FILE-1 |
| FIL-02 | MUST | Tenant-prefixed storage object keys | FR-FILE-2 |
| FIL-03 | MUST | Transactional attachment quota accounting | FR-FILE-2 |
| FIL-04 | MUST | Per-tier single-upload size cap | FR-FILE-2 |
| FIL-05 | MUST | Signed time-limited attachment download URL | FR-FILE-2 |
| FIL-06 | MUST | Probe-safe cross-tenant attachment reads | FR-FILE-2 |
| FIL-07 | MUST | Attachment delete grace period and reaper sweeps | FR-FILE-3 |
| FIL-08 | SHOULD | Reaper ordering and predicate idempotency | §2.10 reaper conventions |

### PW-10 — §2.10 Entity query

| ID | Priority | Title |
|---|---|---|
| QRY-01 | MUST | Structured entity query surface |
| QRY-02 | MUST | Declared filterable field allowlist |
| QRY-03 | MUST | Keyset pagination with a bounded page size |
| QRY-04 | MUST | Empty envelope for unauthorised entity types |
| QRY-05 | MUST | Server-side field stripping on query results |

Deliberately excluded, per the report: the placement state machine and
expand/contract field promotion behind the reference implementation. Those
patch a mutable store this platform does not have.

### PW-11 — §2.8 Agent artifacts

| ID | Priority | Title |
|---|---|---|
| AGT-01 | MUST | Agent artifact envelope with kind discrimination |
| AGT-02 | MUST | Non-production artifact environment enforcement |
| AGT-03 | MUST | Artifact submission idempotency per attempt |
| AGT-04 | MUST | Immutable task specs bound by spec hash |
| AGT-05 | MUST | Non-zero RNG seed folded into spec identity |
| AGT-06 | MUST | Dual-sweep artifact retention |
| AGT-07 | SHOULD | Deprecated envelope field names rejected |

`AGT-07` is the report's smallest observation — the reference platform rejects
the legacy field name rather than silently aliasing it — kept as its own
requirement because it is a habit worth pinning, not a detail of AGT-01.

### PW-12 — §2.9 Orchestrator / implementer separation

| ID | Priority | Title |
|---|---|---|
| SBX-01 | MUST | Orchestrator role gate on task-spec submission |
| SBX-02 | MUST | Server-authoritative orchestrator principal |
| SBX-03 | MUST | Orchestrator excluded from sandbox claim |
| SBX-04 | MUST | Sandbox ownership binding at claim |
| SBX-05 | MUST | Single sentinel for inaccessible sandboxes |
| SBX-06 | MUST | Sandbox release, reclaim, and claim audit |

The report's auth half. The warm-pool half was explicitly not borrowed (§6).

### PW-13 — §3.1 Five states + §3.6 conflict UX

| ID | Priority | Title | From |
|---|---|---|---|
| RND-UI-01 | MUST | Six-state renderer union and single error classifier | §3.1 |
| RND-UI-02 | MUST | Loading state with skeleton layout | §3.1 |
| RND-UI-03 | MUST | Fetch failure state with explicit retry | §3.1 |
| RND-UI-04 | MUST | Leak-free permission denied surface | §3.1 |
| RND-UI-05 | MUST | Rate limit backpressure with retry countdown | §3.1 |
| RND-UI-06 | SHOULD | Three-action write conflict resolution | §3.6 |

Six states, not five: the report counts five error states; the union also needs
`success`.

### PW-14 — §3.2 Design system + §3.3 generic renderer

| ID | Priority | Title | From |
|---|---|---|---|
| CMP-UI-01 | MUST | Generated design token stylesheet | §3.2 |
| CMP-UI-02 | MUST | No literal colour values in component code | §3.2 |
| CMP-UI-03 | SHOULD | Shared UI component library | §3.2 |
| CMP-UI-04 | MUST | Tenant brand override at bootstrap | §3.2 |
| CMP-UI-05 | SHOULD | Field registry extension point | §3.3 |
| CMP-UI-06 | MUST | Generic interpreter architecture rule | §3.3 |

These implement `docs/guides/frontend_design_system.md`, which already exists
and specifies the tokens and component APIs. The requirements cite that
document's own token names rather than the reference platform's.

### PW-15 — §3.2 Query keys

| ID | Priority | Title |
|---|---|---|
| CAC-UI-01 | MUST | Tenant segment in every query key |
| CAC-UI-02 | MUST | Cache disposal on tenant switch and sign-out |
| CAC-UI-03 | SHOULD | Cache lifetime tiers by data class |
| CAC-UI-04 | MUST | Version-pinned task payload fetch |

### PW-16 — §3.4 Static guards + §3.5 accessibility

| ID | Priority | Title | From |
|---|---|---|---|
| GRD-UI-01 | MUST | Forbidlist as single guard source of truth | §3.4 |
| GRD-UI-02 | MUST | Frontend source scan gate | §3.4 |
| GRD-UI-03 | MUST | Post-build bundle scan gate | §3.4 |
| GRD-UI-04 | MUST | Two-sided META control per guard pattern | §3.4 |
| GRD-UI-05 | MUST | Redacted guard violation reporting | §3.4 |
| GRD-UI-06 | MUST | Accessibility gate per canonical surface | §3.5 |
| GRD-UI-07 | MUST | Generated per-field ARIA wiring | §3.5 |

All expressed as static scans or real-browser Playwright assertions, because
DIRECTIVE T-2 forbids MSW. The reference platform's Vitest+jsdom substrate was
not borrowed.

---

## 4. Report sections that produced no requirement — on purpose

| Report § | Content | Where it went |
|---|---|---|
| §0, §1 | How to read; status of the June-26 list | Reference only |
| §4.1-§4.3 | Twelve process and governance items | `docs/workflows.yaml` → `excluded.development_process`. They change the pipeline, not the product, so they are ADHOC handoffs, not requirements. |
| §5.1 | `secrets/crypto.zig` does not encrypt | `excluded.defects` → `ISS-BRW-01`, route to WF-03. A broken code path is not missing capability. |
| §5.2 | `.env.example` incomplete | `excluded.defects` → `ISS-BRW-02`, route to WF-03. |
| §6 | Seven items examined and rejected | `excluded.not_borrowed`, with the reason recorded so nobody re-proposes them. |
| §7 | What ASCOA should borrow from R-Co | Outbound. No R-Co work, so nothing tracked. |
| §8 | Recommended sequence | `docs/agents/RUNBOOK_platform_workflows.md` §4, reconciled against the `depends_on` graph. |

---

## 5. Known gaps in the mapping

One place where the report and the backlog do not line up one-to-one, and one
that has since been closed. Both are recorded rather than quietly smoothed over.

**5.1 FR-TPL-5 is a criterion, not a requirement.** The report's §2.10 flags the
pre-vetted template auto-promotion routing choice — that provisioning promotes
through a *separate entry point which structurally cannot reach the gate*,
rather than through a skip flag on the gated path. That survives as an
acceptance criterion inside `PRM-05` (the non-skippable gate) and as a Business
Rule in the PW-01 process map, which is where it belongs logically, since it is
a statement about how the gate may be bypassed. It has no requirement ID of its
own, so it will not appear in a status report as a distinct deliverable. Left
as-is deliberately: promoting it to its own requirement would imply a separate
deliverable when it is really a constraint on `PRM-05`.

**5.2 FR-TPL-3 — CLOSED by `PRM-09`.** The first edition of this document
recorded that the report's §2.10 named two template gaps and only one was
covered. `PRM-09` now covers the second: a solution pack update is a three-way
comparison between the recorded install base, the tenant's current artefacts,
and the incoming version. Each artefact is classified `unchanged`,
`clean_update`, `local_only` or `conflict`, and a `conflict` artefact is not
applied until a resolution of `keep_local`, `take_incoming` or `merged` is
recorded with its resolving principal. The resolved update is then emitted as a
normal `PRM-01` plan, so it passes the same conflict pre-flight, approval gate
and assertion re-run as any other change.

It sits in PW-01 rather than in a workflow of its own because it reuses that
workflow's diff and conflict machinery, and it is `SHOULD` so it does not gate
PW-01 — the workflow still gates on its seven `MUST` requirements. If template
distribution later grows its own lifecycle (publishing, purchase, vetting), move
`PRM-09` into a dedicated `PW-nn` at that point rather than growing PW-01.

Everything else in §2 and §3 is represented.

## 6. Verifying this yourself

```bash
python3 tools/wfctl.py validate     # no requirement orphaned or double-claimed
python3 tools/wfctl.py show PW-01   # borrow source, requirements, scenarios
python3 tools/reqctl.py show PRM-03 # workflow: PW-01
```

`wfctl validate` treats these as BLOCKER: a requirement claimed by two
workflows, a requirement whose `workflow` field disagrees with the catalogue, a
catalogue entry naming a requirement that is not registered, and a missing
process map. So the mapping in this document cannot silently rot — if it does,
validation fails.
