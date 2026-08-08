# Module: iss0176-lua07-audit-manifest-hash-minimal-wiring

**Covers:** LUA-07 (second acceptance criterion only)
**Related:** GitHub #504, ISS-0176, LUA-04 (`executeScript`), EXT-03 (`plugin_interface.zig`/`plugin_registry.zig`), OBS-03 (`audit_entries`)
**Primary design targets:** `src/engine/lua_script_audit.zig` (new), `migrations/0NN_iss0176_audit_entries_manifest_hash.sql` (new), `tests/integration/iss0176_lua07_audit_manifest_hash_test.zig` (new)

---

## 0. Scope decision (human-operator-confirmed — do not re-litigate)

ISSUE-FIXER's diagnosis (handoff `8f052f0f-0f47-4c9d-bd45-d6bfa2dd3913`) established, and grep
confirms, that **no engine call site invokes the Lua executor today.**
`grep -rn "ScriptResult|executeScript" src/engine/` returns zero matches.
`src/design/lua-integration.md` §25's 3-phase roadmap never schedules real
SERVICE_TASK-with-script engine invocation in any phase. `ScriptResult` /
`executeScriptWithManifest` are exercised exclusively by `src/lua/`'s own
test files.

The human operator was consulted directly on this gap and chose, explicitly,
**Option B** below over the alternative of declaring LUA-07's second criterion
un-satisfiable without the full SERVICE_TASK feature:

- **Option A (rejected):** wait for the full SERVICE_TASK roadmap (all 3
  phases of `lua-integration.md` §25) before this criterion can be met.
- **Option B (chosen):** build a minimal, real, narrow engine-side call path
  now — not a mock, not a stub — that invokes the Lua executor and persists
  `manifest_hash` to a queryable audit record, explicitly scoped smaller than
  full SERVICE_TASK integration.

This document designs Option B. **Every interface, table, and test described
below is real and exercises real code.** The narrowness is in *how the path
is triggered* (§2), not in whether the code that runs is genuine.

---

## 1. Module purpose

Close LUA-07's second acceptance criterion — "a script execution's
`manifest_hash` appears in the persisted execution audit record" — by adding
the smallest genuine engine-side call path that:

1. Calls `src/lua/executor.zig`'s `executeScriptWithManifest` (existing,
   unmodified) from within `src/engine/`.
2. Persists the resulting `ScriptResult.manifest_hash` into a queryable audit
   row via a real `INSERT`, inside the same commit-or-rollback discipline the
   engine already uses for execution-error events (`recordExecutionErrorEventInTx`,
   `src/engine/instance.zig:3470`).
3. Is honestly and permanently labeled, in its doc comment and in this design,
   as **not** the general SERVICE_TASK script-execution handler.

It deliberately does **not** attempt: SERVICE_TASK node-type script dispatch
during normal process execution, script registration/versioning workflows,
limiter enforcement (LUA-08/09/10, already out of scope per `manifest.zig`'s
own header comment), or any BPMN-level "script task" authoring UI. See §6.

---

## 2. Where the minimal call path lives

### 2.1 The existing extension point, and why it is not reused as-is

`src/engine/plugin_registry.zig` + `plugin_interface.zig` (EXT-03) is a real,
wired-in engine extension point: `instance.zig:2896`
(`processServiceTaskRuntimeInTx`) calls
`plugin_registry_mod.resolveGlobalPluginHandler("SERVICE_TASK")` and, if a
handler is registered, invokes it via `invokePluginHandlerSafely` as part of
ordinary SERVICE_TASK token execution — this is genuine production dispatch
code, not test scaffolding.

However: **grep confirms `registerGlobalPluginHandler`/`registerPluginHandler`
are called only from `tests/unit/ext03_plugin_test.zig` and
`tests/integration/{ext03_plugin_integration_test,svc02_plugin_dispatch_scope}_test.zig`
— no production bootstrap path (`src/main.zig` or elsewhere) registers any
handler for any node type today.** Attaching Lua execution to this extension
point would therefore mean either (a) writing a production bootstrap
registration that makes every `SERVICE_TASK` node in every tenant's process
definitions silently start executing Lua scripts — which is exactly the full
SERVICE_TASK-with-script integration this fix must NOT build — or (b)
registering the handler only inside the new integration test, which would
make the "engine call path" indistinguishable from test scaffolding wearing
the extension-point's clothes. Neither is the honest minimal path this issue
calls for, so EXT-03 is named here as the rejected alternative, not reused.

