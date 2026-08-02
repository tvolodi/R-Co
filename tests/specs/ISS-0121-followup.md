---
spec_id: ISS-0121-followup
title: ISS-0121 follow-up batch migration of 17 remaining integration-test files
priority: MUST
test_layer: integration
target_file: tests/integration/iss0121_uuid_helpers_test.zig (helper regression suite)
build_target: iss0121_integration_tests + integration sweep
test_runner_step: zig build test-integration-iss0121 + zig build test-integration
related_design: src/design/iss0121_per_test_uuids.md (specifically §12 follow-up)
related_helpers: tests/integration/helpers.zig
related_issue: GitHub #387 (PR #400 follow-up to PR #399)
status: TEST-DESIGNED
---

# Test Spec: ISS-0121 Follow-up — Batch Migration of 17 Integration-Test Files

**Requirement:** ISS-0121 / GitHub #387 / PR #400 follow-up. The Step 3 implementation in PR #399 introduced the `TestHarness.newUuid()` and `TestHarness.newUuidString(allocator)` helpers in `tests/integration/helpers.zig` and migrated a first batch of three integration-test files. This follow-up extends the migration to the 17 remaining files that still embed non-zero UUID literals at the time PR #399 merged. The helper API is **unchanged** — the follow-up is a pure client of the existing helpers; no new error variants, no signature changes, no ownership-rule changes.

**Priority:** MUST. ISS-0121 is the BLOCKER for the integration-test isolation lint gate. Residual non-zero UUID literals in integration tests produce `23505` unique-constraint failures and cross-test contamination when tests run sequentially or concurrently against the shared PostgreSQL test database.

**Test layer:** integration (real PostgreSQL via `BPM_TEST_DB_URL`). The follow-up does NOT add new test source files — coverage is provided by:

1. The helper regression suite `tests/integration/iss0121_uuid_helpers_test.zig` (TC-ISS-0121-01..07 from `tests/specs/ISS-0121.md`), which pins the contract of `TestHarness.newUuid` / `newUuidString`.
2. The 17 migrated integration-test files themselves, which now generate every fixture identity per-test via the helper API; the existing per-file test cases (TC-ADP-02-*, TC-ISS-202-*, TC-ISS-205-*, TC-OBS-05-*, TC-SVC-04-*, etc.) continue to exercise the underlying business logic.

---

## Purpose

The follow-up applies the §3 replacement rule from `src/design/iss0121_per_test_uuids.md` to the 17 files that still embedded non-zero UUID literals after PR #399 landed. For every non-zero literal in scope:

- A test-local binding is declared with the narrowest practical scope.
- `h.newUuid()` is used for typed `[16]u8` consumers (e.g. `created_by` in `iss202_merge_atomicity_test.zig`).
- `h.newUuidString(allocator)` is used for textual SQL/API parameter arrays; the returned `[]u8` is paired with an immediate `defer allocator.free(...)` at the same scope.
- The all-zero UUID sentinel `00000000-0000-0000-0000-000000000000` is preserved wherever it represents the platform default tenant or an explicit no-value semantic.
- No new module-level UUID constants are introduced; no new helper functions; no baseline suppressions added for non-zero UUID findings.

## Batches

The follow-up ships as three commits on `feature/WF03-gh387-followup-20260802`, mirroring the inner report at `docs/issue-reports/WF03-gh387-followup-20260802-step-01-issue-fixer-INNER-REPORT.yaml`.

### Batch A — Tenant and webhook fixtures (commit `ecd4a6e`)

| File | UUID literals removed | Pattern |
|---|---:|---|
| `tests/integration/adp02_tenant_scope_test.zig` | 17 | tenant, actor, definition, instance, token, task, audit IDs — all generated per test |
| `tests/integration/iss202_merge_atomicity_test.zig` | 13 | typed `[16]u8` `created_by` values — one `h.newUuid()` per test block |
| `tests/integration/iss205_webhook_outbox_test.zig` | 11 | owner, subscription, delivery, instance IDs |
| `tests/integration/iss207_error_retry_test.zig` | 0 | zero current T010 literal — lint delta confirmed zero |
| `tests/integration/iss208_task_guard_test.zig` | 0 | zero current T010 literal — lint delta confirmed zero |

Expected lint delta: up to 42 active T010 findings removed from the batch A subset.

### Batch B — Observability and scheduler fixtures (commit `d4d965b`)

