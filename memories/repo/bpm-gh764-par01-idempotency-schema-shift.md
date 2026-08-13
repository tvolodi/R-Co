# PAR-01 schema shift: events(idempotency_key) lost its UNIQUE index

## Symptom
Integration tests that issue `INSERT INTO events ... ON CONFLICT (idempotency_key) DO NOTHING`
fail deterministically with:
```
ERROR: there is no unique or exclusion constraint matching the ON CONFLICT specification
```
SQLSTATE 42P10. Wrapped as `PoolError.QueryFailed` (src/db/pool.zig:526) and surfaced by tests as
"Unexpected error during replay insert: error.QueryFailed".

## Root cause
Pre-PAR-01: `migrations/001_event_store.sql:49` declared
`CREATE UNIQUE INDEX uq_event_idempotency ON events(idempotency_key)`.

PAR-01 (shipped in commit `38cb7967`, migration `1147_par01_events_partitioning.sql:162-164`)
**deliberately dropped** that index because partitioned tables can only enforce uniqueness across
all partitions via the partition key — i.e. an `events(idempotency_key)` UNIQUE index would have
silently narrowed uniqueness to per-partition scope, which PAR-01 AC2 forbids. Global
idempotency-key uniqueness now lives in the sidecar table `plat_event_idempotency` (PRIMARY KEY
on `idempotency_key`), created by the same migration at lines 176-201.

## Where the production code path uses the new schema correctly
`src/event_store/store.zig:288-294` and `src/scheduler/scheduler.zig:938` already issue
`INSERT INTO plat_event_idempotency (idempotency_key, ...) ... ON CONFLICT (idempotency_key) DO NOTHING`
correctly.

## Tests that need to be updated to match
Anything that runs `INSERT INTO events ... ON CONFLICT (idempotency_key) DO NOTHING` against
post-PAR-01 schemas must be rewritten to:
1. First upsert into `plat_event_idempotency` (using `ON CONFLICT (idempotency_key) DO NOTHING
   RETURNING event_id, created_at`), then
2. INSERT INTO events SELECT ... WHERE NOT EXISTS (SELECT 1 FROM plat_event_idempotency WHERE
   idempotency_key = $1)

Known affected test:
- `tests/integration/iss203_idempotency_keys_test.zig:367-380` — TC-ISS-203-02 (replay dedup)

## Diagnosis trap
When triaging "ON CONFLICT DO NOTHING failed" errors, ALWAYS run a direct
`psql`/docker-compose probe against the test DB before assuming the test code is right. A live
PG probe in <2s tells you whether the target column has a unique constraint. Saves a long
investigation into "is this a wrapping issue in pg.zig / pool.zig" — it almost never is.

## Lint bookkeeping trap: registry handoff_id format
`tools/lint_handoffs.py` matches registry entries to handoff files via the file's own
`handoff_id` field. The file format the rest of the codebase uses is:
`"handoff_id": "<RUN_ID>/step-<NN>-<AGENT>"` (slash separator, upper case RUN_ID — matching the
filename). The grep_search across the registry shows pre-existing entries used
`"handoff_id": "wf03-gh764-20260813-01-issue-fixer"` (lowercase, dashes) — that's the format a
predecessor author wrote, but it FAILS the lint H010 (handoff absent from registry) because the
file's own handoff_id doesn't match. When adding new entries, prefer the file's own handoff_id
verbatim.