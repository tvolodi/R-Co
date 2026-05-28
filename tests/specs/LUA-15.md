# Test Spec: LUA-15 — Structured Failure

**Requirement:** LUA-15 — `platform.fail(reason, details)` MUST terminate the script and propagate a structured failure to the engine. The engine MUST record a `SCRIPT_FAILED` event and transition the instance per the node's error policy.

**Priority:** MUST  
**Test layer:** integration

## Acceptance Criteria Mapping

- A test confirms that calling `platform.fail` produces a `SCRIPT_FAILED` event and the expected instance routing.

## Test Cases

### TC-LUA-15-01: platform.fail terminates execution
**Given:** A Lua script calling `platform.fail("User cancelled request")` followed by `return 42`.  
**When:** The script is executed.  
**Then:** Execution terminates at the fail call; `return 42` is never executed. The script does not return successfully.  
**Layer:** integration  
**Acceptance criterion mapped:** Fail terminates execution.

### TC-LUA-15-02: platform.fail with reason string
**Given:** A Lua script calling `platform.fail("Insufficient balance for transaction")`.  
**When:** The script executes.  
**Then:** The failure is recorded with reason `"Insufficient balance for transaction"`.  
**Layer:** integration  
**Acceptance criterion mapped:** Reason is captured.

### TC-LUA-15-03: platform.fail with reason and details table
**Given:** A Lua script calling `platform.fail("Payment declined", {error_code = 403, provider = "stripe"})`.  
**When:** The script executes.  
**Then:** The failure is recorded with reason and details: `{error_code = 403, provider = "stripe"}`.  
**Layer:** integration  
**Acceptance criterion mapped:** Details are captured.

### TC-LUA-15-04: SCRIPT_FAILED event is emitted
**Given:** A Lua script calling `platform.fail("test failure")` and the instance event log is queried.  
**When:** The script terminates with explicit failure.  
**Then:** A `SCRIPT_FAILED` event appears in the event log with the failure reason.  
**Layer:** integration  
**Acceptance criterion mapped:** Event is recorded.

### TC-LUA-15-05: SCRIPT_FAILED event includes instance_id
**Given:** A Lua script with `instance_id = "inst-abc"` calling `platform.fail("failure")`.  
**When:** The script terminates.  
**Then:** The SCRIPT_FAILED event includes `instance_id = "inst-abc"`.  
**Layer:** integration  
**Acceptance criterion mapped:** Event has context.

### TC-LUA-15-06: SCRIPT_FAILED event includes trace_id
**Given:** A Lua script with `trace_id = "trace-123"` calling `platform.fail("failure")`.  
**When:** The script terminates.  
**Then:** The SCRIPT_FAILED event includes `trace_id = "trace-123"`.  
**Layer:** integration  
**Acceptance criterion mapped:** Event includes trace context.

### TC-LUA-15-07: explicit failure is distinct from runtime error
**Given:** Two scenarios: (1) A script calling `platform.fail("explicit")` and (2) a script hitting `1/0` error.  
**When:** Both execute.  
**Then:** (1) produces a SCRIPT_FAILED event, (2) produces a SCRIPT_ERROR event. The events have different types.  
**Layer:** integration  
**Acceptance criterion mapped:** Failure type is explicit.

### TC-LUA-15-08: variable writes are discarded on fail
**Given:** A Lua script that calls `platform.write_variable("status", "updated")` then `platform.fail("intentional")`.  
**When:** The script terminates.  
**Then:** The instance variable `status` retains its original value (write was discarded).  
**Layer:** integration  
**Acceptance criterion mapped:** Writes not applied on fail.

### TC-LUA-15-09: fail without details argument
**Given:** A Lua script calling `platform.fail("reason only")` (no second argument).  
**When:** The script executes.  
**Then:** The failure is recorded with reason `"reason only"` and details `nil` or `{}`.  
**Layer:** integration  
**Acceptance criterion mapped:** Details optional.

### TC-LUA-15-10: fail with nil details
**Given:** A Lua script calling `platform.fail("reason", nil)`.  
**When:** The script executes.  
**Then:** The failure is recorded with reason and details `nil`.  
**Layer:** integration  
**Acceptance criterion mapped:** Nil details handled.

