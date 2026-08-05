//! Aggregator root for the bpm_main_mod unit test group: definition
//! retrieval (PD-07), export/import, PD-10 search, EE-03 (apply, tasks
//! API), EE-05, EE-07, EE-09, API-02, API-03, API-05, and OBS-04.
//!
//! definition_retrieval_test.zig additionally needs `build_options` and
//! `env` (its testDbUrl() helper uses env.globalEnviron()) — both are wired
//! into this aggregator's module even though the other 11 files don't
//! reference them, which is harmless in Zig.
//!
//! Each file imports only `bpm` (bpm_main_mod) plus, for
//! definition_retrieval_test.zig, `build_options`/`env` — no file-scope
//! mutable state and no duplicate top-level test names across the group
//! (verified by inspection).
//!
//! Run with: zig build test (or zig build test-bpm-main for this group only)
//!
//! Note: the `test { }` block below is itself counted as one test by Zig's
//! runner (a synthetic "container" test) — see graph_test_root.zig for the
//! full explanation of this idiom.

test {
    _ = @import("definition_retrieval_test.zig");
    _ = @import("test_export_import.zig");
    _ = @import("pd10_search_unit_test.zig");
    _ = @import("test_engine_apply.zig");
    _ = @import("test_tasks_api.zig");
    _ = @import("test_engine_ee05.zig");
    _ = @import("test_ee07_parallel_join.zig");
    _ = @import("test_ee09_merge_variables.zig");
    _ = @import("api02_handler_test.zig");
    _ = @import("api03_handler_test.zig");
    _ = @import("test_api05_history.zig");
    _ = @import("test_obs04_timeline.zig");
}
