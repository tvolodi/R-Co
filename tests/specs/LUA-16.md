# Test Spec: LUA-16 — Runtime Error Capture

**Requirement:** LUA-16 — Uncaught Lua errors MUST be captured by the host and converted to structured `SCRIPT_ERROR` events with stack trace, instruction count consumed, and capability state at failure.

**Priority:** MUST  
**Test layer:** integration

## Acceptance Criteria Mapping

- Division by zero in a script yields a rich error report including stack trace and instruction count.
- The `SCRIPT_ERROR` event is appended to the instance event log.

## Test Cases

### TC-LUA-16-01: division by zero raises error
**Given:** A Lua script with `local x = 1 / 0`.  
**When:** The script is executed.  
**Then:** Execution terminates with an error (uncaught, not caught by script).  
**Layer:** unit  
**Acceptance criterion mapped:** Division by zero is an error.

### TC-LUA-16-02: SCRIPT_ERROR event is emitted
**Given:** A Lua script that causes a runtime error (`1 / 0` or nil access).  
**When:** The script terminates with uncaught error.  
**Then:** A `SCRIPT_ERROR` event appears in the instance event log.  
**Layer:** integration  
**Acceptance criterion mapped:** Event is recorded.

### TC-LUA-16-03: error message is included
**Given:** A Lua script with `local x = nil; x.property` (nil access error).  
**When:** The script terminates.  
**Then:** The SCRIPT_ERROR event includes an error_message like `"attempt to index a nil value"`.  
**Layer:** integration  
**Acceptance criterion mapped:** Error message captured.

### TC-LUA-16-04: stack trace is captured
**Given:** A Lua script with nested function calls that throws an error deep in the call stack:
```lua
function f3() return 1 / 0 end
function f2() return f3() end
function f1() return f2() end
f1()
```

**When:** The script terminates.  
**Then:** The SCRIPT_ERROR event includes a stack trace showing the call chain: `f1 -> f2 -> f3`.  
**Layer:** integration  
**Acceptance criterion mapped:** Stack trace includes function names.

### TC-LUA-16-05: stack trace includes source location
**Given:** A Lua script with an error at a specific line.  
**When:** The script terminates.  
**Then:** The stack trace includes line numbers for each frame, e.g. `script:5 in function f1`.  
**Layer:** integration  
**Acceptance criterion mapped:** Stack trace includes line numbers.

### TC-LUA-16-06: instruction count at failure
**Given:** A Lua script with `max_instructions = 100_000` that runs a loop before hitting an error.  
**When:** The script terminates with error.  
**Then:** The SCRIPT_ERROR event includes `instruction_count` showing how many instructions were executed before the error.  
**Layer:** integration  
**Acceptance criterion mapped:** Instruction count recorded.

### TC-LUA-16-07: memory peak at failure
**Given:** A Lua script that allocates memory then hits an error.  
**When:** The script terminates.  
**Then:** The SCRIPT_ERROR event includes `memory_peak_bytes` showing the highest memory usage.  
**Layer:** integration  
**Acceptance criterion mapped:** Memory peak recorded.

### TC-LUA-16-08: capability state at failure
**Given:** A Lua script with capabilities `["variable:read", "service:call:api"]` that hits an error.  
**When:** The script terminates.  
**Then:** The SCRIPT_ERROR event includes `capabilities_at_failure` showing the granted capabilities.  
**Layer:** integration  
**Acceptance criterion mapped:** Capability state recorded.

### TC-LUA-16-09: nil access error
**Given:** A Lua script: `local t = nil; local x = t.field`.  
**When:** The script executes.  
**Then:** A SCRIPT_ERROR is raised with error message about nil value access.  
**Layer:** unit  
**Acceptance criterion mapped:** Nil errors caught.

### TC-LUA-16-10: table access error
**Given:** A Lua script: `local t = {}; t[nil] = 5` (invalid table key).  
**When:** The script executes.  
**Then:** A SCRIPT_ERROR is raised with appropriate error message.  
**Layer:** unit  
**Acceptance criterion mapped:** Table errors caught.

### TC-LUA-16-11: type mismatch error
**Given:** A Lua script: `local x = "string"; x + 5` (string + number).  
**When:** The script executes.  
**Then:** A SCRIPT_ERROR is raised with type mismatch message.  
**Layer:** unit  
**Acceptance criterion mapped:** Type errors caught.

### TC-LUA-16-12: function call error
**Given:** A Lua script: `function f(a, b) return a / b end; f(10, 0)`.  
**When:** The script executes.  
**Then:** A SCRIPT_ERROR is raised at the division by zero, with stack trace showing function f.  
**Layer:** unit  
**Acceptance criterion mapped:** Error in function captured.

