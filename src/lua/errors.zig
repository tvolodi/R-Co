//! Lua execution error types and conversion utilities.

pub const LuaError = error{
    LuaAllocFailed,           // lua_newstate returned null
    BytecodeNotAllowed,       // Input starts with Lua bytecode magic
    CompileError,             // luaL_loadstring failed
    RuntimeError,             // lua_pcall failed (includes capability errors)
    CapabilityDenied,         // Host function called without permission
    TypeError,                // Return value wrong type for context
    InvalidArgument,          // Invalid argument to host function
    DatabaseError,            // Error accessing database
    UnknownEventType,         // Event type not in registry
};

/// Map Lua error types to HTTP status codes (for API layer).
pub fn statusCodeFromError(err: LuaError) u16 {
    return switch (err) {
        error.CapabilityDenied => 403,
        error.TypeError => 422,
        error.InvalidArgument => 400,
        error.BytecodeNotAllowed => 422,
        error.CompileError => 422,
        error.RuntimeError => 500,
        error.LuaAllocFailed => 503,
        error.DatabaseError => 503,
        error.UnknownEventType => 400,
    };
}

/// Provide a human-readable error description.
pub fn errorDescription(err: LuaError) []const u8 {
    return switch (err) {
        error.LuaAllocFailed => "Failed to allocate Lua state",
        error.BytecodeNotAllowed => "Bytecode is not allowed; only source text scripts are permitted",
        error.CompileError => "Script compilation error",
        error.RuntimeError => "Script runtime error",
        error.CapabilityDenied => "Capability check failed for host API function",
        error.TypeError => "Return value type mismatch",
        error.InvalidArgument => "Invalid argument to host function",
        error.DatabaseError => "Database error during script execution",
        error.UnknownEventType => "Unknown event type",
    };
}
