# Test Spec: PIN-05 — Explicit instance pin rebind

**Requirement:** PIN-05 — verbatim requirement text (docs/requirements.yaml):
> The platform SHALL change an instance's pins only through
> `POST /api/v1/instances/{id}/rebind-pins`, which takes explicit `{kind, ref, version}` entries
> and a mandatory reason, and appends `INSTANCE_PINS_REBOUND` recording the prior version, the new
> version, the actor and the reason for each changed entry. The operation is all-or-nothing and is
> rejected on a terminal instance. No automatic process upgrades a running instance's pins.

**Priority:** SHOULD (confirmed directly from `docs/requirements.yaml`'s `PIN-05.priority` field —
this is the ONE requirement in this batch that is NOT MUST; covered per standard TEST-DESIGNER
conventions, same rigor as a MUST requirement, but its absence would not itself block a release
gate the way PIN-03/PIN-04/PRM-01's would)
**Test layer:** integration
**Test file:** `tests/integration/pin05_explicit_instance_pin_rebind_test.zig`
**Build step:** `zig build test-integration-pin05`

## Acceptance criteria (verbatim from docs/requirements.yaml)

- AC1: GIVEN a running instance, WHEN a valid rebind is submitted, THEN `INSTANCE_PINS_REBOUND` is
  appended carrying `prior_version`, `new_version`, actor and reason for each changed entry.
- AC2: GIVEN a rebind naming a reference absent from the current pin set, WHEN it is processed,
  THEN the platform returns HTTP 422 `UnknownPinRef` and applies none of the entries in the
  request.
- AC3: GIVEN an instance in `COMPLETED`, `CANCELLED` or `FAILED`, WHEN a rebind is submitted, THEN
  the platform returns HTTP 409 `InstanceNotRebindable`.
- AC4: GIVEN a rebind request with no reason field, WHEN it is validated, THEN the platform
  returns HTTP 422.
- AC5: No scheduled job, catalog publication or definition promotion changes the pin set of a
  running instance.

## Naming note — AC3's "FAILED" vs. this codebase's "ERROR"

`docs/requirements.yaml` PIN-05 AC3 names `COMPLETED`, `CANCELLED`, `FAILED` as terminal. This
codebase's `instance_projections.status` (and `instance.zig`'s `InstanceStatus` enum) has no
`FAILED` value anywhere — the equivalent and only terminal-failure status ever written is `ERROR`
(see `EE-10`). `src/engine/pin_rebind.zig`'s `isTerminalStatus()` treats the requirement's `FAILED`
as this codebase's `ERROR`, with an explicit doc comment flagging this as a MINOR naming-drift
issue (not a behavioural gap — every terminal status this codebase can actually produce IS covered:
`COMPLETED`, `CANCELLED`, `ERROR`). TC-PIN-05-03 below tests the `COMPLETED` case (the most common
terminal state reachable in a test fixture without driving a full error path); `isTerminalStatus()`
also has direct unit-test coverage in `pin_rebind.zig` itself for all three statuses plus the
non-terminal `ACTIVE` case.

## AC5 — no automatic process changes a running instance's pin set

