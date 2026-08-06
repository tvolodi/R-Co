//! Lua host API module registry.
//!
//! This module coordinates the registration of all platform.* functions.
//! Each function is defined in its own submodule (call_service.zig, read_variable.zig, etc.)

const bindings = @import("../luajit_bindings.zig");
const executor = @import("../executor.zig");

pub const call_service = @import("call_service.zig");
pub const read_variable = @import("read_variable.zig");
pub const write_variable = @import("write_variable.zig");
pub const log_func = @import("log.zig");
pub const emit_event = @import("emit_event.zig");
pub const get_instance_state = @import("get_instance_state.zig");
pub const now_func = @import("now.zig");
pub const fail_func = @import("fail.zig");

/// Register EXACTLY the eight Architecture §5.2 functions into the `platform`
/// table, and no others (LUA-05 first clause).
///
/// The normative capability matrix lives in
/// `src/design/lua-capability-enforcement.md` §3.2. Adding a ninth function
/// without adding a row there is a defect.
///
/// | platform.*            | capability required        |
/// |-----------------------|----------------------------|
/// | call_service          | service:call:<svc_id>      |
/// | read_variable         | variable:read              |
/// | write_variable        | variable:write             |
/// | log                   | audit:log                  |
/// | emit_event            | event:emit                 |
/// | get_instance_state    | instance:read              |
/// | now                   | NONE — ungated by design   |
/// | fail                  | NONE — ungated by design   |
///
/// `now` and `fail` being ungated is a POSITIVE design statement, not an
/// omission: `now` is a pure time read with no state reach (LUA-14), and a
/// script may always terminate itself (LUA-15). A test that expects a gate on
/// either is reading the matrix wrong.
///
/// The context is installed into `LUA_REGISTRYINDEX` by
/// `executor.createSandboxedState` BEFORE this runs, so every closure created
/// here can reach it via `host_context.contextFromState`. The `context`
/// parameter is retained on each `register` for signature stability, but no
/// registration carries the pointer itself — that is the whole point of the
/// registry channel (design §2.2): one write, one shared read helper, no
/// per-closure ceremony that a new function can forget.
pub fn registerAll(
    L: *bindings.LuaState,
    context: *const executor.ExecutionContext,
) !void {
    // Create platform table
    bindings.lua_newtable(L);

    // Register each function (C closure wrapping is done per function)
    try call_service.register(L, context);
    try read_variable.register(L, context);
    try write_variable.register(L, context);
    try log_func.register(L, context);
    try emit_event.register(L, context);
    try get_instance_state.register(L, context);
    try now_func.register(L, context);
    try fail_func.register(L, context);

    // Assign to global 'platform'
    bindings.lua_setglobal(L, "platform");
}
