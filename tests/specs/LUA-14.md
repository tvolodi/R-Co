# Test Spec: LUA-14 — Time Source

**Requirement:** LUA-14 — `platform.now()` MUST return the platform's authoritative time as ISO 8601 UTC. Lua's `os.time` MUST NOT be available.

**Priority:** MUST  
**Test layer:** unit, integration

## Acceptance Criteria Mapping

- `os.time` is `nil` in the sandbox.
- `platform.now()` returns a valid ISO 8601 UTC timestamp.

## Test Cases

### TC-LUA-14-01: platform.now returns valid ISO 8601 UTC
**Given:** A Lua script calling `platform.now()`.  
**When:** The script executes.  
**Then:** The script receives a string in the format `YYYY-MM-DDTHH:MM:SS.sssZ` (ISO 8601 UTC), e.g. `"2026-05-28T14:30:45.123Z"`.  
**Layer:** unit  
**Acceptance criterion mapped:** Format is ISO 8601 UTC.

### TC-LUA-14-02: platform.now returns valid date components
**Given:** The result of `platform.now()` is parsed as ISO 8601.  
**When:** The parsed components are validated.  
**Then:** All components (year, month, day, hour, minute, second, millisecond) are valid (e.g., month 1-12, day 1-31, hour 0-23).  
**Layer:** unit  
**Acceptance criterion mapped:** Timestamp is valid.

### TC-LUA-14-03: platform.now is in UTC
**Given:** A Lua script calling `platform.now()` and comparing with a known UTC time.  
**When:** The local system time is in a non-UTC timezone (e.g., EST).  
**Then:** The returned time is in UTC, not local time (e.g., returns Z suffix, not -05:00).  
**Layer:** unit  
**Acceptance criterion mapped:** Time is UTC, not local.

### TC-LUA-14-04: os.time is nil
**Given:** A Lua script attempting to access `os.time`.  
**When:** The script executes `local t = os.time`.  
**Then:** `t` is `nil` (os.time is not available).  
**Layer:** unit  
**Acceptance criterion mapped:** os.time removed from sandbox.

### TC-LUA-14-05: os.date is nil
**Given:** A Lua script attempting to access `os.date`.  
**When:** The script executes `local d = os.date`.  
**Then:** `d` is `nil` (os.date is not available).  
**Layer:** unit  
**Acceptance criterion mapped:** os.date removed from sandbox.

### TC-LUA-14-06: os.clock is nil
**Given:** A Lua script attempting to access `os.clock`.  
**When:** The script executes `local c = os.clock`.  
**Then:** `c` is `nil` (os.clock is not available).  
**Layer:** unit  
**Acceptance criterion mapped:** os.clock removed from sandbox.

### TC-LUA-14-07: multiple calls to platform.now return increasing times
**Given:** A Lua script calling `platform.now()` three times in quick succession.  
**When:** The script executes and stores the three results: `t1`, `t2`, `t3`.  
**Then:** `t1 <= t2 <= t3` (time progresses monotonically, at least within millisecond precision).  
**Layer:** unit  
**Acceptance criterion mapped:** Time is monotonic.

### TC-LUA-14-08: platform.now requires no capability
**Given:** A Lua script with capabilities `[]` (empty).  
**When:** The script calls `platform.now()`.  
**Then:** The call succeeds (no capability error); time is returned.  
**Layer:** unit  
**Acceptance criterion mapped:** Time source has no capability requirement.

### TC-LUA-14-09: platform.now returns millisecond precision
**Given:** Two rapid calls to `platform.now()` within the same second.  
**When:** Both times are parsed.  
**Then:** The millisecond component may differ between calls (sub-second precision is available).  
**Layer:** unit  
**Acceptance criterion mapped:** Millisecond precision available.

### TC-LUA-14-10: platform.now in event timestamp
**Given:** A Lua script that logs using `platform.log("INFO", "Event", {time = platform.now()})`.  
**When:** The script executes and the log is stored.  
**Then:** The log entry's timestamp (from platform.now) matches the platform's recorded timestamp (approximate match within milliseconds).  
**Layer:** integration  
**Acceptance criterion mapped:** Time is consistent across platform.

