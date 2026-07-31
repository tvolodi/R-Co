# Fix Design: ISS-0100 — Tenant Fixture Hygiene + GBL-084 Guard Scoping

**Issue:** [GitHub #357](https://github.com/tvolodi/R-Co/issues/357) (ISS-0100)
**Run:** WF03-iss0100-20260731
**Type:** E (novel/cross-cutting — data-hygiene bug across test fixtures + a migration guard, not a CRUD/list-page/migration-codegen/react-flow-node pattern)
**Author:** CODE-DESIGNER
**Diagnosis source:** `docs/issue-reports/ISS-0100-diagnosis.yaml`

---

## 1. Problem summary (from diagnosis, not restated in full)

Every disposable integration-test tenant fixture INSERT that omits `tenant_type` defaults to `tenant_type='production'` (per `migrations/GBL-080_env01_tenant_type_field.sql`) and `storage_mode='LEGACY_RLS'` (per `migrations/086_iss107_tenant_storage_mode.sql`). `tools/clean_test_db.py` only reliably targets these via its `tenant_type = 'production'` sweep branch, and even that sweep does not run between individual test binaries within a single `zig build test-integration...` invocation. `migrations/GBL-084_rls_removal.sql`'s pre-flight guard counts **all** `storage_mode = 'LEGACY_RLS'` rows with no `tenant_type` filter, so leaked production-typed fixture tenants are miscounted as real production tenants and block the migration.

Two independent fixes are in scope, per the diagnosis's `recommendation_for_fix_design`:

1. **PRIMARY** — Normalize every disposable fixture INSERT to `tenant_type='test'` + `production_tenant_id=<default tenant id>`.
2. **SUPPLEMENTARY** — Scope GBL-084's guard to `tenant_type = 'production'` rows only, as defense-in-depth.

---

## 2. Reference pattern (verified against `tests/integration/env01_test.zig`)

`env01_test.zig` (lines 69–110) already implements the exact target shape for both tenant kinds:

```
fn insertProductionTenant(allocator, pool, tenant_id, slug) !void {
    ... conn.exec(
        \\INSERT INTO public.tenant
        \\    (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $3, 'ACTIVE', NULL, 'production', NULL)
        \\ON CONFLICT (id) DO NOTHING
    , &[_][]const u8{ tenant_id, slug, slug });
}

fn insertTestTenant(allocator, pool, tenant_id, slug, production_tenant_id) !void {
    ... conn.exec(
        \\INSERT INTO public.tenant
        \\    (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
        \\VALUES ($1::uuid, $2, $3, 'ACTIVE', NULL, 'test', $4::uuid)
        \\ON CONFLICT (id) DO NOTHING
    , &[_][]const u8{ tenant_id, slug, slug, production_tenant_id });
}
```

This is the pattern to replicate: append `tenant_type` and `production_tenant_id` to the column list, and add `'test'` + a bound/literal parameter referencing the default tenant's id to the `VALUES` list.

**The default tenant's id is already a well-known literal used throughout the affected files**: `'00000000-0000-0000-0000-000000000000'` — this is the `slug='default'` row seeded unconditionally by `tests/integration/helpers.zig::ensureDefaultOidcSeeds` (lines 333–349) on every `TestHarness.init()`, and it is already referenced as a literal elsewhere in these same files (e.g. `svc04_admin_api_test.zig` uses it as `actor.tenant_id` / `bpm.api_tenant_context.set(...)`, and `helpers.zig` itself hardcodes it as the seed row's `id`). No new lookup query is needed anywhere in this fix — every affected file either:
- **(a)** already has the literal `'00000000-0000-0000-0000-000000000000'` in scope textually nearby (svc01, svc04, adp07, adp04a, tenant_config_realm, oidc09/10/11/12/15), so BACKEND-DEV binds it as a new `$N::uuid` parameter using the same string literal, or
- **(b)** is `helpers.zig::ensureDefaultOidcSeeds` itself, where the default tenant row is the one being inserted in the *first* statement — the SVC-01..04 block that follows it can reference the same literal directly (it must not select-lookup its own just-inserted row; use the literal, consistent with how the rest of the file already treats this UUID as a fixed constant, not a queried value).

There is no case among the in-scope files where the default tenant's id must be fetched via a new `SELECT id FROM tenant WHERE slug='default'` — the id is a fixed, well-known UUID already hardcoded across the test suite, and reusing that same literal is the lowest-risk, most consistent option (matches existing convention; a `SELECT`-based lookup would be a new pattern introduced nowhere else in these files).

---

## 3. Exact fixes, file by file

For every fixture below: add `tenant_type` and `production_tenant_id` to the column list, add `'test'` and a bound parameter for `production_tenant_id` (value: the literal `00000000-0000-0000-0000-000000000000`) to the `VALUES` list. Do **not** change `ON CONFLICT` targets, existing bound parameters, or any other column. These are disposable/short-lived fixture tenants — none of them is itself the default tenant, so `tenant_type='test'` is correct for all of them (none should become `tenant_type='production'`).

