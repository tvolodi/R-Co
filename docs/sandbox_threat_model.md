# BPM Platform — Sandbox Threat Model

**Document ID:** EXP-701  
**Version:** 1.0  
**Date:** 2026-06-14  
**Status:** Draft — pending sign-off  
**Go-live gate for:** EXP-702 (Ephemeral Sandbox Tier), EXP-703 (Virtual Clock + Sandbox Auth)  
**Owner:** ARCHITECT  
**Source references:** `docs/BPM_Platform_Backend_Architecture.20260611.md §14`, `src/lua/`, `src/wasm/`, `src/oidc/agent_lifecycle.zig`, `src/api/middleware/auth.zig`

> **Purpose.** Two untrusted runtimes (Lua/LuaJIT and Wasm/Wasmtime) plus the agent pipeline
> collectively constitute the extensibility attack surface of the BPM Platform. This document
> enumerates the host-API contracts, identifies credible threats, specifies mitigations that must
> be in place, and defines the go-live gate checklist that a reviewer must clear before any
> tenant-authored or agent-authored code executes in a production environment.
>
> This document is **not** a record of completed work. It is a contract for what must be true.
> Any gap between this contract and the implementation is a blocker for production launch.

---

## Table of Contents

1. [Lua Host-API Surface](#1-lua-host-api-surface)
2. [Wasm Host-API Surface](#2-wasm-host-api-surface)
3. [Agent Pipeline Auth and Session Binding](#3-agent-pipeline-auth-and-session-binding)
4. [Threat Enumeration](#4-threat-enumeration)
5. [Error Cases](#5-error-cases)
6. [Mitigations Per Threat](#6-mitigations-per-threat)
7. [Go-Live Gate Checklist](#7-go-live-gate-checklist)

---

## 1. Lua Host-API Surface

### 1.1 Runtime

BPM uses **LuaJIT** embedded in the platform process (`src/lua/`). Scripts run in service-task
nodes and variable transformers. Scripts are tenant-authored; the host controls what the script
can see and do.

### 1.2 Allowed Standard Library

The Lua standard library is loaded via `src/lua/stdlib.zig` using an allowlist:

| Module | Loaded | Notes |
|---|---|---|
| `math` | ✅ Full | Arithmetic, random, trigonometry — no side effects |
| `string` | ✅ Partial | Dangerous functions removed (see §1.3) |
| `table` | ✅ Full | Table manipulation — no side effects |
| `io` | ❌ Blocked | File I/O forbidden entirely |
| `os` | ❌ Blocked | Shell execution, process control forbidden entirely |
| `package` | ❌ Blocked | Module loading forbidden — sandboxing depends on this |
| `debug` | ❌ Blocked | Stack introspection, coroutine manipulation forbidden |
| `coroutine` | ❌ Blocked | Not loaded; prevents concurrent execution escapes |
| `utf8` | ❌ Not loaded | Not required; not available |

### 1.3 Removed String Functions

The following functions are explicitly nil'd from the loaded `string` table and from the global
environment by `stdlib.zig`, even though LuaJIT would ordinarily expose them via the `string`
module load:

| Function | Reason blocked |
|---|---|
| `string.dump` | Serialises a Lua function to bytecode — enables reflection and code injection |
| `string.load` | Would allow loading arbitrary Lua code at runtime from a string |
| `string.loadfile` | Would allow loading arbitrary Lua code from a file path |
| `string.dofile` | Would execute an arbitrary file |
| `load` (global) | Same as `string.load` — allow-list controls code execution surface |
| `loadstring` (global) | LuaJIT alias for `load`; removed for completeness |
| `dofile` (global) | Would bypass the instruction limiter and capability system |

**Invariant:** After `loadSafeStdlib()` completes, no Lua function available to a script can
load, compile, or execute arbitrary Lua source beyond the script itself.

### 1.4 Allocator Policy

Lua's allocator is replaced with a bounded allocator (`src/lua/memory_limiter.zig`) at state
creation. The replacement is the `lua_Alloc` callback: all `lua_newstate` calls in the platform
use `memory_limiter.alloc` as the allocator.

**Configured limits** (from `src/lua/manifest.zig`):

| Limit | Minimum | Maximum |
|---|---|---|
| `max_memory_bytes` | 1 MB (1,048,576 B) | 256 MB (268,435,456 B) |

When the ceiling is reached the allocator returns `NULL` to Lua. LuaJIT treats a NULL allocator
response as an out-of-memory error and terminates the script with a Lua error. The task is
subsequently routed to the Dead Letter Queue.

### 1.5 Execution Fuel / Instruction Limit

Instruction counting is implemented via a **Lua hook** set at `LUA_MASKCOUNT` every 100
instructions (`src/lua/instruction_limiter.zig`). The hook reads the limiter from Lua global
state (`__limiter__` light userdata), increments the counter by 100, and calls `lua_error` if
the ceiling is exceeded.

**Configured limits** (from `src/lua/manifest.zig`):

| Limit | Minimum | Maximum |
|---|---|---|
| `max_instructions` | 1,000 | 10,000,000 |

### 1.6 Wall-Clock Timeout

A per-execution `TimeoutContext` (`src/lua/timeout.zig`) records `start_time` at creation and
exposes `checkTimeout()`. The host calls `checkTimeout()` at every host-API entry point. If the
elapsed wall-clock time exceeds `timeout_ms`, the call returns `error.WallClockTimeoutExceeded`
and the execution is terminated.

**Configured limits** (from `src/lua/manifest.zig`):

| Limit | Minimum | Maximum |
|---|---|---|
| `timeout_seconds` | 1 s | 3,600 s (1 hour) |

> **Note on the dual limiter design:** Instruction counting catches tight CPU-bound loops.
> Wall-clock timeout catches blocking operations and slow native-code paths. Both must be present;
> neither alone is sufficient.

### 1.7 Capability Gating

Each Lua script declares a manifest (`src/lua/manifest.zig`, `ScriptManifest`) at registration.
The manifest lists required capability strings. The platform validates the manifest against the
`CapabilitySet` granted to the script at dispatch time. If the manifest requests a capability
not in the granted set, `validateManifest` returns `ManifestError.UnauthorizedCapability` and
the script is rejected before execution begins.

**Standard capability strings** (`src/lua/capabilities.zig`):

| Capability | Effect if granted |
|---|---|
| `variable:read` | Script may call `platform.getVariable(name)` |
| `variable:write` | Script may call `platform.setVariable(name, value)` |
| `service:call:<service_id>` | Script may call the named service from the service catalog |
| `audit:log` | Script may emit structured audit log entries |
| `event:emit` | Script may emit process events |
| `instance:read` | Script may read instance state |

**No capability is implicitly granted.** A script without any capabilities runs in a pure
computation sandbox (math/string/table only, no platform integration).

### 1.8 Script Manifest Integrity

The `ScriptManifest` carries a `manifest_hash` (`[32]u8`, SHA-256). The validator checks the
hash against the canonicalised manifest payload before accepting it. A hash mismatch returns
`ManifestError.ManifestHashMismatch`. This prevents a race condition where a manifest is
replaced between validation and execution.

### 1.9 Host-API Function Table (Authoritative)

Host API functions exposed to Lua scripts are registered in `src/lua/host_api/`. Only functions
corresponding to capabilities in the granted `CapabilitySet` are registered into the Lua state.
Functions outside the granted set are never visible to the script.

| Host function | Required capability | Description |
|---|---|---|
| `platform.getVariable` | `variable:read` | Read an instance variable by name |
| `platform.setVariable` | `variable:write` | Write an instance variable |
| `platform.callService` | `service:call:<id>` | Call a service catalog entry |
| `platform.log` | `audit:log` | Emit a structured log entry |
| `platform.emitEvent` | `event:emit` | Emit a process event |
| `platform.getInstance` | `instance:read` | Read current instance state |

---

## 2. Wasm Host-API Surface

### 2.1 Runtime

BPM uses **Wasmtime** (`src/wasm/`) to execute compiled WebAssembly modules. Wasm is the
highest-capability extension tier — it accepts pre-compiled Wasm binaries from any language
(Rust, C, Go, AssemblyScript). The host-API surface is therefore the strongest isolation
boundary in the platform.

### 2.2 Fuel (CPU Budget)

Wasmtime's fuel mechanism is used via `store_set_fuel` in `WasmStore.init`
(`src/wasm/engine.zig`). Each store receives an instruction-unit budget before execution. When
the budget reaches zero, Wasmtime traps with `OutOfFuel` and execution terminates immediately.

**Default configuration** (`src/wasm/instance.zig`, `InstanceConfig`):

| Parameter | Default | Effect |
|---|---|---|
| `max_fuel` | 1,000,000 units | Module may consume at most this many Wasmtime fuel units |

Modules may declare a per-module `max_fuel` in their `ModuleCapabilities` export
(`src/wasm/capabilities.zig`, `ModuleCapabilities`). The platform enforces that the declared
`max_fuel` does not exceed the platform-configured ceiling for the tenant's tier.

### 2.3 Memory Limits

Each Wasm store is initialized with a `memory_cap` (bytes). The store passes this cap to
Wasmtime's store data. The `memory.zig` module enforces the cap at two points:

1. **Import validation:** every host function that reads or writes linear memory calls
   `validatePointer(store, memory, ptr, len)` before dereferencing. This catches:
   - null pointer (`ptr == 0`)
   - negative pointer (`ptr < 0`)
   - out-of-bounds: `ptr + len > memory_size`
   - integer overflow in pointer arithmetic

2. **`memory.grow` interception:** the host intercepts growth requests and rejects any
   `memory.grow` instruction that would cause total memory to exceed `memory_cap`.

**Default configuration**:

| Parameter | Default | Meaning |
|---|---|---|
| `max_memory_pages` | 256 pages | 16 MB linear memory |
| `memory_cap` | `max_memory_pages × 65536` | Enforced bytes ceiling |

Modules declare `max_memory_pages` in their `ModuleCapabilities` export. The platform caps the
declared value at the tier ceiling.

### 2.4 Capability Gating

Wasm modules declare required capabilities via a `get_capabilities` export (returns a
`ModuleCapabilities` struct). The platform validates this against the module's granted
`CapabilitySet` at registration (`src/wasm/capabilities.zig`).

**Standard Wasm capability strings**:

| Capability | Effect if granted |
|---|---|
| `variable:read` | Module may call `bpm_get_variable(ptr, len, out_ptr, out_len)` |
| `variable:write` | Module may call `bpm_set_variable(key_ptr, key_len, val_ptr, val_len)` |
| `service:call:*` (wildcard) | Module may call any service catalog entry |
| `service:call:<id>` | Module may call the specific named service |
| `audit:log` | Module may call `bpm_log(level, msg_ptr, msg_len)` |
| `uuid:generate` | Module may call `bpm_generate_uuid(out_ptr)` |
| `time:read` | Module may call `bpm_current_time()` → i64 epoch ms |

Wildcard matching (`service:call:*`) is supported via `CapabilitySet.hasWildcard()`. A granted
`service:call:*` matches any `service:call:<id>` target.

**Import allowlist:** at instantiation (`src/wasm/instance.zig`), only host functions
corresponding to granted capabilities are provided in the import list passed to
`wasmtime_instance_new`. A module that imports a function not in its granted capability set
fails instantiation with a linker error before any code runs.

### 2.5 Timeout

A `TimeoutContext` (`src/wasm/timeout.zig`) records start time. The host checks timeout at
every host-API call entry. If elapsed time exceeds the configured `timeout_seconds`, the call
returns an error and no further host-API functions are executed.

**Default timeout** (`InstanceConfig`): 30 seconds.

### 2.6 Instance Pooling

Wasm instances are pooled (`src/wasm/pool.zig`). Pooled instances are **reset between uses**:
the store is re-initialised with a fresh fuel budget and memory cap; all linear memory is
zeroed. No instance state persists across tenant invocations. Modules are cached by SHA-256
content hash (`src/wasm/engine.zig`, `getOrLoadModule`); only the compiled module is shared,
not the store.

### 2.7 Host-API Function Table (Authoritative)

| Host import | Required capability | Description |
|---|---|---|
| `bpm:get_variable` | `variable:read` | Read instance variable |
| `bpm:set_variable` | `variable:write` | Write instance variable |
| `bpm:call_service` | `service:call:<id>` | Invoke service catalog entry |
| `bpm:log` | `audit:log` | Emit structured log |
| `bpm:generate_uuid` | `uuid:generate` | Generate a platform UUID |
| `bpm:current_time` | `time:read` | Read current wall-clock time (ms epoch) |

No other host imports exist. A module that references any symbol outside this table fails to
link at instantiation time and is never executed.

---

## 3. Agent Pipeline Auth and Session Binding

### 3.1 Agent Identity Model

Agents are **Keycloak service principals** — they authenticate as machine clients via the
client-credentials OAuth 2.0 flow, obtaining a short-lived JWT from the tenant's Keycloak realm.
The JWT is validated by `src/api/middleware/auth.zig` against the tenant realm's JWKS endpoint.

`src/oidc/agent_lifecycle.zig` defines the agent principal model:

```
AgentPrincipal {
    actor_id   : []const u8          // The agent's Keycloak client_id
    role       : .platform_admin | .agent_runner | .other
    scopes     : []const IdpScope    // Granted IDP operation scopes
    auth_source: .human | .agent     // Discriminator for role-sim confinement
}
```

The `requireScope(principal, scope)` function enforces that the principal holds the required
`IdpScope` before any IDP management operation proceeds. `platform_admin` bypasses the scope
check; `agent_runner` must hold the explicit scope; all other roles are denied.

### 3.2 Per-Tenant Realm Isolation

Each tenant has its own Keycloak realm. Agent principals are registered in, and issue tokens
from, the tenant's realm. A token issued by tenant A's realm cannot authenticate against
tenant B's realm because:

1. The `iss` claim names the tenant realm URL.
2. `auth.zig` resolves the realm URL from the tenant context (set by the tenant-routing
   middleware before auth runs) and validates the JWT against that realm's JWKS only.
3. A mismatch between JWT `iss` and the resolved realm URL is a hard authentication failure.

**Cross-tenant token replay is structurally impossible** under this model — the token's `iss`
and the tenant context must agree.

### 3.3 Sandbox-Control Auth

The sandbox control surface (`execute`, `assert`, `trace`, `advance_clock`, `complete_task` —
see EXP-703) is an authenticated endpoint. It requires:

1. A valid agent JWT in the `Authorization` header (Bearer token).
2. The agent's `actor_id` must match the `agent_id` recorded when the sandbox was created
   (`sandbox_sessions` table, `owner_agent_id` column).
3. The sandbox must be in the `ACTIVE` state.

Requirement 2 enforces **session binding**: only the agent that claimed the sandbox can control
it. A different agent principal (even from the same tenant) cannot execute commands against a
sandbox it does not own.

### 3.4 Session Binding — (tenant × agent × task_spec)

Each sandbox session is bound to a triple:

| Dimension | Source | Enforcement |
|---|---|---|
| `tenant_id` | JWT `tenant_id` claim, resolved from realm routing | Schema isolation: sandbox schema is `tenant_<slug>_sbx_<uuid>` |
| `agent_id` | JWT `client_id` (actor_id) | `owner_agent_id` check on every sandbox-control request |
| `task_spec_id` | Sandbox claim request body | Stored in `sandbox_sessions.task_spec_id`; assertion checks validate against this spec |

A request that presents a valid agent token but requests control of a sandbox bound to a
different `task_spec_id` is rejected with HTTP 403. The three-way binding prevents an agent
from interfering with a peer agent's concurrent sandbox even within the same tenant.

### 3.5 Role-Simulation Confinement

Agents in the agent pipeline may simulate process roles (e.g. "act as OperationsManager") to
test role-restricted task completion flows. This is a deliberate test feature. The confinement
rules are:

1. **Sandboxes only.** Role simulation is permitted only when `auth_source == .agent` AND
   the request targets a sandbox schema (`tenant_<slug>_sbx_<uuid>`). Role simulation is
   **rejected at the middleware layer** for requests targeting a production or staging schema
   (`tenant_<slug>` without `_sbx_`).

2. **Scope-gated.** The agent must hold the `IdpScope.role_bind` scope to invoke
   role-simulation. Agents without this scope receive HTTP 403 before any simulation state
   is created.

3. **Audit-logged.** Every role-simulation invocation writes an audit entry with
   `action = "role_simulation"`, `actor_id = <agent_id>`, `simulated_role = <role>`,
   `sandbox_id = <id>`. The audit entry is written **inside the same transaction** as the
   simulated action.

4. **No token elevation.** Role simulation is a server-side context flag. It does not cause the
   platform to issue an OIDC token with elevated privileges. The agent's JWT is unchanged
   throughout. The simulated role affects only the platform's process-actor resolution for the
   duration of that request.

---

## 4. Threat Enumeration

The following threats are credible given the attack surfaces documented in §§1–3.

### T-01 — Code Execution Escape (Lua)

**Description:** A malicious or buggy Lua script escapes the sandbox and executes arbitrary
host-process code. Attack vectors include:

- Use of blocked standard-library functions (`os.execute`, `io.popen`, `loadstring`) to spawn
  processes or load new code.
- LuaJIT JIT compiler vulnerabilities that allow crafted bytecode to corrupt host memory.
- FFI abuse: LuaJIT exposes a `ffi` library that, if loaded, allows direct C function calls and
  arbitrary memory access.

**Impact:** Full host-process compromise; access to all tenant data in the process address
space; platform credential exfiltration.

**Severity:** Critical.

---

### T-02 — Code Execution Escape (Wasm)

**Description:** A malicious Wasm module escapes linear memory isolation and corrupts host
memory. Vectors include:

- A bug in Wasmtime's bounds-checking for linear memory accesses.
- An integer overflow in pointer arithmetic allowing an out-of-bounds write.
- A vulnerability in the JIT-compiled native code generated by Wasmtime.

**Impact:** Same as T-01.

**Severity:** Critical.

---

### T-03 — Cross-Tenant Data Leakage

**Description:** A tenant's script or Wasm module reads data belonging to a different tenant.
Vectors include:

- A host-API function that resolves a resource name without enforcing the tenant schema
  context, returning data from another tenant's schema.
- A pooled Wasm instance whose linear memory is not zeroed between uses, leaking the previous
  tenant's variable values.
- A Lua state that is reused across tenants without a fresh state per execution.

**Impact:** Tenant A reads confidential process data from Tenant B. Regulatory violation;
platform trust destroyed.

**Severity:** Critical.

---

### T-04 — Resource Exhaustion (CPU)

**Description:** A script or module executes a tight infinite loop, consuming 100% of a worker
thread's CPU, starving other tenants and platform background tasks (scheduler, webhook
dispatcher, DLQ).

**Impact:** Platform-wide degradation or availability loss for all tenants.

**Severity:** High.

---

### T-05 — Resource Exhaustion (Memory)

**Description:** A script or module allocates unboundedly, consuming all platform heap memory.

**Lua vector:** A script builds a large table or string in a loop; the memory limiter is not
installed or has an excessively high ceiling.

**Wasm vector:** A module calls `memory.grow` repeatedly until the platform OOMs.

**Impact:** Process OOM kill; platform unavailability.

**Severity:** High.

---

### T-06 — Resource Exhaustion (Wall Clock)

**Description:** A script blocks a host thread indefinitely by entering a slow native call
(e.g. a tight Lua loop that calls a slow host-API function on each iteration, resetting the
effective wall-clock per call) or through a deadlock condition.

**Impact:** Thread pool exhaustion; cascading availability failure.

**Severity:** High.

---

### T-07 — Privilege Escalation via Role Simulation

**Description:** An agent uses the role-simulation capability in a production or staging schema
to complete tasks as a role it does not legitimately hold, bypassing business-process approvals.

**Example:** An agent simulates the role of `CEO` in a production instance to approve a
high-value payment without genuine CEO involvement.

**Impact:** Business rule bypass; financial loss; regulatory non-compliance.

**Severity:** Critical.

---

### T-08 — Sandbox Session Hijacking

**Description:** An agent crafts a request to control a sandbox it does not own — for example,
by guessing or intercepting a `sandbox_id`. A successful hijack allows the attacker to poison
the target agent's test assertions, inject false variable values, or advance the clock to cause
spurious test failures.

**Impact:** Test integrity violated; tampered UAT results; falsified go-live gates.

**Severity:** High.

---

### T-09 — Cross-Tenant Token Replay

**Description:** A principal obtains a valid JWT from Tenant A's realm and presents it to an
endpoint routing requests for Tenant B.

**Impact:** Authentication bypass; cross-tenant data access.

**Severity:** Critical.

---

### T-10 — LuaJIT FFI Abuse

**Description:** LuaJIT ships with an `ffi` library that, if loaded, allows Lua code to declare
and call arbitrary C functions and access arbitrary memory. If `ffi` is not explicitly blocked
at state creation, a script can bypass all capability and memory controls.

**Impact:** Full host-process compromise (same as T-01, but easier to exploit).

**Severity:** Critical.

---

### T-11 — Manifest Hash Bypass

**Description:** The manifest hash in `ScriptManifest.manifest_hash` is computed by the client
and submitted with the manifest. If the platform does not independently recompute the hash from
the manifest fields and verify it, a malicious client can submit a manifest claiming benign
capabilities while the hash references a different (more permissive) manifest body.

**Impact:** A script executes with capabilities exceeding what its nominal manifest declares.

**Severity:** High.

---

## 5. Error Cases

This section maps each enumerated threat (T-01 through T-11) to the concrete platform error outcome — the error value, HTTP status code, or observable signal that the system surfaces when the threat is detected and blocked.

| Threat | Detection point | Platform error / signal | HTTP status (if API surface) | Disposition |
|---|---|---|---|---|
| **T-01** Lua code execution escape | `stdlib.zig` blocked-function enforcement; executor pre-flight | `LuaError` propagated as `error.LuaRuntimeError`; specific blocked calls return `nil` in Lua scope | N/A — in-process; task result written to DLQ | Task routed to DLQ with `error_kind = "CapabilityViolation"` |
| **T-02** Wasm execution escape | Wasmtime bounds-check trap; `memory.zig` `validatePointer` | `WasmTrap` from Wasmtime (e.g. memory out of bounds); `error.PointerOutOfBounds` from `validatePointer` | N/A — in-process | Task routed to DLQ with `error_kind = "WasmTrap"` |
| **T-03** Cross-tenant data leakage | Host-API tenant-context check; Wasm pool reset | `error.TenantContextMissing` or `error.TenantSchemaMismatch` from host-API layer | 500 Internal Server Error (tenant context absent); 403 Forbidden (schema mismatch) | Request rejected before data is returned; audit log entry written |
| **T-04** Resource exhaustion (CPU) | Lua instruction limiter hook; Wasm `OutOfFuel` trap | Lua: `error.InstructionLimitExceeded` raised by hook; Wasm: `OutOfFuel` trap from Wasmtime | N/A — in-process | Task routed to DLQ with `error_kind = "InstructionLimitExceeded"` |
| **T-05** Resource exhaustion (memory) | Lua `memory_limiter.zig` NULL return; Wasm `memory.grow` interception | Lua: Lua OOM error (LuaJIT receives NULL from allocator → raises error); Wasm: `error.MemoryCapExceeded` from grow interception | N/A — in-process | Task routed to DLQ with `error_kind = "MemoryLimitExceeded"` |
| **T-06** Resource exhaustion (wall clock) | `TimeoutContext.checkTimeout()` at every host-API entry | `error.WallClockTimeoutExceeded` returned from the host-API call; script/module execution terminates | N/A — in-process | Task routed to DLQ with `error_kind = "TimeoutExceeded"` |
| **T-07** Privilege escalation via role simulation | Auth middleware schema-suffix check; `auth_source` discriminator; `requireScope` | `error.RoleSimulationForbidden` (non-sandbox schema); `error.InsufficientScope` (missing `role_bind`); `error.AgentSourceRequired` (human token) | 403 Forbidden | Request rejected; audit log entry written with `action = "role_simulation_rejected"` |
| **T-08** Sandbox session hijacking | Sandbox control endpoint `owner_agent_id` check; ACTIVE-state check | `error.SandboxNotOwned`; `error.SandboxNotActive` | 403 Forbidden (`SandboxNotOwned`); 404 Not Found (expired/torn-down sandbox) | Request rejected; no state mutation occurs |
| **T-09** Cross-tenant token replay | `auth.zig` JWT `iss` vs. tenant realm URL validation | `error.InvalidIssuer` | 401 Unauthorized | Request rejected before any handler runs; no tenant data accessed |
| **T-10** LuaJIT FFI abuse | `stdlib.zig` explicit nil of `ffi` global at state creation | Lua script accessing `ffi` receives `nil`; any attempt to call it raises a standard Lua nil-call error | N/A — in-process | Script receives Lua runtime error; task routed to DLQ with `error_kind = "CapabilityViolation"` |
| **T-11** Manifest hash bypass | `validateManifest` in `manifest.zig` — platform recomputes hash and compares | `ManifestError.ManifestHashMismatch` | 422 Unprocessable Entity | Registration request rejected; manifest not stored; no script execution occurs |

> **DLQ disposition note.** All in-process errors (T-01 through T-06) that terminate execution without an HTTP surface use the Dead Letter Queue as the observable output channel. The DLQ item carries `error_kind`, `tenant_id`, `task_id`, `instance_id`, and the raw error string. Operators monitor the DLQ for security-pattern anomalies (repeated `CapabilityViolation` or `WasmTrap` errors from the same tenant warrant investigation).

---

## 6. Mitigations Per Threat

### M-01 — Lua Execution Escape Mitigations (addresses T-01, T-10)

| Control | Implementation | Status |
|---|---|---|
| Block `io`, `os`, `package`, `debug` entirely | `stdlib.zig` — libraries never loaded | ✅ Implemented |
| Nil dangerous string/global functions | `stdlib.zig` — `string.dump`, `string.load`, `loadstring`, `dofile`, `load` removed | ✅ Implemented |
| Block FFI explicitly | `ffi` must be nil'd at Lua state creation before any script executes | ⚠️ **Verify** — `stdlib.zig` does not explicitly show `ffi` removal |
| Capability-gate every host-API function | Host API registers functions only for granted capabilities | ✅ Implemented |
| Per-state fresh LuaJIT state | Each script execution creates a new Lua state | ⚠️ **Verify** — executor must not reuse states across tenants |
| JIT hardening | Disable LuaJIT JIT compiler in production builds (`LUAJIT_DISABLE_JIT`) for critical-path sandboxes pending CVE review | ⚠️ **Design decision required** |

---

### M-02 — Wasm Execution Escape Mitigations (addresses T-02)

| Control | Implementation | Status |
|---|---|---|
| Wasmtime's built-in bounds checking | Wasmtime enforces linear memory bounds at the JIT level | ✅ Runtime guarantee |
| Host pointer validation before deref | `memory.zig` — `validatePointer()` on every host call | ✅ Implemented |
| Integer overflow check | `ptr_u + len > memory_size` guard with u64 arithmetic | ✅ Implemented |
| Import allowlist enforcement | Only capability-matched imports passed to `instance_new` | ✅ Implemented |
| Keep Wasmtime updated | Subscribe to Wasmtime security advisories; treat any memory-safety CVE as a P0 blocker | ⚠️ Process requirement |

---

### M-03 — Cross-Tenant Data Leakage Mitigations (addresses T-03)

| Control | Implementation | Status |
|---|---|---|
| Schema-per-tenant isolation | All SQL executes in the tenant's schema search path set by `SET search_path` at connection checkout | ✅ Architectural |
| Host-API functions are tenant-context-bound | Every host-API function receives `tenant_id` from the execution context, not from script input | ✅ Implemented (required in host_api implementation) |
| Fresh Lua state per execution | No Lua state reuse across tenant boundaries | ⚠️ **Verify** |
| Wasm linear memory zeroed between pool reuses | `pool.zig` must zero or replace linear memory before returning an instance to a different tenant | ⚠️ **Verify** — pool reset semantics must be confirmed |
| Capability `instance:read` is scoped to tenant | The host-API implementation must reject instance reads outside the current tenant schema | ⚠️ **Verify** |

---

### M-04 — Resource Exhaustion Mitigations (addresses T-04, T-05, T-06)

| Control | Implementation | Status |
|---|---|---|
| Lua instruction limiter | `instruction_limiter.zig` — LUA_MASKCOUNT hook every 100 instructions; configurable ceiling | ✅ Implemented |
| Lua memory ceiling | `memory_limiter.zig` — custom `lua_Alloc`; NULL returned on ceiling | ✅ Implemented |
| Lua wall-clock timeout | `timeout.zig` — checked at every host-API entry point | ✅ Implemented |
| Wasm fuel budget | `engine.zig` — `store_set_fuel`; Wasmtime traps on exhaustion | ✅ Implemented |
| Wasm memory page cap | `instance.zig` `InstanceConfig.max_memory_pages`; `memory.grow` interception | ✅ Implemented |
| Wasm wall-clock timeout | `wasm/timeout.zig` — checked at every host-API entry | ✅ Implemented |
| Per-tenant execution ceilings enforced at dispatch | The executor must reject manifests whose declared limits exceed the tenant's tier quota | ⚠️ **Verify** — requires EXP-601 (tier→quota model) |
| DLQ routing on limit breach | Tasks that terminate due to any limit are routed to the Dead Letter Queue, not silently dropped | ✅ Implemented (per architecture §14.2) |

---

### M-05 — Privilege Escalation via Role Simulation (addresses T-07)

| Control | Implementation | Status |
|---|---|---|
| Role simulation blocked for non-sandbox schemas | Middleware checks schema suffix (`_sbx_`) before permitting `role_simulation` flag | ⚠️ **Must implement before EXP-703 ships** |
| `role_bind` scope required | `requireScope(principal, .role_bind)` enforced | ✅ Designed — verify implementation in auth.zig middleware path |
| `auth_source == .agent` gate | Role simulation only permitted when JWT discriminator is `.agent` | ⚠️ **Must implement** |
| Audit log every simulation | Audit row written inside the same transaction as the simulated action | ⚠️ **Must implement** |
| No token elevation | Role simulation is a context flag; no JWT is issued with elevated scopes | ✅ Architectural |

---

### M-06 — Sandbox Session Hijacking Mitigations (addresses T-08)

| Control | Implementation | Status |
|---|---|---|
| `owner_agent_id` check on every control request | Sandbox control endpoint validates `actor_id == sandbox_sessions.owner_agent_id` | ⚠️ **Must implement in EXP-703** |
| Sandbox IDs are cryptographically random UUIDs | `sandbox_id = uuid_v4()` — not guessable | ✅ Platform UUID policy |
| Sandbox sessions expire | Idle sandbox sessions older than `sandbox_ttl_seconds` are reaped; expired session control returns 404 | ⚠️ **Must implement** |
| ACTIVE-state check | Control requests to TORN_DOWN or EXPIRED sandboxes are rejected | ⚠️ **Must implement** |

---

### M-07 — Cross-Tenant Token Replay (addresses T-09)

| Control | Implementation | Status |
|---|---|---|
| JWT `iss` matched to tenant realm URL | `auth.zig` validates `iss` against the resolved realm URL for the tenant context | ✅ Implemented |
| Tenant context set before auth middleware | Tenant-routing middleware sets `tenant_id` from the URL path before the auth middleware runs | ✅ Architectural |
| Short token TTL | Agent JWTs should have a TTL of ≤ 5 minutes (configured in Keycloak client settings) | ⚠️ **Configuration gate** |

---

### M-08 — Manifest Hash Bypass (addresses T-11)

| Control | Implementation | Status |
|---|---|---|
| Platform recomputes hash from fields | `validateManifest` must SHA-256 the canonical serialisation of `(capabilities, max_instructions, max_memory_bytes, timeout_seconds)` and compare to `manifest_hash` before accepting | ⚠️ **Verify** — `manifest.zig` carries `ManifestError.ManifestHashMismatch` but the recomputation code must be audited |
| Canonical serialisation is deterministic | Hash input must be deterministically ordered (sorted capability list, fixed-width integers) | ⚠️ **Verify** |

---

## 7. Go-Live Gate Checklist

This checklist must be passed — with evidence attached — before any tenant-authored or
agent-authored Lua script, Wasm module, or sandbox session is activated in a production
environment. An item marked **BLOCK** must be resolved before any production traffic flows.
An item marked **VERIFY** requires a human reviewer to inspect code and attach a sign-off comment.

### 6.1 Lua Sandbox Gate

| # | Gate item | Severity | Evidence required |
|---|---|---|---|
| L-01 | `ffi` library is explicitly nil'd before any user script runs | **BLOCK** | Code review of `stdlib.zig`; test case: script calling `ffi.cdef` must error immediately |
| L-02 | No Lua state is reused across different tenant executions | **BLOCK** | Code review of `executor.zig`; demonstrate fresh state per call |
| L-03 | Instruction limiter is always installed before script execution | **BLOCK** | Code review of executor entry point; unit test with tight loop triggers limit |
| L-04 | Memory limiter is always installed as `lua_Alloc` before script execution | **BLOCK** | Code review of executor entry point; unit test with large table allocation triggers limit |
| L-05 | Wall-clock timeout is always checked at every host-API entry | **BLOCK** | Code review of host_api/; unit test with sleeping script triggers timeout |
| L-06 | All dangerous stdlib functions are removed (dump, load, loadstring, dofile, os, io, package, debug, coroutine) | **BLOCK** | Automated test suite: for each blocked name, assert that accessing it from Lua returns nil |
| L-07 | Manifest hash is recomputed platform-side and verified | **VERIFY** | Code review of `manifest.zig` hash verification path |
| L-08 | Script capability set is locked before execution; no runtime capability mutation | **VERIFY** | Code review of executor; capability set is immutable after dispatch |
| L-09 | Scripts that exceed any limit are routed to the DLQ, not silently dropped or retried | **BLOCK** | Integration test: script hitting instruction limit appears in DLQ with error_kind = "InstructionLimitExceeded" |

### 6.2 Wasm Sandbox Gate

| # | Gate item | Severity | Evidence required |
|---|---|---|---|
| W-01 | Every host-API call validates the linear memory pointer before dereferencing | **BLOCK** | Code review of all host_api/ functions; fuzz test with out-of-bounds pointers |
| W-02 | Pooled instances zero or replace linear memory before reuse across tenants | **BLOCK** | Code review of `pool.zig` reset path; test: write sentinel bytes to memory in tenant A's execution; tenant B must not see them |
| W-03 | Fuel budget is set before every module execution | **BLOCK** | Code review of `engine.zig` `WasmStore.init`; unit test: module in tight loop terminates with OutOfFuel |
| W-04 | Import allowlist: only capability-matched imports provided to `instance_new` | **BLOCK** | Code review of instantiation path; test: module importing uncapable function fails to link |
| W-05 | `memory.grow` requests that exceed the per-instance cap are rejected | **BLOCK** | Unit test: module calling `memory.grow` beyond cap receives trap |
| W-06 | Wasm timeout is checked at every host-API entry | **BLOCK** | Code review; unit test with slow host-API loop triggers timeout |
| W-07 | Wasmtime version is pinned in `build.zig.zon`; a process exists to apply security patches | **VERIFY** | Check `build.zig.zon`; attach Wasmtime CVE monitoring subscription |
| W-08 | Module content hash is verified against the stored artifact hash before execution | **VERIFY** | Code review of `module_registry.zig` and `engine.zig` `getOrLoadModule` |

### 6.3 Agent Pipeline Auth Gate

| # | Gate item | Severity | Evidence required |
|---|---|---|---|
| A-01 | JWT `iss` is validated against the tenant-context realm URL on every request | **BLOCK** | Integration test: token from tenant A presented to tenant B endpoint returns 401 |
| A-02 | Agent tokens have TTL ≤ 5 minutes (Keycloak client configuration) | **BLOCK** | Keycloak admin screenshot or IaC review of client settings |
| A-03 | Role simulation is rejected for non-sandbox schema targets | **BLOCK** | Integration test: agent with `role_bind` scope calling role-sim on production schema receives 403 |
| A-04 | `auth_source == .agent` discriminator is enforced for role simulation | **BLOCK** | Code review of role-sim middleware; human-issued token must not allow role simulation |
| A-05 | Every role-simulation event is written to the audit log in the same transaction | **BLOCK** | Integration test: simulate a role; verify audit log entry appears with `action = "role_simulation"` |
| A-06 | Sandbox session `owner_agent_id` check is enforced on every control request | **BLOCK** | Integration test: agent B attempts to control agent A's sandbox; receives 403 |
| A-07 | Sandbox sessions expire and are reaped | **VERIFY** | Code review of sandbox lifecycle; test: expired session control returns 404 |
| A-08 | `requireScope` enforcement is in the hot path for all IDP management operations | **VERIFY** | Code review of `agent_lifecycle.zig` call sites in `src/oidc/` |

### 6.4 Cross-Cutting Gate

| # | Gate item | Severity | Evidence required |
|---|---|---|---|
| X-01 | Tenant isolation suite passes: a script from tenant A cannot read tenant B's variables | **BLOCK** | Integration test in `tests/integration/` asserting cross-tenant read returns empty/403 |
| X-02 | No script or module can reach the platform database connection pool directly | **VERIFY** | Architectural review: pool is not exposed through any host-API function |
| X-03 | Platform credentials (DB URL, OIDC client secret, HMAC keys) are not accessible from script scope | **BLOCK** | Verify `platform.getVariable` and all host-API functions do not expose environment or config values |
| X-04 | Per-tenant execution limits are derived from tier quota (EXP-601) and not manually configured per-script by the tenant | **VERIFY** | When EXP-601 ships: verify the dispatcher rejects manifests that exceed tier ceilings |
| X-05 | This document has been reviewed and signed off by the ARCHITECT before any untrusted code is promoted to production | **BLOCK** | Sign-off attached to this document (ARCHITECT name + date) |

---

## Appendix A — Default Limit Summary

| Runtime | Parameter | Default | Absolute Maximum |
|---|---|---|---|
| Lua | `max_instructions` | Declared in manifest | 10,000,000 |
| Lua | `max_memory_bytes` | Declared in manifest | 256 MB |
| Lua | `timeout_seconds` | Declared in manifest | 3,600 s |
| Wasm | `max_fuel` | 1,000,000 units | Per tier quota (EXP-601) |
| Wasm | `max_memory_pages` | 256 pages (16 MB) | Per tier quota |
| Wasm | `timeout_seconds` | 30 s | Per tier quota |

---

## Appendix B — Open Questions

| # | Question | Impact |
|---|---|---|
| OQ-1 | Should the LuaJIT JIT compiler be disabled in production sandbox execution? Disabling removes a class of JIT-CVE risk at cost of 2–10× slower execution. | Risk vs. performance trade-off; affects T-01 mitigation depth |
| OQ-2 | Should `string.byte` and `string.char` be blocked? They enable covert channels via crafted byte sequences but are common in legitimate scripts. | Minor: low-impact covert channel vs. usability cost |
| OQ-3 | Should per-tenant execution limit maximums be enforced by kernel middleware before EXP-601 ships, using hardcoded platform defaults? | Gate X-04 may need a temporary lower-bound enforcement path |
| OQ-4 | What is the exact pool-reset semantics for Wasm instances? Full memory wipe vs. new instance allocation? The security posture differs significantly. | Gate W-02; must be resolved before pooling is enabled for multi-tenant use |

---

*Document produced by CODE-DESIGNER agent (EXP-701) as a Type E design artefact.
No implementation code is included. Go-live gates are binding pre-conditions for EXP-702 and EXP-703.*
