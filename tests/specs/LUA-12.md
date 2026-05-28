# Test Spec: LUA-12 — Service Call

**Requirement:** LUA-12 — `platform.call_service(service_id, payload)` MUST invoke a registered service synchronously. The response MUST be returned as a Lua table. Service call failures MUST return a structured error, not raise a Lua error.

**Priority:** MUST  
**Test layer:** integration

## Acceptance Criteria Mapping

- Calling a registered service round-trips through the host and returns the response as a Lua table.
- A service call failure returns a structured error table the script can inspect.

## Test Cases

### TC-LUA-12-01: successful service call returns response as table
**Given:** A Lua script with registered service `payment_svc` at `http://localhost:8080/api` and a script calling `platform.call_service("payment_svc", "GET", "/status", {}, "")`.  
**When:** The service is reachable and returns `{"status": "ready", "version": "1.0"}`.  
**Then:** The script receives a Lua table `{status = "ready", version = "1.0"}`.  
**Layer:** integration  
**Acceptance criterion mapped:** Service call round-trips as Lua table.

### TC-LUA-12-02: service call with POST method and body
**Given:** A Lua script calling `platform.call_service("api", "POST", "/create", {}, '{"name":"test"}')`.  
**When:** The service accepts the POST and returns `{"id": 123, "created": true}`.  
**Then:** The script receives the response as a Lua table.  
**Layer:** integration  
**Acceptance criterion mapped:** POST with body works.

### TC-LUA-12-03: service call with headers
**Given:** A Lua script calling `platform.call_service("api", "GET", "/data", {Authorization = "Bearer token123"}, "")`.  
**When:** The service receives and validates the header.  
**Then:** The call succeeds and returns the expected response.  
**Layer:** integration  
**Acceptance criterion mapped:** Headers passed to service.

### TC-LUA-12-04: service not found returns error table
**Given:** A Lua script calling `platform.call_service("unknown_service", "GET", "/", {}, "")`.  
**When:** The service is not registered.  
**Then:** The script receives a structured error table (not a Lua error), e.g. `{error = "Service not found", service_id = "unknown_service"}`.  
**Layer:** integration  
**Acceptance criterion mapped:** Service not found is structured error.

### TC-LUA-12-05: HTTP error response returns structured error
**Given:** A Lua script calling `platform.call_service("api", "GET", "/missing", {}, "")`.  
**When:** The service returns HTTP 404.  
**Then:** The script receives a structured error table: `{status_code = 404, error = "Not found"}` (not a Lua error).  
**Layer:** integration  
**Acceptance criterion mapped:** HTTP errors returned as data.

### TC-LUA-12-06: service timeout returns structured error
**Given:** A Lua script with `timeout_seconds = 1` calling a service that hangs for 5 seconds.  
**When:** The service call exceeds the script timeout.  
**Then:** The script receives a structured error table: `{error = "Service call timeout"}`.  
**Layer:** integration  
**Acceptance criterion mapped:** Timeout is structured error.

### TC-LUA-12-07: capability requirement for service call
**Given:** A Lua script with capabilities `["variable:read"]` (no `service:call:api`).  
**When:** The script calls `platform.call_service("api", "GET", "/", {}, "")`.  
**Then:** A Lua error is raised with capability denial (see LUA-06).  
**Layer:** unit  
**Acceptance criterion mapped:** Capability check applies (cross-reference to LUA-06).

### TC-LUA-12-08: service call with JSON response
**Given:** A Lua script calling a service that returns JSON `{"items": [{"id": 1, "name": "A"}, {"id": 2, "name": "B"}]}`.  
**When:** The service returns the JSON.  
**Then:** The script receives a Lua table with nested tables: `{items = {[1] = {id = 1, name = "A"}, [2] = {id = 2, name = "B"}}}`.  
**Layer:** integration  
**Acceptance criterion mapped:** Complex JSON structures work.

### TC-LUA-12-09: service call with plain text response
**Given:** A Lua script calling a service that returns plain text `"Hello, World!"` with Content-Type `text/plain`.  
**When:** The service returns the text.  
**Then:** The script receives the response (implementation-dependent: as a string field or wrapped in a table).  
**Layer:** integration  
**Acceptance criterion mapped:** Non-JSON responses handled.

