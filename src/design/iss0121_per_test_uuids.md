# ISS-0121 Per-Test UUID Isolation Design

**Classification:** Type E — novel, cross-cutting integration-test refactor. The work changes a shared test harness, fixture conventions, lint baseline handling, CI enforcement, and many test files; none of the Type A–D parameter-file patterns in `templates/lego-catalog.md` applies.

## Purpose

This design eliminates hardcoded UUID literals in integration tests by introducing a per-test UUID generator on `TestHarness` (`newUuid` and `newUuidString`). Currently, hundreds of integration tests embed reusable non-zero UUIDs directly in fixtures and SQL parameters, which causes `23505` unique-constraint failures and cross-test contamination when tests run sequentially or concurrently against the shared test database. The refactor replaces every fixture-identity literal with a locally generated binding produced inside the owning test block, while preserving the conventional all-zero sentinel where it means "platform default tenant" or "no value." The design also tightens the isolation lint baseline and adds a CI gate so newly introduced hardcoded fixture UUIDs fail the build.

## 1. Problem statement

Fresh diagnosis for ISS-0121 / GitHub #387 confirms **258 active MAJOR T010 findings** across more than 100 integration-test files, with another **195 findings suppressed** by the current isolation-lint baseline. Tests embed reusable non-zero UUID literals directly in fixtures and SQL parameters. Sequential reruns or concurrent binaries sharing the same PostgreSQL test database can therefore reuse primary keys, foreign keys, actor IDs, idempotency keys, and correlation identifiers, causing `23505` unique-constraint failures, cross-test contamination, or accidental reads of state created by another test.

The all-zero UUID remains a conventional sentinel and is exempt from T010. Every non-zero identifier that represents test-created state must be generated per test. This design formalizes the pattern already documented in `docs/guides/test_infrastructure_guide.md` §9 (the current location corresponding to the requested §11.1 per-test UUID guidance).

## 2. Solution overview

Extend `TestHarness` in `tests/integration/helpers.zig` with two in-memory fixture-ID helpers:

- `newUuid` obtains 16 fresh random bytes from the standard-library cryptographically secure random source, normalizes the UUID version and variant bits, and returns a UUID value.
- `newUuidString` obtains a fresh UUID through `newUuid`, allocates its canonical lower-case hyphenated representation, and transfers ownership of that byte slice to the caller.

Generation is process-local and requires no database round trip, global counter, shared mutable fixture state, or deterministic seed. Random generation provides practical uniqueness across calls, test blocks, binaries, processes, and repeated runs. The string helper exists only for APIs and SQL parameter arrays that currently consume textual UUIDs; typed consumers use `newUuid` directly.

## 3. API contract

Signatures only:

````zig
pub fn newUuid(self: *TestHarness) std.uuid.Uuid
pub fn newUuidString(self: *TestHarness, allocator: std.mem.Allocator) error{OutOfMemory}![]u8
````

### Semantics

- Each invocation returns a fresh RFC 4122-compatible UUID value suitable for a distinct test fixture.
- `self` associates generation with the active test harness and keeps the fixture API discoverable; generation performs no database I/O and does not mutate persisted state.
- `newUuid` is infallible at the public contract level because the standard cryptographic random source used by Zig does not expose a recoverable generation error through this API.
- `newUuidString` propagates only allocation failure.

### Allocation and ownership

- `newUuid` performs no heap allocation.
- `newUuidString` allocates exactly one caller-owned byte slice containing the canonical 36-byte hyphenated representation, without a required trailing sentinel.
- The caller must release the returned slice with the same allocator, normally through an immediate `defer allocator.free(id_string)`.
- Callers that already own a scoped allocator may pass `h.allocator`; explicit allocator input remains preferred because ownership is visible at each call site.

### Thread safety

The helpers introduce no shared mutable module state. Calls from different harnesses or threads may execute concurrently, subject to the thread-safety guarantees of Zig's standard cryptographic random source. The design does not add a harness-local counter or lock.

## Errors

The error set produced by the new public API surface on `TestHarness` is intentionally narrow:

