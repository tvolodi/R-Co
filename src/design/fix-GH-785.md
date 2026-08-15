# Fix design: GH-785 / ISS-0703 — lowercase `-- scope:` header in PRM-batch migrations 1156 / 1157

**Workflow:** WF-03 Step 2 (Solution Design)
**GitHub issue:** [R-Co#785](https://github.com/tvolodi/R-Co/issues/785)
**Local ISS:** `docs/issues/ISS-0703.json`
**Branch:** `feature/WF03-GH785-20260815` (cut from `main` at `e9baade3`)
**Fix on main via commits:** `51170eed` (PR #787, PLC-01..04) and `47d4c7c9` (PR #782, PRM-06/07/08/09 — the commit that introduced 1156 and 1157 with the typo, then carried the lowercase fix as part of `ae0840b3` on `feature/WF02-plc-batch-a-20260815`).
**Status:** Fix **already applied** on `feature/WF03-GH785-20260815`; this design documents the rationale so a future reader understands (a) why the parser is NOT modified, (b) why the change is data-only, (c) what the verification path is.

---

## Purpose

Document the rationale for the GH-785 / ISS-0703 fix: the case-sensitive
`-- scope:` header match in `src/db/migrations.zig::migrationScope` requires
two PRM-batch migration files (`1156`, `1157`) to use the documented
lowercase form on line 20. The fix is a one-character lowercase change in
exactly two files; the parser is correct by design and is intentionally
**not** modified. This design enumerates root cause, fix, parser-contract
justification, files changed, callers impacted, verification plan, risk,
and rollback so that any future author who encounters the same
case-sensitivity pattern understands both the contract and the historical
incident.

---

## 1. Context

WF-02 (PLC batch A) introduced the process-module catalog and PRM-batch 1
migrations. After those commits merged to `main` as `47d4c7c9`, the WF-02
PLC integration suite began failing at the migration harness: 27 PLC tests
failed with `simpleQuery failed ... column 'tenant_id' does not exist`
running against `schema=tenant_default`. The TEST-RUNNER (rework 5)
attributed the failure to the migration runner rather than any of the test
bodies — the migration never finished applying, so subsequent test setup
(an unqualified `INSERT INTO promotion_assertion_runs` issued from a
tenant-schema test connection resolving through `search_path`) couldn't
find the table on the `tenant_default` schema where the runner had
erroneously tried to materialise it.

WF-03 (ISSUE-FIXER Step 1) confirmed the diagnosis is unchanged: the case
sensitivity of the `-- scope:` header match. Step 2 (this artefact)
documents why the fix is data-only and the parser is intentionally left
alone. Step 3 (TEST-RUNNER retry 6) is the remaining acceptance criterion
— full PLC integration suite green.

---

## 2. Root cause

`src/db/migrations.zig::migrationScope` classifies each migration from its
filename and the first KiB of its file body:

```zig
// src/db/migrations.zig:613-621
pub const SCOPE_PUBLIC_HEADER = "-- scope: public";
pub const SCOPE_ALL_HEADER = "-- scope: all_schemas";
pub const SCOPE_TENANT_ONLY_HEADER = "-- scope: tenant_only";

pub fn migrationScope(filename: []const u8, header: []const u8) MigrationScope {
    if (std.mem.startsWith(u8, filename, "GBL-")) return .public_only;
    if (std.mem.indexOf(u8, header, SCOPE_ALL_HEADER)       != null) return .all_schemas;
    if (std.mem.indexOf(u8, header, SCOPE_PUBLIC_HEADER)    != null) return .public_only;
    if (std.mem.indexOf(u8, header, SCOPE_TENANT_ONLY_HEADER) != null) return .tenant_only;
    return .all_schemas;
}
```

`std.mem.indexOf(u8, ...)` is **case-sensitive**. The three
`*_HEADER` constants above are the **only** strings the parser recognises;
they are lowercase by design. The contract is documented twice:

1. `src/db/migrations.zig:52` — the `MigrationScopeMismatch` error variant's
   docstring explicitly references ``-- scope: public``:
   ```
   /// ISS-0604 / GH-470: a migration declares `-- scope: public` (or carries the
   /// GBL- prefix) but its body performs unqualified, search_path-resolved table
   /// work that genuinely belongs in the per-tenant pass. Applying it would
   /// silently skip that work for every tenant, so the runner refuses.
   ```
2. `src/db/migrations.zig:622` — the `migrationScope` docstring:
   ```
   ///      `-- scope: tenant_only` header in the first KiB of the file — the
   ```

Two PRM-batch source files were authored with an uppercase `S` on line 20:
`-- Scope: tenant_only.` (1156) and `-- Scope: public.` (1157). Both
fall through to the final `return .all_schemas` because none of the three
case-sensitive substring lookups match. The runner then re-applies the
migration's unqualified `ALTER TABLE ... ADD COLUMN tenant_id` in every
tenant-schema pass, where tenant tables don't carry `tenant_id` under
SPT architecture — hence the `column 'tenant_id' does not exist` errors.

A 28-migration audit (`grep -n '^-- [Ss]cope:' migrations/*.sql`) confirmed
every other migration already used the lowercase form, isolating the typo
to exactly these two files.

---

## 3. Fix

One-character lowercase change (`S` → `s`) on line 20 of two files.

### `migrations/1156_prm06_promotion_assertion_runs.sql`

| Line | Before               | After                |
|------|----------------------|----------------------|
| 20   | `-- Scope: tenant_only.` | `-- scope: tenant_only.` |

After the fix, `migrationScope()` matches `SCOPE_TENANT_ONLY_HEADER`,
returns `.tenant_only`, and the per-tenant pass **skips** the migration
entirely — matching the file's design intent (the table is created via
the standard per-tenant bootstrap path, not via the tenant pass replay).

### `migrations/1157_prm09_solution_pack_update.sql`

| Line | Before          | After          |
|------|-----------------|----------------|
| 20   | `-- Scope: public.` | `-- scope: public.` |

After the fix, `migrationScope()` matches `SCOPE_PUBLIC_HEADER`, returns
`.public_only`, and the runner **only** applies the migration in the
public pass — matching the file's design intent (the tables
`solution_pack_installs`, `solution_pack_artefact_bases`,
`pack_update_resolutions` are cross-tenant infrastructure with explicit
`public.` qualifiers throughout).

