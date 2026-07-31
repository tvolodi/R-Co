# ISS-0100 Rework 1 — Guard Slug Scoping (GitHub #357)

**Type:** E (novel / cross-cutting — one new global migration + one tooling script edit + one test-hygiene
fix; none is a Type A–D lego pattern)
**Run:** WF03-iss0100-20260731, rework_count 2 (this revision addresses CODE-DESIGN-VALIDATOR's second
FAIL, handoff `wf03-iss0100-step-02d`)
**Author:** CODE-DESIGNER
**Input:** `docs/issue-reports/ISS-0100-rework1-diagnosis.yaml` (`recommendation_for_fix_design`);
CODE-DESIGN-VALIDATOR rework-2 FAIL findings `ISS-0100-REWORK1-VALIDATION-01` (BLOCKER) and
`ISS-0100-REWORK1-VALIDATION-02` (MINOR)
**Scope size:** 3 files total (1 new migration, 1 lint script edit, 1 test-file cleanup fix) — well within
the 5-file-per-iteration constraint. **No multi-iteration split needed for this rework.**

---

## 1. Problem recap (from the rework diagnosis)

ISS-0100's original fix (13 files + `migrations/GBL-102_iss503_guard_tenant_type_scope.sql`) correctly
scoped the ISS-503 pre-flight guard to `tenant_type = 'production'` rows only. That fix is **not being
reverted or altered in its tenant_type logic** — see §5 (no-regression confirmation) below.

The rework gap: `tests/integration/adp04b_tenant_realm_binding_test.zig` and
`tests/integration/tm01_tenant_list_test.zig` legitimately call `service.createTenant()` /
`registry.createTenant()` — the real production tenant-creation API path, which intentionally omits
`tenant_type` (defaulting to `'production'` per `GBL-080_env01_tenant_type_field.sql`) because these
tests are specifically asserting on real production-shaped tenant behavior (default realm backfill,
real HTTP-shaped list output). Their `defer cleanupTenantBySlug(...)` is correctly armed before any
fallible call and does clean up at the end of each test's own lifecycle. The failure is not a missing
cleanup — it is that `TestHarness.init()` re-evaluates the guard on **every single call**, throughout the
full ~700-test binary's lifetime (not once at startup — confirmed via `src/db/migrations.zig`'s
live `SELECT version FROM public.schema_migrations` re-query on every `Migrations.run()` call), so any
other test's `TestHarness.init()` can observe an adp04b/tm01 fixture row mid-flight, between its creation
and its own end-of-test `defer` cleanup, and trip the guard.

Per the diagnosis's ranked recommendation, the correct fix layer is the **guard itself**, not the
producers (adp04b/tm01's cleanup code is already correct and is not being touched).

---

## 2. PREFERRED fix — new migration, guard scoped by slug convention

### 2.1 Verifying the naming convention (re-checked directly, not trusted from the diagnosis summary)

Grepped `tests/integration/` for every literal tenant slug passed to `service.createTenant()` /
`registry.createTenant()` and for every raw `INSERT INTO tenant (...)` that omits `tenant_type`
(the only two ways a row can land as `tenant_type='production'`):

```
grep -rn "service\.createTenant(\|registry\.createTenant(\|\.createTenant(" tests/integration/
```

Result: **exactly two files** call these production-path APIs anywhere in the integration suite:

- `tests/integration/adp04b_tenant_realm_binding_test.zig` — slugs `tc-adp-04b-02-no-realm`,
  `tc-adp-04b-03-compat`, `tc-adp-04b-04-tenant`, `tc-adp-04b-04-duplicate`,
  `tc-adp-04b-05-default-mismatch`, `tc-adp-04b-06-default-normalized`
- `tests/integration/tm01_tenant_list_test.zig` — slug `tc-tm-01-01`, `tc-tm-03-01..04`,
  and `runtimeFixtureSlug(alloc, "tc-tm-04-01", ...)` / `"tc-tm-04-02"` / `"tc-tm-04-04"` /
  `"tc-tm-05-01"` / `"tc-tm-05-02"` / `"tc-tm-05-03"` (a SHA-256-derived-suffix helper, but the
  **prefix argument** is always a literal starting with `tc-`)

Every single slug in both files starts with the literal prefix `tc-`. This confirms the diagnosis's
finding directly against source, not just by summary.

Cross-check — other files that also insert into `tenant` but were correctly **not** flagged by the
original fix or this rework, to make sure `tc-%` isn't accidentally too narrow or too wide:

- `tests/integration/oidc11_identity_stability_test.zig`, `oidc35_onboarding_test.zig` use non-`tc-`
  slugs (`oidc11-tenant-01`, `unique-host-test-10`, `unique-slug-test-11`) but their raw
  `INSERT INTO tenant (...)` statements **explicitly pass `tenant_type = 'test'`** — they never rely on
  the default, so they were never `'production'` rows and are irrelevant to this guard regardless of
  slug prefix.
- `tests/integration/oidc12_realm_tenant_binding_test.zig`, `oidc15_realm_deletion_test.zig` use
  `tc-oidc12-*` / `tc-oidc15-*` slugs with explicit `tenant_type` columns in their INSERTs too — already
  covered by `tc-%` and already non-default anyway (belt-and-suspenders).
  `tests/integration/env01_test.zig`'s TC-ENV-01-08 deliberately constructs a `tenant_type = .production`
  input (`slug = "tc-env01-08-prod"`) to assert the saga **rejects** it before any row is persisted
  (`expectError(error.ProductionTenantMustNotHaveRef, ...)`) — no row ever lands in `public.tenant`, and
  the slug is `tc-`-prefixed regardless, so it is unaffected either way.
- `tests/integration/oidc14_realm_provisioning_test.zig` is a pure builder-function test (no DB
  connection, no `TestHarness.init()` at all) — irrelevant to the guard.

**Conclusion:** `slug NOT LIKE 'tc-%'` is precisely correct — neither too broad (it does not exempt any
row that is actually a real, non-fixture production tenant, since no such tenant would ever be named
`tc-*`) nor too narrow (it covers every current call site that can produce a `tenant_type='production'`
fixture row). No more precise anchor (e.g. requiring a longer structured suffix) is warranted: a simple
prefix match is sufficient and any tighter pattern would risk missing a legitimate but differently-suffixed
`tc-`-prefixed fixture in the future. The prefix character class does not need per-project-area anchoring
(`tc-adp-`, `tc-tm-`, etc.) — the flat `tc-%` prefix already discriminates correctly against real
production tenant slugs, which by definition are business-chosen names, not test-case identifiers.

### 2.2 Migration numbering (re-checked against current disk state, not assumed)

```
ls migrations/GBL-1*.sql | sort
```
Current highest: `GBL-102_iss503_guard_tenant_type_scope.sql`. Full `migrations/` directory listing
(sorted) confirms no `GBL-103` or higher exists anywhere on disk. **Next available number: `GBL-103`.**

New file: **`migrations/GBL-103_iss0100_guard_tc_slug_scope.sql`**

### 2.3 Design rationale — new file, not in-place edit (same pattern as GBL-102 §"WHY A NEW FILE")

Identical reasoning to GBL-102's own header comment, restated for this file: migrations are tracked by
filename in `public.schema_migrations`, and an already-recorded filename is never re-read or re-executed
(`src/db/migrations.zig`: `if (applied.contains(filename)) continue;`). In any environment where GBL-102
has already recorded itself as applied (which is exactly the state ISS-0100's original fix put every
existing environment into, once it stopped perpetually failing), editing GBL-102's WHERE clause in place
would be inert — the runner would never re-read the edited file. This migration instead **republishes**
GBL-102's full body (identical DDL, identical structure, identical NOTICE messages) under a new filename,
with only the guard's WHERE clause narrowed further to also exclude `tc-%`-prefixed slugs. Because
migration filenames sort and apply in order, and GBL-102's own guard will already be satisfied (or
perpetually retrying) independently, GBL-103 runs after it and either:

