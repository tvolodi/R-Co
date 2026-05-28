# Test Spec: LUA-06 — Capability Check at Call Site

**Requirement:** LUA-06 — Every host function MUST check the script's declared capabilities before executing. A missing capability MUST raise a Lua error with structured details (function name, capability required, capabilities granted).

**Priority:** MUST  
**Test layer:** unit, integration

## Acceptance Criteria Mapping

- A capability denial test exists for every host function listed in Architecture §5.2.
- Denied capability errors include function name, capability required, and capabilities granted.

## Test Cases

### TC-LUA-06-01: platform.call_service denies unknown service capability
**Given:** A Lua script with capabilities `["variable:read"]` (no `service:call:payment_svc`).  
**When:** The script calls `platform.call_service("payment_svc", "POST", "/pay", {}, "{}")`.  
**Then:** A Lua error is raised with message containing `"service:call:payment_svc"`, `"payment_svc"`, and the list of granted capabilities.  
**Layer:** unit  
**Acceptance criterion mapped:** Every host function has capability check; call_service verified.

### TC-LUA-06-02: platform.call_service allows permitted service
**Given:** A Lua script with capability `["service:call:payment_svc"]`.  
**When:** The script calls `platform.call_service("payment_svc", "GET", "/status", {}, "")` against a registered service.  
**Then:** The call proceeds (succeeds or fails on HTTP layer, not on capability layer).  
**Layer:** integration  
**Acceptance criterion mapped:** Permitted capability allows call.

### TC-LUA-06-03: platform.read_variable denies without variable:read
**Given:** A Lua script with capabilities `["service:call:test"]` (no `variable:read`).  
**When:** The script calls `platform.read_variable("my_var")`.  
**Then:** A Lua error is raised with message containing `"variable:read"` and granted capabilities.  
**Layer:** unit  
**Acceptance criterion mapped:** Read capability denied when absent.

### TC-LUA-06-04: platform.read_variable allows with variable:read
**Given:** A Lua script with capability `["variable:read"]` and instance has variable `{"status": "active"}`.  
**When:** The script calls `platform.read_variable("status")`.  
**Then:** The call returns `"active"` (the variable value).  
**Layer:** integration  
**Acceptance criterion mapped:** Read capability allows access.

### TC-LUA-06-05: platform.write_variable denies without variable:write
**Given:** A Lua script with capabilities `["variable:read"]` (no `variable:write`).  
**When:** The script calls `platform.write_variable("status", "done")`.  
**Then:** A Lua error is raised with message containing `"variable:write"`.  
**Layer:** unit  
**Acceptance criterion mapped:** Write capability denied when absent.

### TC-LUA-06-06: platform.write_variable allows with variable:write
**Given:** A Lua script with capability `["variable:write"]`.  
**When:** The script calls `platform.write_variable("status", "completed")`.  
**Then:** The write is staged (no Lua error raised).  
**Layer:** integration  
**Acceptance criterion mapped:** Write capability allows staging.

### TC-LUA-06-07: platform.log denies without audit:log
**Given:** A Lua script with capabilities `["variable:read"]` (no `audit:log`).  
**When:** The script calls `platform.log("INFO", "Script running", {})`.  
**Then:** A Lua error is raised with message containing `"audit:log"`.  
**Layer:** unit  
**Acceptance criterion mapped:** Log capability denied when absent.

### TC-LUA-06-08: platform.log allows with audit:log
**Given:** A Lua script with capability `["audit:log"]`.  
**When:** The script calls `platform.log("WARN", "Alert", {reason="test"})`.  
**Then:** The log entry is appended (no Lua error).  
**Layer:** integration  
**Acceptance criterion mapped:** Log capability allows emission.

### TC-LUA-06-09: platform.emit_event denies without event:emit
**Given:** A Lua script with capabilities `["variable:read"]` (no `event:emit`).  
**When:** The script calls `platform.emit_event("CUSTOM_EVENT", {})`.  
**Then:** A Lua error is raised with message containing `"event:emit"`.  
**Layer:** unit  
**Acceptance criterion mapped:** Emit capability denied when absent.

