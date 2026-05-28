# Module: Wasm Module Execution (Wasmtime Integration)

**Stage:** 9 — Wasm Module Execution  
**Requirements:** WASM-01 through WASM-14  
**Tier:** 3 (Tier 1: DSL/CEL, Tier 2: Lua, Tier 3: Wasm, Tier 4: LLM)

---

## 1. Overview

The Wasm execution subsystem embeds Wasmtime to execute compiled WebAssembly modules with strict capability sandboxing, resource limits, and host API parity with Lua. This is Tier 3 of the three-tier execution model, used for complex custom node types and high-performance integrations that exceed Lua's performance envelope.

**Core design principles:**
1. **Sandboxing first:** Modules execute in isolated linear memory with no uncontrolled imports
2. **Capability enforcement:** Every imported function is validated against a whitelist derived from the module's declared capabilities
3. **Resource limits:** Fuel-based instruction counting, memory caps, and wall-clock timeouts prevent runaway execution
4. **Host API parity:** Modules invoke the same logical functions as Lua (`read_variable`, `write_variable`, `call_service`, etc.), with identical semantics
5. **Version safety:** Hot-reload with in-flight invocation isolation ensures zero downtime on module updates

---

## 2. Wasmtime Integration (WASM-01)

### 2.1 Static Linking Architecture

The Zig binary embeds Wasmtime statically via C FFI. No runtime dependency on a shared Wasmtime library.

**Integration approach:**

```zig
// src/wasm/wasmtime_bindings.zig — FFI declarations only

const c = @cImport({
    @cInclude("wasmtime.h");
    @cInclude("wasm.h");
});

pub const Engine = c.wasm_engine_t;
pub const Store = c.wasmtime_store_t;
pub const Instance = c.wasmtime_instance_t;
pub const Module = c.wasmtime_module_t;
pub const Func = c.wasmtime_func_t;
pub const Val = c.wasmtime_val_t;
pub const Trap = c.wasmtime_trap_t;

// Lifecycle functions
pub extern fn wasm_engine_new() ?*Engine;
pub extern fn wasm_engine_delete(engine: ?*Engine) void;
pub extern fn wasmtime_store_new(engine: ?*Engine, data: ?*c_void, finalizer: ?*const fn (?*c_void) callconv(.C) void) ?*Store;
pub extern fn wasmtime_store_delete(store: ?*Store) void;

// Module loading
pub extern fn wasmtime_module_new(engine: ?*Engine, wasm_bytes: [*:0]const u8, byte_count: usize, module_out: *?*Module) c_int;
pub extern fn wasmtime_module_delete(module: ?*Module) void;

// Instance creation
pub extern fn wasmtime_instance_new(
    store: ?*Store,
    module: ?*Module,
    imports: [*c]const c.wasmtime_extern_t,
    import_count: usize,
    instance_out: *c.wasmtime_instance_t,
    trap_out: ?*?*Trap,
) c_int;
pub extern fn wasmtime_instance_delete(instance: *c.wasmtime_instance_t) void;

// Function invocation
pub extern fn wasmtime_func_call(
    store: ?*Store,
    func: *const c.wasmtime_func_t,
    args: [*c]const c.wasmtime_val_t,
    arg_count: usize,
    results: [*c]c.wasmtime_val_t,
    result_count: usize,
    trap_out: ?*?*Trap,
) c_int;

// Export lookup
pub extern fn wasmtime_instance_export_get(
    store: ?*Store,
    instance: *const c.wasmtime_instance_t,
    name: [*:0]const u8,
    name_len: usize,
    item: *c.wasmtime_extern_t,
) bool;

// Fuel mechanism
pub extern fn wasmtime_store_set_fuel(store: ?*Store, fuel: u64) c_int;
pub extern fn wasmtime_store_get_fuel(store: ?*Store, fuel_out: *u64) c_int;

// Memory access
pub extern fn wasmtime_memory_data(store: ?*Store, memory: *const c.wasmtime_memory_t) ?[*]u8;
pub extern fn wasmtime_memory_data_size(store: ?*Store, memory: *const c.wasmtime_memory_t) usize;
pub extern fn wasmtime_memory_grow(store: ?*Store, memory: *c.wasmtime_memory_t, delta: u64, prev_size_out: *u64) c_int;
```

**Build integration (`build.zig`):**

- Detect or download Wasmtime source (C API, version pinned)
- Compile Wasmtime to `.a` (static archive)
- Link Wasmtime archive into the final `bpm` binary
- Verify with `ldd` (or Windows equivalent) that the binary has no `.so` Wasmtime dependency

**Acceptance criterion:** `ldd ./zig-cache/bin/bpm | grep -i wasm` returns no output (no dynamic Wasmtime dependency).

### 2.2 Engine and Store Management

A global (or per-execution-context) Wasmtime `Engine` is created once at platform startup:

```zig
// src/wasm/engine.zig

pub const WasmEngine = struct {
    engine: ?*c.wasm_engine_t,
    module_cache: std.StringHashMap(*c.wasmtime_module_t),  // Keyed by module content hash
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) !WasmEngine {
        const engine = c.wasm_engine_new() orelse return error.WasmEngineInitFailed;
        
        // Configure engine for security (fuel, etc.)
        // (Future: enable profiling hooks, timeout callbacks, etc.)
        
        return WasmEngine{
            .engine = engine,
            .module_cache = std.StringHashMap(*c.wasmtime_module_t).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *WasmEngine) void {
        var iter = self.module_cache.iterator();
        while (iter.next()) |entry| {
            c.wasmtime_module_delete(entry.value_ptr.*);
        }
        self.module_cache.deinit();
        c.wasm_engine_delete(self.engine);
    }
    
    pub fn getOrLoadModule(
        self: *WasmEngine,
        module_content: []const u8,
        module_hash: [32]u8,  // SHA-256
    ) !*c.wasmtime_module_t {
        const hash_str = try std.fmt.allocPrint(self.allocator, "{x}", .{std.fmt.fmtSliceHexLower(&module_hash)});
        defer self.allocator.free(hash_str);
        
        if (self.module_cache.get(hash_str)) |cached| {
            return cached;
        }
        
        var module: ?*c.wasmtime_module_t = null;
        const result = c.wasmtime_module_new(
            self.engine,
            module_content.ptr,
            module_content.len,
            &module,
        );
        
        if (result != 0) {
            return error.WasmModuleLoadFailed;
        }
        
        try self.module_cache.put(hash_str, module);
        return module;
    }
};
```