### TC-LUA-12-10: multiple sequential service calls
**Given:** A Lua script calling `platform.call_service("api", ...)` twice with different paths.  
**When:** Both services are reachable.  
**Then:** Both calls complete and the script receives two responses in sequence.  
**Layer:** integration  
**Acceptance criterion mapped:** Multiple calls work.

### TC-LUA-12-11: service call response does not raise Lua error on HTTP error
**Given:** A Lua script calling a service that returns HTTP 500 (internal server error).  
**When:** The error is returned.  
**Then:** The script does NOT raise a Lua error; instead, it receives a structured error table that the script can inspect with `if response.error then ... end`.  
**Layer:** integration  
**Acceptance criterion mapped:** HTTP errors are data, not exceptions.

### TC-LUA-12-12: service call with query parameters
**Given:** A Lua script calling `platform.call_service("api", "GET", "/search?q=test&limit=10", {}, "")`.  
**When:** The service is called.  
**Then:** The query string is passed to the service endpoint.  
**Layer:** integration  
**Acceptance criterion mapped:** Query strings in path work.

### TC-LUA-12-13: service response included in event log
**Given:** A Lua script that makes a service call and completes. The instance event log is queried.  
**When:** The event log is read.  
**Then:** A SCRIPT_SERVICE_CALL event (or equivalent) may be recorded with the service_id, request, and response summary.  
**Layer:** integration  
**Acceptance criterion mapped:** Service calls are audited.

### TC-LUA-12-14: service call with empty response
**Given:** A Lua script calling a service that returns HTTP 204 (No Content).  
**When:** The service returns empty.  
**Then:** The script receives either nil or an empty table `{}` (implementation-dependent).  
**Layer:** integration  
**Acceptance criterion mapped:** Empty responses handled.

### TC-LUA-12-15: service call network error returns structured error
**Given:** A Lua script calling a service at an unreachable address (e.g., `http://invalid.local:9999`).  
**When:** The network fails.  
**Then:** The script receives a structured error table: `{error = "Connection refused"}` (not a Lua error or host crash).  
**Layer:** integration  
**Acceptance criterion mapped:** Network errors are structured.

## Test Data Factories

### Factory: Successful service call script
```lua
return {
    __manifest__ = {
        capabilities = { "service:call:payment_svc" },
        max_instructions = 100000,
        max_memory_bytes = 16777216,
        timeout_seconds = 30
    },
    function main(order_id)
        local response = platform.call_service(
            "payment_svc",
            "POST",
            "/charge",
            {["Content-Type"] = "application/json"},
            '{"order_id": "' .. order_id .. '"}'
        )
        if response.error then
            platform.fail("Payment failed", response)
        end
        return response.transaction_id
    end
}
```

### Factory: Service call with error handling
```lua
return {
    __manifest__ = {
        capabilities = { "service:call:api", "variable:write" },
        max_instructions = 100000,
        max_memory_bytes = 16777216,
        timeout_seconds = 30
    },
    function main()
        local result = platform.call_service("api", "GET", "/data", {}, "")
        if result.error then
            platform.write_variable("api_error", result.error)
            return nil
        end
        platform.write_variable("api_response", result)
        return result
    end
}
```

### Factory: Multiple service calls
```lua
return {
    __manifest__ = {
        capabilities = { "service:call:api1", "service:call:api2" },
        max_instructions = 100000,
        max_memory_bytes = 16777216,
        timeout_seconds = 30
    },
    function main()
        local resp1 = platform.call_service("api1", "GET", "/users", {}, "")
        local resp2 = platform.call_service("api2", "GET", "/products", {}, "")
        return {users = resp1, products = resp2}
    end
}
```

## Expected Outcomes

- **Pass:** Successful service calls return response as Lua table.
- **Pass:** Service call failures return structured error tables (not Lua errors).
- **Pass:** HTTP errors, timeouts, network errors all return structured errors.
- **Pass:** Capability requirement for specific service_id is enforced.
- **Pass:** Complex JSON responses are properly converted to Lua tables.
- **Pass:** Multiple sequential calls work.

## Traceability

- LUA-12 acceptance: TC-LUA-12-01 through TC-LUA-12-15.
- LUA-06 (capability checks): TC-LUA-12-07 (service:call capability required).
- REPO-07 (service catalog): Service lookup and invocation.
- EE-10 (instance error handling): Service failures trigger error handling policy.
- WASM-12 (Wasm parity): Same service call semantics for Wasm.
