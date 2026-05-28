# Test Spec: LUA-11 — Variable Read/Write

**Requirement:** LUA-11 — `platform.read_variable(name)` MUST return the current value or `nil`. `platform.write_variable(name, value)` MUST stage a write; writes are applied atomically on script success and discarded on script failure.

**Priority:** MUST  
**Test layer:** integration

## Acceptance Criteria Mapping

- A failed script does not leave partial variable writes in instance state.
- A successful script's writes are visible to subsequent operations on the instance.

## Test Cases

### TC-LUA-11-01: read_variable returns current value
**Given:** An instance with variable `status = "pending"` and a Lua script calling `platform.read_variable("status")`.  
**When:** The script is executed.  
**Then:** The script receives the string `"pending"` as the return value.  
**Layer:** integration  
**Acceptance criterion mapped:** Read retrieves stored value.

### TC-LUA-11-02: read_variable returns nil for missing variable
**Given:** An instance with no variable named `missing_key` and a Lua script calling `platform.read_variable("missing_key")`.  
**When:** The script is executed.  
**Then:** The script receives `nil` as the return value.  
**Layer:** integration  
**Acceptance criterion mapped:** Missing read returns nil.

### TC-LUA-11-03: write_variable stages a write
**Given:** An instance with variable `count = 5` and a Lua script calling `platform.write_variable("count", 10)`.  
**When:** The script is executed and completes successfully.  
**Then:** The instance variable `count` is updated to `10` in the instance state.  
**Layer:** integration  
**Acceptance criterion mapped:** Successful write applies.

### TC-LUA-11-04: write_variable discarded on script failure
**Given:** An instance with variable `count = 5` and a Lua script that calls `platform.write_variable("count", 10)` then calls `platform.fail("test failure")`.  
**When:** The script is executed.  
**Then:** The script fails with SCRIPT_FAILED event. The instance variable `count` remains `5` (write was discarded).  
**Layer:** integration  
**Acceptance criterion mapped:** Failed script's writes not applied.

### TC-LUA-11-05: write_variable discarded on runtime error
**Given:** An instance with variable `value = "original"` and a Lua script that calls `platform.write_variable("value", "new")` then hits a Lua error (`1 / 0` or nil access).  
**When:** The script is executed.  
**Then:** The script fails with SCRIPT_ERROR event. The instance variable `value` remains `"original"`.  
**Layer:** integration  
**Acceptance criterion mapped:** Runtime error's writes not applied.

### TC-LUA-11-06: multiple writes to same key, last write wins
**Given:** A Lua script calling `platform.write_variable("status", "a")`, then `platform.write_variable("status", "b")`, then `platform.write_variable("status", "c")`.  
**When:** The script completes successfully.  
**Then:** The instance variable `status` is set to `"c"` (final write).  
**Layer:** integration  
**Acceptance criterion mapped:** Last write is applied.

### TC-LUA-11-07: script can read and modify same variable
**Given:** An instance with variable `count = 5` and a Lua script: `local c = platform.read_variable("count"); platform.write_variable("count", c + 1)`.  
**When:** The script is executed.  
**Then:** The variable `count` is updated to `6`.  
**Layer:** integration  
**Acceptance criterion mapped:** Read-modify-write pattern works.

### TC-LUA-11-08: multiple different variables can be written
**Given:** A Lua script calling:
- `platform.write_variable("a", 1)`
- `platform.write_variable("b", 2)`
- `platform.write_variable("c", 3)`

**When:** The script completes successfully.  
**Then:** All three variables are updated: `a=1`, `b=2`, `c=3`.  
**Layer:** integration  
**Acceptance criterion mapped:** Multiple writes succeed.

### TC-LUA-11-09: write with nil value clears the variable
**Given:** An instance with variable `temp = "value"` and a Lua script calling `platform.write_variable("temp", nil)`.  
**When:** The script completes successfully.  
**Then:** The variable `temp` is cleared (set to nil or removed from the instance).  
**Layer:** integration  
**Acceptance criterion mapped:** Nil write clears variable.

### TC-LUA-11-10: write variable with complex table value
**Given:** A Lua script calling `platform.write_variable("data", {x = 10, y = 20, z = {nested = true}})`.  
**When:** The script completes successfully.  
**Then:** The instance variable `data` is set to a structured value containing the nested table.  
**Layer:** integration  
**Acceptance criterion mapped:** Complex values serialized and stored.

