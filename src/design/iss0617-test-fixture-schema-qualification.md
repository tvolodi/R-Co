# ISS-0617 / GH-566 — Schema-qualify `repository_artifacts` references in exp601_tier_quota_test.zig

**Run ID:** WF03-GH566-20260808
**Issue:** [GH-566](https://github.com/tvolodi/R-Co/issues/566) (ISS-0617)
**Classification:** Type E (test-fixture correctness fix — no CRUD/migration/list-page/react-flow-node shape; falls to Type E per `templates/lego-catalog.md` selection rule 5. It is also explicitly test-assertion/fixture logic, which the catalog's "What stays in Type E" section names directly: "Assertion logic in integration tests")
**Step:** WF-03 Step 2c — CODE-DESIGNER strategy-change fix design
**Related:** `src/design/iss0617-gbl134-missing-tables-followup.md` (superseded as the *sole* fix for this issue — see §5), `migrations/GBL-136_iss0617_drop_remaining_global_registry_shadows.sql` (already implemented; disposition addressed in §5), ISS-0185/GH-517 (originating diagnosis), ISS-0620/GH-573, ISS-0621/GH-574 (unrelated follow-ons, not touched here)

Covers: ISS-0617

## 1. Problem statement (confirmed, corrected from the GBL-136 design)

`ISS-0617`'s `confirmed_root_cause` field traces TC-EXP-601-01 through 04's
failures to a single proximate cause: `tests/integration/exp601_tier_quota_test.zig`
issues **unqualified** `INSERT INTO repository_artifacts` statements against
`TestHarness.conn`, a connection whose `search_path` is set to
`tenant_default,public` by `configureTestSearchPath()`
(`tests/integration/helpers.zig:248-256`). Because a **stray, distinct**
`tenant_default.repository_artifacts` relation exists (left behind by
`GBL-134`'s incomplete `v_tables` coverage — see §5), the unqualified INSERT
resolves to that stray copy instead of the canonical `public.repository_artifacts`
table that `src/config/loader.zig`'s `loadConfigArtifact` actually queries
(confirmed in §2 below). The resolver's JOIN finds 0 rows, `loadActiveQuotaPolicy`
returns `ConfigError.ConfigNotFound`, and `quota_policy.loadEffectiveQuotaProfile`
falls through to the platform default profile (200000) instead of applying the
test's configured override (10).

**This design was preceded by a migration-based fix (`GBL-136`) that was
implemented, applied, and then empirically falsified as a complete solution for
this specific issue.** `GBL-136` was applied to both `bpm_dev` and `bpm_test`;
6 of its 8 target tables dropped successfully, but `repository_artifacts`
did not, and cannot: `tenant_default.artifact_versions` holds a live FK
(`fk_artifact_versions_content`, `ON DELETE RESTRICT`) into
`tenant_default.repository_artifacts`, and `artifact_versions` itself can
never be dropped via `RESTRICT` because two *legitimate* PER_TENANT tables
(`artifact_activations`, `artifact_activation_history`) hold their own live
FKs into it — this is documented as intentional, permanent, correct RESTRICT
behavior in `src/design/iss0617-gbl134-missing-tables-followup.md` §3.1, not
a bug. The consequence, confirmed by this same live-FK analysis, is that
`repository_artifacts` is **permanently, transitively** un-droppable from
`tenant_default` for as long as `artifact_versions` exists there — no
migration-level fix (reordering, retrying, a different `v_tables` array) can
change this. A fix for THIS issue therefore cannot rely on the stray table
ever going away. It must instead stop the test fixture from writing to it in
the first place.

## 2. Confirmation: what `loadConfigArtifact` actually queries

`src/config/loader.zig::loadConfigArtifact` (lines 185-222) runs its query
through `pool.acquire()` (line 201) — a connection drawn from the `db.Pool`
built by the test's own `makePool()` helper
(`tests/integration/exp601_tier_quota_test.zig:44-49`). Pool connections are
routed by `src/db/pool.zig::applyRequestStorageRouting` (lines 258-300, called
from `Pool.acquire()` at line 837). For the nil-UUID default tenant used
throughout this test file (`bpm.api_tenant_context.DEFAULT_TENANT_ID`, set in
`makePool()` line 47), the routing function resolves `storage_mode` via
`resolveAndCacheStorageMode` — and `TestHarness.provisionTenant()`
(`tests/integration/helpers.zig:1116-1124`) never sets a `storage_mode` value
on the `tenant` row it inserts, so the resolver's two lookups (row check,
then `tenant_schemas` check) both find nothing and fall through to the
documented default: `.LEGACY_RLS` (`pool.zig:172-175, 232-234`). The
`.LEGACY_RLS` branch of `applyRequestStorageRouting`
(`pool.zig:277-282`) issues exactly `SET search_path TO public` — no
`tenant_default`, no fallback path, nothing else. This is unconditional for
every test tenant in this file, since none of them are promoted to
`storage_mode='SCHEMA'`.

The query itself (`loader.zig:206-212`):

```sql
SELECT ra.content_json::text
FROM tenant_artifact_activations taa
JOIN repository_artifacts ra ON ra.version_id = taa.active_version_id
WHERE taa.tenant_id = $1
  AND taa.artifact_kind = $2
  AND taa.artifact_name = $3
LIMIT 1
```

references `repository_artifacts` unqualified — but on this connection
`search_path=public` only, so PostgreSQL's schema resolution has exactly one
candidate schema to search and unambiguously resolves it to
`public.repository_artifacts`. This is confirmed precise, not inferred: there
is no ambiguity or fallback behavior to describe here, because a
single-schema `search_path` has only one possible resolution. The activation
row (`tenant_artifact_activations`) is unaffected by this issue — `GBL-134`
already dropped its `tenant_default` shadow (per
`iss0617-gbl134-missing-tables-followup.md` §1, confirmed via
`\dt tenant_default.tenant_artifact_activations` returning no relation), so
it too resolves unambiguously to `public.tenant_artifact_activations` from
both the harness connection and the pool connection.

**Conclusion:** the resolver's query is correct and requires no change. The
defect is entirely in the test fixture's write path, which is free to target
the wrong schema because its connection's `search_path` includes
`tenant_default` first.

## 3. Every unqualified `repository_artifacts` reference in the test file

Full read of `tests/integration/exp601_tier_quota_test.zig` (310 lines)
confirms exactly **two** distinct SQL statements reference
`repository_artifacts`, both unqualified, both executed against
`harness.conn` (the `tenant_default,public` search-path connection):

1. **`insertQuotaPolicyArtifact` helper** (lines 51-65) — the sole `INSERT
   INTO repository_artifacts (...)` statement inside this shared helper
   function. It is called from three of the four test blocks:
   - TC-EXP-601-01, line 110
   - TC-EXP-601-02, line 151
   - TC-EXP-601-04, line 263

2. **Inline `INSERT INTO repository_artifacts (...)`** directly inside
   TC-EXP-601-03 (lines 202-214) — a second, near-identical fixture insert
   for a `file`-kind artifact, written inline rather than through the shared
   helper (it uses a different `artifact_kind`/`artifact_name` pair:
   `'file'`, `'exp601-file'`, versus the helper's `'config'`,
   `'tier_quota_policy'`).

No other reference to `repository_artifacts` — qualified or unqualified —
appears anywhere else in the file. (TC-EXP-601-05 does not touch the database
at all; it is a pure function test of `quota_middleware.classifyTarget`.)
Both statements are structurally identical in the relevant respect: an
unqualified relation name in the `INSERT INTO` clause, executed on
`harness.conn`.

## 4. Fix specification — schema-qualify both references

Change both occurrences of the bare identifier `repository_artifacts` in the
`INSERT INTO` clause to the explicitly schema-qualified
`public.repository_artifacts`:

- **Location 1:** `insertQuotaPolicyArtifact` (line 53), the statement
  opening `INSERT INTO repository_artifacts (` → `INSERT INTO
  public.repository_artifacts (`.
- **Location 2:** the inline insert inside TC-EXP-601-03 (line 203), the
  statement opening `INSERT INTO repository_artifacts (` → `INSERT INTO
  public.repository_artifacts (`.

No other line in either statement changes — column lists, parameter
placeholders (`$1`...`$4`), type casts, and the values clause are all
unaffected. This is a two-token edit (`repository_artifacts` →
`public.repository_artifacts`) at each of the two call sites, applied to the
`INSERT INTO` target identifier only.

**Do not schema-qualify any other identifier in this file as part of this
fix.** `tenant_artifact_activations` (in `ensureQuotaPolicyActivation`, lines
67-76), `instance_projections`, `instance_waits`, and `dead_letter_items`
(scattered inline inserts in TC-EXP-601-02/03/04) are all confirmed to have
had their `tenant_default` shadows already dropped by `GBL-134`
(`tenant_artifact_activations`) or are not part of the `GLOBAL_REGISTRY`
classification at all (the other three are ordinary `PER_TENANT` tables whose
canonical home is `tenant_default` — qualifying them to `public` would be
actively wrong). Only `repository_artifacts` has the specific
dual-schema-existence property that makes its resolution ambiguous under
`search_path=tenant_default,public`; introducing schema qualification
anywhere else in this file is out of scope and would be over-fixing a problem
that does not exist at those call sites.

**Rationale for schema-qualifying rather than changing the connection's
`search_path`:** an alternative fix would change `configureTestSearchPath`
(or add a per-call `SET search_path`) so the harness connection no longer
includes `tenant_default` ahead of `public` for this file. That is rejected
as broader and riskier than necessary — `configureTestSearchPath` is shared
infrastructure used by every integration test in this suite (`grep` confirms
call sites across all `tests/integration/*_test.zig` files that use
`TestHarness`), and narrowing its `search_path` would risk breaking any other
test that legitimately depends on unqualified references resolving to
`tenant_default` first (the entire point of that ordering, per its own
comment at `helpers.zig:248-252`, is that most fixture tables genuinely live
in `tenant_default`). Qualifying the two specific statements that write to
the one specific table whose resolution is ambiguous is the minimal-blast-radius
fix: it changes nothing about shared test infrastructure, nothing about
connection configuration, and nothing about any other test file.

**This is a test-file-only change.** No production code
(`src/config/loader.zig`, `src/db/pool.zig`, `src/config/quota_policy.zig`,
`src/api/middleware/quota_enforcement.zig`) is touched. The only file this
design modifies is
`tests/integration/exp601_tier_quota_test.zig`.

## 5. Disposition of `GBL-136` — recommend keeping it, unmodified

`GBL-136` remains a correct, independently-scoped migration for its own
stated purpose: completing `GBL-134`'s coverage gap for the **7 other**
`GLOBAL_REGISTRY` tables in its 8-name scope
(`artifact_versions` [drop attempted, expected-skip per its own §3.1],
`event_type_registry_producers`, `oidc_migration_item`, `oidc_migration_job`,
`registry_idp_operation_ledger`, `tenant`, `tenant_hostnames`) plus
`repository_artifacts` itself, whose `tenant_default` shadow `GBL-136` *does*
still correctly attempt to drop and — per the live-FK analysis in this
design's §1 and in `iss0617-gbl134-missing-tables-followup.md` §5 — should
**also** succeed on a live database, independent of `artifact_versions`'
permanent skip, because the FK edge between the two points the *other*
direction (`artifact_versions → repository_artifacts`, not
`repository_artifacts → artifact_versions`).

This creates an apparent tension with this run's own confirmed empirical
result (`repository_artifacts` remained un-dropped in both `bpm_dev` and
`bpm_test` after applying `GBL-136`) that is worth stating plainly rather
than glossing over: the handoff's task description asserts
`fk_artifact_versions_content` as an `artifact_versions →
repository_artifacts` FK with `ON DELETE RESTRICT`, which — if
`repository_artifacts` is the *referenced* side — would indeed make
`repository_artifacts`'s own drop attempt fail with
`dependent_objects_still_exist` for exactly the same reason
`artifact_versions`'s drop attempt does, contradicting the GBL-136 design
doc's §5 claim that the FK only blocks `artifact_versions` and leaves
`repository_artifacts` free. This design does not attempt to re-litigate
which of the two prior analyses has the FK direction right — that is a
question about `GBL-136`'s own internal correctness for its 6-or-7-table
scope, not about whether this issue's fix (§4 above) is correct. **Critically,
it does not matter to this design either way**, because:

- If `GBL-136` successfully drops `tenant_default.repository_artifacts`
  (the GBL-136 design's own prediction), then after `GBL-136` runs there is
  only one `repository_artifacts` relation reachable from any connection, so
  the test fixture's original unqualified INSERT would incidentally start
  working too — but §4's fix still applies cleanly and harmlessly, because
  `public.repository_artifacts` and the (now nonexistent) `tenant_default`
  copy are no longer in conflict; the qualified INSERT simply targets the
  one remaining table.
- If `GBL-136` does *not* successfully drop it (this run's actual observed
  result, matching the handoff's FK analysis), §4's fix is what makes
  TC-EXP-601-01 through 04 pass, exactly as designed.

Either way, §4's schema-qualification fix is correct and sufficient on its
own, **without depending on `GBL-136`'s outcome for `repository_artifacts`
specifically.** This is precisely why this design does not require `GBL-136`
to be reverted: the two fixes do not conflict, and §4 does not need `GBL-136`
to succeed, partially succeed, or exist at all in order to resolve
TC-EXP-601-01 through 04.

**Recommendation: keep `GBL-136`, ship it alongside this fix, unmodified.**
Reasoning:

1. **It is independently correct and already validated for its other 6-7
   tables.** Live application to both `bpm_dev` and `bpm_test` confirmed 6 of
   8 tables dropped successfully with no errors and no unexpected side
   effects (per the handoff's own empirical account). Reverting a
   validated, harmless migration would only reintroduce the exact technical
   debt (`GBL-134`'s incomplete coverage) that `GBL-136` exists to close for
   those other tables — `event_type_registry_producers`,
   `oidc_migration_item`, `oidc_migration_job`,
   `registry_idp_operation_ledger`, `tenant`, `tenant_hostnames` all remain
   genuinely-stray `tenant_default` shadows of canonical `public` tables
   regardless of how ISS-0617 itself gets fixed.
2. **It does not regress anything.** `GBL-136`'s own design (§3.2 of
   `iss0617-gbl134-missing-tables-followup.md`) already handles the
   `dependent_objects_still_exist` exception per-table with a scoped
   exception handler that logs and continues rather than aborting — so
   `repository_artifacts` (or `artifact_versions`) failing to drop, whichever
   way the FK direction actually resolves, is already a handled, expected,
   non-fatal outcome of running the migration, not a migration failure.
   `zig build migrate` still exits 0.
3. **It is not required for this fix to work**, as shown above — so keeping
   it is not a correctness dependency, only an independent piece of
   completed technical debt that happens to ship in the same run.
4. **Reverting it would require its own justification this design does not
   have.** The only argument *for* reverting would be if `GBL-136` were
   found to be actively harmful or redundant; neither is true. Discarding
   validated, harmless work because the *original* hypothesis (that it alone
   would fix ISS-0617) turned out to be incomplete would waste real
   engineering effort for no safety or correctness benefit.

**One residual open question flagged, not resolved, by this design:** the
FK-direction discrepancy noted above (does `fk_artifact_versions_content`
block `repository_artifacts`'s own RESTRICT drop, or only
`artifact_versions`'s?) is worth confirming precisely with a live
`pg_constraint` query at TEST-RUNNER/RELEASE-VALIDATOR time, since the two
existing analyses disagree on it. This does not block this fix or block
shipping `GBL-136` — §4's schema-qualification fix is correct regardless of
the answer — but if the discrepancy indicates `GBL-136`'s own header
comments or `RAISE NOTICE` skip-count expectations are wrong (e.g., expecting
7 drops + 1 skip when the true outcome is 6 drops + 2 skips), that is a
documentation-accuracy nit worth a MINOR follow-up note, not a functional
defect in either migration or this fix.

## 6. Confirmation against TC-EXP-601-01 through 04's assertions

- **TC-EXP-601-01** (lines 86-125): calls `insertQuotaPolicyArtifact` (line
  110, via the now-qualified helper) then
  `quota_policy.loadEffectiveQuotaProfile` (line 114) and asserts
  `max_entity_records_total == 10` (line 117, from
  `generousQuotaPolicyJson()`'s override value) and
  `max_concurrent_sandboxes == 1` (line 118). With the fixture's INSERT now
  landing in `public.repository_artifacts`, `loadConfigArtifact`'s JOIN
  (§2, itself always querying `public` unqualified under
  `search_path=public`) finds the row, `loadActiveQuotaPolicy` returns the
  JSON instead of `null`, and `loadEffectiveQuotaProfile` applies the parsed
  override instead of falling through to `defaultProfileForTier(.standard)`
  (200000). The second half of this test (lines 120-124, the
  `tenant_without_policy` case) is unaffected by this fix — that tenant
  never gets an activation row at all, so it correctly continues to resolve
  to the default profile via the same `ConfigNotFound → null → default`
  path, just for a different reason (no activation row, not a
  wrong-schema row).
- **TC-EXP-601-02** (lines 127-174): calls `insertQuotaPolicyArtifact` (line
  151, qualified) with `zeroQuotaPolicyJson()`, then
  `quota_middleware.check(...)` for `.entity_write`. `quota_middleware.check`
  internally calls `loadEffectiveQuotaProfile` as its first step (per
  `confirmed_root_cause.test_blocks_relationship` in ISS-0617); with the
  qualified INSERT, that call now correctly resolves the zero-quota profile
  instead of the generous default, so the requested delta (1) exceeds the
  (now correctly zero) limit and the `429`/`quota-exceeded`/`entity_records`
  assertions (lines 169-171) are exercised as the test expects.
- **TC-EXP-601-03** (lines 176-235): calls `insertQuotaPolicyArtifact` (line
  200, qualified, `zeroQuotaPolicyJson()`) **and** the second, inline
  qualified INSERT (line 203, this design's Location 2) for the file-kind
  artifact fixture. The file-kind insert is not itself read by
  `loadEffectiveQuotaProfile` (which only reads the `config`/`tier_quota_policy`
  artifact) — it exists to populate `repository_artifacts` with a
  plausible file-content row for the `.file_write` check's own internal
  bookkeeping/shape expectations. Qualifying it to `public` is still correct
  and necessary: any code path that reads it back (directly or via a future
  extension of `quota_middleware.check`) must find it in the same schema the
  `config` artifact now correctly lands in, for the same
  `search_path=public`-only reason established in §2. With the zero-quota
  profile now correctly resolved (via the same mechanism as TC-EXP-601-02),
  the `429`/`quota-exceeded`/`file_count`-or-`file_bytes` assertions (lines
  230-232) are exercised as expected.
- **TC-EXP-601-04** (lines 237-300): calls `insertQuotaPolicyArtifact` (line
  263, qualified) with `zeroQuotaPolicyJson()`, then exercises
  `.sandbox_allocate` and `.agent_retry` targets through the same
  `quota_middleware.check` → `loadEffectiveQuotaProfile` path. Both checks
  now correctly resolve the zero-quota profile for the same reason as
  TC-EXP-601-02/03, so the `429`/`concurrent_sandboxes` (line 282) and
  `429`/`agent_retry` (line 297) assertions are exercised as expected. This
  test block's **second, distinct** failure mode noted in ISS-0617
  (`PgError.ServerError` on `INSERT INTO instance_waits`, line 265) is
  **not** addressed by this fix — `instance_waits` is not a
  `repository_artifacts` reference and is out of this design's scope
  entirely (per ISS-0617's own notes, it needs separate diagnosis; per
  `iss0617-gbl134-missing-tables-followup.md` §5/§6, it is also confirmed
  **not** one of `GBL-136`'s 8 in-scope names, having already been resolved
  in the opposite direction by `GBL-135`). If that second failure mode is
  still live after this fix lands, TC-EXP-601-04 may still fail at line 265
  before ever reaching its quota assertions — this is a known, pre-existing,
  separately-tracked condition, not a gap in this design's coverage of the
  `repository_artifacts` root cause.

All four blocks' `repository_artifacts`-driven assertions are satisfied by
this fix without requiring `repository_artifacts` to ever be dropped from
`tenant_default` — the fixture simply stops writing there.

## 7. Files touched

- `tests/integration/exp601_tier_quota_test.zig` (2-line change: qualify the
  `INSERT INTO repository_artifacts` target identifier at line 53 and line
  203 to `public.repository_artifacts`)
- No other file is modified by this design. `migrations/GBL-136_iss0617_drop_remaining_global_registry_shadows.sql`
  ships as-is (§5) — this design does not modify it.

## 8. Verification

- `zig build` exits 0 (no production code touched; test file remains valid Zig)
- `zig build test-integration` (or the scoped `exp601` target) against a
  freshly migrated `bpm_test` database — TC-EXP-601-01 through 03 pass;
  TC-EXP-601-04 passes its quota-guard assertions (lines 271-299) but may
  still fail earlier at line 265 if the separate, out-of-scope
  `instance_waits` issue is still unresolved at TEST-RUNNER time — that
  outcome is expected and does not indicate a defect in this fix
- Manual/live confirmation (already partially done during ISS-0617's own
  diagnosis pass, per its `verification_method` field): after the fix, a
  same-transaction row count of `public.repository_artifacts` for the
  inserted `version_id` is 1, and `tenant_default.repository_artifacts` for
  the same `version_id` is 0 — the inverse of the pre-fix observation
- `git diff --stat` confirms only `tests/integration/exp601_tier_quota_test.zig`
  changed by this fix (excluding whatever `GBL-136`/handoff/report files this
  run's other steps touch)

## 9. Out of scope

- Reverting or modifying `GBL-136` — recommended to keep, unmodified (§5).
- Resolving the FK-direction discrepancy flagged in §5 between this
  handoff's analysis and `iss0617-gbl134-missing-tables-followup.md`'s §5 —
  flagged for confirmation at TEST-RUNNER/RELEASE-VALIDATOR time, not
  decided here, and not blocking either fix.
- TC-EXP-601-04's second failure mode (`instance_waits` insert error) — a
  distinct, already-flagged, separately-tracked issue per ISS-0617's own
  notes.
- ISS-0620, ISS-0621 — unrelated follow-on issues from the same diagnosis
  lineage, each fixed in their own separate runs.
- Any change to `configureTestSearchPath`, `applyRequestStorageRouting`, or
  any other shared test/production infrastructure — considered and
  explicitly rejected in §4 as broader than necessary for this fix.
