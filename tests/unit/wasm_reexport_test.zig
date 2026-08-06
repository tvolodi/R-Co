//! ISS-0147 / GH #463 — regression guard for the src/wasm re-export.
//!
//! src/wasm/ implements WASM-01..14 (11 MUST + 2 SHOULD, all RELEASED, all
//! listed in docs/requirements.yaml `implemented_in`), yet it was re-exported
//! by neither src/bpm.zig nor src/main.zig and reached from no addTest root.
//! No production build path compiled it, so the subsystem could have broken
//! silently without any target going red.
//!
//! `pub const wasm = @import("wasm")` in src/bpm.zig fixes that, but a bare
//! re-export is not self-enforcing: Zig only semantically analyses a decl that
//! something actually references. This file references concrete decls from
//! every file in the subsystem, so a compile break anywhere under src/wasm/
//! now fails `zig build test`.
//!
//! On the external-link question (the open half of ISS-0147): none is needed.
//! src/wasm/ contains zero @cImport and zero linkSystemLibrary.
//! wasmtime_bindings.zig declares only `extern struct`/`extern union` TYPES —
//! `extern` there is a memory-layout qualifier, not a link-time symbol
//! reference — and every binding fn is an `inline fn` stub returning a failure
//! sentinel (engine_new -> null, module_new -> 1). Real Wasmtime bindings are
//! a Stage 10 concern per that file's own header comment; nothing needs to be
//! linked for this subsystem to compile and be type-checked today.
//!
//! Run with: zig build test (via tests/unit/bpm_src_test_root.zig).

const std = @import("std");
const bpm = @import("bpm");

test "ISS-0147: src/wasm subsystem is reachable through the bpm re-export shim" {
    const wasm = bpm.wasm;

    // mod.zig public entry points (WASM-01, WASM-02).
    try std.testing.expect(@hasDecl(wasm, "executeModule"));
    try std.testing.expect(@hasDecl(wasm, "instantiateModule"));
    try std.testing.expect(@hasDecl(wasm, "validateModuleABI"));

    // Per-file decls — one from each file, so a break anywhere fails here.
    _ = wasm.engine.WasmEngine; // WASM-01, WASM-03, WASM-04, WASM-05
    _ = wasm.executor.ExecutionResult; // WASM-02, WASM-09
    _ = wasm.instance.WasmInstance; // WASM-02, WASM-08
    _ = wasm.capabilities.CapabilitySet; // WASM-06, WASM-07
    _ = wasm.errors.WasmError;
    _ = wasm.memory; // WASM-08, WASM-10
    _ = wasm.timeout.TimeoutContext; // WASM-11
    _ = wasm.pool.InstancePool; // WASM-13
    _ = wasm.module_registry.ModuleRegistry; // WASM-14

    // host_api parity surface (WASM-12).
    const host_api = wasm.host_api;
    try std.testing.expect(@hasDecl(host_api, "read_variable"));
    try std.testing.expect(@hasDecl(host_api, "write_variable"));
    try std.testing.expect(@hasDecl(host_api, "call_service"));
    try std.testing.expect(@hasDecl(host_api, "log"));
    try std.testing.expect(@hasDecl(host_api, "now"));
    try std.testing.expect(@hasDecl(host_api, "fail"));
    try std.testing.expect(@hasDecl(host_api, "uuid"));
}

test "ISS-0147: wasmtime_bindings needs no external link" {
    const bindings = bpm.wasm.wasmtime_bindings;

    // `extern struct` is a layout qualifier; these are opaque handle types
    // with no fields, so referencing them pulls in no external symbol.
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(bindings.Engine));
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(bindings.Store));
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(bindings.Module));

    // The stubs are real, callable Zig — no linker involvement. They return
    // failure sentinels until Stage 10 swaps in the real @cImport bindings.
    try std.testing.expect(bindings.engine_new() == null);
    try std.testing.expect(bindings.store_new(null, null, null) == null);

    var module_out: ?*bindings.Module = null;
    const rc = bindings.module_new(null, "\x00asm", 4, &module_out);
    try std.testing.expectEqual(@as(c_int, 1), rc); // stub: fail
    try std.testing.expect(module_out == null);
}
