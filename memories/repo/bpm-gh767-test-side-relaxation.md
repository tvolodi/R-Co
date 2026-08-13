# WF03-GH767-20260813 — Test-side relaxation pattern (inverse of "fix the test")

## Context

ISS-0701 / GH-767: `tests/integration/env01_test.zig` TC-ENV-01-03 was failing
because the production-row invariant excluded rows that didn't match
`tenant_type='production'`. The default-tenant fixture (slug='default') has
`tenant_type='test'` with a non-null `production_tenant_id`, introduced by
commit `a2eea7a1` to prevent ISS-0112 drift. The test invariant was too strict:
it assumed "any non-tc-env01 row must be production-typed" — but the default
fixture is *intentionally* test-typed.

## The decision

The fix went on the **test side**, not the fixture side:

```zig
// Before — too strict:
WHERE tenant_type = 'production'
   OR (id NOT IN (SELECT id FROM _env01_fixture))

// After — also exclude the deliberately-test default:
WHERE tenant_type = 'production'
   OR (id NOT IN (SELECT id FROM _env01_fixture) AND slug <> 'default')
```

The parenthesisation of the `OR` group was also required — without it the
`AND slug <> 'default'` would bind to the wrong operand.

## Why this is the inversion of the usual rule

The usual guidance is "fix the test, not the code" — when a test breaks because
production code changes, the test is usually wrong. But here, the **fixture
code** (`a2eea7a1` in helpers.zig) deliberately introduced a violating row to
prevent a *different* drift bug (ISS-0112). The fixture is intentionally
non-production. Relaxing the test invariant is correct because:

1. The fixture is *not* a transient setup mistake — it's a permanent design
   choice.
2. Reverting the fixture would re-introduce ISS-0112.
3. The test was checking the wrong invariant anyway — "all non-fixture rows
   are production-typed" overreaches when there's a third legitimate class
   (the system default, which is non-production by definition).

## Test for this pattern in future triage

When a test invariant breaks and a fixture was changed recently:

1. **Look at the fixture commit's diff** — is the new value defending against
   another known bug (search for related ISS/GH references in the commit
   message or PR body)?
2. **Look at the fixture's intent** — is it intentionally different from the
   test's assumed invariant, or did the fixture drift by accident?
3. **If intentional**: relax the test. Document the relaxation with a comment
   that cites the defending bug (so future readers don't try to "fix" the
   fixture).
4. **If accidental**: revert the fixture change (or add a migration that
   restores the old invariant). Then the test stays as-is.

## References

- Commit `a2eea7a1` — default tenant fixture change (defending against ISS-0112)
- Commit `2da073a4` — test-side relaxation (this workflow's fix)
- PR #779 — squash-merged to main
- GH-767 — closed as COMPLETED at 2026-08-13T19:30:36Z
- ISS-0701 — RESOLVED
- ISS-0112 — the drift bug the fixture defends against