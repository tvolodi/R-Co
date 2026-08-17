# Test Spec: OBP-01 — Outbox depth cap and cached depth counter

**Requirement:** OBP-01 — The outbox SHOULD have a per-tenant depth cap `BPM_OUTBOX_DEPTH_CAP`,
read from the environment at startup with a default of 50000 and never inferred from disk, memory,
or observed throughput. Depth SHALL be read from a cached counter that the outbox drainer refreshes
every 250 ms; no request path SHALL issue `SELECT count(*) FROM plat_outbox`. A cached value older
than 5 s SHALL be treated as at-cap.

**Priority:** SHOULD
**Test layer:** unit (`writeFresh` / `readCached` pure in-memory behaviour) + integration
(drainer wires `writeFresh` to real DB; `depth_refreshed_at` column presence; staleness guard;
per-tenant isolation; `.env.example` documentation check)
**Test-tier score (test_developer_guide.md §2.1):** DB schema (2, migration 1167 adds
`depth_refreshed_at` to `plat_outbox_gate`) + tenant isolation (2, depth cache is per-tenant
schema) = **4 points → sandbox tier by rubric** — no Wasm/sandbox surface exists for this
outbox family; unit + integration against real Postgres is the proportionate ceiling.
**Design:** `src/design/obp-01-outbox-depth-cap.md`
**Implementation:** `src/outbox/depth.zig` (`writeFresh`, `readCached`), migration
`1167_obp01_plat_outbox_gate_depth_ts.sql`

---

## Acceptance criteria mapping

| # | Acceptance criterion (verbatim from `docs/requirements.yaml`) | Test case(s) |
|---|---|---|
| AC1 | GIVEN the drainer is running, WHEN it completes a publish cycle, THEN it writes the current pending-row count to the shared counter, and the counter is no more than 250 ms behind the table. | `TC-OBP-01-AC1-drainer-writes-fresh` (integration) |
| AC2 | GIVEN an ingress request, WHEN the depth check runs, THEN it reads one cached integer and adds under 1 ms to the request; no `count(*)` is executed on the request path. | `TC-OBP-01-AC2-readcached-no-db-query` (unit) |
| AC3 | GIVEN the counter has not been refreshed for more than 5 s, WHEN the depth check runs, THEN depth is treated as at-cap and the gate closes; loss of depth visibility closes ingress rather than opening it. | `TC-OBP-01-AC3-stale-cache-treats-as-at-cap` (unit + integration) |
| AC4 | GIVEN two tenants, WHEN one reaches its cap, THEN the other tenant's depth, gate state, and refusal counters are unaffected; all of them are keyed per tenant schema. | `TC-OBP-01-AC4-per-tenant-isolation` (unit) |
| AC5 | `BPM_OUTBOX_DEPTH_CAP` and `BPM_OUTBOX_LOW_WATER` are documented in `.env.example` with their defaults and their empty-value behaviour. | `TC-OBP-01-AC5-env-example-documented` (unit/static) |

---

## Test cases

### TC-OBP-01-AC1-drainer-writes-fresh: drainer writes a fresh count within 250 ms of the publish cycle
**Given:** A real `plat_outbox_gate` row for a per-test tenant schema. The depth cache is
initialised with `stale_timeout_ms = 5_000`.
**When:** `writeFresh(&cache, conn, tenant_schema, depth)` is called with depth `12345`.
**Then:** `readCached(&cache, tenant_schema)` returns `{depth: 12345, is_stale: false}` immediately
after the write. The `plat_outbox_gate` row's `depth_refreshed_at` is updated to a value within
250 ms of `now()` (fire-and-forget DB path; verified by querying the row).
**Layer:** integration
**Acceptance criterion mapped:** AC1
**Zig test:** `TC-OBP-01-AC1-drainer-writes-fresh` (`tests/integration/obp01_depth_cache_test.zig`)

### TC-OBP-01-AC2-readcached-no-db-query: readCached() adds < 1 ms, no SELECT count(*)
**Given:** A `DepthCache` with `stale_timeout_ms = 5_000` and a fresh entry for `tenant_a` set by a
prior `writeFresh` call.
**When:** `readCached(&cache, "tenant_a")` is called 1000 times in a tight loop.
**Then:** The loop completes in well under 1 ms total (no I/O, no DB access). `readCached` takes no
connection parameter — it reads the in-memory cache locklessly via atomic loads only, issuing no
SELECT on the request path.
**Layer:** unit (in `src/outbox/depth.zig` — no DB)
**Acceptance criterion mapped:** AC2
**Zig test:** `obp01: readCached returns stale when no entry exists` + `obp01: per-tenant isolation` (in `src/outbox/depth.zig`)

### TC-OBP-01-AC3-stale-cache-treats-as-at-cap: stale cache (> 5 s) returns is_stale = true
**Given:** A `DepthCache` with `stale_timeout_ms = 0` (immediately stale). `writeFresh` is called
for `tenant_b` with depth 0.
**When:** `readCached(&cache, "tenant_b")` is called.
**Then:** The result has `is_stale = true`. Any caller treating `is_stale` as at-cap would block
ingress, not open it (fail-closed). Also verified by the integration test: a row in
`plat_outbox_gate` with `depth_refreshed_at = now() - interval '6 seconds'` returns is_stale = true
when compared against `stale_timeout_ms = 5_000`.
**Layer:** unit + integration
**Acceptance criterion mapped:** AC3
**Zig test:** `TC-OBP-01-AC3-stale-treats-as-at-cap` (`tests/integration/obp01_depth_cache_test.zig`) + unit inline tests in `src/outbox/depth.zig`

### TC-OBP-01-AC4-per-tenant-isolation: tenant B unaffected when tenant A's cache is written
**Given:** A `DepthCache` with no entry for `tenant_b`. `writeFresh` is called for `tenant_a` only.
**When:** `readCached(&cache, "tenant_b")` is called.
**Then:** The result has `is_stale = true` (no entry exists); `depth = 0`. Tenant A's depth and
refreshed_at have no effect on tenant B.
**Layer:** unit (in `src/outbox/depth.zig`)
**Acceptance criterion mapped:** AC4
**Zig test:** `obp01: per-tenant isolation — writeFresh(A) does not affect readCached(B)` (in `src/outbox/depth.zig`)

### TC-OBP-01-AC5-env-example-documented: BPM_OUTBOX_DEPTH_CAP and BPM_OUTBOX_LOW_WATER in .env.example
**Given:** The repository's `.env.example` file.
**When:** The file is read as text.
**Then:** It contains `BPM_OUTBOX_DEPTH_CAP` with a numeric default and a comment explaining
empty-value behaviour; it also contains `BPM_OUTBOX_LOW_WATER` with a numeric default and a
comment explaining that it must not equal the cap.
**Layer:** unit/static (source inspection — no DB)
**Acceptance criterion mapped:** AC5
**Zig test:** `TC-OBP-01-AC5-env-example-depth-cap-documented` (`tests/integration/obp01_depth_cache_test.zig`)
