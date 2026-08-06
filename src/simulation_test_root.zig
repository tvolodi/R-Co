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
//! Run via `zig build test-simulation` (also reached by `zig build test`).

const std = @import("std");

pub const simulation = @import("simulation/mod.zig");

test {
    std.testing.refAllDecls(simulation);
}
