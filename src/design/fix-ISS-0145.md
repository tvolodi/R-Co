# Fix design: ISS-0145 / GitHub #457 — ambient `tenant_context` ordering dependency in `tests/integration/*.zig`

## Problem

`tenant_context` (`src/api/tenant_context.zig`) is process-wide threadlocal state.
`Pool.acquire()`'s `applyRequestStorageRouting()` (`src/db/pool.zig`) branches on
`tenant_context.get()` / `getStorageMode()` to decide whether a checked-out
connection's `search_path` routes to `public` (no tenant context) or
`tenant_default,public` (resolved default tenant, SCHEMA mode). When
`tenant_id.len == 0`, routing silently falls back to `search_path TO public` —
it never errors (`src/db/pool.zig` `applyRequestStorageRouting`, the
`tenant_id.len == 0` branch at line 261). This is correct behaviour for the
production no-tenant case (bootstrap token / platform-admin), but it means a
test file that never establishes tenant context gets no loud failure — only a
downstream `C42P01 relation "<table>" does not exist` once a business-table
query resolves against `public` instead of `tenant_default`.

Most `tests/integration/*.zig` files bootstrap their fixtures through
`helpers.zig`'s `TestHarness.init()`, which already handles this correctly: it
calls `bpm.api_tenant_context.clear()` (discard any leftover value from
whatever test ran immediately before it in `main_test.zig`'s fixed
declaration order within this binary) and then
`bpm.api_tenant_context.set(bpm.api_tenant_context.DEFAULT_TENANT_ID)`
(`tests/integration/helpers.zig` lines 816, 965) before returning.

88 files instead define their own local `fn makePool(...)` helper that calls
`Pool.init()` directly, bypassing `TestHarness`. A file in this group whose
`makePool()` (and no other code in the file) never calls
`tenant_context.set()`/`.clear()` is implicitly depending on whatever tenant
context value the immediately-preceding test in the binary happened to leave
set. This is invisible when the umbrella `zig build test-integration` target
happens to schedule a `tenant_context`-setting test right before it, and
severely visible when a narrower binary (`test-integration-svc`,
`test-integration-env`, etc.) compiles the same source into its own binary
with a different immediately-preceding test — reproducing GitHub #457's
~291/543 failure signature.

## Audit result (full file-by-file grep + manual read of every hit — see
ISS-0145 registry entry and this run's diagnosis step for method)

- **56 files: CONFIRMED BUG.** `makePool()` present; the file never
  references `tenant_context`/`api_tenant_context` `.set(`/`.clear(` anywhere.
  Every `pool.acquire()` in the file runs under whatever ambient value the
  previous test left behind.
- **3 files: PARTIAL (same defect, narrower symptom).** `env02_test.zig`,
  `env05_test.zig`, `iss0129_migration_run_advisory_lock_test.zig`. Each
  test's own body *does* call `tenant_context.set(<some_id>)` before its own
  assertions — but only after already calling fixture-setup helpers
  (`insertProductionTenant`, `insertTestTenant`, `provisionTenantSchema`, …)
  that call `pool.acquire()` through `makePool()`'s pool *before* that
  `.set()` call runs. Those fixture INSERTs execute under ambient leftover
  tenant context, not a known value.
- **29 files: SAFE**, already following the correct pattern: `makePool()`
  itself calls `bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000")`
  as its first line, before `Pool.init(...)`. No change needed. This is the
  existing house convention this fix extends to the other 59 files (e.g.
  `tests/integration/obs03_audit_log_test.zig` lines 29-34,
  `instance_error_test.zig` lines 76-79, `ext01_service_task_test.zig` lines
  64-67, `adp02_tenant_scope_test.zig` lines 27-30).

Full file lists for the 56 and the 3 are in this run's diagnosis output
(`handoffs/WF03-gh457-20260806/`) and are reproduced verbatim in the
BACKEND-DEV handoff's `task.description`.

## Scope corrections found during implementation

Verifying reachability of the 56 CONFIRMED-BUG files against `main_test.zig`
and `build.zig` (every file must be `@import`-ed into `main_test.zig` or have
its own `.root_source_file` entry in `build.zig` to ever be compiled) turned
up three files that do not need the `makePool()` change:

- **`iss0076_secrets_table_test.zig`** — has its own dedicated build.zig
  binary (`test-integration-iss0076`) and IS reachable, but its one raw
  `Pool.init()` call runs immediately after `helpers.TestHarness.init()` in
  the same test function, which has already set `tenant_context` to
  `DEFAULT_TENANT_ID`. Genuinely safe as written; excluded from the fix.
