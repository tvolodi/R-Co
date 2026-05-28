# Test Spec: LUA-07 — Capability Manifest Validation

**Requirement:** LUA-07 — On script load, the platform MUST validate the script's manifest against the script artifact. Manifest hash MUST be recorded with each execution.

**Priority:** MUST  
**Test layer:** unit, integration

## Acceptance Criteria Mapping

- A modified manifest without re-registration is rejected at load time.
- The manifest hash appears in the execution audit record.

## Test Cases

### TC-LUA-07-01: valid manifest loads successfully
**Given:** A script artifact with a valid manifest declaring capabilities `["variable:read"]` within safe limits (instructions: 100k, memory: 16MB, timeout: 30s).  
**When:** The script is loaded for execution.  
**Then:** The manifest is validated and the script proceeds to execution (no rejection).  
**Layer:** unit  
**Acceptance criterion mapped:** Valid manifest passes validation.

### TC-LUA-07-02: manifest with undeclared capability is rejected
**Given:** A script manifest declaring capability `["service:call:unknown_service"]` but the script artifact is not registered with that capability.  
**When:** The script is loaded.  
**Then:** Manifest validation fails with error `UnauthorizedCapability`.  
**Layer:** unit  
**Acceptance criterion mapped:** Undeclared capability rejected at load time.

### TC-LUA-07-03: manifest instruction limit below minimum is rejected
**Given:** A script manifest with `max_instructions = 500` (below minimum of 1000).  
**When:** The manifest is validated.  
**Then:** Validation fails with error `InstructionLimitTooLow`.  
**Layer:** unit  
**Acceptance criterion mapped:** Low instruction limit rejected.

### TC-LUA-07-04: manifest instruction limit above maximum is rejected
**Given:** A script manifest with `max_instructions = 50_000_000` (above maximum of 10M).  
**When:** The manifest is validated.  
**Then:** Validation fails with error `InstructionLimitTooHigh`.  
**Layer:** unit  
**Acceptance criterion mapped:** High instruction limit rejected.

### TC-LUA-07-05: manifest instruction limit at valid boundaries passes
**Given:** Script manifests with `max_instructions = 1000` and another with `max_instructions = 10_000_000`.  
**When:** Both manifests are validated.  
**Then:** Both pass validation (inclusive boundaries).  
**Layer:** unit  
**Acceptance criterion mapped:** Boundary values are valid.

### TC-LUA-07-06: manifest memory limit below minimum is rejected
**Given:** A script manifest with `max_memory_bytes = 500_000` (below minimum of 1MB = 1_048_576).  
**When:** The manifest is validated.  
**Then:** Validation fails with error `MemoryLimitTooLow`.  
**Layer:** unit  
**Acceptance criterion mapped:** Low memory limit rejected.

### TC-LUA-07-07: manifest memory limit above maximum is rejected
**Given:** A script manifest with `max_memory_bytes = 500_000_000` (above maximum of 256MB = 268_435_456).  
**When:** The manifest is validated.  
**Then:** Validation fails with error `MemoryLimitTooHigh`.  
**Layer:** unit  
**Acceptance criterion mapped:** High memory limit rejected.

### TC-LUA-07-08: manifest timeout below minimum is rejected
**Given:** A script manifest with `timeout_seconds = 0` (below minimum of 1).  
**When:** The manifest is validated.  
**Then:** Validation fails with error `TimeoutTooLow`.  
**Layer:** unit  
**Acceptance criterion mapped:** Low timeout rejected.

### TC-LUA-07-09: manifest timeout above maximum is rejected
**Given:** A script manifest with `timeout_seconds = 7200` (above maximum of 3600 seconds).  
**When:** The manifest is validated.  
**Then:** Validation fails with error `TimeoutTooHigh`.  
**Layer:** unit  
**Acceptance criterion mapped:** High timeout rejected.

### TC-LUA-07-10: manifest timeout at valid boundaries passes
**Given:** Script manifests with `timeout_seconds = 1` and another with `timeout_seconds = 3600`.  
**When:** Both manifests are validated.  
**Then:** Both pass validation (inclusive boundaries).  
**Layer:** unit  
**Acceptance criterion mapped:** Timeout boundaries are valid.

### TC-LUA-07-11: manifest hash is computed and recorded
**Given:** A script artifact with a specific manifest.  
**When:** The manifest is validated and the script executes.  
**Then:** The execution record includes a `manifest_hash` field containing the SHA-256 hash of the manifest.  
**Layer:** integration  
**Acceptance criterion mapped:** Hash is recorded with execution.