### TC-LUA-11-11: write_variable returns nil (no result)
**Given:** A Lua script storing the result: `local result = platform.write_variable("key", "value")`.  
**When:** The script executes.  
**Then:** `result` is `nil` (write_variable returns nothing).  
**Layer:** unit  
**Acceptance criterion mapped:** Write return value is nil.

### TC-LUA-11-12: capability requirements for read/write
**Given:** A Lua script with capabilities `["variable:read"]` only (no write).  
**When:** The script calls `platform.write_variable("key", "value")`.  
**Then:** A Lua error is raised with capability denial (see LUA-06).  
**Layer:** unit  
**Acceptance criterion mapped:** Capability checks apply (cross-reference to LUA-06).

### TC-LUA-11-13: write ordering with concurrent scripts
**Given:** Two instances both executing scripts that write to their own variables simultaneously. Each script writes to `status = "done"`.  
**When:** Both scripts complete.  
**Then:** Each instance has `status = "done"` (writes are isolated per instance).  
**Layer:** integration  
**Acceptance criterion mapped:** Writes are per-instance.

### TC-LUA-11-14: atomic commit on success
**Given:** A Lua script that writes 5 variables then completes. A concurrent reader queries the instance between write staging and commit.  
**When:** The writes are staged but not yet committed (still in pending buffer).  
**Then:** The concurrent reader does not see the staged writes (they are not visible until commit).  
**Layer:** integration  
**Acceptance criterion mapped:** Writes are transactional (all-or-nothing).

### TC-LUA-11-15: variable key length limit
**Given:** A Lua script attempting to write a variable with a key longer than 255 characters.  
**When:** The script calls `platform.write_variable(very_long_key, value)`.  
**Then:** The call fails with a structured error or the key is truncated per platform policy.  
**Layer:** integration  
**Acceptance criterion mapped:** Key constraints enforced.

### TC-LUA-11-16: variable value size limit
**Given:** A Lua script attempting to write a 100 MB string to a variable (with memory limit allowing).  
**When:** The script calls `platform.write_variable("big", huge_string)`.  
**Then:** The call fails with a structured error if the serialized value exceeds the platform's maximum.  
**Layer:** integration  
**Acceptance criterion mapped:** Value size constraints enforced.

## Test Data Factories

### Factory: Successful read/write script
```lua
return {
    __manifest__ = {
        capabilities = { "variable:read", "variable:write" },
        max_instructions = 100000,
        max_memory_bytes = 16777216,
        timeout_seconds = 30
    },
    function main(initial_value)
        local current = platform.read_variable("status") or initial_value
        platform.write_variable("previous", current)
        platform.write_variable("status", "processed")
        return current
    end
}
```

### Factory: Script that fails after write
```lua
return {
    __manifest__ = {
        capabilities = { "variable:read", "variable:write" },
        max_instructions = 100000,
        max_memory_bytes = 16777216,
        timeout_seconds = 30
    },
    function main()
        platform.write_variable("attempt", 1)
        platform.fail("intentional failure")
    end
}
```

### Factory: Script with multiple variable updates
```lua
return {
    __manifest__ = {
        capabilities = { "variable:write" },
        max_instructions = 100000,
        max_memory_bytes = 16777216,
        timeout_seconds = 30
    },
    function main()
        platform.write_variable("step", 1)
        platform.write_variable("status", "running")
        platform.write_variable("started_at", platform.now())
        platform.write_variable("data", {count = 0})
        return true
    end
}
```

## Expected Outcomes

- **Pass:** Read returns stored value or nil.
- **Pass:** Writes are staged and applied atomically on success.
- **Pass:** Writes are discarded on failure (explicit or runtime error).
- **Pass:** Multiple writes and read-modify-write patterns work.
- **Pass:** Complex values (tables) are handled.
- **Pass:** Writes are per-instance and transactional.

## Traceability

- LUA-11 acceptance: TC-LUA-11-01 through TC-LUA-11-16.
- LUA-06 (capability checks): TC-LUA-11-12 (read/write capability required).
- EE-09 (variable merge logic): Instance state is updated from writes.
- DB-03 (transactional integrity): Writes are atomic.
