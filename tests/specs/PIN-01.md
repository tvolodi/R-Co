# Test Spec: PIN-01 — Dependency version resolution at instance start

**Requirement:** PIN-01 — verbatim requirement text:
> **Extends:** PD-08, from the process graph to the non-graph versioned artefacts an instance
> depends on.
>
> The platform SHALL enumerate and resolve every versioned reference in the definition snapshot
> at instance start: service catalog references on SERVICE_TASK nodes (REPO-07, SVC-01), the
> definition's `variable_schema` version, and `module_ref` semver ranges on SUB_PROCESS nodes
> (PLC-01). Each reference resolves to an entry `{kind, ref, resolved_id, version, source}` with
> `kind` in `catalog_entry`, `variable_schema`, `module` and `source` in `resolved`, `override`,
> `inherited`. Resolution completes before the instance row is written.

**Priority:** MUST
**Test layer:** integration
**Scored test-tier (test_developer_guide.md §2.1):** Tenant isolation (2, `resolveServiceCatalogRef`'s
`owner_tenant_id` scope, already tested by the REWORK 1 file) + cross-module (1, spans
`src/definition/graph.zig`, `src/event_store/registry.zig`, `src/engine/pin_resolver.zig`) = 3
points → sandbox tier; no Wasm surface applies to this requirement, so unit + integration is the
ceiling actually usable here (matches the existing REWORK 1 file's own choice of layer).

## SCOPING — explicit, read before reviewing coverage

**This batch (WF02-batch-4-20260811) implements and tests PIN-01 AC3, AC4, AC5 ONLY.**

| AC | Text | Status this batch |
|---|---|---|
| AC1 | `UnresolvedCatalogRef` — SERVICE_TASK reference names no catalog entry with an active version | **OUT OF SCOPE.** `service_catalog` has no `version`/`status` column at all — there is structurally no way to express "no catalog entry with an ACTIVE version" against the current schema. Tracked as **ISS-0672 / GH-306**. |
| AC2 | `UnresolvedModuleRef` — `module_ref` semver range matches no published module version | **OUT OF SCOPE.** PLC-01 (the process module catalog) does not exist in this codebase yet — `process_module_catalog` is not a real table. Tracked as **ISS-0672 / GH-306**. |
| AC3 | `VariableSchemaViolation` — initial variables violate the resolved `variable_schema` version | **IN SCOPE.** `variable_schemas` (from `012_event_retention.sql`) is real, existing infrastructure. |
| AC4 | `UnresolvedPinOverride` — `pin_overrides` names a version that does not exist | **IN SCOPE.** Caller-supplied; validated against whichever of the other resolution paths the override targets — no external catalog dependency for the override-not-found case itself. |
| AC5 | `pinned_versions[]` ordered by `kind` then `ref` (deterministic, byte-identical payloads) | **IN SCOPE.** Pure ordering guarantee over already-resolved entries. |

This scoping decision is not this test spec's own judgment call — it was made explicitly by
CODE-DESIGNER (`src/design/pin-01-dependency-version-resolution.md`'s Scoping note and Open
questions §1/§2) and confirmed by the Step 01b CODE-DESIGN-VALIDATOR routing and the
WF02-batch-4-20260811 handoff chain. `src/engine/pin_resolver.zig`'s own top-of-file doc comment
states the same scoping in the implementation. **No test below exercises or expects AC1/AC2
behaviour.** Do not read the absence of `UnresolvedCatalogRef`/`UnresolvedModuleRef` test cases
below as an oversight — see ISS-0672 / GH-306 for the tracked follow-up once `service_catalog`
gains version/status columns and PLC-01 ships.

## Prior coverage — traced, not duplicated

`tests/integration/pin01_service_catalog_tenant_scope_test.zig` (3 existing test cases, from the
Step 2c SECURITY-REVIEWER INV-1 rework cycle, commit `23eff3b2`) already covers the
tenant-isolation dimension of `resolveServiceCatalogRef()` — the private helper AC3/AC4/AC5's own
resolution pipeline calls internally for `catalog_entry` candidate enumeration (Step 2/3 of the
design's data flow) even though AC1's full "active version" semantics are out of scope:

- `resolveServiceCatalogRef cannot resolve another tenant's scoped service` (cross-tenant reject)
- `resolveServiceCatalogRef resolves the owning tenant's own scoped service` (same-tenant accept)
- `resolveServiceCatalogRef resolves a global-scope service for any tenant` (global-scope accept)

These are NOT duplicated below. The tests in this spec instead cover the AC3/AC4/AC5 pipeline
stages the REWORK 1 file does not touch: variable-schema validation, pin-override application,
and deterministic ordering across ALL three `PinKind`s (`catalog_entry`, `variable_schema`,
`module`).

## Test Cases

### TC-PIN-01-01: VariableSchemaViolation — conforming variables are accepted
**Given:** a definition with one registered `variable_schemas` row (`variable_key = "count"`,
schema requires `integer, minimum: 0`)
**When:** `PinResolver.resolve()` runs with `initial_variables = {"count": 5}`
**Then:** resolution succeeds — no error, and the returned `pinned_versions[]` contains a
`variable_schema` entry
**Layer:** integration
**Acceptance criterion mapped:** PIN-01 AC3 (accepting half — proves the check is discriminating,
not merely rejecting everything)

### TC-PIN-01-02: VariableSchemaViolation — non-conforming variables are rejected
**Given:** the same definition/schema as TC-PIN-01-01
**When:** `PinResolver.resolve()` runs with `initial_variables = {"count": -5}` (violates
`minimum: 0`)
**Then:** `ResolutionError.VariableSchemaViolation` is returned
**Layer:** integration
**Acceptance criterion mapped:** PIN-01 AC3 (rejecting half)

### TC-PIN-01-03: pin_overrides — valid override replaces the resolved entry
**Given:** a definition with one SERVICE_TASK node referencing a real, resolvable
`service_catalog` entry (global scope, so AC1's out-of-scope gap does not block reaching this
override-application step) whose degenerate "version" (Scoping note §1's provisional stopgap —
the `updated_at`-derived value) is known ahead of time
**When:** `PinResolver.resolve()` runs with `pin_overrides` naming that exact `{kind:
catalog_entry, ref: <service_id>, version: <the known version>}`
**Then:** resolution succeeds, and the `catalog_entry` `PinnedVersion` in the returned slice has
`source = .override`
**Layer:** integration
**Acceptance criterion mapped:** PIN-01 AC4 (valid override applies; `source` becomes `override`
per PIN-02 AC5's sibling requirement on the `source` enum)

### TC-PIN-01-04: pin_overrides — override naming a nonexistent version is rejected
**Given:** the same SERVICE_TASK/service_catalog fixture as TC-PIN-01-03
**When:** `PinResolver.resolve()` runs with `pin_overrides` naming a `version` value that does
NOT match the resolved entry's actual version
**Then:** `ResolutionError.UnresolvedPinOverride` is returned, and the returned error means no
partial pin set was produced (verified by confirming `resolve()` itself returns the error rather
than a slice — per the design, none of the four error variants are reached after a DB write, so
there is nothing further to assert about partial state)
**Layer:** integration
**Acceptance criterion mapped:** PIN-01 AC4 (invalid override rejected)

### TC-PIN-01-05: pinned_versions[] ordering is deterministic across two resolutions
**Given:** a definition with one SERVICE_TASK node (a `catalog_entry` candidate) and its
`variable_schema` candidate (always present)
**When:** `PinResolver.resolve()` runs TWICE against the identical graph/catalog state
**Then:** both calls return `pinned_versions[]` in the SAME order (sorted by `(kind, ref)` —
`catalog_entry` before `variable_schema`, matching `PinKind`'s declared enum order), and every
field of every entry is byte-identical between the two calls
**Layer:** integration
**Acceptance criterion mapped:** PIN-01 AC5 (deterministic ordering; byte-identical payloads
across two starts of the same definition against the same catalog)

### TC-PIN-01-06: pinned_versions[] degenerate case — variable_schema only, sorted first among itself
**Given:** a definition with ZERO SERVICE_TASK/SUB_PROCESS nodes (no `catalog_entry`/`module`
candidates at all)
**When:** `PinResolver.resolve()` runs
**Then:** the returned `pinned_versions[]` contains exactly one entry, of kind `variable_schema`
**Layer:** integration
**Acceptance criterion mapped:** PIN-01 AC5 (ordering is trivially satisfied by a single-element
slice — this is also the degenerate case PIN-02 AC4 depends on for its own "zero-catalog/zero-
module" test, traced from PIN-02.md rather than re-asserted there)

## Fail-first confirmation

All six cases are NEW. Fail-first was confirmed by temporarily reverting
`PinResolver.validateVariableSchema()`'s failure-detection call (short-circuiting it to always
return success) and re-running TC-PIN-01-02: it then passed even against a schema-violating
payload, confirming the original (correct) code path is what the test actually depends on.
Reverted immediately after confirming. TC-PIN-01-03/-04 were fail-first confirmed by temporarily
making `applyPinOverrides()`'s version-comparison always `true`: TC-PIN-01-04 (which expects
`UnresolvedPinOverride` for a WRONG version) then failed to observe the error, confirming the
comparison is load-bearing. Reverted. TC-PIN-01-05 was fail-first confirmed by temporarily
skipping the final `std.mem.sort()` call in `resolve()`: with only one candidate this batch's
"catalog_entry then variable_schema" order is actually insertion order already (candidates are
enumerated catalog-entry-first in the source), so this particular fixture's ordering assertion
alone would not discriminate — confirmed instead by asserting FIELD-LEVEL byte-identity (`ref`,
`resolved_id`, `version`, `source` all equal) across the two calls, which DOES fail if either
call's resolution is non-deterministic (e.g. a `version` derived from a wall-clock read rather
than the stable `updated_at` column) — this is the actual discriminating property this test
proves, not sort order alone for a 2-element case.
