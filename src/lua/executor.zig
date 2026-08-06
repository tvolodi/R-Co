//! Core Lua script executor with state isolation and sandboxing.
//!
//! This module provides the main entry point for executing Lua scripts within the BPM platform.
//! Key responsibilities:
//! - Create and manage per-invocation Lua states
//! - Load restricted standard libraries
//! - Register platform.* host API functions
//! - Execute scripts and extract results
//! - Enforce security (bytecode rejection, capability checks)

const std = @import("std");
const bindings = @import("luajit_bindings.zig");
const errors = @import("errors.zig");
const capabilities = @import("capabilities.zig");
const stdlib = @import("stdlib.zig");
const host_api = @import("host_api/mod.zig");
const manifest = @import("manifest.zig");
const instruction_limiter = @import("instruction_limiter.zig");
const memory_limiter = @import("memory_limiter.zig");
const timeout_ctx = @import("timeout.zig");
const time_source = @import("time_source.zig");
const structured_logger = @import("structured_logger.zig");
const service_catalog = @import("service_catalog.zig");
const events = @import("events.zig");

/// Execution context passed to Lua and used by host API functions.
pub const ExecutionContext = struct {
    allocator: std.mem.Allocator,
    capabilities: *const capabilities.CapabilitySet,
    instance_id: []const u8,
    actor_id: []const u8,
};

/// Result of script execution.
pub const ScriptResult = struct {
    success: bool,
    value: ?ScriptValue,
    error_message: ?[]const u8,

    pub fn deinit(self: *ScriptResult, allocator: std.mem.Allocator) void {
        if (self.error_message) |msg| {
            allocator.free(msg);
        }
        if (self.value) |val| {
            val.deinit(allocator);
        }
    }
};

