# Test Spec: SPT-03 — Remove legacy bpm.tenant_id session variable and tenant_id predicates

**Requirement:** SPT-03 — Remove legacy `bpm.tenant_id` session variable and `tenant_id` predicates  
**Design artefact:** `src/design/spt-03-code-cleanup.md`  
**Test file:** `tests/integration/spt03_code_cleanup_test.zig`  
**Requirement severity:** MUST

---

## Context

After SPT-02 moved all tenant data into per-tenant schemas, SPT-03 removes the
backward-compatibility shims in Zig source code that referenced the old row-based
tenancy model:

- `applyRequestTenantContext()` in `src/db/pool.zig` already only sets
  `search_path` (the `bpm.tenant_id` session variable was removed in an
  earlier pass; this is verified by AC-2).
- Migration 068 dropped `tenant_id` from `public.events` and
  `public.events_archive`, completing the removal of tenant columns from all
  public-schema tables.
- `src/event_store/store.zig`: `use_tenant_id_column` compatibility branches
  removed; all event-store SQL paths are now column-free.
- `src/db/provisioning.zig`: registry queries against `public.tenant_schemas`
  now use `schema_name` (unique) instead of `tenant_id` as the lookup key.
- `src/config/loader.zig`: `loadConfigArtifact()` / `loadActiveConfig()` no
  longer accept or use a `tenant_id` parameter; the pool's `search_path`
  scopes the `tenant_artifact_activations` lookup automatically.

---

## Test Case Summary

| ID | Title | Layer | Pass Condition |
|---|---|---|---|
| TC-SPT-03-01 | No `bpm.tenant_id` session variable active after pool checkout | integration | `current_setting('bpm.tenant_id', true)` returns NULL or empty string |
| TC-SPT-03-02 | `search_path` is set to the correct tenant schema after pool checkout | integration | `current_schema()` returns the expected schema name |
| TC-SPT-03-03 | events table has no `tenant_id` column in any schema | integration | `information_schema.columns` count for events.tenant_id = 0 in public and 0 in tenant schemas |
| TC-SPT-03-04 | Events appended in one tenant schema are invisible in another | integration | Count of events in schema A = 1; count in schema B = 0 after isolated insert |

---

## Test Cases (Detail)

### TC-SPT-03-01: No bpm.tenant_id session variable after pool checkout

**Acceptance criterion:** AC-3 — `current_schema()` is the tenant schema and no
`bpm.tenant_id` session variable is set.

**Test strategy:** Acquire a pool connection with a test tenant ID set in the
tenant context module. Execute `SELECT current_setting('bpm.tenant_id', true)`.
Expect NULL or empty string (variable absent = SPT-03 clean).

**Expected:**
- `current_setting('bpm.tenant_id', true)` IS NULL or = ''

---

### TC-SPT-03-02: search_path set to correct tenant schema

**Acceptance criterion:** AC-3 — The correct tenant schema is active on every
connection checkout.

**Test strategy:** Set tenant context to a provisioned test tenant UUID. Acquire
a pool connection. Execute `SELECT current_schema()`. Expect the tenant schema
name (e.g. `tenant_<32hex>`).

**Expected:**
- `current_schema()` = `tenant_<uuid_no_hyphens>`

---

### TC-SPT-03-03: events.tenant_id column absent from public schema

**Acceptance criterion:** AC-1 — After migration 068, `events.tenant_id` and
`events_archive.tenant_id` do not exist in the public schema.

**Test strategy:** Query `information_schema.columns` for both tables in
`table_schema='public'` with `column_name='tenant_id'`. Expect count = 0.

**Expected:**
- `SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='events' AND column_name='tenant_id'` → 0
- `SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='events_archive' AND column_name='tenant_id'` → 0

---

### TC-SPT-03-04: Event isolation via search_path (two tenants)

**Acceptance criterion:** AC-4 — Concurrent requests for different tenants each
use their own schema; neither can read the other's rows.

**Test strategy:** Provision two test tenant schemas via
`bpm_provision_tenant_schema()`. Set tenant context to schema A, insert a row
into `events`. Set tenant context to schema B, verify 0 rows in `events`.
Rollback via `h.deinit()` cleans both schemas.

**Expected:**
- Count of events in schema A = 1
- Count of events in schema B = 0
