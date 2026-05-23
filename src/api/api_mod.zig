//! Single-root re-export shim for API convention modules (API-01).
//!
//! Having one module root prevents "file exists in two modules" conflicts
//! that arise when errors.zig is both a named-module root AND imported via
//! a relative path inside content_type.zig and response.zig.
pub const errors = @import("errors.zig");
pub const content_type = @import("middleware/content_type.zig");
pub const auth = @import("middleware/auth.zig");
pub const response = @import("response.zig");
pub const pagination = @import("pagination.zig");
pub const validation = @import("validation.zig");
pub const validate_middleware = @import("middleware/validate.zig");
