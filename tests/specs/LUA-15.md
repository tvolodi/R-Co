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
---

## ISS-0625 / GH-592 Integration Test Cases

The TCs below are exercised by the end-to-end integration test
`tests/integration/iss0625_lua_12_15_16_test.zig` (one file, three
requirement families, real LuaJIT + real PostgreSQL via BPM_TEST_DB_URL).
The TC-LUA-15-NN cases above describe the *user-facing contract*; these
new TCs verify the *production wiring* that delivers it. They are
sub-numbers because the design also defines a unit-level suite at
`src/lua/iss0625_lua_12_15_16_test.zig` (TC-ISS-0625-LUA-15-01..04 unit
form).

### TC-ISS-0625-LUA-15-int-01: integration — platform.fail produces ScriptResult.error_kind == .ExplicitFailure
**Given:** A real `ExecutionContext` with an empty `CapabilitySet`, a sandboxed `lua_State`, and a Lua script `platform.fail("User cancelled request", {code = 403}); return 42`.  
**When:** `lua_executor.executeScript` runs the script.  
**Then:** `ScriptResult.success == false`, `ScriptResult.error_kind == .ExplicitFailure`, `ScriptResult.error_message == "User cancelled request"`, `ScriptResult.script_error == null` (explicit failure carries no stack trace).  
**Layer:** integration  
**Acceptance criterion mapped:** the `platform.fail` host-API call writes the LUA-15 registry discriminator AND the reason key on `LUA_REGISTRYINDEX`, and `executor.executeSource` classifies the resulting failed `lua_pcall` as `.ExplicitFailure` rather than `.RuntimeError`.  
**Test file:** `tests/integration/iss0625_lua_12_15_16_test.zig`, test block `"TC-ISS-0625-LUA-15-int-01: ..."`.

### TC-ISS-0625-LUA-15-int-02: integration — error() raise produces .RuntimeError (NOT mis-classified)
**Given:** A real `ExecutionContext` and a Lua script that uses the standard `error()` builtin (e.g. `error("intentional runtime error")`). The script author never calls `platform.fail`.  
**When:** `lua_executor.executeScript` runs the script.  
**Then:** `ScriptResult.success == false`, `ScriptResult.error_kind == .RuntimeError`, `ScriptResult.script_error != null` (a `ScriptErrorPayload` is built).  
**Layer:** integration  
**Acceptance criterion mapped:** a Lua runtime error is classified as `.RuntimeError`, NOT `.ExplicitFailure` — the LUA-15 discriminator reads `bpm.explicit_failure` truthy from the registry and that flag is FALSE when the script never went through `platform.fail`.  
**Test file:** `tests/integration/iss0625_lua_12_15_16_test.zig`, test block `"TC-ISS-0625-LUA-15-int-02: ..."`.

### TC-ISS-0625-LUA-15-int-03: integration — script forges __failure_reason__ via _G is IGNORED
**Given:** A real `ExecutionContext` and a Lua script that sets `__failure_reason__ = "FORGED"` and `__explicit_failure__ = true` BEFORE calling `platform.fail("real reason from registry")`.  
**When:** `lua_executor.executeScript` runs the script.  
**Then:** `ScriptResult.error_kind == .ExplicitFailure` (because `platform.fail` legitimately wrote the registry discriminator), AND `ScriptResult.error_message == "real reason from registry"` — NOT `"FORGED"`. The pre-ISS-0625 `_G.__failure_reason__` channel is dead weight; the registry channel wins.  
**Layer:** integration  
**Acceptance criterion mapped:** LUA-15 anti-forgery guarantee — the migration to a registry-backed discriminator eliminated the `_G` channel as an authoritative source.  
**Test file:** `tests/integration/iss0625_lua_12_15_16_test.zig`, test block `"TC-ISS-0625-LUA-15-int-03: ..."`.

### TC-ISS-0625-LUA-15-int-04: integration — explicit details table is preserved; no stack trace on explicit failures
**Given:** A real `ExecutionContext` and a Lua script `platform.fail("Validation failed", {user_id = "u1", amount = -10, reason = "negative"})`.  
**When:** `lua_executor.executeScript` runs the script.  
**Then:** `ScriptResult.success == false`, `ScriptResult.error_kind == .ExplicitFailure`, `ScriptResult.error_message == "Validation failed"`, `ScriptResult.script_error == null`. The table details are preserved in the engine-side channel (the executor reads the registry value after the failed pcall), but the executor-level invariant is that an explicit failure produces NO `ScriptErrorPayload`.  
**Layer:** integration  
**Acceptance criterion mapped:** explicit failures are a clean API — no stack trace, no script_error side-channel; the table details flow on a separate channel (`host_context.readExplicitFailure` returns the `details` field separately to the engine).  
**Test file:** `tests/integration/iss0625_lua_12_15_16_test.zig`, test block `"TC-ISS-0625-LUA-15-int-04: ..."`.

## ISS-0625 Cross-References

- LUA-12 (service call): TC-ISS-0625-LUA-12-int-01..02 in this run's integration test file.
- LUA-16 (stack-trace + instruction-count payload): TC-ISS-0625-LUA-16-int-01..03 in this run's integration test file.
- Backlog issue: ISS-0625 / GH-592. Unit tests live in `src/lua/iss0625_lua_12_15_16_test.zig` (TC-ISS-0625-LUA-{12,15,16}-NN).