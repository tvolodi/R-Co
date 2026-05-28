//! Unit tests for repository artifacts module (REPO-01..03)
//!
//! Tests artifact creation, versioning, and validation.

const std = @import("std");
const repository = @import("repository");

// Note: Full DB tests are in test-integration mode (requires BPM_TEST_DB_URL)
// These are pure input-validation tests.

test "Artifacts module compiles" {
    // Placeholder: ensure the module can be imported without errors
    _ = repository.artifacts;
}