### TC-LUA-14-11: platform.fail uses current time
**Given:** A Lua script calling `platform.fail("reason", {time = platform.now()})`.  
**When:** The script terminates with failure.  
**Then:** The SCRIPT_FAILED event timestamp is close to the provided time (within milliseconds).  
**Layer:** integration  
**Acceptance criterion mapped:** Script-provided time aligns with platform time.

### TC-LUA-14-12: script cannot modify os module
**Given:** A Lua script attempting to add a function to `os`: `os.custom = function() return "hacked" end`.  
**When:** The script executes.  
**Then:** The assignment either fails (sandbox prevents modification) or is local to this script and doesn't affect the sandbox.  
**Layer:** unit  
**Acceptance criterion mapped:** Sandbox is not modified by script.

### TC-LUA-14-13: platform.now in conditional logic
**Given:** A Lua script using `platform.now()` as part of conditional logic: `if platform.now() > cutoff then ... end`.  
**When:** The script executes.  
**Then:** String comparison of ISO 8601 times works correctly (lexicographic order).  
**Layer:** unit  
**Acceptance criterion mapped:** Time strings are comparable.

### TC-LUA-14-14: Lua math.time is not available
**Given:** A Lua script attempting to call `math.time`.  
**When:** The script executes `local t = math.time`.  
**Then:** `t` is `nil` (no such function in the math module).  
**Layer:** unit  
**Acceptance criterion mapped:** No backdoor time function.

### TC-LUA-14-15: platform.now with very large call count
**Given:** A Lua script calling `platform.now()` 10,000 times in a loop (within instruction limit).  
**When:** The script executes.  
**Then:** All calls succeed and return timestamps. The loop may hit the instruction limit, but not due to time calls.  
**Layer:** unit  
**Acceptance criterion mapped:** Time calls are lightweight.

### TC-LUA-14-16: platform.now result is read-only string
**Given:** A Lua script calling `local t = platform.now()` then attempting to modify: `t[1] = "X"`.  
**When:** The script executes.  
**Then:** The modification fails (strings are immutable in Lua, as expected).  
**Layer:** unit  
**Acceptance criterion mapped:** Returned time is string (immutable).

## Test Data Factories

### Factory: Script using platform.now
```lua
return {
    __manifest__ = {
        capabilities = { "audit:log" },
        max_instructions = 100000,
        max_memory_bytes = 16777216,
        timeout_seconds = 30
    },
    function main()
        local start_time = platform.now()
        
        -- Simulate some work
        local sum = 0
        for i = 1, 1000 do
            sum = sum + i
        end
        
        local end_time = platform.now()
        
        platform.log("INFO", "Computation completed", {
            start = start_time,
            end = end_time
        })
        
        return {start = start_time, end = end_time, result = sum}
    end
}
```

### Factory: Script checking for time availability
```lua
return {
    __manifest__ = {
        capabilities = {},
        max_instructions = 10000,
        max_memory_bytes = 1000000,
        timeout_seconds = 30
    },
    function main()
        -- Verify platform.now exists
        assert(platform.now ~= nil, "platform.now not available")
        
        -- Verify os.time does not exist
        assert(os.time == nil, "os.time should not be available")
        
        -- Call platform.now and verify format
        local now = platform.now()
        assert(type(now) == "string", "platform.now must return string")
        assert(string.match(now, "%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d%d%dZ"), "Invalid ISO 8601 format")
        
        return true
    end
}
```

## Expected Outcomes

- **Pass:** `platform.now()` returns ISO 8601 UTC timestamp.
- **Pass:** `os.time`, `os.date`, `os.clock` are nil (not available).
- **Pass:** Time is monotonically increasing.
- **Pass:** No capability required for `platform.now()`.
- **Pass:** Millisecond precision available.
- **Pass:** Time is consistent across platform operations.

## Traceability

- LUA-14 acceptance: TC-LUA-14-01 through TC-LUA-14-16.
- LUA-03 (stdlib restrictions): os module not loaded, time functions removed.
- LUA-13 (logging): Uses platform.now for timestamp context.
- API-09 (trace ID propagation): Timestamps are part of trace context.
- DSL-09 (equivalent time source in DSL tier): Same time source for consistency.