### 2.2 The chosen path: a small, explicitly-labeled engine module

Add `src/engine/lua_script_audit.zig`, a new file with exactly one exported
function:

```
pub fn executeScriptForAudit(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    context: *const lua_executor.ExecutionContext,
    script_source: []const u8,
    script_manifest: *const lua_manifest.ScriptManifest,
    registered_hash: [32]u8,
    actor_id_hex: []const u8,
) LuaScriptAuditError!ScriptAuditOutcome
```

Doc comment (verbatim intent, BACKEND-DEV must preserve this framing):

> `executeScriptForAudit` is a MINIMAL LUA-07-completion path. It is **not**
> the SERVICE_TASK script-execution handler and must not be called from
> `processServiceTaskRuntimeInTx` or any other normal process-execution flow.
> It exists to give the engine one real, callable place that (a) invokes
> `lua.executor.executeScriptWithManifest` and (b) persists the resulting
> `manifest_hash` to `audit_entries` — satisfying LUA-07's second acceptance
> criterion end-to-end. The general SERVICE_TASK-with-script integration
> described in `src/design/lua-integration.md` §25 remains unbuilt; when it
> lands, that work supersedes this function rather than building on it.

Behaviour, precisely:

1. Calls `lua_executor.executeScriptWithManifest(context, script_source,
   script_manifest, registered_hash)` — the real, existing function, no
   wrapping/mocking of its internals.
2. On success (`ScriptResult.success == true` or `false` — both are valid
   *executions*; only a Zig error return means the call itself failed),
   builds an audit row (§3) carrying `action = "lua_script.execute"`,
   `resource_type = "lua_script"`, `resource_id` = a UUID derived from
   `context.instance_id` (already `[]const u8`; parsed/validated the same way
   `bpm_audit_try_uuid` validates elsewhere), and the manifest hash from the
   `ScriptResult`.
3. Executes the `INSERT` on the caller-supplied `conn` (no connection
   management inside this function — same convention as
   `recordExecutionErrorEventInTx`, which also takes `conn: *db.Conn` and
   performs no `BEGIN`/`COMMIT` of its own). The caller controls the
   transaction boundary.
4. Returns a small `ScriptAuditOutcome{ script_result: ScriptResult, audit_id:
   [16]u8 }` so the caller (test or future admin endpoint) can assert on both
   the execution outcome and the audit row's identity in one round trip.
5. Frees nothing the caller owns; `ScriptResult.deinit` remains the caller's
   responsibility exactly as it is for every existing `executeScript*` caller
   today.

### 2.3 What calls `executeScriptForAudit` (the honest part)

Per the operator's chosen scope, the **only** caller in this fix is the
integration test itself (§5) — invoked directly, the same way
`tests/integration/*_test.zig` files already call `TestHarness.init()` and
issue real queries against a real Postgres instance. There is no HTTP route,
no admin endpoint, and no engine-internal caller added in this fix.

This is stated plainly rather than disguised: `executeScriptForAudit` is
production code (real types, real SQL, real error propagation, compiled into
the `engine` module and reachable by anything that imports it), but its
**only current caller** is the integration test that proves LUA-07's second
criterion. This mirrors exactly how `executeScriptWithManifest` itself has
lived since ISS-0169 — real, correct, callable, and today only ever called
from `src/lua/`'s own tests. `lua_script_audit.zig`'s doc comment (§2.2) is
the durable record of this fact so a future reader does not mistake "callable
from anywhere" for "called by the engine's normal execution flow." A follow-up
issue (§6.3) is filed to track wiring a real caller (an admin/ops endpoint or
the eventual SERVICE_TASK integration) — not fixed here.

---

## 3. Audit-record schema decision

### 3.1 Options considered

- **Reuse `audit_log.detail` (JSONB), no schema change.** Rejected: LUA-07's
  criterion is "the manifest_hash appears in the persisted execution audit
  record" and is mutation-checked (§5) — a JSONB blob technically satisfies a
  loose reading, but makes the mutation test weaker (it would assert on a key
  inside an opaque JSON blob rather than a typed column) and gives no index
  for "find all script executions by manifest_hash," which is the realistic
  operational query this data exists to answer. Also `audit_log` is fed by
  generic API-mutation instrumentation (`entity_type`/`entity_id`/`detail`
  free-form) — bending it to carry a fixed-shape 32-byte hash column-like
  value inside JSON is a worse fit than either alternative below.