| File | UUID literals removed | Pattern |
|---|---:|---|
| `tests/integration/iss601_state_snapshots_test.zig` | 0 | zero current T010 literal — lint delta confirmed zero |
| `tests/integration/obs05_dlq_test.zig` | 18 | instance, user, definition, DLQ identifiers |
| `tests/integration/obs06_alerts_test.zig` | 0 | zero current T010 literal — lint delta confirmed zero |
| `tests/integration/sch02_timer_polling_test.zig` | 0 | zero current T010 literal — lint delta confirmed zero |
| `tests/integration/sch303_timer_dlq_test.zig` | 0 | zero current T010 literal — lint delta confirmed zero |

Expected lint delta: up to 18 active T010 findings removed from the batch B subset.

### Batch C — Admin and tenant-management fixtures (commit `67ed36b`)

| File | UUID literals removed | Pattern |
|---|---:|---|
| `tests/integration/svc01_service_catalog_scope_test.zig` | 0 | zero current T010 literal — lint delta confirmed zero |
| `tests/integration/svc02_plugin_dispatch_scope_test.zig` | 0 | T050 `BPM_TEST_DB_URL` finding out of scope for UUID migration |
| `tests/integration/svc03_definition_activation_scope_test.zig` | 0 | zero current T010 literal — lint delta confirmed zero |
| `tests/integration/svc04_admin_api_test.zig` | 10 | tenant and owner IDs — zero system/default tenant sentinel preserved |
| `tests/integration/tm01_tenant_list_test.zig` | 0 | zero current T010 literal — lint delta confirmed zero |
| `tests/integration/onboarding_realm_guard_test.zig` | 0 | T020 mutable-state finding out of scope for UUID migration |

Expected lint delta: up to 10 active T010 findings removed from the batch C subset.

### Combined expected lint delta

The combined expected lint delta across the three batches is **up to 70 active T010 findings removed** from the 17 files. The follow-up does not move findings between batches; each batch is independently verifiable against a single `python tools/lint_test_isolation.py tests/integration --no-baseline --json` run that filters on the file set.

## Replacement rule (unchanged from §3)

1. Create the harness before generating identifiers (`var h = try TestHarness.init(alloc); defer h.deinit();`).
2. Declare a local binding in the same test block with the narrowest practical scope.
3. Use `h.newUuid()` for typed `std.uuid.Uuid` / `[16]u8` consumers.
4. Use `h.newUuidString(alloc)` for textual SQL/API parameters and pair with `defer alloc.free(...)` immediately after successful allocation.
5. Preserve the all-zero sentinel `00000000-0000-0000-0000-000000000000` only where it represents the platform default tenant or an explicit no-value semantic.
6. Pass the binding into parameterized SQL or helper arguments; do NOT interpolate it into SQL text.
7. Reuse one binding within a test only where the same logical identity is required. Generate separate UUIDs for distinct rows or actors.
8. Assertions that previously compared a response to a literal must compare against the generated binding.

## Per-file patterns

The 17 files fall into four implementation patterns. The classification below is the contract that BACKEND-DEV applies during the migration sweep.

### instance-id — per-test `INSERT INTO instances` UUIDs

Files where the dominant pattern is generating the primary key for a freshly inserted process instance, then propagating that ID into related fixtures (tasks, tokens, audit rows, idempotency keys).

- `tests/integration/adp02_tenant_scope_test.zig`
- `tests/integration/iss202_merge_atomicity_test.zig`
- `tests/integration/iss205_webhook_outbox_test.zig`
- `tests/integration/obs05_dlq_test.zig`
- `tests/integration/svc04_admin_api_test.zig` (tenant-context instances only)

For each `instance-id` file, declare `const instance_id = try h.newUuidString(alloc); defer alloc.free(instance_id);` at the top of the test block, then thread it through every SQL parameter and assertion.

### actor-id — per-test `creator_id` / `actor_id` UUIDs

Files where the dominant pattern is generating a human or system actor identity used in audit and ownership columns.

- `tests/integration/adp02_tenant_scope_test.zig` (overlaps with `instance-id`)
- `tests/integration/iss202_merge_atomicity_test.zig` (typed `[16]u8` `created_by` — uses `h.newUuid()` directly, no allocation)
- `tests/integration/obs05_dlq_test.zig` (user IDs)
- `tests/integration/svc04_admin_api_test.zig` (actor tenant contexts)

For typed `[16]u8` consumers, prefer `h.newUuid()` directly and pass the value into the API or helper that expects the raw byte form. Do not stringify and reparse; the helper exists precisely to avoid that allocation.

### audit-id — per-test `audit_entries.resource_id` UUIDs

Files where the dominant pattern is generating a resource identifier that appears in audit log fixtures.

- `tests/integration/adp02_tenant_scope_test.zig` (audit rows for tenant operations)
- `tests/integration/iss205_webhook_outbox_test.zig` (delivery audit entries)
- `tests/integration/obs05_dlq_test.zig` (DLQ audit entries)

