# Test Spec: PIN-03 — No fallback to latest version

**Requirement:** PIN-03 — verbatim requirement text (docs/requirements.yaml):
> The platform SHALL resolve every versioned dependency during execution through the instance's
> pin set. A reference with no pin entry raises the typed error `PinMissing` and the step enters
> the standard retry then dead-letter path. The engine SHALL NOT resolve the current active
> version in place of a missing pin, and retiring or deprecating a pinned version SHALL NOT affect
> instances already pinned to it.

**Priority:** MUST (confirmed directly from `docs/requirements.yaml`'s `PIN-03.priority` field)
**Test layer:** integration
**Test file:** `tests/integration/pin03_no_fallback_to_latest_version_test.zig`
**Build step:** `zig build test-integration-pin03`

## Acceptance criteria (verbatim from docs/requirements.yaml)

- AC1: GIVEN a node whose reference has no entry in the pin set, WHEN the node executes, THEN
  `PinMissing` is raised naming the reference and no catalog lookup for the latest version occurs.
- AC2: GIVEN a newer catalog entry version is published while an instance is in flight, WHEN the
  instance next reaches a SERVICE_TASK using that reference, THEN it invokes the pinned version.
- AC3: GIVEN the pinned catalog entry version is set to DEPRECATED after the instance started,
  WHEN the node executes, THEN execution proceeds on the pinned version.
- AC4: GIVEN the retry budget for a `PinMissing` step is exhausted, WHEN the last retry fails,
  THEN the step lands in the dead-letter queue with the reference name in the payload.
- AC5: No code path substitutes the current active version for a missing or unresolvable pin
  entry.

## SCOPING — AC3 is explicitly NOT covered by its literal text; read before reviewing coverage

`service_catalog` has no `version`/`status` column (confirmed again during this batch by reading
`migrations/049_repository_service_catalog.sql` — unchanged since PIN-01's design read it).
**There is no DEPRECATED value anywhere in this schema** — the literal AC3 trigger condition
("the pinned catalog entry version is set to DEPRECATED") cannot be constructed in a test fixture
at all. This is tracked as **ISS-0672 / GH-306**, still open.

Per `src/design/pin-03-no-fallback-to-latest-version.md`'s Scoping note and Open questions §1,
this spec implements the design's documented **scoped structural substitute** instead
(TC-PIN-03-05): proving "execution proceeds through the pin's `resolved_id`, not a fresh
unconditional re-lookup" using the real `catalog_entry` degenerate stopgap (PIN-01's
`updated_at`-derived "version") — the SAME structural guarantee AC2 and AC3 both actually depend
on for "retirement doesn't affect in-flight instances."

**UNCOVERED, explicitly:** the literal AC3 sub-clause "catalog entry version is set to DEPRECATED"
remains untested until `service_catalog` gains a version/status column (ISS-0672/GH-306). TC-PIN-03-05
does NOT claim full AC3 coverage — it is a documented, scoped structural substitute only. Do not
read AC3 as fully covered by this file.

## Test Cases

### TC-PIN-03-01: no pin entry -> PIN_MISSING, no catalog lookup occurs
**Given:** a SERVICE_TASK node whose `service_id` has NO entry in the instance's effective pin set
(the catalog row itself is real and resolvable, proving the guard fires on the missing PIN entry,
not because the catalog is unreachable)
**When:** the node executes (driven via `completeTask()` on the preceding HUMAN_TASK)
**Then:** the instance transitions to `ERROR` and a `dead_letter_items` row with
`entry_type = 'pin_missing'` is written whose `reason` contains `PIN_MISSING` and whose
`original_payload` names the missing `service_id`
**Layer:** integration
**Acceptance criterion mapped:** PIN-03 AC1

### TC-PIN-03-02: newer catalog version published while in flight does not affect the pinned instance
**Given:** an instance started with a real, resolved `catalog_entry` pin
**When:** the live `service_catalog` row is mutated after instance start (endpoint + `updated_at`
change — PIN-01's degenerate `updated_at`-derived version stopgap)
**Then:** the instance's own recorded `pinned_versions[]` `resolved_id` for that reference is
UNCHANGED before vs. after the catalog mutation
**Layer:** integration
**Acceptance criterion mapped:** PIN-03 AC2

### TC-PIN-03-03: retry-budget exhaustion for PIN_MISSING lands in DLQ with the reference name
**Given:** a SERVICE_TASK node whose reference has no pin entry
**When:** the node executes and the retry budget (retry_count == retry_limit == 1, this
implementation's PIN_MISSING convention) is exhausted
**Then:** a `dead_letter_items` row exists with `item_type = 'SERVICE_TASK'`,
`retry_count >= retry_limit`, and the reference name present in `original_payload`
**Layer:** integration
**Acceptance criterion mapped:** PIN-03 AC4

### TC-PIN-03-04: negative-space — no fallback to the current active version
**Given:** a SERVICE_TASK node whose reference has no pin entry, where the catalog entry for that
`service_id` IS fully live and resolvable (if any fallback path existed, the instance would
execute successfully)
**When:** the node executes
**Then:** the instance is in `ERROR` (not `COMPLETED`) and a `pin_missing` DLQ row exists — proving
the guard raised `PinMissing` unconditionally rather than falling back to a fresh catalog lookup
**Layer:** integration
**Acceptance criterion mapped:** PIN-03 AC5 (genuine negative-space assertion, not a happy-path
test: a fallback bug would make this test observe `COMPLETED`, not `ERROR`)

### TC-PIN-03-05: AC3 scoped structural substitute — retirement does not affect an in-flight pin
**Given:** an instance started with a real, resolved `catalog_entry` pin (SAME mechanism as
TC-PIN-03-02, reused here specifically for the AC3 angle: "retiring... a pinned version SHALL NOT
affect instances already pinned to it")
**When:** the catalog row is mutated after instance start (the only way this schema can express a
change to a catalog entry, absent a status column)
**Then:** the already-started instance's recorded pin (`resolved_id`) is unaffected by the
mutation
**Layer:** integration
**Acceptance criterion mapped:** PIN-03 AC3 (SCOPED STRUCTURAL SUBSTITUTE ONLY — see Scoping
section above; the literal DEPRECATED-status trigger remains uncovered, tracked as ISS-0672/GH-306)

## Fail-first confirmation

All five cases are NEW. Fail-first was confirmed by temporarily removing the `pin_guard` block in
`src/engine/instance.zig`'s `processServiceTaskRuntimeInTx()` (the PIN-03 AC1/AC4/AC5 guard) and
re-running TC-PIN-03-01/03/04: all three failed as expected — the instance completed successfully
instead of entering `ERROR`, and no `pin_missing` DLQ row was written (since `PinMissing` was never
raised). TC-PIN-03-02/05 were fail-first confirmed by temporarily making
`resolveServiceCatalogRef()` re-resolve the endpoint on every read (bypassing the pin's fixed
`resolved_id`): both tests then failed because the `resolved_id` observed after the catalog
mutation differed from the value observed before. All temporary changes were reverted immediately
after confirming — no production change is retained by this handoff.

## Verified live (this handoff)

`zig build test-integration-pin03` — 5/5 pass against a real PostgreSQL instance
(`BPM_TEST_DB_URL`).