- `newUuid(self: *TestHarness) std.uuid.Uuid` — infallible at the public contract level. The standard cryptographic random source used by Zig does not expose a recoverable generation error through this helper, so no error variants are declared on the return type. Generation is pure: it performs no I/O, no allocation, and cannot observe transient runtime failure.
- `newUuidString(self: *TestHarness, allocator: std.mem.Allocator) ![]u8` — declares the single error variant `error.OutOfMemory`. The only recoverable failure path is the canonical 36-byte hyphenated representation allocation; every other step is infallible. Callers must use `try` (or explicit handling) and pair the call with `defer allocator.free(binding)` so a leak does not turn into a future T030 finding.
- No new error variants are introduced on any other helper or function in this design. The harness method `newUuidString` does not propagate database errors, network errors, parse errors, or lock errors because it has no dependency on those subsystems at runtime.

## 4. Replacement rule

For every non-zero UUID literal used as test fixture identity:

1. Create the harness before generating identifiers.
2. Declare a local binding in the same test block with the narrowest practical scope.
3. Use a typed UUID when the consumer accepts `std.uuid.Uuid`; use the allocated string form only when a textual SQL/API parameter is required.
4. Register cleanup for every allocated UUID string immediately after successful allocation.
5. Pass the binding into parameterized SQL or helper arguments; do not interpolate it into SQL text.
6. Reuse one binding within a test only where the same logical identity is required. Generate separate UUIDs for distinct rows or actors.
7. Preserve the all-zero sentinel only where it means the platform default tenant or an explicit no-value sentinel; do not replace it with random data.
8. Assertions that previously compared a response to a literal must compare against the generated binding.
9. Derived values such as idempotency keys or correlation IDs must be built from the generated ID through existing safe formatting helpers, with caller-owned allocations deferred.

The target source shape is a local `const id = h.newUuid();` for typed use, or `const id = try h.newUuidString(allocator);` followed immediately by `defer allocator.free(id);` for textual use. Although legacy guidance shows `try h.newUuid()`, the signature in this design is intentionally infallible and therefore does not require `try`.

## 5. Migration strategy

Apply the refactor incrementally, one affected test file at a time:

1. Open the file and identify every non-zero UUID literal reported by T010. Distinguish fixture identity from the permitted all-zero sentinel and from prose-only documentation.
2. Locate the owning test block and its `TestHarness` plus allocator. If a literal is module-level, move the generated binding into each test block that needs it so fixtures cannot be shared across blocks.
3. Replace typed parsing of a literal with a local `newUuid` binding. Replace textual literal use with a local `newUuidString` binding and immediate caller cleanup.
4. Update every SQL parameter, helper call, expected response, derived key, and cleanup path that refers to that logical identifier.
5. Preserve relational identity: parent and child rows that intentionally share a key reference the same generated binding; unrelated rows receive distinct calls.
6. Run `python tools/lint_test_isolation.py --no-baseline --json <affected-file>` and confirm the file's T010 count falls by exactly the number of non-zero literals replaced, without introducing T020, T030, T040, T050, or T060 findings.
7. Run the file's focused integration-test target where one exists, then proceed to the next file.
8. After the full sweep, run `python tools/lint_test_isolation.py --no-baseline --json tests/integration` and review every residual finding before updating the baseline.

No bulk textual replacement is acceptable without test-block review because repeated literals can represent either the same relational key or several identities that must become distinct.

## 6. Files-to-change

`docs/issues/ISS-0121.json#files_to_change` contains 22 paths. The requested implementation sweep consists of the following **20 Zig files**: one shared harness plus 19 integration-test files. Rough counts below are derived from current UUID-pattern matches and exclude all-zero sentinel occurrences where identifiable; the isolation linter is authoritative during implementation.

