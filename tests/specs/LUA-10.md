# Test Spec: LUA-10 — Wall Clock Timeout

**Requirement:** LUA-10 — Each script execution MUST have a configurable wall clock timeout enforced by the host (not relying on Lua to cooperate).

**Priority:** MUST  
**Test layer:** unit, integration

## Acceptance Criteria Mapping

- A script that blocks on a host function is still terminable within the configured timeout.
- The timeout is enforced from outside the Lua state.

## Test Cases

### TC-LUA-10-01: script completes within timeout
**Given:** A Lua script with `timeout_seconds = 10` that executes arithmetic in 100 milliseconds.  
**When:** The script is executed.  
**Then:** The script completes successfully well before 10 seconds.  
**Layer:** unit  
**Acceptance criterion mapped:** Fast script completes.

### TC-LUA-10-02: infinite loop hits timeout
**Given:** A Lua script with `timeout_seconds = 2` containing `while true do local x = 1 + 1 end`.  
**When:** The script is executed.  
**Then:** After approximately 2 seconds, execution is interrupted with error `TimeoutExceeded`.  
**Layer:** unit  
**Acceptance criterion mapped:** Infinite loop interrupted by timeout.

### TC-LUA-10-03: host function call respects timeout
**Given:** A Lua script with `timeout_seconds = 1` that calls a slow host function. Assume `platform.call_service("slow_api", ...)` takes 5 seconds.  
**When:** The script is executed.  
**Then:** The host function call is interrupted at approximately 1 second, before it returns. Error `TimeoutExceeded` is raised.  
**Layer:** integration  
**Acceptance criterion mapped:** Host call blocked by timeout.

### TC-LUA-10-04: timeout enforced from outside Lua state
**Given:** A Lua script designed to bypass Lua-level hooks (assumes Lua hook callback can be disabled or delayed).  
**When:** The script runs with a 1-second timeout.  
**Then:** The timeout is still enforced from the host side (timer or signal handler), terminating execution at 1 second regardless of Lua state.  
**Layer:** unit  
**Acceptance criterion mapped:** Timeout is host-enforced, not Lua-enforced.

### TC-LUA-10-05: timeout error includes elapsed time
**Given:** A Lua script with `timeout_seconds = 2` that times out after 2.1 seconds.  
**When:** The timeout error is raised.  
**Then:** The error payload includes fields: `timeout_seconds: 2`, `elapsed_ms: ~2100` (actual elapsed).  
**Layer:** unit  
**Acceptance criterion mapped:** Error is structured with timing.

### TC-LUA-10-06: timeout distinguishable from instruction/memory limits
**Given:** A Lua script designed to trigger multiple limits (low instruction, low memory, short timeout). We set timeout much lower.  
**When:** The script exceeds timeout before other limits.  
**Then:** The error type is `TimeoutExceeded` (not `InstructionLimitExceeded` or `MemoryLimitExceeded`).  
**Layer:** unit  
**Acceptance criterion mapped:** Timeout error is distinct.

### TC-LUA-10-07: timeout is per-invocation
**Given:** Two sequential script invocations both with `timeout_seconds = 1`. The first executes for 500 ms. The second also executes for 500 ms.  
**When:** Both scripts are executed sequentially.  
**Then:** Both succeed (the timeout is reset between invocations).  
**Layer:** integration  
**Acceptance criterion mapped:** Timeout is per-invocation, not cumulative.

### TC-LUA-10-08: tight loop hits timeout not instruction limit
**Given:** A Lua script with `timeout_seconds = 1` and `max_instructions = 1_000_000_000` (very high) containing an infinite loop.  
**When:** The script is executed.  
**Then:** The loop is interrupted at approximately 1 second by the timeout, not by the instruction limit.  
**Layer:** unit  
**Acceptance criterion mapped:** Timeout can fire independently of instruction limit.

### TC-LUA-10-09: timeout recorded in execution record
**Given:** A Lua script with `timeout_seconds = 30` that completes in 500 ms.  
**When:** The execution is recorded.  
**Then:** The record includes `declared_timeout_seconds: 30` and `wall_clock_elapsed_ms: ~500`.  
**Layer:** integration  
**Acceptance criterion mapped:** Timing recorded.

### TC-LUA-10-10: no timeout on very fast script
**Given:** A Lua script with `timeout_seconds = 1` that executes a single arithmetic operation in < 1 ms.  
**When:** The script is executed.  
**Then:** The script completes successfully without approaching the timeout.  
**Layer:** unit  
**Acceptance criterion mapped:** Sub-millisecond scripts complete.

## Test Data Factories

### Factory: Script that sleeps via host call
```lua
-- Assume platform.delay_millis(ms) is available
function create_delay_script(delay_ms)
    return string.format([[
        local result = platform.call_service("sleep", "POST", "/sleep?ms=%d", {}, "")
        return result
    ]], delay_ms)
end
```

### Factory: Infinite loop script
```lua
return {
    __manifest__ = {
        capabilities = {},
        max_instructions = 1000000000,
        max_memory_bytes = 64000000,
        timeout_seconds = 2
    },
    function main()
        while true do
            local x = 1 + 1
        end
    end
}
```

### Factory: Fast arithmetic script
```lua
return {
    __manifest__ = {
        capabilities = {},
        max_instructions = 10000,
        max_memory_bytes = 1000000,
        timeout_seconds = 30
    },
    function main()
        local sum = 0
        for i = 1, 100 do
            sum = sum + i
        end
        return sum
    end
}
```

## Expected Outcomes

- **Pass:** Fast scripts complete without timeout.
- **Pass:** Infinite loops/slow host calls are interrupted by timeout.
- **Pass:** Timeout is enforced from host side, not relying on Lua cooperation.
- **Pass:** Error includes elapsed time and timeout value.
- **Pass:** Timeout is per-invocation.
- **Pass:** Timeout can fire independently of instruction/memory limits.

## Traceability

- LUA-10 acceptance: TC-LUA-10-01 through TC-LUA-10-10.
- LUA-08 (instruction limit companion): Both prevent runaway execution via different mechanisms.
- LUA-09 (memory limit companion): Three complementary resource limits.
- WASM-11 (Wasm timeout): Equivalent for Wasm modules.