### 3.1 `tests/integration/helpers.zig` — `ensureDefaultOidcSeeds` (SVC-01..04 block, lines 363–376)

Before:
```sql
INSERT INTO tenant (id, slug, display_name, status, idp_realm_id)
VALUES
  ('eeeeeeee-0000-0000-0000-000000000001'::uuid, 'svc-t1',       'SVC Test Tenant 1',       'ACTIVE', 'svc-realm-t1'),
  ('eeeeeeee-0000-0000-0000-000000000002'::uuid, 'svc-t2',       'SVC Test Tenant 2',       'ACTIVE', 'svc-realm-t2'),
  ('b4200000-0000-0000-0000-000000000001'::uuid, 'svc04-upd-tn', 'SVC04 Update Tenant',     'ACTIVE', 'realm-svc04-upd'),
  ('c4300000-0000-0000-0000-000000000001'::uuid, 'svc04-cnf-ow', 'SVC04 Conflict Owner',    'ACTIVE', 'realm-svc04-cnf-ow'),
  ('c4300000-0000-0000-0000-000000000002'::uuid, 'svc04-cnf-ot', 'SVC04 Conflict Other',    'ACTIVE', 'realm-svc04-cnf-ot'),
  ('d4400000-0000-0000-0000-000000000001'::uuid, 'svc04-inuse-t','SVC04 InUse Tenant',      'ACTIVE', 'realm-svc04-inuse'),
  ('e4500000-0000-0000-0000-000000000001'::uuid, 'svc04-lst-ta', 'SVC04 List TA',           'ACTIVE', 'realm-svc04-ta'),
  ('e4500000-0000-0000-0000-000000000002'::uuid, 'svc04-lst-tb', 'SVC04 List TB',           'ACTIVE', 'realm-svc04-tb'),
  ('f4600000-0000-0000-0000-000000000001'::uuid, 'svc04-all-t',  'SVC04 All Tenant',        'ACTIVE', 'realm-svc04-all')
ON CONFLICT (id) DO NOTHING
```

After (column list gains `tenant_type, production_tenant_id`; every row gains `'test', '00000000-0000-0000-0000-000000000000'::uuid`):
```sql
INSERT INTO tenant (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
VALUES
  ('eeeeeeee-0000-0000-0000-000000000001'::uuid, 'svc-t1',       'SVC Test Tenant 1',       'ACTIVE', 'svc-realm-t1',      'test', '00000000-0000-0000-0000-000000000000'::uuid),
  ('eeeeeeee-0000-0000-0000-000000000002'::uuid, 'svc-t2',       'SVC Test Tenant 2',       'ACTIVE', 'svc-realm-t2',      'test', '00000000-0000-0000-0000-000000000000'::uuid),
  ('b4200000-0000-0000-0000-000000000001'::uuid, 'svc04-upd-tn', 'SVC04 Update Tenant',     'ACTIVE', 'realm-svc04-upd',   'test', '00000000-0000-0000-0000-000000000000'::uuid),
  ('c4300000-0000-0000-0000-000000000001'::uuid, 'svc04-cnf-ow', 'SVC04 Conflict Owner',    'ACTIVE', 'realm-svc04-cnf-ow','test', '00000000-0000-0000-0000-000000000000'::uuid),
  ('c4300000-0000-0000-0000-000000000002'::uuid, 'svc04-cnf-ot', 'SVC04 Conflict Other',    'ACTIVE', 'realm-svc04-cnf-ot','test', '00000000-0000-0000-0000-000000000000'::uuid),
  ('d4400000-0000-0000-0000-000000000001'::uuid, 'svc04-inuse-t','SVC04 InUse Tenant',      'ACTIVE', 'realm-svc04-inuse', 'test', '00000000-0000-0000-0000-000000000000'::uuid),
  ('e4500000-0000-0000-0000-000000000001'::uuid, 'svc04-lst-ta', 'SVC04 List TA',           'ACTIVE', 'realm-svc04-ta',    'test', '00000000-0000-0000-0000-000000000000'::uuid),
  ('e4500000-0000-0000-0000-000000000002'::uuid, 'svc04-lst-tb', 'SVC04 List TB',           'ACTIVE', 'realm-svc04-tb',    'test', '00000000-0000-0000-0000-000000000000'::uuid),
  ('f4600000-0000-0000-0000-000000000001'::uuid, 'svc04-all-t',  'SVC04 All Tenant',        'ACTIVE', 'realm-svc04-all',   'test', '00000000-0000-0000-0000-000000000000'::uuid)
ON CONFLICT (id) DO NOTHING
```

This is a raw-literal SQL statement executed via `conn.exec(sql, &.{})` with zero bound args (all values are literals in the query text already, per the existing code) — appending literals to each row is consistent with the existing style and introduces no new parameter binding.

