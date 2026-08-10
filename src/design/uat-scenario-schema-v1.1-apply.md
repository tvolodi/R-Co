# Module: UAT Scenario Schema v1.1 — Application to Consumer Agent Docs

## Module purpose

This design artefact is the specification for **applying** the v1.1 addendum
(`docs/agents/uat-scenario-schema-v1.1-addendum.md`, 2026-07-29) to the five
consumer agent docs it names. The addendum defines a new
`company_id: platform` value, a required `platform_workflow` field, a new
`via: system` step type, a new `verification.method: system_state` with a
mandatory `evidence` field, and a new `actor-system-*` actor naming
convention. None of the six consumer docs listed in §7 of the addendum
currently enforce any of those rules, so a platform-workflow scenario
authored to the addendum is rejected by UAT-RUNNER on `company_id` alone.

This artefact is **not** Zig, SQL, or TypeScript. It is a Type E prose
design that enumerates, per consumer file, the exact anchor location, the
exact before→after prose, and the rationale citing §7 of the addendum.
BACKEND-DEV will execute the edits in WF-03 Step 3.

---

## Public interface (what BACKEND-DEV receives)

BACKEND-DEV reads this artefact and produces five edited consumer docs plus
the optional CLAUDE.md note. There is no code-level public interface. The
"interface" is the per-consumer edit list in §5 below — one block per file,
each block containing:

- **Anchor** — the heading or paragraph in the existing file that is the
  locus of the change.
- **Before** — the current text that is being replaced or augmented.
- **After** — the new text that replaces or augments the current text.
- **Rationale** — cites the §7 row in the addendum that mandates the change.

This contract is intentionally text-level because the change is text-level.
BACKEND-DEV applies `replace_string_in_file` per block, then re-runs the
acceptance criteria at the bottom of this artefact to verify.

---

## Data types

Not applicable — this artefact produces no source code, no migration, no
TypeScript interface. The only "data types" are the six edit blocks named
below in §5.

---

## Key invariants

These invariants must hold after BACKEND-DEV has finished:

1. **Every v1.0 scenario file remains valid unchanged.** The addendum is
   additive (§"Status" header). No edit may remove or rename a v1.0 field
   that any current scenario depends on.
2. **The nine rejection rules in §8 of the addendum are restated in
   UAT-RUNNER.md** as the formal schema-validation gate — not just in
   prose, but as the check UAT-RUNNER runs against every scenario file
   before it executes anything. The malformed-scenario MAJOR issue path
   (§UAT_RUNNER.md Step 2 today) is the place where this lives.
3. **`company_id: platform` does NOT trigger a Keycloak company lookup.**
   The lookup at `GET /api/v1/tenants/<slug>` returns 404 for `platform`,
   so UAT-RUNNER must branch before calling it.
4. **`BPM_UAT_TOKEN` is the sole credential for `company_id: platform`.**
   The platform operator identity is platform-wide; there is no per-tenant
   realm. The existing `actor-platform-admin` credential resolves here.
5. **`via: api` stays forbidden.** The addendum §3 restates this explicitly.
   UAT-RUNNER.md and PRODUCT_OWNER.md must keep the v1.0 prohibition
   language.
6. **`actor-system-*` actors never appear on `via: gui` steps.** UAT-RUNNER
   validates the cross-product (step actor × step `via`) and rejects
   mismatches as malformed scenarios (§8 of the addendum, rule 8).
7. **WF-05 skips BO-* steps when a scenario's `company_id` is `platform`.**
   PRODUCT-OWNER is the sole business gate for platform scenarios; the three
   BO agents never receive one.
8. **PRODUCT-OWNER rejects any `system_state` outcome with empty `evidence`.**
   This is a hard reject (not a downgrade) so the evidence requirement is
   not silently waived.
9. **`tools/wfctl.py uat-ready <PW-nn>` is a hard pre-condition** for ORCH
   dispatching WF-05. Non-zero exit blocks the dispatch — same pattern as
   `zig build test-env-verify` in §8a of ORCHESTRATOR.md.
10. **WF-06 allows `REQ-ANALYST` to author `company_id: platform` scenarios.**
    No `BO-*` persona owns platform workflows, so WF-06 must select the
    authoring agent by `company_id`, not by org structure.
11. **The report-language rule from §4 of the addendum is restated
    unchanged** in every consumer doc that emits business text. Stack
    traces, selector strings, file paths with line numbers, SQL, and Zig or
    TypeScript function names remain forbidden in `description`, `detail`,
    `evidence`, and `business_impact` fields.

---

## External dependencies

This design depends on:

- `docs/agents/uat-scenario-schema-v1.1-addendum.md` (v1.1 normative source —
  read-only reference for the consumer edits).
- `docs/workflows.yaml` — must carry `uat_surface: gui | mixed | system`
  on every workflow so UAT-RUNNER can enforce the §3 permission table. If
  any workflow lacks the field, that is a separate defect (forwarded to the
  global queue per §8c of ORCHESTRATOR.md), not something this design fixes.
- `tools/wfctl.py` — must implement `uat-ready <PW-nn>` as the ORCH gate.
  If the subcommand does not exist yet, it is created as part of the
  BACKEND-DEV edit; this design assumes its signature is `python3 tools/wfctl.py uat-ready <PW-nn>` and that exit code is the only signal.
- The five consumer docs (`UAT_RUNNER.md`, `PRODUCT_OWNER.md`,
  `ORCHESTRATOR.md`, `WF-05_uat_run.md`, `WF-06_scenario_authoring.md`) —
  these are the edit targets.
