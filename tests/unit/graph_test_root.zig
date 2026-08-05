//! Aggregator root for the graph_mod unit test group (PD-02, PD-05, PD-06).
//!
//! Combines definition_test.zig, graph_node_attributes_test.zig, and
//! graph_edge_conditions_test.zig into a single `zig build test` compile
//! unit. Each file already imports only `std` and `graph`, so merging is
//! safe: no file-scope mutable state, no top-level `test` name collisions
//! across the three files (verified by inspection — each file's `test`
//! blocks are prefixed with its own requirement-ID scheme: PD-02, PD-05,
//! PD-06 respectively).
//!
//! Run with: zig build test (or zig build test-graph for this group only)
//!
//! Note: the `test { }` block below is itself counted as one test by Zig's
//! runner (a synthetic "container" test, `test_0`) — 62 real tests across
//! the three imported files plus this one is the expected 63/63.

test {
    _ = @import("definition_test.zig");
    _ = @import("graph_node_attributes_test.zig");
    _ = @import("graph_edge_conditions_test.zig");
}