### TC-LUA-06-10: platform.emit_event allows with event:emit
**Given:** A Lua script with capability `["event:emit"]`.  
**When:** The script calls `platform.emit_event("CUSTOM_EVENT", {payload="test"})`.  
**Then:** The event is staged for emission (no Lua error).  
**Layer:** integration  
**Acceptance criterion mapped:** Emit capability allows staging.

### TC-LUA-06-11: platform.get_instance_state denies without instance:read
**Given:** A Lua script with capabilities `["variable:read"]` (no `instance:read`).  
**When:** The script calls `platform.get_instance_state()`.  
**Then:** A Lua error is raised with message containing `"instance:read"`.  
**Layer:** unit  
**Acceptance criterion mapped:** Instance read capability denied when absent.

### TC-LUA-06-12: platform.get_instance_state allows with instance:read
**Given:** A Lua script with capability `["instance:read"]`.  
**When:** The script calls `platform.get_instance_state()`.  
**Then:** The instance state (variables, status) is returned as a Lua table.  
**Layer:** integration  
**Acceptance criterion mapped:** Instance read capability allows state access.

### TC-LUA-06-13: platform.now requires no capability
**Given:** A Lua script with capabilities `[]` (empty).  
**When:** The script calls `platform.now()`.  
**Then:** The current time is returned as ISO 8601 string (no capability error).  
**Layer:** unit  
**Acceptance criterion mapped:** Time source has no capability requirement.

### TC-LUA-06-14: platform.fail requires no capability
**Given:** A Lua script with capabilities `[]` (empty).  
**When:** The script calls `platform.fail("User cancelled", {})`.  
**Then:** The script terminates with an explicit failure (no capability error).  
**Layer:** unit  
**Acceptance criterion mapped:** Fail requires no capability.

### TC-LUA-06-15: error message format includes all required fields
**Given:** A Lua script with capabilities `["variable:read"]` attempting to call `platform.call_service("admin", ...)`.  
**When:** The capability check fails.  
**Then:** The error message includes: (a) function name, (b) required capability `"service:call:admin"`, (c) granted capabilities as a comma-separated list.  
**Layer:** unit  
**Acceptance criterion mapped:** Error format is structured and informative.

### TC-LUA-06-16: capability denial before any execution
**Given:** A Lua script with capabilities `["variable:read"]` that has a service call in its main logic.  
**When:** The script is executed.  
**Then:** The error is raised on the `platform.call_service` line, not from any downstream code.  
**Layer:** unit  
**Acceptance criterion mapped:** Capability check is the first guard.

## Test Data Factories

### Factory: Create execution context with capabilities
```zig
fn createContextWithCapabilities(allocator: std.mem.Allocator, caps: []const []const u8) !ExecutionContext {
    var capability_set = CapabilitySet.init(allocator);
    for (caps) |cap| {
        try capability_set.add(cap);
    }
    
    return ExecutionContext{
        .allocator = allocator,
        .capabilities = capability_set,
        // ... other fields initialized
    };
}
```

### Factory: Simple script that uses single host function
```lua
function test_function_call(func_name, arg1, arg2)
    if func_name == "read" then
        return platform.read_variable(arg1)
    elseif func_name == "write" then
        return platform.write_variable(arg1, arg2)
    elseif func_name == "log" then
        return platform.log(arg1, arg2, {})
    elseif func_name == "now" then
        return platform.now()
    -- ... etc
    end
end
```

## Expected Outcomes

- **Pass:** Lua error raised with correct capability denial message.
- **Pass:** Permitted capability allows function to execute or proceed to next layer.
- **Pass:** All 8 host functions (read, write, call_service, log, emit_event, get_instance_state, now, fail) verified to have capability checks.
- **Pass:** Error message format is consistent and informative.

## Traceability

- LUA-06 acceptance: TC-LUA-06-01 through TC-LUA-06-16.
- LUA-05 (host API registration): TC-LUA-06-01 through TC-LUA-06-14 (verify that only registered functions exist and are callable).
- LUA-07 (manifest validation): Capability check relies on manifest having declared capabilities.
- WASM-06 (parity with Wasm): Same capability check pattern applies to Wasm modules.
