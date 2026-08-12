# Lego Catalog — Reusable Implementation Templates

**Purpose:** Reduce design and implementation cost by classifying work into reusable patterns ("Lego pieces") that lower-capability models can instantiate from a small parameter file, instead of re-deriving boilerplate from prose.

**Audience:** CODE-DESIGNER (decides classification), BACKEND-DEV / FRONTEND-DEV (consumes parameter files via codegen), CODE-DESIGN-VALIDATOR (verifies classification was applied).

---

## How design classification works (WF-02 Step 1)

For every requirement (or coherent group of requirements) in the handoff, CODE-DESIGNER classifies it as **Type A–E**:

| Type | Pattern | Output | Time budget |
|---|---|---|---|
| **A** | Standard CRUD HTTP endpoint | `templates/specs/<name>.crud-endpoint.yaml` parameter file | 10 min |
| **B** | Standard list page + filter form + table | `templates/specs/<name>.list-page.yaml` parameter file | 10 min |
| **C** | Standard DB migration + integration test pair | `templates/specs/<name>.migration.yaml` parameter file | 10 min |
| **D** | Standard React Flow custom node | `templates/specs/<name>.react-flow-node.yaml` parameter file | 5 min |
| **E** | Novel / business-logic / cross-cutting | Full `src/design/<module>.md` artefact (existing format) | 30–60 min |

A single requirement may decompose into mixed types — e.g. "add config repository" = Type C migration + Type A CRUD endpoint + Type E novel store logic. List each parameter file under `artifacts_out` in the handoff result.

---

## Selection rules — answer in order

Pick the **first** type whose rule matches; do not over-classify.

1. **Type C** if the requirement adds, alters, or removes a database table/column or creates a new migration. (Migration spec also pulls in matching integration test scaffold.)
2. **Type A** if the requirement adds a new HTTP route (`POST/PUT/PATCH/GET/DELETE`) that maps 1-to-1 onto a store method. (Skip if the handler needs custom business logic mid-flight — that is Type E.)
3. **Type D** if the requirement adds a new React Flow node type (start, end, gateway, task, etc.). One YAML per node type.
4. **Type B** if the requirement adds a new admin/list page with the shape: query → table → row actions → optional create form. (Skip if the page needs custom interactions — that is Type E.)
5. **Type E** otherwise. Write the full design artefact.

When in doubt, prefer Type E. A wrongly-classified Type A masquerading as Type E only wastes design time; a Type E forced into Type A masks real complexity from BACKEND-DEV.

### Partial-fit: when does CUSTOM-block deviation tip into Type E?

The Lego types (A, B, C, D) allow a bounded amount of custom logic through `// CUSTOM:` blocks. The question is how much deviation is still within budget before the requirement should be reclassified Type E.

**Still acceptable within Type A/B/D (stay in the template):**
- The handler calls one store method and then needs non-trivial input validation before the call (empty-string check, length limit, UUID format) — isolatable to a single `// CUSTOM:` block.
- The table column needs a badge colour map that can't be derived from the column name alone — one `// CUSTOM:` block in the generated TSX.
- A row action needs a bespoke navigation target (not archive/delete) — one `// CUSTOM:` block.
- The migration test case needs a non-trivial assertion (checking a derived column, verifying a constraint fires) — the assertion goes in the `// CUSTOM:` block that codegen already reserves for it.

**Tip into Type E (reclassify):**
- The handler calls more than one store method in sequence, or coordinates with a second module (e.g. emitting an audit event, triggering a saga step).
- The handler's error-to-status mapping is context-dependent (the same error variant maps to different status codes depending on request state).
- The list page needs a non-trivial client-side aggregation or a second API call to populate a column.
- The create form has conditional field visibility or multi-step submission.
- The migration needs a data backfill (DML mixed with DDL) beyond what the `sql_setup` fixture mechanism covers.
- Any `// CUSTOM:` block would need to be longer than ~15 lines or would need to import a module not already present in the generated file.

**Worked partial-fit example:**  
Requirement PD-10 (definition full-text search) uses `operation: custom` in its Type A spec because the handler needs two validation checks (`q` empty → 422, `q` > 512 chars → 422) before calling `store.search`. Both checks fit in a single `// CUSTOM:` block and call only one store method. This stays Type A.

If PD-10 had also needed to log each search query to an audit store (a second module call) and adjust the result ranking based on a per-tenant configuration lookup (a third call with conditional logic), the handler would have been reclassified Type E — the complexity would have overflowed the `// CUSTOM:` model entirely.

---

## What stays in Type E (never templated)

