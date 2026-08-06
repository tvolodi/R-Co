//! Aggregator root for the bpm_src_mod unit test group: db_test.zig,
//! reconstruction_test.zig (EE-11), sch05/sch06/sch302 (scheduler),
//! service_task_test.zig (EXT-01), ext03_plugin_test.zig (EXT-03), and
//! effects/test_effects.zig (EXP-301/302/303).
//!
//! engine_test.zig is deliberately NOT included here even though it also
//! only imports bpm_src_mod: it has its own documented, historically-relied-
//! upon `zig build test-engine` step (see docs/guides/backend_developer_guide.md
//! §"zig build test-<module>") and stays a standalone target so that step
//! keeps running exactly engine_test.zig's tests, not this whole group's.
//!
//! Each file imports only `bpm` (bpm_src_mod), with no file-scope mutable
//! state and no duplicate top-level test names across the group (verified
//! by inspection).
//!
//! Run with: zig build test (or zig build test-bpm-src for this group only)
//!
//! Note: the `test { }` block below is itself counted as one test by Zig's
//! runner (a synthetic "container" test) — see graph_test_root.zig for the
//! full explanation of this idiom.

test {
    _ = @import("db_test.zig");
    _ = @import("reconstruction_test.zig");
    _ = @import("sch05_missed_timer_recovery_test.zig");
    _ = @import("sch06_timer_jitter_test.zig");
    _ = @import("sch302_startup_sweep_lock_test.zig");
    _ = @import("service_task_test.zig");
    _ = @import("ext03_plugin_test.zig");
    _ = @import("effects/test_effects.zig");
    // ISS-0147 / GH #463: forces semantic analysis of the src/wasm subsystem,
    // which src/bpm.zig now re-exports as `bpm.wasm`.
    _ = @import("wasm_reexport_test.zig");
}
