id: ISS-0125
title: "process_definitions DELETE blocked by orphan FK references in instance_definition_snapshots"
classification: "A — logic error in schema/test cleanup contract"
symptom: >-
  C23503Mupdate or delete on table "process_definitions" violates foreign key constraint
  "instance_definition_snapshots_definition_id_fkey" on table
  "instance_definition_snapshots"DKey (id)=(cddd8d2a-dd21-4af0-8598-b8f4bf83886a)
  is still referenced from table "instance_definition_snapshots".
evidence:
  migration_review:
    - path: migrations/GBL-085_state_snapshots.sql
      lines: 1-31
      finding: >-
        This migration creates instance_state_snapshots only; it did not introduce or
        alter instance_definition_snapshots. The handoff hypothesis named the wrong migration.
    - path: migrations/004_definitions.sql
      lines: 50-57
      finding: >-
        This is the only migration that touches instance_definition_snapshots. Line 52
        declares definition_id UUID NOT NULL REFERENCES process_definitions(id) without
        ON DELETE CASCADE, so PostgreSQL uses the default NO ACTION referential action.
  shared_harness_cleanup:
    - path: tests/integration/helpers.zig
      lines: 310-325
      cleanup_order:
        - instance_definition_snapshots
        - tasks
        - timers
        - instance_projections
        - variable_schemas
        - process_definitions
        - events
        - audit_log
        - audit_entries
        - dead_letter_items
        - webhook_subscriptions
        - service_catalog
      finding: >-
        resetTestData already places instance_definition_snapshots before
        process_definitions. Its per-table TRUNCATE ... RESTART IDENTITY CASCADE also
        cascades dependencies. It is not the observed DELETE ordering violation, though
        preserving and documenting this ordering remains useful defense in depth.
  affected_test_cleanup:
    - path: tests/integration/iss202_merge_atomicity_test.zig
      lines: 130-152
      setup_teardown_refs:
        cleanup_instance_defers: "lines 212, 306, 416, 528, 626, 734, 825, 925, 1029, 1143, 1239, 1339, 1467"
        cleanup_definition_defers: "lines 203, 297, 407, 519, 617, 725, 816, 916, 1020, 1134, 1230, 1330, 1458"
      cleanup_sql:
        - "DELETE FROM instance_definition_snapshots WHERE instance_id = $1::uuid"
        - "DELETE FROM instance_projections WHERE instance_id = $1::uuid"
        - "DELETE FROM process_definitions WHERE name = $1"
      finding: >-
        Zig executes defers in LIFO order. cleanupInstance is registered after
        cleanupByName, so it normally runs first and respects the FK. However, both
        helpers swallow every SQL error; if child deletion fails, cleanupByName still
        attempts the parent DELETE and emits C23503.
    - path: tests/integration/iss203_idempotency_keys_test.zig
      lines: 130-149
      setup_teardown_refs:
        cleanup_instance_defers: "lines 242, 338, 481, 568, 574, 691"
        cleanup_definition_defers: "lines 222, 318, 432, 548, 647"
      cleanup_sql:
        - "DELETE FROM timers WHERE instance_id = $1::uuid"
        - "DELETE FROM tasks WHERE instance_id = $1::uuid"
        - "DELETE FROM events WHERE instance_id = $1::uuid"
        - "DELETE FROM instance_definition_snapshots WHERE instance_id = $1::uuid"
        - "DELETE FROM instance_projections WHERE instance_id = $1::uuid"
        - "DELETE FROM process_definitions WHERE name = $1"
      finding: >-
        Registration order also causes instance cleanup before definition cleanup, but
        blanket catch {} makes the sequence non-atomic and silently continues after a
        failed child delete.
    - path: tests/integration/iss601_state_snapshots_test.zig
      lines: 113-177
      additional_cleanup_blocks: "lines 617-624, 838-846, 990-997"
      cleanup_sql:
        - "DELETE FROM instance_state_snapshots WHERE instance_id = $1::uuid"
        - "DELETE FROM events WHERE instance_id = $1::uuid"
        - "DELETE FROM instance_definition_snapshots WHERE instance_id = $1::uuid"
        - "DELETE FROM instance_projections WHERE instance_id = $1::uuid"
      finding: >-
        Per-test cleanup deletes child snapshots before instance projections, but it does
        not delete process_definitions. Those definitions persist until a later shared
        harness reset or another suite's name-based parent cleanup. The best-effort
        catch {} pattern can hide incomplete cleanup and leak rows between binaries.
    - path: tests/integration/event_store_test.zig
      finding: >-
        The requested integration file does not exist. The only matching file is
        tests/unit/event_store_test.zig; it contains SkipZigTest stubs only and no DB
        setup, teardown, or cleanup SQL. ISS-0113 also carries this stale path.
  log:
    path: scratch/WF03-gh375-20260801/test-runner-step5c/zig_test_integration.log
    supplied_offsets:
      - offset: 1480582
        observed_content: "std.testing.expectEqual stack trace; no C23503 text"
      - offset: 1480767
        observed_content: "std.testing.expectEqual stack trace; no C23503 text"
    offset_note: >-
      The supplied offsets are stale or use a different indexing basis. The supplied log
      contains 43 C23503 tokens, but the two requested positions do not contain them.
    verified_error_lines:
      - decoded_character_offset: 865065
        verbatim_joined_line: >-
          C23503Mupdate or delete on table "process_definitions" violates foreign key
          constraint "instance_definition_snapshots_definition_id_fkey" on table
          "instance_definition_snapshots"DKey (id)=(cddd8d2a-dd21-4af0-8598-b8f4bf83886a)
          is still referenced from table "instance_definition_snapshots".
      - decoded_character_offset: 865555
        verbatim_joined_line: >-
          C23503Mupdate or delete on table "process_definitions" violates foreign key
          constraint "instance_definition_snapshots_definition_id_fkey" on table
          "instance_definition_snapshots"DKey (id)=(7c2e5ecd-cbd4-4ffc-8a34-c0b39ad466f6)
          is still referenced from table "instance_definition_snapshots".
