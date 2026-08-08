# ISS-0617 / GH-566 — Follow-up migration for GBL-134's 8 missing GLOBAL_REGISTRY tables

**Run ID:** WF03-GH566-20260808
**Issue:** GH-566 / ISS-0617 (confirmed_root_cause traces to the upstream defect below)
**Severity:** MAJOR
**Author:** CODE-DESIGNER
**Status:** DESIGN (rework 1 — corrected GBL-136 scope from 13 to 8 tables; see §5)

## 1. Purpose / Problem

`GBL-134_iss0185_drop_global_registry_shadows.sql` was intended to drop the
`tenant_default` (and per-tenant-schema) shadow copies of all 37 tables that
`docs/issue-reports/ISS-0185-diagnosis.yaml`'s `classification_table` marks
`GLOBAL_REGISTRY` (canonical home: `public`). Its header comment and the
sibling design doc (`src/design/iss0185_dual_schema_cleanup.md`) both claim
full 37-table coverage, but the migration's `v_tables` array
(`migrations/GBL-134_iss0185_drop_global_registry_shadows.sql:45-70`) lists
only 24 names. The diagnosis file's `global_registry_tenant_default_is_stray`
list names 37; 13 of those are absent from GBL-134's array:

```
api_token_audit
artifact_versions
event_payload_store
event_type_registry_producers
instance_definition_snapshots
instance_waits
oidc_migration_item
oidc_migration_job
registry_idp_operation_ledger
repository_artifacts
tenant
tenant_hostnames
variable_schemas
```

Each of these 13 names is confirmed present, verbatim, in the diagnosis
file's `global_registry_tenant_default_is_stray` list
(`docs/issue-reports/ISS-0185-diagnosis.yaml:54-87`) — cross-checked
directly against that file, not assumed from the handoff description.

**However, 5 of these 13 are already resolved — in the opposite direction —
by the companion migration `GBL-135`.** The diagnosis file double-classifies
`api_token_audit`, `event_payload_store`, `instance_definition_snapshots`,
`instance_waits`, and `variable_schemas`: they appear in BOTH
`global_registry_tenant_default_is_stray` (lines 59, 61, 68-69, 86) AND —
verbatim — in `GBL-135`'s actual `v_tables` array
(`migrations/GBL-135_iss0185_drop_per_tenant_shadows.sql:45-58`), which has
already dropped these 5 names' `public` copies, treating `tenant_default` as
their canonical home. That has already run against the shared `bpm_test`
database and `r-co-2`'s `bpm_dev`. Re-verified directly against both source
files for this rework (see §5 for the full account, including why the
original version of this design got the direction backwards). This
contradiction between the diagnosis file's two lists is a genuine defect in
that file, filed separately as ISS-0621/GH-574 — not this design's concern
to resolve; this design simply excludes the 5 names from its scope so it does
not fight GBL-135's already-applied, operationally-canonical direction.

**GBL-136's true scope is therefore the 13 names above MINUS these 5,
leaving exactly 8 names:**

```
artifact_versions
event_type_registry_producers
oidc_migration_item
oidc_migration_job
registry_idp_operation_ledger
repository_artifacts
tenant
tenant_hostnames
```

**GBL-134 has already run against multiple databases** (the shared
`bpm_test` instance and workspace `r-co-2`'s `bpm_dev`) and, per this
repo's migration convention, is immutable once applied. This design
specifies a **new** forward migration, **GBL-136**, that completes
GLOBAL_REGISTRY coverage for the remaining, still-genuinely-missing shadow
copies by dropping exactly these 8 names' `tenant_default` (and other
tenant-schema) copies. (GBL-135 already exists as the companion
PER_TENANT-direction migration, so the next free `GBL-<NNN>` slot is 136.)