- `CLAUDE.md` (optional — see §5 consumer 6).

This design does **not** depend on `BO-SWIFTROUTE.md`, `BO-VORTEX.md`, or
`BO-MERIDIAN.md` — §7 explicitly says no change for those.

---

## Open questions

- **None blocking.** The addendum is self-contained and §7 is unambiguous
  about which consumer edits are required.
- **Latent question (not for this design):** `tools/wfctl.py uat-ready`
  does not yet exist in this repo's tree at the time of writing. BACKEND-DEV
  must either (a) create it as part of this change, or (b) escalate the
  missing tool as a separate task. Decision (a) is preferred — the
  addendum's §2 (`platform_workflow` … `tools/wfctl.py uat-ready <PW-nn>`
  will not release a workflow to WF-05) treats it as already-existing
  infrastructure.
- **Latent question (not for this design):** `docs/workflows.yaml` may not
  yet carry `uat_surface` on every workflow. If UAT-RUNNER's enforcement
  (§3 permission table) finds a missing field, it has to either reject the
  workflow or default sensibly. Reasonable default is `mixed` (most
  permissive); rejecting is safer. This is a UAT-RUNNER.md §2 detail,
  surfaced here so BACKEND-DEV's edit does not silently swallow it.

## Errors

Malformed platform scenarios are rejected during UAT preparation; consumers do not
silently downgrade, execute, or sign off invalid input. UAT-RUNNER applies the nine
addendum §8 rules and reports a **MAJOR** malformed-scenario issue at schema-validation
time, including: missing `platform_workflow` on `company_id: platform`; an unknown
`platform_workflow`; a workflow whose `uat_surface` forbids the declared `via` value;
missing `via: gui` where `gui` or `mixed` requires it; `via: api`; a `system_state`
outcome with empty `evidence`; `actor-system-*` on a non-system step; invalid actor
references; and prohibited technical language in business-facing fields. The scenario
is skipped and the UAT run does not proceed with it.

PRODUCT-OWNER performs a second hard reject if any `system_state` outcome has an empty
`evidence` field, including reports produced after runner validation or reports loaded
from an external source. This remains a release-blocking MAJOR finding rather than a
warning or inferred-evidence fallback.

ORCH invokes `python3 tools/wfctl.py uat-ready <PW-nn>` before dispatching WF-05. A
non-zero exit means the catalogue's `uat_scenarios` list is incomplete (or another
precondition is missing); ORCH does not dispatch WF-05, files the missing precondition,
and forwards it to the global queue. Exit 0 is the only successful readiness result.

WF-05 routes a platform scenario directly to PRODUCT-OWNER at Step 2b and skips all
`2a-*` BO sign-off steps. If the run includes a non-platform scenario requiring a
`BO-*` sign-off, the relevant `2a-*` steps run normally; platform routing must not
suppress tenant-domain evaluation.

---

## Edit list

The six blocks below are the BACKEND-DEV work. Each block lists the file,
the anchor in the current file, the before-text, the after-text, and the
§7 row that mandates the change.

### Consumer 1 — `docs/agents/UAT_RUNNER.md`

#### §7 row: UAT-RUNNER

> Accept `company_id: platform`; resolve credentials from `BPM_UAT_TOKEN`
> instead of the company lookup. Accept `via: system` and `system_state`.
> Enforce the `uat_surface` table in §3. Require `evidence` on every
> `system_state` outcome.

There are four edits inside UAT_RUNNER.md.

---

**Edit 1.1 — Pre-flight check (`Step 1`)**

*Anchor.* `## 4. Execution workflow` → `### Step 1 — Pre-flight check`.
The block that today does a `for slug in swiftroute vortex meridian`
tenant-API loop.

*Before (current Step 1, second sub-block).*

```text
Additionally, verify the tenant lookup endpoint:

  # Tenant API (must return 200 for each seed company)
  for slug in swiftroute vortex meridian; do
    curl -sf -H "Authorization: Bearer $BPM_UAT_TOKEN" \
      http://localhost:3000/api/v1/tenants/$slug > /dev/null || echo "TENANT_${slug}_MISSING"
  done

If any `TENANT_*_MISSING`: STOP. Return FAIL with severity BLOCKER.
Message: `"Tenant API returned 404 for <slug>. Ensure seed data includes all companies."`
```

*After (Step 1, second sub-block).*

```text
Additionally, classify scenarios by `company_id` and verify only the tenant
slugs that are actually present in the scenario set:

  # Collect the unique tenant slugs actually used by the scenarios in this run
  tenant_slugs=$(python3 -c "
  import yaml, glob
  slugs = set()
  for path in glob.glob('tests/simulation/scenarios/*.yaml'):
      with open(path) as f:
          s = yaml.safe_load(f)
      cid = s.get('company_id')
      if cid in ('swiftroute','vortex','meridian'):
          slugs.add(cid)
  print(' '.join(sorted(slugs)))
  ")

  for slug in $tenant_slugs; do
    curl -sf -H "Authorization: Bearer $BPM_UAT_TOKEN" \
      http://localhost:3000/api/v1/tenants/$slug > /dev/null || echo "TENANT_${slug}_MISSING"
  done

If any `TENANT_*_MISSING`: STOP. Return FAIL with severity BLOCKER.
Message: `"Tenant API returned 404 for <slug>. Ensure seed data includes all companies."`

Scenarios with `company_id: platform` MUST NOT be added to `$tenant_slugs`
above — the tenant endpoint returns 404 for `platform` by design. For
`platform` scenarios, credential resolution is handled later in Step 2.5
from `BPM_UAT_TOKEN` directly, without a tenant lookup.
```

