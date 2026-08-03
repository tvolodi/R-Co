# ISS-0121 Residual-29 — Incremental Per-Test UUID Migration Design (WF-03 / GH #402)

**Classification:** Type E — novel, cross-cutting integration-test fixture refactor. The work touches the shared `TestHarness` API (re-uses it; no new helper), fixture conventions across 29 integration-test files, and the lint-baseline handling policy. None of the Type A–D parameter-file patterns in `templates/lego-catalog.md` applies because there is no single CRUD endpoint, list page, migration, or React Flow node to model — the change is the systematic replacement of hardcoded UUID literals with calls to an existing helper, applied per-file across a known file inventory.

This artefact is the **WF-03 Step 2 fix design** for the residual T010 hardcoded-UUID migration tracked by GitHub issue #402. It is **prose-only**: it prescribes *what* to change and *how* to verify it; it does **not** contain implementation code (no Zig function bodies, no SQL DDL, no linter regex edits, no baseline JSON diffs).

---

## 1. Context

- **Issue:** `ISS-0121` — Hardcoded UUID violations (T010) across 100+ integration test files. Recorded as MAJOR (test-quality / per-test-fixture-isolation). Knowledge-base entry: `docs/issues/ISS-0121.json` (status RESOLVED-PARTIAL). Continuation reference: `https://github.com/tvolodi/R-Co/issues/402` (sync-ref `rco-sync-ref: ISS-0121-residual-29`); original: `https://github.com/tvolodi/R-Co/issues/387`.
- **Prior fixes already merged to `main`:**
  - `c40817a` PR #399 — `fix(ISS-0121): per-test UUID generator on TestHarness (GH #387)` — introduced `TestHarness.newUuid` (helpers.zig:467) and `TestHarness.newUuidString` (helpers.zig:479).
  - `ef42a06` PR #403 — `fix(ISS-0121): incremental per-test UUID migration (GH #387 part 2)` — migrated 17 test files; lint MAJOR dropped 243 → 174.
  - `6cc92ec` PR #404 — unrelated ISS-0122 root cause; provides `main` baseline.
- **Branch in use:** `feature/WF03-gh402-20260803` at base `6cc92ec` (set up by BACKEND-DEV step 00, handoff `f880dbd3-…`; pushed to `origin`).
- **Root-cause statement:** Integration tests INSERT hardcoded 16-byte/36-byte UUID literals directly into SQL fixture statements. When two test files (or two test blocks within a file) reuse the same literal in the shared `bpm_test` database, the second INSERT collides via unique-constraint `23505` or overwrites prior data, contaminating the test environment. Per INV-TI-3 (test_infrastructure_guide.md §3 / §9) all test fixtures must use per-test UUIDs generated fresh at the start of each test block.

### Live lint state (this run, captured at handoff creation)

```
$ python tools/lint_test_isolation.py tests/integration
files_checked = 122
BLOCKER = 0
MAJOR  = 174
MINOR  = 0
Suppressed 195 issue(s) from baseline: tools/lint_test_isolation.baseline.json
```

Active MAJOR breakdown (computed from `--json` output of the same command, baseline applied):

| Code | Count | Files affected |
|---|---:|---|
| T010 | 168 | 26 |
| T020 | 3 | 3 (`entity_subsystem_test.zig`, `ext03_plugin_integration_test.zig`, `onboarding_realm_guard_test.zig`) |
| T050 | 3 | 3 (`entity_subsystem_test.zig`, `exp601_tier_quota_test.zig`, `svc02_plugin_dispatch_scope_test.zig`) |

**Total of 29 unique files carrying active findings** (the residual-29 inventory inherited from `docs/issue-reports/WF03-gh402-20260803-step-005-issue-fixer-INNER-REPORT.yaml`). The pre-existing `iss0121_per_test_uuids.md` §6 lists a 20-file scope that was true for PR #399; PR #403 migrated 17 more; this run continues the same incremental migration over the remaining 29.

> **Source-of-truth invariant.** This design **trusts the live lint output** (`--json` mode of `tools/lint_test_isolation.py`) as the authoritative inventory at every milestone. The on-disk affected file set is exactly the 29 unique files listed in §5 below; the legacy `docs/issues/ISS-0121.json#files_to_change` list (22 paths) is informational only — BACKEND-DEV uses the live list, not the legacy list, at each batch.

---

## 2. Module purpose

The "module" this artefact describes is the **invariant**: every non-zero UUID literal that represents test-created identity must be generated per test via `TestHarness.newUuid` or `TestHarness.newUuidString`. The invariant must hold across all 29 affected files; no new helper is introduced; the existing API surface is re-used unchanged.

The design enforces the invariant in three layers:

1. **Per-file migration sweep** — replace each non-zero UUID literal with the corresponding `newUuid`/`newUuidString` call in the smallest possible scope (test block, not module).
2. **Batched PRs** — keep each fix PR reviewable (≤ 4 PRs, mirroring WF-02 batch cap and the §5 batch split), with one commit per PR and a focused lint delta per commit.
3. **Verification recipe** — every batch lands only when lint MAJOR strictly decreases, `zig build test` exits 0, the full integration suite exits 0, and no new T010/T020/T050 findings are introduced.