### TC-LUA-15-11: fail with complex details structure
**Given:** A Lua script calling `platform.fail("Complex failure", {nested = {data = {value = 123}}, array = {1, 2, 3}})`.  
**When:** The script executes.  
**Then:** The failure details include the nested structure.  
**Layer:** integration  
**Acceptance criterion mapped:** Complex structures work.

### TC-LUA-15-12: no capability required for fail
**Given:** A Lua script with capabilities `[]` (empty).  
**When:** The script calls `platform.fail("reason")`.  
**Then:** The call succeeds (no capability error); execution terminates.  
**Layer:** unit  
**Acceptance criterion mapped:** No capability required.

### TC-LUA-15-13: instance routing on SCRIPT_FAILED
**Given:** A SERVICE_TASK node with error policy: if SCRIPT_FAILED, transition to error handler task. A Lua script calls `platform.fail("error handler needed")`.  
**When:** The script terminates.  
**Then:** The instance transitions to the error handler task per the error policy.  
**Layer:** integration  
**Acceptance criterion mapped:** Error policy routing works (cross-reference EE-10).

### TC-LUA-15-14: platform.fail before any other calls
**Given:** A Lua script calling `platform.fail("early fail")` as the very first statement.  
**When:** The script executes.  
**Then:** The script terminates immediately with failure; subsequent statements never execute.  
**Layer:** integration  
**Acceptance criterion mapped:** Fail is immediate.

### TC-LUA-15-15: multiple fail calls (first wins)
**Given:** A Lua script with two fail calls (only first reachable due to control flow).  
**When:** The script executes the first fail.  
**Then:** The script terminates; the second fail is never reached.  
**Layer:** integration  
**Acceptance criterion mapped:** First fail terminates.

### TC-LUA-15-16: fail reason is not a Lua error
**Given:** A Lua script calling `platform.fail("reason string")`.  
**When:** Observing the internal implementation.  
**Then:** The failure is implemented as a Lua error (raises via lua_error) but is caught and converted to SCRIPT_FAILED event (not SCRIPT_ERROR).  
**Layer:** integration  
**Acceptance criterion mapped:** Failure handling is special-cased.

## Test Data Factories

### Factory: Script with controlled failure path
```lua
return {
    __manifest__ = {
        capabilities = { "variable:write" },
        max_instructions = 100000,
        max_memory_bytes = 16777216,
        timeout_seconds = 30
    },
    function main(should_fail)
        platform.write_variable("progress", "started")
        
        if should_fail then
            platform.fail("User cancelled operation", {
                progress = "started",
                action = "cancel"
            })
        end
        
        platform.write_variable("progress", "completed")
        return "success"
    end
}
```

### Factory: Script with validation failure
```lua
return {
    __manifest__ = {
        capabilities = { "variable:read" },
        max_instructions = 100000,
        max_memory_bytes = 16777216,
        timeout_seconds = 30
    },
    function main(amount)
        if amount < 0 then
            platform.fail("Invalid amount", {
                provided = amount,
                min = 0
            })
        end
        
        if amount > 1000000 then
            platform.fail("Amount exceeds limit", {
                provided = amount,
                max = 1000000
            })
        end
        
        return amount
    end
}
```

### Factory: Script with fail and error policy interaction
```lua
return {
    __manifest__ = {
        capabilities = { "audit:log" },
        max_instructions = 100000,
        max_memory_bytes = 16777216,
        timeout_seconds = 30
    },
    function main(context)
        platform.log("INFO", "Processing request", context)
        
        -- Check some condition
        local valid = context.user_id ~= nil and context.amount > 0
        
        if not valid then
            platform.fail("Validation failed", {
                user_id = context.user_id,
                amount = context.amount
            })
        end
        
        return "processed"
    end
}
```

## Expected Outcomes

- **Pass:** `platform.fail()` terminates execution immediately.
- **Pass:** SCRIPT_FAILED event is emitted with reason and details.
- **Pass:** Event includes instance_id and trace_id.
- **Pass:** Variable writes are discarded on fail.
- **Pass:** Explicit failure is distinguished from runtime errors.
- **Pass:** Instance routing follows error policy on SCRIPT_FAILED.
- **Pass:** No capability required for fail.

## Traceability

- LUA-15 acceptance: TC-LUA-15-01 through TC-LUA-15-16.
- LUA-16 (runtime error capture): Explicit failure vs uncaught error distinction.
- EE-10 (instance error handling): Error policy routing applies.
- EE-09 (variable merge logic): Variables not written on fail.
