# Module: ISS-0095 Fix — Set Tenant Context in Every Integration Test's `makePool()`

## Module purpose

20 of the 21 `tests/integration/*_test.zig` files named in ISS-0095.json's scope update construct
a `Pool` (either via a local `makePool()` helper, or via inline `Pool.init()` call sites) without
first calling `bpm.api_tenant_context.set(...)`. (The 21st file, `adp10_agent_io_capture_audit_test.zig`,
was verified at design time to already be correct — see "Excluded" below.) `src/db/pool.zig`'s
connection-acquire path falls back to `SET search_path TO public` when no tenant context has been
set, and per `migrations/GBL-073_tnt01_drop_legacy_public_business_tables.sql` the business tables
(`process_definitions`, `instance_projections`, `tasks`, `audit_entries`, `users`, `api_tokens`,
`dead_letter_queue`, `webhook_subscriptions`, `events`, `onboarding_registry`, `service_catalog`,
etc.) no longer exist in `public` — they only exist per-tenant-schema after the Stage-12
schema-per-tenant cutover. This fix applies the already-proven correct pattern (from
`tests/integration/audit_iss103_test.zig`) to all 20 affected files.

## Root cause (adopted from ISS-0095 diagnosis, docs/issues/ISS-0095.json)

Each affected file's own `makePool(allocator, url)` helper is structurally:

```zig
fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    return Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 5 });
}
```

— with no `pub const api_tenant_context = bpm.api_tenant_context;` root-level re-export (required
so `src/db/pool.zig`'s `tenant_context_mod.get()` can see tenant state set from the test binary's
root module) and no `bpm.api_tenant_context.set(...)` call before `Pool.init()`. Any connection
acquired from such a pool runs queries with `search_path=public`, where the tables above no longer
resolve.

`tests/integration/audit_iss103_test.zig` already has the correct pattern and is the reference
implementation:

```zig
pub const api_tenant_context = bpm.api_tenant_context;
// ...
fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_default,public (schema isolation).
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    var pool = try Pool.init(std.testing.io, allocator, PoolConfig{ .url = url, .pool_size = 5 });
    errdefer pool.deinit();
    ...
    return pool;
}
```

## Scope and non-goals

- In scope: the 20 files listed under "Affected files — pattern A" below — add the
  `api_tenant_context` re-export (if not already present at file root) and the
  `.set("00000000-0000-0000-0000-000000000000")` call as the first statement inside each file's
  own `makePool()` helper, before its `Pool.init()` call.
- In scope: the 3 files listed under "Affected files — pattern B" below (`svc01`, `svc03`, `svc04`)
  — these have **no `makePool()`-named helper**; each test case calls `Pool.init()` inline
  directly. For these, add the `api_tenant_context` re-export once at file root, and insert
  `bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");` as the statement
  immediately before **every** inline `Pool.init(...)` call site in the file (5 sites in `svc01`,
  7 in `svc03`, 12 in `svc04` — confirmed by grep at design time; BACKEND-DEV must re-grep for
  `Pool.init(` in each file to get the current authoritative count/line numbers, since line numbers
  will shift as earlier sites in the same file are edited). Do not extract a shared helper function
  as part of this fix — that refactor is out of scope (see below).
- In scope: `tests/integration/adp06_pipeline_run_correlation_test.zig` — this file has exactly one
  `makePool()` helper (line 28), called from two of its three test cases (`TC-ADP-06-02` at line
  123, `TC-ADP-06-03` at line 229). `TC-ADP-06-01` calls only `TestHarness.init()` and never calls
  `makePool()` — nothing to change for that test case. Fixing `makePool()` itself (pattern A, one
  edit) automatically covers both call sites in TC-ADP-06-02 and TC-ADP-06-03. Do not modify the
  file's `TestHarness.init()` calls (present in all three test cases) — those already set correct
  tenant context and are unrelated to this fix.
- In scope: verifying each fixed file compiles and its integration test(s) pass against
  `BPM_TEST_DB_URL`.
- Out of scope: `tests/integration/adp10_agent_io_capture_audit_test.zig`. Originally listed in
  ISS-0095.json's scope-update file list, but verified at design time to contain no `Pool.init()`
  and no `makePool()` anywhere — it uses `TestHarness.init()` exclusively, which already sets
  tenant context correctly (see `tests/integration/helpers.zig` `TestHarness.init()`). This file
  does not exhibit the bug and requires no change. (If TEST-RUNNER re-confirms a tenant-context
  failure signature in this file after the other 20 are fixed, that would indicate the file was
  misattributed for a different reason and should be re-diagnosed as a new issue, not folded into
  this fix.)
- Out of scope: consolidating all files onto a single shared `makePool()` export in
  `tests/integration/helpers.zig` (the issue's own "prevention" note names this as a longer-term
  improvement, not required for this fix). Each file keeps its own local pattern (either a
  `makePool()` helper or inline call sites), with the same tenant-context-set-before-init pattern
  reproduced consistently — this is the same style the reference file (`audit_iss103_test.zig`)
  already established and does not introduce a new abstraction the issue did not ask for.
- Out of scope: `src/db/pool.zig` itself — its `public`-fallback behavior is correct and
  intentional for non-tenant-scoped callers; only test files need to opt into tenant scoping.

## Affected files — pattern A: single `makePool()` helper (17)