Direct consequence confirmed by ISS-0617's `confirmed_root_cause`: because
`repository_artifacts` is one of these 8 genuinely-missing names, its `tenant_default`
shadow was never dropped. `TestHarness`'s pool connection uses
`search_path = "tenant_default,public"`
(`tests/integration/helpers.zig:256`), so the test fixture's unqualified
`INSERT INTO repository_artifacts` (exp601_tier_quota_test.zig:51-65)
silently lands in the stray `tenant_default.repository_artifacts` instead
of the canonical `repository_artifacts` copy in the `public` schema that
`src/config/loader.zig`'s `loadConfigArtifact` (a pool-only connection,
`search_path=public`) actually queries. The JOIN against the `public`
schema's `repository_artifacts` finds 0 rows, `loadActiveQuotaPolicy` returns
`ConfigError.ConfigNotFound`, and `quota_policy.loadEffectiveQuotaProfile`
falls through to the platform default profile (200000) instead of applying
the test's override (10). TC-EXP-601-01 asserts `10` and observes `200000`
— this is the root-cause assertion; TC-EXP-601-02/03/04 all call
`quota_middleware.check`, which internally calls the same
`loadEffectiveQuotaProfile` as its first step, so they inherit the same
misresolved profile and their 429-rejection assertions fail downstream for
the same reason. Once GBL-136 drops `tenant_default.repository_artifacts`,
the fixture's unqualified INSERT can no longer resolve to a stray copy —
there will be exactly one `repository_artifacts` table reachable from any
connection regardless of `search_path`, and the resolver's JOIN will find
the row all four test blocks depend on.

**Out of scope — explicitly not addressed by this design.** A separate,
more severe defect was found in the same migration during the ISS-0185
diagnosis and is filed as ISS-0620 / GH-573 (BLOCKER, potential data
loss): GBL-134's *existing* `v_tables` list wrongly includes 4 names
(`artifact_activation_groups`, `entity_definitions`, `entity_record_latest`,
`entity_type_instances`) that the diagnosis actually classifies
`PER_TENANT` (opposite direction — `tenant_default` is canonical, `public`
is the stray copy) — meaning those 4 tables' `tenant_default` copies have
**already been incorrectly dropped**. This design does not attempt to
recover or remediate that damage, does not re-verify or re-litigate
ISS-0620's classification question, and does not include any of those 4
names in GBL-136's table list. They are excluded from GBL-136's scope by
construction — the 8-name list above already omits them. ISS-0620 is
fixed in its own separate WF-03 run.

## 2. Public interface — new migration: GBL-136

**File:** `migrations/GBL-136_iss0617_drop_remaining_global_registry_shadows.sql`

**Structure: identical to GBL-134**, with `v_tables` replaced by the
8-name list above. Specifically, reuse:

- The same `DO $$ ... END $$` block wrapped in a single implicit
  transaction (a bare `DO` block in this repo's migration runner executes
  inside the one transaction the runner opens per migration file — see
  §3 below for why this matters for the `tenant` case).
- The same outer loop over `SELECT id FROM public.tenant ORDER BY
  created_at ASC`, mapping the nil UUID to `tenant_default` and every
  other tenant id to `tenant_<uuid-no-dashes>`, exactly as GBL-134 lines
  73-80.
- The same inner `FOREACH v_table IN ARRAY v_tables` loop with GBL-134's
  two defenses, unchanged:
  1. **Defense 1** — only proceed if the table also exists in `public`
     (`information_schema.tables` check on `table_schema='public'`). This
     is what makes the migration safe to run even though
     `registry_idp_operation_ledger` currently exists in **neither**
     schema on the live `bpm_test` database (verified empirically via
     `\dt`) — Defense 1 causes that name to be silently skipped as a
     no-op rather than erroring, exactly as it would for any other
     not-yet-created table.
  2. **Defense 2** — only drop if the table also exists in the specific
     target tenant schema (idempotent — a schema that already lacks the
     shadow, e.g. because a partial prior run already dropped it, is
     left alone without error).
  3. `EXECUTE format('DROP TABLE %I.%I RESTRICT', v_schema_name,
     v_table)` — RESTRICT mode, unchanged. Do not use CASCADE (see §3).
  4. Same `RAISE NOTICE` per drop and summary count at the end.