*Rationale.* First half of §7's `UAT-RUNNER` row — "resolve credentials
from `BPM_UAT_TOKEN` instead of the company lookup" requires UAT-RUNNER to
not call the tenant endpoint for `platform` slugs.

---

**Edit 1.2 — Resolve tenant context (`Step 2.5`)**

*Anchor.* `### Step 2.5 — Resolve tenant context`. The block that today
calls `resolveTenantContext` for every unique slug.

*Before (current Step 2.5).*

```text
Before executing any scenario, resolve each unique `company_id` into a
`TenantContext` via `resolveTenantContext()` from `pipeline.ts`:

  [code snippet calling resolveTenantContext(request, slug, adminToken)]

If `resolveTenantContext()` throws (404 or network error): add a BLOCKER
issue for that scenario and skip it. Do not abort the entire run.
```

*After (Step 2.5).*

```text
Before executing any scenario, resolve each unique `company_id` into a
`TenantContext` via `resolveTenantContext()` from `pipeline.ts`:

  [code snippet calling resolveTenantContext(request, slug, adminToken)]

For `company_id: platform`: SKIP the tenant lookup. The platform operator
identity comes from `BPM_UAT_TOKEN` (already validated in Step 1); the
`TenantContext` for `platform` scenarios is `{ realm: null, tenantId:
'platform', tokenUrl: $BPM_UAT_TOKEN }`. `realm` is null because there is
no per-tenant realm for platform actions; all platform actor credentials
are issued against the platform operator client.

If `resolveTenantContext()` throws for a non-platform slug (404 or network
error): add a BLOCKER issue for that scenario and skip it. Do not abort
the entire run.
```

*Rationale.* Second half of §7's `UAT-RUNNER` row — "resolve credentials
from `BPM_UAT_TOKEN` instead of the company lookup" for `platform`
scenarios. The branch must live before the throw handling, because the
`platform` slug is not a real tenant and would otherwise throw on every
platform scenario.

---

**Edit 1.3 — Step 3 "Execute each scenario" (extend to cover system steps)**

*Anchor.* `### Step 3 — Execute each scenario` → bullet 1
("Executes scenario steps through the browser"). The list of numbered
bullets today is four items; this edit adds a fifth.

*Before (bullet 1, current text).*

```text
1. **Executes scenario steps through the browser** — runs the Playwright pipeline test
   that matches the scenario `id` (`web/tests/e2e/pipelines/<id>.pipeline.e2e.spec.ts`).
   Every step marked `via: gui` is performed by Playwright navigating the actual browser UI.
   There is no fallback to direct API calls for steps a business user would perform.
   If no matching Playwright pipeline test exists: STOP. Record BLOCKER issue:
   _"No UI pipeline test found for scenario <id>. The GUI for this process has not been
   implemented. ORCH must route to FRONTEND-DEV."_
```

*After (Step 3 execution additions).* The existing GUI bullet remains unchanged.
Add a separate `via: system` path: for a step whose actor is `actor-system-*` or
whose `via` is `system`, UAT-RUNNER invokes the platform operator endpoint named by
`produces` (or advances the virtual clock). It reuses `BPM_UAT_TOKEN`, does not obtain
a credential for the system actor, and records the invoked endpoint and payload as
business-readable evidence under `expected_outcomes[*].verification.evidence`.

*Rationale.* Second half of §7's `UAT-RUNNER` row — "Accept `via: system` and
`system_state`". The addendum §3 defines the execution semantics and §5 defines the
actor naming. This gives system steps an execution path without weakening the v1.0
rule that a human action must use the GUI.

---

**Edit 1.4 — Schema validation (`Step 2`) — add the nine rejection rules**

*Anchor.* `### Step 2 — Load and validate scenarios`. The Python snippet
today asserts only the v1.0 required fields (`id`, `company_id`, `title`,
`actors`, `steps`, `expected_outcomes`).

*Before (current Step 2 snippet).*

```python
  for field in ("id", "company_id", "title", "actors", "steps", "expected_outcomes"):
      assert field in s, f"{path}: missing '{field}'"
  scenarios.append(s)
```

*After (Step 2 snippet — replace with the v1.0+v1.1 check, split across two
named passes for legibility).* The first pass enforces the v1.0 required fields
and the structural v1.1 rules from addendum §8.

