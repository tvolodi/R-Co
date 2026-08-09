# Module: fix-ISS-0637 — remove stale `::uuid` cast on `audit_entries.resource_id` comparisons in TC-EXT-02-INT-08

## Summary

GitHub #619 / ISS-0637 (MAJOR). `TC-EXT-02-INT-08` in
`tests/integration/ext02_webhook_dispatch_test.zig` fails with
`PgError.ServerError`. The GitHub issue's body speculated the cause was
`pool.Conn` losing `search_path` after `COMMIT` (a `SET LOCAL` reverting
outside its transaction, producing `42P01 relation "audit_entries" does not
exist`).

**That theory is refuted.** Diagnosis (ISSUE-FIXER Step 1, this run) confirmed
by source inspection:

- `src/db/pool.zig`'s `applyRequestStorageRouting()` issues a plain
  session-scoped `SET search_path TO tenant_default,public` on every
  `Pool.acquire()` — never `SET LOCAL`. It persists for the life of the held
  connection and is reset to `public` only in `Pool.release()`. `TC-EXT-02-
  INT-08` acquires one connection (`conn`) and holds it for the whole test
  body, so its `search_path` never reverts mid-test.
- `SET LOCAL search_path` does exist elsewhere in this codebase
  (`src/db/migrations.zig`, `src/event_store/store.zig`, per ISS-0128/
  ISS-0130) but those are unrelated subsystems (migration runner, event
  store), not the webhook/audit path this issue concerns. The issue's
  speculation appears to have pattern-matched from that unrelated fix.

The **actual** root cause, captured by rebuilding a narrow diagnostic step
(`zig build test-integration-ext02 -Dlog-pg-errors=true`, added to
`build.zig` this run) to surface the real PostgreSQL wire-protocol error text
(normally swallowed — `vendor/pg/pg.zig`'s `log_pg_errors` build option
defaults to `false` per ISS-0607/GH-542):

```
POSTGRES ERROR: C42883 operator does not exist: text = uuid
```

`migrations/GBL-120_iss103_audit_resource_id_text.sql` (ISS-103) altered
`audit_entries.resource_id` from `UUID` to `TEXT` in **every** schema (it
loops on `current_schema()`, not just `public` — the `GBL-` filename prefix
is misleading here; this migration is not public-only). `tests/integration/
ext02_webhook_dispatch_test.zig` lines 687 and 702 still write
`resource_id = $1::uuid`, comparing a `TEXT` column against a `UUID`-cast
parameter. PostgreSQL has no implicit `text = uuid` operator, so this fails
unconditionally with C42883 — independent of search_path, schema routing, or
connection pooling. This is a **CATEGORY E (test code error)** per WF-03
Step 1's failure taxonomy: the source/trigger code is correct; the test has
a stale type expectation left over from before ISS-103 changed the column
type. It was previously masked by an unrelated compile/relation error
(C42703, fixed by ISS-0635's migration 1138) that made the test fail earlier
for a different reason before ever reaching this query.

## Fix scope confirmation

1 file:

- `tests/integration/ext02_webhook_dispatch_test.zig` — remove the `::uuid`
  cast on both `resource_id = $1` comparisons in `TC-EXT-02-INT-08` (lines
  687, 702). `created.subscription_id` is already formatted as a canonical
  UUID string; comparing it against a `TEXT` column with no cast on either
  side is correct and matches the pattern already used successfully by every
  other `queryText`/`conn.query` call in this same file that targets a
  `TEXT` column (e.g. `status`, `action`).

No source (`src/`) or migration change is required — the trigger function
(`bpm_audit_on_mutation()`, `migrations/024_webhook_subscription_audit.sql`)
already produces a correctly-typed `TEXT` `resource_id` via `(src->>'id')::uuid`
being written into a `TEXT` column by ordinary implicit `uuid → text` output
casting on `INSERT`, which Postgres allows (the restriction is specifically
on comparison operators, not on assignment/insert casting). Only the test's
query-side comparison is wrong. Total: 1 file, well within the ≤5 constraint.

## Public function signatures before/after

None. This is a SQL literal change inside a test file; no Zig function
signature changes.

## Error taxonomy changes

None. No `error{}` set changes anywhere in `src/`.

## Required change (structural, not literal diff)

In `tests/integration/ext02_webhook_dispatch_test.zig`, function-scoped
inside `test "TC-EXT-02-INT-08: ..."`:

```
- \\  AND resource_id = $1::uuid
+ \\  AND resource_id = $1
```

applied to both occurrences (the `webhook_subscription.create` count query
and the `webhook_subscription.delete` count query immediately below it).
`created.subscription_id` (the `$1` bind value, a `[]const u8`) is unchanged
— it is still a valid UUID-format string, which PostgreSQL compares
correctly against a `TEXT` column with a plain `text = text` comparison and
no cast required on either side.

## Callers / scripts impacted

None outside the one test file. `webhook_store.createSubscription` and
`webhook_store.deleteSubscription` (`src/webhook/subscription_store.zig`)
are unchanged — they do not query `audit_entries` at all; they only set
`bpm.actor_id`/`bpm.audit_action` session config that the `AFTER INSERT/
UPDATE/DELETE` trigger on `webhook_subscriptions` reads.

## Incidental discovery — not fixed here

The same `resource_id = $1::uuid` pattern, and therefore the same C42883
failure, independently exists in `tests/integration/adp02_tenant_scope_test.zig`
(`TC-ADP-02-05`, lines 530/549 — confirmed by the same standalone diagnostic
technique). This is filed separately as ISS-0638 / GitHub #621 and forwarded
to the global queue per the one-issue-one-run rule; it is out of scope for
this fix and is not touched on this branch.

## Verification expectations

TEST-RUNNER (Step 5) should confirm, via `zig build test-integration-ext02`
(the narrow step added this run) and the full `zig build test-integration`
suite:

1. `TC-EXT-02-INT-08` passes.
2. No regression in the other 9 EXT-02 tests in the same file (baseline:
   8/10 passing before this fix, with `TC-EXT-02-INT-05` — signature header
   — failing for an unrelated, pre-existing reason not touched by this fix).
3. No new failures introduced elsewhere in the suite.

## Open questions

None blocking.