The all-zero sentinel (`00000000-0000-0000-0000-000000000000`) is **preserved** in every position where the API contract requires it (default tenant, NULL marker, system placeholder); the linter already excludes this case in `tools/lint_test_isolation.py:84` (`if val == ALL_ZEROS_UUID: continue`).

---

## 3. Public interface — UNCHANGED

The existing API on `TestHarness` is the migration surface. **No new helper, no wrapper, no new module.** Per `docs/agents/CODE-DESIGNER` mode rules, the design re-uses the signatures below verbatim (already implemented at `tests/integration/helpers.zig:467` and `:479`):

````zig
pub fn newUuid(self: *TestHarness) bpm.uuid.Uuid
pub fn newUuidString(self: *TestHarness, allocator: std.mem.Allocator) ![]u8
````

### Semantics (verbatim from helpers.zig)

- `newUuid` obtains 16 fresh random bytes from the standard-library cryptographically secure random source via `bpm.uuid.generateUuidV4BytesInto(&bytes)`. Returns `bpm.uuid.Uuid`. **Infallible; allocation-free.** Self parameter is unused (`_ = self;`).
- `newUuidString` delegates to `bpm.uuid.newUuidV4(allocator)` and `@constCast`s the canonical 36-byte hyphenated lowercase string to `[]u8` for caller mutability. **Returns `![]u8`; the only error variant is `error.OutOfMemory`.** Caller owns the slice and must release it.

### Allocation and ownership (binding for migration)

- `newUuid` — no heap allocation; binding is a 16-byte stack value.
- `newUuidString` — exactly one caller-owned heap allocation per call. The caller MUST `defer allocator.free(binding)` immediately after a successful call; the test harness transaction rollback (`TestHarness.deinit()` → `conn.rollback()`) does **not** free Zig-side heap allocations.

### Lifetime (binding for migration)

- The binding lives for the lifetime of the test block. Allocate it at the top of the test block (after `var h = helpers.TestHarness.init(allocator)` and `defer h.deinit();`), then reference it in INSERT/SELECT/assertion arguments.
- Two distinct test blocks MUST NOT share a single binding — that is exactly the module-const anti-pattern that the per-test UUID pattern replaces.
- A single test block MAY have multiple bindings — one per logical identity (e.g. `def_id`, `inst_id`, `dlq_id`). Each MUST be a separate `h.newUuidString(allocator)` call with its own `defer`.

### Thread safety

The helpers introduce no shared mutable module state. Calls from different harnesses or threads may execute concurrently, subject to the thread-safety guarantees of Zig's standard cryptographic random source. **No mutex, no harness-local counter, no deterministic seed.**

### Error taxonomy (binding for migration)

`newUuidString` is the only call site that can return an error variant to the caller (`error.OutOfMemory`). BACKEND-DEV MUST use `try` and pair the call with `defer allocator.free(binding)`. The migration MUST NOT add a helper that swallows the error or returns a `null`-on-failure contract — the existing `try` propagation is the contract.

---

## 4. Replacement rule

For every non-zero UUID literal that represents test-created identity in the 29 residual files:

1. **Create the harness first.** The `var h = helpers.TestHarness.init(allocator) catch …; defer h.deinit();` block MUST already exist in the owning test before any per-test UUID binding is generated. Files that use a pool (`makePool(...)` only, no `TestHarness`) MUST either route through `TestHarness` for the UUID binding (and pass the binding string slice into the pool-based assertions/INSERTs), or call `bpm.uuid.newUuidV4(allocator)` directly — but for consistency BACKEND-DEV prefers keeping the binding on `h` even when the rest of the test uses a pool.

2. **Declare the binding in the test block's narrowest scope.** NEVER at module scope. NEVER as a `const` shared between tests. The binding lifetime is the test block.

3. **Pick the helper that matches the consumer.**
   - **Typed `[16]u8` / `bpm.uuid.Uuid` consumer** (raw-byte INSERT parameters, `created_by` columns that take a typed UUID, fixtures parsed via `parseUuid(s: []const u8) ![16]u8` and then threaded into the API as `[16]u8`) — use `h.newUuid()` directly. Do **not** stringify and reparse; that costs an allocation and a parse.
   - **Textual SQL parameter consumer** (`$N::uuid` casts, `&.{ "uuid-literal" }` parameter arrays, JSON body fields, response payload assertions that compare a string) — use `h.newUuidString(allocator)` with an immediate `defer allocator.free(id)`.

4. **Pair every `newUuidString` call with `defer allocator.free(binding)`.** The defer MUST appear on the next line so the lifetime is visible at the call site. A binding without a defer is a T030-class leak waiting to be filed.