- The same file-header comment block documenting root cause, safety
  properties, and cross-reference to this design doc and to
  `docs/issue-reports/ISS-0185-diagnosis.yaml`, updated to describe the
  8-table scope (and to note explicitly that 5 of the original 13
  candidate names — `api_token_audit`, `event_payload_store`,
  `instance_definition_snapshots`, `instance_waits`, `variable_schemas` —
  are deliberately excluded because `GBL-135` already resolved them in the
  PER_TENANT direction; see §5) and to note explicitly that GBL-134 already
  ran and this is its follow-up, not a replacement.

No other structural change from GBL-134's pattern is warranted — the
existing pattern's safety properties (idempotent, existence-checked,
per-tenant-schema scoped, RESTRICT, single transaction, public side never
touched) fully cover this case. Inventing a different pattern here would
only create an unexplained inconsistency between two migrations solving
the same class of problem.

## 3. Error taxonomy / cross-table FK ordering within `tenant_default` — the part that is NOT identical to GBL-134's easy case

The one error condition this migration must handle deliberately is
PostgreSQL's `dependent_objects_still_exist` exception, raised by a
RESTRICT-mode `DROP TABLE` when a live foreign key still points at the
table being dropped. GBL-134 never needed to handle this (its 24 names
were verified dependent-free); GBL-136 does, for the reasons below.

GBL-134's header comment asserts (line 105-106) that none of its 24
original table names have tenant-side dependents, so every RESTRICT drop
in that migration was guaranteed to succeed. **That guarantee does not
carry over to all 8 new names.** Live inspection of
`pg_constraint`/`pg_depend` on the `tenant_default` schema of the shared
`bpm_test` database (the same database the ISS-0185 diagnosis and
ISS-0617 verification both used) found FK edges **within the 8-name set
itself**, plus edges into the 8-name set from tables that must stay
in `tenant_default`:

| Referencing table (`tenant_default`) | FK column | References (`tenant_default`) |
|---|---|---|
| `event_type_registry_producers` (in scope) | → | `artifact_versions` (in scope) |
| `oidc_migration_item` (in scope) | → | `oidc_migration_job` (in scope) |
| `artifact_versions` (in scope, self-referencing) | parent_version_id | `artifact_versions` (in scope) |
| `artifact_versions` (in scope) | content ref | `repository_artifacts` (in scope) |
| `tenant_hostnames` (in scope) | tenant_id | `tenant` (in scope) |
| `artifact_activations` (**NOT in scope — PER_TENANT, canonical in tenant_default**) | → | `artifact_versions` (in scope) |
| `artifact_activation_history` (**NOT in scope — PER_TENANT, canonical in tenant_default**) | → | `artifact_versions` (in scope) |
| `repository_form_schemas` (**NOT in scope — exists only in `tenant_default`, not classified in the ISS-0185 diagnosis at all**) | `version_id` | `artifact_versions` (in scope) — `fk_form_schema_version` |

Two distinct consequences follow, and GBL-136's design must handle both
without aborting the whole migration:

### 3.1 `artifact_versions` cannot ever be dropped via RESTRICT, and that is correct

`artifact_activations` and `artifact_activation_history` are themselves
classified PER_TENANT by the ISS-0185 diagnosis
(`docs/issue-reports/ISS-0185-diagnosis.yaml:90-91`) — their
`tenant_default` copies are the canonical, legitimate data, not shadows.
Those tables are untouched by GBL-136 (they are not in the 8-name list)
and will continue to hold real per-tenant rows that FK-reference
`tenant_default.artifact_versions`. This means `DROP TABLE
tenant_default.artifact_versions RESTRICT` will **fail every single time
it runs**, on every tenant schema, for as long as those two legitimate
per-tenant tables exist — this is not a transient ordering problem that
a different `v_tables` array order fixes; it is a permanent, structural
FK relationship between a GLOBAL_REGISTRY shadow and genuinely-canonical
PER_TENANT data in the same schema.