| File | Approximate non-zero literals to replace | Design note |
|---|---:|---|
| `tests/integration/helpers.zig` | 0 | Add the two shared API methods; existing UUIDs are all-zero sentinel or explanatory text. |
| `tests/integration/adp02_tenant_scope_test.zig` | 17 | Generate IDs inside each tenant-scope test; preserve default-tenant zero sentinel. |
| `tests/integration/iss101_timers_failed_status_test.zig` | 10 | Replace instance, timer, and actor fixture IDs. |
| `tests/integration/iss102_claim_test.zig` | 3 | Replace worker and creator IDs; preserve zero tenant sentinel. |
| `tests/integration/iss202_merge_atomicity_test.zig` | 13 | Replace repeated creator literal in every independent test block rather than sharing one generated ID. |
| `tests/integration/iss203_idempotency_keys_test.zig` | 1 | Replace creator ID; preserve zero tenant sentinel. |
| `tests/integration/iss205_webhook_outbox_test.zig` | 11 | Replace owner, subscription, delivery, and instance IDs per test. |
| `tests/integration/iss207_error_retry_test.zig` | 9 | Replace definition, instance, and DLQ IDs; keep embedded all-zero tenant sentinels. |
| `tests/integration/iss208_task_guard_test.zig` | 7 | Replace definition, instance, task, and token IDs; preserve zero tenant sentinel. |
| `tests/integration/iss601_state_snapshots_test.zig` | 2 | Move module-level creator identity into test-local generation and replace overflow event ID. |
| `tests/integration/obs05_dlq_test.zig` | 18 | Replace fixture and actor IDs; update response assertions to compare with generated values. |
| `tests/integration/obs06_alerts_test.zig` | 9 | Replace input IDs and update payload/correlation assertions derived from them. |
| `tests/integration/sch02_timer_polling_test.zig` | 2 | Move creator and actor IDs from module scope into owning tests. |
| `tests/integration/sch303_timer_dlq_test.zig` | 9 | Replace instance, definition, and timer IDs; derive idempotency keys from generated timer IDs. |
| `tests/integration/svc01_service_catalog_scope_test.zig` | 12 | Replace tenant/owner/caller IDs; preserve zero production-tenant sentinel where semantically required. |
| `tests/integration/svc03_definition_activation_scope_test.zig` | 7 | Replace owner, caller, and arbitrary-tenant IDs; preserve tenant-context zero sentinel. |
| `tests/integration/svc04_admin_api_test.zig` | 11 | Replace owner and tenant fixture IDs; do not randomize explicit zero-sentinel admin/default context. |
| `tests/integration/tm01_tenant_list_test.zig` | 2 | Replace actor/user IDs. |
| `tests/integration/onboarding_realm_guard_test.zig` | 0 T010 | No non-zero UUID replacement currently indicated; retain in the issue sweep for its separately diagnosed T020 mutable-state finding, which is outside this design's UUID API. |
| `tests/integration/svc02_plugin_dispatch_scope_test.zig` | 0 T010 | No non-zero UUID replacement currently indicated; retain in the issue sweep for its separately diagnosed T050 database-environment finding, which is outside this design's UUID API. |

The remaining two paths in `files_to_change` are prevention infrastructure and are covered separately:

- `tools/lint_test_isolation.py` — CI policy and T010 gate behavior.
- `tools/lint_test_isolation.baseline.json` — regenerated residual baseline.

The issue reports 258 active T010 findings across the full integration tree, so these approximate counts are planning aids rather than a claim that the 19 listed test files exhaust every active literal. Before closing ISS-0121, implementation must reconcile the full no-baseline output with the issue scope and add any omitted T010-bearing files to the migration sweep rather than hiding them in the baseline.

## 7. Lint baseline update rules

The baseline is a record of explicitly accepted legacy debt, not a mechanism for making a red lint run green.

1. Run the linter with `--no-baseline --json` after all targeted replacements.
2. Do not copy the old baseline forward wholesale: line-number-based keys become stale after edits.
3. Remove every T010 entry whose source literal was replaced or whose line no longer exists.
4. Do not add any new T010 suppression for a non-zero fixture UUID. Residual T010 findings require code migration or a documented false-positive fix in the linter.
5. Preserve only independently reviewed findings that are outside ISS-0121, such as a legitimate non-T010 residual already tracked by a separate issue.
6. For each preserved residual, require an issue reference and rationale in the baseline metadata or companion issue record.
7. Regenerate deterministically from the reviewed clean no-baseline report, then run the normal baseline-aware command and require exit code zero.
8. Compare old and new counts. The active T010 count must be zero and the suppressed T010 count must not increase.
9. Review the diff to ensure the baseline shrinks because source violations were removed, not because messages, severities, or paths were changed to evade matching.