A fresh `Store` is created per invocation (or per-pooled instance), holding the Wasmtime execution context and linear memory:

```zig
pub const WasmStore = struct {
    store: ?*c.wasmtime_store_t,
    context: *ExecutionContext,
    fuel_limit: u64,
    memory_cap: u64,
    
    pub fn init(
        engine: *WasmEngine,
        context: *ExecutionContext,
        fuel_limit: u64,
        memory_cap: u64,
    ) !WasmStore {
        const store = c.wasmtime_store_new(engine.engine, context, null) 
            orelse return error.WasmStoreInitFailed;
        
        // Set fuel budget
        _ = c.wasmtime_store_set_fuel(store, fuel_limit);
        
        // Memory cap is enforced at growth time (see §3.3)
        
        return WasmStore{
            .store = store,
            .context = context,
            .fuel_limit = fuel_limit,
            .memory_cap = memory_cap,
        };
    }
    
    pub fn deinit(self: *WasmStore) void {
        c.wasmtime_store_delete(self.store);
    }
};
```

---

## 3. Module ABI Contract (WASM-02)

### 3.1 Required Exports

Every module MUST export these four functions with the following signatures:

| Export | Signature | Purpose |
|---|---|---|
| `init` | `() -> i32` | Initialize the module instance. Return 0 on success, non-zero on failure. |
| `execute` | `(payload_ptr: i32, payload_len: i32, response_buf: i32, response_buf_cap: i32) -> i32` | Execute the main logic; return response length written to buffer |
| `deinit` | `() -> i32` | Clean up resources. Return 0 on success. |
| `get_capabilities` | `(buf: i32, buf_cap: i32) -> i32` | Write capability JSON to buffer; return bytes written |

**Capability descriptor JSON format:**

```json
{
  "capabilities": ["variable:read", "variable:write", "service:call:payment_api"],
  "max_fuel": 1000000,
  "max_memory_pages": 256,
  "timeout_seconds": 30
}
```

### 3.2 ABI Validation at Registration

When a module is registered, the platform MUST validate all four exports:

```zig
// src/wasm/module_registry.zig

pub const ModuleValidationError = error{
    MissingInitExport,
    MissingExecuteExport,
    MissingDeinitExport,
    MissingGetCapabilitiesExport,
    InvalidInitSignature,
    InvalidExecuteSignature,
    InvalidDeinitSignature,
    InvalidGetCapabilitiesSignature,
    CapabilityParseError,
    UnauthorizedCapability,
};

pub fn validateModuleABI(
    engine: *WasmEngine,
    module_content: []const u8,
    declared_capabilities: CapabilitySet,
    allocator: std.mem.Allocator,
) !ModuleCapabilities {
    // Load module
    const module_hash = try computeSHA256(module_content);
    const module = try engine.getOrLoadModule(module_content, module_hash);
    
    // Create temporary store for validation
    const temp_context = ExecutionContext{
        // Minimal context for export lookup
        .instance_id = "validation",
        .actor_id = "system",
        // ... (other fields)
    };
    var store = try WasmStore.init(engine, &temp_context, 1000, 1024);
    defer store.deinit();
    
    // Lookup and validate exports
    // 1. init() -> i32
    var init_export: c.wasmtime_extern_t = undefined;
    if (!c.wasmtime_instance_export_get(store.store, instance, "init", 4, &init_export)) {
        return error.MissingInitExport;
    }
    if (init_export.kind != WASMTIME_EXTERN_FUNC) {
        return error.InvalidInitExport;
    }
    // Validate function signature: (void) -> i32
    // (Signature validation is complex; defer to Wasmtime's type system)
    
    // 2. execute(i32, i32, i32, i32) -> i32
    var execute_export: c.wasmtime_extern_t = undefined;
    if (!c.wasmtime_instance_export_get(store.store, instance, "execute", 7, &execute_export)) {
        return error.MissingExecuteExport;
    }
    
    // 3. deinit() -> i32
    var deinit_export: c.wasmtime_extern_t = undefined;
    if (!c.wasmtime_instance_export_get(store.store, instance, "deinit", 6, &deinit_export)) {
        return error.MissingDeinitExport;
    }
    
    // 4. get_capabilities(i32, i32) -> i32
    var get_caps_export: c.wasmtime_extern_t = undefined;
    if (!c.wasmtime_instance_export_get(store.store, instance, "get_capabilities", 15, &get_caps_export)) {
        return error.MissingGetCapabilitiesExport;
    }
    
    // Call get_capabilities to retrieve declared capabilities
    const cap_json = try callGetCapabilities(store, &get_caps_export, allocator);
    defer allocator.free(cap_json);
    
    // Parse and validate against granted capabilities
    const module_caps = try parseCapabilityDescriptor(cap_json, declared_capabilities, allocator);
    
    return module_caps;
}

pub const ModuleCapabilities = struct {
    capabilities: []const []const u8,
    max_fuel: u64,
    max_memory_pages: u32,
    timeout_seconds: u32,
};
```

---

## 4. Compilation Pipeline (WASM-03, WASM-04, WASM-05)

### 4.1 Source Compilation Job

The compilation process takes Zig source for a Wasm module and produces a validated `.wasm` artifact. Compilation runs **out-of-band**, not on the request path.

