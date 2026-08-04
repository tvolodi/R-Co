# Module: Lua Script Execution (LuaJIT Integration)

**Stage:** 8 — Lua Script Execution  
**Requirements:** LUA-01 through LUA-16

---

## 1. Overview

The Lua integration subsystem embeds LuaJIT for moderate-complexity script execution, providing a sandboxed, capability-controlled execution layer for dynamically generated or user-defined logic. This is Tier 2 of the three-tier execution model (Tier 1: CEL expressions in DSL-12, Tier 2: Lua scripts, Tier 3: WASM in future stages).

**Core design principle:** Isolation first. Every script invocation receives a fresh Lua state with no leakage of globals, memory, or execution context from prior invocations.

---

## 2. C-Interop Strategy (LUA-01)

### 2.1 Static Linking

The Zig binary MUST embed LuaJIT statically. No runtime dependency on a shared Lua library.

**Integration approach:**

```zig
// src/lua/luajit_bindings.zig — FFI declarations only, no implementation

const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lualib.h");
    @cInclude("lauxlib.h");
    @cInclude("luajit.h");
});

pub const LuaState = c.lua_State;
pub const LuaValue = c.lua_Number;

// FFI wrapper function declarations (C signatures)
pub extern fn lua_newstate(f: *const fn (u: ?*c_void, p: ?*c_void, osize: usize, nsize: usize) callconv(.C) ?*c_void, ud: ?*c_void) ?*c.lua_State;
pub extern fn lua_close(L: *c.lua_State) void;
pub extern fn lua_getglobal(L: *c.lua_State, name: [*:0]const u8) c_int;
// ... (additional FFI declarations as needed)
```

**Build integration (`build.zig`):**

- Detect or download LuaJIT source (or pre-built object file)
- Compile LuaJIT to `.a` (static archive) or object files
- Link LuaJIT archive into the final `bpm` binary
- Verify with `ldd` that the binary has no `.so` Lua dependency

**Acceptance criterion:** `ldd ./zig-cache/bin/bpm | grep -i lua` returns no output (or equivalent Windows check).

---

## 3. State Isolation (LUA-02)

### 3.1 Per-Invocation State Lifecycle

**Each script invocation follows this lifecycle:**

1. **Create:** A new `lua_State` is allocated via `lua_newstate()`
2. **Configure:** Standard libs are loaded (math, string, table only; restricted as per §4)
3. **Register:** Host API functions (platform.*) are registered
4. **Execute:** Script source is compiled and run
5. **Destroy:** The state is closed via `lua_close()`; all memory is freed

```zig
// Pseudocode
pub fn executeScript(script: []const u8, capabilities: CapabilitySet, context: ExecutionContext) !ScriptResult {
    // 1. Create a fresh state
    const L = lua_newstate(lua_alloc, null) orelse return error.LuaAllocFailed;
    defer lua_close(L);
    
    // 2. Load restricted standard libraries
    try loadRestrictedStdlibs(L);
    
    // 3. Register host API (platform.* functions)
    try registerHostAPI(L, capabilities, context);
    
    // 4. Execute the script
    const result = try loadAndRun(L, script);
    
    return result;
}
```

### 3.2 Global State Isolation

- **No persistent globals:** Each invocation's state is destroyed; no globals leak to the next invocation.
- **No state caching:** Even though `lua_State` is cheap, we do not reuse states across invocations (simplicity over micro-optimization).
- **Stateless host functions:** Platform API functions receive all data they need as arguments; they don't read from shared mutable state.

**Test:** Execution A sets `globalVar = 42`. Execution B reads `globalVar` and gets `nil`, not `42`.

---

## 4. Stdlib Whitelist and Removal Matrix (LUA-03, LUA-04)

### 4.1 Allowed Modules

Only these standard library modules are loaded:

| Module | Status | Rationale |
|---|---|---|
| `math` | ✓ Fully loaded | Safe mathematical operations; no I/O or code modification |
| `string` | ✓ Loaded with removals | Manipulation is safe; remove dump/load/loadfile/dofile |
| `table` | ✓ Fully loaded | Table operations are safe; no I/O or code injection |
| `io` | ✗ Blocked | File/network I/O forbidden; I/O goes through host API only |
| `os` | ✗ Blocked | System execution forbidden (`os.execute`, `os.getenv`, etc.) |
| `package` | ✗ Blocked | Module loading forbidden; sandboxing depends on this |
| `debug` | ✗ Blocked | Debug hooks and introspection forbidden; security risk |

### 4.2 Function-Level Removals

Within loaded modules, explicitly remove these functions:

**From `string` module:**
- `string.dump()` — bytecode generation (security risk; see LUA-04)
- `loadstring()` / `load()` / `loadfile()` / `dofile()` — code loading (prevents sandbox escape)
- Note: `os.execute` is already blocked by not loading the `os` module, but if any backdoor access exists, remove it

**Implementation:**

```zig
fn loadRestrictedStdlibs(L: *c.lua_State) !void {
    // Load math (fully safe)
    luaopen_math(L);
    lua_setglobal(L, "math");
    
    // Load string (with restrictions)
    luaopen_string(L);
    lua_setglobal(L, "string");
    
    // Remove dangerous string functions
    try removeLuaGlobal(L, "string.dump");
    try removeLuaGlobal(L, "string.load");
    try removeLuaGlobal(L, "string.loadfile");
    try removeLuaGlobal(L, "string.dofile");
    try removeLuaGlobal(L, "loadstring");
    try removeLuaGlobal(L, "load");
    
    // Load table (fully safe)
    luaopen_table(L);
    lua_setglobal(L, "table");
    
    // Do NOT load io, os, package, debug
    // Do NOT call luaopen_io, luaopen_os, luaopen_package, luaopen_debug
}
```

### 4.3 Bytecode Loading Prevention (LUA-04)

Lua scripts MUST be provided as **source text only**. Bytecode (compiled `.lc` or binary format) is rejected.

**Detection:**

Lua bytecode files begin with the magic number `\x1b\x4c\x75\x61` (ESC 'L' 'u' 'a'). Check the input before attempting to load:

```zig
fn loadAndRun(L: *c.lua_State, script: []const u8) !ScriptResult {
    // Reject bytecode: magic number is 0x1b 0x4c 0x75 0x61
    if (script.len >= 4 and 
        script[0] == 0x1b and 
        script[1] == 0x4c and 
        script[2] == 0x75 and 
        script[3] == 0x61) {
        return error.BytecodeNotAllowed;
    }
    
    // Load and compile as source text
    const status = c.luaL_loadstring(L, script.ptr);
    if (status != 0) {
        // Compile error
        const msg = c.lua_tostring(L, -1);
        return error.CompileError;
    }
    
    // Execute
    if (c.lua_pcall(L, 0, 1, 0) != 0) {
        const msg = c.lua_tostring(L, -1);
        return error.RuntimeError;
    }
    
    // Extract result
    return try getScriptResult(L);
}
```

---

## 5. Host API Registration (LUA-05, LUA-06)

### 5.1 Function Registry

The `platform.*` namespace exposes exactly these functions. No others are registered.

