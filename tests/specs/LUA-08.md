# Test Spec: LUA-08 — Instruction Limit

**Requirement:** LUA-08 — Each script execution MUST have a configurable maximum instruction count. Exceeding the limit MUST terminate the script with a structured timeout error.

**Priority:** MUST  
**Test layer:** unit, integration

## Acceptance Criteria Mapping

- An infinite loop terminates within the configured instruction limit.
- The error returned is structured and identifies the script and the limit exceeded.

## Test Cases

### TC-LUA-08-01: infinite loop terminates within instruction limit
**Given:** A Lua script with `max_instructions = 10_000` containing an infinite loop `while true do end`.  
**When:** The script is executed.  
**Then:** Execution terminates within 10,000 instructions with error `InstructionLimitExceeded`.  
**Layer:** unit  
**Acceptance criterion mapped:** Infinite loop caught by limit.

### TC-LUA-08-02: script within limit executes fully
**Given:** A Lua script with `max_instructions = 100_000` that performs 500 iterations of arithmetic `local x = 1 + 1`.  
**When:** The script is executed.  
**Then:** The script completes successfully without hitting the limit.  
**Layer:** unit  
**Acceptance criterion mapped:** Normal script within limit completes.

### TC-LUA-08-03: tight loop hitting limit partway through
**Given:** A Lua script with `max_instructions = 5_000` containing `for i=1, 100000 do local x = i * 2 end`.  
**When:** The script is executed.  
**Then:** The loop terminates early at approximately 5,000 instructions with error `InstructionLimitExceeded`.  
**Layer:** unit  
**Acceptance criterion mapped:** Limit enforced mid-execution.

### TC-LUA-08-04: instruction count in error message
**Given:** A Lua script with `max_instructions = 1_000` that exceeds the limit.  
**When:** The error is raised.  
**Then:** The error payload includes fields: `instruction_limit: 1000`, `instructions_executed: ~1000` (actual count), and `script_id`.  
**Layer:** unit  
**Acceptance criterion mapped:** Error is structured.

### TC-LUA-08-05: instruction limit error distinguishable from other errors
**Given:** A Lua script that both (a) hits an instruction limit and (b) has a syntax error. We execute the version with instruction limit.  
**When:** The script is executed.  
**Then:** The error type is `InstructionLimitExceeded` (not `RuntimeError` or `CompileError`).  
**Layer:** unit  
**Acceptance criterion mapped:** Error type is distinct.

### TC-LUA-08-06: recursive function call consumes instructions
**Given:** A Lua script with `max_instructions = 10_000` containing a recursive function that calls itself 10,000 times `function f(n) if n > 0 then f(n-1) end end f(100000)`.  
**When:** The script is executed.  
**Then:** Recursion terminates due to instruction limit (not stack overflow from the host).  
**Layer:** unit  
**Acceptance criterion mapped:** Recursion consumes instructions.

### TC-LUA-08-07: host function calls consume instructions
**Given:** A Lua script with `max_instructions = 5_000` that makes repeated calls to `platform.now()` in a loop `for i=1,10000 do platform.now() end`.  
**When:** The script is executed.  
**Then:** The loop terminates at approximately 5,000 instructions due to limit, not due to the number of calls.  
**Layer:** integration  
**Acceptance criterion mapped:** Host function calls count toward limit.

### TC-LUA-08-08: string operations consume instructions
**Given:** A Lua script with `max_instructions = 5_000` containing heavy string manipulation `local s = "x" for i=1,100000 do s = s .. "y" end`.  
**When:** The script is executed.  
**Then:** The loop terminates at approximately 5,000 instructions.  
**Layer:** unit  
**Acceptance criterion mapped:** String operations consume instructions.

### TC-LUA-08-09: table operations consume instructions
**Given:** A Lua script with `max_instructions = 10_000` building a large table `local t = {} for i=1,100000 do table.insert(t, i) end`.  
**When:** The script is executed.  
**Then:** The loop terminates at approximately 10,000 instructions.  
**Layer:** unit  
**Acceptance criterion mapped:** Table operations consume instructions.

### TC-LUA-08-10: instruction limit recorded in execution record
**Given:** A Lua script with `max_instructions = 50_000` that completes normally.  
**When:** The execution is recorded.  
**Then:** The execution record includes fields: `declared_max_instructions: 50000`, `actual_instructions_consumed: ~<actual>`.  
**Layer:** integration  
**Acceptance criterion mapped:** Execution statistics recorded.

## Test Data Factories

### Factory: Script with configurable loop count
```lua
function create_loop_script(iterations)
    return string.format([[
        local count = 0
        for i = 1, %d do
            count = count + 1
        end
        return count
    ]], iterations)
end
```

### Factory: Infinite loop script
```lua
return {
    __manifest__ = {
        capabilities = {},
        max_instructions = 10000,
        max_memory_bytes = 16777216,
        timeout_seconds = 30
    },
    function main()
        while true do
            local x = 1 + 1
        end
    end
}
```

### Factory: Normal script within limits
```lua
return {
    __manifest__ = {
        capabilities = { "variable:read" },
        max_instructions = 100000,
        max_memory_bytes = 16777216,
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

- **Pass:** Infinite loops terminate within limit.
- **Pass:** Normal scripts within limit complete.
- **Pass:** Error is structured with instruction count details.
- **Pass:** All instruction-consuming operations (loops, recursion, string ops, table ops, host calls) are counted.
- **Pass:** Instruction count is recorded in execution record.

## Traceability

- LUA-08 acceptance: TC-LUA-08-01 through TC-LUA-08-10.
- LUA-07 (manifest): Manifest declares `max_instructions` that is enforced here.
- LUA-09 (memory limit companion): Memory and instruction limits work together.
- LUA-10 (timeout companion): Timeout and instruction limit both prevent runaway.
- WASM-09 (Wasm fuel equivalent): Same concept for Wasm modules.