## 8. CI hook (prevention)

Wire the baseline-aware isolation lint into an existing mandatory CI/build gate that runs before integration-test binaries. The hook invokes `python tools/lint_test_isolation.py tests/integration` from the repository root and propagates the process exit code. Since the linter already exits non-zero for active MAJOR or BLOCKER findings, any newly introduced T010 finding fails the gate.

The prevention contract is:

- CI cannot use `--no-baseline` for its ordinary gate because reviewed non-T010 legacy debt may remain temporarily.
- CI must use the repository baseline and fail if a finding does not match it exactly.
- The baseline file and linter are reviewed code; changing either in the same pull request as a new suppression requires explicit justification.
- A separate diagnostic/no-baseline run may publish full counts, but it must not replace the fail-on-new-finding command.
- The lint gate runs before expensive integration binaries so isolation defects fail fast.
- Once the migration is complete, promote T010 severity from MAJOR to BLOCKER as defense in depth; behavior remains fail-closed either way because both severities already produce exit code 1.

## 9. Acceptance criteria

1. `TestHarness` exposes the two signatures in §3 with no database access and no module-level mutable state.
2. `newUuid` returns a standards-compatible UUID and successive calls in a test process yield distinct values.
3. `newUuidString` returns the canonical 36-character hyphenated representation and has explicit caller-free ownership.
4. Every migrated non-zero fixture literal is replaced by a test-local generated binding; the all-zero sentinel remains only where semantically intentional.
5. Generated bindings are passed through prepared-statement parameters or existing helper arguments, never interpolated into SQL text.
6. Every allocated UUID string has unconditional caller cleanup.
7. The 20 Zig files in §6 are reviewed, and every actual T010 occurrence in them is either replaced or identified as the all-zero exemption.
8. A full `--no-baseline` lint run reports zero active T010 findings in the agreed ISS-0121 closure scope; omitted files discovered by that run are added to the sweep.
9. The regenerated baseline contains no newly suppressed T010 fixture violation, stale fixed entry, or unexplained residual.
10. The baseline-aware isolation lint exits zero and its CI hook rejects a deliberately introduced non-zero UUID literal in a temporary validation change.
11. Focused tests for each migrated file and the full integration suite pass against real PostgreSQL without new `23505` collisions attributable to fixture identity reuse.
12. Documentation references the per-test UUID pattern in `docs/guides/test_infrastructure_guide.md` §9, corresponding to the task's requested §11.1 guidance.

## 10. Out of scope

- Database schema changes, migrations, SQL DDL, or production data backfills.
- Changes to production UUID generation or API identifier semantics.
- Replacing the all-zero default-tenant/no-value sentinel where it is semantically required.
- Deterministic seeded UUIDs for snapshot/replay tests; a future design may introduce a separately named deterministic source if a concrete need arises.
- Fixing unrelated T020 and T050 findings in `onboarding_realm_guard_test.zig` and `svc02_plugin_dispatch_scope_test.zig`; they remain separately actionable lint defects even though those files are in ISS-0121's list.
- Rewriting test cleanup architecture, transaction handling, database provisioning, or advisory-lock behavior.
- Converting every textual UUID consumer to typed `std.uuid.Uuid`; this refactor changes fixture identity, not unrelated APIs.
- Suppressing newly discovered violations to satisfy a target count.

## 11. Risks & mitigations