| Function | Signature | Capability | Purpose |
|---|---|---|---|
| `platform.read_variable(key)` | `(string) -> any` | `variable:read` | Read instance variable (LUA-11) |
| `platform.write_variable(key, value)` | `(string, any) -> nil` | `variable:write` | Write instance variable (LUA-11) |
| `platform.call_service(svc_id, method, path, headers, body)` | `(string, string, string, table, string) -> table` | `service:call:<svc_id>` | HTTP call to registered service (LUA-12) |
| `platform.log(level, message, context)` | `(string, string, table) -> nil` | `audit:log` | Structured log entry (LUA-13) |
| `platform.now()` | `() -> string` | (none) | Platform time in ISO 8601 UTC (LUA-14) |
| `platform.fail(reason, details)` | `(string, any) -> none` | (none) | Terminate with structured failure (LUA-15) |
| `platform.emit_event(event_type, payload)` | `(string, table) -> nil` | `event:emit` | Append event to event log (LUA-06) |
| `platform.get_instance_state()` | `() -> table` | `instance:read` | Read full instance state (read-only) (LUA-06) |

### 5.2 Capability Check Pattern

Every host function MUST check the caller's capability grant before executing.

```zig
fn platformCallService(L: *c.lua_State) callconv(.C) c_int {
    // Get the capability set from the Lua state's user data
    const capabilities = getCapabilitiesFromLua(L);
    
    // Extract service_id from first argument
    const svc_id = c.lua_tostring(L, 1);
    const capability = try std.fmt.allocPrint(allocator, "service:call:{s}", .{svc_id});
    defer allocator.free(capability);
    
    // Check capability
    if (!capabilities.has(capability)) {
        return luaError(L, "Capability denied: {s} (granted: {s})", .{capability, capabilities.summary()});
    }
    
    // Proceed with the call
    const method = c.lua_tostring(L, 2);
    // ... (rest of implementation)
    
    return 1; // Return value count
}
```

**Error format (Lua error):**

```lua
platform.call_service("forbidden", "GET", "/") 
-- raises: "Capability denied: service:call:forbidden (granted: service:call:approved, variable:read)"
```

### 5.3 Capability Set Storage

Capabilities are attached to the Lua state's user data (via `lua_setuserdata`):

```zig
const ScriptExecutionContext = struct {
    capabilities: CapabilitySet,
    instance_id: []const u8,
    actor_id: []const u8,
    db_conn: *DatabaseConnection,
    allocator: std.mem.Allocator,
};

fn registerHostAPI(L: *c.lua_State, context: *ScriptExecutionContext) !void {
    // Store context as Lua state user data
    c.lua_setuserdata(L, context);
    
    // Create the platform table
    c.lua_newtable(L);
    
    // Register functions
    c.lua_pushcfunction(L, platformCallService);
    c.lua_setfield(L, -2, "call_service");
    
    c.lua_pushcfunction(L, platformReadVariable);
    c.lua_setfield(L, -2, "read_variable");
    
    // ... (more functions)
    
    // Assign to global 'platform'
    c.lua_setglobal(L, "platform");
}
```

---

## 6. Execution Model

### 6.1 Script Invocation Trigger

Scripts are invoked in these scenarios (in later stages):

1. **Service Task with scriptable behavior** — A SERVICE_TASK node can include a Lua script to transform the response body
2. **Condition evaluation fallback** — Complex CEL conditions may be compiled to Lua (future optimization)
3. **Generated logic from Developer Agent** — High-level specifications may be compiled to Lua

### 6.2 Return Value Contract

A script MUST return a single value (or nil):

- **Successful execution:** Return value is captured and type-checked
- **No return / nil return:** Treated as success with no output
- **Error / exception:** Runtime error message is captured; execution fails

```zig
pub const ScriptResult = struct {
    success: bool,
    value: ?ScriptValue,  // nil if no output
    error_message: ?[]const u8,  // null if success
};

pub const ScriptValue = union(enum) {
    nil_value: void,
    boolean: bool,
    number: f64,
    string: []const u8,
    table: std.StringHashMap(ScriptValue),
};
```

### 6.3 Memory Management

- **Allocator:** The Lua state is allocated from the request-scoped allocator (survives for one request)
- **Script source:** Passed as a slice; Lua makes its own copy during compilation
- **Return values:** Converted to Zig types and copied; Lua state is freed before return

---

## 7. Error Handling

### 7.1 Error Types

```zig
pub const LuaError = error {
    LuaAllocFailed,           // lua_newstate returned null
    BytecodeNotAllowed,       // Input starts with Lua bytecode magic
    CompileError,             // luaL_loadstring failed
    RuntimeError,             // lua_pcall failed
    CapabilityDenied,         // Host function called without permission
    TypeError,                // Return value wrong type for context
};
```

### 7.2 Error Propagation

Errors are propagated as Lua exceptions (via `lua_error`):

```zig
fn luaError(L: *c.lua_State, comptime fmt: []const u8, args: anytype) c_int {
    var buffer: [1024]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, fmt, args) catch "error message too long";
    c.lua_pushstring(L, message);
    _ = c.lua_error(L);
    return 0;  // Never reached; lua_error does not return
}
```

When a Lua error is raised, `lua_pcall` returns non-zero, and we extract the error message:

```zig
if (c.lua_pcall(L, 0, 1, 0) != 0) {
    const msg = c.lua_tostring(L, -1);
    return error.RuntimeError;
    // Error context: msg contains the error (capability denial, type error, etc.)
}
```

---

## 8. Security Considerations

### 8.1 No Bytecode Injection

By rejecting bytecode files, we prevent pre-compiled attacks. Scripts MUST be source text.

### 8.2 No Code Generation

Removing `string.dump`, `load`, `loadstring`, `loadfile`, and `dofile` prevents Lua scripts from generating or loading new code dynamically. The only code that runs is the source script provided by the caller.

### 8.3 No I/O or System Access

- `io` module not loaded → no file I/O
- `os` module not loaded → no system execution or environment access
- `package` module not loaded → no dynamic module loading (already sandboxed)
- `debug` module not loaded → no introspection or hook injection

### 8.4 Capability Grants

Every host API function checks the caller's capability before executing. A script cannot call `platform.call_service("admin_only")` unless the capability `service:call:admin_only` is explicitly granted.

### 8.5 Memory Limits

Lua allocations come from the request-scoped allocator. No unbounded allocation is possible (allocator has internal limits per arena).

---

## 23. Public Interface

### 23.1 Core Executor

```zig
// src/lua/executor.zig

pub const ExecutionContext = struct {
    // Identities and routing
    instance_id: []const u8,
    actor_id: []const u8,
    script_id: []const u8,
    trace_id: []const u8,
    
    // Capabilities and permissions
    capabilities: CapabilitySet,
    
    // State access
    instance_state: InstanceState,  // Immutable; can be read but not written via platform.get_instance_state()
    pending_writes: *std.StringHashMap(ScriptValue),  // Transactional writes (staged until success)
    
    // Resource limits and manifest
    manifest: ScriptManifest,  // Declared limits and hash
    instruction_limiter: *InstructionLimiter,
    memory_limiter: *MemoryLimiter,
    timeout_context: TimeoutContext,
    
    // External services
    service_catalog: *ServiceCatalog,
    
    // Logging and events
    time_source: *TimeSource,
    structured_logger: *StructuredLogger,
    event_store: *EventStore,
    
    // Execution result tracking
    explicit_failure: ?ScriptFailure,
    
    // Allocator
    allocator: std.mem.Allocator,
};

pub fn executeScript(
    context: *ExecutionContext,
    script_source: []const u8,
) !ScriptResult;

pub const ScriptResult = struct {
    success: bool,
    value: ?ScriptValue,
    error_type: ?ErrorType,
    error_message: ?[]const u8,
    instruction_count: u64,
    memory_peak: u64,
    wall_clock_elapsed_ms: u64,
};

pub const ErrorType = enum {
    CompileError,
    RuntimeError,
    ExplicitFailure,
    InstructionLimitExceeded,
    MemoryLimitExceeded,
    TimeoutExceeded,
    CapabilityDenied,
};
```