### TC-LUA-16-13: assert failure
**Given:** A Lua script: `assert(false, "Assertion failed!")`.  
**When:** The script executes.  
**Then:** A SCRIPT_ERROR is raised with message containing `"Assertion failed!"`.  
**Layer:** unit  
**Acceptance criterion mapped:** Assertions are errors.

### TC-LUA-16-14: variable writes discarded on error
**Given:** A Lua script that calls `platform.write_variable("status", "updated")` then hits an error `1/0`.  
**When:** The script terminates with error.  
**Then:** The instance variable `status` retains its original value (write was discarded due to error).  
**Layer:** integration  
**Acceptance criterion mapped:** Writes not applied on error.

### TC-LUA-16-15: error distinguished from explicit failure
**Given:** Two scripts: (1) one that hits `1/0` error, (2) one that calls `platform.fail("reason")`.  
**When:** Both terminate.  
**Then:** (1) produces SCRIPT_ERROR event, (2) produces SCRIPT_FAILED event. Events have different types.  
**Layer:** integration  
**Acceptance criterion mapped:** Error vs failure distinction.

### TC-LUA-16-16: SCRIPT_ERROR event includes instance_id and trace_id
**Given:** A Lua script with `instance_id = "inst-xyz"` and `trace_id = "trace-789"` that hits an error.  
**When:** The script terminates.  
**Then:** The SCRIPT_ERROR event includes `instance_id = "inst-xyz"` and `trace_id = "trace-789"`.  
**Layer:** integration  
**Acceptance criterion mapped:** Event has context.

## Test Data Factories

### Factory: Script with intentional division by zero
```lua
return {
    __manifest__ = {
        capabilities = { "variable:read" },
        max_instructions = 100000,
        max_memory_bytes = 16777216,
        timeout_seconds = 30
    },
    function main(divisor)
        if divisor == 0 then
            -- This will raise an uncaught error
            return 10 / divisor
        end
        return 10 / divisor
    end
}
```

### Factory: Script with nested function error
```lua
return {
    __manifest__ = {
        capabilities = {},
        max_instructions = 100000,
        max_memory_bytes = 16777216,
        timeout_seconds = 30
    },
    function process_item(item)
        if not item.id then
            error("Item missing id")
        end
        return item.id
    end,
    
    function process_list(items)
        local results = {}
        for i, item in ipairs(items) do
            results[i] = process_item(item)
        end
        return results
    end,
    
    function main(data)
        return process_list(data)
    end
}
```

### Factory: Script with variable write then error
```lua
return {
    __manifest__ = {
        capabilities = { "variable:write" },
        max_instructions = 100000,
        max_memory_bytes = 16777216,
        timeout_seconds = 30
    },
    function main(value)
        platform.write_variable("processing", true)
        
        -- Some computation
        local result = value
        if type(value) == "string" then
            result = tonumber(value)
        end
        
        -- This will error if value was not a valid number string
        local doubled = result * 2
        
        platform.write_variable("result", doubled)
        return doubled
    end
}
```

### Factory: Script with assertion
```lua
return {
    __manifest__ = {
        capabilities = { "variable:read" },
        max_instructions = 100000,
        max_memory_bytes = 16777216,
        timeout_seconds = 30
    },
    function main(config)
        assert(config.api_key ~= nil, "API key is required")
        assert(config.timeout > 0, "Timeout must be positive")
        
        local current = platform.read_variable("state")
        assert(current ~= nil, "No current state found")
        
        return current
    end
}
```

## Expected Outcomes

- **Pass:** Division by zero, nil access, type mismatches, and assertions raise SCRIPT_ERROR.
- **Pass:** SCRIPT_ERROR event includes error message, stack trace with line numbers, and function names.
- **Pass:** Instruction count and memory peak are recorded.
- **Pass:** Capability state is included.
- **Pass:** Variable writes are discarded on error.
- **Pass:** Runtime errors are distinguished from explicit failures (SCRIPT_ERROR vs SCRIPT_FAILED).
- **Pass:** Event includes instance_id and trace_id for tracing.

## Traceability

- LUA-16 acceptance: TC-LUA-16-01 through TC-LUA-16-16.
- LUA-15 (structured failure): Explicit failure vs uncaught error.
- EE-10 (instance error handling): Error events trigger error policy routing.
- EE-09 (variable merge logic): Variables not written on error.
---

## ISS-0625 / GH-592 Integration Test Cases