```python
  # Pass 1 — v1.0 required fields and v1.1 structural rules (addendum §8).
  for field in ("id", "company_id", "title", "actors", "steps", "expected_outcomes"):
      assert field in s, f"{path}: missing '{field}'"

  if s["company_id"] not in ("platform", "swiftroute", "vortex", "meridian"):
      raise ValueError(f"{path}: company_id must be one of platform|swiftroute|vortex|meridian")
  if s["company_id"] == "platform" and "platform_workflow" not in s:
      raise ValueError(f"{path}: platform scenarios require platform_workflow")
  if "platform_workflow" in s and s["platform_workflow"] not in PLATFORM_WORKFLOWS:
      raise ValueError(f"{path}: platform_workflow {s['platform_workflow']} not in docs/workflows.yaml")
  uat_surface = PLATFORM_WORKFLOWS[s.get("platform_workflow")]["uat_surface"] \
                if "platform_workflow" in s else "mixed"
  via_values = [step["via"] for step in s["steps"]]
  if uat_surface == "gui" and "system" in via_values:
      raise ValueError(f"{path}: via: system forbidden when uat_surface is gui")
  if uat_surface in ("gui", "mixed") and "gui" not in via_values:
      raise ValueError(f"{path}: workflow with uat_surface={uat_surface} must contain at least one via: gui step")
  for eo in s["expected_outcomes"]:
      v = eo["verification"]
      if v["method"] == "system_state" and not v.get("evidence", "").strip():
          raise ValueError(f"{path}: system_state outcome requires non-empty evidence")
  for step in s["steps"]:
      if step["actor"].startswith("actor-system-") and step["via"] != "system":
          raise ValueError(f"{path}: actor-system-* actors may only appear on via: system steps")
```

The second pass enforces the report-language rule (addendum §4) and only runs
once the structural pass above has accepted the scenario.

```python
  # Pass 2 — report-language rule (addendum §4). Reject stack traces,
  # selectors, file paths with line numbers, SQL, Zig/TypeScript names.
  if contains_technical_leak(s.get("description", "")):
      raise ValueError(f"{path}: technical language in description violates report-language rule")
  for eo in s["expected_outcomes"]:
      for fld in ("description", "business_impact"):
          if contains_technical_leak(eo.get(fld, "")):
              raise ValueError(f"{path}: technical language in expected_outcomes.{fld}")
      v = eo["verification"]
      if contains_technical_leak(v.get("detail", "")):
          raise ValueError(f"{path}: technical language in verification.detail")
      if v["method"] == "system_state" and contains_technical_leak(v.get("evidence", "")):
          raise ValueError(f"{path}: technical language in verification.evidence")
  scenarios.append(s)
```

*Rationale.* Third half of §7's `UAT-RUNNER` row — "Enforce the
`uat_surface` table in §3. Require `evidence` on every `system_state`
outcome." The nine rules are §8 of the addendum verbatim; they map to the
malformed-scenario path that already exists in UAT-RUNNER's Step 2.

---

**Edit 1.5 — §9 Scenario YAML schema — extend the field table**

*Anchor.* `## 9. Scenario YAML schema`. The current section ends with a
short YAML example showing v1.0 fields. The change adds a one-paragraph
note pointing readers at the v1.1 addendum.

*Before (current last paragraph of §9).*

```text
See `docs/agents/uat-scenario-schema.md` for the complete schema and
annotated examples. Key fields:

  [yaml example with id/company_id/title/process_id/description/actors/
   preconditions/steps/expected_outcomes/tags]
```

*After (extend with a v1.1 cross-reference).*

```text
See `docs/agents/uat-scenario-schema.md` (v1.0) for the complete base
schema and annotated examples, and
`docs/agents/uat-scenario-schema-v1.1-addendum.md` for the additive
platform-workflow fields (`company_id: platform`, `platform_workflow`,
`via: system`, `verification.method: system_state` with mandatory
`evidence`, `actor-system-*` actors). The v1.1 addendum restates the
report-language rule unchanged: every `description`, `detail`, `evidence`
and `business_impact` field must be readable by a non-technical
stakeholder. Stack traces, Playwright selectors, file paths with line
numbers, SQL queries, and Zig or TypeScript function names are forbidden.

Key v1.0 fields:

  [yaml example unchanged]
```

*Rationale.* The §9 field table is the place every reader lands when they
go to "what fields does UAT-RUNNER read?". Adding the v1.1 cross-reference
keeps the discovery path intact without duplicating the addendum's
content.

---

### Consumer 2 — `docs/agents/PRODUCT_OWNER.md`

#### §7 row: PRODUCT-OWNER

> Evaluate `company_id: platform` scenarios directly; do not wait for
> `BO-*` sign-off files for those. Reject any `system_state` outcome with
> an empty `evidence` field.

There are three edits inside PRODUCT_OWNER.md.

---

**Edit 2.1 — Step 1 ("Read all BO sign-off reports") — make BO sign-off conditional**

*Anchor.* `## 5. Execution workflow` → `### Step 1 — Read all BO sign-off reports`.
Today this step raises if `swiftroute`, `vortex`, or `meridian` is missing.

*Before (current Step 1).*

```python
  signoffs = {}
  for path in Path("tests/uat-reports").glob(f"bo-signoff-*-{run_id}.yaml"):
      with open(path) as f:
          signoffs[path.stem.split("-")[2]] = yaml.safe_load(f)

  # Expect: swiftroute, vortex, meridian
  missing = {"swiftroute", "vortex", "meridian"} - set(signoffs.keys())
  if missing:
      raise RuntimeError(f"Missing BO sign-off(s): {missing}")
```

*After (Step 1 — branch on platform scenarios).*