| Risk | Consequence | Mitigation |
|---|---|---|
| Incorrect UUID bit normalization | Generated values may not meet downstream UUID validation expectations. | Require RFC-compatible version/variant bits and add focused contract tests for canonical parse/format round trips. |
| Random collision | Two fixtures could theoretically receive the same ID. | Use the standard cryptographically secure 128-bit source; practical collision probability is negligible. |
| Allocation leak from string helper | Large suites accumulate memory or trigger T030. | Require immediate `defer allocator.free(binding)` after every successful string allocation; keep typed use allocation-free. |
| Blind replacement breaks relational identity | Parent/child rows receive different generated IDs, or distinct rows accidentally share one. | Migrate per logical identity, trace every binding through SQL parameters and assertions, and run focused tests after each file. |
| Assertions retain old literals | Tests fail despite correct fixture insertion or cease checking the created row. | Replace expected payload, URL, correlation, and response comparisons with values derived from the same local binding. |
| Module-level generated fixture state | Tests remain order-dependent even though literals disappear. | Generate inside each test block; never introduce global counters, cached UUIDs, or module-level mutable variables. |
| Concurrent random-source use is misunderstood | Implementers may add unnecessary synchronization or unsafe shared state. | Rely on the standard source's concurrency contract and keep helper state-free. |
| Baseline regeneration masks debt | Active defects disappear from CI without being fixed. | Generate from reviewed no-baseline output, forbid new T010 suppressions, and inspect count/diff changes. |
| Approximate file counts drift | Some active T010 findings remain in files omitted from the initial 20-file plan. | Treat the full no-baseline report as authoritative and expand the sweep before closure; never force the baseline to fit the initial list. |
| Existing tests depend on recognizable literals | Debugging or expected serialized text becomes less readable. | Keep semantic variable names and include generated values in failure diagnostics where existing test helpers support them. |
| Cyclic dependency | The new API surface could accidentally introduce a module-to-module import cycle that prevents compilation or breaks layering. | `newUuid` and `newUuidString` live entirely within `tests/integration/helpers.zig`, depend only on `std.uuid`, the standard cryptographic random source, and a caller-supplied `std.mem.Allocator`. They have no runtime dependency on the database, the network, the process environment, the harness pool, or any other production module, so the diff cannot create a cycle. The import graph remains a strict DAG from `tests/integration/*` into `tests/integration/helpers.zig`, and from `helpers.zig` into `std` only. |
| CI hook duplicates or bypasses build behavior | Local and CI outcomes diverge. | Invoke the same repository-root linter command in both documented pre-check and mandatory CI/build gate, propagating its exit code unchanged. |

## 12. Follow-up: Batch migration of 17 remaining files (ISS-0121 GH #387 PR #400)

### Purpose

This follow-up extends the §6 migration sweep to the 17 integration-test files that still embed non-zero UUID literals after PR #399 closed the first batch of three files. The helper API introduced in §3 (`TestHarness.newUuid` and `TestHarness.newUuidString`) is unchanged — the follow-up is a pure client of the same API. The work is incremental: each file in scope is migrated individually against the existing design contract, and the CI gate from §8 continues to enforce the T010 baseline.

### Errors

No new error variants are introduced. The follow-up reuses the API surface declared in §3:

- `newUuid(self: *TestHarness) std.uuid.Uuid` — infallible at the public contract level.
- `newUuidString(self: *TestHarness, allocator: std.mem.Allocator) error{OutOfMemory}![]u8` — propagates only `error.OutOfMemory`.

Callers must continue to pair `newUuidString` with `defer allocator.free(binding)`. The follow-up must not add error variants, change the return type, or alter the ownership rules.

### Replacement rule

The rule from §3 applies unchanged:

1. Create the harness before generating identifiers.
2. Declare a local binding in the same test block.
3. Use `newUuid` for typed `std.uuid.Uuid` consumers.
4. Use `newUuidString` for textual SQL/API parameters and pair with `defer allocator.free(binding)`.
5. Preserve the all-zero sentinel (`00000000-0000-0000-0000-000000000000`) only where it represents the platform default tenant or an explicit no-value sentinel. The literal `ALL_ZEROS_UUID` is **not** replaced.
6. Replace each non-zero UUID literal with `h.newUuidString(allocator)` (or `h.newUuid()` for `[16]u8` callers) — never suppress, never alias.
7. Generated bindings flow through prepared-statement parameters or helper arguments; never into SQL text.

### Batches

The follow-up splits the 17 remaining files into three commits, mirroring the inner report at `docs/issue-reports/WF03-gh387-followup-20260802-step-01-issue-fixer-INNER-REPORT.yaml`. Each batch is a single commit, a single focused integration-test target run, and a single lint delta.

#### Batch A — Tenant and webhook fixtures