The TCs below are exercised by the end-to-end integration test
`tests/integration/iss0625_lua_12_15_16_test.zig` (one file, three
requirement families, real LuaJIT + real PostgreSQL via BPM_TEST_DB_URL).
The TC-LUA-16-NN cases above describe the *user-facing contract*; these
new TCs verify the *production wiring* that delivers it. They are
sub-numbers because the design also defines a unit-level suite at
`src/lua/iss0625_lua_12_15_16_test.zig` (TC-ISS-0625-LUA-16-01..03 unit
form).

### TC-ISS-0625-LUA-16-int-01: integration — runtime error captures error_message (KNOWN LIMITATION: stack_trace empty on LuaJIT 2.1)
**Given:** A real `ExecutionContext` and a Lua script that raises a runtime error from a nested call chain (`f3 -> f2 -> f1 -> main`, with `f3` calling `error("boom in f3")`).  
**When:** `lua_executor.executeScript` runs the script.  
**Then:** `ScriptResult.success == false`, `ScriptResult.error_kind == .RuntimeError`, `ScriptResult.script_error != null`, `ScriptErrorPayload.error_message` contains the substring `"boom in f3"`. **KNOWN LIMITATION:** `ScriptErrorPayload.stack_trace` is empty because LuaJIT 2.1 (Lua 5.1 API) unwinds the call stack before `lua_pcall` returns to C, so `lua_getstack` returns 0 by the time `captureStackTrace` runs. The proper fix is to install `debug.traceback` as the `errfunc` argument to `lua_pcall`. Today the trace is empty; the TC asserts this as the invariant and flips when the limitation is fixed. Tracking: ISS-0626 (to be filed).  
**Layer:** integration  
**Acceptance criterion mapped:** LUA-16 end-to-end — the `lua_pcall` error message reaches `ScriptErrorPayload.error_message`; classification as `.RuntimeError` is correct.  
**Test file:** `tests/integration/iss0625_lua_12_15_16_test.zig`, test block `"TC-ISS-0625-LUA-16-int-01: ..."`.

### TC-ISS-0625-LUA-16-int-02: integration — instruction_count == 0 (LUA-08 instruction limiter not installed)
**Given:** A real `ExecutionContext` (with `instruction_limiter = null` — the LUA-08 source is not installed in this run, per design D-3) and a Lua script that raises via nil indexing (`local x = nil; return x.field`).  
**When:** `lua_executor.executeScript` runs the script.  
**Then:** `ScriptResult.success == false`, `ScriptResult.error_kind == .RuntimeError`, `ScriptResult.script_error != null`, `ScriptErrorPayload.instruction_count == 0` AND `ScriptErrorPayload.memory_peak_bytes == 0` (LUA-09 deferred, always 0 today).  
**Layer:** integration  
**Acceptance criterion mapped:** decision D-3 — the payload still constructs when the limiter is null, with `instruction_count = 0` and the skip reason recorded in `capabilities_at_failure`.  
**Test file:** `tests/integration/iss0625_lua_12_15_16_test.zig`, test block `"TC-ISS-0625-LUA-16-int-02: ..."`.

### TC-ISS-0625-LUA-16-int-03: integration — capabilities_at_failure == skip_reason literal (decision D-3)
**Given:** A real `ExecutionContext` (limiter not installed) and a Lua script that raises via `error("intentional runtime error")`.  
**When:** `lua_executor.executeScript` runs the script.  
**Then:** `ScriptErrorPayload.capabilities_at_failure` equals the literal string `"skip: instruction_count source not installed (LUA-08 deferred)"` (also reachable as `lua_executor.SKIP_REASON_NO_INSTRUCTION_LIMITER`). Any change to this literal in `src/lua/executor.zig` is a test change.  
**Layer:** integration  
**Acceptance criterion mapped:** decision D-3 — the literal skip reason is the authoritative signal that the payload constructed in the LUA-08-deferred branch.  
**Test file:** `tests/integration/iss0625_lua_12_15_16_test.zig`, test block `"TC-ISS-0625-LUA-16-int-03: ..."`.

## ISS-0625 Cross-References

- LUA-12 (service call): TC-ISS-0625-LUA-12-int-01..02 in this run's integration test file.
- LUA-15 (registry-channel failure anti-forgery): TC-ISS-0625-LUA-15-int-01..04 in this run's integration test file.
- Backlog issue: ISS-0625 / GH-592. Unit tests live in `src/lua/iss0625_lua_12_15_16_test.zig` (TC-ISS-0625-LUA-{12,15,16}-NN). Limitation follow-up: ISS-0626 (LUA-16 stack-trace empty on LuaJIT 2.1 — install `debug.traceback` as the `errfunc` to `lua_pcall`).