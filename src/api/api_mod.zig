//! Single-root re-export shim for API convention modules (API-01).
//!
//! Having one module root prevents "file exists in two modules" conflicts
//! that arise when errors.zig is both a named-module root AND imported via
//! a relative path inside content_type.zig and response.zig.
pub const errors = @import("errors.zig");
pub const content_type = @import("middleware/content_type.zig");
pub const auth = @import("middleware/auth.zig");
pub const identity_provider = @import("identity_provider");
pub const response = @import("response.zig");
pub const pagination = @import("pagination.zig");
pub const validation = @import("validation.zig");
pub const validate_middleware = @import("middleware/validate.zig");
pub const trace_context = @import("trace_context.zig");
pub const tenant_context = @import("tenant_context");
pub const pipeline_context = @import("pipeline_context");
pub const trace_middleware = @import("middleware/trace.zig");
pub const rate_limit = @import("middleware/rate_limit.zig");
pub const openapi = @import("openapi/mod.zig");
pub const openapi_route = @import("routes/openapi.zig");
