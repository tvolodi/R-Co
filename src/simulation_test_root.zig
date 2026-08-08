//! Test root for the in-file tests inside `src/simulation/` (7 blocks across
//! context.zig, time_source.zig, uuid_source.zig, mock_catalog.zig and
//! tenant_store.zig).
//!
//! ISS-0137 / GH #439. Like src/repository, the whole simulation tree was
//! orphaned — mod.zig was reachable from no addTest root.
//!
//! Single-Owner Module Rule (design §1.2): this is the ONE C3 shim that reaches
//! its target by **relative** path, and that is correct precisely because
//! `src/simulation/mod.zig` does NOT become a named-module root anywhere in this
//! design. Relative reach is permitted only for files that are no module's root.
//!
//! Placement at `src/` is load-bearing — the shim must NOT sit at
//! `src/simulation/`. Both `src/simulation/types.zig` (line 2) and
//! `src/simulation/tenant_store.zig` (line 2) import `../event_store/store.zig`,
//! escaping `src/simulation/`, and types.zig is imported by six of the nine
//! simulation siblings. A shim rooted at src/simulation/ would make those
//! imports escape the module root and Zig 0.16 rejects that. Identical to the
//! constraint that forced src/transition_test_root.zig to `src/`.
//!
//! ## ISS-0172 / GH #500 — refAllDecls through mod.zig does not reach leaves
//!
//! `std.testing.refAllDecls(simulation)` alone (where `simulation = mod.zig`)
//! pins only `mod.zig`'s OWN top-level decls — each of which is itself a
//! `pub const x = @import("x.zig")` module reference. Taking the address of a
//! module reference does not descend into that module: it neither resolves
//! its struct field types (the memory_limiter.zig class of bug) nor analyses
//! its function bodies (the instruction_limiter.zig class of bug). Empirically
//! confirmed by injecting `std.Thread.NonExistentMutex` into an unused struct,
//! and separately a statement type error into an uncalled function, three
//! levels under a `mod.zig`-style aggregator: `refAllDecls` on the aggregator
//! caught NEITHER. This is the same gap ISS-0172 found in
//! `src/lua_test_root.zig`, here one layer removed.
//!
//! The fix: call `refAllDecls` directly on every LEAF file (not just the
//! aggregator), and separately force every leaf's own struct/union/enum
//! declarations to have their fields resolved via `pinModuleTypes` below
//! (`_ = @sizeOf(T)` per type — `refAllDecls` alone does not reach field
//! types even for a leaf it does otherwise analyse). Both pins were verified
//! by deliberate mutation against this exact file shape before being applied
//! — see the ISS-0172 mutation-test evidence recorded in
//! `src/lua_test_root.zig`'s header, which used the same probe.
//!
//! Run via `zig build test-simulation` (also reached by `zig build test`).

const std = @import("std");

pub const simulation = @import("simulation/mod.zig");

/// ISS-0172 / GH #500 — forces field-type resolution AND method-body analysis
/// for every struct/union/enum declared at `T`'s top level.
///
/// `refAllDecls(T)` alone does not do this for a nested type: it takes the
/// address of each decl, which for a type decl only proves the type NAME
/// resolves, not that its fields do (Zig resolves struct field types lazily),
/// and — separately, confirmed by mutation test — `refAllDecls` called on the
/// ENCLOSING module does not descend into that type's own methods at all;
/// `std.meta.declarations` only walks the module's own top-level decls, and a
/// method is a declaration of the struct, not of the module. `_ = @sizeOf(field)`
/// closes the field-type gap; `refAllDecls(field)` — called directly on the
/// struct/union/enum itself — closes the method-body gap, because a method IS
/// one of that type's own declarations.
fn pinModuleTypes(comptime T: type) void {
    inline for (comptime std.meta.declarations(T)) |decl| {
        const field = @field(T, decl.name);
        if (@TypeOf(field) == type) {
            switch (@typeInfo(field)) {
                .@"struct", .@"union", .@"enum" => {
                    _ = @sizeOf(field);
                    std.testing.refAllDecls(field);
                },
                else => {},
            }
        }
    }
}

test {
    std.testing.refAllDecls(simulation);

    // ISS-0172: direct refAllDecls on every leaf, not just the mod.zig
    // aggregator — refAllDecls(simulation) alone does not descend into these.
    std.testing.refAllDecls(simulation.types);
    std.testing.refAllDecls(simulation.context);
    std.testing.refAllDecls(simulation.time_source);
    std.testing.refAllDecls(simulation.uuid_source);
    std.testing.refAllDecls(simulation.mock_catalog);
    std.testing.refAllDecls(simulation.service_interceptor);
    std.testing.refAllDecls(simulation.tenant_store);
    std.testing.refAllDecls(simulation.runtime);
    std.testing.refAllDecls(simulation.scenario_runner);

    // ISS-0172: struct/union/enum field-type resolution per leaf.
    pinModuleTypes(simulation.types);
    pinModuleTypes(simulation.context);
    pinModuleTypes(simulation.time_source);
    pinModuleTypes(simulation.uuid_source);
    pinModuleTypes(simulation.mock_catalog);
    pinModuleTypes(simulation.service_interceptor);
    pinModuleTypes(simulation.tenant_store);
    pinModuleTypes(simulation.runtime);
    pinModuleTypes(simulation.scenario_runner);
}