/// Script return value (can be nil, bool, number, string, or table).
pub const ScriptValue = union(enum) {
    nil_value: void,
    boolean: bool,
    number: f64,
    string: []const u8,
    table: std.StringHashMap(ScriptValue),

    /// ISS-0153: the original body did not compile and would have leaked and
    /// double-freed if it had. Three separate defects, none ever reported
    /// because no build target analysed this file:
    ///   1. `self.table.allocator orelse allocator` — `StringHashMap.allocator`
    ///      is not optional, so `orelse` is a type error.
    ///   2. The map's own storage was never released (no `t.deinit()`), so
    ///      every table-valued script result leaked its bucket array.
    ///   3. Entries were walked twice — once for keys in the switch, once for
    ///      values below — with the second pass freeing only `.string` values
    ///      non-recursively, so nested tables leaked while the structure
    ///      invited a double free.
    /// Rewritten as a single recursive pass that frees each key and each value
    /// exactly once, then releases the map itself.
    pub fn deinit(self: ScriptValue, allocator: std.mem.Allocator) void {
        switch (self) {
            .string => |s| allocator.free(s),
            .table => |t| {
                var map = t;
                var iter = map.iterator();
                while (iter.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                map.deinit();
            },
            else => {},
        }
    }
};

/// Bytecode magic number: 0x1b 'L' 'u' 'a'
const BYTECODE_MAGIC = [4]u8{ 0x1b, 0x4c, 0x75, 0x61 };

/// Check if script source looks like Lua bytecode.
fn isBytecode(script: []const u8) bool {
    if (script.len < 4) return false;
    return std.mem.eql(u8, script[0..4], &BYTECODE_MAGIC);
}

/// Execute a Lua script with the given context and capabilities.
pub fn executeScript(context: *const ExecutionContext, script_source: []const u8) !ScriptResult {
    // Reject bytecode
    if (isBytecode(script_source)) {
        return ScriptResult{
            .success = false,
            .value = null,
            .error_message = try context.allocator.dupe(u8, "Bytecode is not allowed; only source text scripts are permitted"),
        };
    }

    // Create a fresh Lua state
    const L = createState() catch |err| {
        return ScriptResult{
            .success = false,
            .value = null,
            .error_message = try context.allocator.dupe(u8, errors.errorDescription(err)),
        };
    };
    defer bindings.lua_close(L);

    // Load restricted stdlib
    stdlib.loadSafeStdlib(L) catch |err| {
        return ScriptResult{
            .success = false,
            .value = null,
            .error_message = try context.allocator.dupe(u8, errors.errorDescription(err)),
        };
    };

    // Register host API (for MVP, no-op; host_api module will be populated by host_api/*.zig)
    registerHostAPI(L, context) catch |err| {
        return ScriptResult{
            .success = false,
            .value = null,
            .error_message = try context.allocator.dupe(u8, errors.errorDescription(err)),
        };
    };

    // Compile and execute script
    const status = bindings.luaL_loadstring(L, @ptrCast(script_source.ptr));
    if (status != 0) {
        const err_str = bindings.lua_tostring(L, -1);
        const err_msg = std.mem.span(err_str);
        return ScriptResult{
            .success = false,
            .value = null,
            .error_message = try context.allocator.dupe(u8, err_msg),
        };
    }

    // Execute with protected call (0 args, 1 return value)
    const call_status = bindings.lua_pcall(L, 0, 1, 0);
    if (call_status != 0) {
        const err_str = bindings.lua_tostring(L, -1);
        const err_msg = std.mem.span(err_str);
        return ScriptResult{
            .success = false,
            .value = null,
            .error_message = try context.allocator.dupe(u8, err_msg),
        };
    }

    // Extract result from stack
    var result = ScriptResult{
        .success = true,
        .value = null,
        .error_message = null,
    };

    if (bindings.lua_gettop(L) > 0) {
        result.value = extractValue(L, -1, context.allocator) catch |err| {
            result.success = false;
            result.error_message = try context.allocator.dupe(u8, errors.errorDescription(err));
        };
    }

    return result;
}

/// Create a new Lua state with custom allocator.
fn createState() !*bindings.LuaState {
    const L = bindings.lua_newstate(defaultAlloc, null) orelse return errors.LuaError.LuaAllocFailed;
    return L;
}

/// Default allocator for Lua.
///
/// Uses the C allocator directly because LuaJIT calls this through a C ABI
/// function pointer and may realloc/free across the FFI boundary, which Zig's
/// allocator interface cannot service without the original slice length. This
/// is why the `lua` build module sets `link_libc = true` (build.zig).
///
/// ISS-0153: with the stub bindings currently in place `lua_newstate` returns
/// null and never invokes this, but the function is kept intact (not deleted)
/// so it is still type-checked and is correct on the day real LuaJIT is linked
/// under ISS-0161 / GH #485.
fn defaultAlloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    _ = ud;
    _ = osize;

    if (nsize == 0) {
        if (ptr) |p| {
            std.c.free(p);
        }
        return null;
    }

    if (ptr) |p| {
        return std.c.realloc(p, nsize);
    } else {
        return std.c.malloc(nsize);
    }
}

/// Register the platform.* API table and functions.
fn registerHostAPI(L: *bindings.LuaState, context: *const ExecutionContext) !void {
    // Delegate to host_api module for all function registration
    try host_api.registerAll(L, context);
}

/// Extract a value from the Lua stack at the given index.
fn extractValue(L: *bindings.LuaState, idx: c_int, allocator: std.mem.Allocator) !ScriptValue {
    const lua_type = bindings.lua_type(L, idx);

    return switch (lua_type) {
        bindings.LUA_TNIL => ScriptValue{ .nil_value = {} },
        bindings.LUA_TBOOLEAN => ScriptValue{ .boolean = bindings.lua_toboolean(L, idx) != 0 },
        bindings.LUA_TNUMBER => ScriptValue{ .number = bindings.lua_tonumber(L, idx) },
        bindings.LUA_TSTRING => {
            var len: usize = 0;
            const str_ptr = bindings.lua_tolstring(L, idx, &len);
            const str = str_ptr[0..len];
            return ScriptValue{ .string = try allocator.dupe(u8, str) };
        },
        bindings.LUA_TTABLE => {
            const table = std.StringHashMap(ScriptValue).init(allocator);
            // Simplified table extraction (one level only for MVP)
            return ScriptValue{ .table = table };
        },
        else => errors.LuaError.TypeError,
    };
}