- No-ops immediately if GBL-102 already succeeded and recorded itself (RLS removal DDL is idempotent —
  `IF EXISTS` / `DROP COLUMN IF EXISTS` throughout, so re-running it is always safe), or
- Succeeds where GBL-102 could not, the first time a `tc-%` fixture row is the only thing keeping the
  unscoped-by-slug guard tripped.

### 2.4 Exact guard WHERE clause

Current guard (GBL-102, lines 72–76):

```sql
SELECT count(*) INTO v_legacy_count
FROM public.tenant
WHERE storage_mode = 'LEGACY_RLS'
  AND tenant_type = 'production';
```

New guard (GBL-103):

```sql
SELECT count(*) INTO v_legacy_count
FROM public.tenant
WHERE storage_mode = 'LEGACY_RLS'
  AND tenant_type = 'production'
  AND slug NOT LIKE 'tc-%';
```

This is a pure narrowing (adds one `AND` clause) — it cannot cause the guard to pass in a case where the
current GBL-102 guard would correctly fail (any row that is `tenant_type='production'` AND does **not**
start with `tc-` is still counted, exactly as before). It can only cause the guard to additionally pass
in cases where the only blocking rows are `tc-*` test fixtures — the exact and only class of row this
rework is scoped to exclude.

### 2.5 Full migration file body (illustrative — full republished DDL, header comment included)