- **New column on `audit_entries` (`migrations/020_obs03_audit_entries.sql`).**
  Rejected: `audit_entries` is populated exclusively by the
  `bpm_audit_on_mutation()` trigger (§ migration 020) firing on `INSERT
  /UPDATE/DELETE` of specific business tables (`process_definitions`,
  `instance_projections`, `tasks`, `users`, `groups`, `group_members`,
  `api_tokens`, `dead_letter_queue`). A Lua script execution is not a
  row-level mutation of any of those tables, so no trigger would ever
  populate a `manifest_hash` column added here — the column would sit NULL
  for every trigger-fired row and would require a second, parallel
  non-trigger write path anyway. Bending a trigger-fed table to also accept
  direct application-level inserts is a schema-integrity smell independent of
  this fix.
- **New dedicated table `lua_script_execution_audit` (chosen).** A
  purpose-built, application-inserted (not trigger-fed) table matches how
  this data is actually produced — one `INSERT` per script execution, issued
  by engine code, not by a row-mutation trigger. It gives `manifest_hash` a
  real typed column (`BYTEA`, exactly 32 bytes), lets the mutation test
  assert a precise `SELECT ... WHERE manifest_hash = $1` result, and does not
  perturb either existing audit table's contract or its consumers.

### 3.2 Migration description (BACKEND-DEV implements; not written here)

New file `migrations/0NN_iss0176_audit_entries_manifest_hash.sql` (BACKEND-DEV
assigns the next free migration number per the project's numbering
convention). Must:

1. `CREATE TABLE IF NOT EXISTS lua_script_execution_audit` with columns:
   - `audit_id UUID PRIMARY KEY DEFAULT gen_random_uuid()`
   - `instance_id UUID NOT NULL` — the executing instance/context identity
     (§2.2 step 2); not a foreign key to `instance_projections`, since this
     path is reachable without a real process instance existing (the
     integration test may use a synthetic UUID) — mirrors how
     `audit_entries.resource_id` also carries no FK constraint.
   - `actor_id UUID` — nullable, same convention as `audit_entries.actor_id`.
   - `script_success BOOLEAN NOT NULL` — `ScriptResult.success`.
   - `manifest_hash BYTEA NOT NULL` — the 32-byte SHA-256 hash; `NOT NULL`
     because every row this fix writes goes through
     `executeScriptWithManifest`, which always produces a verified hash (the
     plain `executeScript` path, which yields `manifest_hash = null`, is out
     of scope for this audit table — see §6.1).
   - `error_message TEXT` — nullable, `ScriptResult.error_message` when
     `script_success = false`.
   - `occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`.
2. `CHECK (octet_length(manifest_hash) = 32)` — catches a truncated/mis-typed
   write at the database boundary rather than trusting application code
   alone; consistent with this project's general preference for structural
   guarantees (see anti-patterns catalogue on build-graph barriers as
   compile-time guarantees vs runtime hopes).
3. `CREATE INDEX IF NOT EXISTS idx_lua_script_audit_manifest_hash ON
   lua_script_execution_audit(manifest_hash)` — supports the mutation test's
   query and the realistic "find executions of this exact manifest" lookup.
4. `CREATE INDEX IF NOT EXISTS idx_lua_script_audit_instance_time ON
   lua_script_execution_audit(instance_id, occurred_at DESC)` — mirrors the
   time-ordered lookup indexes on both existing audit tables.
5. No triggers, no immutability guard. `audit_entries` enforces
   append-only-ness via `bpm_audit_immutable_guard()` because it is the
   general-purpose tamper-evident audit trail; this table is a narrower,
   purpose-specific record and does not need to duplicate that machinery for
   this fix's scope (an immutability trigger can be added later without
   migration conflict if this table's role expands — noted as a non-blocking
   follow-up, not required now).
6. Unqualified table/index names (no `public.` prefix), consistent with every
   existing migration in this repo (anti-patterns: schema-qualified names
   break when `search_path` differs).
7. Idempotent: `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS`
   throughout, matching migrations 009 and 020's own idempotency style.

---

## 4. Public interface

### 4.1 `src/engine/lua_script_audit.zig` (new file)