5. **Preserve relational identity.** Parent and child rows that intentionally share a key reference the **same** generated binding. Unrelated rows receive **distinct** calls. Repeated literals that previously meant "the same logical identity in two INSERTs" become a single binding passed into both INSERTs. Repeated literals that previously meant "two independent identities that happened to share a literal" become two distinct bindings.

6. **Update assertions to compare against the binding.** Any test code that compared a SQL response, JSON payload, or audit log entry to the prior literal MUST compare against the same generated binding. This is the most failure-prone step; the §10 risks list names it explicitly.

7. **Preserve the all-zero sentinel** (`00000000-0000-0000-0000-000000000000`) where the API contract requires it: default tenant seed (`ensureDefaultOidcSeeds` in helpers.zig), NULL marker for `created_by_id`/`actor_id` columns where the schema explicitly permits the sentinel, and any test that asserts the harness persists the canonical default-tenant UUID. The linter excludes `ALL_ZEROS_UUID` automatically; BACKEND-DEV MUST NOT replace it with random data.

8. **Module-level constants are forbidden.** If a file currently has `const SOME_ID = "abcd…";` at module scope, BACKEND-DEV MUST move the binding inside each owning test block and remove the module-level `const`. A module-level `const` UUID is a T020-adjacent anti-pattern (shared state across blocks) and triggers `bypass` of the per-test isolation goal.

9. **Derived values must flow from the binding.** Idempotency keys, correlation IDs, payload-derived fields, audit `resource_id`, task guard tokens — anything derived from a UUID literal must be built from the generated binding via existing safe formatting helpers (e.g. `std.fmt.allocPrint(allocator, "idem-{s}", .{binding})` with appropriate `defer`). No interpolation into SQL text.

---

## 5. Batching — four PRs of roughly equal size

The 29 residual files split into four PRs to keep each reviewable and to mirror the WF-02 batch cap (`CLAUDE.md §"Batch cap"`). Each batch is a single BACKEND-DEV commit with the subject line shown; each batch ends with a focused integration-test target run (file-level `zig build test-<module>` where it exists) plus a project-wide lint diff.

> **Batching rationale:** (a) the WF-02 batch cap is 4 requirements / 4 PRs; (b) PR #403 split into 3 commits of 6/6/5 files and worked; (c) keeping the 24-file "carry-over from prior runs" in batches B and D (which contain the largest residual files like `exp601_tier_quota_test.zig` and `ext02_webhook_dispatch_test.zig`) lets the harder SQL/audit-touching files land later, after the routine instance-id and actor-id patterns are proven correct.

### Batch A — ADP / IDN identity binding sweep (8 files, 27 literals)

| File | Active T010 | Notes |
|---|---:|---|
| `tests/integration/adp06_pipeline_run_correlation_test.zig` | 8 | instance, pipeline-run, correlation IDs; typed `[16]u8` likely needed |
| `tests/integration/adp07_agent_role_reserved_usernames_test.zig` | 4 | user IDs, role IDs |
| `tests/integration/adp09_tamper_evident_audit_chain_test.zig` | 6 | audit `resource_id`, instance IDs (NB: this file also carries a T050 — out of scope; only the T010 literals are touched) |
| `tests/integration/idn02_group_management_test.zig` | 2 | group/user IDs |
| `tests/integration/idn03_role_access_test.zig` | 1 | user_id |
| `tests/integration/idn04_api_token_management_test.zig` | 1 | api_token id |
| `tests/integration/ext01_service_task_test.zig` | 1 | service-task fixture id |
| `tests/integration/ext03_plugin_integration_test.zig` | 1 (T010) + 8 (T020) | plugin invocation id; the T020 module-level mutable var (`integration_test_payloads` etc., per linter) is **out of scope** for this design — BACKEND-DEV MUST NOT touch T020 in this batch, only the T010 literal |

**Expected delta after Batch A lands:** BLOCKER=0, MAJOR ≤ 147 (was 174), files affected ≤ 22.

### Batch B — exp601/ext02/db/obs/env heavy fixture migration (8 files, 79 literals)

| File | Active T010 | Notes |
|---|---:|---|
| `tests/integration/exp601_tier_quota_test.zig` | 24 | tier/quota fixture IDs; largest file in the residual; typed + textual mix. NB: this file also carries a T050 — out of scope for this design. |
| `tests/integration/ext02_webhook_dispatch_test.zig` | 20 | webhook subscription/delivery IDs; mix of helper-generated IDs and pre-existing helpers (`seedAdminUser`, `seedWebhookSubscription`) |
| `tests/integration/db_integration_test.zig` | 5 | db0301aa-…, db0301bb-…, db0302cc-…, db0302dd-…, acac0000-… literals |
| `tests/integration/obs06_alerts_test.zig` | 9 | alert rule / incident IDs (`aaaaaaaa-…`, `11111111-…`, `22222222-…`, `a1111111-…`, etc.) |
| `tests/integration/entity_subsystem_test.zig` | 5 (T010) + 1 (T020) + 1 (T050) | entity record IDs; **only the 5 T010 literals are in scope** |
| `tests/integration/env03_test.zig` | 6 | environment fixture IDs |
| `tests/integration/sch02_timer_polling_test.zig` | 2 | timer-poll fixture IDs |
| `tests/integration/instance_error_test.zig` | 3 | error-instance fixture IDs |