### TC-LUA-07-12: manifest hash mismatch is detected
**Given:** A script artifact that was previously registered with manifest hash H1. The manifest content is now modified (different capabilities, limits, or declaration order) without re-registration.  
**When:** The script is loaded with the new manifest.  
**Then:** Validation fails with error `ManifestHashMismatch` because the artifact hash no longer matches the recorded hash.  
**Layer:** integration  
**Acceptance criterion mapped:** Tampering detected via hash mismatch.

### TC-LUA-07-13: manifests with same content produce identical hashes
**Given:** Two script artifacts with logically identical manifests (same capabilities, limits, and canonical form).  
**When:** Both manifests are validated and hashed.  
**Then:** Both produce the same SHA-256 hash.  
**Layer:** unit  
**Acceptance criterion mapped:** Hash is deterministic.

### TC-LUA-07-14: manifest with additional capabilities beyond granted set is rejected
**Given:** A script manifest declaring capabilities `["variable:read", "service:call:billing"]` but the script artifact is only registered with `["variable:read"]`.  
**When:** The manifest is validated.  
**Then:** Validation fails because `service:call:billing` is undeclared.  
**Layer:** unit  
**Acceptance criterion mapped:** Superset of capabilities rejected.

### TC-LUA-07-15: empty capabilities manifest is valid
**Given:** A script manifest with an empty capabilities list `[]` (script uses only platform.now and platform.fail).  
**When:** The manifest is validated.  
**Then:** Validation passes (no capability is required).  
**Layer:** unit  
**Acceptance criterion mapped:** Empty capabilities allowed.

### TC-LUA-07-16: malformed manifest is rejected
**Given:** A script with a manifest field containing invalid JSON or missing required fields.  
**When:** The manifest is parsed and validated.  
**Then:** Validation fails with error `MalformedManifest`.  
**Layer:** unit  
**Acceptance criterion mapped:** Structural validation enforced.

## Test Data Factories

### Factory: Create valid manifest
```zig
fn createValidManifest(allocator: std.mem.Allocator, caps: []const []const u8) !ScriptManifest {
    return ScriptManifest{
        .capabilities = try allocator.dupe([]const u8, caps),
        .max_instructions = 100_000,
        .max_memory_bytes = 16_777_216,  // 16 MB
        .timeout_seconds = 30,
        .manifest_hash = try computeHash(caps, 100_000, 16_777_216, 30),
    };
}
```

### Factory: Compute manifest hash
```zig
fn computeManifestHash(
    allocator: std.mem.Allocator,
    capabilities: []const []const u8,
    max_instructions: u64,
    max_memory_bytes: u64,
    timeout_seconds: u32,
) ![32]u8 {
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    
    // Canonical form: sorted capabilities, then numeric limits
    var sorted_caps = try allocator.alloc([]const u8, capabilities.len);
    defer allocator.free(sorted_caps);
    std.mem.copy([]const u8, sorted_caps, capabilities);
    std.sort.insertion([]const u8, sorted_caps, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    
    for (sorted_caps) |cap| {
        sha.update(cap);
        sha.update("\0");  // Null separator
    }
    sha.update("\x00");  // Field separator
    sha.update(std.fmt.bufPrint(..., "{}", .{max_instructions}));
    sha.update("\x00");
    sha.update(std.fmt.bufPrint(..., "{}", .{max_memory_bytes}));
    sha.update("\x00");
    sha.update(std.fmt.bufPrint(..., "{}", .{timeout_seconds}));
    
    var hash: [32]u8 = undefined;
    sha.final(&hash);
    return hash;
}
```

### Factory: Script with capabilities in manifest
```lua
return {
    __manifest__ = {
        capabilities = { "variable:read", "variable:write" },
        max_instructions = 100000,
        max_memory_bytes = 16777216,
        timeout_seconds = 30
    },
    function main(x)
        local val = platform.read_variable("status")
        platform.write_variable("processed", true)
        return val
    end
}
```

## Expected Outcomes

- **Pass:** Valid manifest with all fields within safe ranges is accepted.
- **Pass:** Manifest with invalid capabilities, limits, or format is rejected with specific error.
- **Pass:** Manifest hash is computed deterministically and matches stored hash.
- **Pass:** Hash mismatch (tampering) is detected at load time.
- **Pass:** All 6 manifest validation checks (capabilities, instruction limit, memory limit, timeout, hash, format) function correctly.

## Traceability

- LUA-07 acceptance: TC-LUA-07-01 through TC-LUA-07-16.
- LUA-06 (capability checks): TC-LUA-07-02, TC-LUA-07-14 (manifest declares which capabilities are checked).
- REPO-05 through REPO-07 (artifact repository): Manifest hash recorded in artifact metadata.
- EE-10 (instance error handling): Manifest validation failure treated as structured error.