### 23.2 Capability Grant Structure

```zig
// src/lua/capabilities.zig

pub const CapabilitySet = struct {
    grants: std.StringHashMap(void),  // Key = capability string; value is ignored
    allocator: std.mem.Allocator,
    
    pub fn has(self: *const CapabilitySet, cap: []const u8) bool;
    pub fn add(self: *CapabilitySet, cap: []const u8) !void;
    pub fn summary(self: *const CapabilitySet) []const u8;
};

pub const StandardCapabilities = struct {
    pub const SERVICE_CALL_PREFIX = "service:call:";
    pub const VARIABLE_READ = "variable:read";
    pub const VARIABLE_WRITE = "variable:write";
    pub const AUDIT_LOG = "audit:log";
    pub const EVENT_EMIT = "event:emit";
    pub const INSTANCE_READ = "instance:read";
};
```

### 23.3 Manifest and Resource Limits

```zig
// src/lua/manifest.zig

pub const ScriptManifest = struct {
    capabilities: []const []const u8,
    max_instructions: u64,
    max_memory_bytes: u64,
    timeout_seconds: u32,
    manifest_hash: [32]u8,
};

pub fn validateManifest(
    script_artifact: *const ScriptArtifact,
    requested_capabilities: CapabilitySet,
    allocator: std.mem.Allocator,
) !ScriptManifest;
```

### 23.4 Resource Limiter Modules

```zig
// src/lua/instruction_limiter.zig
pub const InstructionLimiter = struct {
    max_instructions: u64,
    instructions_executed: u64,
    allocator: std.mem.Allocator,
    pub fn install(L: *c.lua_State, limiter: *InstructionLimiter, max_instructions: u64) !void;
};

// src/lua/memory_limiter.zig
pub const MemoryLimiter = struct {
    max_memory_bytes: u64,
    current_memory_bytes: u64,
    peak_memory_bytes: u64,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
};

// src/lua/timeout.zig
pub const TimeoutContext = struct {
    timeout_ms: u64,
    start_time: i64,
    timed_out: bool,
    pub fn init(timeout_seconds: u32) TimeoutContext;
    pub fn checkTimeout(self: *TimeoutContext) !void;
};
```

### 23.5 Time Source and Logging

```zig
// src/lua/time_source.zig
pub const TimeSource = struct {
    pub fn now(self: *const TimeSource) !DateTime;
};

pub const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    millisecond: u16,
    pub fn formatISO8601(self: *const DateTime, allocator: std.mem.Allocator) ![]const u8;
};

// src/lua/structured_logger.zig
pub const StructuredLogEntry = struct {
    timestamp: DateTime,
    level: LogLevel,
    message: []const u8,
    script_id: []const u8,
    instance_id: []const u8,
    actor_id: []const u8,
    trace_id: []const u8,
    context: ?ScriptValue,
};

pub const StructuredLogger = struct {
    pub fn log(self: *StructuredLogger, entry: StructuredLogEntry) !void;
};
```

### 23.6 Service Catalog

```zig
// src/lua/service_catalog.zig
pub const RegisteredService = struct {
    service_id: []const u8,
    endpoint_url: []const u8,
    request_schema: ?[]const u8,
    response_schema: ?[]const u8,
    auth_method: AuthMethod,
};

pub const ServiceCatalog = struct {
    services: std.StringHashMap(RegisteredService),
    allocator: std.mem.Allocator,
    pub fn lookup(self: *const ServiceCatalog, service_id: []const u8) ?*const RegisteredService;
};
```

### 23.7 Events and Failures

```zig
// src/lua/events.zig
pub const Event = struct {
    type: EventType,
    instance_id: []const u8,
    payload: EventPayload,
    timestamp: DateTime,
    trace_id: []const u8,
};

pub const EventType = enum {
    SCRIPT_ERROR,
    SCRIPT_FAILED,
    // ... (others from EE-10)
};

pub const EventPayload = union(EventType) {
    SCRIPT_ERROR: ScriptErrorPayload,
    SCRIPT_FAILED: ScriptFailedPayload,
};

pub const ScriptErrorPayload = struct {
    error_message: []const u8,
    stack_trace: []const u8,
    instruction_count: u64,
    memory_peak_bytes: u64,
    capabilities_at_failure: []const u8,
};

pub const ScriptFailedPayload = struct {
    reason: []const u8,
    details: ?ScriptValue,
};

pub const ScriptFailure = struct {
    reason: []const u8,
    details: ?ScriptValue,
    trace_id: []const u8,
    instance_id: []const u8,
};
```

### 23.8 Host API Modules

Each host API function lives in its own module under `src/lua/host_api/`:

```
src/lua/
├── executor.zig              # Main executor (LUA-02)
├── capabilities.zig          # Capability model (LUA-06)
├── luajit_bindings.zig       # C FFI declarations only (LUA-01)
├── stdlib.zig                # Stdlib loading with restrictions (LUA-03, LUA-04)
├── errors.zig                # Error types and mapping
├── manifest.zig              # Script manifest validation (LUA-07)
├── instruction_limiter.zig   # Instruction count enforcement (LUA-08)
├── memory_limiter.zig        # Memory allocation limits (LUA-09)
├── timeout.zig               # Wall clock timeout enforcement (LUA-10)
├── time_source.zig           # Platform authoritative time (LUA-14)
├── structured_logger.zig     # Structured logging (LUA-13)
├── service_catalog.zig       # Service registration and lookup (LUA-12)
├── events.zig                # Event types and payloads (LUA-15, LUA-16)
└── host_api/
    ├── read_variable.zig     # platform.read_variable (LUA-11)
    ├── write_variable.zig    # platform.write_variable (LUA-11)
    ├── call_service.zig      # platform.call_service (LUA-12)
    ├── log.zig               # platform.log (LUA-13)
    ├── now.zig               # platform.now (LUA-14)
    ├── fail.zig              # platform.fail (LUA-15)
    ├── emit_event.zig        # platform.emit_event (LUA-06)
    └── get_instance_state.zig # platform.get_instance_state (LUA-06)
```

---

## 10. External Dependencies

| Dependency | Module | Purpose |
|---|---|---|
| LuaJIT | `luajit_bindings.zig` (C FFI) | Embedded script runtime (LUA-01) |
| `src/engine/state.zig` | `executor.zig` | InstanceState type for context (LUA-02) |
| `src/event_store/store.zig` | `events.zig`, `host_api/emit_event.zig` | Event appending (LUA-16, LUA-15, LUA-06) |
| `src/tasks/manager.zig` | `host_api/read_variable.zig`, `host_api/write_variable.zig` | Variable access (LUA-11) |
| `src/identity/tokens.zig` | `capabilities.zig` | Capability validation (LUA-06, LUA-07) |
| `src/api/errors.zig` | `errors.zig` | Error response mapping |
| Service catalog | `service_catalog.zig`, `host_api/call_service.zig` | Service lookup and invocation (LUA-12, REPO-07) |
| Structured logging | `structured_logger.zig`, `host_api/log.zig` | Audit and trace logging (LUA-13, OBS-01, API-09) |
| Time source | `time_source.zig`, `host_api/now.zig` | Platform authoritative time (LUA-14, SIM-03) |

---

## 11. Testing Strategy