```python
  import yaml
  from pathlib import Path

  signoffs = {}
  for path in Path("tests/uat-reports").glob(f"bo-signoff-*-{run_id}.yaml"):
      with open(path) as f:
          signoffs[path.stem.split("-")[2]] = yaml.safe_load(f)

  # Determine whether ANY scenario in this run is a platform scenario.
  # Platform scenarios are evaluated by PRODUCT-OWNER directly; they do
  # NOT require BO-* sign-off files (BO-* never receive them).
  with open(f"tests/uat-reports/uat-{date}-{run_id}.yaml") as f:
      uat = yaml.safe_load(f)
  has_platform = any(s.get("company_id") == "platform" for s in uat["scenarios"])

  if has_platform:
      # Platform scenarios are present; BO-* sign-offs are still required
      # for any non-platform scenarios in the run.
      non_platform = {s["company_id"] for s in uat["scenarios"] if s["company_id"] != "platform"}
      missing = non_platform - set(signoffs.keys())
      if missing:
          raise RuntimeError(f"Missing BO sign-off(s) for non-platform scenarios: {missing}")
  else:
      # Tenant-only run; all three BO sign-offs are mandatory.
      missing = {"swiftroute", "vortex", "meridian"} - set(signoffs.keys())
      if missing:
          raise RuntimeError(f"Missing BO sign-off(s): {missing}")
```

*Rationale.* First half of §7's `PRODUCT-OWNER` row — "Evaluate
`company_id: platform` scenarios directly; do not wait for `BO-*` sign-off
files for those." The current `RuntimeError` would block every WF-05 run
that contains a single platform scenario, because the three BO-* agents
will never produce a sign-off for a scenario none of their personas own.

---

**Edit 2.2 — Step 2 ("Check platform requirement coverage") — reject empty evidence**

*Anchor.* `### Step 2 — Check platform requirement coverage`. The current
text describes MUST-requirement coverage; the change inserts an additional
hard-reject pass for `system_state` outcomes with empty `evidence`.

*Before (current Step 2 prose).*

```text
For each MUST requirement in the current stage: verify at least one scenario
across the three companies exercises it. A requirement with no UAT scenario
coverage is a MAJOR issue even if TEST-RUNNER passed.
```

*After (Step 2 prose — add a new sub-paragraph after the existing one).*

```text
For each MUST requirement in the current stage: verify at least one scenario
across the three companies exercises it. A requirement with no UAT scenario
coverage is a MAJOR issue even if TEST-RUNNER passed.

Additionally, for every `system_state` outcome across all scenarios in the
UAT report: confirm `verification.evidence` is non-empty. The evidence
field is required by the v1.1 addendum (§4); without it, the runner's
evidence trail is whatever it captured ad hoc, which a non-technical
reviewer cannot read or verify. An empty `evidence` field on any
`system_state` outcome is a MAJOR issue — even if the scenario's overall
verdict is PASS — and blocks the release. The issue's
`suggested_action` is `route_to_uat_runner` with instruction to obtain
the missing evidence (screenshot, status endpoint payload, log line, or
row count) and re-run.
```

*Rationale.* Second half of §7's `PRODUCT-OWNER` row — "Reject any
`system_state` outcome with an empty `evidence` field." This is a
hard-reject at the PO layer (not just a MAJOR issue at the runner layer);
the runner already rejects malformed scenarios in its own schema check
(Edit 1.4), but PO must catch the case where the runner was bypassed or
where the field was stripped post-validation.

---

**Edit 2.3 — §1 "Position in the quality hierarchy" — note platform path**

*Anchor.* `## 1. Purpose` → `### Position in the quality hierarchy`. The
ASCII tree today shows `PRODUCT-OWNER` over three BOs; the change inserts
a note about platform scenarios skipping the BO layer.

*Before (current tree).*

```text
PRODUCT-OWNER       →  "Should we ship this?" (cross-tenant coherence)
  ├── BO-SWIFTROUTE →  "Does this serve SwiftRoute?" (logistics domain)
  ├── BO-VORTEX     →  "Does this serve Vortex?" (manufacturing domain)
  └── BO-MERIDIAN   →  "Does this serve Meridian?" (regulated lending domain)
```

*After (extend the tree with a note).*

```text
PRODUCT-OWNER       →  "Should we ship this?" (cross-tenant coherence)
  ├── BO-SWIFTROUTE →  "Does this serve SwiftRoute?" (logistics domain)
  ├── BO-VORTEX     →  "Does this serve Vortex?" (manufacturing domain)
  └── BO-MERIDIAN   →  "Does this serve Meridian?" (regulated lending domain)

For `company_id: platform` scenarios, the three BO-* agents are not in the
chain — no business persona owns platform workflows. PRODUCT-OWNER
evaluates platform scenarios directly. See the v1.1 addendum
(§"Why this addendum exists", §"Changes required in consuming agents").
```

*Rationale.* First half of §7's `PRODUCT-OWNER` row — the discovery path.
Without this note, a reader lands on the tree and infers that BO-*
sign-off is always required; the gate logic in Edit 2.1 would then read
as a special case. The note establishes the rule up front.

---

### Consumer 3 — `docs/agents/ORCHESTRATOR.md`

#### §7 row: ORCH

> Before dispatching WF-05, run `python3 tools/wfctl.py uat-ready <PW-nn>`;
> a non-zero exit means the workflow is not eligible. Use the printed
> dispatch block as the handoff context.

There is one edit (with one optional follow-on).

---

**Edit 3.1 — New §8e "Platform-Workflow UAT Gate" — add after §8d**

*Anchor.* Insert a new section immediately after `## 8d. Project Board
Status` and before `## 9. Orchestrator Log`.

*Before (current boundary — the end of §8d).*

```text
**ORCH does not call the tool directly** — it is invoked by the agent executing the
relevant step (BACKEND-DEV/FRONTEND-DEV at claim and merge, UAT-RUNNER at validation),
the same way `fn:register-issue` is threaded through existing steps rather than being
its own row in a pipeline table. ORCH's only obligation is to not treat a board-update
failure as a run failure — it never is one.

---
```

