# Test Spec: SPT-03 — Remove legacy `bpm.tenant_id` session variable and `tenant_id` predicates

**Requirement:** SPT-03 — After SPT-02 is applied and all data lives in tenant schemas, the platform MUST remove all backward-compatibility shims that reference the old row-based tenancy model: `applyRequestStorageRouting()`/`applyRequestTenantContext()` in `src/db/pool.zig` MUST stop calling `set_config('bpm.tenant_id', ...)` and only set `search_path TO <schema_name>,public`; all `WHERE tenant_id = $N` predicates / bind parameters / INSERT column references on business tables MUST be removed; the `bpm_effective_tenant_id()` SQL function MUST be dropped (062, with Zig call sites removed); and the `tenant_id` column definitions in affected Zig structs MUST be removed.
**Priority:** MUST
**Test layer:** integration (real PostgreSQL via `BPM_TEST_DB_URL`) + source-assertion
**Implementation:** `tests/integration/spt02_03_04_schema_tenant_migration_test.zig`
**Design authority:** `src/design/spt-02-03-04-schema-per-tenant-migration.md` §8, §15 (SPT-03 trace)

> **AC1 scope note (authoritative — OQ-1 / validator ruling):** the literal grep
> `grep -r "bpm\.tenant_id\|set_config.*tenant\|WHERE tenant_id\|tenant_id = \$" src/` is
> **unsatisfiable as written**: Class-G registry queries (`tenant_schemas`, `tenant_hostnames`,
> `tenant_realm_binding`) and `owner_tenant_id` lines legitimately contain `WHERE tenant_id = $N`
> substrings. The design's scoped interpretation governs: (a) no `bpm.tenant_id` /
> `set_config.*tenant` string remains in `src/`; (b) no `tenant_id` predicate/bind/INSERT
> references any Class-B business table; (c) every remaining `tenant_id` predicate targets a
> Class-G registry table in the §8.2 R4 allow-list. TC-SPT-03-01 asserts (a) across `src/**/*.zig`
> and the Class-B-absence half of (b) against the live schema.

## Test Cases

| TC ID | Name | Acceptance Criterion |
|---|---|---|
| TC-SPT-03-01 | No `bpm.tenant_id` / `set_config.*tenant` in `src/`; no Class-B `tenant_id` column | SPT-03 AC1 (scoped) |
| TC-SPT-03-02 | Collapsed routing compiles and routes via `search_path` only | SPT-03 AC2 |
| TC-SPT-03-03 | Tenant JWT context → correct `current_schema()`; no `bpm.tenant_id` session variable | SPT-03 AC3 |
| TC-SPT-03-04 | Two concurrent requests for different tenants are isolated via `search_path` | SPT-03 AC4 |
| TC-SPT-03-05 | No-tenant / reset path returns to `public`; existing routing keeps working | SPT-03 AC5 |

### TC-SPT-03-01: No `bpm.tenant_id` / `set_config.*tenant` in `src/`; no Class-B `tenant_id` column

**Given:** SPT-03 implementation has landed (Step 2a commit `27ec5d6c`).
**When:** `src/**/*.zig` is walked and each file scanned for the literals `bpm.tenant_id` and `set_config('bpm.tenant_id'`; the live `public` schema is queried for `tenant_id` columns.
**Then:** No `src/` file contains either literal (session variable removed — scoped AC1a); every public table still carrying `tenant_id` is in the Class-G allow-list (no Class-B `tenant_id` column — AC1b).
**Layer:** integration + source-assertion
**Acceptance criterion mapped:** SPT-03 AC1 (scoped interpretation per design §8.3 / OQ-1).

### TC-SPT-03-02: Collapsed routing compiles and routes via `search_path` only

**Given:** A per-test tenant schema is provisioned via `provisionTestTenantSchema()`.
**When:** A pool connection is acquired with the tenant context bound; `SHOW search_path` is executed and a Class-B table in the schema is queried.
**Then:** The connection is usable end-to-end (the collapsed `applyRequestStorageRouting()` compiles and runs), `search_path` contains the tenant schema, and unqualified queries resolve there.
**Layer:** integration
**Acceptance criterion mapped:** SPT-03 AC2 — `zig build` exits 0 with no unused `tenant_id` fields (behavioural consequence exercised here; the compile gate itself is TEST-RUNNER's `zig build`).

### TC-SPT-03-03: Tenant JWT context → correct `current_schema()`; no `bpm.tenant_id` session variable

**Given:** A per-test tenant schema is provisioned and the tenant context is bound.
**When:** A pool connection is acquired; `SELECT current_schema()` and `SELECT current_setting('bpm.tenant_id', true)` are executed.
**Then:** `current_schema()` equals the tenant schema name and `current_setting('bpm.tenant_id', true)` is NULL (the session variable is never set on checkout).
**Layer:** integration
**Acceptance criterion mapped:** SPT-03 AC3 — correct tenant schema active via `current_schema()`, no `bpm.tenant_id` session variable set.

### TC-SPT-03-04: Two concurrent requests for different tenants are isolated via `search_path`

**Given:** Two per-test schemas A and B are provisioned; a row is inserted into a Class-B table in A (routed via A's search_path).
**When:** Two connections are acquired with contexts A and B respectively; each runs `SHOW search_path` and queries the row.
**Then:** Connection A sees its row; connection B's `search_path` contains only its own schema and B cannot read A's row (cross-tenant isolation via `search_path`).
**Layer:** integration
**Acceptance criterion mapped:** SPT-03 AC4 — two concurrent requests for different tenants have independent `search_path`s; neither reads the other's rows.

### TC-SPT-03-05: No-tenant / reset path returns to `public`; existing routing keeps working

**Given:** An empty tenant context (no resolved tenant).
**When:** A pool connection is acquired with the empty context; then, after release and re-acquire with no tenant, `SHOW search_path` is executed.
**Then:** The connection's `search_path` is `public` (and contains no tenant schema) both on the no-tenant path and after reset — so existing public-routed code keeps working (no regression).
**Layer:** integration
**Acceptance criterion mapped:** SPT-03 AC5 — `zig build test` passes with no regressions (no-tenant/routing-reset behaviour preserved, exercised here).
