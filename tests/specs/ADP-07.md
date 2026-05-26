# Test Spec: ADP-07 -- Agent role and reserved usernames

**Requirement:** ADP-07 -- Add `AGENT_RUNNER` as a grantable role, reserve `agent:` usernames for agent identities, reject non-`PLATFORM_ADMIN` creation of `agent:*` usernames, allow `PLATFORM_ADMIN` creation for `agent:*`, and preserve existing behavior for non-agent identities.
**Priority:** MUST
**Test layer:** integration

## Test Cases

### TC-ADP-07-01: AGENT_RUNNER role is seeded and token issuance accepts it
**Given:** ADP-07 migration `034_adp07_agent_role_reserved_usernames.sql` is applied and an admin-created user exists.
**When:** A token is issued for that user with requested roles containing `AGENT_RUNNER`.
**Then:** `roles` contains `AGENT_RUNNER` in persisted role catalog and issued token role JSON includes `AGENT_RUNNER`.
**Layer:** integration
**Acceptance criterion mapped:** `AGENT_RUNNER` is a new, grantable role.
**Implemented by:** `tests/integration/adp07_agent_role_reserved_usernames_test.zig` test `TC-ADP-07-01`.

### TC-ADP-07-02: non-admin actor cannot create agent-prefixed usernames
**Given:** A non-admin actor context.
**When:** User creation is requested with mixed-case reserved prefix username `AgEnT:tc-adp-07-02`.
**Then:** Service rejects with `IdentityError.ReservedUsernameRequiresPlatformAdmin`.
**Layer:** integration
**Acceptance criterion mapped:** A regular user cannot register a username starting with `agent:`.
**Implemented by:** `tests/integration/adp07_agent_role_reserved_usernames_test.zig` test `TC-ADP-07-02`.

### TC-ADP-07-03: PLATFORM_ADMIN can create agent-prefixed usernames
**Given:** A `PLATFORM_ADMIN` actor context.
**When:** User creation is requested with username `agent:tc-adp-07-03`.
**Then:** User creation succeeds and persisted username equals requested reserved username.
**Layer:** integration
**Acceptance criterion mapped:** A `PLATFORM_ADMIN` can register `agent:*` usernames.
**Implemented by:** `tests/integration/adp07_agent_role_reserved_usernames_test.zig` test `TC-ADP-07-03`.

### TC-ADP-07-04: JIT OIDC path also rejects reserved prefix
**Given:** A tenant binding and OIDC JIT user input with `preferred_username = agent:jit-adp07`.
**When:** JIT provisioning path `createOrGetJitOidcUser` executes without admin override context.
**Then:** Service rejects with `IdentityError.ReservedUsernameRequiresPlatformAdmin`.
**Layer:** integration
**Acceptance criterion mapped:** Reserved username policy is enforced consistently across identity creation surfaces.
**Implemented by:** `tests/integration/adp07_agent_role_reserved_usernames_test.zig` test `TC-ADP-07-04`.

### TC-ADP-07-05: non-agent identities remain compatible on create path
**Given:** A `PLATFORM_ADMIN` actor context and non-reserved username `tc-adp-07-05-user`.
**When:** User creation runs through the same identity service path used by reserved-prefix enforcement.
**Then:** User creation succeeds, proving reserved-username checks do not regress non-agent create behavior.
**Layer:** integration
**Acceptance criterion mapped:** No-regression behavior for non-agent identities.
**Implemented by:** `tests/integration/adp07_agent_role_reserved_usernames_test.zig` test `TC-ADP-07-05`.

## Traceability Matrix

| Requirement / acceptance area | Concrete test evidence |
|---|---|
| ADP-07: AGENT_RUNNER is a new grantable role | `TC-ADP-07-01` and migration `migrations/034_adp07_agent_role_reserved_usernames.sql` |
| ADP-07: non-admin cannot create `agent:*` usernames | `TC-ADP-07-02` |
| ADP-07: `PLATFORM_ADMIN` can create `agent:*` usernames | `TC-ADP-07-03` |
| ADP-07: enforcement is consistent across implemented identity surfaces | `TC-ADP-07-04` |
| ADP-07: no-regression for non-agent identities | `TC-ADP-07-05` |

## Coverage Gaps Identified

- None for ADP-07 acceptance criteria in this handoff. Covered surfaces include role grantability, reserved-prefix enforcement (deny/allow), JIT consistency, and non-agent compatibility.

## Execution Notes For TEST-RUNNER

- Required env: `BPM_TEST_DB_URL` pointing to PostgreSQL integration database.
- Execute integration suite entrypoint via `zig build test-integration` to run `TC-ADP-07-*`.
- Assertions are deterministic (fixed usernames, fixed actor contexts, fixed tenant binding IDs, and direct persisted-row checks).