- Engine kernel, transition logic, deterministic replay
- Auth / identity / OIDC flows
- Audit chain / tamper-evident logic
- Cross-module orchestration sagas (e.g. tenant onboarding)
- Anything performance-sensitive (NFR benchmarks attached)
- Assertion logic in integration tests (template generates scaffold + fixture only — see `templates/migration.schema.md`)

---

## Template index

| Spec | Schema doc | Codegen tool | Lints input? | Status |
|---|---|---|---|---|
| `templates/specs/migration.template.yaml` | `templates/migration.schema.md` | `tools/codegen_migration.py` | yes (lint_design_artefact) | active |
| `templates/specs/crud-endpoint.template.yaml` | `templates/crud-endpoint.schema.md` | `tools/codegen_crud_endpoint.py` | yes (lint_design_artefact) | active |
| `templates/specs/list-page.template.yaml` | `templates/list-page.schema.md` | `tools/codegen_list_page.py` | yes (lint_frontend_conventions on output) | active |
| `templates/specs/react-flow-node.template.yaml` | — | `tools/codegen_react_flow_node.py` | — | active |
| `templates/specs/form-field.example.tsx` | — | — (snippet to copy) | — | reference |

Each codegen script is idempotent: re-running over the same YAML reproduces the same output, so re-classification during rework is safe.

---

## How CODE-DESIGN-VALIDATOR uses this catalog

For each Type A–D parameter file in `artifacts_out`:
1. Run the matching lint (see table above) over the YAML.
2. Run the matching codegen with `--dry-run`. Codegen must exit 0.
3. Verify the generated artefact (preview output) covers every acceptance criterion listed in the requirement.

For Type E artefacts: run `tools/lint_design_artefact.py <file>` as before.

A FAIL on any of these steps routes back to CODE-DESIGNER for rework.

---

## How implementers use this catalog

**BACKEND-DEV / FRONTEND-DEV** receive a handoff whose `context.artifacts_in` lists either:
- a Type E design file (`src/design/<module>.md`) — implement as before, or
- one or more Type A–D parameter files (`templates/specs/*.yaml`) — run the matching codegen, review the output, edit only the parts the codegen marks `// CUSTOM:` or `-- CUSTOM:`, then commit both the parameter file and the generated artefact.

Never edit generated boilerplate outside `CUSTOM` blocks. If boilerplate is wrong, fix the template — not the generated file.

### The CUSTOM: block convention in depth

Every codegen tool marks implementer-owned regions with a language-appropriate comment:

- Zig files: `// CUSTOM: <hint>` followed by a stub return or placeholder.
- SQL files: `-- CUSTOM: <hint>` inside a test case's assertion block.
- TypeScript/TSX files: `// CUSTOM: <hint>` above a colour map, action handler, or similar.

**What CUSTOM: blocks contain after code generation:**  
A short English description of what the implementer must write, plus a stub (e.g. `return errorResult(allocator, 501, "not implemented")`) that makes the file compile before the work is done. The stub exists so `zig build` or the TypeScript compiler does not fail on partially-implemented files.

**What the implementer must do inside each block:**  
Replace or augment the stub with the real logic: the store call and JSON serialisation for a handler, the assertion body for a test case, or the badge colour map for a table column. The `// CUSTOM:` comment itself must be preserved — lint checks its presence as a signal that the block was not silently deleted.

**What the implementer must NOT do:**  
Edit any line outside a `// CUSTOM:` block. If the generated boilerplate is incorrect (wrong struct shape, wrong error variant name, wrong import path), fix the parameter YAML or the codegen script and re-run codegen. Codegen is idempotent: re-running over the same YAML produces the same boilerplate and preserves the content of every `// CUSTOM:` block you have already filled in, so re-running is always safe.

**Per-type references:**  
See `templates/migration.schema.md` (Type C), `templates/crud-endpoint.schema.md` (Type A), and `templates/list-page.schema.md` (Type B) for the exact `// CUSTOM:` regions produced by each codegen tool and worked examples of filled-in blocks.

---

## Adding a new Lego piece

A pattern is a Lego candidate when it has been instantiated by hand **at least three times** with materially identical structure. Before adding:

1. List the three existing instances (file paths + line counts).
2. Identify the parameters that vary across them (these become the YAML schema).
3. Write `templates/specs/<name>.template.yaml` (worked example).
4. Write `templates/<name>.schema.md` (field-by-field doc).
5. Write `tools/codegen_<name>.py`.
6. Add a row to the template index above.
7. Update the selection rules if the new type changes them.

Do not add Lego pieces speculatively. One concrete instance is not a pattern; two might be coincidence; three is a Lego.