Leave the first `ensureDefaultOidcSeeds` statement (the `slug='default'` row itself, lines 334–349) untouched — that row is legitimately the production/default tenant with `tenant_type='production'` (the column default), which is correct and must not change.

### 3.2 `tests/integration/svc01_service_catalog_scope_test.zig` — `insertTenant` helper (lines 23–31) and both call sites (line 25 in the grep listing corresponds to this helper; line 202 is a second literal call site — verify at implementation time whether line 202 is a second helper-function definition or a second call; treat both textual occurrences the same way)

Before:
```sql
INSERT INTO tenant (id, slug, display_name, idp_realm_id, created_at)
VALUES ($1::uuid, $2, $3, $4, now())
ON CONFLICT (id) DO NOTHING
```
bound: `&.{ id_hex, slug, slug, slug }`

After:
```sql
INSERT INTO tenant (id, slug, display_name, idp_realm_id, created_at, tenant_type, production_tenant_id)
VALUES ($1::uuid, $2, $3, $4, now(), 'test', $5::uuid)
ON CONFLICT (id) DO NOTHING
```
bound: `&.{ id_hex, slug, slug, slug, "00000000-0000-0000-0000-000000000000" }`

Apply identically to the second `INSERT INTO tenant (id, slug, display_name, idp_realm_id, created_at)` occurrence at line 202 (same shape — confirm at implementation time whether it is a duplicate helper or a second call to the same `insertTenant` function; either way the fix is the same column/value addition).

### 3.3 `tests/integration/svc04_admin_api_test.zig` — 6 inline INSERT occurrences (lines 320, 378, 385, 527, 624, 631, 698 per the file's repeated pattern)

All follow the identical shape:
```sql
INSERT INTO tenant (id, slug, display_name, idp_realm_id, created_at)
VALUES ($1::uuid, $2, $3, $4, now())
ON CONFLICT (id) DO NOTHING
```
bound: `&.{ owner_hex, "svc04-...", "SVC04 ...", "realm-svc04-..." }` (4 positional args per call site).

After (same transformation at every occurrence):
```sql
INSERT INTO tenant (id, slug, display_name, idp_realm_id, created_at, tenant_type, production_tenant_id)
VALUES ($1::uuid, $2, $3, $4, now(), 'test', $5::uuid)
ON CONFLICT (id) DO NOTHING
```
bound: append `"00000000-0000-0000-0000-000000000000"` as the 5th positional arg at each of the ~7 call sites in this file. (Note: `svc04_admin_api_test.zig` lines 440 and 581 insert into `tenant_c4300000....process_definitions` / `tenant_d4400000....process_definitions` — schema-qualified tenant-owned tables, not `public.tenant` rows — these are NOT tenant fixture inserts and are OUT of scope; only the bare `INSERT INTO tenant (...)` occurrences change.)

### 3.4 `tests/integration/adp07_agent_role_reserved_usernames_test.zig` — `ensureTenantBinding` helper (lines 75–91)

Before:
```sql
INSERT INTO tenant (id, slug, display_name, status, idp_realm_id)
VALUES ($1::uuid, $2, $3, 'ACTIVE', $4)
ON CONFLICT (id) DO UPDATE
SET slug = EXCLUDED.slug,
    display_name = EXCLUDED.display_name,
    status = 'ACTIVE',
    idp_realm_id = EXCLUDED.idp_realm_id,
    updated_at = NOW()
```
bound: `&[_][]const u8{ tenant_id, slug, display_name, realm }`

After:
```sql
INSERT INTO tenant (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
VALUES ($1::uuid, $2, $3, 'ACTIVE', $4, 'test', $5::uuid)
ON CONFLICT (id) DO UPDATE
SET slug = EXCLUDED.slug,
    display_name = EXCLUDED.display_name,
    status = 'ACTIVE',
    idp_realm_id = EXCLUDED.idp_realm_id,
    updated_at = NOW()
```
bound: `&[_][]const u8{ tenant_id, slug, display_name, realm, "00000000-0000-0000-0000-000000000000" }`