| File | UUID count | Notes |
|---|---:|---|
| `tests/integration/adp02_tenant_scope_test.zig` | 18 | tenant, actor, definition, instance, token, task, audit IDs |
| `tests/integration/iss202_merge_atomicity_test.zig` | 13 | typed `[16]u8` created_by values; one per test block |
| `tests/integration/iss205_webhook_outbox_test.zig` | 11 | owner, subscription, delivery, instance IDs |
| `tests/integration/iss207_distribution_pause_test.zig` | 0 | no current T010 literal; confirm lint delta is zero |
| `tests/integration/iss208_idempotent_replay_test.zig` | 0 | no current T010 literal; confirm lint delta is zero |

Expected lint delta: up to 42 active T010 findings removed from the batch A subset. Commit subject: `test(WF03-gh387-followup-20260802): isolate tenant and webhook fixtures`.

#### Batch B — Observability and scheduler fixtures

| File | UUID count | Notes |
|---|---:|---|
| `tests/integration/iss601_compensation_journal_test.zig` | 0 | no current T010 literal; confirm lint delta is zero |
| `tests/integration/obs05_dlq_test.zig` | 18 | instance, user, definition, DLQ identifiers |
| `tests/integration/obs06_incident_report_test.zig` | 0 | no current T010 literal; confirm lint delta is zero |
| `tests/integration/sch02_audit_pipeline_test.zig` | 0 | no current T010 literal; confirm lint delta is zero |
| `tests/integration/sch303_tenant_suspension_test.zig` | 0 | no current T010 literal; confirm lint delta is zero |

Expected lint delta: up to 18 active T010 findings removed from the batch B subset. Commit subject: `test(WF03-gh387-followup-20260802): isolate observability and scheduler fixtures`.

#### Batch C — Admin and tenant-management fixtures

| File | UUID count | Notes |
|---|---:|---|
| `tests/integration/svc01_admin_groups_api_test.zig` | 0 | no current T010 literal; confirm lint delta is zero |
| `tests/integration/svc02_admin_users_api_test.zig` | 0 | no current T010 literal; confirm lint delta is zero |
| `tests/integration/svc03_admin_realms_api_test.zig` | 0 | no current T010 literal; confirm lint delta is zero |
| `tests/integration/svc04_admin_api_test.zig` | 10 | tenant and owner IDs; retain zero system/default tenant sentinel |
| `tests/integration/tm01_sla_breach_test.zig` | 0 | no current T010 literal; confirm lint delta is zero |
| `tests/integration/onboarding_realm_guard_test.zig` | 0 | T020 mutable-state finding is out of scope for this UUID migration |
| `tests/integration/svc02_plugin_dispatch_scope_test.zig` | 0 | T050 BPM_TEST_DB_URL finding is out of scope for this UUID migration |

Expected lint delta: up to 10 active T010 findings removed from the batch C subset. Commit subject: `test(WF03-gh387-followup-20260802): isolate admin and tenant-management fixtures`.

The combined expected lint delta across all three batches is up to 70 active T010 findings removed from these 17 files (relative to the 243-finding baseline captured at `run_at: "2026-08-02T16:43:29Z"`). The follow-up does not move findings between batches; each batch is independently verifiable.

### Per-file patterns

Each of the 17 files falls into one of four patterns. The classification below is the contract that BACKEND-DEV applies during the migration sweep.

#### instance-id — per-test `INSERT INTO instances` UUIDs

Files where the dominant pattern is generating the primary key for a freshly inserted process instance, then propagating that ID into related fixtures (tasks, tokens, audit rows, idempotency keys).

- `tests/integration/adp02_tenant_scope_test.zig`
- `tests/integration/iss202_merge_atomicity_test.zig`
- `tests/integration/iss205_webhook_outbox_test.zig`
- `tests/integration/obs05_dlq_test.zig`
- `tests/integration/svc04_admin_api_test.zig` (tenant-context instances only)

For each `instance-id` file, declare `const instance_id = try h.newUuidString(allocator); defer allocator.free(instance_id);` at the top of the test block, then thread it through every SQL parameter and assertion.

#### actor-id — per-test `creator_id` / `actor_id` UUIDs

