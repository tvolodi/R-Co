//! Wasm module execution subsystem for BPM Platform.
//!
//! Provides sandboxed Wasm module execution with:
//! - Wasmtime static linking (WASM-01)
//! - Module ABI contract validation (WASM-02)
//! - Source compilation jobs (WASM-03)
//! - Compilation caching (WASM-04)
//! - Build reproducibility (WASM-05)
//! - Import whitelist enforcement (WASM-06)
//! - Filesystem access restrictions (WASM-07)
//! - Memory isolation with pointer validation (WASM-08)
//! - Fuel-based instruction limits (WASM-09)
//! - Memory caps (WASM-10)
//! - Wall-clock timeouts (WASM-11)
//! - Host API parity with Lua (WASM-12)
//! - Instance pooling (WASM-13)
//! - Hot reload with version management (WASM-14)

pub const executor = @import("executor.zig");
pub const engine = @import("engine.zig");
pub const instance = @import("instance.zig");
pub const capabilities = @import("capabilities.zig");
pub const errors = @import("errors.zig");
pub const memory = @import("memory.zig");
pub const timeout = @import("timeout.zig");
pub const pool = @import("pool.zig");
pub const module_registry = @import("module_registry.zig");
pub const wasmtime_bindings = @import("wasmtime_bindings.zig");
pub const host_api = @import("host_api/mod.zig");

// Re-export key types for public API
pub const ExecutionResult = executor.ExecutionResult;
pub const ExecutionContext = executor.ExecutionContext;
pub const ErrorType = executor.ErrorType;
pub const WasmEngine = engine.WasmEngine;
pub const WasmStore = engine.WasmStore;
pub const WasmInstance = instance.WasmInstance;
pub const InstanceConfig = instance.InstanceConfig;
pub const CapabilitySet = capabilities.CapabilitySet;
pub const StandardCapabilities = capabilities.StandardCapabilities;
pub const ModuleCapabilities = capabilities.ModuleCapabilities;
pub const WasmError = errors.WasmError;
pub const TimeoutContext = timeout.TimeoutContext;
pub const InstancePool = pool.InstancePool;
pub const ModuleRegistry = module_registry.ModuleRegistry;
pub const ModuleVersion = module_registry.ModuleVersion;

// Public entry point
pub const executeModule = executor.executeModule;
pub const instantiateModule = instance.instantiateModule;
pub const validateModuleABI = instance.validateModuleABI;
