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

    pub fn deinit(self: ScriptValue, allocator: std.mem.Allocator) void {
        switch (self) {
            .string => |s| allocator.free(s),
            .table => |t| {
                var iter = t.keyIterator();
                while (iter.next()) |key| {
                    allocator.free(key.*);
                }
                // Note: values are deallocated recursively below
            },
            else => {},
        }
        // Recursive cleanup for table values (simplified: only one level)
        if (self == .table) {
            var iter = self.table.valueIterator();
            while (iter.next()) |val| {
                if (val.* == .string) {
                    (self.table.allocator orelse allocator).free(val.string);
                }
            }
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

/// Default allocator for Lua (uses Zig's GPA for simplicity; can be customized).
fn defaultAlloc(ud: ?*c_void, ptr: ?*c_void, osize: usize, nsize: usize) callconv(.C) ?*c_void {
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
            var table = std.StringHashMap(ScriptValue).init(allocator);
            // Simplified table extraction (one level only for MVP)
            return ScriptValue{ .table = table };
        },
        else => errors.LuaError.TypeError,
    };
}