These audit IDs are referenced from both INSERT statements and SELECT assertions; both sides of the comparison must move together so the SELECTed `resource_id` matches the originally generated string.

### module-const — file-scope `const` UUIDs that need parameterisation

Files where a non-zero UUID literal was bound at module scope and reused across multiple test blocks. Such constants must be moved into the owning test block and replaced with a generated binding per the §3 rule.

- `tests/integration/adp02_tenant_scope_test.zig` (verify each tenant constant is local to its test block)
- `tests/integration/iss202_merge_atomicity_test.zig` (the repeated `created_by` literal must become per-block, not shared)

Files with zero current T010 findings (see batch tables above) are retained in the migration sweep only for completeness; BACKEND-DEV confirms the lint delta is exactly zero before declaring the file migrated.

## Coverage statement

This spec does NOT add new test source files. Coverage is satisfied by:

1. **Helper contract regression suite** — `tests/integration/iss0121_uuid_helpers_test.zig` (TC-ISS-0121-01..07) covers the helper API surface. Any future regression in `TestHarness.newUuid` / `newUuidString` that produces all-zero, non-distinct, or non-canonical output fails TC-01..06 (unit-style, no DB). TC-07 covers the round-trip through `audit_entries.resource_id TEXT` against real PostgreSQL.
2. **Migrated integration tests** — the 17 files in scope contain their own pre-existing TC-ADP-02-*, TC-ISS-202-*, TC-ISS-205-*, TC-OBS-05-*, TC-SVC-04-*, TC-ISS-207-*, TC-ISS-208-*, TC-ISS-601-*, TC-OBS-06-*, TC-SCH-02-*, TC-SCH-303-*, TC-SVC-01-*, TC-SVC-02-*, TC-SVC-03-*, TC-TM-01-*, TC-ONBOARDING-* test cases. The migration replaces fixture identity generation; the business-logic assertions are unchanged and continue to run against real PostgreSQL.

The coverage gate is satisfied by the existing TC inventory in `tests/specs/ISS-0121.md` (TC-ISS-0121-01..07) plus the per-file TC inventory of the 17 migrated files. There is no DEFERRED work, no "future phase" note, no partial coverage.

## Isolation and security contract

- Every migrated UUID literal is now produced per test by `TestHarness.newUuid` or `TestHarness.newUuidString(allocator)`. Each call returns a cryptographically random 128-bit v4 UUID, so distinct test invocations cannot collide on primary keys, foreign keys, actor IDs, idempotency keys, or correlation identifiers.
- Every allocated UUID string is paired with `defer allocator.free(...)` immediately after successful allocation. The defer is unconditional — it survives both PASS and FAIL paths through `defer h.deinit()`.
- All fixture SQL continues to use PostgreSQL placeholders (`$1::text`, `$2::uuid`, etc.) — no string interpolation of fixture UUIDs into SQL text.
- The all-zero UUID sentinel `00000000-0000-0000-0000-000000000000` is preserved wherever it represents the platform default tenant (`bpm.api_tenant_context.set("00000000-...")`) or an explicit no-value semantic in `pool_config`, `INSERT ... ON CONFLICT DO NOTHING` no-op probes, or actor-context defaults.
- No mocks, no stubs, no in-memory database, no `error.SkipZigTest` on MUST coverage.
- Lint gate: `python tools/lint_test_isolation.py tests/integration --no-baseline` exits non-zero for any new active MAJOR or BLOCKER finding; the baseline-aware variant `python tools/lint_test_isolation.py tests/integration` exits non-zero for any finding that is not in `tools/lint_test_isolation.baseline.json`.

## Verification artifacts

The follow-up produces three commits on `feature/WF03-gh387-followup-20260802`:

1. `ecd4a6e` — Batch A (5 files migrated)
2. `d4d965b` — Batch B (5 files migrated, only `obs05_dlq_test.zig` had UUID literals)
3. `67ed36b` — Batch C (7 files migrated, only `svc04_admin_api_test.zig` had UUID literals)

Per-file verification during the sweep:

- `git show <batch-commit> -- <file>` → confirm only UUID-literal lines changed; no test logic or assertion shapes modified.
- `zig build` → exit 0 (compilation succeeds).
- `zig build test` → exit 0 (unit-style tests TC-ISS-0121-01..06 pass without DB).
- `python tools/lint_test_isolation.py tests/integration --no-baseline --json` → `MAJOR` count across the 17 files drops from the pre-migration baseline.

## Acceptance criteria

