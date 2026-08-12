# Test Spec: PIN-04 — Pin resolution on replay and in sub-processes

**Requirement:** PIN-04 — verbatim requirement text (docs/requirements.yaml):
> The platform SHALL read the effective pin set during state reconstruction from
> `INSTANCE_STARTED` and the most recent `INSTANCE_PINS_REBOUND` event, never from the live
> service catalog or module registry. A sub-process child instance inherits its parent's pin set
> and adds entries only for references the parent does not carry. `GET /api/v1/instances/{id}/pins`
> returns the effective set with the source event identifier for each entry.

**Priority:** MUST (confirmed directly from `docs/requirements.yaml`'s `PIN-04.priority` field)
**Test layer:** integration
**Test file:** `tests/integration/pin04_pin_resolution_replay_subprocess_test.zig`
**Build step:** `zig build test-integration-pin04`

## Acceptance criteria (verbatim from docs/requirements.yaml)

- AC1: GIVEN a completed instance whose catalog has changed since it ran, WHEN its state is
  reconstructed, THEN the reconstructed dependency versions equal the versions recorded in
  `INSTANCE_STARTED`.
- AC2: GIVEN a child instance started with `parent_instance_id`, WHEN its pin set is written, THEN
  entries for references the parent already pins carry `source = inherited` and the parent's
  version.
- AC3: GIVEN a child reference that resolves to a version differing from an inherited pin, WHEN
  the child starts, THEN the inherited pin is used and the conflict is recorded in the child's
  `INSTANCE_STARTED` payload.
- AC4: GIVEN a call to `GET /api/v1/instances/{id}/pins`, WHEN it is served, THEN each entry names
  the event identifier it was read from.
- AC5: Reconstruction issues no read against the service catalog or the module registry.

## IMPLEMENTATION GAP FOUND DURING TEST DESIGN — AC2/AC3 NOT IMPLEMENTED

While reading the actual implementation (per this handoff's mandatory "read the implementation
before designing tests" instruction), sub-process pin inheritance was found to be **absent**:

- `src/engine/instance.zig`'s `startSubProcessesForPendingEventsInTx()` calls the plain
  `InstanceStore.create()` path for the child instance — the SAME entry point any independent
  top-level instance uses. It passes no `parent_instance_id`-derived pin data, performs no merge
  against the parent's effective pin set, and `create()` itself has no `parent_instance_id`
  parameter at all (confirmed by reading its full signature).
- `serialisePinnedVersions()` (the function that builds `INSTANCE_STARTED`'s payload) emits only
  the `pinned_versions` field — no `pin_inheritance_conflicts` field exists anywhere in
  `src/engine/instance.zig`'s payload construction.
- `grep -rn "pin_inheritance_conflicts\|inheritPins\|inheritParentPins" src/` returns matches only
  inside `src/design/pin-04-*.md` (the design document itself) — zero matches in any `.zig` source
  file.

This is a genuine implementation gap, not a test-design ambiguity. Per this repo's
"Unblock-Everything" / "No SkipZigTest on a MUST test" directives, **TC-PIN-04-03 and TC-PIN-04-04
below are written as real, runnable tests against the AC text as specified** — they are NOT
skipped, deferred, or watered down to match the current behaviour. They currently **FAIL** against
the implementation (confirmed live — see "Verified live" below), which is the correct fail-first
signal: the requirement's AC2/AC3 guarantee does not yet exist in production code. This is reported
as a BLOCKER issue in this handoff's `result.issues`, to be picked up by BACKEND-DEV in a follow-up
fix, per TEST-DESIGNER's canonical instructions ("If infrastructure is unavailable... ORCH will
create an ADHOC handoff" — the same escalation shape applies to a genuine pre-existing coverage gap
discovered mid-design).

AC1, AC4, AC5 (reconstruction-only, no sub-process inheritance involved) ARE fully implemented and
pass.

## Test Cases

### TC-PIN-04-01: reconstruction reads pins ONLY from the event log, never the live catalog
**Given:** an instance started with a real, resolved `catalog_entry` pin
**When:** the live `service_catalog` row is mutated AFTER instance start, then
`reconstructEffectivePins()` is called both before and after the mutation
**Then:** the reconstructed `resolved_id` for that reference is IDENTICAL before and after — the
catalog mutation has no effect on reconstruction's output
**Layer:** integration
**Acceptance criterion mapped:** PIN-04 AC1

### TC-PIN-04-02: reconstruction issues no read against the service catalog (negative-space)
**Given:** an instance started with a real, resolved `catalog_entry` pin
**When:** the `service_catalog` row is DELETED entirely, then `reconstructEffectivePins()` is
called
**Then:** reconstruction still succeeds and still reports the original pin entry — if
reconstruction issued any live catalog read, this would fail (missing row) or silently drop the
entry; neither happens
**Layer:** integration
**Acceptance criterion mapped:** PIN-04 AC5 (negative-space: a regression that adds a live catalog
read to reconstruction would make this test fail, since the row backing that read no longer
exists)

### TC-PIN-04-03: sub-process child inherits the parent's pin, tagged source=inherited — **CURRENTLY FAILING (implementation gap)**
**Given:** a parent instance and a SUB_PROCESS child definition both referencing the SAME
`service_id`; the parent starts first and pins a specific `resolved_id`; the live catalog is then
mutated (publishing what WOULD be a different resolution) before the child starts
**When:** the parent's HUMAN_TASK is completed, triggering the SUB_PROCESS child to start
**Then:** the child's OWN `INSTANCE_STARTED` payload carries, for the shared reference, `source =
"inherited"` and `resolved_id` equal to the PARENT's (not a fresh independent resolution)
**Layer:** integration
**Acceptance criterion mapped:** PIN-04 AC2
**Status:** FAILS against current implementation — see "IMPLEMENTATION GAP" section above.

### TC-PIN-04-04: a conflicting child-resolved version is recorded in the child's INSTANCE_STARTED payload — **CURRENTLY FAILING (implementation gap)**
**Given:** the same parent/child setup as TC-PIN-04-03, where the child's OWN independent
resolution (absent inheritance) would differ from the parent's already-fixed pin
**When:** the child starts
**Then:** the child's `INSTANCE_STARTED` payload carries a `pin_inheritance_conflicts` entry
naming the reference and the parent's version
**Layer:** integration
**Acceptance criterion mapped:** PIN-04 AC3
**Status:** FAILS against current implementation — see "IMPLEMENTATION GAP" section above.

### TC-PIN-04-05: GET /api/v1/instances/{id}/pins returns the effective set with source_event_id per entry
**Given:** an instance started with a real pin set (no rebind has occurred yet)
**When:** `handleGetPins()` is called for the instance
**Then:** HTTP 200 with a `pins` array where every entry carries a non-empty `source_event_id`
alongside `kind`, `ref`, `resolved_id`, `version`
**Layer:** integration
**Acceptance criterion mapped:** PIN-04 AC4

## Fail-first confirmation

TC-PIN-04-01/02/05 are NEW and were fail-first confirmed: TC-PIN-04-01 was confirmed by temporarily
making `reconstructEffectivePins()`'s `resolveServiceCatalogRef`-style lookup re-read the live
catalog on every call (bypassing the stored `INSTANCE_STARTED` payload) — the test then failed
because the `resolved_id` differed before/after the mutation. TC-PIN-04-02 needs no separate
fail-first construction beyond TC-PIN-04-01's: deleting the row is what makes a hypothetical live
read observable as a failure (missing relation / `InstanceNotFound`) rather than silently passing;
this was confirmed by re-running the same regression variant used for TC-PIN-04-01 against the
delete case, which produced a query failure as expected. TC-PIN-04-05 was confirmed against a
build that reverted `handleGetPins()` to return only `pinned_versions` without `source_event_id` —
the assertion on `source_event_id.string.len > 0` then failed to find the key at all. All temporary
changes were reverted immediately after confirming.

TC-PIN-04-03/04 are fail-first BY CONSTRUCTION against the current, unmodified implementation — no
temporary revert was needed since they already fail without any test-side mutation. This is
recorded here as their fail-first confirmation.

## Verified live (this handoff)

`zig build test-integration-pin04` — 3/5 pass (TC-PIN-04-01, -02, -05), 2/5 fail
(TC-PIN-04-03, -04) against a real PostgreSQL instance (`BPM_TEST_DB_URL`). The 2 failures are the
expected, correct signal for the AC2/AC3 implementation gap documented above — NOT a defect in the
test code.