Files where the dominant pattern is generating a human or system actor identity used in audit and ownership columns.

- `tests/integration/adp02_tenant_scope_test.zig` (overlaps with `instance-id`; actor IDs are distinct from instance IDs)
- `tests/integration/iss202_merge_atomicity_test.zig` (typed `[16]u8` `created_by`)
- `tests/integration/obs05_dlq_test.zig` (user IDs)

For typed `[16]u8` consumers, prefer `h.newUuid()` directly and pass the value into the API or helper that expects the raw byte form. Do not stringify and reparse; the helper exists precisely to avoid that allocation.

#### audit-id — per-test `audit_entries.resource_id` UUIDs

Files where the dominant pattern is generating a resource identifier that appears in audit log fixtures.

- `tests/integration/adp02_tenant_scope_test.zig` (audit rows for tenant operations)
- `tests/integration/iss205_webhook_outbox_test.zig` (delivery audit entries)
- `tests/integration/obs05_dlq_test.zig` (DLQ audit entries)

These audit IDs are referenced from both INSERT statements and SELECT assertions; both sides of the comparison must move together.

#### module-const — file-scope `const` UUIDs that need parameterisation

Files where a non-zero UUID literal is bound at module scope and reused across multiple test blocks. Such constants must be moved into the owning test block and replaced with a generated binding per the §3 rule.

- `tests/integration/adp02_tenant_scope_test.zig` (verify each tenant constant is local to its test block)
- `tests/integration/iss202_merge_atomicity_test.zig` (the repeated `created_by` literal must become per-block, not shared)

Files with zero current T010 findings (see batch tables above) are retained in the migration sweep only for completeness; BACKEND-DEV must confirm the lint delta is exactly zero before declaring the file migrated.

### Lint acceptance

The follow-up uses the baseline recorded at `run_at: "2026-08-02T16:43:29Z"`: 243 active MAJOR findings across the 17 affected files, captured by `tools/lint_test_isolation.py`. The acceptance gate is:

- MAJOR count across these 17 files must drop to **<10** (i.e. fewer than ten residual active MAJOR findings total).
- BLOCKER count must remain **0**.
- The combined removal across the three batches must be ≥ 70 active T010 findings to claim the migration is complete; any shortfall is filed as a follow-up WF-03 issue, not absorbed into a baseline suppression.
- The regenerated baseline must not introduce new T010 suppressions for any of the 17 files.

### Risks & mitigations

| Risk | Consequence | Mitigation |
|---|---|---|
| Test parallelism collision | Two parallel tests receive the same generated ID under load. | The 3-file baseline in PR #399 already proved per-test generation suffices; this follow-up reuses the same `TestHarness` allocation path with no shared mutable state. |
| Module-level constants | Tests remain order-dependent even though literals disappear. | Any file-scope `const` UUID is moved into the owning test block during migration; BACKEND-DEV must reject patches that introduce a new module-level UUID binding. |
| Helper string vs raw bytes | `[16]u8` consumers receive a stringified allocation that costs both an allocation and a parse. | Use `h.newUuid()` directly for typed `[16]u8` consumers; reserve `h.newUuidString` for textual SQL/API parameters. Verify each call site during the file-by-file sweep. |
| Lint over-suppression | Residual T010 findings are hidden in a regenerated baseline instead of being migrated. | The follow-up is migration-only; no new suppression entries are added. The regenerated baseline is reviewed against the no-baseline output, matching the §7 rules. |

### Follow-up acceptance criteria

1. Each of the 17 files listed above is reviewed against the §3 API contract.
2. Files with `uuid_count > 0` have every non-zero literal replaced with a generated binding; the all-zero sentinel remains only where semantically required.
3. Files with `uuid_count == 0` are confirmed clean by a `--no-baseline` lint run; no new UUID literals are introduced.
4. The combined MAJOR count across the 17 files is below 10 after the three commits land.
5. The three commits follow the subject lines listed in the batch tables above and land on the `feature/WF03-gh387-followup-20260802` branch.
6. The regenerated baseline contains no new T010 suppressions and matches the §7 review rules.
7. The CI hook from §8 exits zero on the merged branch.
