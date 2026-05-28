//! Host API functions exposed to Wasm modules.
//!
//! Provides platform.* functions with Lua parity:
//! - read_variable, write_variable (state access)
//! - call_service (service invocation)
//! - log, now, fail, uuid (utilities)

pub const read_variable = @import("read_variable.zig");
pub const write_variable = @import("write_variable.zig");
pub const call_service = @import("call_service.zig");
pub const log = @import("log.zig");
pub const now = @import("now.zig");
pub const fail = @import("fail.zig");
pub const uuid = @import("uuid.zig");

pub const HostAPIError = error{
    CapabilityDenied,
    InvalidArgument,
    DatabaseError,
};