*After (insert the new §8e between §8d and §9).* Preserve the existing §8d
boundary, then add **§8e Platform-Workflow UAT Gate** between §8d and §9.

The existing §8d boundary remains unchanged:

> **ORCH does not call the tool directly** — it is invoked by the agent executing the
> relevant step (BACKEND-DEV/FRONTEND-DEV at claim and merge, UAT-RUNNER at
> validation), the same way `fn:register-issue` is threaded through existing steps
> rather than being its own row in a pipeline table. ORCH's only obligation is to not
> treat a board-update failure as a run failure — it never is one.

**§8e. Platform-Workflow UAT Gate (BEFORE Dispatching WF-05).** Before ORCH dispatches
WF-05 (UAT Run) against a platform workflow (`PW-nn` in `docs/workflows.yaml`), it
MUST verify the workflow is UAT-ready: `python3 tools/wfctl.py uat-ready <PW-nn>`.

**Exit 0 → CLEARED.** Log `BENCH_ENV_CHECK`-style line:
`<ISO8601> | UAT_READY | <RUN-ID> | --- | ORCH | CLEARED: <PW-nn> — dispatching WF-05`
Then proceed to WF-05 dispatch. The tool prints a JSON dispatch block (workflow id,
scenarios expected, uat_surface, owning BO list — usually empty for platform); copy
that block into the WF-05 Step 1 handoff's `context.artifacts_in` so UAT-RUNNER does
not need to re-resolve it.

**Non-zero exit → BLOCKED.** The tool prints the missing scenarios or preconditions.
Log: `<ISO8601> | UAT_READY | <RUN-ID> | --- | ORCH | BLOCKED: <PW-nn> — <reason>`.
Do NOT dispatch WF-05. File each missing precondition as its own issue (ISS file +
GitHub issue, per CLAUDE.md "No Issue Left Local-Only") and forward to the global
queue per §8c. Then stop this WF-05 dispatch attempt; the operator decides whether to
launch a WF-06 (scenario authoring) run to add the missing scenarios, or to defer the
UAT.

**Judge this gate by the exit code only.** Never phrase a handoff task as "make X stop
appearing in the output of `wfctl.py uat-ready`" — the same trap that produced the
2026-05-30 label-renaming incident (see `docs/anti-patterns.md`). If the gate's
definition is wrong, change the definition in `tools/wfctl.py`; do not arrange for it
to pass. The §8e gate mirrors §8a in shape (hard pre-flight gate, exit-code-only
verdict, log-line on both branches, ADHOC handoff if blocked) so operators who learned
§8a already know §8e.

*Rationale.* The §7 `ORCH` row verbatim — "Before dispatching WF-05, run
`python3 tools/wfctl.py uat-ready <PW-nn>`; a non-zero exit means the
workflow is not eligible. Use the printed dispatch block as the handoff
context." Modelling §8e on §8a reuses the protocol operators already
trust (CLEARED / BLOCKED log lines, exit-code-only judgement) so the
gate does not introduce a new pattern that operators need to learn.

---

### Consumer 4 — `docs/agents/workflows/WF-05_uat_run.md`

#### §7 row: WF-05

> Add `platform_workflow` to the run context. When it is set and
> `company_id` is `platform`, skip steps 2a-sr / 2a-vx / 2a-mc and go
> straight to 2b (`PRODUCT-OWNER`).

There are three edits inside WF-05_uat_run.md.

---

**Edit 4.1 — §3 Pipeline — note the platform branch**

*Anchor.* `## 3. Pipeline`. The step table today lists Steps 00, 1,
2a-sr/vx/mc, 2b, 2c, 3, 4, Final.

*Before (current row of the pipeline table for 2a-sr).*

```text
| **2a-sr** | `BO-SWIFTROUTE` | — | Domain sign-off: SwiftRoute scenarios + authored fixes if needed |
```

*After (insert a new row immediately before Step 2b).*

```text
| **2a-sr** | `BO-SWIFTROUTE` | — | Domain sign-off: SwiftRoute scenarios + authored fixes if needed |
| **2a-vx** | `BO-VORTEX`     | — | Domain sign-off: Vortex scenarios + authored fixes if needed |
| **2a-mc** | `BO-MERIDIAN`   | — | Domain sign-off: Meridian scenarios + quorum vote |
| **2a-platform** | *(skip)* | Routing gate | When the run carries `platform_workflow` and the scenario set includes any `company_id: platform` scenario, skip Steps 2a-sr / 2a-vx / 2a-mc and proceed straight to 2b. Log: `<ts> \| SKIP-BO \| <run_id> \| --- \| ORCH \| platform_workflow <PW-nn> — BO-* sign-off not required` |
| **2b**    | `PRODUCT-OWNER` | **Hard gate** | Cross-tenant coherence + MUST coverage + final release recommendation. **For platform workflows, PRODUCT-OWNER evaluates the platform scenarios directly with no preceding BO sign-off.** |
```

*Rationale.* First half of §7's `WF-05` row — "Add `platform_workflow` to
the run context." The pipeline table is the canonical map; a `2a-platform`
gate row makes the skip behaviour visible without forcing the reader to
parse prose.

---

**Edit 4.2 — §4 Step 1 — populate `platform_workflow` into handoff context**

*Anchor.* `### Step 1 — UAT execution (UAT-RUNNER)`. The current handoff
task example shows `description`, `acceptance_criteria`, and
`functions_to_call`; the change adds the new `platform_workflow` context
field.