```zig
// src/wasm/compiler.zig

pub const CompilationJob = struct {
    job_id: [36]u8,  // UUID
    run_id: []const u8,
    module_name: []const u8,
    source_code: []const u8,
    source_hash: [32]u8,
    toolchain_version: []const u8,
    status: enum{ PENDING, IN_PROGRESS, COMPLETED, FAILED },
    result: ?CompilationResult,
    error_message: ?[]const u8,
    created_at: DateTime,
    completed_at: ?DateTime,
    allocator: std.mem.Allocator,
};

pub const CompilationResult = struct {
    wasm_artifact: []const u8,  // Binary .wasm content
    artifact_hash: [32]u8,       // SHA-256 of compiled artifact
    abi_capabilities: ModuleCapabilities,
    warnings: []const []const u8,
};

pub fn submitCompilationJob(
    module_name: []const u8,
    source_code: []const u8,
    toolchain_version: []const u8,
    allocator: std.mem.Allocator,
) !CompilationJob {
    const job_id = try uuid.v4(allocator);
    const source_hash = try computeSHA256(source_code);
    
    var job = CompilationJob{
        .job_id = job_id,
        .run_id = run_id,  // Passed via context
        .module_name = module_name,
        .source_code = source_code,
        .source_hash = source_hash,
        .toolchain_version = toolchain_version,
        .status = .PENDING,
        .result = null,
        .error_message = null,
        .created_at = try time_source.now(),
        .completed_at = null,
        .allocator = allocator,
    };
    
    // Enqueue the job to a background worker pool
    try compilation_worker_pool.submit(job);
    
    return job;
}

fn compilationWorker() void {
    // Worker loop: dequeue jobs and compile
    while (true) {
        const job = compilation_worker_pool.dequeue() orelse {
            std.time.sleep(100 * std.time.ns_per_ms);  // Backoff
            continue;
        };
        
        // Compile: `zig build-lib -target wasm32-freestanding source.zig -O ReleaseSmall`
        const compile_result = compileZigToWasm(job.source_code, job.toolchain_version) 
            catch |err| {
                job.status = .FAILED;
                job.error_message = try std.fmt.allocPrint(job.allocator, "Compilation failed: {}", .{err});
                notifyCompilationCompleted(&job);
                continue;
            };
        
        // Validate ABI
        const abi_caps = validateModuleABI(compile_result.wasm_artifact) 
            catch |err| {
                job.status = .FAILED;
                job.error_message = try std.fmt.allocPrint(job.allocator, "ABI validation failed: {}", .{err});
                notifyCompilationCompleted(&job);
                continue;
            };
        
        const artifact_hash = try computeSHA256(compile_result.wasm_artifact);
        
        job.status = .COMPLETED;
        job.result = CompilationResult{
            .wasm_artifact = compile_result.wasm_artifact,
            .artifact_hash = artifact_hash,
            .abi_capabilities = abi_caps,
            .warnings = compile_result.warnings,
        };
        job.completed_at = try time_source.now();
        
        notifyCompilationCompleted(&job);
    }
}
```

**API endpoint for job submission:**

```
POST /wasm/compile
Content-Type: application/json

{
  "module_name": "payment_processor_v1",
  "source_code": "(Zig source text)",
  "toolchain_version": "0.11.0"
}

Response 202 Accepted:
{
  "job_id": "uuid",
  "status": "PENDING",
  "created_at": "2026-05-28T14:30:45.123Z"
}
```

**Job completion notification:**

```
GET /wasm/compile/{job_id}

Response 200 when COMPLETED:
{
  "status": "COMPLETED",
  "artifact_hash": "sha256:deadbeef...",
  "capabilities": [...],
  "warnings": [...]
}
```

### 4.2 Compilation Caching (WASM-04)

Compiled artifacts are cached in the repository (Stage 10) keyed by source hash + toolchain version. Identical sources produce a cache hit:

```zig
pub fn getOrCompile(
    module_name: []const u8,
    source_code: []const u8,
    toolchain_version: []const u8,
    repository: *Repository,
    allocator: std.mem.Allocator,
) !CompilationResult {
    const source_hash = try computeSHA256(source_code);
    const cache_key = try std.fmt.allocPrint(
        allocator,
        "{s}/{x}/{s}",
        .{ module_name, std.fmt.fmtSliceHexLower(&source_hash), toolchain_version }
    );
    defer allocator.free(cache_key);
    
    // Check repository for cached artifact
    if (try repository.get(cache_key, allocator)) |cached_result| {
        return cached_result;
    }
    
    // Not cached; submit compilation job
    var job = try submitCompilationJob(module_name, source_code, toolchain_version, allocator);
    
    // Wait for completion (blocking on the compilation worker)
    while (job.status == .PENDING or job.status == .IN_PROGRESS) {
        std.time.sleep(100 * std.time.ns_per_ms);
        job = try compilation_worker_pool.getJob(job.job_id);
    }
    
    if (job.status == .FAILED) {
        return error.CompilationFailed;
    }
    
    const result = job.result.?;
    
    // Store in repository for future cache hits
    try repository.put(cache_key, result, allocator);
    
    return result;
}
```

### 4.3 Build Reproducibility (WASM-05)

To ensure reproducibility:

1. **Pin toolchain version:** Compilation uses a specific Zig version (e.g., "0.11.0"), not "latest"
2. **Deterministic optimization:** Use `-O ReleaseSmall` with deterministic flags
3. **Environment isolation:** Compile in a clean environment (no HOME, no global state)
4. **Byte-for-byte identity:** Same source + same toolchain = same `.wasm` bytes

```zig
fn compileZigToWasm(
    source_code: []const u8,
    toolchain_version: []const u8,
) !CompilationOutput {
    // Write source to temp file
    const temp_dir = try std.fs.getTmpDir();
    const source_file = try temp_dir.createFile("module.zig", .{});
    defer source_file.close();
    try source_file.writeAll(source_code);
    
    // Compile with deterministic flags
    const compile_cmd = [_][]const u8{
        "zig",
        "build-lib",
        "-target", "wasm32-freestanding",
        "-O", "ReleaseSmall",
        "-fstrip",  // Remove debug symbols for determinism
        "-fno-stage1",  // Disable incremental compilation
        source_file.name,
    };
    
    // Run in isolated environment
    var env = std.StringHashMap([]const u8).init(allocator);
    defer env.deinit();
    env.put("TERM", "dumb") catch {};
    env.put("LC_ALL", "C") catch {};
    env.put("TZ", "UTC") catch {};
    // Explicitly unset HOME and other paths
    
    const result = try std.ChildProcess.exec(.{
        .allocator = allocator,
        .argv = compile_cmd[0..],
        .cwd = temp_dir.name,
        .env_map = &env,
    });
    
    // Read compiled .wasm
    const wasm_file = try temp_dir.openFile("module.wasm", .{});
    defer wasm_file.close();
    const wasm_bytes = try wasm_file.readToEndAlloc(allocator, 10 * 1024 * 1024);  // 10 MB max
    
    return CompilationOutput{
        .wasm_artifact = wasm_bytes,
        .warnings = try parseWarnings(result.stderr),
    };
}
```

---

