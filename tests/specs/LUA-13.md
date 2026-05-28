# Test Spec: LUA-13 — Logging

**Requirement:** LUA-13 — `platform.log(level, message, context)` MUST emit a structured log entry tagged with the script's identity, instance ID, and trace ID.

**Priority:** MUST  
**Test layer:** integration

## Acceptance Criteria Mapping

- A log entry produced by `platform.log` appears in structured output (OBS-01) with correct correlation IDs.

## Test Cases

### TC-LUA-13-01: log entry with INFO level
**Given:** A Lua script calling `platform.log("INFO", "Script starting", {})`.  
**When:** The script executes.  
**Then:** A structured log entry appears with `level = "INFO"`, `message = "Script starting"`.  
**Layer:** integration  
**Acceptance criterion mapped:** INFO level logging works.

### TC-LUA-13-02: log entry with WARN level
**Given:** A Lua script calling `platform.log("WARN", "Deprecation warning", {})`.  
**When:** The script executes.  
**Then:** A structured log entry appears with `level = "WARN"`.  
**Layer:** integration  
**Acceptance criterion mapped:** WARN level logging works.

### TC-LUA-13-03: log entry with ERROR level
**Given:** A Lua script calling `platform.log("ERROR", "Something failed", {})`.  
**When:** The script executes.  
**Then:** A structured log entry appears with `level = "ERROR"`.  
**Layer:** integration  
**Acceptance criterion mapped:** ERROR level logging works.

### TC-LUA-13-04: log entry with DEBUG level
**Given:** A Lua script calling `platform.log("DEBUG", "Detailed info", {})`.  
**When:** The script executes.  
**Then:** A structured log entry appears with `level = "DEBUG"` (if debug logging is enabled).  
**Layer:** integration  
**Acceptance criterion mapped:** DEBUG level logging works.

### TC-LUA-13-05: log entry includes instance_id
**Given:** A Lua script with `instance_id = "inst-123"` calling `platform.log("INFO", "test", {})`.  
**When:** The script executes.  
**Then:** The log entry includes `instance_id = "inst-123"`.  
**Layer:** integration  
**Acceptance criterion mapped:** Instance ID is included.

### TC-LUA-13-06: log entry includes trace_id
**Given:** A Lua script with `trace_id = "trace-abc-123"` calling `platform.log("INFO", "test", {})`.  
**When:** The script executes.  
**Then:** The log entry includes `trace_id = "trace-abc-123"`.  
**Layer:** integration  
**Acceptance criterion mapped:** Trace ID is included (from API-09).

### TC-LUA-13-07: log entry includes script_id
**Given:** A Lua script with `script_id = "script-001"` calling `platform.log("INFO", "test", {})`.  
**When:** The script executes.  
**Then:** The log entry includes `script_id = "script-001"`.  
**Layer:** integration  
**Acceptance criterion mapped:** Script ID is included.

### TC-LUA-13-08: log entry includes actor_id
**Given:** A Lua script executed with `actor_id = "user-456"` calling `platform.log("INFO", "test", {})`.  
**When:** The script executes.  
**Then:** The log entry includes `actor_id = "user-456"`.  
**Layer:** integration  
**Acceptance criterion mapped:** Actor ID is included.

### TC-LUA-13-09: log entry with context object
**Given:** A Lua script calling `platform.log("INFO", "Processing", {order_id = "ORD-123", amount = 99.99})`.  
**When:** The script executes.  
**Then:** The log entry includes context fields: `order_id = "ORD-123"`, `amount = 99.99`.  
**Layer:** integration  
**Acceptance criterion mapped:** Context is included.

### TC-LUA-13-10: log entry timestamp is recorded
**Given:** A Lua script calling `platform.log("INFO", "test", {})`.  
**When:** The script executes.  
**Then:** The log entry includes a `timestamp` field with ISO 8601 UTC time.  
**Layer:** integration  
**Acceptance criterion mapped:** Timestamp is recorded.

### TC-LUA-13-11: multiple log entries in sequence
**Given:** A Lua script calling:
- `platform.log("INFO", "Starting", {})`
- `platform.log("INFO", "Processing", {})`
- `platform.log("INFO", "Done", {})`