Insert the `.set(...)` call as the first statement inside the existing `makePool()` function body,
before its `Pool.init()` call. Add the `api_tenant_context` re-export at file root if not already
present.

1. `tests/integration/adp02_tenant_scope_test.zig`
2. `tests/integration/adp06_pipeline_run_correlation_test.zig` (fixes TC-ADP-06-02/03; TC-ADP-06-01
   needs no change — see scope note above)
3. `tests/integration/adp07_agent_role_reserved_usernames_test.zig`
4. `tests/integration/env03_test.zig`
5. `tests/integration/exp201_202_entities_test.zig`
6. `tests/integration/ext01_service_task_test.zig`
7. `tests/integration/ext02_webhook_dispatch_test.zig`
8. `tests/integration/instance_error_test.zig`
9. `tests/integration/iss203_idempotency_keys_test.zig`
10. `tests/integration/iss207_error_retry_test.zig`
11. `tests/integration/obs03_audit_log_test.zig`
12. `tests/integration/obs05_dlq_test.zig`
13. `tests/integration/obs06_alerts_test.zig`
14. `tests/integration/sch02_timer_polling_test.zig`
15. `tests/integration/tnt_backfill_export_cleanup_test.zig`
16. `tests/integration/tnt_schema_isolation_test.zig`
17. `tests/integration/spt01_provisioning_test.zig`

Before implementing, BACKEND-DEV must re-grep each file above for `fn makePool` to confirm it
still has exactly one such helper (design-time state) — if any file's structure has since diverged
(e.g. now has multiple helpers or inline sites), treat it under pattern B instead and note the
discrepancy in the handoff result.

## Affected files — pattern B: no `makePool()`, inline `Pool.init()` call sites (3)

Add the `api_tenant_context` re-export once at file root. Then insert
`bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");` immediately before **each**
inline `Pool.init(...)` call in the file.

18. `tests/integration/svc01_service_catalog_scope_test.zig` — 5 call sites at design time
    (lines 295, 411, 477, 544, 600 — re-grep for current line numbers before editing)
19. `tests/integration/svc03_definition_activation_scope_test.zig` — 7 call sites at design time
    (lines 166, 217, 271, 330, 365, 415, 461 — re-grep for current line numbers before editing)
20. `tests/integration/svc04_admin_api_test.zig` — 12 call sites at design time
    (lines 154, 192, 232, 271, 303, 359, 469, 507, 602, 676, 732, 758 — re-grep for current line
    numbers before editing)

## Excluded — no change required

- `tests/integration/adp10_agent_io_capture_audit_test.zig` — see "Out of scope" above.

## Design

### Per-file change — pattern A (17 files with a `makePool()` helper)

1. If the file does not already have `pub const api_tenant_context = bpm.api_tenant_context;` at
   root scope, add it near the other `pub const` re-exports / type aliases at the top of the file
   (matching `audit_iss103_test.zig` line 16).
2. Inside the file's `makePool()` function (not `TestHarness`-derived pools, which are already
   correct), insert `bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");` as the
   first statement, before the `Pool.init(...)` call. Use the same tenant UUID constant
   (`"00000000-0000-0000-0000-000000000000"`, the default/seed tenant) as the reference file, since
   these tests already assume that tenant's schema (`tenant_default`) is provisioned by the shared
   test setup.
3. Do not otherwise alter the function's signature, migration-running logic, or error handling —
   this is a minimal, targeted fix, not a refactor.

### Per-file change — pattern B (3 files with inline `Pool.init()` call sites)

1. Add `pub const api_tenant_context = bpm.api_tenant_context;` at file root once, if not already
   present.
2. Re-grep the file for `Pool.init(` to get the current, authoritative list of call sites (line
   numbers in this design are a design-time snapshot and will shift after each edit).
3. Immediately before each `Pool.init(...)` call, insert a line
   `bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");` at the same indentation
   level as the `Pool.init` line. Every site gets this line — do not skip any, and do not attempt
   to deduplicate by extracting a shared helper (out of scope, see above).
4. Do not otherwise alter surrounding logic, test assertions, or error handling.

### Common rule (both patterns)

Do not modify any `TestHarness.init()` call or its surrounding code in any file — `TestHarness`
already sets tenant context correctly (`tests/integration/helpers.zig`) and is unrelated to this
fix.

### Verification

After the edits:

```bash
zig build test-integration-obs03      # dedicated target, exists per ISS-0095
zig build test-integration            # full aggregate suite — all 21 files' cases must now
                                       # reach their real assertions instead of failing on
                                       # "relation ... does not exist"
```

A file's test cases may still fail after this fix for reasons unrelated to tenant-context setup
(e.g. genuine assertion mismatches) — this fix's acceptance criterion is that the specific
`relation "..." does not exist` / `TenantNotFound` / `DefinitionNotFound`-via-public-schema failure
signature is eliminated for all 21 files, not that every test in every file passes for unrelated
reasons.

## Error taxonomy

No new error types introduced. `bpm.api_tenant_context.set()` is infallible (existing API, already
used identically by the reference file and by `TestHarness.init()`).

## Dependencies

- `bpm.api_tenant_context` (existing module, `src/api/tenant_context.zig` or equivalent — already
  imported transitively via `const bpm = @import("bpm");` in every affected file).
- No new dependencies, no migration changes, no build.zig changes.
