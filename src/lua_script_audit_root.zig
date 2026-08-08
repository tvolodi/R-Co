//! Named-module root for `src/engine/lua_script_audit.zig` (ISS-0176 / GH #504).
//!
//! ## Why this shim exists
//!
//! `src/engine/lua_script_audit.zig` imports `../lua/executor.zig` by
//! relative path. `src/lua/host_api/call_service.zig` and `host_api/now.zig`
//! escape `src/lua/` into `../../simulation/*.zig`, which in turn reaches
//! `../event_store/store.zig` — so any module that contains
//! `lua_script_audit.zig` must be rooted at `src/`, not `src/engine/`, to
//! keep the whole import chain inside the module root (Zig 0.16 rejects an
//! `@import` that escapes it). This is the identical constraint documented in
//! `src/lua_test_root.zig` and `src/transition_test_root.zig`.
//!
//! `src/bpm.zig` deliberately does NOT re-export `src/lua/` (see its own
//! comment) because LuaJIT is linked into exactly one compile unit
//! (`lua_tests`, `build.zig`) — pulling `lua/executor.zig` into `bpm_src_mod`
//! would require every target that imports `bpm` (the main server exe and
//! ~90 integration test files) to link LuaJIT too. This shim keeps
//! `lua_script_audit.zig` reachable ONLY from a dedicated module that links
//! LuaJIT explicitly (see build.zig's `lua_script_audit_mod` /
//! `test-integration-iss0176` wiring), which is exactly the scope the design
//! (`src/design/iss0176-lua07-audit-manifest-hash-minimal-wiring.md` §2.3)
//! calls for: production code, real types, but reachable today only by the
//! integration test that proves LUA-07's second criterion.
const std = @import("std");

pub const lua_script_audit = @import("engine/lua_script_audit.zig");

/// Re-exported so the ISS-0176 integration test can build a real
/// ScriptManifest/ExecutionContext/CapabilitySet without a second dedicated
/// module — it needs the same LuaJIT-linked root this file already is.
///
/// IMPORTANT: because `lua/mod.zig` pulls in `lua/host_api/call_service.zig`,
/// which escapes into `../../simulation/runtime.zig`, this module and `bpm`
/// (src/bpm.zig, which also owns src/simulation/* via its own
/// `pub const simulation = @import("simulation/mod.zig")`) can NEVER be
/// imported into the same compile unit — Zig 0.16 rejects that as "file
/// exists in modules 'bpm' and 'lua_script_audit'" (verified empirically).
/// This is why the ISS-0176 integration test does NOT use
/// tests/integration/helpers.zig's TestHarness (which imports `bpm`) and
/// instead re-implements the minimal subset it needs (pool connect + tenant
/// context + migrations + UUID generation) from the bpm-free modules below.
pub const lua = @import("lua/mod.zig");

/// bpm-free: imports only `pool` (named module). Lets the integration test
/// apply pending migrations without going through TestHarness/bpm.
pub const migrations = @import("db/migrations.zig");

/// bpm-free: util/uuid.zig -> api/middleware/trace.zig -> api/trace_context.zig,
/// none of which touch bpm.zig or src/simulation/.
pub const uuid = @import("util/uuid.zig");

test {
    std.testing.refAllDecls(lua_script_audit);
}