**This is the correct, intended safety behavior, not a defect to work
around.** RESTRICT failing here is PostgreSQL correctly refusing to
silently orphan `artifact_activations`/`artifact_activation_history` rows
or (worse) cascade-delete them. GBL-136 must **not** use CASCADE to force
this drop through — CASCADE would delete the referencing rows in
`artifact_activations`/`artifact_activation_history`, which are live
per-tenant data, not shadow copies. Forcing this table's drop is out of
scope for both this issue and ISS-0620; it is arguably not even a bug —
`artifact_versions`'s presence in the diagnosis's GLOBAL_REGISTRY list
may itself need re-examination in a future issue, but that question is
explicitly **not** decided here (GBL-135's own header comment already
flags `artifact_versions`-adjacent tables `oidc_migration_job` and
`repository_artifacts` as reclassified HYBRID during a later verification
pass for exactly this kind of dependent-table reason — see §5 below for
why `repository_artifacts` itself is still safe to drop despite that
note).

### 3.2 The migration must tolerate a per-table RESTRICT failure without aborting the whole transaction

This is the operationally critical question and it must be answered
precisely, not assumed. GBL-134's structure is a single `DO $$ ... END
$$` block containing a `FOREACH` loop with no per-iteration exception
handler (no `BEGIN ... EXCEPTION WHEN ... END` inside the loop body).
`EXECUTE format('DROP TABLE %I.%I RESTRICT', ...)` that fails on
dependent-object-exists raises `dependent_objects_still_exist`, an
**unhandled** exception inside the `DO` block. PL/pgSQL does not catch
this automatically — it propagates out of the `DO $$ ... END $$`
statement, and the migration runner's surrounding transaction (per
migration file, per this repo's convention) rolls back the **entire**
migration file, including every drop that already succeeded on earlier
tenant schemas or earlier table names in the same pass.

**Consequence for GBL-136: reusing GBL-134's bare `FOREACH` structure
unmodified would make the `artifact_versions` RESTRICT failure (§3.1)
abort the whole migration and roll back every other successful drop in
the same file, on every tenant schema — not just skip that one table.**
That is a real behavioral difference from GBL-134, where the "no tenant
dependents" guarantee meant this code path was never exercised. GBL-136
must add exactly one piece of structure GBL-134 does not need:

- Wrap each individual `EXECUTE format('DROP TABLE %I.%I RESTRICT', ...)`
  call in its own `BEGIN ... EXCEPTION WHEN dependent_objects_still_exist
  THEN ... END` sub-block (a nested block within the existing `FOREACH`
  iteration, not a change to the outer transaction structure). On
  catching `dependent_objects_still_exist`, `RAISE NOTICE` naming the
  schema, table, and the fact that the drop was skipped due to a live FK
  dependent (reference this design doc, §3.1, in the notice text so a
  future reader lands here), and continue the loop — do not re-raise,
  do not set any rollback flag. Every other table name and every other
  tenant schema must still be attempted and still commit.
- This exception handler is scoped narrowly to
  `dependent_objects_still_exist` only. Any other error (e.g. permissions,
  connectivity) must still propagate and abort the migration normally —
  do not use a bare `WHEN OTHERS` catch-all, which would silently mask
  unrelated failures the same way the `continue-on-error` CI pattern did
  in the incident CLAUDE.md documents under "Never Satisfy a Gate by
  Editing What It Measures."
- The final `RAISE NOTICE` summary line should report two counts:
  tables/schemas actually dropped, and tables/schemas skipped due to a
  live dependent (expected: `artifact_versions` skipped on every tenant
  schema; everything else dropped). A summary that shows 0 skips would
  itself be a signal something changed and needs re-investigation.

## 4. `tenant` — special handling, and why it is expected to succeed

`tenant` is the one name in this list that intuitively sounds
FK-dangerous, since nearly every business table in every schema
references it. Live inspection of `tenant_default`'s FK graph confirms
exactly one **tenant_default-local** dependent: `tenant_hostnames`
(`tenant_hostnames_tenant_id_fkey`, `tenant_default.tenant_hostnames.tenant_id
→ tenant_default.tenant.id`). Critically, `tenant_hostnames` is **itself
one of the 8 names in this migration's scope** — so as long as
`tenant_hostnames`'s `tenant_default` shadow is dropped in the same pass
(order within the `FOREACH` array does not strictly matter across
separate `DO` block invocations per tenant schema, but for clarity
GBL-136's `v_tables` array should list `tenant_hostnames` before `tenant`
so the common case resolves within a single top-to-bottom pass rather
than requiring the exception-and-skip path), `tenant`'s RESTRICT drop
will succeed cleanly with no dependent objects remaining.

The other tables that reference the canonical, untouched `tenant` copy in
the `public` schema are irrelevant here — GBL-136 only ever drops
`tenant_default`'s (and other tenant schemas') copies, never the `public`
schema's `tenant` table, so FK chains anchored on the `public` copy are
never affected by this migration.

If a future or differently-provisioned database has additional
`tenant_default`-local FK dependents on `tenant` beyond `tenant_hostnames`
(none were found on the inspected `bpm_test` database, but this is not
provable for every possible database state), the same §3.2
exception-and-skip handling applies: RESTRICT failing on `tenant` is
tolerated as an expected/acceptable outcome — the migration logs a skip
and continues — rather than treated as a fatal error. Blocking the drop
rather than silently cascading is the correct, conservative behavior for
a table this central; GBL-136 must never use CASCADE on `tenant`.

## 5. Why 5 of the original 13 candidate names are excluded — corrected finding (rework 1)

**This section was factually backwards in the original version of this
design and has been corrected.** The original text claimed live inspection
showed `api_token_audit`, `event_payload_store`,
`instance_definition_snapshots`, `instance_waits`, and `variable_schemas`
still had `public` copies, and concluded GBL-136 should include all 5.
CODE-DESIGN-VALIDATOR's independent live query against `bpm_test`
(`docker exec` `psql`) found the opposite, and this rework re-verified the
correction directly against both source files rather than trusting either
prior claim:

- `docs/issue-reports/ISS-0185-diagnosis.yaml`'s `global_registry_tenant_default_is_stray`
  list (lines 54-87) includes all 5 names, classifying them GLOBAL_REGISTRY
  (i.e., `tenant_default` copy is the stray shadow, `public` is canonical).
- `migrations/GBL-135_iss0185_drop_per_tenant_shadows.sql`'s **actual**
  `v_tables` array (lines 45-58 — not just its header comment) also
  contains all 5 names verbatim: `api_token_audit`, `event_payload_store`,
  `instance_definition_snapshots`, `instance_waits`, `variable_schemas`.
  GBL-135 classifies PER_TENANT tables as the tables it drops from
  `public` (its own header, lines 1-20: "This migration drops the public
  shadow for each per-tenant table... tenant_default.\<name\> is never
  touched"). GBL-135 has already run against the shared `bpm_test`
  database and `r-co-2`'s `bpm_dev`.

**These 5 names are therefore double-classified in the diagnosis file
itself** — present in both `global_registry_tenant_default_is_stray`
(GLOBAL direction) and, operationally, treated as PER_TENANT by GBL-135's
actual applied array (even though the diagnosis file's own
`per_tenant_public_is_stray` list, lines 88-101, does not separately list
them — the contradiction is between the diagnosis file's GLOBAL list and
GBL-135's applied `v_tables`, not between the diagnosis file's two lists).
This contradiction is a genuine defect in the source diagnosis, filed
separately as **ISS-0621/GH-574** — this design does not attempt to
resolve which classification is "correct" in the abstract.

**The practical, already-settled fact this design must respect:** GBL-135
has *already run* and already dropped these 5 names' `public` copies on
every database this migration will target. Their `tenant_default` copies
are the only surviving copies of these 5 tables anywhere — dropping them
via GBL-136 would not be completing a shadow-copy cleanup, it would be
**deleting the only remaining copy of live data**. That is categorically
different from GBL-136's other 8 names, where the `public` copy is
canonical and untouched, and the `tenant_default` copy is a true,
disposable shadow.

**Resolution: GBL-136 excludes these 5 names entirely.** They are not
included in the `v_tables` array, not mentioned in the Section 8
verification query, and not counted in this design's scope. If Defense 1
(only drop if the table also exists in `public`) were evaluated for these
5 names on a database where GBL-135 has already run, it would correctly
find no `public` copy and skip them as a no-op anyway — but this design
does not rely on that as its safety mechanism, since a differently-ordered
or partially-migrated database could theoretically have applied GBL-136
before GBL-135 (both are new-enough forward migrations with no declared
ordering dependency between them other than migration-file sequence
number). Explicit exclusion by omission from `v_tables`, not reliance on
Defense 1, is the correct and unambiguous way to keep these 5 tables'
`tenant_default` copies permanently safe from this migration.

**`repository_artifacts` and `oidc_migration_job` are unaffected by this
correction and remain in GBL-136's 8-name scope**, safe to drop for a
different, independently-verified reason. GBL-135's file header
(`migrations/GBL-135_iss0185_drop_per_tenant_shadows.sql:41-44`) contains a
note that `oidc_migration_job` and `repository_artifacts` were "moved to
HYBRID during v4 verification" because they have **public-side** FK
dependents (`oidc_migration_item` and `artifact_versions`, respectively,
referencing them from `public`). That note is about the opposite direction
from what GBL-136 does: GBL-135 drops **public** shadows of PER_TENANT
tables, and the note explains why the `public` schema's
`oidc_migration_job` / `repository_artifacts` copies were correctly **left
in place** rather than dropped as PER_TENANT shadows (because `public`-side
data legitimately depends on them). Unlike the 5 names above, neither
`oidc_migration_job` nor `repository_artifacts` actually appears in
GBL-135's applied `v_tables` array (verified directly against
`migrations/GBL-135_iss0185_drop_per_tenant_shadows.sql:45-58` — the array
lists 12 names, neither of these two among them) — the header note is
informational context about why they were *considered and rejected* for
GBL-135, not evidence they were ever dropped from `public` by it. Their
`public` copies remain canonical and untouched, exactly as the diagnosis
file's GLOBAL_REGISTRY classification expects. Live inspection confirms
`tenant_default.oidc_migration_job` has no local dependents other than
`tenant_default.oidc_migration_item` (in scope, handled per §3.2 ordering
the same way as `tenant`/`tenant_hostnames`), and
`tenant_default.repository_artifacts` has exactly one local dependent,
`tenant_default.artifact_versions` — which is itself never actually
dropped (§3.1), so `repository_artifacts`'s drop is **not** blocked by
that edge; the FK points the other way (`artifact_versions` →
`repository_artifacts`), so `repository_artifacts` has no incoming FK from
anything that survives, and its drop succeeds. This is also consistent
with ISS-0617's own verification, which confirmed
`tenant_default.repository_artifacts` is the actual stray copy causing the
test failure.

## 6. Fixes TC-EXP-601-01 through 04

- **TC-EXP-601-01** calls `quota_policy.loadEffectiveQuotaProfile`
  directly and asserts `max_entity_records_total == 10`. Once GBL-136
  drops `tenant_default.repository_artifacts`, the test fixture's
  unqualified `INSERT INTO repository_artifacts` (which currently
  resolves to the stray tenant_default copy via
  `search_path=tenant_default,public`) has nowhere left to land except
  `public.repository_artifacts` — there is exactly one relation named
  `repository_artifacts` reachable from any connection. The resolver's
  pool connection (`search_path=public`) now finds the row its JOIN
  needs, `loadActiveQuotaPolicy` returns the artifact content instead of
  `ConfigError.ConfigNotFound`, and `loadEffectiveQuotaProfile` applies
  the test's override (10) instead of falling through to
  `defaultProfileForTier(.standard)` (200000).
- **TC-EXP-601-02, 03, 04** all call `quota_middleware.check`, which
  calls the same `loadEffectiveQuotaProfile` as its first internal step.
  Once that call resolves the correct (test-configured, typically
  zero-quota) profile instead of the generous platform default, the
  requested deltas in each test correctly exceed the resolved limits and
  the middleware's 429-rejection path is exercised as each test expects.
- TC-EXP-601-04's second, distinct failure mode noted in ISS-0617
  (`PgError.ServerError` on `INSERT INTO instance_waits`) was flagged in
  the issue as possibly sharing the same upstream mechanism because
  `instance_waits` was originally believed to be one of GBL-136's missing
  names. **Corrected by this rework (§5): `instance_waits` is one of the 5
  names GBL-135 already resolved in the PER_TENANT direction and is
  explicitly excluded from GBL-136's 8-name scope.** GBL-136 therefore does
  **not** touch `tenant_default.instance_waits`, and does not fix
  TC-EXP-601-04's second failure mode by this mechanism. This failure mode
  remains a distinct issue to re-diagnose separately, per ISS-0617's own
  notes — it was never safe to assume fixed by this design without
  verification at TEST-RUNNER time, and that remains true now that the
  table is confirmed out of scope rather than merely unverified.

## 7. Files touched

- `migrations/GBL-136_iss0617_drop_remaining_global_registry_shadows.sql`
  (new)
- `CHANGELOG.md` (DOC-UPDATER step)

## 8. Verification

- `zig build` exits 0
- `zig build migrate` exits 0 against the shared `bpm_test` database (idempotent — safe to re-run)
- `RAISE NOTICE` output from the migration run shows 7 of 8 names dropped per tenant schema and exactly 1 skip (`artifact_versions`, per §3.1) with no unhandled exception
- `zig build test-integration` (or the equivalent scoped `exp601` target) — TC-EXP-601-01 through 03 pass (TC-EXP-601-04's `repository_artifacts`-driven assertion passes; its separate `instance_waits`-related failure mode is explicitly not addressed by this design, per §6)
- Re-run the ISS-0185 acceptance intersection query restricted to these 8 names:
  ```
  SELECT t FROM (
    SELECT unnest(ARRAY['event_type_registry_producers',
      'oidc_migration_item','oidc_migration_job',
      'registry_idp_operation_ledger','repository_artifacts',
      'tenant_hostnames']) AS t
  ) expected
  INTERSECT
  SELECT table_name FROM information_schema.tables
   WHERE table_schema='tenant_default' AND table_type='BASE TABLE';
  ```
  Expected: **0 rows** for these 6 (excludes `artifact_versions` and
  `tenant`, which are expected to still show a row each in
  `tenant_default` per §3.1/§4's documented, intentional skip conditions
  — `tenant` is expected to succeed and thus also return 0 rows in the
  common case, but is excluded from this strict assertion so the test
  does not become a false BLOCKER if a database has an undiscovered
  local `tenant` dependent). The 5 excluded names
  (`api_token_audit`, `event_payload_store`,
  `instance_definition_snapshots`, `instance_waits`, `variable_schemas`)
  are deliberately **not** part of this query — they are expected to
  continue showing a row each in `tenant_default` after GBL-136 runs,
  per §5.

## 9. Out of scope

- ISS-0620 (the 4 wrongly-dropped PER_TENANT tables) — separate run.
- Recovering any data lost by ISS-0620's incorrect drops — separate run.
- Deciding whether `artifact_versions` truly belongs in the
  GLOBAL_REGISTRY classification given its structural PER_TENANT
  dependents — flagged in §3.1 as a question for a future issue, not
  decided here.
- Reconciling the diagnosis-file double-classification discrepancy noted
  in §5 (filed as ISS-0621/GH-574) — not resolved here; this design only
  excludes the 5 affected names from GBL-136's scope.
- Annotating source migrations with `-- scope: public` headers (already
  covered by the original ISS-0185 design's §3.1, orthogonal to this
  follow-up).
