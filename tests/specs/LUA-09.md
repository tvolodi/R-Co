# Test Spec: LUA-09 — Memory Limit

**Requirement:** LUA-09 — Each script execution MUST have a configurable memory limit. Allocations exceeding the limit MUST fail gracefully and terminate the script.

**Priority:** MUST  
**Test layer:** unit, integration

## Acceptance Criteria Mapping

- A script attempting to allocate 1 GB with a 16 MB limit fails cleanly without crashing the host.

## Test Cases

### TC-LUA-09-01: allocation exceeding limit fails cleanly
**Given:** A Lua script with `max_memory_bytes = 16_777_216` (16 MB) that attempts to allocate 1 GB via a large table `local big = {} for i=1,1000000 do big[i] = string.rep("x", 1000) end`.  
**When:** The script is executed.  
**Then:** The allocation fails with a Lua error (not a host crash) and returns error type `MemoryLimitExceeded`.  
**Layer:** unit  
**Acceptance criterion mapped:** Large allocation fails cleanly.

### TC-LUA-09-02: script within memory limit executes normally
**Given:** A Lua script with `max_memory_bytes = 32_777_216` (32 MB) that allocates a 5 MB table.  
**When:** The script is executed.  
**Then:** The script completes successfully without hitting the memory limit.  
**Layer:** unit  
**Acceptance criterion mapped:** Normal allocation within limit succeeds.

### TC-LUA-09-03: many small allocations add up to limit
**Given:** A Lua script with `max_memory_bytes = 1_000_000` (1 MB) that makes 1000 allocations of ~2 KB each.  
**When:** The script is executed.  
**Then:** After approximately 500 allocations (1 MB total), the next allocation fails with `MemoryLimitExceeded`.  
**Layer:** unit  
**Acceptance criterion mapped:** Memory is accumulated across allocations.

### TC-LUA-09-04: memory peak tracking is recorded
**Given:** A Lua script with `max_memory_bytes = 64_000_000` (64 MB) that allocates a 30 MB table, then deallocates it, then allocates a 20 MB table.  
**When:** The script completes successfully.  
**Then:** The execution record includes `memory_peak_bytes: ~30_000_000` (the highest point, not the final size).  
**Layer:** integration  
**Acceptance criterion mapped:** Peak memory is tracked.

### TC-LUA-09-05: deallocation frees memory for reuse
**Given:** A Lua script with `max_memory_bytes = 30_000_000` that allocates a 15 MB table, then explicitly releases it, then allocates another 15 MB table.  
**When:** The script is executed.  
**Then:** Both allocations succeed (the first allocation is freed before the second).  
**Layer:** unit  
**Acceptance criterion mapped:** Deallocation allows reuse.

### TC-LUA-09-06: string concatenation consumes memory
**Given:** A Lua script with `max_memory_bytes = 5_000_000` that performs repeated string concatenation `local s = "" for i=1,10000 do s = s .. string.rep("x", 1000) end`.  
**When:** The script is executed.  
**Then:** String memory accumulates; the loop terminates when memory is exhausted with `MemoryLimitExceeded`.  
**Layer:** unit  
**Acceptance criterion mapped:** String operations consume memory.

### TC-LUA-09-07: memory error distinguishable from other errors
**Given:** A Lua script designed to trigger both memory and instruction limits. We execute with memory limit much lower.  
**When:** The script exceeds memory before instructions.  
**Then:** The error type is `MemoryLimitExceeded` (not `InstructionLimitExceeded`).  
**Layer:** unit  
**Acceptance criterion mapped:** Memory error is distinct.

### TC-LUA-09-08: memory limit applies per-invocation
**Given:** Two sequential script executions both with `max_memory_bytes = 10_000_000`. The first allocates 5 MB and completes. The second also allocates 5 MB.  
**When:** Both scripts are executed.  
**Then:** Both succeed (the first's memory is released before the second starts).  
**Layer:** integration  
**Acceptance criterion mapped:** Memory limit is per-invocation, not cumulative.

### TC-LUA-09-09: Lua internal structures consume memory
**Given:** A Lua script with `max_memory_bytes = 2_000_000` (2 MB) that creates many function closures `local funcs = {} for i=1,10000 do funcs[i] = function(x) return x + i end end`.  
**When:** The script is executed.  
**Then:** Closure creation consumes memory; the loop terminates when limit is reached.  
**Layer:** unit  
**Acceptance criterion mapped:** Closure/object creation counts toward limit.

### TC-LUA-09-10: memory limit in execution record
**Given:** A Lua script with `max_memory_bytes = 50_000_000` that allocates and uses 10 MB.  
**When:** The execution is recorded.  
**Then:** The record includes `declared_max_memory_bytes: 50000000` and `actual_memory_peak_bytes: ~10000000`.  
**Layer:** integration  
**Acceptance criterion mapped:** Memory statistics recorded.

## Test Data Factories

### Factory: Script allocating N MB
```lua
function create_alloc_script(mb_count)
    local kb_count = mb_count * 1024
    return string.format([[
        local big = {}
        for i = 1, %d do
            big[i] = string.rep("x", 1024)
        end
        return #big
    ]], kb_count)
end
```

### Factory: String concatenation script
```lua
return {
    __manifest__ = {
        capabilities = {},
        max_instructions = 1000000,
        max_memory_bytes = 5000000,
        timeout_seconds = 30
    },
    function main()
        local s = ""
        for i = 1, 100000 do
            s = s .. "x"
        end
        return s
    end
}
```

### Factory: Closure creation script
```lua
return {
    __manifest__ = {
        capabilities = {},
        max_instructions = 1000000,
        max_memory_bytes = 2000000,
        timeout_seconds = 30
    },
    function main()
        local funcs = {}
        for i = 1, 100000 do
            funcs[i] = function(x) return x + i end
        end
        return #funcs
    end
}
```

## Expected Outcomes

- **Pass:** Large allocations fail cleanly with `MemoryLimitExceeded`.
- **Pass:** Normal scripts within limit execute successfully.
- **Pass:** Memory accumulates across allocations and is freed on deallocation.
- **Pass:** Peak memory is tracked and recorded.
- **Pass:** Memory limit is per-invocation.
- **Pass:** All memory-consuming operations (tables, strings, closures) are counted.

## Traceability

- LUA-09 acceptance: TC-LUA-09-01 through TC-LUA-09-10.
- LUA-08 (instruction limit companion): Memory and instruction limits enforce different resource bounds.
- LUA-10 (timeout companion): Timeout is the third resource limit.
- WASM-10 (Wasm memory cap): Equivalent for Wasm modules.
