# Fix Design: ISS-0099 — TC-SPT-01-06 uses an unprovisioned tenant UUID, so storage_mode resolution falls back to LEGACY_RLS/public instead of exercising the SCHEMA routing path

## Root cause (from docs/issues/ISS-0099.json and GitHub #355)

`TC-SPT-01-06` sets `tenant_context` to a fixed, never-provisioned UUID
(`a1b2c3d4-e5f6-4a7b-8c9d-e0f1a2b3c4d5`) and expects `SHOW search_path` to
resolve to that tenant's dedicated schema. `applyRequestStorageRouting()` in
`src/db/pool.zig` (lines 179-245) resolves `storage_mode` by querying
`SELECT storage_mode FROM public.tenant WHERE id = $1::uuid` (lines 193-196).
For a UUID with no `public.tenant` row, the query returns no row, and the
function correctly defaults to `LEGACY_RLS` (line 213: "Default: LEGACY_RLS
(tenant not found, null mode, or any non-SCHEMA value)"), which routes to
`SET search_path TO public` (line 223) — not the tenant's schema.

This is the same class of drift as ISS-0098: `TC-SPT-01-06` predates the
ISS-501 `storage_mode` gate and was never updated to satisfy it. Unlike
ISS-0098, the fix here is not "the test's expectation was wrong" — the test's
*stated intent* ("pool checkout sets search_path to tenant schema for
non-default tenant") is a real, still-valid acceptance criterion for SPT-01
(TC-SPT-01-06 in `tests/specs/SPT-01.md`), and TC-SPT-01-07 already covers the
LEGACY_RLS/public fallback path. Weakening TC-SPT-01-06 to also assert the
fallback would leave the SCHEMA routing branch (`pool.zig:228-243`)
uncovered by any integration test. The correct fix is option (a) from the
issue: provision a real `public.tenant` row with `storage_mode='SCHEMA'` for
the test UUID, so the test genuinely exercises the SCHEMA path.

This is CATEGORY E (test code error) — no production code changes.
`pool.zig` behavior is correct per the ISS-501 design and is unchanged.

## What changes

### 1. `tests/integration/spt01_provisioning_test.zig` — `TC-SPT-01-06`

- Replace the fixed literal UUID with a freshly generated UUID
  (`randomUuidStr`, already used by every other test in this file) so the
  test has proper per-test isolation instead of a shared hardcoded value.
- Before acquiring the pool connection, `INSERT INTO public.tenant (id, slug,
  display_name, status, idp_realm_id, storage_mode) VALUES ($1::uuid, ...,
  'SCHEMA')` for the generated UUID — mirroring the existing pattern in
  `tests/integration/iss107_tenant_storage_mode_test.zig:160` and
  `tests/integration/test_iss503_rls_removal.zig:130`.
- Register a `defer` to clean up the inserted `public.tenant` row
  (`DELETE FROM public.tenant WHERE id = $1::uuid`), in addition to the
  existing `cleanupTenant` defer for the schema/registry rows. Ordered so the
  tenant row delete runs after the schema cleanup (defers run LIFO — register
  the tenant-row cleanup defer first, then acquire the connection).
- Update the comment block above the test (currently lines 382-389) to state
  that the test provisions a real `SCHEMA`-mode tenant so it exercises
  `applyRequestStorageRouting()`'s `SCHEMA` branch, not just the naming
  convention.
- No change to the assertion itself — it already correctly checks that
  `search_path` contains the expected `tenant_<stripped_uuid>` schema name.

## Public function signatures before/after

No public function signatures change. No source files outside the test file
are touched.

## Error taxonomy changes

None.

## Migration plan

None — no schema or data changes. The test inserts/deletes its own
`public.tenant` row using existing columns (`storage_mode` added by migration
086, already applied by `TestHarness.init()`).

## Callers impacted

None — this is a test-fixture fix. No caller of `pool.zig` or the test suite
changes behavior.

## Fix scope

1 file:
- `tests/integration/spt01_provisioning_test.zig`

Within the 5-file cap. No TEST-DESIGNER step required — this is a pure
regression fix per WF-03 Fix Scope Rule (test fixture was incomplete; no
business logic added or modified).
