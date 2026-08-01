# Test-harness lock-timeout bracket pattern

## The pattern

When widening a critical section around a Postgres advisory lock in the
integration test harness, you must ALSO bracket every OTHER advisory-lock
acquire in the same TestHarness.init() (or equivalent bootstrap) with a
`SET lock_timeout = '<large>'` / `SET lock_timeout = '<ambient>'` pair —
not just the one acquire you widened.

## Why

Widening one critical section increases queue depth for OTHER acquires
that block on the same lock key (here: `bpm_test_migrations_public`).
The ambient `lock_timeout` (5s in this repo's helpers.zig) was tuned
for the narrower queue depth and will start cancelling those OTHER
acquires with 55P03 once enough binaries queue behind the widened
section.

## Verified failure mode (2026-08-01, GH-366)

`tests/integration/helpers.zig` `TestHarness.init()` has TWO
advisory-lock acquires of the same key
(`pg_advisory_lock(hashtext('bpm_test_migrations_public'))`):

| Line | Function        | Bracketed by 90s? | Status pre-fix |
|------|------------------|-------------------|-----------------|
| 99   | `runMigrations()` | NO               | 55P03 under load |
| 487  | `init()` widened section | YES (ISS-0107 rework-1) | OK |

fc5884b (ISS-0107 rework-1) bracketed only line 487. The line-99
acquire still ran under the ambient 5s lock_timeout. After the line-487
section was widened, queue depth at line-99 grew to the point where
later-queued binaries' line-99 acquires waited past 5s and got cancelled
by Postgres with 55P03. The repro was reproducible on a freshly-
migrated, empty-row db_test container — confirms it is a code defect,
not environment drift.

## Fix shape

Apply the same SET/SET bracket to line 99:

```zig
try conn.exec("SET lock_timeout = '90s'", &.{});
try conn.exec("SELECT pg_advisory_lock(hashtext('bpm_test_migrations_public'))", &.{});
try conn.exec("SET lock_timeout = '5s'", &.{});
```

Plain sequential SET/SET, not SET LOCAL (the connection is not inside a
transaction at this point). Mirrors the proven pattern at line 487.
No retry, no sleep, no driver change. Stays within the <=5 file Fix
Scope Rule.

## Diagnostic shortcuts

- `select-string -path tests/integration/helpers.zig -pattern 'pg_advisory_lock'` — every acquire site.
- `select-string -path <captured-log> -pattern 'helpers.zig:\d+'` — every stack-frame
  reference; group by file:line to find the failing acquire site.
- Search for both 40P01 (deadlock) AND 55P03 (lock-timeout) when
  investigating concurrent integration failures — they often co-occur
  in the same log because both are queue-depth symptoms.