### 11.1 Unit Tests (No DB)

**Core Isolation (LUA-01, LUA-02):**
- `test_lua_isolation`: Fresh state for each invocation; no global leakage
- `test_simple_script`: Execute a basic arithmetic script and verify result

**Stdlib Restrictions (LUA-03, LUA-04):**
- `test_stdlib_whitelist`: math, string, table available; io, os, package, debug blocked
- `test_stdlib_removals`: string.dump, load, loadstring, loadfile, dofile all raise errors
- `test_bytecode_rejection`: Scripts starting with bytecode magic are rejected
- `test_bytecode_magic_detection`: Byte-for-byte check of ESC 'L' 'u' 'a' rejection

**Capability Framework (LUA-05, LUA-06):**
- `test_capability_checks`: Host API denies calls without matching capabilities
- `test_capability_error_format`: Denied capability error includes capability string and granted set

**Manifest Validation (LUA-07):**
- `test_manifest_validation_pass`: Valid manifest loads successfully
- `test_manifest_validation_unauthorized_capability`: Undeclared capability is rejected
- `test_manifest_validation_limit_bounds`: Limits outside safe ranges are rejected
- `test_manifest_hash_verification`: Changed artifact without re-registration is rejected

**Instruction Limit (LUA-08):**
- `test_instruction_limit_loop`: Infinite loop terminates within configured limit
- `test_instruction_limit_normal`: Script within limit executes fully
- `test_instruction_limit_error_structure`: Error includes limit and executed count

**Memory Limit (LUA-09):**
- `test_memory_limit_exceeded`: 1 GB allocation with 16 MB limit fails cleanly
- `test_memory_limit_normal`: Script within limit executes normally
- `test_memory_limit_peak_tracking`: Peak usage is recorded

**Wall Clock Timeout (LUA-10):**
- `test_timeout_normal`: Script completes within timeout
- `test_timeout_on_loop`: Infinite loop terminates within timeout
- `test_timeout_error_structure`: Error includes timeout and elapsed time

**Time Source (LUA-14):**
- `test_platform_now`: `platform.now()` returns valid ISO 8601 UTC string
- `test_platform_now_format`: Format is YYYY-MM-DDTHH:MM:SS.sssZ
- `test_os_time_not_available`: `os.time` is `nil`

### 11.2 Integration Tests (With DB)

**Variable Access (LUA-11):**
- `test_read_variable`: Scripts read instance variables correctly
- `test_write_variable`: Scripts stage variable writes
- `test_write_on_success`: Writes are applied after successful execution
- `test_write_on_failure`: Writes are discarded after failed execution
- `test_write_ordering`: Multiple writes to same key result in final value
- `test_read_after_write`: Script reads modified variable within same execution

**Service Calls (LUA-12):**
- `test_call_service_success`: Registered service round-trips correctly
- `test_call_service_not_found`: Non-existent service returns structured error
- `test_call_service_capability_denied`: Missing capability denies access
- `test_call_service_http_error`: HTTP errors return structured response

**Logging (LUA-13):**
- `test_log_info`: Log at INFO level appears in structured output
- `test_log_with_context`: Log entries include context fields
- `test_log_correlation_ids`: Log includes trace_id, instance_id, actor_id
- `test_log_capability_denied`: Missing audit:log capability denies access

**Structured Failure (LUA-15):**
- `test_explicit_failure`: `platform.fail` terminates execution
- `test_explicit_failure_with_details`: Failure includes details
- `test_script_failed_event`: SCRIPT_FAILED event is emitted
- `test_error_policy_routing`: Instance transitions per error policy

**Runtime Error Capture (LUA-16):**
- `test_runtime_error_captured`: Division by zero captured as SCRIPT_ERROR
- `test_nil_access_error`: Nil access error captured with message
- `test_stack_trace_detail`: Stack trace includes function names and line numbers
- `test_error_instruction_count`: Instruction count recorded with error
- `test_error_capability_state`: Capability set included in error payload
- `test_error_vs_explicit_failure`: Uncaught errors distinguished from `platform.fail`

### 11.3 Security Tests

- Attempt `io.open()` (should fail)
- Attempt `os.execute()` (should fail)
- Attempt `require()` (should fail)
- Attempt to load bytecode (should fail)
- Attempt `string.dump()` (should fail)
- Attempt to modify `platform` table (should fail)
- Attempt to access Lua debug API (should fail)

### 11.4 Cross-Module Compatibility

- (Future) Lua vs. Wasm host API parity tests (see WASM-12)

---

## 12. Capability Manifest Validation (LUA-07)

### 12.1 Manifest Structure

Each Lua script MUST carry a capability manifest declaring the capabilities it requires to execute:

```lua
-- script.lua
return {
    __manifest__ = {
        capabilities = {
            "variable:read",
            "variable:write",
            "service:call:payment_svc"
        },
        max_instructions = 100000,
        max_memory_bytes = 16777216,  -- 16 MB
        timeout_seconds = 30
    },
    -- Script logic follows
    function main(instance_id)
        return instance_id
    end
}
```

Alternatively, the manifest may be provided separately as JSON or embedded in the script artifact metadata.

### 12.2 Manifest Validation at Load

**When a script is loaded, the platform MUST:**

1. Extract or verify the manifest
2. Validate that the manifest's declared capabilities are a subset of the script's registered capabilities
3. Validate that the manifest's declared limits (instruction count, memory, timeout) are ≥ safe minimums and ≤ safe maximums
4. Record the manifest hash with the execution record

```zig
// src/lua/manifest.zig

pub const ScriptManifest = struct {
    capabilities: []const []const u8,
    max_instructions: u64,
    max_memory_bytes: u64,
    timeout_seconds: u32,
    manifest_hash: [32]u8,  // SHA-256 of the manifest
};

pub fn validateManifest(
    script_artifact: *const ScriptArtifact,
    requested_capabilities: CapabilitySet,
    allocator: std.mem.Allocator,
) !ScriptManifest {
    const manifest = try parseManifest(script_artifact, allocator);
    defer allocator.free(manifest.capabilities);
    
    // Verify all declared capabilities are registered
    for (manifest.capabilities) |cap| {
        if (!requested_capabilities.has(cap)) {
            return error.UnauthorizedCapability;
        }
    }
    
    // Validate limits are within safe ranges
    if (manifest.max_instructions < 1000) {
        return error.InstructionLimitTooLow;
    }
    if (manifest.max_instructions > 10_000_000) {
        return error.InstructionLimitTooHigh;
    }
    
    if (manifest.max_memory_bytes < 1_048_576) {  // 1 MB min
        return error.MemoryLimitTooLow;
    }
    if (manifest.max_memory_bytes > 268_435_456) {  // 256 MB max
        return error.MemoryLimitTooHigh;
    }
    
    if (manifest.timeout_seconds < 1) {
        return error.TimeoutTooLow;
    }
    if (manifest.timeout_seconds > 3600) {  // 1 hour max
        return error.TimeoutTooHigh;
    }
    
    // Compute and verify manifest hash
    const hash = try computeManifestHash(script_artifact, allocator);
    std.mem.copy(u8, &manifest.manifest_hash, &hash);
    
    return manifest;
}

pub const ManifestError = error {
    UnauthorizedCapability,
    InstructionLimitTooLow,
    InstructionLimitTooHigh,
    MemoryLimitTooLow,
    MemoryLimitTooHigh,
    TimeoutTooLow,
    TimeoutTooHigh,
    ManifestHashMismatch,
    MalformedManifest,
};
```