```zig
const std = @import("std");
const db = @import("../db/pool.zig");            // exact import path: match whatever
                                                    // instance.zig uses for *db.Conn
const lua_executor = @import("../lua/executor.zig");
const lua_manifest = @import("../lua/manifest.zig");

pub const LuaScriptAuditError = error{
    OutOfMemory,
    InvalidInstanceId,
} || lua_executor_errors; // union of executeScriptWithManifest's declared
                          // error set (errors.LuaError || manifest.ManifestError
                          // || error{OutOfMemory}) plus this module's own DB
                          // error propagation (db.Conn's query error set)

pub const ScriptAuditOutcome = struct {
    script_result: lua_executor.ScriptResult,
    audit_id: [16]u8,

    /// Caller must call script_result.deinit(allocator) — ownership matches
    /// every existing executeScript* caller; this function adds no new
    /// ownership rule on top of the one that already exists.
};

pub fn executeScriptForAudit(
    allocator: std.mem.Allocator,
    conn: *db.Conn,
    context: *const lua_executor.ExecutionContext,
    script_source: []const u8,
    script_manifest: *const lua_manifest.ScriptManifest,
    registered_hash: [32]u8,
    actor_id_hex: ?[]const u8,
) LuaScriptAuditError!ScriptAuditOutcome;
```

Notes for BACKEND-DEV:

- `context.instance_id` is `[]const u8` on `ExecutionContext` (see
  `src/lua/executor.zig:43`); parse/validate it into the audit row's
  `instance_id UUID` column the same way `bpm_audit_try_uuid` in migration
  020 tolerates a non-UUID string (return `InvalidInstanceId` rather than
  `catch unreachable` — per this repo's absolute rule against `catch
  unreachable` on realistic failure paths).
- The SQL `INSERT` MUST use `$1`..`$N` placeholders (no string interpolation
  of `script_source`, `error_message`, or any other data) — the security rule
  in the backend guide applies here exactly as everywhere else.
- `manifest_hash` (`[32]u8` in Zig, `BYTEA` in Postgres) is bound as raw
  bytes, not hex-encoded text — avoid the asymmetric-cast class of bug the
  SQL param-type linter (`tools/lint_sql_param_types.py`) checks for; run
  that linter over the new file before completing the implementation
  handoff.
- This function performs I/O (it is explicitly not `transition.zig` and
  carries no pretense of purity) — same category as
  `recordExecutionErrorEventInTx`, which is the closest existing precedent in
  this codebase for "engine-layer function that persists an execution
  outcome to an audit-shaped table inside a caller-supplied transaction."

### 4.2 Error taxonomy

| Error | Source | Meaning |
|---|---|---|
| `LuaError.*` (existing) | `lua_executor.executeScriptWithManifest` | Sandbox setup or script compile/run failure — propagated unchanged, not caught or reinterpreted by this module |
| `ManifestError.*` (existing) | `lua_manifest.verifyManifestHash` / `validateManifest` (called inside `executeScriptWithManifest`) | Manifest/hash/capability/limit rejection — propagated unchanged |
| `InvalidInstanceId` (new) | `executeScriptForAudit` | `context.instance_id` did not parse as a UUID; the script may still have executed (or been rejected) — this error means only that the audit write could not be attributed, and it MUST NOT be swallowed into a silent skip (per the anti-patterns entry on stubs that discard state and return success: a function that cannot record what it claims to record must return an error, not a placeholder) |
| DB query errors (existing, from `conn`'s error set) | Postgres driver | Propagated unchanged; the caller (test, in this fix's scope) decides rollback |
| `OutOfMemory` (existing) | Both layers | Propagated unchanged |

No new error swallows an existing one. `executeScriptForAudit` adds exactly
one new variant (`InvalidInstanceId`) to the union of what
`executeScriptWithManifest` already declares.

---

## 5. Integration test — mutation-checkable, end-to-end

New file `tests/integration/iss0176_lua07_audit_manifest_hash_test.zig`.

**Test body (real, not mocked):**

1. `TestHarness.init()` — real Postgres connection via `BPM_TEST_DB_URL`,
   per-test isolation per the project's existing integration-test
   conventions (per-test UUIDs, no shared fixture rows).
2. Build a real `ScriptManifest` via `lua_manifest.validateManifest(...)`
   over a fixed capability set and a literal Lua source string (e.g. `"return
   1"`), exactly as `manifest.zig`'s own existing tests already do — no new
   fixture machinery invented.
3. Call `lua_script_audit.executeScriptForAudit(allocator, h.conn, &context,
   script_source, &script_manifest, script_manifest.manifest_hash,
   actor_id_hex)`.
4. Assert the returned `ScriptAuditOutcome.script_result.success == true` and
   `.manifest_hash.? == script_manifest.manifest_hash` (the executor's own
   contract, already true today — this is not what the test exists to catch).
5. **The load-bearing assertion:** query
   `SELECT manifest_hash FROM lua_script_execution_audit WHERE audit_id =
   $1`, using the `audit_id` returned in step 3, and assert the retrieved
   bytes equal `script_manifest.manifest_hash`.
6. Clean up the inserted row in a `defer` (or rely on `TestHarness`'s
   transaction rollback if `conn` is `h.conn`, matching the existing
   integration-test isolation convention — BACKEND-DEV confirms which
   applies once `db.Conn`'s exact transaction semantics for this call are
   settled during implementation).

**Why step 5 is genuinely mutation-checkable (the issue's own bar):**
deleting the `INSERT`, or deleting just the `manifest_hash` column binding
from that `INSERT` (leaving the row written but the column NULL or
zero-filled), makes step 5's `SELECT` either return no row or return a value
that does not equal `script_manifest.manifest_hash` — the test fails either
way. There is no path by which commenting out the persistence write leaves
this test green: unlike an assertion against the in-memory `ScriptResult`
alone (which the hash-producing side, §`executor.zig` `executeScriptWithManifest`,
already satisfies independent of this fix), step 5 can only pass if the audit
row was actually written and actually carries the hash — which is exactly
the second acceptance criterion, and exactly the gap ISSUE-FIXER identified
as unbuilt.

TEST-DESIGNER additionally derives a spec file
`tests/specs/ISS-0176-LUA-07-audit.md` per the standard test-design step; this
design does not prescribe its prose, only the scenario above.

---

## 6. Explicitly out of scope

**Not attempted by this fix — future-phase items:**

1. **SERVICE_TASK-with-script engine integration.** No process definition's
   SERVICE_TASK node executes a Lua script as part of ordinary token
   traversal after this fix lands. `processServiceTaskRuntimeInTx` is
   unmodified. `lua-integration.md` §25's 3-phase roadmap remains entirely
   unbuilt; this fix does not start phase 1, 2, or 3, and must not be
   recorded as having done so in `docs/status/requirement_status.yaml` or the
   changelog beyond LUA-07's own literal criterion.
2. **The plain `executeScript` path** (no manifest, `manifest_hash = null`)
   is not audited by `lua_script_execution_audit` — only the
   manifest-verified path is, since the table's `manifest_hash` column is
   `NOT NULL` by design (§3.2 item 1). Auditing unmanifested executions, if
   ever required, is a separate decision.
3. **An HTTP/admin endpoint calling `executeScriptForAudit`.** None is added.
   The only caller after this fix is the integration test (§2.3). Filing a
   follow-up issue for "give `executeScriptForAudit` a real production
   caller" is DOC-UPDATER/ISSUE-FIXER's responsibility per the incidental-
   finding protocol, not part of this design's acceptance criteria.
4. **Resource-limit enforcement (LUA-08/09/10).** Unaffected; `manifest.zig`'s
   existing header comment already states limits are validated, not
   enforced, and this fix does not change that.
5. **`audit_entries` / `audit_log` schema changes.** Neither existing table is
   altered. This fix adds a third, purpose-built table instead (§3.1).

Any future work that builds real SERVICE_TASK script dispatch should treat
`lua_script_audit.zig` as a reference for "how the engine calls the Lua
executor and persists its manifest hash," not as a component to import
into the SERVICE_TASK runtime path as-is — the real integration will need to
decide manifest lookup/registration, capability derivation from the
executing tenant/definition, and error routing through
`buildExecutionErrorPayload`/`recordExecutionErrorEventInTx` the way
`processServiceTaskRuntimeInTx` already does for its plugin-handler path,
none of which this minimal fix designs.

---

## 7. Acceptance criteria mapping

| LUA-07 criterion (this fix's scope: criterion 2 only) | Satisfied by |
|---|---|
| A genuine, non-mocked engine call path invokes the Lua executor | `src/engine/lua_script_audit.zig::executeScriptForAudit` calling `lua_executor.executeScriptWithManifest` (§2.2, §4.1) |
| `manifest_hash` is persisted to a queryable audit record | New table `lua_script_execution_audit`, `manifest_hash BYTEA NOT NULL` column (§3.2) |
| Integration test proves it end-to-end | `tests/integration/iss0176_lua07_audit_manifest_hash_test.zig` (§5) |
| Mutation-checked ("deleting the hash write makes it fail") | §5's step-5 rationale |
| Honestly scoped, not disguised as full SERVICE_TASK integration | §0, §2.3, §6 (doc comment text is prescriptive and must survive into the implementation) |