prior_issue_matches:
  - id: ISS-0047
    match: >-
      Same affected helper and shared-state contamination pattern. Its resolved strategy
      added transient-table cleanup and seed restoration, but it did not address this FK's
      delete action or fail-fast cleanup ordering.
  - id: ISS-0050
    match: >-
      Same resetTestData cleanup surface. It replaced an all-or-nothing multi-table
      TRUNCATE with per-table best-effort truncation. The current helper retains that
      strategy and already orders snapshots before definitions.
  - id: ISS-0088
    match: >-
      Same hard-coded cleanup-list drift and swallowed ServerError pattern. Its prevention
      strategy recommends validating cleanup table references against the live schema.
  - id: ISS-0113
    match: >-
      Closest open sibling: event/idempotency fixture contamination where cleanup fails on
      FK references. It recommends per-test identifiers and dependent-before-parent cleanup.
  exact_resolved_match: null
  conclusion: >-
    No earlier resolved issue has the same instance_definition_snapshots-to-process_definitions
    FK and parent-delete failure. Prior strategies support defensive cleanup ordering, but
    none removes the schema-level fragility.
root_cause:
  type: code-defect
  details: >-
    migrations/004_definitions.sql:50-57 defines
    instance_definition_snapshots.definition_id as a NOT NULL foreign key to
    process_definitions.id without ON DELETE CASCADE. Therefore any parent DELETE requires
    every child snapshot to have been removed successfully first. The shared harness is
    correctly ordered at tests/integration/helpers.zig:310-325, and the two explicit
    definition-cleanup suites register child cleanup after parent cleanup so LIFO execution
    is also nominally correct. The actual cleanup contract is fragile because their child
    and parent DELETE helpers independently swallow all SQL errors
    (iss202_merge_atomicity_test.zig:130-152 and
    iss203_idempotency_keys_test.zig:130-149). A failed or incomplete child cleanup can thus
    silently continue into DELETE FROM process_definitions, producing C23503. The ISS-601
    blocks delete instance children but leave process_definitions for later cleanup, which
    increases cross-binary shared-state exposure. GBL-085 is unrelated: it creates
    instance_state_snapshots, not instance_definition_snapshots.