**Expected delta after Batch B lands:** BLOCKER=0, MAJOR ≤ 68 (was 147, removing 79). This is the largest aggregate drop.

### Batch C — ADP+ISS+SCH+SVC: process, timer, and tenant fixture migration (8 files, 53 literals)

| File | Active T010 | Notes |
|---|---:|---|
| `tests/integration/exp103_instance_waits_test.zig` | 17 | instance_waits IDs (`e10301xx-*`/`e10302xx-*` patterns); mix of typed parseUuid consumers and textual SQL params |
| `tests/integration/iss207_error_retry_test.zig` | 9 | def/instance/dlq IDs (`d0207001-…`, `d0207002-…`, `d0207003-…`) |
| `tests/integration/iss208_task_guard_test.zig` | 8 | def/instance/task/token IDs (`d0208001-…`, `d0208002-…`) |
| `tests/integration/iss601_state_snapshots_test.zig` | 2 | creator + overflow event IDs |
| `tests/integration/sch303_timer_dlq_test.zig` | 9 | instance/definition/timer IDs (`30310000-…`, `30320000-…`, `30100000-…` patterns; mid-block `…000000` is all-zero except the prefix) |
| `tests/integration/svc01_service_catalog_scope_test.zig` | 12 | tenant/owner/caller IDs (`aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeee01/02`, `c0111111-…`, `c0222222-…`, `d1111111-…`, `eeeeeeee-…`, `b3dd1111-…`) |
| `tests/integration/svc03_definition_activation_scope_test.zig` | 7 | owner/caller/tenant IDs (`10000000-…`, `40000000-…`, `eeeeeeee-…`) |
| `tests/integration/exp401_exp402_comp_restore_test.zig` | 1 | compensation journal id |

**Expected delta after Batch C lands:** BLOCKER=0, MAJOR ≤ 15 (was 68, removing 53).

### Batch D — T020/T050-adjacent residuals + remaining low-count files (5 files, 9 literals)

| File | Active T010 | Notes |
|---|---:|---|
| `tests/integration/concurrent_instances_test.zig` | 2 | concurrent instance IDs |
| `tests/integration/onboarding_realm_guard_test.zig` | 1 (T010) + 1 (T020) | realm/tenant context id; **only the T010 literal is in scope** — T020 `dummy_ctx_byte` is out of scope |
| `tests/integration/svc02_plugin_dispatch_scope_test.zig` | 1 (T050) | T050 finding is out of scope; this file has **no active T010** — BACKEND-DEV MUST confirm the lint delta is exactly zero for T010 and NOT touch the T050 finding |
| `tests/integration/env01_test.zig` | 2 | env-01 fixture IDs |
| `tests/integration/tm01_tenant_list_test.zig` | 2 | tenant list fixture IDs |

**Expected delta after Batch D lands:** BLOCKER=0, MAJOR ≤ 6 (was 15, removing 9 — `tm01` brings 2 of those; the remaining 4 are residual suppresion noise from `entity_subsystem_test.zig` / `obs06_alerts_test.zig` / `db_integration_test.zig` once the per-file grep is re-run, see §10).

**Final state after all four batches land:** MAJOR < 10 across the project; the `MAJOR → BLOCKER` promotion of T010 in `tools/lint_test_isolation.py` then becomes safe (see §9 step 4).

---

## 6. Per-file pattern catalogue

Across the 29 files, four patterns recur. The catalogue below is the unambiguous instruction set BACKEND-DEV applies at each call site.

### Pattern P1 — `instance-id` (most common)

The dominant pattern: the test inserts a process instance with a hardcoded UUID, then threads that same UUID into tasks/tokens/audit rows/idempotency keys.

**Action:** at the top of the test block (after `var h = helpers.TestHarness.init(allocator)`), declare
```text
const instance_id = try h.newUuidString(allocator);
defer allocator.free(instance_id);
```
(thread shape only — not implementation code). Replace every literal occurrence of the prior instance ID with `instance_id`. Repeat for `def_id` and any related-row IDs.

Files: `adp06_*`, `exp103_*`, `ext02_*`, `iss207_*`, `iss208_*`, `obs06_*`, `sch303_*`, `svc01_*`, `svc03_*`, `adp09_*` (audit rows), `iss601_*`, `exp601_*`, `instance_error_*`, `sch02_*`, `exp401_*`, `tm01_*`, `env03_*`, `concurrent_instances_*`.

### Pattern P2 — `actor-id` (typed `[16]u8` consumers)

The dominant pattern: a `created_by` or `actor_id` column is bound to a typed `[16]u8`. Example: `iss202_merge_atomicity_test.zig` (not in this residual but illustrates the pattern) — `created_by` is parsed from a literal into `[16]u8` via `parseUuid`.