### 12.3 Manifest Recording

The manifest hash and declared limits are recorded in the execution result:

```zig
pub const ScriptExecutionRecord = struct {
    script_id: []const u8,
    manifest_hash: [32]u8,
    declared_capabilities: []const []const u8,
    declared_max_instructions: u64,
    declared_max_memory_bytes: u64,
    declared_timeout_seconds: u32,
    actual_instructions_consumed: u64,
    actual_memory_peak_bytes: u64,
    wall_clock_elapsed_ms: u64,
};
```

### 12.4 Test Strategy

- **test_manifest_validation_pass:** A script with valid manifest and granted capabilities loads successfully.
- **test_manifest_validation_unauthorized_capability:** A script declaring `service:call:admin` without that capability is rejected with `UnauthorizedCapability`.
- **test_manifest_validation_limit_bounds:** A script with instruction limit below 1000 is rejected; one above 10M is rejected.
- **test_manifest_hash_mismatch:** A script whose artifact hash changed without manifest re-registration is rejected.

---

## 13. Instruction Limit (LUA-08)

### 13.1 Instruction Counting Mechanism

Lua instructions are counted via a hook callback registered with `lua_sethook`:

```zig
// src/lua/instruction_limiter.zig

pub const InstructionLimiter = struct {
    max_instructions: u64,
    instructions_executed: u64,
    allocator: std.mem.Allocator,
    
    pub fn install(L: *c.lua_State, limiter: *InstructionLimiter, max_instructions: u64) !void {
        limiter.max_instructions = max_instructions;
        limiter.instructions_executed = 0;
        
        // Register the hook callback with the Lua state
        // The callback is invoked every N instructions (e.g., every 100)
        c.lua_sethook(L, luaHookCallback, LUA_MASKCOUNT, 100);
        
        // Store the limiter instance in the Lua state's user data (thread-local storage)
        c.lua_setuserdata(L, limiter);
    }
};

fn luaHookCallback(L: *c.lua_State, ar: *c.lua_Debug) callconv(.C) void {
    const limiter = c.lua_getuserdata(L) orelse return;
    
    limiter.instructions_executed += 100;  // Approximate; actual count is hook interval
    
    if (limiter.instructions_executed > limiter.max_instructions) {
        // Raise a Lua error; the execution will terminate
        _ = c.lua_error(L);
    }
}
```

### 13.2 Error Handling

When the instruction limit is exceeded, a structured error is returned:

```zig
pub const InstructionLimitError = struct {
    instruction_limit: u64,
    instructions_executed: u64,
    script_id: []const u8,
};

pub fn onInstructionLimitExceeded(
    script_id: []const u8,
    limit: u64,
    executed: u64,
    allocator: std.mem.Allocator,
) !ScriptError {
    return ScriptError{
        .code = "INSTRUCTION_LIMIT_EXCEEDED",
        .message = try std.fmt.allocPrint(
            allocator,
            "Script exceeded instruction limit: {} of {} executed",
            .{ executed, limit }
        ),
        .script_id = script_id,
        .detail = .{ .instruction_limit = InstructionLimitError{
            .instruction_limit = limit,
            .instructions_executed = executed,
            .script_id = script_id,
        }},
    };
}
```

### 13.3 Test Strategy

- **test_instruction_limit_loop:** An infinite loop terminates within the configured limit.
- **test_instruction_limit_normal:** A script that stays within the limit executes normally.
- **test_instruction_limit_error_structure:** The error returned includes script ID and limit details.

---

## 14. Memory Limit (LUA-09)

### 14.1 Memory Allocation Control

Lua's allocator is replaced with a bounded allocator that tracks total memory and enforces a per-execution ceiling:

```zig
// src/lua/memory_limiter.zig

pub const MemoryLimiter = struct {
    max_memory_bytes: u64,
    current_memory_bytes: u64,
    peak_memory_bytes: u64,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    
    pub fn alloc(ud: ?*c_void, ptr: ?*c_void, osize: usize, nsize: usize) callconv(.C) ?*c_void {
        const limiter = @ptrCast(*MemoryLimiter, ud orelse return null);
        
        limiter.mutex.lock();
        defer limiter.mutex.unlock();
        
        if (nsize == 0) {
            // Deallocation
            limiter.current_memory_bytes -= osize;
            limiter.allocator.free(ptr.?[0..osize]);
            return null;
        }
        
        // Allocation or reallocation
        if (limiter.current_memory_bytes + (nsize - osize) > limiter.max_memory_bytes) {
            return null;  // Allocation failed
        }
        
        const new_ptr = limiter.allocator.realloc(
            if (ptr) |p| p[0..osize] else &[0]u8{},
            nsize,
        ) catch return null;
        
        limiter.current_memory_bytes += (nsize - osize);
        if (limiter.current_memory_bytes > limiter.peak_memory_bytes) {
            limiter.peak_memory_bytes = limiter.current_memory_bytes;
        }
        
        return new_ptr.ptr;
    }
};

pub fn installMemoryLimiter(
    L: *c.lua_State,
    limiter: *MemoryLimiter,
    max_memory_bytes: u64,
    allocator: std.mem.Allocator,
) !void {
    limiter.max_memory_bytes = max_memory_bytes;
    limiter.current_memory_bytes = 0;
    limiter.peak_memory_bytes = 0;
    limiter.allocator = allocator;
    
    // The Lua state is created with the custom allocator
    // (This is set up at lua_newstate time, not afterwards)
}
```

### 14.2 Graceful Allocation Failure

When memory allocation fails, Lua's `lua_newstate` returns null, and we propagate the error:

```zig
pub const MemoryLimitError = struct {
    memory_limit: u64,
    memory_allocated: u64,
    allocation_request: u64,
};

pub fn onMemoryLimitExceeded(
    limit: u64,
    current: u64,
    requested: u64,
) ScriptError {
    return ScriptError{
        .code = "MEMORY_LIMIT_EXCEEDED",
        .message = try std.fmt.allocPrint(
            allocator,
            "Memory allocation failed: {} + {} bytes > {} limit",
            .{ current, requested, limit }
        ),
        .detail = .{ .memory_limit = MemoryLimitError{
            .memory_limit = limit,
            .memory_allocated = current,
            .allocation_request = requested,
        }},
    };
}
```

### 14.3 Test Strategy

- **test_memory_limit_exceeded:** Attempting to allocate 1 GB with a 16 MB limit fails cleanly (no host crash).
- **test_memory_limit_normal:** A script within the memory limit executes normally.
- **test_memory_limit_peak_tracking:** Peak memory usage is recorded in the execution record.

---

## 15. Wall Clock Timeout (LUA-10)

### 15.1 Host-Enforced Timeout

The wall clock timeout is enforced by the host (Zig), not by Lua. This ensures timeouts work even if a host function blocks or Lua enters a tight loop that the hook callback can't interrupt promptly.

