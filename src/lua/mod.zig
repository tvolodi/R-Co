//! Lua script execution subsystem for BPM Platform.
//!
//! Provides sandboxed Lua script execution with:
//! - Per-invocation state isolation
//! - Restricted stdlib (math, string, table only)
//! - Bytecode rejection
//! - Capability-based authorization
//! - Host API functions (platform.*)
//!
//! Public API:
//! - executor.executeScript(context, script_source) -> ScriptResult
//! - executor.ExecutionContext
//! - executor.ScriptResult
//! - executor.ScriptValue
//! - capabilities.CapabilitySet
//! - capabilities.StandardCapabilities

pub const executor = @import("executor.zig");
pub const capabilities = @import("capabilities.zig");
pub const errors = @import("errors.zig");
pub const stdlib = @import("stdlib.zig");
pub const luajit_bindings = @import("luajit_bindings.zig");
pub const host_api = @import("host_api/mod.zig");

// Re-export key types for public API
pub const ExecutionContext = executor.ExecutionContext;
pub const ScriptResult = executor.ScriptResult;
pub const ScriptValue = executor.ScriptValue;
pub const CapabilitySet = capabilities.CapabilitySet;
pub const StandardCapabilities = capabilities.StandardCapabilities;
pub const LuaError = errors.LuaError;

// Public entry point
pub const executeScript = executor.executeScript;
