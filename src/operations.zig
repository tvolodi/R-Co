//! Aggregator for the `operations` named module (PI-09 / ISS-0084 / GH-299).
//!
//! `tests/integration/*.zig` cannot reach `src/operations/*.zig` by relative
//! path because Zig 0.16 forbids an `@import` from escaping the importing
//! file's module root. The build wires this aggregator in as the `operations`
//! named module via `build.zig` and integration tests reach it as
//! `@import("operations")`. Symbols are re-exported flat so callers do
//! `operations.assertDatabaseConfiguration(...)` rather than the double
//! `operations.startup_assertions.assertDatabaseConfiguration(...)` that a
//! generic module-aggregator pattern would force.
pub const startup_assertions = @import("operations/startup_assertions.zig");
pub const assertDatabaseConfiguration = startup_assertions.assertDatabaseConfiguration;
pub const assertDatabaseConfigurationWithOverrides = startup_assertions.assertDatabaseConfigurationWithOverrides;
pub const StartupAssertionError = startup_assertions.StartupAssertionError;