```zig
// src/lua/timeout.zig

pub const TimeoutContext = struct {
    timeout_ms: u64,
    start_time: i64,  // nanoseconds since epoch
    timed_out: bool,
    
    pub fn init(timeout_seconds: u32) TimeoutContext {
        return TimeoutContext{
            .timeout_ms = @intCast(u64, timeout_seconds) * 1000,
            .start_time = std.time.nanoTimestamp(),
            .timed_out = false,
        };
    }
    
    pub fn checkTimeout(self: *TimeoutContext) !void {
        const now = std.time.nanoTimestamp();
        const elapsed_ms = @intCast(u64, now - self.start_time) / 1_000_000;
        
        if (elapsed_ms > self.timeout_ms) {
            self.timed_out = true;
            return error.WallClockTimeoutExceeded;
        }
    }
};

pub fn executeScriptWithTimeout(
    L: *c.lua_State,
    script: []const u8,
    timeout_seconds: u32,
    allocator: std.mem.Allocator,
) !ScriptResult {
    var timeout_ctx = TimeoutContext.init(timeout_seconds);
    
    // Set up a separate thread or async task to monitor timeout
    // (or use a platform-specific timer mechanism)
    
    // Execute the script
    timeout_ctx.checkTimeout() catch |err| {
        if (err == error.WallClockTimeoutExceeded) {
            return error.TimeoutExceeded;
        }
        return err;
    };
    
    // ... (rest of execution)
    
    // Final timeout check before returning
    try timeout_ctx.checkTimeout();
    
    return result;
}
```

### 15.2 Interruption Strategy

On timeout, the execution is interrupted as follows:

1. If the Lua state is executing (in `lua_pcall`), a Lua error is raised via `lua_error` from a signal handler or timer callback
2. If a host function is executing, the host function checks the timeout on return
3. The Lua state is closed, and a timeout error is propagated

```zig
fn timeoutInterruptHandler() void {
    // Signal handler or timer callback that is invoked when timeout elapses
    // Raise a Lua error in the Lua state
    g_lua_state_for_timeout.* |L| {
        _ = c.lua_error(L);
    };
}
```

### 15.3 Test Strategy

- **test_timeout_normal:** A script that completes quickly executes fully.
- **test_timeout_on_loop:** An infinite loop is interrupted within the configured timeout.
- **test_timeout_on_blocking_host_call:** A script blocked on a host function call is interrupted within the timeout.
- **test_timeout_error_structure:** The timeout error includes the elapsed time and timeout value.

---

## 16. Variable Read/Write (LUA-11)

### 16.1 Variable Read and Write Operations

Two host functions provide transactional access to instance variables:

**`platform.read_variable(key: string) -> any`**

Returns the current value of the instance variable, or `nil` if not set. The read is immediate; no state staging.

```zig
fn platformReadVariable(L: *c.lua_State) callconv(.C) c_int {
    const context = getExecutionContextFromLua(L);
    
    // Check capability
    if (!context.capabilities.has(StandardCapabilities.VARIABLE_READ)) {
        return luaError(L, "Capability denied: {s}", .{StandardCapabilities.VARIABLE_READ});
    }
    
    // Get the variable key from Lua
    const key = c.lua_tostring(L, 1) orelse return luaError(L, "Variable key must be a string");
    
    // Read from instance state
    const value = context.instance_state.variables.get(key) orelse {
        c.lua_pushnil(L);
        return 1;
    };
    
    // Convert Zig value to Lua value
    try pushLuaValue(L, value);
    return 1;
}
```

**`platform.write_variable(key: string, value: any) -> nil`**

Stages a write to the instance variable. The write is NOT immediately applied; it is buffered until the script completes successfully.

```zig
fn platformWriteVariable(L: *c.lua_State) callconv(.C) c_int {
    const context = getExecutionContextFromLua(L);
    
    // Check capability
    if (!context.capabilities.has(StandardCapabilities.VARIABLE_WRITE)) {
        return luaError(L, "Capability denied: {s}", .{StandardCapabilities.VARIABLE_WRITE});
    }
    
    // Get the key and value
    const key = c.lua_tostring(L, 1) orelse return luaError(L, "Variable key must be a string");
    const value = try popLuaValue(L, 2);
    
    // Stage the write to a pending buffer
    try context.pending_writes.put(key, value);
    
    // Return nil
    c.lua_pushnil(L);
    return 1;
}
```

### 16.2 Atomic Write Semantics

Writes are applied atomically on script success, discarded on script failure:

```zig
pub fn executeScript(
    context: *ExecutionContext,
    script_source: []const u8,
) !ScriptResult {
    // ... (script execution setup)
    
    var pending_writes = std.StringHashMap(ScriptValue).init(context.allocator);
    defer pending_writes.deinit();
    
    context.pending_writes = &pending_writes;
    
    // Execute the script
    const result = try loadAndRun(L, script_source);
    
    // On success, apply writes
    if (result.success) {
        var iter = pending_writes.iterator();
        while (iter.next()) |entry| {
            try context.instance_state.variables.put(entry.key_ptr.*, entry.value_ptr.*);
        }
    } else {
        // On failure, discard writes
        pending_writes.clear();
    }
    
    return result;
}
```

### 16.3 Error Handling

```zig
pub const VariableError = error {
    ReadFailed,
    WriteFailed,
    VariableKeyTooLong,
    VariableValueTooLarge,
};
```

### 16.4 Test Strategy

- **test_read_variable:** Scripts can read instance variables.
- **test_write_variable:** Scripts can stage writes to variables.
- **test_write_on_success:** Variable writes are applied after successful script execution.
- **test_write_on_failure:** Variable writes are discarded after failed script execution.
- **test_write_ordering:** Multiple writes to the same key result in the final write value.
- **test_read_after_write:** A script can read a variable, write it, and read the modified value.

---

## 17. Service Call (LUA-12)

### 17.1 Service Invocation

`platform.call_service(service_id, method, path, headers, body)` invokes a registered service synchronously and returns the response.

```zig
fn platformCallService(L: *c.lua_State) callconv(.C) c_int {
    const context = getExecutionContextFromLua(L);
    
    // Check capability
    const service_id = c.lua_tostring(L, 1) orelse return luaError(L, "service_id must be a string");
    const capability = try std.fmt.allocPrint(
        context.allocator,
        "{s}{s}",
        .{ StandardCapabilities.SERVICE_CALL_PREFIX, service_id }
    );
    defer context.allocator.free(capability);
    
    if (!context.capabilities.has(capability)) {
        return luaError(L, "Capability denied: {s}", .{capability});
    }
    
    // Extract arguments
    const method = c.lua_tostring(L, 2) orelse return luaError(L, "method must be a string");
    const path = c.lua_tostring(L, 3) orelse return luaError(L, "path must be a string");
    const headers = try popLuaValue(L, 4);  // Lua table
    const body = c.lua_tostring(L, 5) orelse "";
    
    // Look up service in the catalog
    const service = context.service_catalog.lookup(service_id) orelse {
        return luaError(L, "Service not found: {s}", .{service_id});
    };
    
    // Make the HTTP call
    var http_response = try makeHttpCall(
        service.endpoint,
        method,
        path,
        headers,
        body,
        context.timeout_ms,
        context.allocator,
    ) catch |err| {
        return luaError(L, "Service call failed: {s}", .{@errorName(err)});
    };
    defer http_response.deinit();
    
    // Convert response to Lua table
    try pushLuaTable(L, &http_response);
    
    return 1;  // Return response table
}

pub const ServiceCallResponse = struct {
    status_code: u16,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
};
```

### 17.2 Service Catalog Integration

Services are registered in the catalog with endpoint, auth, and schema details:

```zig
pub const RegisteredService = struct {
    service_id: []const u8,
    endpoint_url: []const u8,
    request_schema: ?[]const u8,  // JSON schema or null
    response_schema: ?[]const u8,
    auth_method: AuthMethod,  // NONE, BEARER, API_KEY, OAUTH2
};

pub const ServiceCatalog = struct {
    services: std.StringHashMap(RegisteredService),
    allocator: std.mem.Allocator,
    
    pub fn lookup(self: *const ServiceCatalog, service_id: []const u8) ?*const RegisteredService {
        return self.services.getPtr(service_id);
    }
};
```