**Action:** use `const actor_id = h.newUuid();` — a 16-byte stack value, no allocation, no defer. Pass `&actor_id` (or `actor_id` if the parameter type is exactly `[16]u8`) into the typed parameter slot. Do **not** stringify and reparse; the helper exists to avoid that allocation.

Files: `db_integration_test.zig` (db0301aa-… literals → typed), `adp06_*` (correlation IDs), `idn02_*`, `idn03_*`, `idn04_*`, `exp103_*` (instance_waits typed), `env01_*` (env fixtures).

### Pattern P3 — `audit-id`

The pattern: a `resource_id` or `audit_entries.resource_id` is hardcoded. Both the INSERT side and the SELECT assertion side reference the same literal.

**Action:** declare one binding per distinct resource identity, pass it into the INSERT, then assert against the same binding. The replacement is mechanical but the **assertion side** is where previous PRs regressed (response field that previously contained the literal now contains the binding — the assertion must reference the binding, not a constant).

Files: `adp09_tamper_evident_audit_chain_test.zig`, `ext02_webhook_dispatch_test.zig` (delivery audit), `obs06_alerts_test.zig`, `iss601_state_snapshots_test.zig`.

### Pattern P4 — `module-const` (forbidden outcome)

The pattern: a non-zero UUID literal is bound at module scope (`const SOME_ID = "abcd…";`) and reused across multiple test blocks.

**Action:** move the binding inside the owning test block; remove the module-level `const`; the binding is now per-block. If the original intent was "the same logical identity across blocks," that intent itself was the bug — different test blocks MUST have distinct identities; the prior sharing is what causes `23505` collisions.

Files: `iss601_state_snapshots_test.zig` (per the §6 follow-up design), `exp103_instance_waits_test.zig` (the `e1030100-*` literals appear in multiple test blocks; per-test per-block bindings).

### Out-of-scope findings (do not touch in this migration)

| Finding | File | Why out of scope |
|---|---|---|
| T020 (module-level mutable var) | `entity_subsystem_test.zig`, `ext03_plugin_integration_test.zig`, `onboarding_realm_guard_test.zig` | T020 is a separate lint rule (module-level mutable state, not hardcoded UUID); fixing it requires refactoring the surrounding test architecture, which is outside the per-test UUID migration's scope. Backlog entry recommended. |
| T050 (no BPM_TEST_DB_URL) | `entity_subsystem_test.zig`, `exp601_tier_quota_test.zig`, `svc02_plugin_dispatch_scope_test.zig` | T050 means the file uses a pool without referencing the env var; the fix is a one-line `const env = std.process.Environ{ .block = .global };` + reference. It is independent of T010. Backlog entry recommended; do NOT touch in this migration. |

---

## 7. Validation gates (per batch and final)

Every batch lands only when all four gates pass in this order.

### Gate G1 — lint strictly decreases

```bash
python tools/lint_test_isolation.py --json tests/integration | tee scratch/lint_<batch>.log
```