- **`oidc31_end_to_end_auth_suite_test.zig`**,
  **`oidc08_claim_mapping_config_test.zig`** — neither is referenced by
  filename anywhere in `main_test.zig` or `build.zig`; both are unreachable
  dead code that is never compiled into any test binary, so the ordering bug
  cannot manifest in them (they never run at all). This is the same defect
  class as GitHub #439 ("55 test-bearing .zig files wired into no build
  target"), which already lists both of these files (and 5 more OIDC files
  this audit also flagged as makePool-having-but-unreachable:
  `oidc35_onboarding_test.zig`, `oidc34_migration_helper_test.zig`,
  `oidc15_realm_deletion_test.zig`, `oidc11_identity_stability_test.zig`,
  `oidc12_realm_tenant_binding_test.zig`, `oidc10_attribute_sync_test.zig`,
  `oidc09_jit_provisioning_test.zig`). No new issue filed — #439 already
  tracks fixing the build-wiring gap; once wired, these files would need the
  same `makePool()` fix applied, which is now a known follow-up captured in
  this design doc for whoever picks up #439.

**Final implementation scope: 49 files** (46 confirmed-bug + 3 partial, all
verified reachable from `main_test.zig`/`build.zig` before editing).

## Fix

**Mechanical, uniform change across all 59 affected files.** In each file's
own `fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool` (or
`!pool_mod.Pool`, matching whichever local alias the file already uses),
insert as the first statement in the function body:

```zig
fn makePool(allocator: std.mem.Allocator, url: []const u8) !Pool {
    // Set the tenant context BEFORE Pool.init so that every pool.acquire()
    // applies SET search_path TO tenant_default,public (schema isolation).
    bpm.api_tenant_context.set("00000000-0000-0000-0000-000000000000");
    return Pool.init(std.testing.io, allocator, PoolConfig{
        .url = url,
        .pool_size = 5,   // preserve each file's existing pool_size value
    });
}
```

This is verbatim the pattern already used by the 29 SAFE files — no new
mechanism, no new helper, just applying the existing convention everywhere
`makePool()` is defined locally. `Pool.init()` itself does not call
`acquire()` (confirmed by reading `src/db/pool.zig` lines 703-720+ — `init`
only opens raw connections and populates the idle list; no routing/search_path
logic runs until `acquire()`), so setting `tenant_context` immediately before
`Pool.init()` and immediately after are equivalent in effect; before is
chosen to match the existing convention exactly.

For files using the `pool_mod.Pool` alias instead of a bare `Pool` import
(e.g. `adp07_agent_role_reserved_usernames_test.zig`,
`adp04_user_tenant_binding_test.zig`, `idn04_api_token_management_test.zig`,
`tm01_tenant_list_test.zig`, and others), use whatever module alias that file
already uses to reach `api_tenant_context` (`bpm.api_tenant_context` if `bpm`
is imported, otherwise the file's existing alias — check each file's imports;
several already import `tenant_context = bpm.api_tenant_context` as a local
alias, e.g. `env02_test.zig` line 27 — reuse it rather than introducing a
second name for the same import in one file).

**The 3 PARTIAL files require no additional change beyond the mechanical
`makePool()` fix.** Adding `tenant_context.set(DEFAULT_TENANT_ID)` inside
`makePool()` establishes a deterministic baseline before the first
`pool.acquire()` (i.e. before any fixture-setup call). Each test's own later
`tenant_context.set(test_id)` / `.clear()` calls, which run after fixture
setup and govern the test's actual assertions, are unchanged and continue to
override the baseline exactly as today — the fix only removes the
*undefined* window between `makePool()` returning and the test's own
`.set()` call, during which fixture-setup queries currently run under
whatever the previous test left behind.

## Non-goals

- **No change to `src/db/pool.zig` or `src/api/tenant_context.zig`.** ISS-0145
  lists "make `Pool.acquire()` fail loudly when `tenant_context` was never
  set" as a design consideration, explicitly marked not mandatory. Rejected
  for this fix: `tenant_id.len == 0` is a legitimate, intentional state in
  production (bootstrap token / platform-admin path, `pool.zig` line 262
  comment) — asserting on it inside `Pool.acquire()` would either break that
  path or require distinguishing "test build, never explicitly set" from
  "production, intentionally no tenant," which is not information available
  inside `pool.zig` itself. The per-file fix below removes the *undefined*
  window without touching production-path semantics.
- **No change to `helpers.zig` / `TestHarness`.** Already correct (this is
  what ISS-0144's fix hardened). Not in scope.
- **No behavioural change to any of the 29 already-SAFE files.**

## Acceptance criteria (from ISS-0145 / GitHub #457, unchanged)

- Every `tests/integration/*.zig` file reachable from `main_test.zig` whose
  own setup never called `tenant_context.set()`/`.clear()` before its first
  `Pool.acquire()` now does so (59 files: 56 confirmed + 3 partial).
- `zig build test-integration-svc` and `zig build test-integration-env` each
  produce a stable, low failure count (comparable to the umbrella
  `zig build test-integration`'s own rate) across 3+ consecutive runs.