candidate_strategies:
  a:
    name: "ON DELETE CASCADE migration only"
    changes: >-
      Add GBL-106 to replace instance_definition_snapshots_definition_id_fkey with an
      equivalent FK using ON DELETE CASCADE.
    pros:
      - "Enforces the parent/child lifecycle at the database boundary for every caller."
      - "Eliminates C23503 when deleting a definition with retained immutable snapshots."
      - "Small production-code blast radius."
    cons:
      - "Does not expose or correct silent failures in test cleanup helpers."
      - "Does not independently verify cleanup ordering and fixture isolation."
    blast_radius: "One FK constraint and all process_definitions DELETE callers."
    risk: "Medium: parent deletion will now intentionally remove snapshot history."
  b:
    name: "Cleanup reorder/fail-fast only"
    changes: >-
      Keep the FK unchanged; consolidate cleanup so all dependent rows are removed before
      process_definitions and do not swallow child-delete errors before attempting the parent.
    pros:
      - "Preserves restrictive production FK semantics."
      - "Makes test failures attributable instead of silently cascading."
      - "Directly improves shared-test database hygiene."
    cons:
      - "Every current and future parent-delete caller must preserve ordering."
      - "A missed cleanup path can recreate the same C23503 cluster."
      - "The shared harness is already correctly ordered, so reorder alone does not remove schema fragility."
    blast_radius: "Shared helper plus all bespoke definition/instance cleanup blocks."
    risk: "Medium-high: duplicated cleanup logic and broad test-suite coupling."
  c:
    name: "ON DELETE CASCADE plus cleanup-order hardening"
    changes: >-
      Add GBL-106 with ON DELETE CASCADE and harden helpers/tests to perform explicit
      child-before-parent cleanup without swallowing a child failure before parent deletion.
    pros:
      - "Fixes the invariant at the database boundary and the immediate test-hygiene defect."
      - "Protects production callers while keeping cleanup behavior explicit and diagnosable."
      - "Matches the strongest parts of ISS-0047, ISS-0050, ISS-0088, and ISS-0113 prevention strategies."
    cons:
      - "Touches both schema and integration-test infrastructure."
      - "Requires a schema contract test for the altered FK delete action."
    blast_radius: "One FK constraint, shared cleanup helper, and affected bespoke test cleanup helpers."
    risk: "Medium, mitigated by contract and focused integration tests."
recommendation:
  strategy: c
  justification: >-
    Use both defenses. GBL-106 should make snapshot ownership explicit with ON DELETE CASCADE,
    while cleanup hardening should retain child-before-parent ordering and stop masking failed
    child deletion. Cascade alone would leave contamination diagnostics weak; cleanup changes
    alone would leave every future process_definitions delete dependent on manual ordering.
acceptance_criteria:
  - "[ ] A new GBL-106 migration replaces instance_definition_snapshots_definition_id_fkey with ON DELETE CASCADE without modifying migration 004 in place."
  - "[ ] A schema contract test proves deleting a process_definitions row deletes its referencing instance_definition_snapshots rows and leaves no C23503 error."
  - "[ ] resetTestData keeps instance_definition_snapshots before process_definitions and a focused test verifies the cleanup contract against PostgreSQL."
  - "[ ] iss202_merge_atomicity and iss203_idempotency cleanup cannot continue to a parent definition DELETE after a child cleanup failure has been swallowed."
  - "[ ] ISS-601 teardown removes instance_state_snapshots, events, instance_definition_snapshots, and instance_projections in dependent-before-parent order and does not leak definitions across test binaries."
  - "[ ] The four affected test surfaces are corrected to the actual paths; tests/unit/event_store_test.zig is not treated as an integration cleanup owner unless a real DB-backed replacement is added."
  - "[ ] A focused integration run for ISS-202, ISS-203, ISS-601, and event-store idempotency completes with zero instance_definition_snapshots_definition_id_fkey C23503 diagnostics."
  - "[ ] The full zig build test-integration log contains zero process_definitions DELETE C23503 diagnostics across repeated runs against the shared test database."