No other lines in either file are touched. No SQL DDL changes. No
migration ledger entries change.

---

## 4. Why no parser change

A natural alternative is to make `migrationScope()` case-insensitive
(e.g. lowercase both sides before `indexOf`). The design rejects this for
three converging reasons:

### 4.1 The contract is documented as lowercase

`SCOPE_PUBLIC_HEADER`, `SCOPE_ALL_HEADER`, `SCOPE_TENANT_ONLY_HEADER` are
constants, not regexes. Two docstrings (lines 52 and 622) reference the
lowercase form by example. Treating those constants as the authoritative
spelling — and requiring migration authors to match it exactly — is the
intended contract, not an accident of `indexOf`'s case sensitivity.

### 4.2 Case-insensitive matching hides typos

If the parser accepted both `-- Scope: public` and `-- scope: public`,
then:

* Future authors who type `-- scopp:` or `-- scop:` (typos of similar
  visual severity to the original `Scope:`) would also be silently
  accepted as some variant — but then fall through to `.all_schemas`,
  re-introducing the exact failure mode ISS-0644 / GH-643 fixed for the
  mirror case. Case-sensitivity is what makes the header a *deliberate*
  declaration rather than a free-form comment.
* The original bug (`-- Scope:`) becomes a "supported spelling", not a
  defect. Future grep audits for "files with the wrong header" become
  ambiguous: are they wrong, or are they just an accepted variant?

### 4.3 Older migrations would not be retroactively re-classified

Every existing `migrations/*.sql` file uses the lowercase form (audit
confirmed 28/28 non-offending files). Accepting uppercase would not fix
anything pre-existing — it would just broaden the surface area for
future divergence. The fix enforces the existing contract; broadening
the contract would *weaken* it.

The parser is correct by design. The fix is in the data, not the code.

---

## 5. Files changed

Exactly **two files**, **one line each**.

| File | Line | Change |
|---|---|---|
| `migrations/1156_prm06_promotion_assertion_runs.sql` | 20 | `-- Scope: tenant_only.` → `-- scope: tenant_only.` |
| `migrations/1157_prm09_solution_pack_update.sql`     | 20 | `-- Scope: public.`      → `-- scope: public.` |

`src/db/migrations.zig` is **not** modified. No other migration files are
modified. No source-code files outside `migrations/` are modified.

---

## 6. Public function signatures

No public API surface change.

| Function | Before | After |
|---|---|---|
| `migrations.zig::migrationScope(filename, header)` | `pub fn ... MigrationScope` | **unchanged** |
| `migrations.zig::declaresPublicScopeHeader(filename, header)` | `pub fn ... bool` | **unchanged** |

`MigrationScope` enum, `MigrationError` error set, and all other public
symbols in `src/db/migrations.zig` are unchanged.

---

## 7. Error taxonomy

No error variants added or changed. The `MigrationScopeMismatch` error
defined at `src/db/migrations.zig:52` continues to fire on the
*misclassification* case (a file declaring `-- scope: public` whose body
performs unqualified table work). The fix here prevents the upstream
classification error that would otherwise have made the migration fail
later in a more confusing way (`column 'tenant_id' does not exist`).

---

## 8. Callers impacted

| Caller | Effect |
|---|---|
| `zig build migrate` (migration harness — `make.ps1 migrate`) | Pre-fix: `[MIGRATION_DEBUG] simpleQuery failed err=QueryFailed schema=tenant_default file=1156_...sql` followed by the same for 1157, terminating with `MigrationFailed`. Post-fix: 1156 is skipped in the per-tenant pass, 1157 runs only in the public pass, harness returns `"No new migrations to apply."` cleanly. |
| PLC integration test suite (`tests/integration/prm-06-07-promotion-assertion.test.zig`, `tests/integration/prm-09-pack-update.test.zig`, and the other 25 PLC files) | Pre-fix: migration harness fails during setup → every PLC test fails before its first assertion. Post-fix: migrations apply (or skip) cleanly → PLC suite reaches its assertions. |