```sql
-- GBL-103: ISS-0100 rework 1 (GitHub #357) — further scope the ISS-503 guard
-- (already scoped to tenant_type='production' by GBL-102) to also exclude
-- test-fixture tenant slugs matching the 'tc-%' naming convention used
-- throughout tests/integration/.
--
-- WHY A NEW FILE INSTEAD OF EDITING GBL-102 IN PLACE:
-- Same rationale as GBL-102's own header (migrations/GBL-102_iss503_guard_tenant_type_scope.sql
-- "WHY A NEW FILE INSTEAD OF EDITING GBL-084 IN PLACE"): migrations are tracked
-- by filename in public.schema_migrations and an already-recorded filename is
-- never re-read (src/db/migrations.zig `if (applied.contains(filename)) continue;`).
-- In any environment where GBL-102 already recorded itself as applied, editing
-- GBL-102's guard SQL in place would be inert. This file republishes GBL-102's
-- full body unchanged, with the guard's WHERE clause narrowed to additionally
-- exclude slug LIKE 'tc-%' fixture tenants.
--
-- WHY 'tc-%' AND NOT A TENANT_TYPE-BASED FIX:
-- adp04b_tenant_realm_binding_test.zig and tm01_tenant_list_test.zig legitimately
-- exercise the real service.createTenant() production API path (asserting real
-- default-realm backfill / real HTTP-shaped list output) — converting them to
-- tenant_type='test' would falsify what they test. Their per-test `defer`
-- cleanup is already correct; the gap is that the guard re-evaluates on EVERY
-- TestHarness.init() call across the ~700-test binary's lifetime, so any other
-- test's init() can observe an adp04b/tm01 fixture row in its transient
-- in-flight window. See docs/issue-reports/ISS-0100-rework1-diagnosis.yaml for
-- full mechanism analysis. Every tenant slug created via service.createTenant()/
-- registry.createTenant() across the whole tests/integration/ tree is prefixed
-- 'tc-' (grep-verified at design time; see src/design/iss0100-rework1-guard-slug-scoping.md
-- §2.1) — a real production tenant would never be named 'tc-*'.
--
-- Idempotent: all DDL uses IF EXISTS / DROP COLUMN IF EXISTS, safe to re-run
-- even where GBL-102 already fully succeeded.
-- GBL-prefix: operates on public schema; exempt from lint_migration_schema.py
-- business-table check.

DO $$
DECLARE
    v_legacy_count INTEGER;
    v_tenant_table_exists BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'tenant'
    ) INTO v_tenant_table_exists;

    IF v_tenant_table_exists THEN
        SELECT count(*) INTO v_legacy_count
        FROM public.tenant
        WHERE storage_mode = 'LEGACY_RLS'
          AND tenant_type = 'production'
          AND slug NOT LIKE 'tc-%';

        IF v_legacy_count > 0 THEN
            RAISE EXCEPTION 'ISS-503 pre-flight failed: % tenant(s) still in LEGACY_RLS mode. All tenants must be cut over to SCHEMA before RLS removal.', v_legacy_count;
        END IF;
    ELSE
        RAISE NOTICE 'GBL-103: public.tenant table does not exist. Assuming legacy cleanup already occurred.';
    END IF;

    RAISE NOTICE 'GBL-103: Pre-flight check PASSED — Proceeding with RLS removal.';

    -- Group 1: RLS-protected tables — disable RLS, drop policy, drop tenant_id
    -- (identical to GBL-102/GBL-084 — unchanged, idempotent)
    ALTER TABLE IF EXISTS public.process_definitions DISABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS process_definitions_tenant_policy ON public.process_definitions;
    ALTER TABLE IF EXISTS public.process_definitions DROP COLUMN IF EXISTS tenant_id;

    ALTER TABLE IF EXISTS public.instance_projections DISABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS instance_projections_tenant_policy ON public.instance_projections;
    ALTER TABLE IF EXISTS public.instance_projections DROP COLUMN IF EXISTS tenant_id;

    ALTER TABLE IF EXISTS public.tasks DISABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS tasks_tenant_policy ON public.tasks;
    ALTER TABLE IF EXISTS public.tasks DROP COLUMN IF EXISTS tenant_id;

    ALTER TABLE IF EXISTS public.tokens DISABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS tokens_tenant_policy ON public.tokens;
    ALTER TABLE IF EXISTS public.tokens DROP COLUMN IF EXISTS tenant_id;

    ALTER TABLE IF EXISTS public.audit_entries DISABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS audit_entries_tenant_policy ON public.audit_entries;
    ALTER TABLE IF EXISTS public.audit_entries DROP COLUMN IF EXISTS tenant_id;

    ALTER TABLE IF EXISTS public.audit_log DISABLE ROW LEVEL SECURITY;
    DROP POLICY IF EXISTS audit_log_tenant_policy ON public.audit_log;
    ALTER TABLE IF EXISTS public.audit_log DROP COLUMN IF EXISTS tenant_id;

    -- Group 2: Non-RLS tables that had tenant_id column (identical, unchanged)
    ALTER TABLE IF EXISTS events DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS events_archive DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS instance_sequence DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS event_type_registry DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS event_retention_policies DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS public.timers DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS public.users DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS public.groups DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS public.group_members DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS public.roles DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS public.user_roles DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS public.api_tokens DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS public.webhook_subscriptions DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS public.webhook_deliveries DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS public.dead_letter_items DROP COLUMN IF EXISTS tenant_id;
    ALTER TABLE IF EXISTS public.repository_form_schemas DROP COLUMN IF EXISTS tenant_id;

    -- Group 3: Drop RLS helper function (identical, unchanged)
    DROP FUNCTION IF EXISTS public.bpm_effective_tenant_id() CASCADE;

    RAISE NOTICE 'GBL-103: RLS removal complete. tenant_id columns and RLS policies removed from public business tables.';
END $$;
```

BACKEND-DEV implementing this handoff should copy GBL-102's DDL groups verbatim (they are already
correct and unchanged) and apply only the WHERE-clause addition and header/NOTICE renaming shown above.

---

## 3. SUPPLEMENTARY — lint extension (`tools/lint_test_isolation.py`)

### 3.1 Purpose

The `tc-%` exclusion in §2 is currently informal — nothing enforces that a future test author who calls
`service.createTenant()` / `registry.createTenant()` (or writes a raw `INSERT INTO tenant` that omits
`tenant_type`) uses a `tc-`-prefixed slug. If they don't, their fixture row silently defeats GBL-103's
exclusion and reintroduces exactly this rework's failure mode for a slug the guard doesn't recognize.
This extension makes the convention machine-checked instead of tribal knowledge.

### 3.2 Existing script structure (read before designing the extension)

`tools/lint_test_isolation.py` is a single-pass linter over `tests/integration/*.zig`. It already has:
a `Report`/`Issue` dataclass pair with `severity`/`code`/`file`/`line`/`message`; a `find_test_blocks()`
helper that returns `(name, start, end)` byte-span tuples for every `test "..." { ... }` block via
brace-depth matching; a per-block-and-per-file `lint_file(path, report)` entry point; existing checks
T010 (hardcoded UUID), T020 (module-level `var`), T030 (alloc without defer), T040 (skip on MUST), T050
(missing `BPM_TEST_DB_URL` reference); a JSON baseline-suppression mechanism (`--baseline`,
`lint_test_isolation.baseline.json`) so pre-existing, accepted findings don't reblock CI; and a `main()`
that exits 1 on any BLOCKER/MAJOR.

### 3.3 New check: T060 — un-prefixed slug on a production-defaulting tenant-creation call

**New severity/code:** `MAJOR`, code `T060`.