*Before (current Step 1 handoff task example).*

```json
  {
    "description": "Execute all UAT scenarios under tests/simulation/scenarios/. Evaluate each outcome against business expectations. Produce a UAT report in tests/uat-reports/.",
    "acceptance_criteria": [
      "Pre-flight check passes (backend + Keycloak + seed data present)",
      ...
    ],
    "functions_to_call": [
      "fn:run-uat-scenarios",
      ...
    ]
  }
```

*After (extend the JSON block with a new `context.platform_workflow` field).*

```json
  {
    "description": "Execute all UAT scenarios under tests/simulation/scenarios/. Evaluate each outcome against business expectations. Produce a UAT report in tests/uat-reports/.",
    "context": {
      "platform_workflow": "<PW-nn if this WF-05 run targets a platform workflow; omit otherwise>",
      "uat_surface": "<gui | mixed | system — from docs/workflows.yaml>"
    },
    "acceptance_criteria": [
      "Pre-flight check passes (backend + Keycloak + seed data present)",
      "For company_id: platform scenarios: BPM_UAT_TOKEN is the sole credential (no tenant lookup)",
      ...
    ],
    "functions_to_call": [
      "fn:run-uat-scenarios",
      ...
    ]
  }
```

*Rationale.* First half of §7's `WF-05` row. ORCH populates
`platform_workflow` from the §8e gate's printed dispatch block; the
runner reads it to know whether to skip the BO branch in Step 4.2.

---

**Edit 4.3 — §4 Step 2 — gate the BO-* dispatch on `company_id`**

*Anchor.* `### Step 2 — ORCH routing gate`. The current Step 2 routes to
BO-* after UAT-RUNNER. The change inserts a routing branch above the
existing routing logic.

*Before (current Step 2 prose).*

```text
UAT-RUNNER result determines Step 2 routing:
- `PASS` → proceed to Step 3
- `FAIL` (any BLOCKER or MAJOR) → ORCH files each failing scenario's issue ...
- `PARTIAL` → same handling per severity; MINORs are logged only
```

*After (Step 2 prose — insert platform-routing branch).*

```text
UAT-RUNNER result determines Step 2 routing:
- `PASS` → proceed to Step 3
- `FAIL` (any BLOCKER or MAJOR) → ORCH files each failing scenario's issue ...
- `PARTIAL` → same handling per severity; MINORs are logged only

**Platform-workflow branch.** Before dispatching BO-SWIFTROUTE / BO-VORTEX /
BO-MERIDIAN, ORCH inspects `tests/uat-reports/uat-<date>-<run_id>.yaml`:

  if any scenario in the UAT report has `company_id: platform`:
      log: <ts> | SKIP-BO | <run_id> | --- | ORCH | platform_workflow <PW-nn> — BO-* sign-off not required
      skip Steps 2a-sr / 2a-vx / 2a-mc
      proceed straight to Step 2b (PRODUCT-OWNER)
  else:
      dispatch BO-SWIFTROUTE / BO-VORTEX / BO-MERIDIAN in parallel as today
```

*Rationale.* Second half of §7's `WF-05` row — "When it is set and
`company_id` is `platform`, skip steps 2a-sr / 2a-vx / 2a-mc and go
straight to 2b (`PRODUCT-OWNER`)." The routing gate is the right place —
Step 2 already exists as the dispatch decision point.

---

### Consumer 5 — `docs/agents/workflows/WF-06_scenario_authoring.md`

#### §7 row: WF-06

> Allow `REQ-ANALYST` as an author for `company_id: platform` scenarios,
> since no `BO-*` persona owns them.

There are two edits inside WF-06_scenario_authoring.md.

---

**Edit 5.1 — §3 Pipeline — change author selection logic**

*Anchor.* `## 3. Pipeline`. The current table lists `BO-<COMPANY>` for
Step 1, `UAT-RUNNER` for Step 1b, `BO-<COMPANY>` for Step 2, `ORCH` for
Step 3.

*Before (current Step 1 row).*

```text
| **1** | `BO-<COMPANY>` | — | Author scenario YAML from brief |
```

*After (Step 1 row — note that REQ-ANALYST authors platform scenarios).*

```text
| **1** | `BO-<COMPANY>` *(or `REQ-ANALYST` for `company_id: platform`)* | — | Author scenario YAML from brief. **For platform workflows, no BO-* persona owns the workflow; ORCH dispatches `REQ-ANALYST` instead — the same agent that authors requirements — because the platform scenarios are specifications rather than business-stakeholder narratives.** |
```

*Rationale.* §7's `WF-06` row verbatim. The pipeline table is the
authoritative agent-per-step list; the parenthetical disambiguates the
case the addendum §1 introduces.

---

**Edit 5.2 — §5 Trigger recognition — branch the trigger on `company_id`**

*Anchor.* `## 5. Trigger recognition`. The current text describes three
trigger conditions; the third one already covers PO-flagged uncovered
MUST requirements. The change adds a fourth trigger for platform
workflows.

*Before (current third trigger bullet).*

```text
3. After WF-05 completes and PRODUCT-OWNER flags an uncovered MUST requirement:
   [yaml example]
   ORCH spawns WF-06 for each uncovered requirement.
```

*After (extend with a fourth trigger).*

