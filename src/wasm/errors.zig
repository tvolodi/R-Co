//! Wasm execution error types and conversion utilities.

pub const WasmError = error{
    WasmEngineInitFailed,       // wasm_engine_new returned null
    WasmStoreInitFailed,        // wasmtime_store_new returned null
    WasmModuleLoadFailed,       // wasmtime_module_new failed
    WasmInstanceCreationFailed, // wasmtime_instance_new failed or trap during instantiation
    ExecutionTrap,              // Wasm trap during execution (out of bounds, divide by zero, etc.)
    FuelExhausted,              // Instruction limit reached
    TimeoutExceeded,            // Wall-clock timeout exceeded
    CapabilityDenied,           // Module attempted to call unauthorized import
    PointerOutOfBounds,         // Memory pointer validation failed
    NullPointer,                // Null pointer dereference attempt
    MemoryAccessViolation,      // Memory access error
    MemoryCapExceeded,          // Linear memory growth beyond configured cap
    InvalidImport,              // Module imports unauthorized function
    FilesystemAccessNotAllowed, // Module attempted WASI filesystem access
    MissingInitExport,          // Module missing init() export
    MissingExecuteExport,       // Module missing execute() export
    MissingDeinitExport,        // Module missing deinit() export
    MissingGetCapabilitiesExport, // Module missing get_capabilities() export
    InvalidInitSignature,       // init() has wrong signature
    InvalidExecuteSignature,    // execute() has wrong signature
    InvalidDeinitSignature,     // deinit() has wrong signature
    InvalidGetCapabilitiesSignature, // get_capabilities() has wrong signature
    CapabilityParseError,       // Failed to parse capability JSON
    UnauthorizedCapability,     // Module declared unauthorized capability
    CompilationFailed,          // Zig-to-Wasm compilation failed
    InstancePoolExhausted,      // No available pooled instances
    InvalidFuelBudget,          // Fuel limit out of range
    FuelLimitOutOfRange,        // Fuel limit outside acceptable range
    MemoryGrowthFailed,         // wasmtime_memory_grow failed
    InitFailed,                 // Module init() returned non-zero
    DeinitFailed,               // Module deinit() returned non-zero
    ModuleNotFound,             // Module not registered
    PoolNotFound,               // Instance pool not found
    DatabaseError,              // Database error
    InvalidArgument,            // Invalid argument
    AllocationFailed,           // Memory allocation failed
};

/// Map Wasm error types to HTTP status codes (for API layer).
pub fn statusCodeFromError(err: WasmError) u16 {
    return switch (err) {
        error.CapabilityDenied => 403,
        error.UnauthorizedCapability => 403,
        error.FilesystemAccessNotAllowed => 403,
        error.PointerOutOfBounds => 400,
        error.InvalidArgument => 400,
        error.InvalidInitSignature => 422,
        error.InvalidExecuteSignature => 422,
        error.InvalidDeinitSignature => 422,
        error.InvalidGetCapabilitiesSignature => 422,
        error.CapabilityParseError => 422,
        error.TimeoutExceeded => 504,
        error.FuelExhausted => 504,
        error.ExecutionTrap => 500,
        error.InitFailed => 500,
        error.DeinitFailed => 500,
        error.MemoryAccessViolation => 500,
        error.MemoryCapExceeded => 500,
        error.CompilationFailed => 500,
        error.WasmEngineInitFailed => 503,
        error.WasmStoreInitFailed => 503,
        error.WasmModuleLoadFailed => 503,
        error.WasmInstanceCreationFailed => 503,
        error.InstancePoolExhausted => 503,
        error.ModuleNotFound => 404,
        error.PoolNotFound => 500,
        error.DatabaseError => 503,
        error.AllocationFailed => 503,
        error.NullPointer => 400,
        error.InvalidFuelBudget => 400,
        error.FuelLimitOutOfRange => 400,
        error.MemoryGrowthFailed => 500,
        error.MissingInitExport => 422,
        error.MissingExecuteExport => 422,
        error.MissingDeinitExport => 422,
        error.MissingGetCapabilitiesExport => 422,
        error.InvalidImport => 403,
    };
}

/// Provide a human-readable error description.
pub fn errorDescription(err: WasmError) []const u8 {
    return switch (err) {
        error.WasmEngineInitFailed => "Failed to initialize Wasmtime engine",
        error.WasmStoreInitFailed => "Failed to initialize Wasmtime store",
        error.WasmModuleLoadFailed => "Failed to load Wasm module",
        error.WasmInstanceCreationFailed => "Failed to create Wasm instance",
        error.ExecutionTrap => "Wasm execution trap (out of bounds, divide by zero, etc.)",
        error.FuelExhausted => "Instruction limit exceeded during Wasm execution",
        error.TimeoutExceeded => "Wall-clock timeout exceeded",
        error.CapabilityDenied => "Module attempted to call unauthorized function",
        error.PointerOutOfBounds => "Memory pointer out of bounds",
        error.NullPointer => "Null pointer dereference",
        error.MemoryAccessViolation => "Memory access error",
        error.MemoryCapExceeded => "Linear memory growth exceeded configured limit",
        error.InvalidImport => "Module imports unauthorized function",
        error.FilesystemAccessNotAllowed => "Filesystem access not allowed",
        error.MissingInitExport => "Module missing required init() export",
        error.MissingExecuteExport => "Module missing required execute() export",
        error.MissingDeinitExport => "Module missing required deinit() export",
        error.MissingGetCapabilitiesExport => "Module missing required get_capabilities() export",
        error.InvalidInitSignature => "init() export has invalid signature",
        error.InvalidExecuteSignature => "execute() export has invalid signature",
        error.InvalidDeinitSignature => "deinit() export has invalid signature",
        error.InvalidGetCapabilitiesSignature => "get_capabilities() export has invalid signature",
        error.CapabilityParseError => "Failed to parse module capability descriptor",
        error.UnauthorizedCapability => "Module declared unauthorized capability",
        error.CompilationFailed => "Zig-to-Wasm compilation failed",
        error.InstancePoolExhausted => "No available pooled instances",
        error.InvalidFuelBudget => "Fuel budget too small (minimum 1000)",
        error.FuelLimitOutOfRange => "Fuel limit outside acceptable range",
        error.MemoryGrowthFailed => "Memory growth operation failed",
        error.InitFailed => "Module init() function failed",
        error.DeinitFailed => "Module deinit() function failed",
        error.ModuleNotFound => "Module not registered",
        error.PoolNotFound => "Instance pool not found",
        error.DatabaseError => "Database error",
        error.InvalidArgument => "Invalid argument",
        error.AllocationFailed => "Memory allocation failed",
    };
}