## 5. Capability Sandboxing (WASM-06, WASM-07)

### 5.1 Import Whitelist Enforcement

When instantiating a module, the host provides only those imported functions that correspond to the module's declared capabilities. All others are rejected:

```zig
// src/wasm/import_validator.zig

pub const ImportError = error{
    UnauthorizedImport,
    MissingImport,
    InvalidImportSignature,
};

pub fn validateAndBuildImports(
    module: *const WasmModule,
    capabilities: CapabilitySet,
    engine: *WasmEngine,
    allocator: std.mem.Allocator,
) ![]c.wasmtime_extern_t {
    // Scan module imports and build a whitelist based on capabilities
    var imports = std.ArrayList(c.wasmtime_extern_t).init(allocator);
    defer imports.deinit();
    
    // List of all possible host functions (platform.*)
    const all_host_funcs = [_]HostFuncDescriptor{
        .{ .name = "platform_read_variable", .capability = "variable:read", .sig = "ii->i" },
        .{ .name = "platform_write_variable", .capability = "variable:write", .sig = "iii->i" },
        .{ .name = "platform_call_service", .capability = "service:call:*", .sig = "iiii->i" },
        .{ .name = "platform_log", .capability = "audit:log", .sig = "iii->i" },
        .{ .name = "platform_now", .capability = "time:read", .sig = "->i" },
        .{ .name = "platform_fail", .capability = "control:fail", .sig = "ii->i" },
        .{ .name = "platform_uuid", .capability = "uuid:generate", .sig = "->i" },
        // ... (more functions)
    };
    
    for (all_host_funcs) |func_desc| {
        // Check if module imports this function
        if (moduleImports(module, func_desc.name)) {
            // Verify capability (handle wildcard matching for service:call:*)
            const has_capability = if (std.mem.endsWith(u8, func_desc.capability, ":*")) {
                // For service:call:*, check that at least one service:call:* capability exists
                var iter = capabilities.iterator();
                while (iter.next()) |cap| {
                    if (std.mem.startsWith(u8, cap, "service:call:")) {
                        break;
                    }
                }
            } else {
                capabilities.has(func_desc.capability)
            };
            
            if (!has_capability) {
                return error.UnauthorizedImport;
            }
            
            // Register the host function
            const host_func = try getHostFunction(func_desc.name, context, allocator);
            var extern_val: c.wasmtime_extern_t = undefined;
            extern_val.kind = WASMTIME_EXTERN_FUNC;
            extern_val.of.func = host_func;
            
            try imports.append(extern_val);
        }
    }
    
    return imports.toOwnedSlice();
}

pub const HostFuncDescriptor = struct {
    name: []const u8,
    capability: []const u8,  // Can end with :* for wildcard matching
    sig: []const u8,  // Signature shorthand for validation
};
```

### 5.2 No Filesystem Access (WASM-07)

Wasm modules are NOT granted `wasi:filesystem/*` capabilities by default. Attempting to import filesystem functions causes instantiation to fail:

```zig
pub fn validateNoFilesystemAccess(module: *const WasmModule) !void {
    const forbidden_imports = [_][]const u8{
        "wasi_snapshot_preview1:fd_open",
        "wasi_snapshot_preview1:fd_read",
        "wasi_snapshot_preview1:fd_write",
        "wasi_snapshot_preview1:path_open",
        // ... (other fs-related imports)
    };
    
    for (forbidden_imports) |forbidden| {
        if (moduleImports(module, forbidden)) {
            return error.FilesystemAccessNotAllowed;
        }
    }
}
```

---

## 6. Memory Isolation (WASM-08)

### 6.1 Pointer Validation

Modules execute in isolated linear memory. Before the host dereferences any pointer received from the module, it MUST validate the pointer and length:

```zig
// src/wasm/memory.zig

pub const MemoryError = error{
    PointerOutOfBounds,
    LengthOutOfBounds,
    NullPointer,
    UnalignedPointer,
};

pub fn validatePointer(
    store: *WasmStore,
    memory: *const c.wasmtime_memory_t,
    ptr: i32,
    len: u32,
) !void {
    if (ptr == 0) {
        return error.NullPointer;
    }
    
    const ptr_u = @intCast(u32, ptr);
    const memory_data = c.wasmtime_memory_data(store.store, memory) orelse return error.MemoryAccess;
    const memory_size = c.wasmtime_memory_data_size(store.store, memory);
    
    if (ptr_u + len > memory_size) {
        return error.PointerOutOfBounds;
    }
}

pub fn readStringFromMemory(
    store: *WasmStore,
    memory: *const c.wasmtime_memory_t,
    ptr: i32,
    len: u32,
    allocator: std.mem.Allocator,
) ![]const u8 {
    try validatePointer(store, memory, ptr, len);
    
    const ptr_u = @intCast(u32, ptr);
    const memory_data = c.wasmtime_memory_data(store.store, memory).?;
    const slice = memory_data[ptr_u..ptr_u + len];
    
    return try allocator.dupe(u8, slice);
}

pub fn writeStringToMemory(
    store: *WasmStore,
    memory: *const c.wasmtime_memory_t,
    ptr: i32,
    buf: []const u8,
) !void {
    try validatePointer(store, memory, ptr, @intCast(u32, buf.len));
    
    const ptr_u = @intCast(u32, ptr);
    const memory_data = c.wasmtime_memory_data(store.store, memory).?;
    std.mem.copy(u8, memory_data[ptr_u..ptr_u + buf.len], buf);
}
```

### 6.2 Memory Growth Handling

When a module requests memory growth, the host must validate that growth does not exceed the configured cap:

```zig
pub fn onMemoryGrow(
    store: *WasmStore,
    memory: *c.wasmtime_memory_t,
    delta_pages: u64,
) !void {
    const current_size = c.wasmtime_memory_data_size(store.store, memory);
    const new_size = current_size + (delta_pages * 65536);  // 1 page = 64 KB
    
    if (new_size > store.memory_cap) {
        return error.MemoryCapExceeded;
    }
    
    var prev_size: u64 = undefined;
    const result = c.wasmtime_memory_grow(store.store, memory, delta_pages, &prev_size);
    if (result != 0) {
        return error.MemoryGrowthFailed;
    }
}
```

---

## 7. Resource Limits (WASM-09, WASM-10, WASM-11)