**Important:** the `ON CONFLICT (id) DO UPDATE SET ...` clause does **not** need to set `tenant_type`/`production_tenant_id` in the `SET` list — these are immutable-by-design (PATCH already rejects changes to them per GBL-080's design) and the row will already carry the correct values from its original INSERT. Leave the `SET` clause exactly as-is; only the column list and `VALUES` list change.

### 3.5 `tests/integration/adp04a_external_identity_linkage_test.zig` — `ensureTenantBinding` helper (lines 95–111)

Identical shape and identical fix to §3.4 (same helper name, same body, same `ON CONFLICT ... DO UPDATE`). Apply the same column/value/bound-parameter addition.

### 3.6 `tests/integration/tenant_config_realm_test.zig` — `insertTestTenant` helper (lines 90–104)

Before:
```sql
INSERT INTO public.tenant (id, slug, display_name, status, idp_realm_id)
VALUES ($1::uuid, $2, $3, 'ACTIVE', $4)
ON CONFLICT (id) DO NOTHING
```
bound: `&[_][]const u8{ id, slug, slug, idp_realm_id }`

After:
```sql
INSERT INTO public.tenant (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
VALUES ($1::uuid, $2, $3, 'ACTIVE', $4, 'test', $5::uuid)
ON CONFLICT (id) DO NOTHING
```
bound: `&[_][]const u8{ id, slug, slug, idp_realm_id, "00000000-0000-0000-0000-000000000000" }`

(Function is misleadingly named `insertTestTenant` already — but prior to this fix it never actually set `tenant_type='test'`; this fix makes the name accurate.)

### 3.7 `tests/integration/oidc09_jit_provisioning_test.zig`, `oidc10_attribute_sync_test.zig`, `oidc11_identity_stability_test.zig` — `ensureTenantBinding` helper (each file defines its own copy, same body)

Same shape and same fix as §3.4/§3.5:
```sql
INSERT INTO tenant (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
VALUES ($1::uuid, $2, $3, 'ACTIVE', $4, 'test', $5::uuid)
ON CONFLICT (id) DO UPDATE
SET slug = EXCLUDED.slug,
    display_name = EXCLUDED.display_name,
    status = 'ACTIVE',
    idp_realm_id = EXCLUDED.idp_realm_id,
    updated_at = NOW()
```
bound: append `"00000000-0000-0000-0000-000000000000"` as the 5th arg.

### 3.8 `tests/integration/oidc12_realm_tenant_binding_test.zig` — 2 inline INSERT occurrences (lines 89, 172)

Before:
```sql
INSERT INTO tenant (id, slug, display_name, status, idp_realm_id)
VALUES (gen_random_uuid(), $1, $2, 'ACTIVE', $3)
ON CONFLICT (slug) DO UPDATE
SET idp_realm_id = EXCLUDED.idp_realm_id,
    display_name = EXCLUDED.display_name,
    updated_at = NOW()
```
bound: `&[_][]const u8{ tenant_slug, "OIDC12 Tenant 01", realm_id }`

After:
```sql
INSERT INTO tenant (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
VALUES (gen_random_uuid(), $1, $2, 'ACTIVE', $3, 'test', $4::uuid)
ON CONFLICT (slug) DO UPDATE
SET idp_realm_id = EXCLUDED.idp_realm_id,
    display_name = EXCLUDED.display_name,
    updated_at = NOW()
```
bound: `&[_][]const u8{ tenant_slug, "OIDC12 Tenant 01", realm_id, "00000000-0000-0000-0000-000000000000" }`

Apply the same transformation to the second occurrence at line 172 (same shape, different literal display-name/slug values already bound as parameters).

### 3.9 `tests/integration/oidc15_realm_deletion_test.zig` — 2 inline INSERT occurrences (lines 227, and the earlier `gen_random_uuid()` pattern repeated around line 322 per the original grep — verify both are the `tenant` table, not `users`)

Before (line 227 shape):
```sql
INSERT INTO tenant (id, slug, display_name, status, idp_realm_id)
VALUES (gen_random_uuid(), $1, $2, 'ACTIVE', $3)
ON CONFLICT (slug) DO UPDATE
SET idp_realm_id = EXCLUDED.idp_realm_id,
    updated_at = NOW()
```
bound: `&[_][]const u8{ tenant_slug, "OIDC15 Tenant 05", realm_id }`

After: identical transformation to §3.8 — add `tenant_type, production_tenant_id` to column list, `'test', $4::uuid` to values, append the default-tenant literal as the 4th bound arg.

The `line 322` occurrence found by the original grep (`INSERT INTO users (id, tenant_id, username, display_name, email, ...)`) is a `users` table insert, not a `tenant` fixture — **out of scope**, no change.

### 3.10 `tests/integration/oidc35_onboarding_test.zig` — 3 inline INSERT occurrences (lines 739, 796, 806)

All three follow:
```sql
INSERT INTO tenant (id, slug, display_name, status, idp_realm_id)
VALUES ($1::uuid, $2, '<literal display name>', 'ACTIVE', $2)
ON CONFLICT (slug) DO NOTHING
```
bound: 2 positional args (`tenant_id_hex`, `slug`) — note `idp_realm_id` reuses the `slug` bind (`$2`) in these three call sites, not a distinct 4th column value.

After:
```sql
INSERT INTO tenant (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id)
VALUES ($1::uuid, $2, '<literal display name>', 'ACTIVE', $2, 'test', $3::uuid)
ON CONFLICT (slug) DO NOTHING
```
bound: append `"00000000-0000-0000-0000-000000000000"` as the 3rd positional arg at each of the 3 call sites (lines 739, 796, 806).

---

## 4. Explicitly OUT of scope (do not modify)

- **`tests/integration/env01_test.zig`, `env02_test.zig`, `env03_test.zig`, `env05_test.zig`, `env01_tenant_type_field_test.zig`** — these ENV-0x requirement tests already set `tenant_type` deliberately and correctly (see §2's reference pattern extracted directly from `env01_test.zig`). Confirmed by direct read: every `INSERT INTO public.tenant` in `env01_test.zig` already includes `tenant_type` and `production_tenant_id` in its column list. No changes.
- **`tests/integration/iss107_tenant_storage_mode_test.zig`** — this file's purpose is testing the `storage_mode` column (ISS-107), a different column from `tenant_type` (ISS-0100/ENV-01). Per the diagnosis's evidence entry (`grep -rn 'INSERT INTO (public\.)?tenant'` finding), this file is called out by name as one of the two exceptions where a bare/partial insert is intentional to its own test's scope, not a hygiene bug — it is testing storage_mode CHECK-constraint behavior in isolation and its fixture rows (`iss107-t3/t4/t5`) are cleaned up by `iss107`-specific teardown, not by `clean_test_db.py`'s `tenant_type` sweep. **No changes to this file under ISS-0100.** (If a future issue wants this file's fixtures to also be tenant_type-hygienic, that is a separate, new issue — not part of this fix, per the `⛔ No Issue Left Local-Only` directive if discovered as a byproduct; this design does not discover it as a new defect, since the diagnosis already scoped it out deliberately.)
- **`tests/integration/spt01_provisioning_test.zig`** (line 439) — already sets `storage_mode` explicitly as part of its own ISS-502/SPT-01 provisioning-path test; not flagged by the diagnosis as part of the 20 affected files. Not touched by this design.
- **All non-`tenant`-table INSERTs** found in the original grep sweep (`users`, `process_definitions`, `service_catalog`, `onboarding_registry`, `tenant_hostnames`, `tenant_artifact_activations`, `events`, `dead_letter_queue`, `artifact_activations`, `artifact_activation_history`, schema-qualified `tenant_<uuid>.process_definitions`) — these insert into other tables, not `public.tenant`, and are unrelated to the `tenant_type`/`storage_mode` default-value bug. Not touched.

---

## 5. GBL-084 guard scoping (SUPPLEMENTARY fix)

### 5.1 Exact SQL change

In the pre-flight check block (current lines 31–38 of `migrations/GBL-084_rls_removal.sql`):

Before:
```sql
IF v_tenant_table_exists THEN
    SELECT count(*) INTO v_legacy_count
    FROM public.tenant
    WHERE storage_mode = 'LEGACY_RLS';

    IF v_legacy_count > 0 THEN
        RAISE EXCEPTION 'ISS-503 pre-flight failed: % tenant(s) still in LEGACY_RLS mode. All tenants must be cut over to SCHEMA before RLS removal.', v_legacy_count;
    END IF;
ELSE
```

After:
```sql
IF v_tenant_table_exists THEN
    SELECT count(*) INTO v_legacy_count
    FROM public.tenant
    WHERE storage_mode = 'LEGACY_RLS'
      AND tenant_type = 'production';

    IF v_legacy_count > 0 THEN
        RAISE EXCEPTION 'ISS-503 pre-flight failed: % tenant(s) still in LEGACY_RLS mode. All tenants must be cut over to SCHEMA before RLS removal.', v_legacy_count;
    END IF;
ELSE
```

Only the `WHERE` clause of the pre-flight `SELECT count(*)` gains `AND tenant_type = 'production'`. No other line in the file changes. The `RAISE EXCEPTION` message text is unchanged (it already says "tenant(s)", which remains accurate once scoped to production tenants).

Note: this migration's file header already states it is exempt from the GBL-prefix schema-qualification lint (`GBL-prefix: operates on public schema; exempt from lint_migration_schema.py business-table check`) and already schema-qualifies `public.tenant` — the new clause does not change qualification style, it only adds a predicate.

### 5.2 New migration file vs. in-place edit — decision: **NEW FILE, numbered `GBL-086`**

**Decision: create a new migration file, `migrations/GBL-086_iss503_guard_tenant_type_scope.sql`. Do NOT edit `GBL-084_rls_removal.sql` in place.**

Rationale, verified directly against this project's migration runner (`src/db/migrations.zig`):

1. **Migrations are tracked by filename, and skip-on-already-applied is unconditional.** `src/db/migrations.zig` line 210: `if (applied.contains(filename)) continue;` — the runner reads `public.schema_migrations` (composite key `schema_name, version` where `version` is the filename), and if the filename is already recorded, the file's *current on-disk contents* are never re-read or re-executed, regardless of what changes were made to the file since. This is confirmed by the backend guide's migration conventions (`docs/guides/backend_developer_guide.md §4.4`): "Migrations run in filename order; never rename an existing migration file" — the corollary is that editing an already-applied file's body is inert everywhere it already succeeded.

2. **GBL-084 has very likely already recorded itself as applied in most environments.** `tests/integration/test_iss503_rls_removal.zig`'s own header (lines 18–38, cited in the diagnosis) states GBL-084 "has almost certainly already been applied once, globally" and that re-application is "a permanent no-op" once successful. In any environment where this is true, editing `GBL-084_rls_removal.sql`'s guard SQL in place would never run again — the tightened guard would silently fail to take effect in exactly the environments most likely to have hit this bug already (long-lived `bpm_test` containers, CI databases that have run the suite before).

3. **In environments where GBL-084 has NOT yet successfully recorded (fresh `db_test` volume, or a volume where the guard has never yet passed)**, an in-place edit to GBL-084 would take effect on the next run — but this is exactly the minority case, and relying on it means the fix is inconsistent across environments: it silently works on fresh databases and silently no-ops on any database where GBL-084 already succeeded once. A new migration file removes this inconsistency entirely — `GBL-086` is guaranteed to run (once, idempotently) in every environment, fresh or long-lived, the next time `zig build migrate` (or any `TestHarness.init()`) executes, because its filename has never been recorded in `schema_migrations`.

4. **This matches the project's own established convention for "tighten a previously-shipped migration's behavior".** `docs/guides/backend_developer_guide.md §4.4` states plainly: "No `DROP` statements in migrations (use a new migration to rename/replace)" and "never rename an existing migration file" — the general pattern for this codebase is additive: a correction to prior migration behavior ships as a new, later-numbered file, not a retroactive edit. `GBL-084`'s own header comment models this too (it is itself a later migration correcting/extending an earlier RLS-removal readiness state, not an edit to an older file).

5. **Numbering:** the `GBL-*` sequence's highest currently-allocated number is `GBL-085` (`GBL-085_state_snapshots.sql`); the next `GBL-*` migrations found on disk jump to `GBL-097`. `GBL-086` through `GBL-096` are unallocated. This fix is topically a direct continuation of the `GBL-084` RLS-removal/ISS-503 guard work, so it takes the next sequential number, `GBL-086`, keeping it adjacent to `GBL-084`/`GBL-085` for readability. **BACKEND-DEV must re-verify no other in-flight branch has claimed `GBL-086` before creating the file** (re-run `ls migrations/GBL-08*.sql` at implementation time — this design was written against a point-in-time listing and a concurrent branch could theoretically claim the number first).

**New file content shape** (prose description — BACKEND-DEV writes the actual SQL):

- Header comment: reference ISS-0100 / GitHub #357, state this migration narrows GBL-084's pre-flight guard to exclude non-production (test-typed) fixture tenants, and reference that it depends on GBL-084 and GBL-080 (`tenant_type` column) having already run.
- Idempotent guard: wrap in the same `DO $$ ... END $$;` pattern GBL-084 uses, with the same `v_tenant_table_exists` check (guard against `public.tenant` not existing, matching GBL-084's own defensive style) plus a check that the `tenant_type` column exists (defensive, since GBL-080 adds it — though GBL-080 is numbered before GBL-084/GBL-086 and should always have run first by migration ordering, an explicit `information_schema.columns` existence check for `tenant_type` costs little and matches the codebase's established defensive style for cross-migration dependencies).
- Body: this migration does **not** need to re-run GBL-084's pre-flight check itself — it only needs to be a placeholder/no-op DDL-wise if GBL-084 already fully executed (RLS removal + column drops), OR, if GBL-084 has NOT yet successfully run (still retrying), this new migration runs first (by filename order, `GBL-086` > `GBL-084`, so GBL-084 is attempted first every time regardless — migrations run in filename order per the runner) — **this ordering detail matters**: since `GBL-084` sorts before `GBL-086` alphabetically/numerically, `GBL-084` always still executes (and its guard still fires) BEFORE `GBL-086` gets a chance to run. **This means GBL-086 must not merely be "a copy of the tightened guard that runs after GBL-084" — it must actually replace GBL-084's job of performing the RLS removal DDL, using the tightened guard, so that once GBL-086 exists, it (not the original GBL-084) is what successfully completes the RLS removal in environments where GBL-084 is still failing.**

  Concretely: `GBL-086` should contain the **full body of GBL-084** (pre-flight guard + all three DDL groups + the RLS-helper-function drop), with only the guard's `WHERE` clause changed to add `AND tenant_type = 'production'`. All DDL statements in GBL-084's body are already idempotent (`IF EXISTS` / `DROP COLUMN IF EXISTS` / `DROP POLICY IF EXISTS` / `DROP FUNCTION IF EXISTS`), so re-executing them from GBL-086 is safe even in environments where GBL-084 already fully succeeded (every `ALTER TABLE ... DROP COLUMN IF EXISTS` is a no-op the second time). In environments where GBL-084 is still failing its guard (leaked fixture rows present), GBL-084 will keep failing-and-not-recording on every `TestHarness.init()`, but immediately after, `GBL-086` runs (later filename) with its scoped guard, passes (because leaked `tenant_type='test'` fixtures are no longer counted, and — combined with the PRIMARY fix in §3 — genuinely production-typed leaks should no longer occur), performs the RLS removal DDL itself, and records itself as applied. `GBL-084` will continue to be *attempted* and *fail* on every subsequent init (its own guard is unchanged and still unscoped) — this is pre-existing, accepted behavior per the diagnosis (`RAISE EXCEPTION` failures are non-fatal to the overall migration run per the runner's per-file transactional retry model) and is not a new regression introduced by this fix; GBL-084 failing forever on an already-migrated-via-GBL-086 database is a harmless, expected side effect of the fail-open-non-recording design GBL-084 already had before this fix. **BACKEND-DEV should note this in a comment inside GBL-086** so a future reader understands why GBL-084 may show perpetual `NOTICE`/`RAISE EXCEPTION` retries in logs even after RLS removal has fully completed via GBL-086.

  (Alternative considered and rejected: editing GBL-084 to add an early-exit no-op if some "already done" marker is detected. Rejected because it adds complexity disproportionate to the fix, and the diagnosis's SUPPLEMENTARY recommendation is explicitly scoped as "narrower, defense-in-depth" — duplicating the idempotent DDL body into GBL-086 is the simplest mechanism that guarantees the tightened guard actually governs whether RLS removal proceeds, in every environment, without relying on GBL-084 ever being edited or superseded.)

---

## 6. Acceptance criteria coverage

| Acceptance criterion (from handoff) | Where covered |
|---|---|
| Design lists every file + INSERT statement that must change, with exact new column/value additions | §3.1–§3.10 |
| Design explains how to obtain the default tenant's id in each affected test file | §2 (literal `00000000-0000-0000-0000-000000000000`, already in scope in every file; no new lookup needed) |
| Design specifies the exact SQL change to GBL-084's pre-flight guard COUNT query | §5.1 |
| Design makes an explicit, justified call on new-migration-file vs in-place-edit for the GBL-084 change | §5.2 (new file, `GBL-086`, with full rationale against the actual runner's `applied.contains(filename)` skip behavior) |
| No implementation code (prose/SQL snippets illustrating intent are fine) | This document contains illustrative SQL snippets only — no `.zig`/`.sql` files were written by CODE-DESIGNER |
| Explicitly confirms env0*_test.zig and iss107_tenant_storage_mode_test.zig are OUT of scope | §4 |

---

## 7. Fix-scope classification for WF-03 fast path

This fix is a **pure regression/test-hygiene fix**: it does not add or modify business logic, does not change any HTTP handler, domain module, or the engine. It normalizes test-fixture data shape (§3) and narrows a migration guard's `WHERE` predicate plus republishes GBL-084's existing, already-tested idempotent DDL under a new filename (§5). No new behavior is introduced that requires new test *design* — the existing `env01_tenant_type_field_test.zig` suite already covers the `ck_tenant_type_fk_coherence` constraint semantics being relied upon, and `test_iss503_rls_removal.zig` already covers GBL-084's guard semantics.

**Recommendation: this fix is eligible for WF-03's "PURE REGRESSION FIX" fast path** — skip Step 4/4b (TEST-DESIGNER / TEST-DESIGN-VALIDATOR) entirely for the whole fix. However, because the file list (13 files) exceeds WF-03 Step 3's hard <=5-source-file-per-iteration constraint (see §8), Step 3 (BACKEND-DEV implementation) is **not** a single handoff — it is a **sequence of Step-3 handoffs, one per fix iteration defined in §8**, executed in order. Only after the **final** iteration (Iteration 4 in §8) completes does the pipeline route to Step 5 (TEST-RUNNER) for full verification.

**Per-iteration checkpoint (between each Step-3 handoff):** after BACKEND-DEV completes each iteration, run `zig build` and the narrowest relevant `zig build test-integration-<suite>` (or the full `zig build test-integration` if a per-suite target does not exist) covering only the files touched in that iteration, to confirm no regression before the next iteration starts. This is a lightweight build/test gate, not a full TEST-RUNNER dispatch — it does not produce a `tests/reports/*.yaml` report and does not require RELEASE-VALIDATOR involvement.

**Final verification (after Iteration 4 only):** TEST-RUNNER (Step 5) re-runs the full set: `svc01`/`svc04`/`adp07`/`adp04a`/`tenant_config_realm`/`oidc09`/`oidc10`/`oidc11`/`oidc12`/`oidc15`/`oidc35` integration suites (to confirm the modified fixtures still pass their own assertions unchanged), `env01_tenant_type_field_test.zig` and `test_iss503_rls_removal.zig` (regression coverage for the invariants this fix relies on), and `db_integration_test.zig` (TC-DB-01-01/02, the originally failing test) as part of a full `zig build test-integration` run, to directly verify the guard no longer fires on leaked test-typed fixtures.

This recommendation is CODE-DESIGNER's assessment; CODE-DESIGN-VALIDATOR may override it if it disagrees with the fast-path eligibility call or the iteration plan.

---

## 8. Fix iteration plan — files BACKEND-DEV will touch, split per WF-03's <=5-file constraint

`docs/agents/workflows/WF-03_issue_resolving.md`'s "Fix size constraint" caps a single fix iteration at <=5 source files. The complete change set is 13 files (12 test files + 1 new migration). This is **not** an architectural-redesign situation — every one of the 12 test-file edits is the same mechanical, independent pattern (add `tenant_type='test'` + `production_tenant_id=<default tenant literal>` to an existing `INSERT INTO tenant` statement), applied file-by-file with zero cross-file coupling, and the 13th is one self-contained new migration. It is therefore split into an ordered sequence of four compliant iterations below, rather than escalated to ORCH. BACKEND-DEV receives one Step-3 handoff per iteration (see §7); ORCH dispatches them sequentially, with a build/test checkpoint after each (§7) before the next iteration's handoff is created.

**Iteration 1 — highest leverage (2 files):**
1. `migrations/GBL-086_iss503_guard_tenant_type_scope.sql` — **new file**, full GBL-084 body republished with the guard's `WHERE` clause scoped to `tenant_type = 'production'` (§5.2)
2. `tests/integration/helpers.zig` — 1 statement (9-row VALUES block, §3.1)

Rationale for going first: `helpers.zig::ensureDefaultOidcSeeds` runs on every single `TestHarness.init()` across the entire integration suite, so it is the single highest-leverage fixture fix — it alone eliminates 9 of the leaked rows that would otherwise defeat GBL-086's guard on every test run. Pairing it with the new migration in the same iteration means the guard-scoping and its primary beneficiary land together, so the checkpoint after Iteration 1 (`zig build` + `zig build test-integration` targeting `helpers.zig` consumers, e.g. `svc01`/`svc04`) already validates the core mechanism end-to-end before touching the remaining, lower-traffic fixture files.

**Iteration 2 — direct helper-function fixtures (5 files):**
3. `tests/integration/svc01_service_catalog_scope_test.zig` — 1 helper function, 2 call-site-equivalent occurrences (§3.2)
4. `tests/integration/svc04_admin_api_test.zig` — ~7 inline INSERT occurrences (§3.3)
5. `tests/integration/adp07_agent_role_reserved_usernames_test.zig` — 1 helper function (§3.4)
6. `tests/integration/adp04a_external_identity_linkage_test.zig` — 1 helper function (§3.5)
7. `tests/integration/tenant_config_realm_test.zig` — 1 helper function (§3.6)

Rationale: these five files are grouped because each is a self-contained `insertTenant`/`ensureTenantBinding`-style helper or a small run of inline occurrences within a single file — no file in this group depends on another. Grouped together as the "SVC/ADP/tenant-config" cluster, distinct from the OIDC cluster in Iteration 3, so a checkpoint failure narrows the search to one topical area.

**Iteration 3 — OIDC cluster, part A (3 files):**
8. `tests/integration/oidc09_jit_provisioning_test.zig` — 1 helper function (§3.7)
9. `tests/integration/oidc10_attribute_sync_test.zig` — 1 helper function (§3.7)
10. `tests/integration/oidc11_identity_stability_test.zig` — 1 helper function (§3.7)

Rationale: these three share the exact same `ensureTenantBinding` helper body (§3.7 covers all three identically), so they are the simplest, most mechanical group and are sequenced first within the OIDC cluster.

**Iteration 4 — OIDC cluster, part B (3 files) — FINAL iteration:**
11. `tests/integration/oidc12_realm_tenant_binding_test.zig` — 2 inline occurrences (§3.8)
12. `tests/integration/oidc15_realm_deletion_test.zig` — 1 inline occurrence, tenant table only; the nearby `users` insert is out of scope (§3.9)
13. `tests/integration/oidc35_onboarding_test.zig` — 3 inline occurrences (§3.10)

Rationale: these three use inline (non-shared-helper) INSERT occurrences rather than a common helper function, so they are grouped separately from Iteration 3's shared-helper trio. This is deliberately the **last** iteration — per §7, only after this iteration's checkpoint passes does the workflow route to Step 5 TEST-RUNNER for full-suite verification.

**Order summary:** Iteration 1 (migration + helpers.zig) → Iteration 2 (SVC/ADP/tenant-config, 5 files) → Iteration 3 (OIDC shared-helper trio, 3 files) → Iteration 4 (OIDC inline trio, 3 files, FINAL). Total: 2 + 5 + 3 + 3 = 13 files, none exceeding 5 per iteration.

**Not touched (any iteration):** `migrations/GBL-084_rls_removal.sql` (left as-is — see §5.2), `env01_test.zig`, `env02_test.zig`, `env03_test.zig`, `env05_test.zig`, `env01_tenant_type_field_test.zig`, `iss107_tenant_storage_mode_test.zig`, `spt01_provisioning_test.zig`, and every non-`tenant`-table INSERT in the originally-grepped file set.
