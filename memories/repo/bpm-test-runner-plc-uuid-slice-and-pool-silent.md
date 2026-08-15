# BPM Test Runner — PLC integration: pool.zig swallowing + UUID slice mismatch

## Two recurring traps in PLC-01..04 integration tests

### Trap 1: `src/db/pool.zig:564` swallows every Postgres error

```zig
// src/db/pool.zig — current behavior
return PoolError.QueryFailed;  // no SQLSTATE, no message
```

Every non-ConnectionFailed PgError from `vendor/pg/pg.zig readUntilReady` is mapped
to `PoolError.QueryFailed` with NO message. The repository then maps that to
`ModuleCatalogError.TransactionFailed`. The Zig stack shows only
TransactionFailed; the actual Postgres error is invisible to the test runner.

This makes diagnosis impossible without either:
- Instrumenting the pool to log SQLSTATE + message at WARN level (gated on
  a debug flag), OR
- Reproducing the SQL directly via docker-compose exec -T db_test psql.

Verified today (reworks 6-8): the pool silently ate errors from at least three
unrelated defects — Status literal syntax error (rework 6), pool failures
on the AFTER-fix registerModule (rework 8), and listVisibleModules parameter
mismatch (rework 8). The TestHarness even marks the harness's own connection
with a per-process owner tag (ISS-0602) but the pool layer still doesn't
expose errors.

When you see `ModuleCatalogError.TransactionFailed` in a PLC test, do NOT
trust the stack trace to find the cause. Reproduce the SQL via psql first.

### Trap 2: UUID column slice lengths in Zig tests

`process_module_catalog` and other UUID columns return 36 chars (hyphenated
UUID v4) when fetched via `conn.query()` as text. The Zig 0.16 std lib
`std.fmt.hexToBytes` parses 32 hex chars (no dashes) — passing `[0..32]`
of a 36-char result returns `error.InvalidCharacter`.

Verified today (rework 8 — TC-PLC-04-05):
```zig
// ❌ fails — slice too short, then hexToBytes chokes on dashes
_ = try std.fmt.hexToBytes(&grant_id_bytes, grant_id_row[0..32]);

// ✅ works — slice full UUID, then strip dashes before hexToBytes
var hex_buf: [36]u8 = undefined;
@memcpy(hex_buf[0..36], grant_id_row[0..36]);
// strip dashes and call hexToBytes on the 32-char hex
```

Or simpler: pull the raw 16-byte UUID via bytea decode if the column is bytea.
process_module_catalog's PK is varchar, so the slice-and-strip pattern is the
fix.

### Connection: pool.zig talking to bpm_test DB on port 5434

The PLC integration tests use `BPM_TEST_DB_URL=postgres://bpm:bpm@localhost:5434/bpm_test`
(direct DB connection, NOT the backend HTTP server). The backend on :8080 also
hits the same DB but via a separate connection pool. So:

- If a test wants to verify SQL behavior, use `docker-compose exec -T db_test psql -U bpm -d bpm_test -c "..."`
- If the backend log is silent, it's because the test traffic does NOT flow through
  the backend — the test has its own pg.zig connection.
- Backend logs only show what the backend HTTP server itself does (e.g. health
  checks, API requests).

### Other PLC-01..04 quirks seen across rewrites

- `makePool(alloc)` is the correct Zig 0.16 syntax — `makePool(&alloc)` was
  the pre-0.16 form. The TEST-RUNNER handoff's prior commit 334041f7 fixed this.
- `process_module_catalog` has 9 columns: module_id, version, owning_tenant_id,
  owning_definition_id, interface_schema, exportable, status, created_at,
  updated_at. Constraints: PK, CHECK on status, UNIQUE(module_id, version).
  No FK constraints.
- `interface_schema` is `jsonb NOT NULL` — you cannot pass NULL, you must
  pass `'{}'` or a real JSON object. Tests that pass empty/null break.
- `tc-PLC-04-05` slice bug: `grant_id_row[0..32]` is wrong length; should be
  `grant_id_row[0..36]` with dash stripping.
- `tc-PLC-03-05` seed bug: publishing a new version when the prior module has
  no interface_schema triggers `InterfaceNotDeclared` in production code but
  the test expects "no warning". Either test seed needs a sentinel schema, or
  publishModule must distinguish "absent prior + absent new" (no warning) from
  "absent prior + new has schema" (warning). Currently always returns
  InterfaceNotDeclared when prior is absent.