### 17.3 Error Handling

Service call failures return structured errors, not Lua errors:

```zig
pub const ServiceCallError = struct {
    service_id: []const u8,
    reason: []const u8,
    http_status: ?u16,
    response_body: ?[]const u8,
};

// Service calls catch errors and return them as Lua values (not raise)
```

### 17.4 Test Strategy

- **test_call_service_success:** A successful service call returns the response as a Lua table.
- **test_call_service_not_found:** Calling a non-existent service returns a structured error.
- **test_call_service_capability_denied:** Calling without the required capability denies access.
- **test_call_service_http_error:** HTTP errors are returned as structured error responses.
- **test_call_service_response_schema_validation:** (Optional) Response is validated against schema if provided.

---

## 18. Logging (LUA-13)

### 18.1 Structured Logging

`platform.log(level, message, context_table)` emits a structured log entry tagged with script identity, instance ID, and correlation IDs.

```zig
fn platformLog(L: *c.lua_State) callconv(.C) c_int {
    const context = getExecutionContextFromLua(L);
    
    // Check capability
    if (!context.capabilities.has(StandardCapabilities.AUDIT_LOG)) {
        return luaError(L, "Capability denied: {s}", .{StandardCapabilities.AUDIT_LOG});
    }
    
    // Extract arguments
    const level = c.lua_tostring(L, 1) orelse return luaError(L, "level must be a string");
    const message = c.lua_tostring(L, 2) orelse return luaError(L, "message must be a string");
    const context_table = try popLuaValue(L, 3);  // Optional; defaults to empty
    
    // Validate log level
    const log_level = std.meta.stringToEnum(LogLevel, level) orelse {
        return luaError(L, "Invalid log level: {s}", .{level});
    };
    
    // Construct a structured log entry
    const log_entry = StructuredLogEntry{
        .timestamp = try context.time_source.now(),
        .level = log_level,
        .message = message,
        .script_id = context.script_id,
        .instance_id = context.instance_id,
        .actor_id = context.actor_id,
        .trace_id = context.trace_id,
        .context = context_table,
    };
    
    // Write to structured log
    try context.structured_logger.log(log_entry);
    
    // Return nil
    c.lua_pushnil(L);
    return 1;
}

pub const StructuredLogEntry = struct {
    timestamp: DateTime,
    level: LogLevel,
    message: []const u8,
    script_id: []const u8,
    instance_id: []const u8,
    actor_id: []const u8,
    trace_id: []const u8,
    context: ?ScriptValue,  // Additional context from the script
};

pub const LogLevel = enum {
    DEBUG,
    INFO,
    WARN,
    ERROR,
};
```

### 18.2 Correlation IDs

Log entries automatically include:
- **trace_id:** Propagated from the API request boundary (API-09)
- **instance_id:** The workflow instance UUID
- **actor_id:** The user or service that initiated the action
- **script_id:** The script's registered identifier

### 18.3 Test Strategy

- **test_log_info:** A script logs at INFO level and the entry appears in structured output.
- **test_log_with_context:** Log entries include context fields passed by the script.
- **test_log_correlation_ids:** Log entries include correct trace_id, instance_id, and actor_id.
- **test_log_capability_denied:** Logging without the audit:log capability is denied.

---

## 19. Time Source (LUA-14)

### 19.1 Platform Time Function

`platform.now()` returns the platform's authoritative time as an ISO 8601 UTC string. This is the ONLY time function available; `os.time()` is NOT available.

```zig
fn platformNow(L: *c.lua_State) callconv(.C) c_int {
    const context = getExecutionContextFromLua(L);
    
    // Get current time from platform time source
    const now = try context.time_source.now();
    
    // Convert to ISO 8601 UTC string
    const iso_string = try now.formatISO8601(context.allocator);
    defer context.allocator.free(iso_string);
    
    // Push to Lua
    c.lua_pushstring(L, iso_string.ptr);
    return 1;  // Return the time string
}

pub const TimeSource = struct {
    pub fn now(self: *const TimeSource) !DateTime {
        const now_ns = std.time.nanoTimestamp();
        return DateTime.fromNanoseconds(now_ns);
    }
};

pub const DateTime = struct {
    // ISO 8601 representation: "2026-05-28T14:30:45.123Z"
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    millisecond: u16,
    
    pub fn formatISO8601(self: *const DateTime, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(
            allocator,
            "{:04d}-{:02d}-{:02d}T{:02d}:{:02d}:{:02d}.{:03d}Z",
            .{
                self.year, self.month, self.day,
                self.hour, self.minute, self.second,
                self.millisecond,
            }
        );
    }
};
```

### 19.2 Removal of `os.time` and Related Functions

When loading the standard library (§4), explicitly ensure `os.time`, `os.date`, and similar time functions are NOT available:

```zig
// In loadRestrictedStdlibs:
// Do NOT load the os module, which includes os.time
// If any backdoor access to time exists, remove it
try removeLuaGlobal(L, "os.time");
try removeLuaGlobal(L, "os.date");
try removeLuaGlobal(L, "os.clock");
```

### 19.3 Test Strategy

- **test_platform_now:** `platform.now()` returns a valid ISO 8601 string in UTC.
- **test_platform_now_format:** Returned time is correctly formatted (YYYY-MM-DDTHH:MM:SS.sssZ).
- **test_os_time_not_available:** `os.time` is `nil` in the script sandbox.
- **test_time_determinism:** Multiple calls to `platform.now()` within a single script increment consistently.

---

## 20. Structured Failure (LUA-15)

### 20.1 Explicit Failure Function

`platform.fail(reason, details)` terminates the script immediately with a structured failure that is propagated to the engine.

```zig
fn platformFail(L: *c.lua_State) callconv(.C) c_int {
    const context = getExecutionContextFromLua(L);
    
    // Extract reason and details
    const reason = c.lua_tostring(L, 1) orelse return luaError(L, "reason must be a string");
    const details = try popLuaValue(L, 2);  // Optional; defaults to null
    
    // Create a structured failure
    const failure = ScriptFailure{
        .reason = reason,
        .details = details,
        .trace_id = context.trace_id,
        .instance_id = context.instance_id,
    };
    
    // Set the failure as an error that will be returned to the engine
    context.explicit_failure = failure;
    
    // Raise a Lua error to terminate execution
    return c.lua_error(L);
}

pub const ScriptFailure = struct {
    reason: []const u8,
    details: ?ScriptValue,
    trace_id: []const u8,
    instance_id: []const u8,
};
```

### 20.2 Engine Integration

When `platform.fail` is called, the engine:

1. Captures the failure reason and details
2. Emits a `SCRIPT_FAILED` event with the failure information
3. Transitions the instance per the SERVICE_TASK's error policy (see EE-10)

```zig
pub fn executeScript(
    context: *ExecutionContext,
    script_source: []const u8,
) !ScriptResult {
    // ... (setup)
    
    const status = c.lua_pcall(L, 0, 1, 0);
    
    if (status != 0) {
        // Lua error occurred
        
        // Check if it was an explicit failure
        if (context.explicit_failure) |failure| {
            // Emit SCRIPT_FAILED event
            try context.event_store.append(Event{
                .type = .SCRIPT_FAILED,
                .instance_id = context.instance_id,
                .payload = ScriptFailedPayload{
                    .reason = failure.reason,
                    .details = failure.details,
                },
                .timestamp = try context.time_source.now(),
                .trace_id = context.trace_id,
            });
            
            return ScriptResult{
                .success = false,
                .error_type = .ExplicitFailure,
                .error_message = failure.reason,
            };
        } else {
            // Runtime error (see LUA-16)
            // ...
        }
    }
    
    return result;
}
```

