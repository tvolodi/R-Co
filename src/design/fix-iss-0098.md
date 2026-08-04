# Fix Design: ISS-0098 — TC-SPT-01-07 stale expectation vs. ISS-501 no-tenant routing

## Root cause (from docs/issues/ISS-0098.json)

`TC-SPT-01-07` was written against the pre-ISS-501 SPT-01 design, where empty
tenant context was expected to resolve `search_path` to `tenant_default`. The
ISS-501 design (`src/design/iss501_storage_mode_routing.md`) deliberately
superseded that routing function and defines the no-tenant path as
`SET search_path TO public`. `src/db/pool.zig`'s `applyRequestStorageRouting()`
correctly implements ISS-501. The test was never updated when the routing
function was refactored (commit `01cf924`). This is CATEGORY E (test code
error) — no business logic changes.

## What changes

### 1. `tests/integration/spt01_provisioning_test.zig` — `TC-SPT-01-07`

- Rename the test from "pool checkout for default tenant sets search_path to
  tenant_default" to reflect the corrected expectation, e.g. "pool checkout
  with empty tenant context sets search_path to public (ISS-501 no-tenant
  path)".
- Update the preceding comment block (currently lines 435–439) to describe
  the ISS-501 no-tenant-path behavior instead of the stale SPT-01 behavior.
- Change the assertion: instead of checking `search_path` contains
  `tenant_default`, assert it resolves to `public` (mirroring the pattern
  already used in `TC-SPT-01-06`, but checking for `"public"`).
- No changes to test setup/teardown — `tenant_context.set("")` remains the
  correct way to exercise the no-tenant path.

### 2. `src/db/pool.zig` — `schemaNameForTenant()` doc comment

- The function doc comment (lines 120–128) currently states "Empty string →
  tenant_default" without qualification. Add a note clarifying this branch is
  unreachable via `applyRequestStorageRouting()`'s no-tenant short-circuit
  (lines 174–178), which never calls `schemaNameForTenant` for an empty
  `tenant_id`. This is documentation-only — no behavior change, no signature
  change.

## Public function signatures before/after

No public function signatures change. `schemaNameForTenant()` keeps its
existing signature and behavior (still used correctly for non-empty resolved
tenant IDs in the `SCHEMA` branch, pool.zig:223). `applyRequestStorageRouting()`
is untouched.

## Error taxonomy changes

None.

## Migration plan

None — no schema or data changes.

## Callers impacted

None — this is a test assertion fix plus a doc-comment clarification. No
caller of `pool.zig` or the test suite changes behavior.

### 3. `tests/specs/SPT-01.md` — test spec doc

Per CODE-DESIGN-VALIDATOR rework (Step 2b, rework 1): this permanent spec doc
independently documents the same stale TC-SPT-01-07 expectation and would
otherwise still contradict both the corrected test and the ISS-501 design
after this fix, reproducing the exact drift pattern that created ISS-0098.

- Table row (line 19): change acceptance criterion from `Pool checkout for
  default tenant sets search_path to 'tenant_default,public'` /
  `SHOW search_path ... contains tenant_default` to the corrected
  `Pool checkout with empty tenant context sets search_path to 'public'
  (ISS-501 no-tenant path)` / `SHOW search_path ... contains public`.
- Detail section (lines 84–90, `### TC-SPT-01-07`): update heading, **Then**
  clause, and **Acceptance criterion mapped** line to describe the
  `public` result and reference `applyRequestStorageRouting` (the current
  function name — the doc currently cites the pre-ISS-501 name
  `applyRequestTenantContext`, which no longer exists in `pool.zig`).
- Leave TC-SPT-01-05 and TC-SPT-01-06 untouched — both remain accurate
  (TC-SPT-01-05 covers schema *provisioning*, not routing; TC-SPT-01-06
  covers the non-empty-tenant SCHEMA-path case, unaffected by this fix).

## Fix scope

3 files:
- `tests/integration/spt01_provisioning_test.zig`
- `src/db/pool.zig` (comment only)
- `tests/specs/SPT-01.md` (spec doc correction)

Within the 5-file cap. No TEST-DESIGNER step required — this is a pure
regression fix per WF-03 Fix Scope Rule (test and spec doc were wrong; no
business logic added or modified).