```text
3. After WF-05 completes and PRODUCT-OWNER flags an uncovered MUST requirement:
   [yaml example]
   ORCH spawns WF-06 for each uncovered requirement.

4. When a new platform workflow (`PW-nn` in `docs/workflows.yaml`) is
   added, and that workflow has at least one scenario slot in its
   `uat_scenarios` list but no scenario file under
   `tests/simulation/scenarios/`:
   ORCH dispatches `REQ-ANALYST` (not a `BO-*` agent) to author the
   scenarios. The handoff sets `context.target_company_id: platform` and
   links to the v1.1 addendum as the authoritative schema. REQ-ANALYST
   writes the YAML using the same shape as BO-* agents — only the author
   differs.
```

*Rationale.* The §7 row allows REQ-ANALYST to author; this trigger
defines when that happens (a platform workflow slot without a scenario
file). Without the trigger, REQ-ANALYST would never be picked — the
current Step 1 row says `BO-<COMPANY>`, and no BO matches `platform`.

---

### Consumer 6 (optional) — `CLAUDE.md` and any orchestrator routing table

#### §7 row: not present — optional per the issue brief

There is one edit (a one-line pointer), which is **optional** but
recommended because `CLAUDE.md` is the file every agent reads at session
start.

---

**Edit 6.1 — Add a one-line pointer to the v1.1 addendum**

*Anchor.* `CLAUDE.md` → the section listing every agent's mandatory
reading. The pointer is a single line in a list near the top of the file.

*Before (current text — exact context not asserted here; the change is
additive).*

The current text is the agent roster / mandatory-reading list. No
removal — only an insertion.

*After (insert one line — exact wording TBD by BACKEND-DEV at edit time,
but the substantive content is).*

```text
- UAT scenario authoring agents must read `docs/agents/uat-scenario-schema-v1.1-addendum.md` alongside `docs/agents/uat-scenario-schema.md` — the addendum is additive and applies to every `company_id: platform` scenario, every `via: system` step, and every `system_state` verification.
```

*Rationale.* Discoverability was the issue identified in ISS-0085's
`prevention` array — INSTALL_platform_workflows.md and
RUNBOOK_platform_workflows.md cross-link the addendum and that masked the
gap. CLAUDE.md is the canonical session-start reading list; adding the
pointer there guarantees every agent learns of the addendum regardless of
which runbook they happen to be in.

---

## Acceptance criteria (what BACKEND-DEV verifies after editing)

1. **UAT_RUNNER.md** carries (a) the platform-aware pre-flight branch
   (Edit 1.1), (b) the `BPM_UAT_TOKEN` credential branch in Step 2.5
   (Edit 1.2), (c) the `via: system` execution path (Edit 1.3), (d) the
   nine-rule schema check (Edit 1.4), and (e) the v1.1 cross-reference in
   §9 (Edit 1.5).
2. **PRODUCT_OWNER.md** carries (a) the conditional BO-sign-off check
   (Edit 2.1), (b) the empty-evidence hard-reject pass (Edit 2.2), and (c)
   the platform-path note in the quality hierarchy (Edit 2.3).
3. **ORCHESTRATOR.md** has a new §8e "Platform-Workflow UAT Gate" with
   the `python3 tools/wfctl.py uat-ready <PW-nn>` exit-code-only gate
   (Edit 3.1).
4. **WF-05_uat_run.md** carries (a) the `2a-platform` skip row in §3
   (Edit 4.1), (b) the `context.platform_workflow` field in the Step 1
   handoff example (Edit 4.2), and (c) the platform-routing branch in
   Step 2 (Edit 4.3).
5. **WF-06_scenario_authoring.md** carries (a) the REQ-ANALYST Step 1
   row (Edit 5.1) and (b) the fourth trigger condition (Edit 5.2).
6. **CLAUDE.md** carries the one-line pointer (Edit 6.1 — optional).
7. After all edits, `git diff --name-only HEAD~1` shows only the five
   (or six, if 6.1 lands) consumer docs and no other files — this is a
   docs-only change and any Zig/SQL/TS file in the diff is a defect.
8. `git diff --stat HEAD~1` shows only prose (Markdown) line changes; no
   code-coverage markers (`// ...existing code...`, `// CUSTOM:`, etc.)
   are appropriate here because there is no codegen involvement.
9. `python3 tools/lint_handoffs.py` exits 0 (BACKEND-DEV's handoff must
   pass this gate per CLAUDE.md §"Bookkeeping Is Not Optional").
10. `docs/agents/uat-scenario-schema.md` (v1.0) is **unchanged** — the
    addendum is additive and v1.0 scenarios must remain valid unchanged
    (invariant #1 above).
11. None of the three BO-* agent docs (`BO-SWIFTROUTE.md`, `BO-VORTEX.md`,
    `BO-MERIDIAN.md`) is touched — §7 explicitly says no change for them.

---

## Acceptance criteria (the original handoff's three items, mapped)

The handoff's three acceptance criteria map to this artefact as follows:

| Handoff criterion | Satisfied by |
|---|---|
| `src/design/uat-scenario-schema-v1.1-apply.md` exists and covers all 5 consumers from §7 | The file (this artefact) and §§Consumer 1–5 above |
| Each consumer has: anchor location, before/after text, rationale | Edit blocks 1.1–5.2; each block has Anchor / Before / After / Rationale |
| No implementation code (Zig/SQL) — this is a prose design for a docs-only change | No Zig, no SQL, no TypeScript anywhere in this file. The design is prose; BACKEND-DEV's Step 3 will use replace-string-in-file on Markdown. |
