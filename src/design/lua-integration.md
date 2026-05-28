# Module: Lua Script Execution (LuaJIT Integration)

**Stage:** 8 — Lua Script Execution  
**Requirements:** LUA-01, LUA-02, LUA-03, LUA-04, LUA-05, LUA-06

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
| `platform.call_service(svc_id, method, path, headers, body)` | `(string, string, string, table, string) -> (string, number)` | `service:call:<svc_id>` | HTTP call to registered service |
| `platform.read_variable(key)` | `(string) -> any` | `variable:read` | Read instance variable |
| `platform.write_variable(key, value)` | `(string, any) -> nil` | `variable:write` | Write instance variable |
| `platform.log(level, message)` | `(string, string) -> nil` | `audit:log` | Structured log entry |
| `platform.emit_event(event_type, payload)` | `(string, table) -> nil` | `event:emit` | Append event to event log |
| `platform.get_instance_state()` | `() -> table` | `instance:read` | Read full instance state (read-only) |

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

## 9. Public Interface

### 9.1 Core Executor

```zig
// src/lua/executor.zig

pub const ExecutionContext = struct {
    capabilities: CapabilitySet,
    instance_id: []const u8,
    actor_id: []const u8,
    db_conn: *DatabaseConnection,
    instance_state: InstanceState,  // Immutable; can be read but not written via platform.get_instance_state()
    allocator: std.mem.Allocator,
};

pub fn executeScript(
    context: *ExecutionContext,
    script_source: []const u8,
) !ScriptResult;
```

### 9.2 Capability Grant Structure

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

### 9.3 Host API Modules

Each host API function lives in its own module under `src/lua/host_api/`:

```
src/lua/
├── executor.zig              # Main executor
├── capabilities.zig          # Capability model
├── luajit_bindings.zig       # C FFI declarations only
├── stdlib.zig                # Stdlib loading with restrictions
├── errors.zig                # Error types and mapping
└── host_api/
    ├── call_service.zig      # platform.call_service
    ├── read_variable.zig     # platform.read_variable
    ├── write_variable.zig    # platform.write_variable
    ├── log.zig               # platform.log
    ├── emit_event.zig        # platform.emit_event
    └── get_instance_state.zig # platform.get_instance_state
```

---

## 10. External Dependencies

| Dependency | Module | Purpose |
|---|---|---|
| LuaJIT | `luajit_bindings.zig` (C FFI) | Embedded script runtime |
| `src/engine/state.zig` | `executor.zig` | InstanceState type for context |
| `src/event_store/store.zig` | `host_api/emit_event.zig` | Event appending |
| `src/tasks/manager.zig` | `host_api/read_variable.zig` | Variable access |
| `src/identity/tokens.zig` | `executor.zig` (capability lookup) | Capability validation |
| `src/api/errors.zig` | `errors.zig` | Error response mapping |

---

## 11. Testing Strategy

### 11.1 Unit Tests (No DB)

- `test_lua_isolation`: Fresh state for each invocation; no global leakage
- `test_stdlib_whitelist`: math, string, table available; io, os, package, debug blocked
- `test_stdlib_removals`: string.dump, load, loadstring, loadfile, dofile all raise errors
- `test_bytecode_rejection`: Scripts starting with bytecode magic are rejected
- `test_capability_checks`: Host API denies calls without matching capabilities
- `test_simple_script`: Execute a basic arithmetic script and verify result

### 11.2 Integration Tests (With DB)

- `test_call_service_capability`: platform.call_service enforces `service:call:*` grants
- `test_read_write_variable`: Scripts can read/write instance variables
- `test_emit_event`: Scripts can emit events with proper capability checks
- `test_script_isolation`: Two sequential scripts don't see each other's globals

### 11.3 Security Tests

- Attempt `io.open()` (should fail)
- Attempt `os.execute()` (should fail)
- Attempt `require()` (should fail)
- Attempt to load bytecode (should fail)
- Attempt `string.dump()` (should fail)

---

## 12. Open Questions for ORCH / Stakeholders

1. **Resource limits:** Should scripts have execution timeouts (e.g., 10 seconds max)? Should we limit memory? Or rely on the allocator bounds?
2. **Return value type strictness:** Should a script that returns a table be automatically serialized to JSON, or should the caller specify expected type?
3. **Asynchronous calls:** Can platform.call_service make HTTP calls that block the Lua execution, or should it be fire-and-forget?
4. **Logging verbosity:** Should platform.log entries be visible in standard logs, or only in audit logs?
5. **Script caching:** Should we cache compiled (but not executed) Lua bytecode? (We can't persist bytecode, but we could cache in-memory during a single request batch.)

---

## 13. Key Invariants

1. **No state leakage:** Every execution gets a fresh `lua_State` and a clean slate.
2. **No code injection:** Bytecode is rejected; dynamic code loading functions are removed.
3. **No I/O escape:** All I/O-related stdlib modules are not loaded.
4. **Capability enforcement:** Every host function call is guarded by capability check.
5. **Type safety:** Return values are explicitly converted to Zig types with validation.
6. **Determinism (where applicable):** The same script + same instance state + same capabilities always produces the same result.

---

## 14. Implementation Roadmap

**Phase 1 (MVP):**
- Lua state management (create, configure, destroy)
- Stdlib restrictions (load math, string, table; remove dangerous functions; block io, os, package, debug)
- Bytecode detection and rejection
- Basic host API: `platform.read_variable`, `platform.write_variable`
- Capability framework and checks

**Phase 2 (Enhanced):**
- Full host API: `call_service`, `emit_event`, `log`, `get_instance_state`
- Integration with instance state reconstruction
- Resource limits and timeout enforcement
- Comprehensive error context in capability denial messages

**Phase 3 (Optimization):**
- Compiled bytecode caching (in-memory only; never persisted)
- Performance profiling and optimization of host API calls
- Extended capabilities model (role-based, time-limited grants)