### 20.3 Test Strategy

- **test_explicit_failure:** Calling `platform.fail("custom reason")` terminates execution with that reason.
- **test_explicit_failure_with_details:** `platform.fail` accepts optional details and includes them in the event.
- **test_script_failed_event:** A `SCRIPT_FAILED` event is emitted when a script calls `platform.fail`.
- **test_error_policy_routing:** The instance is routed per the SERVICE_TASK's error policy on script failure.

---

## 21. Runtime Error Capture (LUA-16)

### 21.1 Uncaught Error Handling

Uncaught Lua errors (e.g., division by zero, nil value access) are captured by the host and converted to structured `SCRIPT_ERROR` events.

```zig
pub fn executeScript(
    context: *ExecutionContext,
    script_source: []const u8,
) !ScriptResult {
    // ... (setup and execution)
    
    const status = c.lua_pcall(L, 0, 1, 0);
    
    if (status != 0) {
        // Lua error occurred
        
        if (!context.explicit_failure.present) {
            // Uncaught runtime error
            const error_message = c.lua_tostring(L, -1) orelse "unknown error";
            const stack_trace = try captureStackTrace(L, context.allocator);
            
            const instruction_count = getInstructionCount(L);
            
            // Emit SCRIPT_ERROR event
            try context.event_store.append(Event{
                .type = .SCRIPT_ERROR,
                .instance_id = context.instance_id,
                .payload = ScriptErrorPayload{
                    .error_message = error_message,
                    .stack_trace = stack_trace,
                    .instruction_count = instruction_count,
                    .capabilities_at_failure = context.capabilities.summary(),
                },
                .timestamp = try context.time_source.now(),
                .trace_id = context.trace_id,
            });
            
            return ScriptResult{
                .success = false,
                .error_type = .RuntimeError,
                .error_message = error_message,
            };
        }
    }
    
    return result;
}
```

### 21.2 Stack Trace Capture

The Lua debug API is used to extract a stack trace:

```zig
fn captureStackTrace(L: *c.lua_State, allocator: std.mem.Allocator) ![]const u8 {
    var trace = std.ArrayList(u8).init(allocator);
    defer trace.deinit();
    
    var level: c_int = 0;
    var debug_info: c.lua_Debug = undefined;
    
    while (c.lua_getstack(L, level, &debug_info) != 0) {
        _ = c.lua_getinfo(L, "Sl", &debug_info);
        
        const source = std.mem.sliceTo(debug_info.source, 0);
        const line = debug_info.currentline;
        
        try trace.writer().print("  at {s}:{d}\n", .{ source, line });
        
        level += 1;
    }
    
    return trace.toOwnedSlice();
}
```

### 21.3 Error Event Payload

The `SCRIPT_ERROR` event includes comprehensive diagnostic information:

```zig
pub const ScriptErrorPayload = struct {
    error_message: []const u8,
    stack_trace: []const u8,
    instruction_count: u64,
    memory_peak_bytes: u64,
    capabilities_at_failure: []const u8,
};

pub const Event = struct {
    .type: EventType,
    .instance_id: []const u8,
    .payload: union(EventType) {
        SCRIPT_ERROR: ScriptErrorPayload,
        SCRIPT_FAILED: ScriptFailedPayload,
        // ... (other event types)
    },
    .timestamp: DateTime,
    .trace_id: []const u8,
};

pub const EventType = enum {
    SCRIPT_ERROR,
    SCRIPT_FAILED,
    // ... (others from EE-10)
};
```

### 21.4 Test Strategy

- **test_runtime_error_captured:** Division by zero (e.g., `1/0`) is captured as a SCRIPT_ERROR event.
- **test_nil_access_error:** Accessing a field on `nil` is captured with the correct error message.
- **test_stack_trace_detail:** The captured stack trace includes function names, source file, and line numbers.
- **test_error_instruction_count:** The instruction count consumed before the error is recorded.
- **test_error_capability_state:** The error payload includes the script's capability set at the time of failure.
- **test_error_vs_explicit_failure:** Uncaught errors are distinguished from explicit `platform.fail` calls.

---

## 22. Open Questions for ORCH / Stakeholders

1. **Resource limits:** Should scripts have execution timeouts (e.g., 10 seconds max)? Should we limit memory? Or rely on the allocator bounds?
2. **Return value type strictness:** Should a script that returns a table be automatically serialized to JSON, or should the caller specify expected type?
3. **Asynchronous calls:** Can platform.call_service make HTTP calls that block the Lua execution, or should it be fire-and-forget?
4. **Logging verbosity:** Should platform.log entries be visible in standard logs, or only in audit logs?
5. **Script caching:** Should we cache compiled (but not executed) Lua bytecode? (We can't persist bytecode, but we could cache in-memory during a single request batch.)

---

## 24. Key Invariants

1. **No state leakage:** Every execution gets a fresh `lua_State` and a clean slate.
2. **No code injection:** Bytecode is rejected; dynamic code loading functions are removed.
3. **No I/O escape:** All I/O-related stdlib modules are not loaded.
4. **Capability enforcement:** Every host function call is guarded by capability check (LUA-06, LUA-07).
5. **Resource limits enforced:** Instruction count, memory, and wall clock timeout are strictly enforced (LUA-08, LUA-09, LUA-10).
6. **Transactional writes:** Variable writes are staged until success, discarded on failure (LUA-11).
7. **Type safety:** Return values are explicitly converted to Zig types with validation.
8. **Determinism (where applicable):** The same script + same instance state + same capabilities always produces the same result (modulo time source, which is deterministic within a request).
9. **Time source authority:** `platform.now()` is the ONLY time source; `os.time` is not available (LUA-14).
10. **Error capture:** All script failures (explicit or runtime) produce structured events with diagnostic information (LUA-15, LUA-16).

---

## 25. Implementation Roadmap

**Phase 1 (MVP) — Core Isolation and Security:**
- Lua state management (create, configure, destroy) (LUA-01, LUA-02)
- Stdlib restrictions (load math, string, table; remove dangerous functions; block io, os, package, debug) (LUA-03, LUA-04)
- Bytecode detection and rejection (LUA-04)
- Host API registration and capability framework (LUA-05, LUA-06)
- Capability manifest validation (LUA-07)
- Basic variable access: `platform.read_variable`, `platform.write_variable` (LUA-11)

**Phase 2 (Enhanced) — Resource Limits and Extended API:**
- Instruction limit enforcement (LUA-08)
- Memory limit enforcement (LUA-09)
- Wall clock timeout enforcement (LUA-10)
- Full host API: `platform.call_service`, `platform.log`, `platform.now`, `platform.fail` (LUA-12, LUA-13, LUA-14, LUA-15)
- Integration with instance state reconstruction and event store
- Error capture and structured `SCRIPT_ERROR` events (LUA-16)
- Comprehensive error context in capability denial messages

**Phase 3 (Optimization and Integration):**
- Compiled bytecode caching (in-memory only; never persisted)
- Performance profiling and optimization of host API calls
- Extended capabilities model (role-based, time-limited grants)
- Integration with service catalog and mock services (for simulation, see SIM-02)
- Cross-module compatibility tests (Lua vs. Wasm host API parity, see WASM-12)