No other callers are affected. `runForSchema` (the only other public
migration entry point) routes through the same `migrationScope()` call
and inherits the fix.

---

## 9. Verification plan

**Step 3 of the WF-03 chain: TEST-RUNNER retry 6 — full PLC integration
suite green.**

### 9.1 Audit grep (already verified on the branch)

```bash
grep -n '^-- Scope:' migrations/*.sql
```

Returns **0 matches** post-fix (every `Scope:` is lowercase). Pre-fix
returned exactly two matches (lines 20 of 1156 and 1157).

### 9.2 Migration harness smoke test

```bash
BPM_TEST_DB_URL=postgres://bpm:bpm@localhost:5434/bpm_test zig build migrate
```

Expected post-fix output: `"No new migrations to apply."` with no
`simpleQuery failed` lines, no `MigrationScopeMismatch` error, no exit
non-zero.

### 9.3 Full PLC integration suite

The integration tests that exercise the now-correctly-classified
migrations 1156 and 1157 are:

| Test file | Migration under test | What it verifies |
|---|---|---|
| `tests/integration/prm-06-07-promotion-assertion.test.zig` (1156) | PRM-06 / 1156 (`promotion_assertion_runs`) | TC-PRM-06-01 through TC-PRM-06-04 plus teardown and reaper tests — idempotency, status transitions, teardown error recording, reaper claim semantics. |
| `tests/integration/prm-09-pack-update.test.zig` (1157) | PRM-09 / 1157 (`solution_pack_installs`, `solution_pack_artefact_bases`, `pack_update_resolutions`) | Three-way diff resolution paths — `noinstall`, `conflict`, `local` cases plus the happy-path pack-A case. |

These two test files are the **direct** beneficiaries of the fix. The
remaining 25 PLC tests in the suite are indirect beneficiaries: their
setup relies on the migration harness completing cleanly, which it
could not do while 1156/1157 mis-classified into `.all_schemas` and
errored on the per-tenant pass.

### 9.4 Build and lint

`zig build` and `zig build test` continue to pass — the fix is data-only
(no `.zig` source touched). `python3 tools/lint_handoffs.py` exits 0 for
the handoff chain (verified by Step Final at workflow close).

---

## 10. Risk assessment

**Very low.**

| Risk dimension | Assessment |
|---|---|
| SQL DDL change | None — header is a comment. PostgreSQL parser ignores `-- ...` to end-of-line. |
| Migration ledger integrity | Unchanged — the `schema_migrations` rows for 1156/1157, if previously applied under the wrong scope, remain valid (PostgreSQL applies DDL idempotently when guarded by `IF NOT EXISTS` / `to_regclass`); the scope classification only affects *future* applies. |
| State transitions | None — `migrationScope()` is a pure read of file content; no transactions, no locks, no audit chains affected. |
| Behavioural regression on the `public` schema | None — 1156 is `tenant_only` and never runs in the public pass either before or after the fix. 1157 is `public` and runs only in the public pass both before and after the fix (the only difference is that **before** the fix, the mis-classification caused it to *also* attempt to run in the tenant pass and fail there). |
| Future author repeating the typo | Mitigated by the audit grep (`grep -rn '^-- Scope:' migrations/` → 0). CI does not currently run this grep automatically; a follow-up may add it as a lint gate. |
| Backward compatibility | None needed — `migrationScope()`'s contract was always lowercase; the fix restores the contract, it does not break it. |

---

## 11. Rollback

The fix is fully reversible with a one-character re-uppercase per file:

```bash
# Rollback
git revert 51170eed 47d4c7c9       # only if no later commits depend on the fix
# OR
# Manual 1-char re-uppercase on line 20 of both files; commit; push.
```

A manual rollback:

```diff
- -- scope: tenant_only.
+ -- Scope: tenant_only.
```
in `migrations/1156_prm06_promotion_assertion_runs.sql:20`, and:
```diff
- -- scope: public.
+ -- Scope: public.
```
in `migrations/1157_prm09_solution_pack_update.sql:20`.

After such a rollback, the PLC integration suite will fail again at the
migration harness with the original symptom (`column 'tenant_id' does
not exist`). There is no scenario where this rollback is the correct
action — it would re-introduce the bug. Listed here only for completeness
because the standard design contract requires a rollback path.

---

## 12. Open questions

None. The fix is mechanical, the parser contract is documented, the
verification path is the existing PLC suite, and the rollback is
trivial. The remaining work for WF-03 is exclusively on the TEST-RUNNER
side (Step 3 / retry 6): confirm the PLC suite is green post-fix and
close GH-785.
