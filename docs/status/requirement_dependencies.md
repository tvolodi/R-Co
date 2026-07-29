# Requirement Dependencies — what must be built before what

**Generated:** 2026-07-29
**Covers:** the 141 open requirements in `docs/requirements.yaml`
**Regenerate:** `python3 tools/depsort.py order`

---

## 1. Requirements that need another one first — 27 pairs

| This one | needs this first | Because |
|---|---|---|
| `DDL-01` | `MIG-01` | the DDL validator is called by the migration runner, which needs its control table |
| `DDL-02` | `DDL-01` | the ordering check extends the validator |
| `DDL-03` | `DDL-02` | phased generation obeys the ordering rule |
| `DDL-04` | `DDL-03` | the backfill is one of the three generated statements |
| `FIL-03` | `FIL-01` | quota is counted on upload |
| `FIL-04` | `FIL-01` | the size cap is applied on upload |
| `FIL-05` | `FIL-01` | you can only sign a URL for something uploaded |
| `FIL-06` | `FIL-05` | probe-safety is a property of the signed download |
| `FIL-07` | `FIL-01` | deletion needs something to delete |
| `FIL-08` | `FIL-07` | the ordering rules govern the reaper sweeps |
| `QRY-02` | `QRY-01` | the allowlist filters the query surface |
| `QRY-04` | `QRY-01` | the empty envelope is a response of the query surface |
| `QRY-05` | `QRY-01` | field stripping applies to query results |
| `AGT-03` | `AGT-01` | idempotency is keyed on the envelope |
| `AGT-05` | `AGT-04` | the RNG seed is folded into the spec hash |
| `AGT-06` | `PIN-01` | retention is pin-aware, so pins must exist |
| `AGT-07` | `AGT-01` | field-name rejection is a rule of the envelope |
| `SBX-01` | `IDN-05` | the orchestrator gate needs the named role registry |
| `SBX-02` | `SBX-01` | the principal is set by the gated handler |
| `SBX-03` | `SBX-01` | claim exclusion is keyed on the orchestrator role |
| `SBX-04` | `SBX-03` | ownership binds at claim |
| `SBX-05` | `SBX-04` | the sentinel protects the ownership check |
| `SBX-06` | `SBX-04` | the audit records claim and release |
| `SOL-03` | `IDN-05` | the role-mapping gate needs the role registry |
| `PRM-09` | `SOL-02` | a pack update needs pack installation to exist |
| `CAC-UI-04` | `PIN-01` | the client fetches the pinned version, so pins must exist |
| `GRD-UI-07` | `CMP-UI-05` | generated ARIA comes from the field registry |

---

## 2. Whole group before whole group — 5 rules

These come from `depends_on` between platform workflows in `docs/workflows.yaml`.

| Build all of | before any of |
|---|---|
| `DDL-*` (PW-05) | `PAR-*` (PW-06) |
| `PIN-*` (PW-03) | `AGT-*` (PW-11) |
| `AGT-*` (PW-11) | `SBX-*` (PW-12) |
| `RND-UI-*` (PW-13) | `CMP-UI-*` (PW-14) |
| `CMP-UI-*` (PW-14) | `GRD-UI-*` (PW-16) |

Combined, the two longest chains are:

```
MIG-01 -> DDL-01 -> DDL-02 -> DDL-03 -> DDL-04 -> PAR-01..06
PIN-01..05 -> AGT-01..07 -> SBX-01 -> SBX-03 -> SBX-04 -> SBX-05, SBX-06
RND-UI-* -> CMP-UI-* -> GRD-UI-*
```

---

## 3. Everything else — no dependency

**93 of the 141 open requirements have no prerequisite at all.** They can be
started in any order, at any time.

That includes all of `PRM-01..08`, `VLD-*`, `PIN-*`, `MIG-02..06`, `ORD-*`,
`OBP-*`, `RND-UI-*`, `CAC-UI-01..03`, and the older `SOL-01`, `SOL-02`,
`PLC-*`, `SPC-*`, `EXP-*`, `ISS-*`, `SPT-*`, `TD-UI-*`, `OIDC-F-*`, `ENV-04`
and `IDN-05`.

**For the 49 pre-existing requirements specifically, there is almost no
dependency information in the register.** Only two of them have a
prerequisite: `SOL-03` and `SBX-01`, both needing `IDN-05`. Their order comes
from the `stage` number, not from dependencies.

---

## 4. What these 141 requirements are

A common misreading, so stated plainly: **this list is not all requirements,
and it is not all from the ASCOA-GO comparison.**

| Group | Count | What it is |
|---|---|---|
| Already built | **301** | `RELEASED` or `DEPRECATED`. Not listed above — nothing needs to be built before something already built. |
| Borrowed from ASCOA-GO | **92** | The new backlog. Every one carries a `workflow: PW-nn` field. Prefixes: `PRM`, `VLD`, `PIN`, `MIG`, `DDL`, `PAR`, `ORD`, `OBP`, `FIL`, `QRY`, `AGT`, `SBX`, `RND-UI`, `CMP-UI`, `CAC-UI`, `GRD-UI`. |
| Pre-existing R-Co backlog | **49** | Open before the comparison was ever run. Not borrowed, not audit findings. Prefixes: `EXP` (14), `ISS` (16), `PLC` (4), `SOL` (3), `SPC` (2), `SPT` (3), `TD-UI` (3), `OIDC-F` (2), `IDN` (1), `ENV` (1). |
| **Total in the register** | **442** | |

### Nothing separate came out of the audit as a requirement

The audit produced four kinds of finding, and only one became requirements:

| Finding | Where it went |
|---|---|
| Borrowable capabilities | the **92** requirements above |
| Two verified defects — `secrets/crypto.zig` stores plaintext behind AES-256-GCM metadata; `.env.example` is incomplete | `ISS-BRW-01` and `ISS-BRW-02` in the `excluded:` block of `docs/workflows.yaml`. Route to WF-03. A broken code path is not a missing capability, so it is not a requirement. |
| Twelve process and governance items — splitting `CLAUDE.md`, security invariants, a lint gate, CI tiering | `excluded.development_process` in `docs/workflows.yaml`. ADHOC handoffs. They change the pipeline, not the product. |
| Seven items examined and rejected | `excluded.not_borrowed` in `docs/workflows.yaml`, with the reason recorded. |

So: **92 borrowed + 49 that were already yours = the 141 open requirements.**

---

## 5. Where this comes from

There is no `depends_on` field on a requirement. The pairs in §1 are read from
`> **Extends:** X` lines in requirement bodies; the group rules in §2 are read
from `depends_on` between workflows. `**See:**` lines are deliberately ignored —
they mean "related", not "depends on", and they contain real cycles
(`TD-UI-01` and `TD-UI-02` cite each other, as do `OIDC-F-05` and `OIDC-F-06`).

```bash
python3 tools/depsort.py order        # this list, live
python3 tools/depsort.py path SBX-01  # everything that must precede one requirement
python3 tools/depsort.py check        # cycles and dangling references
```