1. The three commits land on `feature/WF03-gh387-followup-20260802` with the subjects listed in the batch tables.
2. `zig build` exits 0 on the merged branch.
3. `zig build test` exits 0 on the merged branch.
4. `python tools/lint_test_isolation.py tests/integration --no-baseline` reports MAJOR count across the 17 files reduced by at least 60 from the pre-migration baseline.
5. `python tools/lint_test_isolation.py tests/integration` (baseline-aware) reports BLOCKER=0.
6. No file in the 17-file sweep introduces a new module-level `const <name> = "<uuid-literal>";` declaration.
7. No file in the 17-file sweep introduces a new helper function, error variant, or ownership rule that differs from the §3 contract.
8. `tests/integration/iss0121_uuid_helpers_test.zig` continues to pass (TC-ISS-0121-01..07) and pins the helper API contract for any future refactor.
9. The regenerated baseline (`tools/lint_test_isolation.baseline.json`) contains no new T010 suppressions for any of the 17 files; existing suppressed entries are reviewed against the §7 rules and any that are stale (e.g. fixed in the migration sweep) are removed.
10. The CI hook from §8 (`python tools/lint_test_isolation.py tests/integration`) exits zero on the merged branch.

## Follow-up acceptance criteria

This spec follows the same completion contract as the parent spec `tests/specs/ISS-0121.md`:

1. `TestHarness.newUuid` and `TestHarness.newUuidString(allocator)` continue to expose the §3 signatures; the follow-up does NOT change the API.
2. The 17 files listed in the batch tables are migrated; zero-literal files are explicitly confirmed clean.
3. The combined MAJOR count across the 17 files drops measurably (≥60 findings removed) from the pre-migration baseline.
4. BLOCKER count across the 17 files remains 0.
5. No new error variants are added; no signature changes; no ownership-rule changes.
6. The three commits land on the `feature/WF03-gh387-followup-20260802` branch.
7. The regenerated baseline contains no new T010 suppressions for any of the 17 files.

## Pipeline assessment

ISS-0121 follow-up is a backend test-helper refactor with no user-visible sequential action. No Playwright pipeline step applies; `docs/guides/test_developer_guide.md §11.10` is unchanged.

## Errors

No new error variants are introduced by this follow-up. The migrated tests continue to use the helper API declared in `src/design/iss0121_per_test_uuids.md §3` and re-tested by `tests/integration/iss0121_uuid_helpers_test.zig` (TC-ISS-0121-01..07):

- `TestHarness.newUuid(self: *TestHarness) std.uuid.Uuid` — infallible at the public contract level. The standard cryptographic random source used by Zig does not expose a recoverable generation error through this helper, so no error variants are declared on the return type. Generation is pure: it performs no I/O, no allocation, and cannot observe transient runtime failure.
- `TestHarness.newUuidString(self: *TestHarness, allocator: std.mem.Allocator) error{OutOfMemory}![]u8` — declares the single error variant `error.OutOfMemory`. The only recoverable failure path is the canonical 36-byte hyphenated representation allocation; every other step is infallible. Callers must use `try` (or explicit handling) and pair the call with `defer allocator.free(binding)` so a leak does not turn into a future T030 finding.

Migration-rule errors (regression in the migration sweep) surface as:

- **E010 (test compile error)** — a migrated call site omits `try` before `h.newUuidString(...)` or `try` before `h.newUuid()` (the latter is documented as infallible and MUST NOT use `try` per §3). Detected at `zig build` / `zig build test`.
- **E020 (baseline drift)** — the regenerated `tools/lint_test_isolation.baseline.json` introduces a new T010 suppression for one of the 17 files. Detected by `git diff` review against the §7 rules.
- **E030 (relational identity)** — a parent/child fixture that previously shared an identity literal now receives distinct generated bindings, breaking referential FK constraints. Detected at integration-test runtime as a PostgreSQL `23503` foreign-key violation.

The follow-up must not add error variants, change the return type, or alter the ownership rules of the helper API. Any future change to the API surface belongs in a separate design artefact and separate spec, not in this follow-up.

## Out of scope

- Database schema changes, migrations, SQL DDL, or production data backfills.
- Changes to production UUID generation or API identifier semantics.
- Replacing the all-zero default-tenant/no-value sentinel where it is semantically required.
- Fixing T020 (mutable-state) and T050 (`BPM_TEST_DB_URL`) findings in `onboarding_realm_guard_test.zig` and `svc02_plugin_dispatch_scope_test.zig`; those remain separately actionable lint defects.
- Adding new helper functions, error variants, or signatures on `TestHarness`.
- Suppressing newly discovered violations to satisfy a target count.