- BLOCKER must remain 0 throughout.
- MAJOR for the affected files in the batch must drop by exactly the number of T010 literals the batch replaced (counted from the `count` column of the inner report's §residual_29_files inventory).
- No new T010, T020, or T050 findings may be introduced in any other file by the batch's diff.
- After all four batches land: BLOCKER=0 and MAJOR < 10 across the entire `tests/integration` tree.

If a batch does not strictly decrease MAJOR for its files, BACKEND-DEV MUST inspect the lint diff (`diff scratch/lint_<batch-pre>.log scratch/lint_<batch-post>.log`) to find the missed literal and re-apply the replacement; do not move to the next batch until G1 is green for the current batch.

### Gate G2 — `zig build test` green

```bash
zig build test 2>&1 | tee scratch/zig_build_test_<batch>.log
```

Exit code 0; no "error set" output in stderr (per BACKEND-DEV self-review §4 in `CLAUDE.md`).

### Gate G3 — focused integration test (file-level)

For each migrated file, run the integration-test target that exercises that file. Per `CLAUDE.md` test infrastructure guide §3, this is `zig build test-integration` filtered by the test name or, where a per-module target exists, `zig build test-integration-<module>`. Exit code 0. Per BACKEND-DEV self-review §5, all integration tests must connect to real PostgreSQL via `BPM_TEST_DB_URL`; no mocks.

### Gate G4 — full integration suite

```bash
BPM_TEST_DB_URL=postgres://bpm:bpm@localhost:5433/bpm_test \
  zig build test-integration 2>&1 | tee scratch/zig_test_integration_<batch>.log
```

Exit code 0. No `23505` unique-violation, no `C42883` asymmetric-type-cast, no `40001` serialization, no `40P01` deadlock, no `55P03` lock-timeout attributable to per-test UUID migration.

> **Re-check after each batch.** G4 must pass after every batch, not just at the end. A batch that breaks G4 is a regression in fixture identity; BACKEND-DEV MUST investigate before continuing.

### Stale inventory handling

The 29-file inventory is captured **once** at the start of this design and is the authoritative input to all four batches. If the live lint during a batch lands with **different** per-file counts than §5 predicts (e.g. `ext02_webhook_dispatch_test.zig` had 20 active T010 at design time but a previous batch's commit accidentally suppressed 3 via a baseline edit — this MUST NOT happen, but the check is here as a safety net):

1. BACKEND-DEV records the discrepancy in `result.issues` of the step handoff.
2. BACKEND-DEV does **not** refresh `tools/lint_test_isolation.baseline.json` to mask the discrepancy.
3. BACKEND-DEV continues with the next batch only after CODE-DESIGNER (Step 2 rework) confirms the inventory discrepancy is harmless (e.g. a previously-hidden T010 was already replaced by an unrelated edit on `main` between this run and the lint capture).
4. The final `<10 MAJOR` acceptance is measured against the live lint at the moment of acceptance, not the design-time inventory.

---

## 8. Files-to-change (per batch, exact path set)

Each batch's commit is a single diff touching only the files in that batch. The commit MUST NOT modify `tests/integration/helpers.zig`, `tools/lint_test_isolation.py`, or `tools/lint_test_isolation.baseline.json` (the only acceptable edits to those files are:

- `tools/lint_test_isolation.py` — the post-fix `MAJOR → BLOCKER` promotion at `:84` only, performed once after Batch D lands and lint MAJOR < 10 is verified (see §9 step 4).
- `tools/lint_test_isolation.baseline.json` — refreshed only after a fix batch lands, NEVER to mask a new violation, NEVER before the fix (per `iss0121_per_test_uuids.md` §7 baseline-update rules, which this design inherits).

### Batch A file set

```
tests/integration/adp06_pipeline_run_correlation_test.zig
tests/integration/adp07_agent_role_reserved_usernames_test.zig
tests/integration/adp09_tamper_evident_audit_chain_test.zig
tests/integration/idn02_group_management_test.zig
tests/integration/idn03_role_access_test.zig
tests/integration/idn04_api_token_management_test.zig
tests/integration/ext01_service_task_test.zig
tests/integration/ext03_plugin_integration_test.zig
```

### Batch B file set

```
tests/integration/exp601_tier_quota_test.zig
tests/integration/ext02_webhook_dispatch_test.zig
tests/integration/db_integration_test.zig
tests/integration/obs06_alerts_test.zig
tests/integration/entity_subsystem_test.zig
tests/integration/env03_test.zig
tests/integration/sch02_timer_polling_test.zig
tests/integration/instance_error_test.zig
```

### Batch C file set

```
tests/integration/exp103_instance_waits_test.zig
tests/integration/iss207_error_retry_test.zig
tests/integration/iss208_task_guard_test.zig
tests/integration/iss601_state_snapshots_test.zig
tests/integration/sch303_timer_dlq_test.zig
tests/integration/svc01_service_catalog_scope_test.zig
tests/integration/svc03_definition_activation_scope_test.zig
tests/integration/exp401_exp402_comp_restore_test.zig
```

### Batch D file set

```
tests/integration/concurrent_instances_test.zig
tests/integration/onboarding_realm_guard_test.zig
tests/integration/svc02_plugin_dispatch_scope_test.zig
tests/integration/env01_test.zig
tests/integration/tm01_tenant_list_test.zig
```

> Note on `svc02_plugin_dispatch_scope_test.zig`: this file has **no active T010** (the linter reports only T050 for it). The file is retained in the batch to confirm the lint delta is exactly zero for T010 and to verify the file is not regression-prone. **No T010 replacement is required**; if the post-batch lint shows zero T010 delta for this file (as expected), the batch is complete.

### Linter edit (post-Batch-D only, single line)

```
tools/lint_test_isolation.py:84
```
Change `"MAJOR"` to `"BLOCKER"` in the `Issue(...)` constructor call that emits T010 findings (the only acceptable lint-side edit; per §9 step 4).

---

## 9. Acceptance criteria (final, post-Batch-D)

1. **MAJOR < 10.** `python tools/lint_test_isolation.py tests/integration` reports `MAJOR < 10` (current target: ≤ 6; final value measured against the live lint).
2. **BLOCKER = 0** throughout the run.
3. **29 files fully migrated.** Every non-zero T010 literal in the 29-file inventory has been replaced with a `h.newUuid()` / `h.newUuidString(allocator)` binding; the all-zero sentinel remains only where the API contract requires it. Files with no active T010 (`svc02_plugin_dispatch_scope_test.zig`) are confirmed clean.
4. **T010 promoted from MAJOR to BLOCKER in `tools/lint_test_isolation.py`.** This is the **deferred goal** of this run — it MUST NOT happen until MAJOR < 10 is achieved on disk. The promotion is a one-line edit at `tools/lint_test_isolation.py:84` (changing the `Issue(...)` severity argument from `"MAJOR"` to `"BLOCKER"`); the baseline-aware exit-code gate (`has_failures` includes BLOCKER, which it already does) makes this fail-closed either way. BACKEND-DEV performs this promotion as the **last** step of Batch D, immediately after gate G1 confirms MAJOR < 10.
5. **`zig build test` exit 0** after each batch and at the end.
6. **Full integration suite exit 0** after each batch and at the end. No new `23505` collisions attributable to fixture identity.
7. **No source changes outside the listed files.** `tests/integration/helpers.zig`, `tools/lint_test_isolation.py` (except the single-line severity edit in step 4), and `tools/lint_test_isolation.baseline.json` are untouched by any other diff in this design.
8. **No new helper introduced.** `TestHarness.newUuid` and `TestHarness.newUuidString` are the only UUID-generation API used by the migration; no helper wrapper, no new module, no static utility.
9. **Baseline grows only when justified.** `tools/lint_test_isolation.baseline.json` may be refreshed after a batch lands ONLY to remove T010 entries that the batch replaced (line-number drift after edits); it MUST NOT add new T010 suppressions, MUST NOT suppress T020/T050 findings, and MUST NOT be edited before the fix.
10. **ISS-0121.json update.** Once MAJOR < 10 + T010-promoted-to-BLOCKER are verified, ISSUE-FIXER (Step 3) updates `docs/issues/ISS-0121.json`: `status: RESOLVED`, `resolution` = full migration of N files (where N is the actual count from the live lint), `prevention` = "T010 promoted to BLOCKER in tools/lint_test_isolation.py:84", `resolved_at` = real UTC time, `github_issue` kept as #402 (continuation; #387 is the original). `docs/issues/issue_index.json` ISS-0121 entry synced to RESOLVED.

---

## 10. Risks & mitigations

| Risk | Consequence | Mitigation |
|---|---|---|
| Blind replacement breaks relational identity | Parent/child rows receive different generated IDs, or distinct rows accidentally share one | Migrate per logical identity (Pattern P1 — same binding passed into both INSERTs); trace every binding through SQL parameters and assertions; run focused test after each file |
| Assertion retains old literal | Test fails despite correct fixture INSERT, or test stops checking the created row | Replace every expected payload, URL, correlation, and response comparison with the same local binding (Pattern P3) |
| Module-level generated fixture state | Tests remain order-dependent even though literals disappear | Generate inside each test block; reject any patch that introduces a module-level UUID binding (Pattern P4); the lint baseline excludes `ALL_ZEROS_UUID` so the default tenant sentinel is safe |
| `[16]u8` consumer receives stringified allocation | Costs both an allocation and a parse; defeats the typed helper | Use `h.newUuid()` directly for typed consumers; reserve `h.newUuidString` for textual SQL/API parameters (Pattern P2) |
| `newUuidString` defer missing | Allocation leak across the test block; triggers future T030 | Require `defer allocator.free(id)` immediately after every successful string call; BACKEND-DEV self-review checks this for every replacement |
| Random collision between two fixtures | Theoretical: 128-bit CSPRNG output yields duplicate | Practically negligible; the existing helper has been in production via PR #399/403 for hundreds of millions of integration test invocations without collision |
| Test parallelism under concurrent binaries | Same generated UUID could collide across processes if the CSPRNG is mis-seeded | Zig's `std.crypto.random` is process-local and uses OS entropy; the existing helper has been validated for cross-process safety (PR #399 / 7 helper regression tests, all PASS) |
| Baseline regeneration masks debt | Active defects disappear from CI without being fixed | Per `iss0121_per_test_uuids.md` §7 rules: regenerate from reviewed no-baseline output, forbid new T010 suppressions, inspect count/diff changes |
| Inventory drift (29 vs 24 in GH #402 body vs 19 in pre-existing design) | BACKEND-DEV migrates the wrong file set | Trust the live lint `--json` output, not the prose counts in `ISS-0121.json#files_to_change` or the GH #402 body; the §5 batch split is computed against the live `29` figure |
| T020 finding suppressed as a side effect of a T010 edit | Active T020 finding goes from `MAJOR` to absent | BACKEND-DEV MUST NOT delete the T020-flagged mutable var declaration as part of a T010 replacement; if a refactor is needed, it is a separate backlog entry |
| T050 finding masked by an unrelated env-var reference added during the migration | Active T050 finding goes from `MAJOR` to absent | BACKEND-DEV MUST NOT add a `BPM_TEST_DB_URL` reference solely to silence T050; if the file genuinely does not connect to Postgres (e.g. it tests pure helpers), the T050 is a false positive and must be fixed in the linter, not masked |
| Lint baseline gains new entries accidentally | Suppression grows because line numbers shifted | Run `--no-baseline` once after each batch and rebuild the baseline diff explicitly; require the active T010 count to drop by exactly the number of replacements, not just be hidden |
| Existing tests depend on recognizable literals | Debugging becomes less readable | Keep semantic variable names (`def_id`, `inst_id`, `dlq_id`); include generated values in failure diagnostics where existing test helpers support them |
| Cyclic dependency | New helper could introduce a module cycle | No new helper is added; the design re-uses `helpers.zig:467/479` whose import graph is `tests/integration/* → tests/integration/helpers.zig → std` and remains a strict DAG |
| Concurrent-batch contention (two PRs both migrating overlapping files) | Race condition on test fixtures | This run owns the residual-29 inventory exclusively; PR #404 (ISS-0122) is already merged; no other active WF03 branch owns the integration test files (verified by step 00 module-conflict scan) |

---

## 11. Out of scope (explicit non-goals)

- New helper, wrapper, module, or trait on `TestHarness`. The existing `newUuid`/`newUuidString` API is the contract.
- Weakening the T010 rule by adding more `ALL_ZEROS_UUID`-style exclusions; the linter's exclusion is at the canonical sentinel only.
- Refreshing `tools/lint_test_isolation.baseline.json` to mask new violations. Baseline edits are limited to removing entries whose source literal was replaced in a landed batch.
- Fixing the T020 module-mutable-var findings in `entity_subsystem_test.zig`, `ext03_plugin_integration_test.zig`, `onboarding_realm_guard_test.zig`. These are separate lint defects and require architectural refactors beyond UUID isolation.
- Fixing the T050 BPM_TEST_DB_URL findings in `entity_subsystem_test.zig`, `exp601_tier_quota_test.zig`, `svc02_plugin_dispatch_scope_test.zig`. These are separate lint defects.
- Production schema changes, migrations, or production-data backfills. The migration is test-only.
- Replacing the all-zero default-tenant/no-value sentinel where it is semantically required.
- Deterministic seeded UUIDs for snapshot/replay tests; a future design may introduce a separately named deterministic source if a concrete need arises.
- Rewriting test cleanup architecture, transaction handling, database provisioning, or advisory-lock behavior.

---

## 12. Verification recipe (end of run)

After all four batches land:

```bash
# Gate G1: lint MAJOR < 10, BLOCKER = 0
python tools/lint_test_isolation.py --json tests/integration | tee scratch/lint_final.log
# Expected: BLOCKER=0 MAJOR=<10 MINOR=0

# Gate G1-bis: confirm T010 promotion took effect (only run after the promotion is committed)
python tools/lint_test_isolation.py --no-baseline --json tests/integration | python -c "
import sys, re, json
raw = re.sub(r'^\ufeff', '', sys.stdin.read())
d = json.loads(raw)
t010 = [i for i in d['issues'] if i['code'] == 'T010']
print(f'T010 active (no-baseline): {len(t010)}')
print(f'T010 BLOCKER severity: {sum(1 for i in t010 if i[\"severity\"] == \"BLOCKER\")}')
"
# Expected: T010 active matches the residual count from the post-Batch-D lint; severity is now BLOCKER

# Gate G2: zig build test
zig build test 2>&1 | tee scratch/zig_build_test_final.log

# Gate G3 + G4: full integration suite
BPM_TEST_DB_URL=postgres://bpm:bpm@localhost:5433/bpm_test \
  zig build test-integration 2>&1 | tee scratch/zig_test_integration_final.log

# Gate G5: confirm tools/lint_test_isolation.baseline.json is unchanged since the start of this run
git diff --stat tools/lint_test_isolation.baseline.json
# Expected: either unchanged or only contains removals for T010 entries whose source literal was replaced

# Final: confirm helpers.zig is unchanged
git diff --stat tests/integration/helpers.zig
# Expected: empty diff (no edits to helpers.zig in this run)
```

If any gate fails, BACKEND-DEV records the failure in `result.issues`, escalates to ORCH, and routes back through CODE-DESIGNER (Step 2 rework, max 3 iterations per the WF-03 policy in `docs/agents/workflows/WF-03_issue_resolving.md`).

---

## 13. Implementation handoff (for BACKEND-DEV Step 3)

When this design lands at BACKEND-DEV, the implementation must follow §4 (replacement rule), §5 (batches), §6 (per-file patterns), §7 (validation gates), and §8 (file sets) without deviation. The design is intended to be unambiguous enough that BACKEND-DEV can apply it mechanically: the §5 batch table tells BACKEND-DEV which files to touch in each commit, the §6 catalogue tells BACKEND-DEV which helper to call at each call site, and the §7 gates tell BACKEND-DEV when the batch is ready to land.

The single allowed linter edit (the `MAJOR → BLOCKER` promotion at `tools/lint_test_isolation.py:84`) is gated on the post-Batch-D lint showing `MAJOR < 10`. The promotion MUST NOT happen earlier; promoting T010 to BLOCKER before the migration is complete would block the build with 168 active findings, which is a regression on the current state.

The PR title for each batch follows the convention `test(WF03-gh402-20260803): isolate <area> fixtures (batch <A|B|C|D>)`; the squash-merge subject line is the same.