**What it flags:** any source location in a `tests/integration/*.zig` file where a tenant row can be
created with `tenant_type` defaulting to `'production'` (i.e. the two patterns identified in §2.1 as the
only ways this happens), and the slug value used is not provably prefixed with an allowlisted
test-fixture prefix.

**Detection patterns (two independent sub-checks, both feeding the same T060 code):**

1. **Production-API call sites.** Regex-match calls of the shape
   `\b(?:service|registry|self\.\w+)?\.createTenant\s*\(` (mirroring the two real call sites found in
   §2.1: `service.createTenant(...)` in `adp04b_tenant_realm_binding_test.zig` and
   `tm01_tenant_list_test.zig`'s `createTestTenant()` wrapper, which itself calls
   `service.createTenant(...)`). For each match, look backward within the enclosing `test "..." { }`
   block (reuse `find_test_blocks()`) for the nearest preceding `const <slug_var> = "..."` or
   `const <slug_var> = try runtimeFixtureSlug(alloc, "...", ...)` assignment that is passed as an
   argument to the `createTenant`/wrapper call (simple heuristic: the identifier used as the
   `slug`/`tenant_slug` field in the call's argument struct, traced to its nearest preceding
   string-literal-valued `const` in the same block — this mirrors the existing `ALLOC_HINT`/`DEFER_HINT`
   block-local regex style already used for T030, not a full AST/dataflow analysis). If the resolved
   literal (or the literal `prefix` argument to `runtimeFixtureSlug`) does not start with an allowlisted
   prefix, emit T060.

2. **Raw INSERT sites that omit `tenant_type`.** Regex-match
   `INSERT INTO (?:public\.)?tenant\s*\(([^)]*)\)` (multiline, matching the Zig multiline-string SQL
   literal style already used throughout `tests/integration/*.zig`, e.g.
   `\\INSERT INTO tenant (id, slug, ...)`). Parse the captured column list; if `tenant_type` is **absent**
   from the column list (meaning the row will take the schema default `'production'` per
   `GBL-080_env01_tenant_type_field.sql`), locate the nearest slug-shaped literal or placeholder-bound
   variable passed as the `slug` positional value and apply the same prefix check. If `tenant_type` **is**
   present in the column list (as in `oidc11`/`oidc35`/`oidc12`/`oidc15`/`env01`'s explicit-`tenant_type`
   INSERTs — see §2.1 cross-check), skip the check entirely for that INSERT — an explicit, non-defaulted
   `tenant_type` value is exactly the other already-supported way (per `anti-patterns.md`'s existing
   ISS-0100 entry) to avoid the production-default trap, and is out of scope for T060.

**Allowlisted prefix set:** start with `("tc-",)`. Confirmed by the §2.1 grep sweep: `tc-` is the only
prefix in current use for any slug reaching a `tenant_type`-defaulting code path. Other prefixes found in
the codebase (`oidc11-tenant-`, `unique-host-test-`, `unique-slug-test-`, `test-tenant`, `defaults-test`,
`otp-tenant`) are all attached to either explicit-`tenant_type` INSERTs (out of scope per the paragraph
above) or, for `oidc14`, a file with no DB interaction at all — so none of them need to be allowlisted for
T060 to pass cleanly against the current tree. The allowlist is defined as a single module-level tuple
(e.g. `TENANT_FIXTURE_SLUG_PREFIXES = ("tc-",)`) so a future legitimate second prefix can be added in one
place without touching the check logic.

**Message:** `f'production-defaulting tenant creation with slug "{slug}" does not start with an allowlisted test-fixture prefix {TENANT_FIXTURE_SLUG_PREFIXES} — will not be excluded by the GBL-103 ISS-503 guard scope'`

**Rationale for MAJOR (not BLOCKER):** consistent with T010/T020/T030/T050's existing severity (all
MAJOR) — this is a fixture-hygiene convention violation, not a definitionally-broken test (T040's
skip-on-MUST is the only existing BLOCKER, reserved for tests that silently stop verifying a MUST
requirement). A T060 violation degrades guard robustness for future runs; it does not make the violating
test itself wrong or non-functional today.

**No change needed to:** `Report`/`Issue` dataclasses, `iter_targets()`, baseline suppression, JSON/text
output modes, or `main()`'s exit-code logic — T060 plugs into the existing per-file `lint_file()` pass
exactly like T010/T020/T050 (file-level scan) combined with T030/T040's block-local pattern (per-test-block
scan using `find_test_blocks()`), reusing already-established helpers.

---

## 3.5 Rework-2 completeness audit — blanket `INSERT INTO tenant` grep (redo, per VALIDATION-02)

CODE-DESIGN-VALIDATOR's MINOR finding `ISS-0100-REWORK1-VALIDATION-02` was correct: §2.1's original
verification searched only `.createTenant(` call sites plus a manually-curated list of files this
designer already suspected. That is not a completeness check — it is a confirmation check on a
pre-selected sample. This section redoes it properly, as a blanket sweep.

### 3.5.1 Method

```
grep -rn "INSERT INTO (public\.)?tenant\s*\(" tests/integration/
```