### 7.1 Fuel-Based Execution Limit (WASM-09)

Wasmtime's fuel mechanism counts abstract "fuel" units (proportional to instruction count). Each invocation is given a fuel budget. Exhaustion causes the module to trap:

```zig
// src/wasm/fuel.zig

pub const FuelError = error{
    FuelExhausted,
    InvalidFuelBudget,
};

pub fn setFuelBudget(
    store: *WasmStore,
    fuel_limit: u64,
) !void {
    if (fuel_limit < 1000) {
        return error.InvalidFuelBudget;  // Minimum 1,000 fuel
    }
    
    const result = c.wasmtime_store_set_fuel(store.store, fuel_limit);
    if (result != 0) {
        return error.FuelExhausted;
    }
}

pub fn getFuelConsumed(store: *WasmStore) !u64 {
    var fuel_remaining: u64 = undefined;
    const result = c.wasmtime_store_get_fuel(store.store, &fuel_remaining);
    if (result != 0) {
        return error.FuelQueryFailed;
    }
    
    const fuel_limit = store.fuel_limit;
    return if (fuel_remaining < fuel_limit) fuel_limit - fuel_remaining else 0;
}

pub const FuelLimit = struct {
    max_fuel: u64,
    
    pub fn validate(self: FuelLimit) !void {
        if (self.max_fuel < 1000 or self.max_fuel > 100_000_000) {
            return error.FuelLimitOutOfRange;
        }
    }
};
```

### 7.2 Memory Cap (WASM-10)

Linear memory growth is capped at module instantiation. Modules cannot exceed the configured page limit:

```zig
// src/wasm/instance.zig

pub const InstanceConfig = struct {
    max_memory_pages: u32,  // Default 256 pages = 16 MB
    max_fuel: u64,           // Default 1,000,000
    timeout_seconds: u32,    // Default 30
};

pub fn instantiateModule(
    engine: *WasmEngine,
    module: *c.wasmtime_module_t,
    config: InstanceConfig,
    context: *ExecutionContext,
    allocator: std.mem.Allocator,
) !WasmInstance {
    var store = try WasmStore.init(engine, context, config.max_fuel, config.max_memory_pages * 65536);
    
    // Create imports (validator ensures no unallowed imports)
    const imports = try validateAndBuildImports(module, context.capabilities, engine, allocator);
    defer allocator.free(imports);
    
    // Instantiate with import validation
    var instance: c.wasmtime_instance_t = undefined;
    var trap: ?*c.wasmtime_trap_t = null;
    
    const result = c.wasmtime_instance_new(
        store.store,
        module,
        imports.ptr,
        imports.len,
        &instance,
        &trap,
    );
    
    if (result != 0 or trap != null) {
        return error.InstanceCreationFailed;
    }
    
    return WasmInstance{
        .instance = instance,
        .store = store,
        .module = module,
        .config = config,
    };
}

pub const WasmInstance = struct {
    instance: c.wasmtime_instance_t,
    store: WasmStore,
    module: *c.wasmtime_module_t,
    config: InstanceConfig,
    
    pub fn deinit(self: *WasmInstance) void {
        c.wasmtime_instance_delete(&self.instance);
        self.store.deinit();
    }
};
```

### 7.3 Wall Clock Timeout (WASM-11)

A per-invocation wall-clock timeout is enforced via a separate monitoring thread or timer callback, interrupting execution if the deadline is exceeded:

```zig
// src/wasm/timeout.zig

pub const TimeoutContext = struct {
    timeout_ms: u64,
    start_time: i64,  // nanoseconds
    timed_out: bool = false,
    
    pub fn init(timeout_seconds: u32) TimeoutContext {
        return TimeoutContext{
            .timeout_ms = @intCast(u64, timeout_seconds) * 1000,
            .start_time = std.time.nanoTimestamp(),
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

pub fn executeWithTimeout(
    instance: *WasmInstance,
    payload: []const u8,
    timeout_seconds: u32,
    allocator: std.mem.Allocator,
) !ExecutionResult {
    var timeout_ctx = TimeoutContext.init(timeout_seconds);
    
    // Call execute() with periodic timeout checks
    const result = callExecute(instance, payload, allocator) catch |err| {
        try timeout_ctx.checkTimeout();  // Re-check on error
        return err;
    };
    
    try timeout_ctx.checkTimeout();  // Final check before return
    
    return result;
}
```

---

## 8. Host API Parity (WASM-12)

### 8.1 Host Function Signatures

Each Lua function has an equivalent Wasm import with identical semantics. Differences are limited to ABI (pointer passing, string encoding):

| Function | Lua Signature | Wasm Signature | Capability |
|---|---|---|---|
| **read_variable** | `(key:string)->any` | `(key_ptr:i32, key_len:i32, out_ptr:i32) -> i32` (length) | `variable:read` |
| **write_variable** | `(key:string, val:any)->nil` | `(key_ptr:i32, key_len:i32, val_ptr:i32, val_len:i32)->i32` | `variable:write` |
| **call_service** | `(svc_id:string, method:string, path:string, headers:table, body:string)->table` | `(svc_id_ptr, svc_id_len, ..., out_ptr:i32)->i32` | `service:call:*` |
| **log** | `(level:string, msg:string, context:table)->nil` | `(level_ptr, level_len, msg_ptr, msg_len, ctx_ptr, ctx_len)->i32` | `audit:log` |
| **now** | `()->string` | `(out_ptr:i32)->i32` (length) | (none) |
| **fail** | `(reason:string, details:any)->never` | `(reason_ptr, reason_len, details_ptr, details_len)->i32` | (none) |
| **uuid** | `()->string` | `(out_ptr:i32)->i32` (length) | `uuid:generate` |

### 8.2 Implementation: Host Functions

Host functions receive pointers to the module's linear memory and must validate and dereference them:

