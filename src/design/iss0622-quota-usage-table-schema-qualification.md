# ISS-0622 / GH-576 — Schema-qualify PER_TENANT usage reads in `quota_enforcement.zig`

**Run ID:** WF03-GH576-20260808
**Issue:** [GH-576](https://github.com/tvolodi/R-Co/issues/576) (ISS-0622)
**Classification:** Type E (cross-cutting middleware business logic — schema/storage-mode
routing is explicitly cross-cutting and cannot be templated per `templates/lego-catalog.md`
selection rule 5; it is also not a CRUD endpoint, migration, list page, or React Flow node)
**Step:** WF-03 Step 2 — CODE-DESIGNER fix design
**Related:** `docs/issues/ISS-0622.json`, `docs/issues/ISS-0617.json` (sibling,
`repository_artifacts`-only fix, already merged — see
`src/design/iss0617-test-fixture-schema-qualification.md`), `docs/anti-patterns.md`
ISS-0185/GH-518 entry (dual-schema-shadow anti-pattern this design must not reintroduce)

Covers: ISS-0622

---

## 0. Module purpose

`src/api/middleware/quota_enforcement.zig` is the central quota-enforcement middleware:
given a tenant and a `QuotaGuardTarget`, it reads current usage for the relevant quota
dimensions and rejects the request with `429` when a configured limit would be exceeded.
This design's purpose is narrow: fix `readUsageForDimension` and its leaf helpers
(`countRows`, `countRowsWhereRecent`, `maxColumn`, and — per §7's note — `tableStorageBytes`)
so their reads against the genuine `PER_TENANT`-only tables `instance_projections`,
`instance_waits`, and `dead_letter_items` are schema-qualified per the request's resolved
`storage_mode`, instead of relying on an unqualified `search_path` that is structurally
incomplete for `.LEGACY_RLS`-mode tenants. No other responsibility of this module
(`check()`'s dispatch logic, `classifyTarget()`, the quota-policy loading/evaluation it
calls into) changes.

## 1. Problem restated precisely

`src/api/middleware/quota_enforcement.zig`'s `readUsageForDimension` (line 143) dispatches
to four helpers — `countRows` (175), `countRowsWhereRecent` (209), `sumColumn` (237),
`maxColumn` (269) — each of which independently calls `pool.acquire()` and issues a SQL
string literal with **no schema qualification** against one of:

- `instance_projections` (via `countRows`, dimensions `.entity_records` / `.concurrent_sandboxes`
  — the latter actually queries `instance_waits`, see below)
- `instance_waits` (via `countRows`, dimension `.concurrent_sandboxes`)
- `dead_letter_items` (via `countRowsWhereRecent` and `maxColumn`, dimensions
  `.agent_retry_per_day` / `.agent_retry_per_job`)
- `repository_artifacts` (via `countRows` and `sumColumn`, dimensions `.file_count` /
  `.file_bytes` — **already correct, not touched by this design**, see §4)

`instance_projections`, `instance_waits`, and `dead_letter_items` are genuine `PER_TENANT`
tables that exist only inside a tenant schema (`tenant_default` for the legacy/default
routing path, `tenant_{slug}` for a `SCHEMA`-mode tenant) — never in `public`. Every
`pool.acquire()` call runs through `src/db/pool.zig`'s `applyRequestStorageRouting`
(pool.zig:258-301), which for `.LEGACY_RLS` mode (pool.zig:277-283) issues exactly
`SET search_path TO public` with **no** `tenant_default` fallback. So for any tenant that
has never been promoted to `.SCHEMA` mode (the documented default — see
`resolveAndCacheStorageMode`, pool.zig:183-234), these three tables are structurally
unreachable from an unqualified query, and `countRows`/`countRowsWhereRecent`/`maxColumn`
fail with `QueryFailed`, which `readUsageForDimension`'s catch-all (line 160-163) turns
into `QuotaMiddlewareError.QuotaUsageReadFailed`.

## 2. Where schema resolution happens — resolve once in `readUsageForDimension`, not per-helper

**Decision: `readUsageForDimension` resolves the schema name exactly once per call, then
passes a schema-qualified table identifier down to whichever helper it dispatches to.**
The four leaf helpers (`countRows`, `countRowsWhereRecent`, `sumColumn`, `maxColumn`) are
changed to accept an already-qualified table-name string instead of a bare table name, and
stop doing any schema reasoning themselves.

Rejected alternative: each helper independently resolves the schema before querying.
Rejected because:

- **Correctness is identical either way** — both approaches call the same underlying
  resolution logic and would produce the same qualified name for a given tenant/request.
  This is not a correctness distinction.
- **Round-trip cost differs.** `resolveAndCacheStorageMode` performs a real DB query
  (`SELECT storage_mode FROM public.tenant ...`, and possibly a second query against
  `public.tenant_schemas` on fallback) only on the **first** `pool.acquire()` of the
  request/thread — `tenant_context.hasStorageMode()` gates it, and the result is cached
  threadlocal via `tenant_context.setStorageMode()`. Because `Pool.acquire()` already calls
  `applyRequestStorageRouting` unconditionally on *every* acquire (including every
  `pool.acquire()` the four helpers already do today), the storage-mode DB round-trip is
  already paid for by the *first* acquire in the request, regardless of which function
  resolves it. So there is no marginal round-trip-count difference between "resolve once in
  `readUsageForDimension`" and "resolve independently in each helper" for the
  `resolveAndCacheStorageMode` cost specifically — both read the same cached threadlocal
  after the first acquire.
- **The real cost this decision controls is code duplication and drift risk, not I/O.**
  `check()` (line 74) calls `readUsageForDimension` one or two times per request depending
  on `input.target` (see the `switch` at lines 95-119: up to 2 dimensions per target). If
  each of the four helpers independently re-derived the schema name via
  `schemaNameForTenant`/`tenant_context.getStorageMode()`, that derivation logic would be
  copy-pasted four times inside the same file, with four chances to drift out of sync
  (e.g. one helper's copy handles a mode branch differently after a future edit). Resolving
  once in the single caller (`readUsageForDimension`) and threading the already-qualified
  name down is strictly less code, one source of truth, and matches the existing
  precedent set by `pool.zig`'s own `applyRequestStorageRouting`, which is itself the
  single resolution point for the whole request — this design mirrors that shape at the
  quota-enforcement layer instead of re-deriving it four times.
- **It also fixes the current call shape with the least edit surface.** `readUsageForDimension`
  already receives `tenant_id` and already has the `switch (dimension)` (lines 150-159)
  that selects which helper and which table name to use — schema resolution slots directly
  into that existing switch with one extra local variable, rather than requiring every
  helper's signature to grow a `tenant_id` parameter it doesn't otherwise need (note
  `countRowsWhereRecent` and `maxColumn` currently `_ = tenant_id;` — they don't use it for
  anything except the (removed) unqualified WHERE clause, so growing their signature to
  do schema resolution internally would be strictly more invasive than passing them an
  already-qualified name).

## 3. Exact mechanism for building the schema-qualified SQL strings

### 3.1 New helper: `resolveTenantSchema`

Add one small function to `quota_enforcement.zig` (private to this file) that performs the
schema resolution `readUsageForDimension` needs:

```
fn resolveTenantSchema(pool: *pool_mod.Pool, tenant_id: []const u8, buf: *[80]u8) QuotaMiddlewareError![]const u8
```

Behavior:
1. If `!tenant_context.hasStorageMode()`: acquire a connection from `pool`, call
   `pool_mod.resolveAndCacheStorageMode(conn, tenant_id)`, release the connection. This is
   the same call `applyRequestStorageRouting` itself makes (pool.zig:271) — reused, not
   reimplemented. Note this DB round-trip is *not* new cost: it duplicates work
   `applyRequestStorageRouting` was already about to do on the *next* `pool.acquire()`
   inside `countRows`/etc. anyway (every acquire re-checks `hasStorageMode()` and skips
   the query once cached) — so this call either is a no-op (mode already cached from an
   earlier acquire this request) or pre-pays a cost that would have been paid moments
   later regardless.
2. Read `tenant_context.getStorageMode()`.
3. If `.SCHEMA`: return `pool_mod.schemaNameForTenant(tenant_id, buf)` (pool.zig:137) —
   the exact same helper `applyRequestStorageRouting`'s `.SCHEMA` branch uses
   (pool.zig:287).
4. If `.LEGACY_RLS`: return the literal `"tenant_default"` written into `buf` (see §5 for
   why this is the correct name for this mode, not some other tenant-specific schema).

This function does **not** call `pool.acquire()` a second time when the mode is already
cached — step 1's acquire only happens on the cache-miss path, matching
`applyRequestStorageRouting`'s own gating exactly.

### 3.2 Building the qualified SQL text: `bufPrint` into a fixed buffer, not `allocPrint`

Each of the three literal SQL strings that reference `instance_projections`,
`instance_waits`, or `dead_letter_items` is changed from a bare table name to
`{schema}.{table}`, built with `std.fmt.bufPrint` into a stack buffer sized generously for
`"tenant_" + 32 hex chars + "." + longest table name` (`instance_projections` is the
longest at 20 chars) — a 128-byte buffer is ample headroom, matching the
`path_buf: [128]u8` sizing precedent already used in `applyRequestStorageRouting`
(pool.zig:288). `bufPrint` (not `allocPrint`) is used because:

- It requires no allocator and cannot fail with `OutOfMemory` under any realistic input
  (the buffer is sized well above the true maximum), matching `schemaNameForTenant`'s own
  allocation-free, hot-path-safe design (pool.zig:136 comment) and
  `applyRequestStorageRouting`'s `search_path` construction (pool.zig:288-293), which uses
  the identical pattern.
- The formatted table name only needs to live for the duration of one `conn.queryRow` call
  immediately after construction — no ownership transfer, no need for arena/allocator
  lifetime management.

Because the *column list*, *WHERE clause*, and *parameter placeholders* differ per
dimension (some queries filter by `tenant_id = $1`, others don't; some have a `WHERE
resolved_at IS NULL` or interval clause), the design does **not** attempt to build one
generic "SELECT COUNT(*) FROM {qualified} WHERE ..." formatter. Instead, each of the three
affected call sites keeps its existing SQL *shape* (same WHERE clause, same parameter
list) and only the leading `FROM <table>` / `INSERT`-equivalent target identifier gains the
`{schema}.` prefix via `bufPrint`. Concretely:

- `countRows`'s `instance_projections` branch: `"SELECT COUNT(*)::text FROM {s} WHERE
  tenant_id = $1::uuid"` with `.{qualified_instance_projections}` substituted for `{s}`.
- `countRows`'s `instance_waits` branch: `"SELECT COUNT(*)::text FROM {s} WHERE
  resolved_at IS NULL"` with `.{qualified_instance_waits}`.
- `countRowsWhereRecent`'s `dead_letter_items` branch: `"SELECT COUNT(*)::text FROM {s}
  WHERE COALESCE(last_retried_at, updated_at, created_at) >= NOW() - INTERVAL '1 day'"`
  with `.{qualified_dead_letter_items}`.
- `maxColumn`'s `dead_letter_items` branch: `"SELECT COALESCE(MAX(retry_count), 0)::text
  FROM {s}"` with `.{qualified_dead_letter_items}`.

`repository_artifacts` branches in `countRows` and `sumColumn` are **not** touched — they
keep their existing unqualified literal strings unchanged (§4).

Because the SQL text itself must now be built at call time (`bufPrint` into a local
buffer) rather than referenced as a `const` string literal, each of the three call sites
constructs its own small `sql_buf: [160]u8` (128 for the qualified `FROM` clause text plus
headroom for the surrounding `SELECT ...` wrapper) immediately before the `conn.queryRow`
call, mirroring the existing local-buffer pattern already used elsewhere in this file
(e.g. none currently, but matching `pool.zig`'s `path_buf`/`schema_buf` precedent at
pool.zig:286-293). No heap allocation is introduced.

### 3.3 SQL-injection safety of the interpolated schema name — confirmed safe, with reasoning

The schema name interpolated into the `FROM` clause comes from exactly one of two sources:

1. **The literal string `"tenant_default"`** (LEGACY_RLS branch) — a fixed compile-time
   constant, not derived from any request input. No injection surface.
2. **`schemaNameForTenant(tenant_id, buf)`** (SCHEMA branch) — read its implementation
   (pool.zig:137-155) directly: it copies the literal prefix `"tenant_"`, then iterates
   `tenant_id`'s bytes and copies every character **except `-`** into the output buffer,
   dropping hyphens. It performs no other transformation and applies no identifier
   quoting (no `%I`-style quoting, confirmed absent from this function).

   Its safety therefore rests entirely on the **caller's guarantee that `tenant_id` is
   already a canonical, validated 36-character UUID string** before this function is ever
   invoked — not on any structural escaping inside `schemaNameForTenant` itself. This
   guarantee holds for every call path relevant to this design:

   - `quota_enforcement.check()`'s `input.tenant_id` and `readUsageForDimension`'s
     `tenant_id` parameter both originate from `QuotaCheckInput.tenant_id`, which callers
     populate from the already-authenticated, already-resolved request tenant context
     (the same `tenant_id` value `pool.acquire()`'s own `applyRequestStorageRouting` uses
     for its identical `schemaNameForTenant` call at pool.zig:287) — not from raw,
     unvalidated user input on this request.
   - The UUID character set (`[0-9a-f-]`, lowercase hex digits and hyphens only) contains
     no SQL metacharacters (no quote, semicolon, backslash, whitespace, or comment
     delimiter) in any of its 36 characters — even in the hypothetical worst case where an
     upstream caller passed a malformed value, the only characters `schemaNameForTenant`
     can emit into the output are whatever `tenant_id` contained verbatim (minus hyphens);
     it does not sanitize, but a genuine UUID string cannot contain anything unsafe to
     interpolate into an unquoted identifier position in the first place.
   - This is stated explicitly per the task's requirement, rather than assumed: **this
     design does not add any new validation of `tenant_id`'s shape** — it relies on the
     same trust boundary `pool.zig` already relies on for the identical interpolation it
     performs today at pool.zig:289-293. If that trust boundary is ever found to be
     violable (e.g. a code path that reaches `schemaNameForTenant` with unvalidated
     input), that is a pre-existing defect in `pool.zig`'s own contract, not something
     this design introduces or is positioned to fix — this design reuses the exact same
     function via the exact same trust contract, with no new call path that bypasses
     tenant-context resolution.

No `std.fmt.allocPrint`/`bufPrint` call in this design ever formats attacker-controlled
free text into SQL; the interpolated segment is always either the constant
`"tenant_default"` or the hyphen-stripped form of an already-authenticated UUID.

## 3a. Public interface impact

No exported symbol of `quota_enforcement.zig` changes shape. `check()`, `classifyTarget()`,
`init()`, `deinit()`, `QuotaGuardTarget`, `QuotaCheckInput`, `QuotaMiddlewareResult`, and
`QuotaMiddlewareError` are all untouched — this is a purely internal fix. The only
signature changes are to this file's **private** (non-`pub`) helpers:

- `readUsageForDimension` (private): body changes to resolve the schema and pass a
  qualified table name down; its own signature (`allocator`, `pool`, `tenant_id`,
  `dimension`, `limit`) → `QuotaMiddlewareError!QuotaUsageSnapshot` is unchanged.
- `countRows`, `countRowsWhereRecent`, `maxColumn`, `sumColumn`, `tableStorageBytes`
  (all private): each still takes a `table_name: []const u8`-shaped parameter, but the
  caller (`readUsageForDimension`) now passes an already-schema-qualified string for the
  three affected tables instead of a bare name — no new parameter is added to these
  helpers' signatures.
- New private helper `resolveTenantSchema(pool: *pool_mod.Pool, tenant_id: []const u8, buf: *[80]u8) QuotaMiddlewareError![]const u8`
  (§3.1) — not exported.

## 4. `.LEGACY_RLS` mode → schema name is `tenant_default` — confirmed, not assumed

Confirmed by reading `resolveAndCacheStorageMode` (pool.zig:183-234) and
`applyRequestStorageRouting` (pool.zig:258-301) directly, not inferred:

- `resolveAndCacheStorageMode`'s three-step fallback (Step 1: `public.tenant.storage_mode`;
  Step 2: `public.tenant_schemas` row check; Step 3: default) resolves to `.LEGACY_RLS`
  whenever neither an explicit `storage_mode='SCHEMA'` row nor a `tenant_schemas`
  provisioning row exists for the tenant. There is no third storage mode and no
  tenant-specific schema name associated with `.LEGACY_RLS` anywhere in this resolution
  logic — the enum (`tenant_context.StorageMode`) has exactly two variants,
  `.LEGACY_RLS` and `.SCHEMA` (tenant_context.zig:18-21).
- `applyRequestStorageRouting`'s `.LEGACY_RLS` branch (pool.zig:277-283) sets
  `search_path TO public` only — it never references `tenant_default` or any other schema
  name. This confirms `.LEGACY_RLS` mode has no *routing-layer* concept of a per-tenant
  schema at all; from the routing layer's perspective, a `.LEGACY_RLS` tenant's data is
  expected to live in `public`, disambiguated by the RLS predicate
  (`set_config('bpm.tenant_id', ...)`) rather than by schema.
- However, `instance_projections`/`instance_waits`/`dead_letter_items` are **not** RLS-
  protected `public` tables — per ISS-0622's own root-cause analysis (confirmed live via
  `\dt public.instance_projections` etc. returning no relation) they were never created in
  `public` at all; `migrations/001_event_store.sql`'s `runForSchema()` machinery
  replays their DDL once per tenant schema, and the **default/bootstrap** tenant's copy of
  that per-schema replay target is named `tenant_default` — confirmed by
  `tests/integration/helpers.zig`'s `configureTestSearchPath` (helpers.zig:248-256), whose
  own comment states plainly: *"Integration tests always run against the 'default' tenant
  (UUID `00000000-0000-0000-0000-000000000000`) → schema `'tenant_default'`"* and sets
  `search_path TO tenant_default,public` explicitly for exactly this reason — unqualified
  references to tables like `process_definitions`/`instance_projections` must resolve to
  the tenant schema, not `public`, "where they no longer exist after migration GBL-073".
  This is the same fact pattern ISS-0622 encountered in production request handling: the
  routing layer's `.LEGACY_RLS` `search_path=public` is simply incomplete for these three
  tables, and `tenant_default` is the one and only schema they live in for the default/
  legacy tenant path — there is no other tenant-specific schema a `.LEGACY_RLS` tenant's
  data could be in, because `.LEGACY_RLS` by definition means "not promoted to
  schema-per-tenant," and `tenant_default` is the single shared schema every
  never-promoted tenant's per-tenant-shaped tables live in.
- `schemaNameForTenant` itself independently corroborates this: its own empty-string/
  all-zero-UUID branch (pool.zig:139-143) returns `"tenant_default"` — the same constant
  this design uses for the `.LEGACY_RLS` branch, for the same underlying tenant identity
  (the platform default/bootstrap tenant). This is not a coincidence this design invents;
  it is the existing codebase's own naming convention for "the one shared tenant schema,"
  reused consistently.
- No design doc (`src/design/db.md` was checked; it documents `pool.zig`'s public
  interface and invariants but does not separately re-derive schema-naming conventions
  beyond what's in `pool.zig` itself) contradicts this. The convention is derived directly
  from `pool.zig` + `helpers.zig`, both read in full for this design.

**Conclusion: for `.LEGACY_RLS` mode, `resolveTenantSchema` always returns the literal
`"tenant_default"`, unconditionally — there is no tenant-specific variant to resolve.**

## 5. `repository_artifacts` (`.file_count` / `.file_bytes`) — untouched, confirmed correct as-is

`readUsageForDimension`'s `.file_count` and `.file_bytes` branches (lines 153-154) call
`countRows(..., "repository_artifacts", ...)` and `sumColumn(..., "repository_artifacts",
"byte_size", ...)` respectively. `repository_artifacts` has a genuine, canonical copy in
`public` (confirmed by the sibling ISS-0617/GH-566 fix, already merged — see
`src/design/iss0617-test-fixture-schema-qualification.md` §2, which independently
confirmed `src/config/loader.zig::loadConfigArtifact` resolves `repository_artifacts`
unqualified under `search_path=public` unambiguously to the canonical `public` copy).
`countRows`'s `repository_artifacts` branch already issues `"SELECT COUNT(*)::text FROM
repository_artifacts WHERE tenant_id = $1::uuid"` unqualified, which is correct as-is
under `.LEGACY_RLS`'s `search_path=public` — no change.

This design's edits to `countRows` and `sumColumn` **must preserve the existing
`repository_artifacts` branch exactly as-is** (same literal string, same parameter list,
no schema prefix added) and only change the branches selecting `instance_projections`,
`instance_waits`, and `dead_letter_items`. The `if (std.mem.eql(u8, table_name,
"repository_artifacts")) ... else` branch structure already present in `countRows` (lines
181-186) and the early-return guard in `sumColumn` (lines 244-246) naturally keep these
two concerns separate; this design's edit adds schema qualification only inside the
non-`repository_artifacts` branches.

## 6. Confirmation against `TC-EXP-601-02` and `TC-EXP-601-04`

Read `tests/integration/exp601_tier_quota_test.zig` in full (375 lines) to confirm.

- **TC-EXP-601-02** (lines 172-229): provisions a tenant via `provisionTenantViaPool`
  (never sets `storage_mode`, so it resolves to `.LEGACY_RLS` per §4), inserts an
  `instance_projections` row directly via `harness.conn` (which runs under
  `configureTestSearchPath`'s `tenant_default,public` search path — lines 198-208, with an
  inline comment already anticipating this exact fix: *"ISS-0622 (filed, not fixed here):
  instance_projections is a genuine PER_TENANT table with no public copy... preserved here
  as the least-wrong option pending ISS-0622's fix"*), then calls
  `quota_middleware.check(..., .entity_write, ...)` (line 213). `check()` dispatches to
  `readUsageForDimension(..., .entity_records, ...)` (line 97), which today calls
  `countRows(..., "instance_projections", ...)` unqualified — under this tenant's
  `.LEGACY_RLS` mode that resolves against `search_path=public`, finds nothing (or errors,
  per ISS-0622's confirmed symptom), and `check()` fails before ever reaching its `429`
  assertions. **After this fix:** `readUsageForDimension` resolves the schema
  (`.LEGACY_RLS` → `tenant_default`, §4), `countRows` queries
  `tenant_default.instance_projections` instead, finds the row the test fixture inserted
  via `harness.conn` (which is *also* on `tenant_default,public`'s search path — the same
  schema), returns `used=1`, and `check()` proceeds to `quota_policy.evaluateQuota` with
  the zero-quota profile (`zeroQuotaPolicyJson()`, already fixed to resolve correctly by
  ISS-0617), correctly rejecting with `429`/`quota-exceeded`/`entity_records` — satisfying
  the test's assertions at lines 224-226.
- **TC-EXP-601-04** (lines 298-364): same `.LEGACY_RLS` tenant setup; inserts fixture rows
  into `instance_waits` and `dead_letter_items` via `harness.conn` (lines 329-330, same
  `tenant_default,public` search path, with the same ISS-0622-anticipating comment at
  lines 326-328), then calls `check(..., .sandbox_allocate, ...)` (line 335) and
  `check(..., .agent_retry, ...)` (line 350). `.sandbox_allocate` dispatches to
  `readUsageForDimension(..., .concurrent_sandboxes, ...)` → `countRows(...,
  "instance_waits", ...)`; `.agent_retry` dispatches to two dimensions →
  `maxColumn(..., "dead_letter_items", "retry_count", ...)` and
  `countRowsWhereRecent(..., "dead_letter_items", ...)`. All three currently fail
  unqualified under `.LEGACY_RLS`'s `search_path=public` the same way TC-EXP-601-02 does.
  **After this fix:** all three resolve against `tenant_default.<table>`, matching where
  the fixture rows actually landed, and the `429`/`concurrent_sandboxes` (line 346) and
  `429`/`agent_retry` (line 361) assertions are satisfied.

  **Explicitly out of scope, per the task instructions:** TC-EXP-601-04's fixture *insert*
  of `instance_waits` at line 329 has a separately tracked defect (a distinct
  `PgError.ServerError` on the INSERT itself, noted in
  `src/design/iss0617-test-fixture-schema-qualification.md` §6 as "not addressed by this
  fix... a distinct, already-flagged, separately-tracked condition"). This design fixes
  only the **read** side in `quota_enforcement.zig`; it does not touch that INSERT, and if
  that INSERT is still broken at TEST-RUNNER time, TC-EXP-601-04 may still fail — at the
  INSERT, before ever reaching the quota-guard assertions this design targets. That
  failure mode, if still present, is not evidence against this design's correctness.

- **TC-EXP-601-01, -03, -05** are unaffected: -01 and -03 never touch
  `instance_projections`/`instance_waits`/`dead_letter_items` (only
  `repository_artifacts`/`tenant_artifact_activations`/`tenant`, all already correctly
  qualified or already resolving correctly per §5 and ISS-0617); -05 is a pure
  `classifyTarget` unit test with no DB access.

## 6a. Error taxonomy — no new error variants

`resolveTenantSchema` (§3.1) introduces one new internal failure path: the
`pool.acquire()`/`resolveAndCacheStorageMode` call it makes on a cache-miss can fail the
same way every existing `pool.acquire()` call in this file already can. This design does
**not** add any new variant to `QuotaMiddlewareError` (`NotInitialized`, `OutOfMemory`,
`PoolExhausted`, `QuotaPolicyNotConfigured`, `QuotaPolicyInvalid`, `QuotaUsageReadFailed`,
`QuotaDimensionUnsupported` — quota_enforcement.zig:38-46). `resolveTenantSchema` surfaces
its failure exactly the way `countRows`/`maxColumn`/`countRowsWhereRecent` already do:
propagated up through `readUsageForDimension`'s existing `catch |err| switch (err) {
error.OutOfMemory => return error.OutOfMemory, else => return error.QuotaUsageReadFailed
}` (lines 160-163) — a pool/query failure during schema resolution becomes
`QuotaUsageReadFailed`, identical in kind (though earlier in the call chain) to today's
failure when the *query itself* fails. Callers of `check()` observe no new error shape:
a `.LEGACY_RLS` tenant whose schema cannot be resolved surfaces the same
`QuotaUsageReadFailed` → HTTP 503 mapping (`src/main.zig` lines 543-553) it would have hit
anyway once the (now schema-qualified) query ran. `resolveAndCacheStorageMode` itself
never returns an error to its caller in the first place — per pool.zig:183-234, every
failure branch inside it degrades to `.LEGACY_RLS` and returns `void` — so the only
failure `resolveTenantSchema` can actually observe is `pool.acquire()`'s own
`PoolError` (mapped to `QueryFailed`-shaped handling, consistent with how this file's
other helpers already treat `pool.acquire()` failures, e.g. `countRows` line 188:
`pool.acquire() catch return error.QueryFailed`).

## 7. Files touched

- `src/api/middleware/quota_enforcement.zig` only:
  - Add `resolveTenantSchema` helper (new private function).
  - `readUsageForDimension`: for the `.entity_records`, `.concurrent_sandboxes`,
    `.agent_retry_per_job`, `.agent_retry_per_day` dimensions, resolve the schema once via
    `resolveTenantSchema` and pass the schema-qualified table name to the helper instead of
    the bare table name. The `.file_count`/`.file_bytes` (`repository_artifacts`) and
    `.entity_storage` (`tableStorageBytes`, uses `pg_total_relation_size($1::regclass)` —
    see note below) branches are unchanged.
  - `countRows`, `countRowsWhereRecent`, `maxColumn`: change their `table_name` parameter
    contract so the `instance_projections`/`instance_waits`/`dead_letter_items` branches
    build their SQL via `bufPrint`-qualified identifiers (§3.2) instead of bare literals;
    the `repository_artifacts` branch inside `countRows` is unchanged (§5).
  - Add `const pool_mod_pkg = @import("pool")`-level access to
    `pool_mod.resolveAndCacheStorageMode` and `pool_mod.schemaNameForTenant` (both already
    exported per pool.zig:137, 183) and `@import("../tenant_context.zig")` (or whatever the
    existing import path for `tenant_context` resolves to in this file — `quota_enforcement.zig`
    does not currently import it; add the import) for `hasStorageMode()`/`getStorageMode()`.

**Note on `.entity_storage` (`tableStorageBytes`):** this dimension calls
`pg_total_relation_size($1::regclass)` (line 312) — a parameterized regclass cast, not a
bare `FROM <table>` reference. `to_regclass`/`::regclass` resolution follows the
connection's `search_path` the same way unqualified `FROM` clauses do, so this call is
*also* affected by the same `.LEGACY_RLS` `search_path=public` gap when passed the bare
string `"instance_projections"` (line 152). This design's scope, per the task instructions
and ISS-0622's acceptance criteria, covers `readUsageForDimension`/`countRows`/
`maxColumn`/`countRowsWhereRecent` explicitly; `tableStorageBytes` is a fifth helper not
named in the task's enumerated list. **Recommendation:** apply the identical fix to this
call site in the same implementation pass, since it is the same bug against the same table
via the same file's same caller (`readUsageForDimension`'s `.entity_storage` branch, line
152) — the schema-qualified name callers already compute in §2 can be passed to
`tableStorageBytes` too, with `$1` becoming `"{schema}.instance_projections"` instead of
`"instance_projections"`. BACKEND-DEV should fix this alongside the four named helpers;
flagging it here rather than silently leaving a fifth, structurally-identical instance of
the exact defect ISS-0622 describes.

## 8. Out of scope

- **`src/admin/tenant_lifecycle.zig::resetTestTenant()` (lines ~100-128).** Read directly
  for this design: its Step 2 (lines 100-128) calls `pool.acquire()` and issues `SELECT
  COUNT(*)::text FROM instance_projections WHERE status NOT IN (...)` unqualified, the
  identical bug class to ISS-0622 — a `.LEGACY_RLS`-mode call to this function would fail
  or silently under-count against `search_path=public` for the same structural reason.
  This is not fixed here; ISS-0622's scope is `quota_enforcement.zig` only, per the task
  instructions. It should be filed as its own follow-up issue (sibling finding, same
  pattern, different call site) rather than folded into this fix.
- **`src/scheduler/scheduler.zig::appendEventInTx`.** Reviewed for due diligence: this
  function receives a `*db.Conn` **parameter** from its caller rather than calling
  `pool.acquire()` itself, and issues an unqualified `UPDATE instance_projections ...`
  (scheduler.zig:937-945). This is structurally different from `quota_enforcement.zig`'s
  self-acquire-per-call pattern — its `search_path` is whatever the *caller* set up on the
  connection it passed in, not something this function controls or that
  `applyRequestStorageRouting` necessarily governs directly at this call site. Whether
  that caller's connection has the correct `tenant_default`-inclusive search path is a
  separate question this design does not attempt to resolve; it is very likely **not**
  the same bug class as ISS-0622 (which is specifically about `pool.acquire()`-per-call
  helpers inheriting `.LEGACY_RLS`'s incomplete `search_path=public`), but is noted here so
  a future reader does not have to re-derive this distinction from scratch.
- **Broader audit of other middleware/modules with the same unqualified-read-via-pool
  pattern against PER_TENANT-only tables**, beyond the two call sites named above
  (`tenant_lifecycle.zig` and the due-diligence note on `scheduler.zig`) — ISS-0622's own
  acceptance criteria asks whether "any other middleware shares this same... pattern"; a
  full repository-wide audit was not performed as part of this design (it was scoped to
  `quota_enforcement.zig` per the task instructions) and would be a reasonable separate
  follow-up if the maintainer wants full coverage confidence.
- **The `instance_waits` fixture-INSERT failure in TC-EXP-601-04** — a distinct, already
  separately-tracked issue per §6, not touched here.
- **The dual-schema-shadow anti-pattern rejected alternative** (creating `public`-schema
  views/copies of `instance_projections`/`instance_waits`/`dead_letter_items`) — considered
  and explicitly rejected per the task's approved strategy; not revisited by this design.
  Doing so would reintroduce the exact dual-schema-existence hazard `GBL-134`/`135`/`136`
  exist to dismantle (`docs/anti-patterns.md`, ISS-0185/GH-518 entry).

## 9. Verification

- `zig build` exits 0 (implementation only touches `quota_enforcement.zig`'s function
  bodies/signatures for internal helpers — no public API surface of this module changes;
  `check()`'s and `classifyTarget()`'s signatures are untouched).
- `zig build test` / the `exp601` integration target: `TC-EXP-601-01` through `-03` and
  `-05` continue to pass; `TC-EXP-601-02` and `TC-EXP-601-04` pass their quota-guard
  (`429`) assertions per §6 (TC-EXP-601-04's separate fixture-insert issue, if still
  unresolved at TEST-RUNNER time, is out of scope per §6/§8 and not evidence against this
  fix).
- Manual/live confirmation option: after the fix, a `.LEGACY_RLS`-mode tenant's
  `quota_middleware.check()` call for `.entity_write`/`.sandbox_allocate`/`.agent_retry`
  targets no longer returns `QuotaUsageReadFailed`; the equivalent query run directly
  against `tenant_default.instance_projections` (etc.) returns the same row count the
  fixed `countRows` call computes.
- `git diff --stat` confirms only `src/api/middleware/quota_enforcement.zig` is modified by
  this fix (excluding handoff/report files this run's other steps touch).