This surfaces **17 files** (confirmed independently, matching CODE-DESIGN-VALIDATOR's own count):
`oidc35_onboarding_test.zig`, `oidc15_realm_deletion_test.zig`, `oidc12_realm_tenant_binding_test.zig`,
`oidc11_identity_stability_test.zig`, `oidc10_attribute_sync_test.zig`, `oidc09_jit_provisioning_test.zig`,
`adp04a_external_identity_linkage_test.zig`, `adp07_agent_role_reserved_usernames_test.zig`,
`svc04_admin_api_test.zig`, `svc01_service_catalog_scope_test.zig`, `tenant_config_realm_test.zig`,
`helpers.zig`, `spt01_provisioning_test.zig`, `test_iss503_rls_removal.zig`,
`iss502_spt_cutover_test.zig`, `iss107_tenant_storage_mode_test.zig`, `env01_tenant_type_field_test.zig`.

For every match, the column list was read and classified:

**(a) `tenant_type` explicitly present in the column list** — never hits the `'production'` default,
out of scope for the guard regardless of slug. Covers: `adp04a` (1), `adp07` (1), `oidc11` (1), `oidc10`
(1), `oidc09` (1), `oidc35` (3), `oidc15` (1), `oidc12` (2), `svc04` (6), `svc01` (2),
`tenant_config_realm_test.zig` (1), and `helpers.zig`'s `svc-t1`/`svc-t2`/SVC-04 fixture block (1
multi-row INSERT, all rows carry `tenant_type = 'test'`). All of these were already correctly excluded
in §2.1 (the `.createTenant()`-based ones) or are additional raw-SQL sites this redo confirms are also
safe on the same basis.

**(b) `tenant_type` omitted (defaults to `'production'` per `GBL-080_env01_tenant_type_field.sql`)** —
requires a cleanup/leak check. Four sites:

1. `helpers.zig` line 350 — the **default seed tenant** (`id = '00000000-0000-0000-0000-000000000000'`,
   `slug = 'default'`), re-asserted via `ON CONFLICT (id) DO UPDATE` on every `TestHarness.init()` call.
   Not a "leak" in the rework's sense at all — it is the system's one required permanent seed row, not a
   test-fixture artifact, and it is **not `tc-`-prefixed** (its slug is `default`) so GBL-103's exclusion
   does not and should not cover it. It is nonetheless safe against the guard because migration
   `087_default_tenant_storage_mode_cutover.sql` unconditionally cuts this specific row over from
   `storage_mode = 'LEGACY_RLS'` to `'SCHEMA'` once its `tenant_schemas` row exists — confirmed by reading
   `087_default_tenant_storage_mode_cutover.sql` lines 57–86. Since the guard only fires on
   `storage_mode = 'LEGACY_RLS' AND tenant_type = 'production'`, this row does not match once 087 has run
   (which happens before any test executes, as part of the standard migration set `TestHarness.init()`
   applies). No action needed — out of scope for this rework, not a regression risk from GBL-102 or
   GBL-103 (this row's guard-safety comes from 087, not from either GBL-10x migration).
2. `spt01_provisioning_test.zig` line 439 (`TC-SPT-01-06`, slug `iss0099-spt0106`) — inserts with
   `storage_mode = 'SCHEMA'` explicit (so it never matches the guard's `LEGACY_RLS` filter regardless of
   `tenant_type`), **and** is cleaned up: `defer { pool.acquire() ... DELETE FROM public.tenant WHERE id
   = $1::uuid ... }` is registered at line 421, **before** the INSERT at line 438–442. No leak, belt-and-
   suspenders cleanup already correct.
3. `iss502_spt_cutover_test.zig` line 145 (`createTenantRow()` helper, slug `iss502-<suffix>`, defaults
   to `LEGACY_RLS` — this is deliberate, per the file's own doc comment: "Create a tenant row in
   LEGACY_RLS mode (the column default)", used to exercise the SPT cutover path under test). Every call
   site (`setupFixture()` at line 365, itself called from all four `TC-ISS502-0N` tests) is preceded by
   `defer cleanupTenant(alloc, &pool, tenant_id, schema_name_str);` registered immediately after
   `tenant_id`/`schema_name_str` are computed and **before** `setupFixture()` runs (line 396, confirmed
   for all four test cases — same pattern repeated at lines 456/516/585). `cleanupTenant()` (line 303)
   ends with `DELETE FROM public.tenant WHERE id = $1::uuid`. **No leak** — this file's own top-of-file
   doc comment ("Every test creates its own fixtures with per-test UUIDs and cleans up via defer (even on
   failure paths)") is accurate and verified. Confirms CODE-DESIGN-VALIDATOR's own note that this file
   needed auditing but was suspected safe.
4. `test_iss503_rls_removal.zig` line 130 (`createTenantRow()` helper, slug `iss503-<suffix>`,
   `storage_mode` passed explicitly as a parameter — callers choose `LEGACY_RLS` or `SCHEMA` per test
   case). The one live call site (`TC-ISS503-01`, line 247, `storage_mode = "LEGACY_RLS"`) is immediately
   followed by `defer deleteTenantRow(&conn, tenant_id);` at line 248 — registered directly after the
   `try createTenantRow(...)` succeeds. `deleteTenantRow()` (line 135) issues
   `DELETE FROM public.tenant WHERE id = $1::uuid`. **No leak.** Confirms CODE-DESIGN-VALIDATOR's own note
   ("cleaned up via deleteTenantRow/defer in the cases reviewed").
5. `iss107_tenant_storage_mode_test.zig` — three live INSERT sites, all analysed in detail below (§3.6):
   TC-ISS-107-03 (`iss107-t3`), TC-ISS-107-04 (`iss107-t4`), TC-ISS-107-05 (`iss107-t5`).

`env01_tenant_type_field_test.zig`'s four `INSERT INTO tenant` occurrences (lines 64, 81, 96, 113) are
**not live code** — they are `//`-commented pseudocode inside unimplemented stub test bodies (each test
body is `TestHarness.init()` + `setup()` + a comment showing the SQL a future implementer should write +
`// CUSTOM:` assertion placeholders, no actual `conn.exec()`/`conn.query()` call). Confirmed by reading
the full file. Not a leak candidate; excluded from the count of live INSERT sites.

### 3.5.2 Audit conclusion

**Exactly one file required a closer look beyond "does it have a `defer`": `iss107_tenant_storage_mode_test.zig`.**
All other omitted-`tenant_type` sites across the 17-file sweep are either not real production-defaulting
rows in practice (explicit `storage_mode='SCHEMA'`), or have correctly-ordered `defer`-based cleanup
already in place, or are the intentionally-permanent, guard-safe default seed tenant. No additional
leak beyond the one investigated in §3.6 was found. The completeness check is now a blanket sweep, not
an incremental extension of a previously-known file list, per VALIDATION-02's recommendation.

---

## 3.6 PRIMARY FIX (rework-2) — `iss107_tenant_storage_mode_test.zig` TC-ISS-107-04 cleanup

### 3.6.1 What CODE-DESIGN-VALIDATOR found

`ISS-0100-REWORK1-VALIDATION-01` (BLOCKER): TC-ISS-107-04 (`check_constraint_rejects_invalid_mode`,
`tests/integration/iss107_tenant_storage_mode_test.zig` lines 182–231) inserts a tenant row at line
192–195 (`slug = 'iss107-t4'`, `tenant_type` and `storage_mode` both omitted, defaulting to
`'production'` / `'LEGACY_RLS'` respectively) with, per the validator, no cleanup anywhere in the test —
unlike its sibling TC-ISS-107-05 (line 266, `slug = 'iss107-t5'`), which is explicitly deleted at line
304 (`DELETE FROM tenant WHERE id = $1::uuid`, inside a dedicated cleanup block at the end of the test
function, lines 299–307).

### 3.6.2 Independent re-verification of the actual runtime behaviour (rework-2 finding)

This designer re-read the full test function (lines 182–231) and the `TestHarness.init()`/`deinit()`
implementation (`tests/integration/helpers.zig` lines 400–504) line by line, plus the underlying pg
driver's transaction primitives (`vendor/pg/pg.zig` — `begin()`/`commit()`/`rollback()` at lines 174–184
simply issue literal `BEGIN`/`COMMIT`/`ROLLBACK` via `simpleQuery()`; `exec()` at line 143 always goes
through `extendedQuery()` regardless of param count; `readUntilReady()` at lines 289–325 only treats a
server `'E'` ErrorResponse as fatal — a `'N'` NoticeResponse, which is what PostgreSQL emits for a
redundant `BEGIN` inside an already-open transaction, falls through the `else` branch and is silently
skipped, so `try h.conn.exec("BEGIN", &.{})` does **not** fail).

**Finding: TC-ISS-107-04 does not actually leak its `iss107-t4` row, on either the pass or the fail
path — the validator's BLOCKER is based on an incomplete transaction-semantics read, not a confirmed
runtime leak.** Mechanism:

- `TestHarness.init()` (line 487) already opens one real transaction via `conn.begin()` before the test
  body runs. `h.deinit()` (registered via `defer h.deinit()` at line 187) always rolls this back
  (line 501: `self.conn.rollback()`, best-effort, `catch {}`).
- The `iss107-t4` row is INSERTed at line 192–195, **inside** that already-open outer transaction.
- Line 201's `try h.conn.exec("BEGIN", &.{})` is a **second `BEGIN` issued while already inside a
  transaction**. PostgreSQL does not support true nested transactions via `BEGIN` — the server treats
  this as a no-op and emits `WARNING: there is already a transaction in progress`, which is a Notice, not
  an Error, so the call succeeds and the test remains inside the **same single real transaction** started
  by `TestHarness.init()`.
- `SAVEPOINT before_bogus` (line 204), the deliberately-failing `UPDATE ... 'BOGUS'` (line 206–209,
  correctly expected to fail with `error.ServerError`), and `ROLLBACK TO SAVEPOINT before_bogus`
  (line 215) all operate correctly within that one real transaction — this part of the test's design is
  sound and is exactly the standard "assert a statement fails, then roll back to a savepoint to keep the
  connection usable" pattern.
- Line 230's `h.conn.exec("ROLLBACK", &.{}) catch {}` is a **real `ROLLBACK`** (not a savepoint rollback)
  — it ends and rolls back the *entire* outer transaction, which contains the `iss107-t4` INSERT from
  line 192–195 (issued before the no-op nested `BEGIN`, so it is part of the same transaction being
  rolled back here). The row is undone at this point, on the happy path.
- On any assertion failure before line 230 (e.g. `expectError`/`expectEqualStrings` at lines 212/227
  returning early via `try`), line 230 is skipped, but `defer h.deinit()` (registered at line 187) still
  runs and calls `self.conn.rollback()`, which rolls back the same still-open outer transaction — the row
  is undone on the failure path too.

**This does not mean the fix should be dropped.** The mechanism above is correct but fragile and
non-obvious: it depends on the reader knowing that PostgreSQL's `BEGIN` does not nest, that a redundant
`BEGIN`'s WARNING is a Notice rather than an Error at the wire-protocol level, and that the test's own
explicit `ROLLBACK` at line 230 (originally written to restore the connection to a clean state, not with
INSERT-cleanup in mind) happens to also undo the INSERT as a side effect. A future edit to this test —
e.g. changing the inner `ROLLBACK` to a `COMMIT` for some unrelated reason, or restructuring the
transaction handling — would silently reintroduce a real, permanent leak with no test failure to signal
it, exactly the failure mode this whole rework exists to close. Per the rework-2 handoff's explicit fix
direction and as defense-in-depth against that fragility, this design still adds an **explicit,
mechanism-independent cleanup** to TC-ISS-107-04, matching TC-ISS-107-05's own belt-and-suspenders style
rather than relying on transaction-nesting semantics being understood correctly forever.

### 3.6.3 TC-ISS-107-05's existing cleanup pattern (reference, read exactly)

TC-ISS-107-05 (`provisioned_tenant_has_schema_storage_mode`, lines 237–308) does **not** use
`TestHarness`/`h.conn` at all — it opens its own `Pool` (`setup_pool`, line 251) and does the INSERT
(line 265–268), the storage_mode UPDATE-and-verify (lines 271–296) inside one `{ ... }` block that
acquires and releases a pool connection, then, in a **second, separate** `{ ... }` block (lines 300–307,
after the first block's connection has already been released), acquires another pool connection and runs:

```zig
conn.exec(
    "DELETE FROM tenant WHERE id = $1::uuid",
    &.{tenant_id},
) catch {};
```

This is **not** a `defer` — it is a plain sequential cleanup step at the end of the function, executed
unconditionally only because nothing between the INSERT and this point can return early (every fallible
call in that test uses `try`, and if any of them fails, the function returns before reaching the cleanup
block — TC-ISS-107-05 itself is not defer-guarded against its own mid-test failure either, which is a
pre-existing, narrower version of the same fragility; not in scope to fix here since the validator did
not flag it and it is not the row causing the current BLOCKER).

### 3.6.4 The fix for TC-ISS-107-04 (this design's actual instruction to BACKEND-DEV)

Unlike TC-ISS-107-05, TC-ISS-107-04 uses the shared `h.conn` (from `TestHarness`), not a private pool
connection, and its control flow has multiple `try`-guarded fallible statements between the INSERT and
the end of the test (the deliberately-failing UPDATE, the SAVEPOINT rollback, two more queries/asserts).
A plain sequential DELETE at the bottom of the function (TC-107-05's style) would therefore **not** be
reached on an early return — a `defer`, registered immediately after the INSERT succeeds, is the correct
primitive here (matching the *intent* of TC-107-05's pattern — "explicitly delete the row this test
inserted, don't rely on outer machinery" — while adapting it to TC-107-04's `try`-heavy control flow, the
same way `test_iss503_rls_removal.zig`'s `deleteTenantRow`/`defer` pairing and
`spt01_provisioning_test.zig`'s inline `defer` block already do elsewhere in this same audit).

**Exact change to `tests/integration/iss107_tenant_storage_mode_test.zig`**, immediately after the
existing INSERT at lines 192–195:

```zig
    try h.conn.exec(
        "INSERT INTO tenant (id, slug, display_name, status, idp_realm_id) VALUES ($1::uuid, 'iss107-t4', 'ISS-107 Test Tenant 4', 'ACTIVE', 'realm-iss107-t4')",
        &.{tenant_id_uuid},
    );
    defer h.conn.exec(
        "DELETE FROM tenant WHERE id = $1::uuid",
        &.{tenant_id_uuid},
    ) catch {};
```

This registers the cleanup as a `defer` on the same statement form TC-ISS-107-05 uses
(`"DELETE FROM tenant WHERE id = $1::uuid"`, unqualified — consistent with this file's existing style,
which does not schema-qualify `tenant` the way `helpers.zig`'s `ensureDefaultOidcSeeds()` does; no shadow-
table ambiguity risk here since this is a fresh per-test UUID, not the fixed default-tenant ID that
motivated that qualification in `helpers.zig`), best-effort (`catch {}`, matching every other cleanup
`defer` audited in §3.5.1(b) and TC-ISS-107-05's own `catch {}`).

**Execution order (Zig `defer` unwinds LIFO — reverse registration order):** `defer h.deinit()` is
registered first (line 187); the new cleanup `defer` is registered second (immediately after the INSERT,
~line 196). On function exit, the new cleanup `defer` therefore fires **before** `h.deinit()`. Line 230's
`h.conn.exec("ROLLBACK", &.{})` is inline code, not a `defer`, so on the happy path it has already run by
the time any `defer` unwinding begins — meaning the outer transaction (and the `iss107-t4` INSERT inside
it) is already rolled back before the new cleanup `defer` fires, so its `DELETE` affects 0 rows and is a
harmless no-op (`catch {}` swallows it regardless). On the early-return failure path (an `expectError`/
`expectEqualStrings` fails before line 230), the new cleanup `defer` fires while the row is still live in
the still-open transaction, deleting it explicitly — and only then does `h.deinit()`'s `rollback()` run
(redundantly rolling back a transaction whose one interesting row is already gone). Either path leaves no
`iss107-t4` row behind, and — after this fix — that is true by an explicit statement, not solely as a side
effect of transaction-rollback mechanics the reader has to reconstruct (§3.6.2).

**Net effect:** defense-in-depth. The row was already provably rolled back by existing transaction
mechanics (§3.6.2); this DELETE makes that cleanup explicit and independent of transaction-nesting
semantics, matching the project's established per-test-cleanup convention (T030 in
`tools/lint_test_isolation.py`: "alloc without defer") and directly matching what CODE-DESIGN-VALIDATOR
and the rework-2 handoff asked for.

---

## 3.7 GBL-103 slug pattern — no change needed as a result of this audit

Per §3.5–3.6, no additional slug-prefix broadening of GBL-103's `WHERE` clause is needed: the one
site the validator flagged as a potential real leak (`iss107-t4`) is fixed at the source (§3.6.4) rather
than by widening the guard's exclusion pattern, consistent with the rework-2 handoff's stated preference
("prefer fixing the actual leak over further broadening the slug-exclusion pattern"). §2's `tc-%` pattern
and rationale are unchanged from rework-1.

---

## 4. NOTE ONLY — build.zig `test-integration-env` naming confusion

Per the diagnosis's finding (`separate_binary_hypothesis_ruled_out`), the `env_integration_tests`
b.addTest() artifact (`build.zig` ~line 1414–1427, backing step `test-integration-env`) uses
`root_source_file = "tests/integration/main_test.zig"` — the **same full ~700-test root file** as the
primary `integration_tests` artifact (~line 838, backing `test-integration`). The step name implies a
scoped ENV-01..05-only subset; it is not one. This cost TEST-RUNNER a wasted verification cycle in Step 5
of this WF-03 run (it believed `test-integration-env` gave cross-contention isolation from adp04b/tm0x
and it does not, because they're compiled into that binary too).

**This design does not fix it.** Per the diagnosis's recommendation (3) and the handoff's acceptance
criteria, this is out of scope for the current rework and should not be bundled into it — it is a
genuine, separate, incidentally-discovered defect (misleading build-step naming), not a cause of ISS-0100's
symptom. **ORCH must file this as its own GitHub issue via `gh issue create`** per the No-Issue-Left-Local-
Only directive (CLAUDE.md), before or after this rework completes — not BACKEND-DEV, and not as part of
this handoff's implementation. Suggested filing content: title along the lines of "build.zig
`test-integration-env` step name implies a scoped ENV-01..05 subset but actually compiles the full
integration suite", body citing `build.zig` lines ~838 and ~1414–1427 and the
`separate_binary_hypothesis_ruled_out` finding in `docs/issue-reports/ISS-0100-rework1-diagnosis.yaml` as
the discovery context, recommended fix either renaming the step or giving it a genuinely scoped
`root_module` analogous to `svc_integration_tests`.

---

## 5. No-regression confirmation

This rework **only adds** a `slug NOT LIKE 'tc-%'` clause on top of the existing, already-shipped
`tenant_type = 'production'` scoping — it does not modify, remove, or weaken any part of the
`tenant_type`-based logic that GBL-102 and the original 13-file ISS-0100 fix introduced:

- GBL-102 is not edited in place and is not superseded — it remains on disk, unchanged, and continues to
  run (and, in environments where it already succeeded, remains a no-op re-run) exactly as before. GBL-103
  runs strictly after it in filename order.
- The `tenant_type = 'production'` condition in the guard's WHERE clause is preserved verbatim in GBL-103;
  the new `slug NOT LIKE 'tc-%'` condition is `AND`-ed on top, which can only ever narrow (never widen) the
  set of rows blocking the guard. Any row that was correctly still blocking the guard under GBL-102's logic
  (a real, non-`tc-`-prefixed, `tenant_type='production'`, `storage_mode='LEGACY_RLS'` row) is still blocked
  under GBL-103.
- None of the 12 already-fixed test files from the original ISS-0100 pass (the `tenant_type='test'`
  conversions, the `defer`-based cleanups, `clean_test_db.py`'s sweep filter) are touched by this rework.
  Their behavior, and their interaction with the guard, is unaffected — they were never part of this
  rework's problem (they don't hit the `tenant_type='production'` default path at all).
- `adp04b_tenant_realm_binding_test.zig` and `tm01_tenant_list_test.zig` are **not modified** by this
  design. Their `service.createTenant()` usage and existing `defer cleanupTenantBySlug(...)` pattern are
  confirmed correct (per the diagnosis's `defer_semantics_verification`) and are left exactly as-is —
  the fix is entirely on the guard side, as the diagnosis's `recommendation_for_fix_design` §(1)
  concluded ("The fix belongs on the GUARD, not the producers").
- The lint extension (§3) is purely additive — a new check code (T060) alongside T010–T050, with no
  changes to existing check logic, severities, or the baseline-suppression mechanism. Existing T010–T050
  findings are unaffected.
- The rework-2 addition (§3.6.4, `iss107_tenant_storage_mode_test.zig` TC-ISS-107-04) touches only that
  one test function, adding a single `defer`-registered `DELETE` statement immediately after its existing
  INSERT. It does not change the test's assertions, its SAVEPOINT/ROLLBACK logic, or any other test case
  in the file (TC-ISS-107-01/02/03/05 are untouched). It cannot regress TC-ISS-107-04 itself: per §3.6.2
  the row was already provably rolled back on every path before this change; the new statement only makes
  that outcome explicit and mechanism-independent. It does not touch GBL-102, GBL-103, or the lint script.

---

## 6. Artefacts for this handoff

| File | Type | Action |
|---|---|---|
| `migrations/GBL-103_iss0100_guard_tc_slug_scope.sql` | Type E (global/system migration, not a Type C business-table migration — exempt from `lint_migration_schema.py` per the GBL-prefix convention established by GBL-084/GBL-102) | New file |
| `tools/lint_test_isolation.py` | Type E (tooling script, not application code — no lego-catalog type applies) | Edit — add T060 check + `TENANT_FIXTURE_SLUG_PREFIXES` constant |
| `tests/integration/iss107_tenant_storage_mode_test.zig` | Type E (integration test source, not a lego-catalog type) | Edit — add one `defer`-registered `DELETE FROM tenant WHERE id = $1::uuid` immediately after TC-ISS-107-04's existing INSERT (§3.6.4). No other test case in this file is touched. |

All three files are within the single-iteration 5-file cap; no multi-iteration split is needed for this
rework. (If the rework-2 completeness audit in §3.5 had surfaced additional real leaks beyond
`iss107-t4`, pushing the total file count past 5, this design would instead have flagged the need for a
follow-on iteration rather than silently exceeding the cap — it did not, so no split is required.)

**Not in scope for BACKEND-DEV on this handoff:** filing the `build.zig` `test-integration-env` naming
issue (§4) — that is an ORCH action item, tracked here for visibility only.