**When:** The script executes.  
**Then:** All three log entries appear in order in the structured log output.  
**Layer:** integration  
**Acceptance criterion mapped:** Multiple logs work.

### TC-LUA-13-12: log entry with empty context
**Given:** A Lua script calling `platform.log("INFO", "message", {})`.  
**When:** The script executes.  
**Then:** The log entry has an empty context (no additional fields).  
**Layer:** integration  
**Acceptance criterion mapped:** Empty context allowed.

### TC-LUA-13-13: log entry with nil context defaults to empty
**Given:** A Lua script calling `platform.log("INFO", "message", nil)` (no third argument).  
**When:** The script executes.  
**Then:** The log entry is recorded (nil context defaults to empty).  
**Layer:** integration  
**Acceptance criterion mapped:** Nil context handling.

### TC-LUA-13-14: capability requirement for logging
**Given:** A Lua script with capabilities `["variable:read"]` (no `audit:log`).  
**When:** The script calls `platform.log("INFO", "test", {})`.  
**Then:** A Lua error is raised with capability denial (see LUA-06).  
**Layer:** unit  
**Acceptance criterion mapped:** Capability check applies (cross-reference to LUA-06).

### TC-LUA-13-15: log message with special characters
**Given:** A Lua script calling `platform.log("INFO", "Msg: 'quote' \"double\" \\backslash", {})`.  
**When:** The script executes.  
**Then:** The log entry records the message with special characters preserved/escaped.  
**Layer:** integration  
**Acceptance criterion mapped:** Special characters handled.

### TC-LUA-13-16: log context with nested table
**Given:** A Lua script calling `platform.log("INFO", "nested", {user = {id = 123, name = "Alice"}})`.  
**When:** The script executes.  
**Then:** The log entry includes the nested context structure.  
**Layer:** integration  
**Acceptance criterion mapped:** Nested structures in context work.

## Test Data Factories

### Factory: Script with multiple log levels
```lua
return {
    __manifest__ = {
        capabilities = { "audit:log" },
        max_instructions = 100000,
        max_memory_bytes = 16777216,
        timeout_seconds = 30
    },
    function main(order_id)
        platform.log("DEBUG", "Script started", {order_id = order_id})
        platform.log("INFO", "Processing order", {order_id = order_id})
        
        -- Simulate some processing
        local result = {status = "success"}
        
        platform.log("INFO", "Order processed", {
            order_id = order_id,
            result = result.status
        })
        platform.log("DEBUG", "Script completed", {})
        
        return result
    end
}
```

### Factory: Script with detailed logging context
```lua
return {
    __manifest__ = {
        capabilities = { "audit:log", "service:call:api" },
        max_instructions = 100000,
        max_memory_bytes = 16777216,
        timeout_seconds = 30
    },
    function main(user_id)
        platform.log("INFO", "User action initiated", {
            user_id = user_id,
            timestamp = platform.now()
        })
        
        local api_response = platform.call_service("api", "GET", "/user/" .. user_id, {}, "")
        
        if api_response.error then
            platform.log("ERROR", "API call failed", {
                error = api_response.error,
                user_id = user_id
            })
            return nil
        end
        
        platform.log("INFO", "User retrieved successfully", {
            user_id = user_id,
            response_size = api_response.size
        })
        
        return api_response
    end
}
```

## Expected Outcomes

- **Pass:** Log entries with INFO, WARN, ERROR, DEBUG levels are recorded.
- **Pass:** Log entries include instance_id, trace_id, script_id, and actor_id.
- **Pass:** Context fields from the script are included in the log.
- **Pass:** Timestamps are recorded in ISO 8601 UTC format.
- **Pass:** Multiple log entries appear in order.
- **Pass:** Special characters and nested structures in context work.
- **Pass:** Capability requirement for logging is enforced.

## Traceability

- LUA-13 acceptance: TC-LUA-13-01 through TC-LUA-13-16.
- LUA-06 (capability checks): TC-LUA-13-14 (audit:log capability required).
- OBS-01 (structured logging): Log entries appear in OBS-01 output.
- API-09 (trace ID propagation): trace_id is included in log entry.
- WASM-12 (Wasm parity): Same logging semantics for Wasm.
