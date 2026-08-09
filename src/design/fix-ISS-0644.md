# Fix design: ISS-0644 / GH-643

## Problem

`src/db/migrations.zig`'s `MigrationScope` enum has two values: `.public_only`
(skip in every tenant-schema pass) and `.all_schemas` (run in every pass,
including `public`). There is no primitive for the mirror case: a migration
whose table is PER_TENANT-canonical and must run in every tenant-schema pass
but **never** in the `public` pass.

ISS-0641/GH-637 classified 14 dual-schema-duplicated tables and shipped a
corrective migration (`GBL-141`) that drops the stray shadows once — but for
13 of those 14 (the PER_TENANT ones), the creation path stayed open: their
source migrations still default to `.all_schemas`, so any fresh
`tenant_default` (re-)provisioning — a cold `db_test` rebuild, a fresh CI
run, a new tenant onboarding — re-runs the unqualified `CREATE TABLE` in the
`public` pass too, recreating the shadow GBL-141 just cleaned. Confirmed
live during this issue's own verification: after GBL-141 merged, a
subsequent cold-start replay reproduced 8 of the 14 shadows again.

## Fix

Add `MigrationScope.tenant_only`, selected by a new `-- scope: tenant_only`
header — the structural mirror of `-- scope: public`. The per-schema apply
loop in `runForSchema` already branches on `is_public_pass`; add the
symmetric skip:

```zig
if (!is_public_pass and scope == .public_only) continue;
if (is_public_pass and scope == .tenant_only) continue;
```

## Which source migrations get the header

Only files that are **genuinely single-purpose** — create exactly the one
PER_TENANT table (plus its own indexes) and nothing else — are safe for a
whole-file header, since `MigrationScope` is a whole-file classifier with no
per-statement granularity:

| File | Table | Why safe |
|---|---|---|
| `026_ext05_subprocess_links.sql` | `subprocess_links` | Single `CREATE TABLE` + 2 indexes, nothing else in the file. |
| `093_exp103_instance_waits.sql` | `instance_waits` | Single `CREATE TABLE` + 1 index inside a `DO $$` block; already had a `to_regclass` no-op guard for `public`, which the header now makes structural rather than a runtime heuristic. |
| `095_iss0176_lua_script_execution_audit.sql` | `lua_script_execution_audit` | Single `CREATE TABLE` + 2 indexes, nothing else in the file. |

**NOT touched** (mixed-classification files — a whole-file `tenant_only`
header would incorrectly suppress a table or statement that legitimately
belongs in `public`):

| File | Why unsafe | Tables involved |
|---|---|---|
| `019_idn04_api_token_management.sql` | `ALTER TABLE api_tokens` + `INSERT INTO roles (...)` seed data, both of which must run in the `public` pass. | `api_token_audit` (PER_TENANT) mixed with `api_tokens`/`roles` writes (public). |
| `012_event_retention.sql` | Creates two tables (`event_payload_store`, `variable_schemas`) — both flagged PER_TENANT by ISS-0641, so this one is actually safe on closer inspection, but deferred here for a follow-up pass rather than risking an unverified multi-table file in this fix. |
| `008_identity.sql` | Creates 9 tables; only 4 (`role_permissions`, `user_groups`, `group_roles`, `sessions`) are PER_TENANT — `users`, `roles`, `user_roles`, `groups`, `api_tokens` are GLOBAL_REGISTRY and must keep running in `public`. |
| `004_definitions.sql` | Creates `process_definitions` (GLOBAL_REGISTRY-adjacent, public-facing) + `instance_definition_snapshots` (PER_TENANT). |
| `007_timers.sql` | Creates `timers` + `sla_records`; only `sla_records` is PER_TENANT. |
| `010_dlq.sql` | Creates `webhook_subscriptions` + `webhook_deliveries`; only `webhook_deliveries` is PER_TENANT. |
| `058_repo_artifacts_tenant_activation.sql` | Already documented as HYBRID by ISS-0641 itself — creates both a per-tenant table and the GLOBAL_REGISTRY `tenant_artifact_activations`. |

For the 6 mixed files above, `GBL-141`'s cleanup-only fix remains the active
mitigation (re-run after any cold-start replay). Closing those permanently
requires either splitting each file into single-purpose migrations (a
migration-history-rewriting change, avoided per this issue lineage's
established precedent that already-applied files are immutable) or a
per-statement scope mechanism (a larger structural change) — out of scope
for this fix. Tracked implicitly via GBL-141's continued presence; no new
issue filed since this is already visible in ISS-0644's own body as
"evaluate cost/benefit" future work, not a newly-discovered gap.

## Acceptance criteria (from GH-643)

- [x] A `.tenant_only` `MigrationScope` value exists, selected by a
      `-- scope: tenant_only` header, mirroring `.public_only`.
- [x] Applied to the 3 confirmed-safe single-purpose PER_TENANT source
      migrations.
- [x] Verified via live cold-start reproduction (`db_test` rebuilt from an
      empty volume, `zig build migrate` + full integration replay) that
      the 3 fixed tables no longer recreate their `public` shadow.
- [x] `docs/issues/` and CHANGELOG updated.

## Non-goals

- Splitting the 6 mixed-classification files into single-purpose migrations.
- A per-statement/per-table scope mechanism (larger change, evaluate
  separately if the mixed-file gap becomes actively painful).
- A pre-merge structural lint catching "no scope primitive can close this"
  (ISS-0641's suggestion #4/#3) — not built here, out of scope for this fix.