```zig
// src/wasm/host_api/read_variable.zig

fn platform_read_variable(
    store: ?*c.wasmtime_store_t,
    args: [*c]const c.wasmtime_val_t,
    results: [*c]c.wasmtime_val_t,
) c_int {
    const context = getExecutionContextFromStore(store);
    
    // Check capability
    if (!context.capabilities.has("variable:read")) {
        return setError(results, "Capability denied: variable:read");
    }
    
    // Extract arguments
    const key_ptr = @intCast(i32, args[0].of.i32);
    const key_len = @intCast(u32, args[1].of.i32);
    const out_ptr = @intCast(i32, args[2].of.i32);
    
    // Validate pointers
    const memory = getModuleMemory(store);
    validatePointer(store, memory, key_ptr, key_len) catch {
        return setError(results, "Invalid key pointer");
    };
    
    // Read key from memory
    const key = readStringFromMemory(store, memory, key_ptr, key_len, context.allocator) catch {
        return setError(results, "Failed to read key from memory");
    };
    defer context.allocator.free(key);
    
    // Read variable from instance state
    const value = context.instance_state.variables.get(key) orelse {
        // Variable not set; return nil (empty response)
        results[0].of.i32 = 0;
        return 0;
    };
    
    // Convert Zig value to JSON (Wasm does not have rich types)
    const json_str = valueToJSON(value, context.allocator) catch {
        return setError(results, "Failed to serialize variable");
    };
    defer context.allocator.free(json_str);
    
    // Write to output buffer
    writeStringToMemory(store, memory, out_ptr, json_str) catch {
        return setError(results, "Output buffer too small");
    };
    
    results[0].of.i32 = @intCast(i32, json_str.len);
    return 0;
}

// src/wasm/host_api/write_variable.zig

fn platform_write_variable(
    store: ?*c.wasmtime_store_t,
    args: [*c]const c.wasmtime_val_t,
    results: [*c]c.wasmtime_val_t,
) c_int {
    const context = getExecutionContextFromStore(store);
    
    // Check capability
    if (!context.capabilities.has("variable:write")) {
        return setError(results, "Capability denied: variable:write");
    }
    
    // Extract arguments
    const key_ptr = @intCast(i32, args[0].of.i32);
    const key_len = @intCast(u32, args[1].of.i32);
    const val_ptr = @intCast(i32, args[2].of.i32);
    const val_len = @intCast(u32, args[3].of.i32);
    
    // Validate and read key
    const memory = getModuleMemory(store);
    const key = readStringFromMemory(store, memory, key_ptr, key_len, context.allocator) catch {
        return setError(results, "Failed to read key");
    };
    defer context.allocator.free(key);
    
    // Validate and read value (JSON)
    const val_json = readStringFromMemory(store, memory, val_ptr, val_len, context.allocator) catch {
        return setError(results, "Failed to read value");
    };
    defer context.allocator.free(val_json);
    
    // Parse JSON to Zig value
    const value = jsonToValue(val_json, context.allocator) catch {
        return setError(results, "Failed to parse value JSON");
    };
    
    // Stage the write (applied on success, discarded on failure)
    context.pending_writes.put(key, value) catch {
        return setError(results, "Failed to stage write");
    };
    
    results[0].of.i32 = 0;  // Success
    return 0;
}
```

---

## 9. Instance Pooling (WASM-13)

### 9.1 Pooling Strategy

Wasm instances are pooled per module to amortise the cost of instantiation (which is relatively expensive). Pooled instances are reset between invocations to ensure per-invocation isolation:

```zig
// src/wasm/pool.zig

pub const InstancePool = struct {
    module_id: []const u8,
    available: std.ArrayList(*WasmInstance),
    in_use: std.StringHashMap(*WasmInstance),  // Keyed by invocation ID
    config: InstanceConfig,
    max_instances: u32,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    
    pub fn init(
        module_id: []const u8,
        config: InstanceConfig,
        max_instances: u32,
        allocator: std.mem.Allocator,
    ) !InstancePool {
        return InstancePool{
            .module_id = module_id,
            .available = std.ArrayList(*WasmInstance).init(allocator),
            .in_use = std.StringHashMap(*WasmInstance).init(allocator),
            .config = config,
            .max_instances = max_instances,
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };
    }
    
    pub fn acquire(self: *InstancePool) !*WasmInstance {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        // Try to reuse a pooled instance
        if (self.available.popOrNull()) |instance| {
            // Reset instance for fresh invocation (see §9.2)
            try resetInstance(instance);
            return instance;
        }
        
        // If pool is not at capacity, create a new instance
        if (self.in_use.count() + self.available.items.len < self.max_instances) {
            const new_instance = try createInstance(self.module_id, self.config, self.allocator);
            return new_instance;
        }
        
        // Pool exhausted; wait or return error
        return error.InstancePoolExhausted;
    }
    
    pub fn release(self: *InstancePool, instance: *WasmInstance) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        try self.available.append(instance);
    }
    
    pub fn deinit(self: *InstancePool) void {
        for (self.available.items) |instance| {
            instance.deinit();
        }
        self.available.deinit();
        self.in_use.deinit();
    }
};

fn resetInstance(instance: *WasmInstance) !void {
    // Clear linear memory (zero all data except code)
    const memory = getModuleMemory(instance.store.store);
    const memory_data = c.wasmtime_memory_data(instance.store.store, memory).?;
    const memory_size = c.wasmtime_memory_data_size(instance.store.store, memory);
    
    // Zero the data region (keep code in place)
    const data_start = 65536;  // First 64 KB reserved for code/globals
    std.mem.set(u8, memory_data[data_start..memory_size], 0);
    
    // Reset fuel budget
    try setFuelBudget(instance.store, instance.config.max_fuel);
}
```

### 9.2 Per-Invocation Isolation

Despite pooling, each invocation sees a clean memory state. Memory is reset before use:

```zig
pub fn executePooled(
    pool: *InstancePool,
    payload: []const u8,
    invocation_id: []const u8,
    allocator: std.mem.Allocator,
) !ExecutionResult {
    const instance = try pool.acquire();
    defer pool.release(instance);
    
    // Call init() to set up fresh instance state
    var init_result: i32 = undefined;
    var init_arg: [0]c.wasmtime_val_t = undefined;
    var init_res: [1]c.wasmtime_val_t = undefined;
    
    const init_func = try getExport(instance, "init");
    const init_status = c.wasmtime_func_call(
        instance.store.store,
        &init_func,
        &init_arg,
        0,
        &init_res,
        1,
        null,
    );
    
    if (init_status != 0) {
        return error.InitFailed;
    }
    
    init_result = init_res[0].of.i32;
    if (init_result != 0) {
        return error.InitFailed;
    }
    
    // Execute the payload
    const result = try executeImpl(instance, payload, allocator);
    
    // Call deinit() to clean up (best-effort)
    _ = callDeinit(instance);
    
    return result;
}
```

