//! Aggregator root for two otherwise-unrelated tests/unit files that were
//! wired into no build target (13 blocks).
//!
//! ISS-0137 / GH #439. lua_test.zig imports only `std`; wasm_executor_test.zig
//! imports the named module `wasm`, which build.zig declared nowhere until
//! cluster C4a (root src/wasm/mod.zig).
//!
//! No Wasmtime link is needed and none is configured: src/wasm/ contains zero
//! `@cImport` and zero `linkSystemLibrary`, and wasmtime_bindings.zig declares
//! only `extern struct`/`extern union` TYPES. `extern struct` is a memory-layout
//! qualifier, not a link-time symbol reference, so this compiles and runs
//! against pure-Zig stubs — exactly as wasm_executor_test.zig's own comment
//! claims ("engine_new is a stub that returns null in unit tests").
//!
//! Whether the src/wasm subsystem is live code at all is a separate question,
//! tracked as ISS-0147 / GH #463; it is deliberately not decided here.
//!
//! Run with: zig build test-misc-unit (also reached by zig build test).

test {
    _ = @import("lua_test.zig");
    _ = @import("wasm_executor_test.zig");
}
