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
/// ISS-0169 / GH #495 — the registry channel and capability gate every host
/// function opens with (LUA-05, LUA-06).
pub const host_context = @import("host_context.zig");
pub const manifest = @import("manifest.zig");
pub const instruction_limiter = @import("instruction_limiter.zig");
pub const memory_limiter = @import("memory_limiter.zig");
pub const timeout = @import("timeout.zig");
pub const time_source = @import("time_source.zig");
pub const structured_logger = @import("structured_logger.zig");
pub const service_catalog = @import("service_catalog.zig");
pub const events = @import("events.zig");

// Re-export key types for public API
pub const ExecutionContext = executor.ExecutionContext;
pub const ScriptResult = executor.ScriptResult;
pub const ScriptValue = executor.ScriptValue;
pub const CapabilitySet = capabilities.CapabilitySet;
pub const StandardCapabilities = capabilities.StandardCapabilities;
pub const LuaError = errors.LuaError;
pub const ScriptManifest = manifest.ScriptManifest;
pub const InstructionLimiter = instruction_limiter.InstructionLimiter;
pub const MemoryLimiter = memory_limiter.MemoryLimiter;
pub const TimeoutContext = timeout.TimeoutContext;
pub const DateTime = time_source.DateTime;
pub const TimeSource = time_source.TimeSource;
pub const StructuredLogger = structured_logger.StructuredLogger;
pub const StructuredLogEntry = structured_logger.StructuredLogEntry;
pub const ServiceCatalog = service_catalog.ServiceCatalog;
pub const RegisteredService = service_catalog.RegisteredService;
pub const Event = events.Event;
pub const EventRecord = events.EventRecord;

// Public entry points
pub const executeScript = executor.executeScript;
/// LUA-07 load-time entry point (ISS-0169). Verifies the manifest against the
/// script artifact BEFORE creating any state, then executes.
pub const executeScriptWithManifest = executor.executeScriptWithManifest;
/// The single sandboxed-state constructor (invariant SBX-2). Tests must use
/// this rather than building a state of their own, or they assert against a
/// sandbox the product never constructs.
pub const createSandboxedState = executor.createSandboxedState;