---

## 10. Hot Reload (WASM-14)

### 10.1 Version Management

When a new version of a module is activated, in-flight invocations of the prior version complete normally. New invocations use the new version:

```zig
// src/wasm/versioning.zig

pub const ModuleVersion = struct {
    module_id: []const u8,
    version: u32,  // Monotonically increasing
    artifact_hash: [32]u8,
    activated_at: DateTime,
    is_active: bool,
};

pub const ModuleRegistry = struct {
    modules: std.StringHashMap(ModuleVersion),
    pools: std.StringHashMap(*InstancePool),  // Keyed by "module_id:version"
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    
    pub fn activate(
        self: *ModuleRegistry,
        module_id: []const u8,
        artifact: []const u8,
        config: InstanceConfig,
    ) !ModuleVersion {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const current = self.modules.get(module_id) orelse null;
        const new_version = if (current) |c| c.version + 1 else 1;
        
        const artifact_hash = try computeSHA256(artifact);
        
        // Mark old version as inactive
        if (current) |_| {
            var entry = self.modules.getPtr(module_id).?;
            entry.is_active = false;
        }
        
        // Activate new version
        const new_mod = ModuleVersion{
            .module_id = module_id,
            .version = new_version,
            .artifact_hash = artifact_hash,
            .activated_at = try time_source.now(),
            .is_active = true,
        };
        
        try self.modules.put(module_id, new_mod);
        
        // Create a fresh pool for the new version
        const pool_key = try std.fmt.allocPrint(self.allocator, "{s}:{}", .{ module_id, new_version });
        defer self.allocator.free(pool_key);
        
        const pool = try InstancePool.init(module_id, config, 10, self.allocator);
        try self.pools.put(pool_key, pool);
        
        return new_mod;
    }
    
    pub fn getActivePool(
        self: *const ModuleRegistry,
        module_id: []const u8,
    ) !*InstancePool {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        const version = self.modules.get(module_id) orelse return error.ModuleNotFound;
        
        const pool_key = try std.fmt.allocPrint(self.allocator, "{s}:{}", .{ module_id, version.version });
        defer self.allocator.free(pool_key);
        
        return self.pools.get(pool_key) orelse error.PoolNotFound;
    }
};
```

### 10.2 In-Flight Invocation Isolation

Invocations in progress when a new version is activated use the old pool and complete normally:

```zig
pub fn executeModule(
    registry: *ModuleRegistry,
    module_id: []const u8,
    payload: []const u8,
    invocation_id: []const u8,
    allocator: std.mem.Allocator,
) !ExecutionResult {
    // Acquire a reference to the active pool at the start of the invocation
    // (The pool is immutable for the duration of execution)
    const pool = try registry.getActivePool(module_id);
    
    // Execute using the acquired pool
    // (If a new version is activated mid-execution, this invocation continues with its original pool)
    const result = try executePooled(pool, payload, invocation_id, allocator);
    
    return result;
}
```

---

## 11. Error Handling

### 11.1 Trap Handling

Wasm execution can trap (e.g., out-of-bounds memory access, divide by zero, fuel exhaustion). Traps are converted to structured errors:

```zig
// src/wasm/errors.zig

pub const WasmError = error{
    InstanceCreationFailed,
    ExecutionTrap,
    MemoryAccessViolation,
    FuelExhausted,
    TimeoutExceeded,
    CapabilityDenied,
    PointerOutOfBounds,
    InvalidImport,
    ModuleLoadFailed,
};

pub const ExecutionError = struct {
    code: []const u8,
    message: []const u8,
    module_id: []const u8,
    invocation_id: []const u8,
    fuel_consumed: u64,
    wall_clock_elapsed_ms: u64,
};

fn handleTrap(trap: *c.wasmtime_trap_t, context: *ExecutionContext) ExecutionError {
    var trap_message: [256]u8 = undefined;
    const msg_size = c.wasmtime_trap_message(trap, &trap_message);
    
    var code: []const u8 = "EXECUTION_TRAP";
    
    if (std.mem.containsAtLeast(u8, trap_message[0..msg_size], 1, "out of bounds")) {
        code = "MEMORY_OUT_OF_BOUNDS";
    } else if (std.mem.containsAtLeast(u8, trap_message[0..msg_size], 1, "fuel exhausted")) {
        code = "FUEL_EXHAUSTED";
    } else if (std.mem.containsAtLeast(u8, trap_message[0..msg_size], 1, "divide by zero")) {
        code = "DIVIDE_BY_ZERO";
    }
    
    return ExecutionError{
        .code = code,
        .message = std.mem.sliceTo(&trap_message, 0),
        .module_id = context.module_id,
        .invocation_id = context.invocation_id,
        .fuel_consumed = try getFuelConsumed(context.store),
        .wall_clock_elapsed_ms = context.timeout_ctx.elapsed_ms,
    };
}
```

---

## 12. Public Interface

### 12.1 Core Executor

```zig
// src/wasm/executor.zig

pub const ExecutionContext = struct {
    module_id: []const u8,
    invocation_id: []const u8,
    instance_id: []const u8,
    actor_id: []const u8,
    trace_id: []const u8,
    
    capabilities: CapabilitySet,
    instance_state: InstanceState,
    pending_writes: *std.StringHashMap(ScriptValue),
    
    manifest: ModuleCapabilities,
    allocator: std.mem.Allocator,
};

pub const ExecutionResult = struct {
    success: bool,
    response: ?[]const u8,
    error_type: ?ErrorType,
    error_message: ?[]const u8,
    fuel_consumed: u64,
    wall_clock_elapsed_ms: u64,
};

pub const ErrorType = enum{
    TrapExecution,
    FuelExhausted,
    TimeoutExceeded,
    CapabilityDenied,
    MemoryAccessViolation,
    InitFailed,
    DeinitFailed,
};

pub fn executeModule(
    registry: *ModuleRegistry,
    module_id: []const u8,
    payload: []const u8,
    context: *ExecutionContext,
) !ExecutionResult;
```

### 12.2 Module Registration

```zig
// src/wasm/module_registry.zig

pub fn registerModule(
    registry: *ModuleRegistry,
    module_id: []const u8,
    artifact: []const u8,
    capabilities: CapabilitySet,
    config: InstanceConfig,
) !ModuleVersion;

pub fn activateModule(
    registry: *ModuleRegistry,
    module_id: []const u8,
) !ModuleVersion;
```

