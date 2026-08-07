# ISS-0605 / GH-537 — C4 Schema Baseline Self-Heal + Tenant-Provisioning Lint

**Run ID:** WF03-GH537-20260807
**Issue:** [GH-537](https://github.com/tvolodi/R-Co/issues/537) (ISS-0605)
**Classification:** **Type E** (novel / cross-cutting change spanning a build-graph gate, a Python maintenance script, and a new Python lint tool)
**Step:** WF-03 Step 2 — CODE-DESIGNER fix design
**Upstream artefact:** [diagnosis report](../../docs/issue-reports/ISS-0605-diagnosis.yaml)
**Implementer:** BACKEND-DEV (Step 3), after the CODE-DESIGN-VALIDATOR gate

## Classification rationale

Applying the selection rules in `templates/lego-catalog.md` in order:

1. **Type C?** No. No table/column is added, altered, or removed; no migration file is created. (Migration `1135_iss0114_backfill_public_tenant_storage_mode.sql` backfills the *inverse* asymmetry and remains out of scope — see §1.2.)
2. **Type A?** No. No HTTP route is added. The fix touches only `verify_test_env.py` (a Python gate), `clean_test_db.py` (a Python maintenance script), and a new `lint_test_tenant_provisioning.py` (a Python static-analysis tool).
3. **Type D?** No. No React Flow node.
4. **Type B?** No. No admin/list page.
5. **Type E — yes.** The change is cross-cutting test-infrastructure tooling: a build-graph gate wiring (`zig build test-env-verify` → `clean_test_db` → `verify_schema_baseline`), a static-analysis lint over `tests/integration/*.zig`, and a Zig integration regression test. `templates/lego-catalog.md` reserves shared-infrastructure concerns for Type E, and no Lego piece covers any of these three artefacts.

---

## Module purpose

Make the `zig build test-env-verify` C4 schema-baseline check **self-heal** instead of permanently failing on test-environment data residue, and add a **lint guard** so future integration tests cannot reproduce the same defect class. Concretely:

- **`tools/verify_test_env.py`** — wire a `clean_test_db.py` invocation as a **predecessor** of C4, so transient half-provisioned `public.tenant` rows are removed before the baseline check runs. The current C4 (`check_schema_baseline()` at lines 523–544) reports the orphans but has no path to remove them; it depends only on `verify_schema_baseline.py --check-tenants`, which only detects and never heals.
- **`tools/lint_test_tenant_provisioning.py`** — new Python lint that scans `tests/integration/*.zig` for `INSERT INTO public.tenant` whose row carries `storage_mode='SCHEMA'` *without* a co-located `bpm_provision_tenant_schema()` (or `provisionTenantSchema()`) call in the same function scope, and fails BLOCKER on the omission. This is the **prevention** layer: even if the runtime defence in C4 is bypassed, no new test binary can re-introduce the orphan pattern that ISS-0140 closed and ISS-0605 reports recurring.
- **`tests/integration/iss0605_orphan_self_heal_test.zig`** — new integration regression test that inserts a single half-provisioned `public.tenant` row, runs the C4 path end-to-end, and asserts the row is gone and C4 reports OK. Connects to a real Postgres via `BPM_TEST_DB_URL`.

Out of scope: `src/db/provisioning.zig` (the diagnosis confirmed `provisionTenantSchema()` itself is correct; the bug is in test callers), `tests/integration/tenant_config_realm_test.zig` and `tests/integration/iss107_tenant_storage_mode_test.zig` (their INSERTs are the *symptom*; the lint guard prevents future occurrences without weakening the existing tests), and every migration file (the asymmetry ISS-0605 reports is the *opposite* direction from what any existing migration backfills).

---

## 1. Problem statement

C4 schema baseline fails on `zig build test-env-verify` because the shared `db_test` database (port 5434) holds 5 `public.tenant` rows with `storage_mode='SCHEMA'` and slug pattern `tenant-<uuid>` that were inserted by integration test binaries **without** a matching `public.tenant_schemas` registration or Postgres `tenant_<uuid>` schema — the exact half-provisioned state previously filed as GH-443 / ISS-0140 (closed 2026-08-05). Verified live:

| Source | Count |
|---|---|
| `public.tenant` rows with `storage_mode='SCHEMA'` | 6 (1 legitimate `tenant_default` + 5 orphans) |
| `public.tenant_schemas` rows | 1 (the legitimate `tenant_default`) |
| `information_schema.schemata` matching `LIKE 'tenant_%'` | 1 (the legitimate `tenant_default`) |

The 5 orphans have UUIDs `9d40194d-…`, `b3ebbbe3-…`, `a06b4eba-…`, `c9f860a2-…`, `dabc15e3-…` and `created_at` between 2026-08-07T08:25:39Z and 2026-08-07T08:25:49Z — within seconds of each other, the signature of a single provisioning race captured across multiple binaries.

### 1.1 Why it recurred (and why ISS-0140 didn't fix it)

ISS-0140 closed the same defect class on 2026-08-05 by adding a defensive DELETE in `tools/clean_test_db.py` (lines 332–336):

```sql
DELETE FROM public.tenant t
WHERE t.storage_mode = 'SCHEMA'
  AND t.slug != 'default'
  AND NOT EXISTS (
    SELECT 1 FROM public.tenant_schemas ts WHERE ts.tenant_id = t.id
  )
```

That DELETE **removes the orphans on the next manual cleanup**, but `zig build test-env-verify` does **not** depend on `clean_test_db.py` — `verify_test_env.py` calls `verify_schema_baseline.py --check-tenants` directly. So the orphans have survived every baseline run since they were created, and 5 new orphans have accumulated, confirming the gap.

The diagnosis also flagged a secondary concern: `tools/verify_schema_baseline.py --auto-fix` (lines 173–219) re-emits the **iss0112 schema-ledger-reconcile** migration SQL — which targets `public.schema_migrations` and `public.tenant_schemas`, **not** `public.tenant`. So `--auto-fix` was never going to remove the orphans; only the C4 sweep is.

### 1.2 Approaches explicitly rejected

Carried forward from the diagnosis; the implementer must not reach for any of these:

- **Just DELETE the 5 orphans and ship.** Forbidden by ISS-0140's recurrence: removing them today satisfies C4 but does not prevent the same state on the next test run. The minimum viable fix closes the recurrence window.
- **Add a new migration that DELETEs orphan `public.tenant` rows.** Wrong layer. Migration `1135_iss0114_backfill_public_tenant_storage_mode.sql` already backfills the inverse asymmetry (tenant_schemas row, no public.tenant row); adding the reverse direction mixes test-fixture hygiene into the migration ledger, where `schema_migrations` is meant to record schema shape, not transient test-fixture state. Two migrations with opposite directions on the same column invite future drift.
- **Modify `provisionTenantSchema()` to wrap Step 6a INSERT in the same transaction as Step 4.** This is the ISS-0106 / cross-binary concurrency fix the diagnosis explicitly defers: the upstream race is *cross-binary* (multiple test binaries hitting the same `db_test` container concurrently) and is a larger concurrency undertaking. Bundling it here would (a) grow this fix into a separate ISSUE, (b) require touching `src/db/provisioning.zig`, which this run explicitly must not modify, and (c) leave the test-side caller-omission bug — the one the lint catches — unaddressed.
- **Weaken `check_tenant_schemas_consistent()` to skip orphan rows or return WARN instead of FAIL.** Forbidden by CLAUDE.md "Never satisfy a gate by editing what it measures." The check is correct; the test environment is dirty. The fix must clean the environment, not soften the check.
- **Modify `tests/integration/tenant_config_realm_test.zig` or `tests/integration/iss107_tenant_storage_mode_test.zig` to call `provisionTenantSchema()` themselves.** These tests are *correct as detectors of the caller-omission bug class* — their INSERTs intentionally exercise the public.tenant table without a backing schema (it is what they are testing). Forcing them through `provisionTenantSchema()` would change the test's semantics. The lint guard catches future occurrences in *other* tests; the existing two are exempt from the lint (see §4.2 baseline file).

---

## 2. Affected code — complete verified enumeration

All line numbers were produced by parsing the files on 2026-08-07; if a number has drifted, the implementer searches for the named symbol, not the literal line.

### 2.1 `tools/verify_test_env.py` — the C4 gate

| Lines | Construct | Role in the defect |
|---|---|---|
| 467–488 | `Check` class | One `Check` per gate, `failed = status == BAD`. |
| 511 | `check_schema_baseline()` definition | **Defective function** — runs `verify_schema_baseline.py --check-tenants` and reports FAIL on missing schemas with no self-heal path. |
| 514 | `script = REPO_ROOT / "tools" / "verify_schema_baseline.py"` | The C4 command target. |
| 515–521 | `BPM_TEST_DB_URL` precondition check | C4 already correctly fails with a clear message if the test DB URL is unset. |
| 522 | `run([sys.executable, str(script), "--check-tenants"], timeout=180)` | The single subprocess call C4 makes today. **No `clean_test_db` invocation anywhere in this function.** |
| 666 | `checks.append(check_schema_baseline())` | Where C4 is wired into the gate list. |
| 711–732 | `main()` reporting block | Prints per-check `[OK]/[FAIL]` lines. |

### 2.2 `tools/clean_test_db.py` — the existing sweep

| Lines | Construct | Role |
|---|---|---|
| 46–61 | `run_psql(sql) -> bool` | Single-statement psql exec via `docker-compose exec db_test psql`. |
| 78–124 | `drop_orphaned_tenant_schemas()` | The schema-drop sweep. Out of scope for this fix. |
| 313–319 | Tenant-row cleanup prelude | `DELETE FROM public.tenant WHERE tenant_type = 'test' AND slug != 'default'` followed by `WHERE tenant_type = 'production' AND slug != 'default'`. |
| **332–336** | **GH-443 / ISS-0140 orphan sweep** | **`DELETE FROM public.tenant t WHERE t.storage_mode = 'SCHEMA' AND t.slug != 'default' AND NOT EXISTS (SELECT 1 FROM public.tenant_schemas ts WHERE ts.tenant_id = t.id)`.** This is the canonical remediation C4 will invoke. |
| 338–340 | `drop_orphaned_tenant_schemas()` call | Drops leaked Postgres schemas whose `tenant_schemas` row exists but the schema is gone — separate from the orphan-row sweep. |

The orphan-row DELETE at 332–336 must be **preserved verbatim**. C4 invokes this script as a subprocess and trusts the existing behaviour.

### 2.3 `tools/verify_schema_baseline.py` — the C4 command target

| Lines | Construct | Role |
|---|---|---|
| 127–149 | `check_tenant_schemas_consistent(conn) -> list[str]` | The C4 detector. Iterates `public.tenant WHERE storage_mode='SCHEMA'` and asserts each `tenant_<id>` schema exists in `information_schema.schemata`. |
| 135 | `tenant_id_s = str(tenant_id)` | |
| 137–140 | `schema_name = "tenant_" + tenant_id_s.replace("-", "")` | The expected schema name; this is what the orphan row does *not* have. |
| 142–148 | `information_schema.schemata` lookup | The drift detector. |

`check_tenant_schemas_consistent()` is **correct as-is** and is not modified. C4 self-heals by **running the sweep before this script**, not by editing the detector.

### 2.4 New files

| Path | Purpose |
|---|---|
| `tools/lint_test_tenant_provisioning.py` | New Python static-analysis tool, exits 0/1/2. |
| `tests/integration/iss0605_orphan_self_heal_test.zig` | New Zig regression test, connects to real Postgres via `BPM_TEST_DB_URL`. |
| `tests/integration/_fixtures/lint_tenant_provisioning/bad_orphan_insert_test.zig` | Lint fixture: a fixture file containing a SCHEMA-mode INSERT with no provisionTenantSchema call, expected to produce 1 BLOCKER. |
| `tests/integration/_fixtures/lint_tenant_provisioning/good_provisioned_insert_test.zig` | Lint fixture: a fixture file containing a SCHEMA-mode INSERT *with* a co-located `provisionTenantSchema()` call, expected to produce 0 BLOCKER. |
| `tools/lint_test_tenant_provisioning.baseline.json` | Baseline file consumed by the lint, matching the style of `tools/lint_test_isolation.baseline.json`. Used to exempt known-good call sites (the two existing tests, see §4.2). |

### 2.5 Tests that exercise the orphan pattern (context only — not modified)

| Path | What it does today |
|---|---|
| `tests/integration/tenant_config_realm_test.zig` lines 80–105 | `insertTestTenant()` INSERTs `public.tenant` with `storage_mode='SCHEMA'` (via the column default) but never calls `provisionTenantSchema()`. Cleanup at lines 117–121 only DELETEs the row, because no schema was ever created. **Exempt from lint via baseline.** |
| `tests/integration/iss107_tenant_storage_mode_test.zig` lines 242–260 | Some sub-tests directly UPDATE `storage_mode='SCHEMA'` on a freshly INSERTed `public.tenant` row without going through `provisionTenantSchema()`. **Exempt from lint via baseline.** |

The baseline entry lists these two files with the regex that identifies their exempt INSERT patterns, so any future `INSERT INTO public.tenant ... 'SCHEMA'` *outside* those files (and outside the fixture files) is BLOCKER.

---

## 3. Design — three layers

### 3.1 Layer 1 — C4 self-heal in `verify_test_env.py` (primary fix)

#### 3.1.1 Helper function

Introduce one file-local helper, `_run_clean_test_db_sweep()`, sitting alongside `check_schema_baseline()` in `verify_test_env.py`. Signature:

```
def _run_clean_test_db_sweep() -> Check:
    """Run tools/clean_test_db.py's orphan-row sweep in-process.
    Returns a Check whose PASS/FAIL/SKIP status reports whether the sweep
    ran successfully. Never raises; non-zero exit returns a Check(BAD)."""
```

Behaviour, in order:

1. Resolve `REPO_ROOT / "tools" / "clean_test_db.py`. If absent, return `Check("C4 cleanup pre-step", SKIP, "clean_test_db.py not present")`.
2. If `BPM_TEST_DB_URL` is unset, return `Check("C4 cleanup pre-step", SKIP, "BPM_TEST_DB_URL not set")`. This is the same precondition C4 already enforces; the helper exists to keep both checks aligned.
3. Invoke `python clean_test_db.py` as a subprocess, inheriting the current environment so `BPM_TEST_DB_URL` reaches it. Capture combined stdout+stderr, 120s timeout.
4. **On non-zero exit**, return `Check("C4 cleanup pre-step", BAD, "<first line of stderr or stdout>", "python tools/clean_test_db.py — fix the cleanup failure above")`. The C4 gate does not silently mask the cleanup failure.
5. **On exit 0**, return `Check("C4 cleanup pre-step", OK, "<first line of clean_test_db output, if any, else 'sweep exited 0'>")`.

The helper invokes `clean_test_db.py` in its **default** mode (no `--include-fixtures`); the `--include-fixtures` flag is operator-curated and C4 must not flip it.

#### 3.1.2 Wiring into `check_schema_baseline()`

Modify `check_schema_baseline()` at lines 511–535 so the **first** thing it does — after the script-existence and `BPM_TEST_DB_URL` precondition checks — is invoke the helper:

```
def check_schema_baseline() -> Check:
    pre_step = _run_clean_test_db_sweep()
    if pre_step.failed:
        return pre_step
    if pre_step.status == SKIP:
        # Skip is informational, not fatal — fall through to the existing check.
        # (The downstream check will fail with a clearer message anyway.)
        pass
    # ...existing code (lines 514–535) unchanged.
```

This guarantees the orphan-row sweep runs **before** `verify_schema_baseline.py --check-tenants`, every time C4 runs.

#### 3.1.3 What this does and does not guarantee

**Does:** within a single `python tools/verify_test_env.py` invocation, any orphan `public.tenant` row is removed before C4's drift detector runs. `clean_test_db.py` runs at most once per invocation (C4 is the only caller), regardless of how many other checks also touch the test DB.

**Does not:** constrain anything outside one invocation — a developer running `python tools/clean_test_db.py` in another terminal while a suite is running, two workspaces pointed at the same database, or CI overlapping two jobs. Those exposures are exactly what Layer 2 (the lint) closes.

#### 3.1.4 Interaction with existing C4 flow — must be preserved

- The existing `[OK] check_tenant_schemas_consistent` message at `verify_schema_baseline.py` lines 268–270 is unchanged.
- The existing `[FAIL]` detail line at lines 263–266 is unchanged.
- The `--auto-fix` flag at `verify_schema_baseline.py` lines 173–219 is unchanged. (It is a separate remediation path; C4 self-heal is the *primary* path, `--auto-fix` remains the operator-initiated path.)
- `BPM_TEST_DB_URL` is read once in the helper and inherited by the subprocess. No new env-var handling.

### 3.2 Layer 2 — `lint_test_tenant_provisioning.py` (prevention)

#### 3.2.1 Helper API

The lint takes one or more paths to scan (default: `tests/integration/`) and exits with:

| Exit code | Meaning |
|---|---|
| 0 | No BLOCKER / MAJOR findings |
| 1 | One or more BLOCKER / MAJOR findings |
| 2 | Bad invocation (missing path, missing baseline, etc.) |

A `Report` dataclass (same shape as `lint_test_isolation.py`'s) collects `Issue(severity, code, file, line, message)` entries.

#### 3.2.2 What it greps for

For every `.zig` file under the scanned path, the lint parses the file and:

1. Finds every `test "..."` block (regex: same as `lint_test_isolation.py` line 49: `TEST_BLOCK`).
2. Inside each test block, looks for:
   - `INSERT INTO (public\.)?tenant` matching an INSERT whose column list contains `storage_mode` and whose value list contains `'SCHEMA'` (case-insensitive, whitespace-tolerant).
   - Or: an `INSERT INTO (public\.)?tenant` followed (within the same test block) by a `UPDATE tenant ... SET storage_mode = 'SCHEMA'` statement. This catches the `iss107` pattern (insert row, then flip the mode).
3. For each such INSERT/UPDATE pair, asserts a `bpm_provision_tenant_schema(` or `provisionTenantSchema(` token appears **somewhere in the same test block**, case-sensitive. "Same test block" = within the `test "..." { ... }` braces. The lint does **not** require the call to immediately follow the INSERT — co-location is what prevents the orphaned-row pattern, not strict adjacency.
4. If the INSERT/UPDATE is found but the provisionTenantSchema call is absent, emit a BLOCKER with code **T070** and message: "test inserts public.tenant row with storage_mode='SCHEMA' without co-located bpm_provision_tenant_schema() — would leave an orphan on cleanup failure (ISS-0605)".
5. If the test block is **exempt** (see §3.2.3 baseline), skip the BLOCKER.

The lint does **not** scan for general SQL injection patterns, FK hygiene, or anything outside the storage_mode='SCHEMA' INSERT co-location rule. Its scope matches its name and ISS-0605.

#### 3.2.3 Baseline file

`tools/lint_test_tenant_provisioning.baseline.json` mirrors the structure of `tools/lint_test_isolation.baseline.json`:

```json
{
  "version": 1,
  "exempt_test_files": {
    "tests/integration/tenant_config_realm_test.zig": {
      "reason": "ISS-0072 / OIDC-F-05 — exercises public.tenant metadata without a backing schema by design (the schema is provisioned by SPT-01 integration, not here)",
      "permit_patterns": [
        "INSERT INTO public.tenant \\([^)]*\\)"
      ]
    },
    "tests/integration/iss107_tenant_storage_mode_test.zig": {
      "reason": "ISS-107 — directly tests the storage_mode column UPDATE; inserting without provisionTenantSchema is the test",
      "permit_patterns": [
        "INSERT INTO tenant ",
        "UPDATE tenant SET storage_mode"
      ]
    }
  },
  "exempt_fixture_files": [
    "tests/integration/_fixtures/lint_tenant_provisioning/bad_orphan_insert_test.zig",
    "tests/integration/_fixtures/lint_tenant_provisioning/good_provisioned_insert_test.zig"
  ]
}
```

`_fixtures/lint_tenant_provisioning/bad_orphan_insert_test.zig` is itself expected to produce 1 BLOCKER when linted in isolation. The lint's `lint_tenant_provisioning_test.zig` runs the lint over `tests/integration/_fixtures/lint_tenant_provisioning/` *with the baseline disabled* (or with the fixture directory removed from `exempt_fixture_files` for the duration of the test) to assert the bad file trips the lint and the good file does not. Concretely: the test passes `--no-baseline` to the lint with the fixture dir as the lone scanned path, asserts exit code 1, asserts the report contains exactly one T070 entry naming `bad_orphan_insert_test.zig`, and asserts zero T070 entries naming `good_provisioned_insert_test.zig`.

#### 3.2.4 Wiring into the gate

The lint is wired into `verify_test_env.py` as a **new C8 check**, sitting between the existing C7 (bench DB URL) and the bottom of `main()`'s `checks = []` list:

```python
def check_tenant_provisioning_lint() -> Check:
    script = REPO_ROOT / "tools" / "lint_test_tenant_provisioning.py"
    if not script.is_file():
        return Check("C8 tenant provisioning lint", SKIP, "lint_test_tenant_provisioning.py not present")
    code, out = run([sys.executable, str(script), "tests/integration"], timeout=120)
    if code != 0:
        blockers = [l for l in out.splitlines() if "BLOCKER" in l]
        detail = blockers[0] if blockers else (out.splitlines()[0] if out else "non-zero exit")
        return Check("C8 tenant provisioning lint", BAD, detail, "fix the provisioning violations above")
    return Check("C8 tenant provisioning lint", OK, "no BLOCKER findings")
```

C8 is run after C7. If C8 fails, the gate exits 1 — the same contract as every other check.

#### 3.2.5 What this does and does not guarantee

**Does:** prevent *new* tests from being merged that exhibit the caller-omission bug. Any future test that inserts a SCHEMA-mode public.tenant row without co-locating `provisionTenantSchema()` fails `zig build test-env-verify` at C8.

**Does not:** rewrite or rewrite history on the two exempt existing tests — those remain exempt because changing their semantics would alter what they test. It also does not catch pre-existing orphan rows in the database (that is Layer 1's job).

### 3.3 Layer 3 — regression test `tests/integration/iss0605_orphan_self_heal_test.zig`

A single Zig test binary that runs against the real test database. Skeleton (describes structure only — implementer writes the body per the conventions in `docs/guides/backend_developer_guide.md` §3–§5):

1. Connect to `BPM_TEST_DB_URL` via `Pool.init()`.
2. Generate a per-test UUID via `randomUuidStr(allocator)` (the existing helper pattern from `tenant_config_realm_test.zig`).
3. Insert a single orphan row directly:

   ```zig
   try conn.exec(
       "INSERT INTO public.tenant (id, slug, display_name, status, idp_realm_id, tenant_type, production_tenant_id) "
       "VALUES ($1::uuid, $2, $3, 'ACTIVE', $4, 'test', $5::uuid)",
       &[_][]const u8{ id, slug, slug, idp_realm_id, "00000000-0000-0000-0000-000000000000" },
   );
   try conn.exec(
       "UPDATE public.tenant SET storage_mode = 'SCHEMA' WHERE id = $1::uuid",
       &[_][]const u8{id},
   );
   ```

4. Assert the row exists and `storage_mode='SCHEMA'` — establishing the pre-condition the regression is testing.
5. Invoke `python tools/verify_test_env.py --quick` as a subprocess (subprocess; uses `--quick` to skip C2/C3 since the test binary already proved the build is green), capture exit code.
6. Assert subprocess exit code is 0.
7. Assert the orphan row no longer exists in `public.tenant` (single SELECT after the subprocess returns).
8. Defer `DELETE FROM public.tenant WHERE id = $1::uuid` (idempotent; safe if §7 already removed it).

The test covers AC-3 from the diagnosis. It connects to real Postgres via `BPM_TEST_DB_URL` per DIRECTIVE T-1.

---

## 4. Error taxonomy

| Condition | Layer | Behaviour | Rationale |
|---|---|---|---|
| `clean_test_db.py` missing | 1 | SKIP — fall through to existing C4 drift check | Operator-error, not a fixture-hygiene issue. C4 will then fail with its own message. |
| `BPM_TEST_DB_URL` unset when sweep is invoked | 1 | SKIP | Same precondition as the existing C4 BPM_TEST_DB_URL check; preserves that path. |
| `clean_test_db.py` exit non-zero | 1 | FAIL with stderr detail | The sweep cannot establish a clean state, so C4 self-heal is not in effect. Reporting the failure is the only correct behaviour. |
| Orphan row remains after sweep | 1 | C4 still FAILs | Indicates the sweep's DELETE statement is incorrect or the orphan row doesn't match its predicates. Diagnostic, not modified. |
| Lint finds a `storage_mode='SCHEMA'` INSERT with no provisionTenantSchema call, file NOT in baseline | 2 | BLOCKER T070 | Caller-omission bug class; emit filename + line of the offending INSERT. |
| Lint exempt file (baseline) hits the same pattern | 2 | No finding | Baseline is the source of truth for exemptions. |
| Lint target path doesn't exist | 2 | Exit 2 | Bad invocation. |
| Regression test cannot connect to `BPM_TEST_DB_URL` | 3 | `error.EnvironmentVariableMissing` propagates | Per `tenant_config_realm_test.zig:50-58` pattern; clear message naming the missing variable. |
| Regression test insert fails (FK violation, etc.) | 3 | Propagate the error | A failed insert means the regression is not actually testing self-heal. |
| Regression test pre-step §7 assertion fails (row still present) | 3 | FAIL with diagnostic | Indicates Layer 1 is broken — `_run_clean_test_db_sweep()` did not invoke the sweep, or the sweep did not match this row's predicates. |

No new Zig error-set members are introduced — Layer 1 changes a Python gate, Layer 2 lives entirely in Python, Layer 3 reuses existing pool helpers. `src/db/provisioning.zig`'s `ProvisioningError` is unchanged.

---

## 5. Public interface

No runtime API, HTTP route, or database schema changes. The interface surface is a Python gate helper, a Python lint tool, and a Zig test binary.

### 5.1 `tools/verify_test_env.py`

- One new module-private helper: `_run_clean_test_db_sweep() -> Check` (signatures and behaviour in §3.1.1).
- One modified function: `check_schema_baseline()` (signatures unchanged, body extended per §3.1.2).
- One new module-private helper: `check_tenant_provisioning_lint() -> Check` (signatures and behaviour in §3.2.4).
- The gate's check list grows from 8 to 9 checks: C0, C1, C2, C3, C4, C5, C6, C7, **C8**. Existing CLI flags (`--quick`, `--bench-only`, `--skip-docker`, `--quiet`) are unchanged.
- Existing `[PASS]/[FAIL]` output format is preserved. The C8 entry follows the same template.

### 5.2 `tools/lint_test_tenant_provisioning.py`

CLI surface:

```
python tools/lint_test_tenant_provisioning.py [PATH...] [--no-baseline] [--json]
```

- `PATH...` — one or more `.zig` files or directories to scan (default: `tests/integration/`).
- `--no-baseline` — ignore the baseline file (used by the regression test to validate the lint itself).
- `--json` — emit a JSON report on stdout matching the structure produced by `lint_test_isolation.py`.

Exit codes: 0 / 1 / 2 as documented in §3.2.1.

### 5.3 `tests/integration/iss0605_orphan_self_heal_test.zig`

One `test "..."` block. Uses `Pool`, the existing `randomUuidStr`/`fillRandom` helpers from `tenant_config_realm_test.zig`, and `helpers.zig`'s `ensureSchemaReady`. Connects to real Postgres via `BPM_TEST_DB_URL`. Per `docs/agents/protocols/GIT_MERGE.md` and DIRECTIVE T-1, no mocks, no in-memory fakes, no skip-on-MUST.

### 5.4 Baseline file

`tools/lint_test_tenant_provisioning.baseline.json` is JSON (matches the format of `tools/lint_test_isolation.baseline.json`, an existing exception to the YAML rule per CLAUDE.md).

---

## 6. Data flow

The C4 self-heal wire-up (Layer 1):

```
zig build test-env-verify
  └── python tools/verify_test_env.py main(argv)
        └── check_schema_baseline()           ← C4
              ├── _run_clean_test_db_sweep()  ← NEW (helper, §3.1.1)
              │     └── subprocess: python tools/clean_test_db.py
              │           └── DELETE 332-336 removes orphan rows
              └── python tools/verify_schema_baseline.py --check-tenants
                    └── check_tenant_schemas_consistent()  → PASS
```

The C8 lint wiring (Layer 2):

```
check_tenant_provisioning_lint()             ← C8 (NEW)
  └── subprocess: python tools/lint_test_tenant_provisioning.py tests/integration
        └── for each test block in tests/integration/*.zig:
              ├── find INSERT INTO tenant ... 'SCHEMA' (or UPDATE ... storage_mode='SCHEMA')
              ├── if same block contains provisionTenantSchema() / bpm_provision_tenant_schema():
              │     └── PASS (skip)
              └── else:
                    ├── if file in baseline (tenant_config_realm_test.zig,
                    │       iss107_tenant_storage_mode_test.zig, fixture files):
                    │     └── PASS (skip)
                    └── else:
                          └── BLOCKER T070 (file:line of offending INSERT)
```

The regression test (Layer 3) is a single Zig `test "..."` block that connects to `BPM_TEST_DB_URL`, inserts one orphan row, invokes `verify_test_env.py --quick` as a subprocess, asserts exit 0, and asserts the row is gone — per §3.3.

---

## 7. Verification

The pass criterion is the **exit code** of `zig build test-env-verify` after the fix is applied, against the shared `db_test` database, with `BPM_TEST_DB_URL` set. Per CLAUDE.md, a gate satisfied by changing what it measures is not a fix.

### 7.1 Primary criterion — diagnosis AC-1 and AC-2

After the fix:

- `python tools/verify_schema_baseline.py --check-tenants` against `BPM_TEST_DB_URL=postgres://bpm:bpm@localhost:5434/bpm_test` reports `[OK] check_tenant_schemas_consistent: all SCHEMA-mode tenants have a Postgres schema` and exits 0 (AC-1). Note: this check is now *also* reachable by C4's pre-step; running it standalone confirms the post-sweep state.
- `zig build test-env-verify` exits 0 with all checks C0..C8 PASS (AC-2). C4 reports OK with the same detail string as AC-1; C8 reports "no BLOCKER findings".

### 7.2 Layer 1 mechanism confirmation — diagnosis AC-3 (regression test)

`tests/integration/iss0605_orphan_self_heal_test.zig` is wired into the build graph. After the fix:

- The test inserts one orphan `public.tenant` row with a per-test UUID.
- It invokes `python tools/verify_test_env.py --quick` as a subprocess.
- It asserts the subprocess exit code is 0 and the orphan row is gone from `public.tenant`.

If Layer 1 is broken (helper not invoked, sweep does not match this row's predicates), this test fails loudly.

### 7.3 Layer 2 mechanism confirmation — diagnosis AC-4 (lint self-check)

`tests/integration/lint_tenant_provisioning_test.zig` is a separate regression test that invokes `python tools/lint_test_tenant_provisioning.py tests/integration/_fixtures/lint_tenant_provisioning/ --no-baseline` and asserts:

- Exit code is 1.
- The report contains exactly one T070 BLOCKER naming `bad_orphan_insert_test.zig`.
- The report contains zero T070 entries naming `good_provisioned_insert_test.zig`.

If Layer 2 is broken (regex misses the bad pattern, baseline mistakenly exempts the bad file), this test fails loudly.

### 7.4 No-regression checks — diagnosis AC-6

- `zig build` exits 0 with no `error set` output (per the BACKEND-DEV checklist).
- `zig build test-integration` exits 0 against `BPM_TEST_DB_URL=5434`. Confirms the existing 172+ tests still pass.
- `python tools/lint_handoffs.py` exits 0 after fix (diagnosis AC-5). Handoff file conforms to schema; timestamps monotonic; log line appended.
- `python tools/lint_test_isolation.py tests/integration` still exits 0 — confirms Layer 2's regex did not accidentally flag legitimate patterns that lint_test_isolation accepts.
- `git diff` touches **no** file under `migrations/` and **not** `src/db/provisioning.zig`. If either appears in the diff, the fix has drifted into changing the wrong layer.

### 7.5 Retest deferred from the diagnosis

The diagnosis flagged the cross-binary concurrency race (ISS-0106) as the *upstream* cause of orphans and explicitly deferred it: "remains out of scope for this fix per candidate_fix.what_we_are_NOT_changing." This design does not address that race; it prevents recurrence via Layers 1 and 2. If a future run still sees orphan rows with `created_at` timestamps *during* a test run (rather than from a previous run), file a separate ISSUE — do not bundle it into a follow-up to ISS-0605.

### 7.6 Environment note

`python3` does not exist on this host; use `python`. `verify_test_env.py`'s existing call sites use `sys.executable` (line 522) and the implementer must continue to do so — it respects whatever interpreter was used to launch the gate.

---

## 8. Dependencies

| Dependency | Nature | Status |
|---|---|---|
| `tools/clean_test_db.py` lines 332–336 orphan-row DELETE | Layer 1 invokes it via subprocess | Exists; unmodified |
| `tools/verify_schema_baseline.py` `check_tenant_schemas_consistent()` lines 127–149 | C4 drift detector | Exists; unmodified |
| `src/db/provisioning.zig` `provisionTenantSchema()` | Layer 2's regex target — the call the lint expects to be present | Exists; unmodified |
| `src/db/provisioning.zig` `bpm_provision_tenant_schema()` SQL function | SQL-level equivalent referenced by the lint regex (alongside `provisionTenantSchema`) | Exists; unmodified |
| `tools/lint_test_isolation.py` baseline-format precedent | Layer 2 baseline file follows the same JSON shape | Exists |
| `tests/integration/tenant_config_realm_test.zig` `randomUuidStr`, `fillRandom` | Layer 3 reuse for per-test UUIDs | Exists |
| `tests/integration/helpers.zig` `ensureSchemaReady` | Layer 3 reuse for migration-runner guarantee | Exists |
| `tools/lint_design_artefact.py` §E030 schema-qualified names rule | This design uses unqualified names throughout; only references `public.tenant` once in the lint description, where the qualifier is part of the documented regex pattern (matching the production SQL string literal) | Exists; this design conforms |
| `docs/anti-patterns.md` "Never satisfy a gate by editing what it measures" entry | Drives the §1.2 rejection list | Exists |
| PostgreSQL advisory lock / `docker-compose exec db_test psql` | Used by `clean_test_db.py`; unchanged | Exists |

---

## 9. Open questions

None blocking. Two minor questions worth ORCH noting in the handoff result so the implementer can choose a sensible default:

1. **C8 ordering.** §3.2.4 places C8 after C7. Alternative: place C8 between C5 (test isolation lint) and C6 (stale locks), so lint-style checks are grouped. Either ordering is defensible; defaulting to after C7 because the existing ordering was selected for adjacency to DB-touching checks and C8 is a *static* lint (it does not touch the DB), so it can run last without delaying anyone.
2. **`_run_clean_test_db_sweep()` SKIP behaviour.** §3.1.2 falls through to the existing C4 drift check on SKIP. Alternative: turn SKIP into a soft warning printed alongside the C4 verdict but not change the C4 outcome. Defaulting to fall-through because the downstream C4 already produces a clearer message in the SKIP cases (no DB URL / no script), so a soft warning would be redundant.

Both defaults are implementer-acceptable; ORCH can confirm before BACKEND-DEV begins Step 3 or accept them silently.