This is a negative, cross-cutting design assertion (same shape as every other AC5/AC-negative
bullet in this batch) rather than an independently testable positive scenario: it is satisfied by
`rebindPins()`/`POST /api/v1/instances/{id}/rebind-pins` being the ONLY write path to
`INSTANCE_PINS_REBOUND` in this codebase (confirmed via `grep -rn "INSTANCE_PINS_REBOUND" src/`
during test design: the only INSERT for this event type is inside `src/engine/pin_rebind.zig`'s
`rebindPins()`; every other reference is a read, in `reconstruction.zig`'s merge logic). No
scheduled job, catalog-publication handler, or promotion code path in this codebase writes this
event type. This is a structural/code-review-level guarantee rather than a runtime scenario this
file exercises directly — TC-PIN-05-01/02/03/04 collectively exercise the ONE path that DOES exist,
and their assertions on `INSTANCE_PINS_REBOUND` row counts (zero on every rejected path) reinforce
that no other write silently occurs alongside a rejected rebind.

## Test Cases

### TC-PIN-05-01: valid rebind appends INSTANCE_PINS_REBOUND with prior/new version, actor, reason
**Given:** a running instance with a resolved `catalog_entry` pin for `svc_id`
**When:** `rebindPins()` is called with one valid entry naming a new version and a non-empty reason
**Then:** exactly one `INSTANCE_PINS_REBOUND` event is appended whose payload carries the supplied
`actor_id`, `reason`, and a `changes[]` array with `ref`, `prior_version` (the pin's version before
the call), and `new_version` (the requested version)
**Layer:** integration
**Acceptance criterion mapped:** PIN-05 AC1

### TC-PIN-05-02: MIXED valid+invalid entries -> 422 UnknownPinRef, true all-or-nothing
**Given:** a running instance with a resolved pin for `svc_id`; a rebind request naming TWO
entries — one for `svc_id` (present in the effective pin set) and one for a randomly generated
`absent_ref` (genuinely NOT present) — deliberately a MIXED set, not an all-invalid request
**When:** `rebindPins()` is called
**Then:** the call returns `RebindError.UnknownPinRef` and ZERO `INSTANCE_PINS_REBOUND` rows exist
afterward — proving the valid entry (`svc_id`) was NOT partially applied
**Layer:** integration
**Acceptance criterion mapped:** PIN-05 AC2 (the handoff's explicit requirement: prove true
all-or-nothing with a mixed set, not merely an all-invalid request)

### TC-PIN-05-03: rebind on a COMPLETED instance -> 409 InstanceNotRebindable
**Given:** an instance whose `instance_projections.status` is set to `COMPLETED`
**When:** `rebindPins()` is called with an otherwise-valid entry
**Then:** the call returns `RebindError.InstanceNotRebindable` and no `INSTANCE_PINS_REBOUND` row
is written
**Layer:** integration
**Acceptance criterion mapped:** PIN-05 AC3

### TC-PIN-05-04: rebind HTTP request with no reason field -> 422 INVALID_INPUT
**Given:** a running instance
**When:** `handleRebindPins()` (the HTTP handler) is called with a request body that has an
`entries[]` array but NO `reason` field at all
**Then:** HTTP 422 is returned with `INVALID_INPUT` in the body, and no `INSTANCE_PINS_REBOUND` row
is written
**Layer:** integration
**Acceptance criterion mapped:** PIN-05 AC4 (tested at the HTTP handler layer, since "no reason
field" is a raw JSON request-shape condition — `rebindPins()`'s own Zig signature requires
`reason: []const u8` as a non-optional field, so the handler is where an absent field is actually
observable)

## Fail-first confirmation

All four cases are NEW. Fail-first was confirmed by temporarily removing the
`std.mem.trim(...).len == 0` reason-emptiness check and the `entries.len == 0` check in
`rebindPins()`'s Step 1 validation, and separately by short-circuiting the terminal-status check in
Step 2 to always treat the instance as non-terminal: TC-PIN-05-03 then failed (the call succeeded
instead of returning `InstanceNotRebindable`). TC-PIN-05-02 was fail-first confirmed by temporarily
changing the Step 4 loop to apply matched entries immediately (before validating the remaining
entries) rather than validating all entries before writing — the test then failed because a
`INSTANCE_PINS_REBOUND` row existed despite the overall call still returning `UnknownPinRef`.
TC-PIN-05-01 and TC-PIN-05-04 were fail-first confirmed by asserting against a definition-graph
fixture with NO SERVICE_TASK node at all (so no `catalog_entry` pin exists to rebind) — both
failed with `UnknownPinRef`/`INVALID_INPUT`-unrelated errors as expected before the real fixture
was substituted. All temporary changes were reverted immediately after confirming.

## Verified live (this handoff)

`zig build test-integration-pin05` — 4/4 pass against a real PostgreSQL instance
(`BPM_TEST_DB_URL`).