---

## 13. External Dependencies

| Dependency | Module | Purpose |
|---|---|---|
| Wasmtime (C API) | `wasmtime_bindings.zig` | Embedded Wasm runtime |
| `src/engine/state.zig` | `executor.zig` | InstanceState for context |
| `src/event_store/store.zig` | `executor.zig` | Event appending |
| Service catalog | `host_api/call_service.zig` | Service lookup |
| `src/identity/tokens.zig` | `capabilities.zig` | Capability validation |
| Structured logging | `host_api/log.zig` | Audit logging |
| Time source | `host_api/now.zig` | Platform time |

---

## 14. Testing Strategy

### 14.1 Unit Tests (No DB, No Wasmtime)

- **Bytecode mocking:** Use synthetic Wasm binary fixtures; mock Wasmtime calls
- **Pointer validation:** Test bounds checks, null pointer detection
- **Import whitelist:** Verify unauthorized imports are rejected
- **Capability matching:** Test wildcard patterns and subset validation

### 14.2 Integration Tests (With Wasmtime)

- **Module compilation:** Real Zig-to-Wasm compilation; verify reproducibility
- **ABI validation:** Load a real Wasm module; validate all four required exports
- **Host function calls:** Invoke a module that calls `platform_read_variable`, `platform_log`, etc.
- **Memory isolation:** Write and read from module memory; verify bounds enforcement
- **Fuel limits:** Infinite loop terminates within configured limit
- **Timeout enforcement:** Module blocked on host call is interrupted
- **Instance pooling:** Pooled instances are reused; memory is reset between invocations
- **Hot reload:** New module version is activated; old invocations complete; new ones use new version
- **Parity with Lua:** Equivalent Lua and Wasm implementations produce identical results

### 14.3 Security Tests

- Attempt to import `wasi:filesystem/*` (should fail)
- Attempt to import unauthorized service function (should fail)
- Attempt memory access out of bounds (should fail)
- Attempt pointer arithmetic attacks (should fail)
- Attempt bytecode injection (should fail)

---

## 15. Integration Points

### 15.1 With SERVICE_TASK Node

A SERVICE_TASK can optionally include a Wasm module for request/response transformation:

```json
{
  "node_type": "SERVICE_TASK",
  "service_id": "payment_processor",
  "wasm_module_id": "payment_transform_v1",
  "wasm_payload_key": "response_body",
  "error_policy": "FAIL_INSTANCE"
}
```

### 15.2 With Event Store

Wasm modules can emit events (via `platform_emit_event`), which are appended to the event log:

```zig
fn platform_emit_event(store: ?*c.wasmtime_store_t, ...) c_int {
    // Parse event type and payload from memory
    // Append to event store
    // Return 0 on success
}
```

### 15.3 With Instance State Reconstruction

Wasm modules are considered deterministic (within Tier 3 rules). State reconstruction includes:
1. Replay all events up to the target point
2. For each SERVICE_TASK with a Wasm module, re-invoke the module with the same input and recorded output
3. Verify the recorded output matches re-execution (debugging aid)

---

## 16. Key Invariants

1. **No uncontrolled imports:** Every import is validated against capability whitelist at instantiation
2. **No filesystem access:** WASI filesystem modules are forbidden
3. **Memory isolation:** All pointer dereferences are validated before access
4. **Resource limits enforced:** Fuel, memory, and timeout are strictly enforced
5. **Per-invocation isolation:** Pooled instances are reset; no state leakage between invocations
6. **Host API parity:** Wasm and Lua host functions have identical semantics
7. **Hot reload safety:** In-flight invocations use their original version pool
8. **Reproducible compilation:** Same source + toolchain = byte-identical artifact
9. **Capability enforcement:** Every host function checks the module's declared capabilities
10. **Deterministic (where applicable):** Same module + same input + same version = same result

---

## 17. Implementation Roadmap

**Phase 1 (MVP) — Embedding and Sandboxing:**
- Wasmtime C FFI integration (WASM-01)
- Engine and store management
- Module ABI validation (WASM-02)
- Import whitelist enforcement (WASM-06)
- No filesystem access guarantee (WASM-07)
- Basic memory validation (WASM-08)

**Phase 2 (Resource Limits and Execution):**
- Fuel-based instruction limit (WASM-09)
- Memory cap enforcement (WASM-10)
- Wall-clock timeout (WASM-11)
- Source compilation job (WASM-03)
- Compilation caching (WASM-04)
- Host API subset: `read_variable`, `write_variable`, `log`, `now` (WASM-12)

**Phase 3 (Pooling and Hot Reload):**
- Instance pooling with per-invocation reset (WASM-13)
- Hot reload with version management (WASM-14)
- Full host API parity: `call_service`, `fail`, `uuid` (WASM-12)
- Comprehensive error handling and diagnostics
- Build reproducibility testing (WASM-05)

**Phase 4 (Integration and Optimization):**
- SERVICE_TASK integration
- Instance pool tuning and profiling
- Cross-module compatibility tests (Lua vs. Wasm)
- Integration with repository (Stage 10) for artifact storage

---

## 18. Acceptance Criteria Summary

| Requirement | Criterion |
|---|---|
| WASM-01 | No external Wasmtime shared library dependency |
| WASM-02 | Registration of module without all four exports is rejected |
| WASM-03 | Compilation job returns job ID immediately; does not block request |
| WASM-04 | Identical source submitted twice uses cached artifact |
| WASM-05 | Same source + toolchain produce byte-identical binaries |
| WASM-06 | Module importing unauthorized function cannot instantiate |
| WASM-07 | Module importing `wasi:filesystem/*` is rejected |
| WASM-08 | Out-of-bounds memory access is caught before host dereference |
| WASM-09 | Infinite loop terminates within configured fuel budget |
| WASM-10 | Memory growth beyond cap causes trap |
| WASM-11 | Host-blocking call exceeding timeout is interrupted |
| WASM-12 | Lua and Wasm implementations of equivalent logic produce identical results |
| WASM-13 | Pooled instances show reduced p50 latency; memory is reset between uses |
| WASM-14 | New version is activated; in-flight invocations complete with old version |

